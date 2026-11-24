import SwiftUI
import AppKit
import CoreGraphics
import DSCore

/// 权限面板徽章的色调，两项权限共用同一套含义：`.success` 只用于本次启动的真实非回环证据；
/// `.danger` 只用于系统明确拒绝；`.warning` 表示尚未取得证据；`.neutral` 表示本次会话已跳过检测。
enum PermissionTone: Equatable {
    case success, warning, neutral, danger

    var color: Color {
        switch self {
        case .success: return DSTheme.success
        case .warning: return DSTheme.warning
        case .neutral: return DSTheme.textSecondary
        case .danger: return DSTheme.danger
        }
    }
}

// Connection evidence is not the same as a direct permission query.
struct PermissionsView: View {
    let model: DSModel
    @State private var inputMonitoringOK = false
    @State private var settingsMessage = ""

    private var networkEvidence: LocalNetworkEvidence { model.permissionMonitor.networkEvidence }
    private var firewallEvidence: FirewallEvidence { model.permissionMonitor.firewallEvidence }

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
                instruction(2, tr("找到 MatchSticks Driver Station 并开启访问权限。"))
                instruction(3, tr("回到应用，确认 Mac 与机器人位于同一网络，并核对连接设置。"))
            }
            HStack {
                Text(tr("macOS 15 及更新系统提供本地网络权限设置。"))
                    .font(.caption).foregroundStyle(DSTheme.textSecondary)
                Spacer()
                Button(tr("重新检测")) { model.restartPermissionVerification() }
                    .buttonStyle(DSActionStyle())
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
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "shield")
                    .font(.system(size: 25, weight: .light)).foregroundStyle(DSTheme.textSecondary)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 8) {
                    DSBadge(text: firewallEvidence.badge,
                            color: firewallEvidence.tone.color,
                            symbol: firewallEvidence.symbol)
                    Text(firewallEvidence.explanation)
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    if case .waiting(let url) = firewallEvidence {
                        Text(tr("在同一网络的另一台设备打开："))
                            .font(.caption).foregroundStyle(DSTheme.textSecondary)
                        Text(url.absoluteString)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(tr("验证成功后监听会自动关闭；重新启动应用会重新检测。"))
                            .font(.caption).foregroundStyle(DSTheme.textSecondary)
                    } else if firewallEvidence == .timedOut || firewallEvidence == .failed || firewallEvidence == .unavailable {
                        Text(tr("可点击重新检测再试。"))
                            .font(.caption).foregroundStyle(DSTheme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Divider()
            Text(tr("在「系统设置 → 网络 → 防火墙 → 选项」中，检查 MatchSticks Driver Station 是否允许接收传入连接。保留其他应用的防火墙设置即可。"))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(tr("只验证当前地址和端口的 TCP 入站路径。"))
                    .font(.caption).foregroundStyle(DSTheme.textSecondary)
                Spacer()
                Button(tr("重新检测")) { model.restartPermissionVerification() }
                    .buttonStyle(DSActionStyle())
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
