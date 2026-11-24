import Foundation
import DSCore

/// 本地网络证据只描述本次启动内的真实行为，不持久化，也不是系统授权开关的直接查询。
@MainActor
enum LocalNetworkEvidence: Equatable {
    case checking, skipped, verifiedRobot, verifiedDiscovery, loopbackSimulator, denied, unverified

    init(commState: DSClient.CommState) {
        switch commState {
        case .idle, .searching: self = .unverified
        case .connected(let host): self = Self.isLoopbackHost(host) ? .loopbackSimulator : .verifiedRobot
        }
    }

    /// 回环主机（本机模拟器）不经本地网络权限；点分地址复用模型的 127/8 解析，命名回环主机按字面匹配。
    static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || DSModel.isLoopbackIPv4(host)
    }

    var hasSuccess: Bool {
        self == .verifiedRobot || self == .verifiedDiscovery
    }

    var tone: PermissionTone {
        switch self {
        case .verifiedRobot, .verifiedDiscovery: return .success
        case .denied: return .danger
        case .checking, .skipped, .loopbackSimulator, .unverified: return .warning
        }
    }

    var badge: String {
        switch self {
        case .checking: return tr("正在检测本地网络")
        case .skipped: return tr("本地网络检测已跳过")
        case .verifiedRobot: return tr("机器人通信正常")
        case .verifiedDiscovery: return tr("非回环 NI 服务发现已验证")
        case .loopbackSimulator: return tr("已连接本机模拟器")
        case .denied: return tr("本地网络访问被拒绝")
        case .unverified: return tr("尚未通过连接验证")
        }
    }

    var symbol: String {
        switch self {
        case .verifiedRobot, .verifiedDiscovery: return "checkmark.circle.fill"
        case .denied: return "exclamationmark.triangle.fill"
        case .checking, .skipped, .loopbackSimulator, .unverified: return "info.circle"
        }
    }

    func explanation(connectionDetail: String) -> String {
        switch self {
        case .checking:
            return tr("正在等待真实非回环机器人连接或本地服务发现证据。")
        case .skipped:
            return tr("AUTO_SIM 已跳过本地网络发现；本会话没有可验证的真实网络证据。")
        case .verifiedRobot:
            return tr("已与 %@ 建立通信，当前连接可用。", connectionDetail)
        case .verifiedDiscovery:
            return tr("已观察到非回环接口上的 NI 服务发现；这只证明当前发现路径可用，不代表机器人已可达。")
        case .loopbackSimulator:
            return tr("本机连接正常，但它不能验证真实机器人所需的本地网络权限。")
        case .denied:
            return tr("系统明确拒绝了本地网络访问。请在「隐私与安全性 → 本地网络」允许后重新检测。")
        case .unverified:
            return tr("目前没有机器人连接记录可用于确认网络访问。连接失败时，可先检查本地网络权限。")
        }
    }
}

/// 防火墙证据仅来自临时验证服务收到的有效非回环入站请求。
@MainActor
enum FirewallEvidence: Equatable {
    case notStarted, skipped, starting, waiting(URL), verified, unavailable, failed, timedOut

    var tone: PermissionTone { self == .verified ? .success : .neutral }

    var badge: String {
        switch self {
        case .notStarted: return tr("尚未启动入站验证")
        case .skipped: return tr("入站验证已跳过")
        case .starting: return tr("正在启动入站验证")
        case .waiting: return tr("正在等待入站验证")
        case .verified: return tr("入站 TCP 验证通过")
        case .unavailable: return tr("未获得可用局域网地址")
        case .failed: return tr("入站验证未完成")
        case .timedOut: return tr("尚未验证入站连接")
        }
    }

    var symbol: String { self == .verified ? "checkmark.circle.fill" : "info.circle" }

    var explanation: String {
        switch self {
        case .notStarted:
            return tr("应用启动后会自动检查入站连接。")
        case .skipped:
            return tr("AUTO_SIM 已跳过局域网入站验证；本会话不监听临时验证端口。")
        case .starting:
            return tr("正在准备临时入站验证端口。")
        case .waiting:
            return tr("让同一网络的另一台设备访问验证地址；收到有效非回环请求后才算成功。")
        case .verified:
            return tr("本次启动已收到有效非回环入站请求；这不等于读取了防火墙规则，也不代表所有端口或协议都可用。")
        case .unavailable:
            return tr("请连接 Wi-Fi 或有线网络后重新检测；这不表示防火墙拒绝。")
        case .failed:
            return tr("验证服务未能完成，请重新检测；这不表示防火墙拒绝。")
        case .timedOut:
            return tr("超时前没有收到有效非回环请求；这不表示防火墙拒绝。")
        }
    }
}

