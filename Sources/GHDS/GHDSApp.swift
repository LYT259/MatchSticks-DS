import SwiftUI
import DSCore

@main
struct GHDSApp: App {
    @State private var model = DSModel()
    @State private var shortcuts = ShortcutManager()
    @State private var updates = UpdateCenter()

    init() {
        if !Bundle.main.bundlePath.hasSuffix(".app") {
            NSApplication.shared.setActivationPolicy(.regular)
        }
    }

    var body: some Scene {
        Window("GH Driver Station", id: "main") {
            RootView(model: model, updates: updates)
                .frame(minWidth: 1040, minHeight: 740)
                .task {
                    shortcuts.install(model: model)
                    model.start()
                    updates.attach(model: model)
                    updates.start()
                }
        }
        .defaultSize(width: 1180, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Window("Mini Driver Station", id: "mini") {
            MiniView(model: model)
                .frame(minWidth: 400, minHeight: 220)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

/// 连接草稿（RootView 常驻，跨页面导航保留）：应用前的一切编辑都留在这里，
/// 避免「切到别的页再回来，草稿被清空」。userEdited 标记未动过的草稿，
/// 进页时自动跟随模型（GHDS_AUTO_SIM / 启动模拟器会改写连接目标）。
struct RootView: View {
    let model: DSModel
    let updates: UpdateCenter
    @State private var selection: Page = .operation
    @State private var simProcess: Process?
    @State private var connectionDraft = ConnectionDraft()
    @Environment(\.openWindow) private var openWindow
    // 语言切换由观察驱动 body 重算，不重建整树，保留页面与控件状态。
    @ObservedObject private var language = LanguageManager.shared

    enum Page: String, CaseIterable, Hashable {
        case operation, setup, usb, diagnostics, charts, messages, permissions, settings
        var title: String {
            switch self {
            case .operation: return tr("驾驶")
            case .setup: return tr("连接")
            case .usb: return tr("手柄")
            case .diagnostics: return tr("诊断")
            case .charts: return tr("数据图表")
            case .messages: return tr("控制台")
            case .permissions: return tr("权限与帮助")
            case .settings: return tr("设置")
            }
        }
        var subtitle: String {
            switch self {
            case .operation: return tr("确认连接与模式，然后开始操作。")
            case .setup: return tr("配置机器人连接目标，或启动本机模拟器。")
            case .usb: return tr("检查输入，安排机器人接收的手柄顺序。")
            case .diagnostics: return tr("检查链路、机器人资源和故障信息。")
            case .charts: return tr("观察电池、处理器和通信质量的变化。")
            case .messages: return tr("查看机器人输出、错误与驾驶台事件。")
            case .permissions: return tr("排查连接问题，了解当前快捷键的使用范围。")
            case .settings: return tr("这些选项会即时保存或生效。")
            }
        }
        var symbol: String {
            switch self {
            case .operation: return "steeringwheel"
            case .setup: return "network"
            case .usb: return "gamecontroller"
            case .diagnostics: return "stethoscope"
            case .charts: return "chart.xyaxis.line"
            case .messages: return "terminal"
            case .permissions: return "questionmark.circle"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(selection.title).font(.system(size: 22, weight: .semibold))
                        Text(selection.subtitle).font(.system(size: 12)).foregroundStyle(DSTheme.textSecondary)
                    }
                    Spacer()
                    Button { openWindow(id: "mini") } label: {
                        Label(tr("迷你驾驶台"), systemImage: "pip")
                    }
                    .buttonStyle(DSActionStyle())
                    UpdateBadge(flow: updates.flow) { updates.requestRestartAndRelaunch() }
                }
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
                DSStatusBar(model: model)
                    .padding(.horizontal, 24).padding(.bottom, 16)
                Divider()
                pageContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                SafetyControlBar(model: model)
            }
            .background(DSTheme.canvas)
        }
        .background(DSTheme.canvas)
        .tint(DSTheme.accent)
        .foregroundStyle(DSTheme.textPrimary)
        .font(.system(size: 13))
        .buttonStyle(DSActionStyle())
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("GH").font(.system(size: 29, weight: .bold, design: .rounded))
                Text("Driver Station").font(.system(size: 14, weight: .semibold))
                Text(tr("机器人驾驶台")).font(.caption).foregroundStyle(DSTheme.textSecondary)
            }
            .padding(.horizontal, 22).padding(.top, 46).padding(.bottom, 32)
            navGroup(tr("操作"), pages: [.operation, .setup, .usb])
            navGroup(tr("监测"), pages: [.diagnostics, .charts, .messages])
                .padding(.top, 22)
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 5) {
                navRow(.settings)
                navRow(.permissions)
            }
            Divider().padding(.vertical, 16).padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.teamNumber > 0 ? "TEAM \(model.teamNumber)" : tr("尚未设置队伍"))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                Text(tr("仅供练习与调试")).font(.caption).foregroundStyle(DSTheme.textSecondary)
            }
            .padding(.horizontal, 12).padding(.bottom, 22)
        }
        .padding(.horizontal, 10)
        .frame(width: 196)
        .background(DSTheme.sidebar)
    }

    private func navGroup(_ title: String, pages: [Page]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(DSTheme.textSecondary)
                .padding(.leading, 12).padding(.bottom, 5)
            ForEach(pages, id: \.self) { navRow($0) }
        }
    }

    private func navRow(_ page: Page) -> some View {
        Button { selection = page } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol).font(.system(size: 14)).frame(width: 20)
                Text(page.title).font(.system(size: 12, weight: selection == page ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(selection == page ? DSTheme.accentText : DSTheme.textPrimary)
            .background(selection == page ? DSTheme.accentDim : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == page ? .isSelected : [])
    }

    @ViewBuilder private var pageContent: some View {
        switch selection {
        case .operation: OperationView(model: model, openConnection: { selection = .setup }, openSettings: { selection = .settings }, openControllers: { selection = .usb })
        case .setup: SetupView(model: model, simProcess: $simProcess, draft: connectionDraft)
        case .settings: SettingsView(model: model)
        case .usb: USBDevicesView(model: model)
        case .diagnostics: DiagnosticsView(model: model)
        case .charts: ChartsView(model: model)
        case .messages: MessagesView(model: model)
        case .permissions: PermissionsView(model: model)
        }
    }
}

