import SwiftUI
import DSCore

// Preferences are not part of the connection draft: every control binds to DSModel and applies immediately.
struct SettingsView: View {
    @Bindable var model: DSModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                generalPanel
                dashboardPanel
                practicePanel
                matchPanel
                loggingPanel
            }
            .padding(24)
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
            .font(.system(size: 13))
        }
        .background(DSTheme.canvas)
    }

    private var generalPanel: some View {
        settingsGroup(tr("通用")) {
            settingsRow(tr("界面语言"), description: tr("默认跟随系统语言；手动选择立即生效。")) {
                DSSelectControl(title: tr("界面语言"), selection: $model.languageMode, options: [
                    DSSelectOption(value: LanguageMode.system, label: tr("跟随系统")),
                    DSSelectOption(value: LanguageMode.english, label: "English"),
                    DSSelectOption(value: LanguageMode.chinese, label: "简体中文"),
                ])
                .frame(width: 240)
            }
        }
    }

    private var dashboardPanel: some View {
        settingsGroup("Dashboard") {
            settingsRow(tr("应用"), description: tr("打开已安装在 Mac 上的 Dashboard 应用。")) {
                HStack(spacing: 8) {
                    DSSelectControl(title: tr("Dashboard 应用"), selection: $model.dashboardKind,
                                    options: DashboardKind.allCases.map { DSSelectOption(value: $0, label: $0.rawValue) })
                        .frame(width: 180)
                    Button(tr("启动 Dashboard")) { launchDashboard() }
                        .buttonStyle(DSActionStyle())
                }
            }
        }
    }

    private var practicePanel: some View {
        settingsGroup(tr("练习时序")) {
            durationRow(tr("自动阶段"), $model.practiceAutoTime, range: 1...60)
            settingsSeparator
            durationRow(tr("遥控阶段"), $model.practiceTeleopTime, range: 15...600)
            settingsSeparator
            durationRow(tr("阶段间等待"), $model.practiceDelayTime, range: 0...30)
            settingsSeparator
            settingsRow(tr("播放阶段提示音"), description: tr("在「驾驶」页面开始练习；时长设置用于下一次练习。")) {
                Toggle(tr("播放阶段提示音"), isOn: $model.soundsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(DSTheme.accent)
            }
        }
    }

    private var matchPanel: some View {
        settingsGroup(tr("比赛信息")) {
            settingsRow(tr("赛事名称"), description: tr("可选")) {
                TextField(tr("可选"), text: $model.competition)
                    .textFieldStyle(DSTextFieldStyle())
                    .accessibilityLabel(tr("赛事名称"))
                    .frame(width: 240)
            }
            settingsSeparator
            settingsRow(tr("场次类型")) {
                DSSelectControl(title: tr("场次类型"), selection: $model.matchType, options: [
                    DSSelectOption(value: UInt8(0), label: tr("未指定")),
                    DSSelectOption(value: UInt8(1), label: tr("练习")),
                    DSSelectOption(value: UInt8(2), label: tr("资格赛")),
                    DSSelectOption(value: UInt8(3), label: tr("淘汰赛")),
                ])
                .frame(width: 240)
            }
            settingsSeparator
            settingsRow("Game Data", description: tr("可选的游戏数据")) {
                TextField(tr("可选的游戏数据"), text: $model.gameData)
                    .textFieldStyle(DSTextFieldStyle())
                    .accessibilityLabel("Game Data")
                    .frame(width: 240)
            }
        }
    }

    private var loggingPanel: some View {
        settingsGroup(tr("日志与录制")) {
            settingsRow(tr("记录会话日志"), description: tr("保存电池、丢包、CPU、CAN 与运行状态，生成 .dslog 和 .wpilog，可在 AdvantageScope 中查看。")) {
                Toggle(tr("记录会话日志"), isOn: $model.dslogEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(DSTheme.accent)
            }
            settingsSeparator
            settingsRow(tr("录制通信数据包"), description: tr("生成 .dsrec 文件，供连接排查与协议回归使用；也支持模拟器会话。")) {
                Toggle(tr("录制通信数据包"), isOn: $model.recording)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(DSTheme.accent)
            }
            Text(tr("文件保存于用户资源库的 Application Support / GHDriverStation：Logs 为会话日志，captures 为通信录制。"))
                .font(.system(size: 12))
                .foregroundStyle(DSTheme.textSecondary)
                .textSelection(.enabled)
                .padding(16)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DSTheme.textPrimary)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(DSTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DSTheme.line))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func settingsRow<Control: View>(_ title: String, description: String? = nil,
                                            @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let description {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(DSTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(minHeight: 60)
    }

    private var settingsSeparator: some View {
        Rectangle()
            .fill(DSTheme.line)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.leading, 16)
    }

    private func durationRow(_ label: String, _ value: Binding<TimeInterval>, range: ClosedRange<Double>) -> some View {
        settingsRow(label) {
            HStack(spacing: 12) {
                Slider(value: value, in: range, step: 1)
                    .accessibilityLabel(label)
                    .tint(DSTheme.accent)
                    .frame(width: 168)
                Text(tr("%d 秒", Int(value.wrappedValue)))
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: 60, alignment: .trailing)
            }
            .frame(width: 240)
        }
    }

    private func launchDashboard() {
        let appName: String
        switch model.dashboardKind {
        case .advantageScope: appName = "AdvantageScope"
        case .shuffleboard: appName = "shuffleboard"
        case .elastic: appName = "Elastic"
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", appName]
        do {
            try p.run()
            model.log(tr("尝试启动 Dashboard：%@", appName))
        } catch {
            model.log(tr("启动 Dashboard 失败：%@（%@）——请确认已安装该应用", appName, error.localizedDescription))
        }
    }
}
