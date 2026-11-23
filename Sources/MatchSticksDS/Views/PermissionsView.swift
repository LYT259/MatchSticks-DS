import SwiftUI
import AppKit
import CoreGraphics
import DSCore

/// 权限面板徽章的色调。`.success` 只用于有正面证据表明权限可用的情形；`.warning` 表示没有证据
/// （并不代表被拒绝）；`.neutral` 用于应用根本不读取该配置的面板。
enum PermissionTone: Equatable {
    case success, warning, neutral

    var color: Color {
        switch self {
        case .success: return DSTheme.success
        case .warning: return DSTheme.warning
        case .neutral: return DSTheme.textSecondary
        }
    }
}

/// 本地网络面板的证据。连接记录不是权限查询：只有真实的非回环机器人连接才能证明本地网络访问可用。
@MainActor
enum LocalNetworkEvidence: Equatable {
    case verifiedRobot
    case loopbackSimulator
    case unverified

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

    var tone: PermissionTone {
        switch self {
        case .verifiedRobot: return .success
        case .loopbackSimulator, .unverified: return .warning
        }
    }

    var badge: String {
        switch self {
        case .verifiedRobot: return tr("机器人通信正常")
        case .loopbackSimulator: return tr("已连接本机模拟器")
        case .unverified: return tr("尚未通过连接验证")
        }
    }

    var symbol: String { self == .verifiedRobot ? "checkmark.circle.fill" : "info.circle" }

    func explanation(connectionDetail: String) -> String {
        switch self {
        case .verifiedRobot: return tr("已与 %@ 建立通信，当前连接可用。", connectionDetail)
        case .loopbackSimulator: return tr("本机连接正常，但它不能验证真实机器人所需的本地网络权限。")
        case .unverified: return tr("目前没有机器人连接记录可用于确认网络访问。连接失败时，可先检查本地网络权限。")
        }
    }
}

// Connection evidence is not the same as a direct permission query.
struct PermissionsView: View {
    let model: DSModel
    @State private var inputMonitoringOK = false
    @State private var settingsMessage = ""

    private var networkEvidence: LocalNetworkEvidence { LocalNetworkEvidence(commState: model.commState) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                networkPanel
                inputPanel
                firewallPanel
                if !settingsMessage.isEmpty {
                    Label(settingsMessage, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(DSTheme.textSecondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(DSTheme.canvas)
        .onAppear { inputMonitoringOK = CGPreflightListenEventAccess() }
    }

    private var networkPanel: some View {
        DSPanel(title: tr("本地网络")) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "network")
                    .font(.system(size: 25, weight: .light)).foregroundStyle(DSTheme.textSecondary)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 8) {
                    DSBadge(text: networkEvidence.badge, color: networkEvidence.tone.color, symbol: networkEvidence.symbol)
                    Text(networkEvidence.explanation(connectionDetail: model.connectionDetail))
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text(tr("应用无法直接读取本地网络授权状态；未连接也可能由网络、地址或机器人状态引起。"))
                        .font(.caption).foregroundStyle(DSTheme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                instruction(1, tr("打开「系统设置」，进入「隐私与安全性 → 本地网络」。"))
                instruction(2, tr("找到 MatchSticks DS 并开启访问权限。"))
                instruction(3, tr("回到应用，确认 Mac 与机器人位于同一网络，并核对连接设置。"))
            }
            HStack {
                Text(tr("macOS 15 及更新系统提供本地网络权限设置。"))
                    .font(.caption).foregroundStyle(DSTheme.textSecondary)
                Spacer()
                // 深链不保证直达本地网络子页面：按钮只承诺打开「隐私与安全性」，提示也只说“已请求”
                Button(tr("打开隐私与安全性")) {
                    openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
                }
                .buttonStyle(DSActionStyle())
            }
        }
    }

    private var inputPanel: some View {
        DSPanel(title: tr("键盘快捷键")) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "keyboard")
                    .font(.system(size: 25, weight: .light)).foregroundStyle(DSTheme.textSecondary)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 8) {
                    // 前台本地事件监听不需要 Input Monitoring
                    DSBadge(text: tr("无需额外授权"), color: DSTheme.success, symbol: "checkmark.circle")
                    Text(tr("当前尚未提供后台全局快捷键。切换到其他应用后，请勿依赖键盘快捷键操作机器人。"))
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text(inputMonitoringOK
                         ? tr("系统的「输入监控」已授权，当前版本暂不使用此权限。")
                         : tr("「输入监控」未授权不影响当前功能，无需为此开启权限。"))
                        .font(.caption).foregroundStyle(DSTheme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text(tr("输入监控仅用于将来的后台按键功能。"))
                    .font(.caption).foregroundStyle(DSTheme.textSecondary)
                Spacer()
                Button(tr("重新检测")) { inputMonitoringOK = CGPreflightListenEventAccess() }
                    .buttonStyle(DSActionStyle())
            }
        }
    }

    private var firewallPanel: some View {
        DSPanel(title: tr("防火墙")) {
            Text(tr("在「系统设置 → 网络 → 防火墙 → 选项」中，检查 MatchSticks DS 是否允许接收传入连接。保留其他应用的防火墙设置即可。"))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                // 未读取系统防火墙配置：中性灰，不暗示已授权或被拒绝
                DSBadge(text: tr("未检测系统防火墙配置"), color: PermissionTone.neutral.color, symbol: "info.circle")
                Spacer()
                Button(tr("打开防火墙设置")) {
                    openSettings("x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall")
                }
                .buttonStyle(DSActionStyle())
            }
        }
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(number))
                .font(.caption.weight(.semibold)).foregroundStyle(DSTheme.textSecondary)
                .frame(width: 20, height: 20)
                .background(DSTheme.canvas, in: Circle())
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openSettings(_ address: String) {
        guard let url = URL(string: address), NSWorkspace.shared.open(url) else {
            settingsMessage = tr("无法直接打开对应页面，请从「系统设置」按上方路径进入。")
            return
        }
        settingsMessage = tr("已请求打开系统设置；若未跳转到对应页面，请按上方路径进入。")
    }
}
