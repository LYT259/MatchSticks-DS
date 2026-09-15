import SwiftUI
import DSCore

// MARK: - GH Driver Station 主窗口（侧栏导航 + 常驻状态栏）

@main
struct GHDSApp: App {
    @State private var model = DSModel()
    @State private var shortcuts = ShortcutManager()

    init() {
        // 未打包成 .app 直接 swift run 时，仍以常规 GUI 应用呈现
        if !Bundle.main.bundlePath.hasSuffix(".app") {
            NSApplication.shared.setActivationPolicy(.regular)
        }
    }

    var body: some Scene {
        WindowGroup("GH Driver Station") {
            RootView(model: model)
                .frame(minWidth: 980, minHeight: 620)
                .task {
                    shortcuts.install(model: model)
                    model.start()
                }
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {} // 去掉无意义的「新建」
        }
    }
}

// MARK: 根布局：状态栏常驻 + NavigationSplitView

struct RootView: View {
    let model: DSModel
    @State private var selection: Page = .operation

    enum Page: String, Hashable {
        case operation, diagnostics, usb, charts, messages, setup

        var title: String {
            switch self {
            case .operation: return "Operation"
            case .diagnostics: return "Diagnostics"
            case .usb: return "USB Devices"
            case .charts: return "Charts"
            case .messages: return "Messages"
            case .setup: return "Setup"
            }
        }

        var symbol: String {
            switch self {
            case .operation: return "slider.horizontal.3"
            case .diagnostics: return "stethoscope"
            case .usb: return "gamecontroller"
            case .charts: return "chart.xyaxis.line"
            case .messages: return "text.bubble"
            case .setup: return "gearshape"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DSStatusBar(model: model)
            Divider()
            NavigationSplitView {
                List(selection: $selection) {
                    Section("操作") {
                        row(.operation)
                    }
                    Section("诊断") {
                        row(.diagnostics)
                        row(.usb)
                        row(.charts)
                        row(.messages)
                    }
                    Section("配置") {
                        row(.setup)
                    }
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            } detail: {
                switch selection {
                case .operation: OperationView(model: model)
                case .diagnostics: DiagnosticsView(model: model)
                case .usb: USBDevicesView(model: model)
                case .charts: ChartsView(model: model)
                case .messages: MessagesView(model: model)
                case .setup: SetupView(model: model)
                }
            }
        }
    }

    private func row(_ page: Page) -> some View {
        Label(page.title, systemImage: page.symbol).tag(page)
    }
}
