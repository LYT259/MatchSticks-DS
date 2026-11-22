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
                audioPanel
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
                                options: model.practiceSeasonYearChoices.map { DSSelectOption(value: $0, label: String($0)) })
                    .frame(width: 120)
            }
        }
    }

    private var dashboardPanel: some View {
        settingsGroup("Dashboard") {
            settingsRow(tr("Dashboard 应用")) {
                VStack(alignment: .trailing, spacing: 10) {
                    DSMultiSelectControl(title: tr("Dashboard 应用"),
                                         selection: $model.dashboardSelection,
                                         options: DashboardKind.allCases.map { DSSelectOption(value: $0, label: $0.rawValue) })
                        .frame(width: 460)
                    Button(tr("启动 Dashboard")) { model.launchSelectedDashboards() }
                        .buttonStyle(DSActionStyle())
                        .disabled(model.dashboardSelection.isEmpty)
                        .help(model.dashboardSelection.isEmpty
                              ? tr("至少选择一个 Dashboard 才能启动")
                              : tr("同时启动所有选中的 Dashboard"))
                }
            }
        }
    }

    private var audioPanel: some View {
        settingsGroup(tr("声音")) {
            settingsRow(tr("播放阶段提示音")) {
                Toggle(tr("播放阶段提示音"), isOn: $model.soundsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(DSTheme.accent)
            }
            settingsSeparator
            settingsRow(tr("播放使能/失能音效")) {
                Toggle(tr("播放使能/失能音效"), isOn: $model.enableDisableSoundsEnabled)
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
}

/// 多选版分段控件：视觉与 DSSegmentedControl 一致，但每个选项独立开关（可全部关闭）。
private struct DSMultiSelectControl<Value: Hashable>: View {
    let title: String
    @Binding var selection: Set<Value>
    let options: [DSSelectOption<Value>]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = selection.contains(option.value)
                Button {
                    toggle(option.value)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 11, weight: .semibold))
                        Text(option.label)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .foregroundStyle(isSelected ? DSTheme.textPrimary : DSTheme.textSecondary)
                    .background(isSelected ? DSTheme.segmentSelected : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    .shadow(color: isSelected ? .black.opacity(0.12) : .clear, radius: 1, y: 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(DSMultiSelectButtonStyle(isSelected: isSelected))
                .accessibilityLabel("\(title)，\(option.label)")
                .accessibilityValue(isSelected ? tr("已选择") : tr("未选择"))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(DSTheme.segmentTrack, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DSTheme.line))
        .frame(minHeight: 32)
    }

    private func toggle(_ value: Value) {
        if selection.contains(value) {
            selection.remove(value)
        } else {
            selection.insert(value)
        }
    }
}

private struct DSMultiSelectButtonStyle: ButtonStyle {
    let isSelected: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(!isSelected && (hovering || configuration.isPressed) ? DSTheme.hover.opacity(0.65) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .onHover { hovering = $0 }
    }
}
