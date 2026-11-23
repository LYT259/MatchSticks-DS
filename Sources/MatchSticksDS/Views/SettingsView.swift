import SwiftUI
import DSCore

// Preferences are not part of the connection draft: every control binds to DSModel and applies immediately.
struct SettingsView: View {
    @Bindable var model: DSModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                generalPanel
                iconPanel
                updatePanel
                dashboardPanel
                audioPanel
                matchPanel
                loggingPanel
            }
            .padding(24)
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
            settingsRow(tr("外观")) {
                DSSegmentedControl(title: tr("外观"), selection: $model.appearanceMode, options: [
                    DSSelectOption(value: AppearanceMode.system, label: tr("跟随系统")),
                    DSSelectOption(value: AppearanceMode.light, label: tr("浅色")),
                    DSSelectOption(value: AppearanceMode.dark, label: tr("深色")),
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
                HStack(spacing: 10) {
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

    // 应用图标（独立面板）：样式 × 外观两维互不重置，均直接绑定 model 即时生效并落独立键。
    private var iconPanel: some View {
        settingsGroup(tr("应用图标")) {
            settingsRow(tr("图标样式")) {
                HStack(spacing: 12) {
                    DSSegmentedControl(title: tr("图标样式"), selection: $model.iconStyle, options: [
                        DSSelectOption(value: IconStyle.color, label: tr("彩色")),
                        DSSelectOption(value: IconStyle.monochrome, label: tr("单色")),
                    ])
                    .frame(width: 300)
                    AppIconArtworkPreview(style: model.iconStyle, appearance: .system)
                }
            }
            settingsSeparator
            settingsRow(tr("图标外观")) {
                HStack(spacing: 12) {
                    DSSegmentedControl(title: tr("图标外观"), selection: $model.iconAppearance, options: [
                        DSSelectOption(value: AppearanceMode.system, label: tr("跟随系统")),
                        DSSelectOption(value: AppearanceMode.light, label: tr("浅色")),
                        DSSelectOption(value: AppearanceMode.dark, label: tr("深色")),
                    ])
                    .frame(width: 300)
                    AppIconArtworkPreview(style: model.iconStyle, appearance: model.iconAppearance)
                }
            }
            settingsSeparator
            Text(tr("运行中的 Dock 图标立即使用所选图稿；Finder 与启动台图标由应用包提供、始终随系统深浅显示，固定浅色/深色只影响运行中的 Dock。"))
                .font(.system(size: 11))
                .foregroundStyle(DSTheme.textSecondary)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // 软件更新：stable / beta 渠道（Sparkle 原生渠道过滤，每次加载 appcast 时重读 allowedChannels）。
    // 切换即时生效并持久化；UpdateCenter 在 GitHub 可达时立即重新检查（不可达则退避重试，见 ADR-0004）。
    private var updatePanel: some View {
        settingsGroup(tr("软件更新")) {
            settingsRow(tr("更新渠道")) {
                DSSegmentedControl(title: tr("更新渠道"), selection: $model.updateChannel, options: [
                    DSSelectOption(value: UpdateChannel.stable, label: tr("稳定版")),
                    DSSelectOption(value: UpdateChannel.beta, label: tr("测试版")),
                ])
                .frame(width: 360)
            }
            settingsSeparator
            Text(tr("测试版会同时接收稳定版与测试版更新；切换渠道后在 GitHub 可达时立即重新检查。"))
                .font(.system(size: 11))
                .foregroundStyle(DSTheme.textSecondary)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
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

/// 图标设置的图稿预览：跟随系统显示浅深一对（样式行恒为一对，直观对比两种深浅）；
/// 固定浅色/深色只显示对应单张。图稿一律经白名单加载，无任意路径入口。
private struct AppIconArtworkPreview: View {
    let style: IconStyle
    let appearance: AppearanceMode

    var body: some View {
        HStack(spacing: 6) {
            switch appearance {
            case .system:
                thumbnail(dark: false)
                thumbnail(dark: true)
            case .light:
                thumbnail(dark: false)
            case .dark:
                thumbnail(dark: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(appearance == .system
                            ? tr("图标预览：浅色与深色图稿")
                            : (appearance == .dark ? tr("深色图稿预览") : tr("浅色图稿预览")))
    }

    private func thumbnail(dark: Bool) -> some View {
        Group {
            if let image = AppIconArtwork.image(style: style, dark: dark) {
                Image(nsImage: image).resizable()
            } else {
                // 图稿资源缺失（如 UI 干测试不打包资源）时的占位，保持行高稳定
                Rectangle().fill(DSTheme.card)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DSTheme.line))
        .help(dark ? tr("深色") : tr("浅色"))
    }
}
