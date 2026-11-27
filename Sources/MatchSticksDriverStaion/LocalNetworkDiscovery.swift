import Foundation
import Network

// MARK: - NI 服务发现（Bonjour `_ni._tcp` 浏览）

/// 浏览器抽象：生产为真实 NWBrowser（start 即触发系统「本地网络」授权询问），测试注入假实现——
/// 不建套接字。NWBrowser.Result 没有公开构造器，结果以服务名交付。
protocol LocalNetworkBrowsing: AnyObject {
    var onState: ((NWBrowser.State) -> Void)? { get set }
    var onServices: (([String]) -> Void)? { get set }
    var onServiceEvidence: (([LocalNetworkServiceEvidence]) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
}

/// 可注入、可测试的服务证据；生产由 NWBrowser.Result 映射，不公开 endpoint 或授权信息。
struct LocalNetworkServiceEvidence: Equatable {
    let name: String
    let serviceType: String
    let interfaces: [NWInterface.InterfaceType]
}

/// 发现事件：只用于日志 / 诊断——不改连接目标，不进发送轮转，也不自动连接。
enum LocalNetworkDiscoveryEvent: Equatable {
    /// 系统拒绝本地网络访问（kDNSServiceErr_PolicyDenied，-65570）
    case policyDenied
    /// 其他浏览失败（网络不可用、mDNS 故障……与权限无关）
    case failed(String)
    /// 瞬态等待（网络暂不可用；既非失败也非权限问题）
    case waiting(String)
    /// 浏览已就绪——没有结果不代表权限被拒绝
    case ready
    /// 当前发现的 NI 服务名（排序；仅在集合变化时发出）
    case services([String])
    /// 带明确非回环接口证据的 NI 服务发现
    case nonLoopbackService(String)
}

/// 生产浏览器：`NWBrowser(for: .bonjour(type: "_ni._tcp", domain: nil))`。
/// NSBonjourServices 已声明 `_ni._tcp`（build-app.sh）；只浏览，不监听、不连接。
final class NIBonjourBrowser: LocalNetworkBrowsing {
    static let serviceType = "_ni._tcp"
    private let browser: NWBrowser

    init() {
        browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
    }

    var onState: ((NWBrowser.State) -> Void)? {
        didSet { browser.stateUpdateHandler = onState }
    }

    var onServices: (([String]) -> Void)? {
        didSet { updateBrowseHandler() }
    }

    var onServiceEvidence: (([LocalNetworkServiceEvidence]) -> Void)? {
        didSet { updateBrowseHandler() }
    }

    private func updateBrowseHandler() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.onServices?(Self.serviceNames(results))
            self.onServiceEvidence?(Self.serviceEvidence(results))
        }
    }

    func start(queue: DispatchQueue) { browser.start(queue: queue) }
    func cancel() { browser.cancel() }

    /// 当前结果的服务名（排序去重）
    static func serviceNames(_ results: Set<NWBrowser.Result>) -> [String] {
        Set(results.compactMap { name(of: $0.endpoint) }).sorted()
    }

    /// Bonjour 服务 endpoint 的服务名；主机端口等其他 endpoint 没有
    static func name(of endpoint: NWEndpoint) -> String? {
        if case .service(let name, _, _, _) = endpoint { return name }
        return nil
    }

    static func serviceEvidence(_ results: Set<NWBrowser.Result>) -> [LocalNetworkServiceEvidence] {
        results.compactMap { result in
            guard case .service(let name, let type, _, _) = result.endpoint else { return nil }
            return LocalNetworkServiceEvidence(
                name: name, serviceType: type, interfaces: result.interfaces.map(\.type))
        }
    }
}