@MainActor
enum FirewallProbeState: Equatable {
    case starting, waiting(URL), verified(peer: String), unavailable, failed, timedOut
}

/// 本次启动的权限证据中心。所有成功只保存在内存中，下一次启动必须重新取得。
@Observable
@MainActor
final class PermissionRuntimeMonitor {
    private(set) var networkEvidence: LocalNetworkEvidence = .checking
    private(set) var firewallEvidence: FirewallEvidence = .notStarted
    private(set) var firewallURL: URL?

    /// 本机全部 IPv4 接口地址：连接到本机局域网地址的模拟器与回环一样，不能证明权限。
    @ObservationIgnored private var localIPv4Addresses: Set<String>
    /// 探针工厂：生产为真实 BSD 临时监听，测试注入假实现。
    @ObservationIgnored private var makeFirewallProbe: @MainActor () -> FirewallProbeControlling
    /// 本次启动的防火墙探针；停止后置空，旧探针迟到的回调按身份丢弃。
    @ObservationIgnored private var firewallProbe: FirewallProbeControlling?

    init(localIPv4Addresses: Set<String>? = nil,
         makeFirewallProbe: @escaping @MainActor () -> FirewallProbeControlling = { FirewallVerificationProbe() }) {
        self.localIPv4Addresses = localIPv4Addresses
            ?? Set(FirewallVerificationProbe.enumerateInterfaces().map(\.address))
        self.makeFirewallProbe = makeFirewallProbe
    }

    func beginNewLaunch(autoSim: Bool = false) {
        firewallProbe?.stop()
        firewallProbe = nil
        networkEvidence = autoSim ? .skipped : .checking
        firewallEvidence = autoSim ? .skipped : .notStarted
        firewallURL = nil
    }

    /// 启动防火墙入站验证：每次调用都取消旧探针并新建一个（重新检测拿到新端口）。
    /// AUTO_SIM 只标记跳过，不创建也不启动探针。
    func startFirewallVerification(autoSim: Bool = false) {
        firewallProbe?.stop()
        firewallProbe = nil
        guard !autoSim else {
            firewallURL = nil
            firewallEvidence = .skipped
            return
        }
        let probe = makeFirewallProbe()
        firewallProbe = probe
        probe.onState = { [weak self, weak probe] state in
            guard let self, let probe, self.firewallProbe === probe else { return }
            self.applyFirewallState(state)
        }
        firewallURL = nil
        applyFirewallState(.starting)
        probe.start()
    }

    func applyDiscovery(_ event: LocalNetworkDiscoveryEvent) {
        switch event {
        case .nonLoopbackService:
            networkEvidence = .verifiedDiscovery
        case .policyDenied:
            networkEvidence = .denied
        case .ready, .waiting, .services:
            break
        case .failed:
            if !networkEvidence.hasSuccess && networkEvidence != .denied {
                networkEvidence = .unverified
            }
        }
    }

    func record(commState: DSClient.CommState) {
        switch commState {
        case .connected(let host):
            if isLoopbackHost(host) {
                if !networkEvidence.hasSuccess && networkEvidence != .denied {
                    networkEvidence = .loopbackSimulator
                }
            } else if networkEvidence != .denied {
                networkEvidence = .verifiedRobot
            }
        case .idle, .searching:
            if networkEvidence == .verifiedRobot || networkEvidence == .loopbackSimulator || networkEvidence == .checking {
                networkEvidence = .unverified
            }
        }
    }

    func applyFirewallState(_ state: FirewallProbeState) {
        if firewallEvidence == .verified {
            guard case .verified = state else { return }
        }
        switch state {
        case .starting:
            firewallEvidence = .starting
        case .waiting(let url):
            firewallURL = url
            firewallEvidence = .waiting(url)
        case .verified:
            firewallURL = nil
            firewallEvidence = .verified
        case .unavailable:
            firewallURL = nil
            firewallEvidence = .unavailable
        case .failed:
            firewallURL = nil
            firewallEvidence = .failed
        case .timedOut:
            firewallURL = nil
            firewallEvidence = .timedOut
        }
    }

    /// 回环主机，或本机任一接口的地址（本机连接自己的局域网地址同样是模拟器）。
    private func isLoopbackHost(_ host: String) -> Bool {
        localIPv4Addresses.contains(host) || LocalNetworkEvidence.isLoopbackHost(host)
    }
}
