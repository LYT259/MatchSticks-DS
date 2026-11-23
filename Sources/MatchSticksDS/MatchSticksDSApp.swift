import SwiftUI
import DSCore

@main
struct MatchSticksDSApp: App {
    @State private var model = DSModel()
    @State private var shortcuts = ShortcutManager()
    @State private var updates = UpdateCenter()
    @State private var windowFlow = DriverStationWindowFlow()

    init() {
        if !Bundle.main.bundlePath.hasSuffix(".app") {
            NSApplication.shared.setActivationPolicy(.regular)
        }
    }

    var body: some Scene {
        Window("MatchSticks DS", id: "main") {
            RootView(model: model, updates: updates, windowFlow: windowFlow)
                .frame(minWidth: 1040, minHeight: 740)
                .task {
                    shortcuts.install(model: model)
                    model.start()
                    updates.attach(model: model)
                    updates.start()
                }
                .background(WindowIdentity(identifier: DriverStationWindowPresenter.mainWindowIdentifier))
        }
        .defaultSize(width: 1180, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // 标准标题栏：原生 standardWindowButton（红绿灯/缩放）位置与行为，
        // 内容不自绘标题栏背景；宽横向驾驶台见 MiniConsoleBar。
        Window("Mini Driver Station", id: "mini") {
            MiniView(model: model, flow: windowFlow)
                .frame(minWidth: 768, minHeight: 128)
                .background(WindowIdentity(identifier: DriverStationWindowPresenter.miniWindowIdentifier))
                .background(MiniWindowCloseObserver { windowFlow.send(.miniWindowClosed) })
        }
        .defaultSize(width: 768, height: 168)
        .windowResizability(.contentMinSize)
    }
}

/// 连接草稿（RootView 常驻，跨页面导航保留）：应用前的一切编辑都留在这里，
/// 避免「切到别的页再回来，草稿被清空」。userEdited 标记未动过的草稿，
/// 进页时自动跟随模型（MATCHSTICKS_DS_AUTO_SIM / 启动模拟器会改写连接目标）。
struct RootView: View {
    let model: DSModel
    let updates: UpdateCenter
    let windowFlow: DriverStationWindowFlow
    @State private var selection: Page = .operation
    @State private var simProcess: Process?
    @State private var connectionDraft = ConnectionDraft()
    @Environment(\.openWindow) private var openWindow
    // 语言切换由观察驱动 body 重算，不重建整树，保留页面与控件状态。
    @ObservedObject private var language = LanguageManager.shared

    enum Page: String, CaseIterable, Hashable {
        case operation, setup, usb, mac, robot, camera, messages, permissions, settings
        var title: String {
            switch self {
            case .operation: return tr("驾驶")
            case .setup: return tr("连接")
            case .usb: return tr("手柄")
            case .mac: return tr("Mac")
            case .robot: return tr("机器人")
            case .camera: return tr("摄像头")
            case .messages: return tr("控制台")
            case .permissions: return tr("权限与帮助")
            case .settings: return tr("设置")
            }
        }
        var symbol: String {
            switch self {
            case .operation: return "steeringwheel"
            case .setup: return "network"
            case .usb: return "gamecontroller"
            case .mac: return "desktopcomputer"
            case .robot: return "stethoscope"
            case .camera: return "video"
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
                .ignoresSafeArea(.container, edges: .vertical)
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    Text(selection.title).font(.system(size: 22, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
                DSStatusBar(model: model,
                            openConnection: { selection = .setup },
                            openJoysticks: { selection = .usb })
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
        .background(alignment: .topLeading) {
            MainWindowDoubleClickHandler()
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
        .toolbar {
            // trailing 工具区（macOS 主流 App 右上角位置），不压侧栏与内容间竖线；
            // 入口点击经窗口流：打开 Mini 并隐藏主窗（Mini 关闭即返回）。
            ToolbarItem(placement: .confirmationAction) {
                HStack(spacing: 10) {
                    Button { windowFlow.send(.miniEntryTapped) } label: {
                        Label(tr("迷你驾驶台"), systemImage: "pip")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(DSActionStyle())
                    .help(tr("切换到迷你驾驶台；主窗口将隐藏，关闭迷你窗口即可返回。"))
                    UpdateBadge(flow: updates.flow) { updates.requestRestartAndRelaunch() }
                }
            }
        }
        .onAppear { bindWindowFlow() }
    }

    /// 绑定窗口效果执行器：Mini 窗口不存在时经 SwiftUI openWindow 创建。
    private func bindWindowFlow() {
        windowFlow.perform = { effect in
            DriverStationWindowPresenter.apply(effect, openMini: { openWindow(id: "mini") })
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MatchSticks")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("DS").font(.system(size: 14, weight: .semibold))
                Text(tr("机器人驾驶台")).font(.caption).foregroundStyle(DSTheme.textSecondary)
            }
            .padding(.horizontal, 22).padding(.top, 46).padding(.bottom, 32)
            navGroup(tr("操作"), pages: [.operation, .setup, .usb])
            navGroup(tr("监测"), pages: [.mac, .robot, .camera, .messages])
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
        case .operation: OperationView(model: model)
        case .setup: SetupView(model: model, simProcess: $simProcess, draft: connectionDraft)
        case .settings: SettingsView(model: model)
        case .usb: USBDevicesView(model: model)
        case .mac: MacStatusView(model: model)
        case .robot: RobotView(model: model)
        case .camera: CameraView(model: model)
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
                .help(model.remoteEstopReported ? tr("机器人仍报告急停，使能不可用；等待复位生效或到驾驶页重启机器人程序。") : tr("使能机器人（需已连接且无急停）"))
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