// Available from every page; all actions call the existing safety-gated model.
struct SafetyControlBar: View {
    let model: DSModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.enabled ? tr("运行时间") : tr("驾驶控制")).font(.caption).foregroundStyle(DSTheme.textSecondary)
                    Text(model.enabled ? String(format: "%02d:%04.1f", Int(model.enabledElapsed) / 60, model.enabledElapsed.truncatingRemainder(dividingBy: 60)) : model.uiStatus)
                        .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(model.uiStatusColor)
                }
                .frame(minWidth: 110, alignment: .leading)
                Spacer(minLength: 8)
                Button { model.setEnabled(true) } label: {
                    controlLabel(tr("使能"), hint: "[ + ] + \\", symbol: "play.fill")
                }
                .buttonStyle(DSActionStyle(color: DSTheme.success, prominent: true))
                .disabled(!model.canEnable || model.remoteEstopReported)
                .help(model.remoteEstopReported ? tr("机器人仍报告急停，使能不可用；等待复位生效或到诊断页重启机器人程序。") : tr("使能机器人（需已连接且无急停）"))
                // Intentionally no keyboardShortcut: only ShortcutManager's three-key chord enables.
                Button { model.setEnabled(false) } label: {
                    controlLabel(tr("失能"), hint: "Return", symbol: "stop.fill")
                }
                .buttonStyle(DSActionStyle())
                Divider().frame(height: 36).padding(.horizontal, 3)
                Button { model.triggerEstop() } label: {
                    controlLabel(model.estopEngaged ? tr("急停已锁定") : tr("急停"), hint: "Space", symbol: "exclamationmark.octagon.fill")
                }
                .buttonStyle(DSActionStyle(color: DSTheme.danger, prominent: true))
                .disabled(model.estopEngaged)
            }
            HStack(alignment: .center, spacing: 10) {
                Text(model.enableExplanation).font(.system(size: 12)).foregroundStyle(DSTheme.textSecondary)
                if model.estopEngaged {
                    Button(tr("复位急停")) { model.resetEstop() }
                        .help(tr("请求重启机器人程序以解除急停锁存。快捷键：Esc + I。"))
                }
                Spacer(minLength: 0)
                if !model.estopEngaged {
                    Text(tr("快捷键仅在前台、非文本输入时生效"))
                        .font(.system(size: 10)).foregroundStyle(DSTheme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(DSTheme.sidebar)
    }

    private func controlLabel(_ title: String, hint: String, symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(hint).font(.system(size: 10, weight: .medium, design: .monospaced))
            }
        }
        .frame(minWidth: 92, minHeight: 34, alignment: .leading)
    }
}
