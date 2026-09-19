import SwiftUI
import CoreGraphics

// MARK: - 权限引导（报告 §5.2 / §8.4：首次运行引导 + 权限状态自检页）

struct PermissionsView: View {
    @State private var inputMonitoringOK = false

    var body: some View {
        Form {
            Section("Input Monitoring（全局快捷键 · Phase 4）") {
                HStack {
                    statusBadge(ok: inputMonitoringOK)
                    Text(inputMonitoringOK
                         ? "已授权（本版本尚无后台按键功能，授权暂不被使用）"
                         : "未授权——当前版本不需要它：快捷键只在应用前台生效（属预期）")
                        .font(.callout)
                    Spacer()
                    Button("重新检测") { checkInputMonitoring(prompt: false) }
                    if !inputMonitoringOK {
                        Button("请求授权") { checkInputMonitoring(prompt: true) }
                    }
                }
                guide("现状：Space/Enter/[ + ] + \\/Esc+I/F1/Backspace 由应用内键盘监听实现，切到后台即不再生效。"
                    + "后台全局 E-Stop 需 CGEventTap（Phase 4 实现），届时才需要「输入监控」权限；"
                    + "macOS 12+ 路径：系统设置 → 隐私与安全性 → 输入监控 → 勾选 GH Driver Station，授权后需重启应用。")
            }

            Section("本地网络（连接机器人）") {
                HStack {
                    statusBadge(ok: model.commConnected)
                    Text(model.commConnected ? "已连接机器人（权限正常）" : "机器人连不上时，第一嫌疑 = 本地网络授权")
                        .font(.callout)
                    Spacer()
                }
                guide("系统设置 → 隐私与安全性 → 本地网络 → 允许 GH Driver Station。首次 UDP/TCP 访问机器人网段时系统弹窗，点「允许」即完成。终端 / SSH 启动豁免此权限。")
            }

            Section("Firewall") {
                guide("防火墙默认关闭且签名应用自动放行；若手动开启防火墙后入站异常，在「防火墙选项」中放行本应用。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("权限")
        .onAppear { checkInputMonitoring(prompt: false) }
    }

    let model: DSModel

    private func statusBadge(ok: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(ok ? "正常" : "待授权").font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(ok ? AnyShapeStyle(.green.opacity(0.15)) : AnyShapeStyle(.orange.opacity(0.15)), in: Capsule())
    }

    private func guide(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func checkInputMonitoring(prompt: Bool) {
        inputMonitoringOK = prompt ? CGRequestListenEventAccess() : CGPreflightListenEventAccess()
    }
}
