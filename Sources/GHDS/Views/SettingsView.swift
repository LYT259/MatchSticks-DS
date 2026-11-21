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
            settingsRow(tr("界面语言")) {
                DSSegmentedControl(title: tr("界面语言"), selection: $model.languageMode, options: [
                    DSSelectOption(value: LanguageMode.system, label: tr("跟随系统")),
                    DSSelectOption(value: LanguageMode.english, label: "English"),
                    DSSelectOption(value: LanguageMode.chinese, label: "简体中文"),
                ])
                .frame(width: 360)
            }
            settingsSeparator
            settingsRow(tr("比赛年份")) {
                DSSelectControl(title: tr("比赛年份"), selection: $model.practiceSeasonYear,
                                options: PracticeTimingPreset.all.map { DSSelectOption(value: $0.year, label: String($0.year)) })
                    .frame(width: 120)
            }
        }
    }

    private var dashboardPanel: some View {
        settingsGroup("Dashboard") {
            settingsRow(tr("应用")) {
                HStack(spacing: 8) {
                    DSSelectControl(title: tr("应用"), selection: $model.dashboardKind,
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
            settingsRow(tr("官方时序")) {
                Button(tr("应用官方时序")) { model.applyPracticeTimingPreset() }
                    .buttonStyle(DSActionStyle())
            }
            settingsSeparator
            PracticeTimingEditor(model: model)
            settingsSeparator
            settingsRow(tr("播放阶段提示音")) {
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
            settingsRow(tr("赛事名称")) {
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
            settingsRow("Game Data") {
                TextField(tr("可选的游戏数据"), text: $model.gameData)
                    .textFieldStyle(DSTextFieldStyle())
                    .accessibilityLabel("Game Data")
                    .frame(width: 240)
            }
        }
    }

    private var loggingPanel: some View {
        settingsGroup(tr("日志与录制")) {
            settingsRow(tr("记录会话日志")) {
                Toggle(tr("记录会话日志"), isOn: $model.dslogEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(DSTheme.accent)
            }
            settingsSeparator
            settingsRow(tr("录制通信数据包")) {
                Toggle(tr("录制通信数据包"), isOn: $model.recording)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(DSTheme.accent)
            }
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

    private func settingsRow<Control: View>(_ title: String,
                                            @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
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