/// NWBrowser 的薄封装：一次启动、可取消、幂等。回调在主队列交付（start 传 .main），
/// 事件同步送达 onEvent（主线程）。首次 start 即触发系统本地网络授权询问——这是真实服务发现，
/// 不是伪造弹窗；浏览结果仅作诊断，不进发送轮转。
/// 终态（权限被拒 / 浏览失败）即取消浏览器；同一终态事件只报一次，重启后也不重复。
@MainActor
final class LocalNetworkDiscovery {
    private let makeBrowser: () -> LocalNetworkBrowsing
    private var browser: LocalNetworkBrowsing?
    private var discovered: [String] = []
    private var reportedNonLoopbackServices: Set<String> = []
    /// 最近一次已上报的终态事件（跨重启保留：同一会话内同一拒绝 / 失败不刷第二条日志）
    private var lastTerminalEvent: LocalNetworkDiscoveryEvent?
    var onEvent: ((LocalNetworkDiscoveryEvent) -> Void)?

    init(makeBrowser: @escaping () -> LocalNetworkBrowsing = { NIBonjourBrowser() }) {
        self.makeBrowser = makeBrowser
    }

    var isRunning: Bool { browser != nil }

    /// 幂等：已启动则不新建、不重启浏览器。
    func start() {
        guard browser == nil else { return }
        let browser = makeBrowser()
        self.browser = browser
        discovered = []
        reportedNonLoopbackServices = []
        browser.onState = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        browser.onServices = { [weak self] names in
            MainActor.assumeIsolated { self?.handle(names) }
        }
        browser.onServiceEvidence = { [weak self] evidence in
            MainActor.assumeIsolated { self?.handle(evidence) }
        }
        browser.start(queue: .main)
    }

    /// 取消并释放浏览器；重复调用安全，之后可再次 start（新浏览器）。
    func cancel() {
        guard let browser else { return }
        self.browser = nil
        browser.onState = nil
        browser.onServices = nil
        browser.onServiceEvidence = nil
        browser.cancel()
    }

    private func handle(_ state: NWBrowser.State) {
        switch state {
        case .setup, .cancelled:
            break
        case .ready:
            onEvent?(.ready)
        case .waiting(let error):
            guard Self.isPolicyDenied(error) else {
                onEvent?(.waiting(String(describing: error)))
                return
            }
            finish(.policyDenied)
        case .failed(let error):
            finish(Self.isPolicyDenied(error) ? .policyDenied : .failed(String(describing: error)))
        @unknown default:
            break
        }
    }

    /// 终态：先取消浏览器（NWBrowser 的 failed 不可恢复；权限被拒不该随网络变化反复报），
    /// 再上报——同一终态事件只报一次。
    private func finish(_ event: LocalNetworkDiscoveryEvent) {
        cancel()
        guard lastTerminalEvent != event else { return }
        lastTerminalEvent = event
        onEvent?(event)
    }

    private func handle(_ names: [String]) {
        guard names != discovered else { return }
        discovered = names
        onEvent?(.services(names))
    }

    private func handle(_ evidence: [LocalNetworkServiceEvidence]) {
        var newlyVerified: [String] = []
        for item in evidence where Self.isNonLoopbackEvidence(item) && !reportedNonLoopbackServices.contains(item.name) {
            reportedNonLoopbackServices.insert(item.name)
            newlyVerified.append(item.name)
        }
        for name in newlyVerified {
            onEvent?(.nonLoopbackService(name))
        }
    }

    /// 只有明确的 Wi-Fi / 有线 / 蜂窝接口才构成非回环证据；空接口、回环和 .other 均不算。
    static func isNonLoopbackEvidence(_ evidence: LocalNetworkServiceEvidence) -> Bool {
        evidence.serviceType == NIBonjourBrowser.serviceType &&
            evidence.interfaces.contains { knownInterface in
                [.wifi, .wiredEthernet, .cellular].contains(knownInterface)
            }
    }

    /// kDNSServiceErr_PolicyDenied（-65570）＝系统拒绝本地网络访问；Network 框架以 NWError.dns 上报。
    /// 不做强转：非 dns 错误或码值不同即视为非权限问题。
    static func isPolicyDenied(_ error: NWError) -> Bool {
        guard case .dns(let code) = error else { return false }
        return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
    }
}
