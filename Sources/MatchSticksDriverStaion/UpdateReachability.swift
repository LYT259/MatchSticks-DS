import Foundation
import Network
import DSCore

// MARK: - GitHub 可达性：真实 HTTPS 探测（默认路由 → 有线 Ethernet）+ 网络路径唤醒（Sparkle 无关）
//
// 判定依据是一次真实 HTTPS 请求（HEAD feed URL）：收到任意 HTTP 状态码（含私有仓库 404）
// 即「GitHub 实际可达」；传输层失败（无连接 / DNS / TLS / 超时）即不可达。
// 不嵌入任何 GitHub 凭证，不调 Releases API。
//
// 路由（2026-11-23 修订，取代「系统自然 fallback」的假设）：先走系统默认路由（macOS 按网络服务
// 顺序选路，radio Wi‑Fi 优先时默认路由通常就是 Wi‑Fi）；默认路由失败后**明确**再经非 Wi‑Fi 路径
// （Mac 上即可用的有线 Ethernet / Thunderbolt 网桥；NWConnection prohibitedInterfaceTypes = [.wifi]，
// 见 SystemRouteProbeTransport）发一次同样的 HTTPS 请求。只有两条路径都失败才算不可达。本类不绑定机器人
// socket、不改网络服务优先级、不关 Wi‑Fi、不干扰机器人连接；Ethernet 不可用时由调度器按有上限的退避持续重试。
//
// 回环地址（本地升级链路 E2E 的 127.0.0.1 测试源）没有「不经 Wi‑Fi」的路径可言，默认路由失败即判不可达。
// NWPathMonitor 同时观察默认路径与有线路径：任一可用即视为 satisfied，及时唤醒调度器重试。
//
// 顺序逻辑可注入 UpdateProbeTransport 做行为测试（test-ui.sh）；生产传输在 UpdateProbeTransport.swift。

/// 探测路由：先系统默认路由，失败后明确改走有线 Ethernet。
enum UpdateProbeRoute: Equatable, Sendable {
    case defaultRoute
    case wiredEthernet
}

/// 一次探测序列的最终结果。route = 作出判定的路径（可达 = 成功的那条；不可达 = 最后尝试的那条，
/// 即有线）；detail 进事件日志，有线阶段的 detail 同时保留默认路由的失败原因。
struct UpdateProbeResult: Equatable, Sendable {
    let reachable: Bool
    let route: UpdateProbeRoute
    let detail: String
}

/// 单路径探测传输抽象。生产实现：默认路由 = URLSession HEAD；有线 = NWConnection + TLS + HTTP/1.1 HEAD。
/// completion 可在任意队列回调，UpdateReachability 自行回主线程；对同一次调用重复回调会被忽略。
protocol UpdateProbeTransport: AnyObject {
    func probe(_ route: UpdateProbeRoute, url: URL, completion: @escaping (UpdateProbeResult) -> Void)
}

@MainActor
final class UpdateReachability {

    /// 探测序列结束（唯一回报点；同一序列只回报一次）
    var onResult: ((UpdateProbeResult) -> Void)?
    /// 路径可用性翻转（默认路径 ∥ 有线路径任一可用 = true；去抖：只在翻转时回调）
    var onPathChange: ((Bool) -> Void)?

    private let probeURL: URL?
    private let transport: any UpdateProbeTransport
    private let monitorsPath: Bool
    private let monitor = NWPathMonitor()
    private let wiredMonitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
    private let queue = DispatchQueue(label: "matchsticks.ds.updatereachability", qos: .utility)
    private(set) var isProbing = false
    private var currentRoute: UpdateProbeRoute = .defaultRoute
    private var defaultFailure = ""
    private var defaultPathSatisfied: Bool?
    private var wiredPathSatisfied: Bool?
    private var aggregatedSatisfied: Bool?

    /// - Parameters:
    ///   - transport: 默认 SystemRouteProbeTransport（真实网络）；测试注入脚本化传输
    ///   - monitorsPath: 默认 true；测试传 false 以不触碰 NWPathMonitor
    init(probeURL: URL?, transport: (any UpdateProbeTransport)? = nil, monitorsPath: Bool = true) {
        self.probeURL = probeURL
        self.transport = transport ?? SystemRouteProbeTransport()
        self.monitorsPath = monitorsPath
    }

    /// 短超时、无 cookie、无缓存、不等待连通——失败交给调度器退避重试。
    nonisolated static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// 回环目标（127/8、::1、localhost）不存在有线路径，默认路由失败即判不可达。
    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return false }
        if host.lowercased() == "localhost" { return true }
        if let v4 = IPv4Address(host), v4.isLoopback { return true }
        if let v6 = IPv6Address(host), v6.isLoopback { return true }
        return false
    }

    func start() {
        guard monitorsPath else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status != .unsatisfied
            DispatchQueue.main.async { self?.pathUpdated(defaultSatisfied: satisfied, wiredSatisfied: nil) }
        }
        wiredMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status != .unsatisfied
            DispatchQueue.main.async { self?.pathUpdated(defaultSatisfied: nil, wiredSatisfied: satisfied) }
        }
        monitor.start(queue: queue)
        wiredMonitor.start(queue: queue)
    }

    /// 发起一次探测序列：默认路由 → （失败且有 wires 可言时）有线 Ethernet；同一时刻最多一个序列。
    func probe() {
        guard !isProbing else { return }
        guard let probeURL else {
            onResult?(UpdateProbeResult(reachable: false, route: .defaultRoute, detail: tr("未配置")))
            return
        }
        isProbing = true
        currentRoute = .defaultRoute
        defaultFailure = ""
        transport.probe(.defaultRoute, url: probeURL) { [weak self] result in
            DispatchQueue.main.async { self?.defaultRouteFinished(result, url: probeURL) }
        }
    }

    // MARK: 顺序（主线程）

    private func defaultRouteFinished(_ result: UpdateProbeResult, url: URL) {
        // 过期 / 重复回调守卫：只有仍在默认阶段才接受
        guard isProbing, currentRoute == .defaultRoute else { return }
        if result.reachable {
            finish(result)
            return
        }
        defaultFailure = result.detail
        guard !Self.isLoopback(url) else {
            finish(UpdateProbeResult(reachable: false, route: .defaultRoute, detail: result.detail))
            return
        }
        currentRoute = .wiredEthernet
        transport.probe(.wiredEthernet, url: url) { [weak self] wired in
            DispatchQueue.main.async { self?.wiredRouteFinished(wired) }
        }
    }

    private func wiredRouteFinished(_ result: UpdateProbeResult) {
        guard isProbing, currentRoute == .wiredEthernet else { return }
        finish(UpdateProbeResult(
            reachable: result.reachable,
            route: .wiredEthernet,
            detail: "default route: \(defaultFailure); Ethernet: \(result.detail)"
        ))
    }

    private func finish(_ result: UpdateProbeResult) {
        isProbing = false
        onResult?(result)
    }

    // MARK: 路径监控（主线程；去抖：只在聚合状态翻转时回调）

    private func pathUpdated(defaultSatisfied: Bool?, wiredSatisfied: Bool?) {
        if let defaultSatisfied { self.defaultPathSatisfied = defaultSatisfied }
        if let wiredSatisfied { self.wiredPathSatisfied = wiredSatisfied }
        let satisfied = self.defaultPathSatisfied == true || self.wiredPathSatisfied == true
        guard aggregatedSatisfied != satisfied else { return }
        aggregatedSatisfied = satisfied
        onPathChange?(satisfied)
    }
}
