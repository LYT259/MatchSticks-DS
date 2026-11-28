import SwiftUI
import DSCore

struct MiniView: View {
    let model: DSModel
    let flow: DriverStationWindowFlow
    @State private var refresh = RobotRefreshFlow()
    @ObservedObject private var language = LanguageManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MiniConsoleBar(model: model, flow: flow, refresh: refresh)
            .onAppear {
                refresh.bindAction { model.refreshRobotConnection() }
                flow.perform = { effect in
                    DriverStationWindowPresenter.apply(effect,
                                                       openMini: { openWindow(id: "mini") },
                                                       openMain: { openWindow(id: "main") })
                }
                flow.send(.miniWindowAppeared)
            }
    }
}

struct MiniConsoleBar: View {
    let model: DSModel
    let flow: DriverStationWindowFlow
    let refresh: RobotRefreshFlow

    var body: some View {
        Group {
            switch model.miniReferenceStyle {
            case .niClassic:
                MiniNIClassicView(model: model, flow: flow, refresh: refresh)
            case .firstModern:
                MiniFIRSTModernView(model: model, flow: flow, refresh: refresh)
            }
        }
        .frame(minWidth: 768, minHeight: 128, alignment: .leading)
        .background(DSTheme.canvas)
        .tint(DSTheme.accent)
        .foregroundStyle(DSTheme.textPrimary)
        .buttonStyle(DSActionStyle())
        .onChange(of: model.commState) { _, _ in
            refresh.noteCommStateChange()
        }
        .task(id: refresh.generation) {
            guard refresh.isRefreshing else { return }
            try? await Task.sleep(for: .seconds(RobotRefreshFlow.maxSpinInterval))
            refresh.settle()
        }
    }
}

struct MiniRestoreButton: View {
    let flow: DriverStationWindowFlow

    var body: some View {
        Button { flow.send(.returnToMainTapped) } label: {
            Label(tr("返回完整驾驶台"), systemImage: "arrow.up.left.and.arrow.down.right")
                .labelStyle(.iconOnly)
                .frame(minWidth: 32, minHeight: 30)
        }
        .help(tr("隐藏迷你驾驶台并恢复完整主窗口。"))
        .accessibilityLabel(tr("返回完整驾驶台"))
    }
}

struct MiniRefreshButton: View {
    let model: DSModel
    let refresh: RobotRefreshFlow

    var body: some View {
        Button { refresh.request() } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .medium))
                .rotationEffect(.degrees(refresh.isRefreshing ? 360 : 0))
                .animation(refresh.isRefreshing
                           ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                           : .default,
                           value: refresh.generation)
        }
        .disabled(model.commConnected)
        .help(tr("刷新机器人连接"))
        .accessibilityLabel(tr("刷新机器人连接"))
    }
}

struct MiniSafetyControls: View {
    let model: DSModel

    var body: some View {
        HStack(spacing: 8) {
            Button { model.setEnabled(true) } label: {
                Label(tr("使能"), systemImage: "play.fill").frame(minWidth: 64, minHeight: 26)
            }
            .buttonStyle(DSActionStyle(color: DSTheme.success, prominent: true))
            .disabled(!model.canEnable || model.remoteEstopReported)
            .help(model.remoteEstopReported
                  ? tr("机器人仍报告急停，使能不可用；等待复位生效或到驾驶页重启机器人程序。")
                  : tr("使能机器人（需已连接且无急停）"))
            Button { model.setEnabled(false) } label: {
                Label(tr("失能"), systemImage: "stop.fill").frame(minWidth: 64, minHeight: 26)
            }
            .help(tr("失能机器人"))
            Button { model.triggerEstop() } label: {
                Label(tr("急停"), systemImage: "exclamationmark.octagon.fill").frame(minWidth: 64, minHeight: 26)
            }
            .buttonStyle(DSActionStyle(color: DSTheme.danger, prominent: true))
            .disabled(model.estopEngaged)
            .help(tr("急停"))
        }
    }
}

struct MiniStatusLights: View {
    let model: DSModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            light("Communications", active: model.commConnected)
            light("Robot Code", active: model.commConnected && model.robotTrace.hasRobotCode)
            light("Joysticks", active: !model.joystickSlots.isEmpty)
        }
    }

    private func light(_ title: String, active: Bool) -> some View {
        HStack(spacing: 7) {
            Text(title).font(.system(size: 10))
            Circle().fill(active ? DSTheme.success : DSTheme.danger).frame(width: 8, height: 8)
        }
        .accessibilityLabel("\(title): \(active ? tr("正常") : tr("未就绪"))")
    }
}

struct MiniModePicker: View {
    let model: DSModel

    var body: some View {
        DSSegmentedControl(title: tr("驾驶模式"), selection: Binding(
            get: { model.mode }, set: { model.setMode($0) }
        ), options: [
            DSSelectOption(value: NIMode.teleoperated, label: "Teleop"),
            DSSelectOption(value: NIMode.autonomous, label: "Auto"),
            DSSelectOption(value: NIMode.test, label: "Test"),
        ])
        .disabled(model.enabled)
    }
}

struct MiniAlliancePicker: View {
    let model: DSModel

    var body: some View {
        DSSelectControl(title: "Alliance Station", selection: Binding(
            get: { model.alliance }, set: { model.alliance = $0 }
        ), options: [AllianceStation.blue1, .blue2, .blue3, .red1, .red2, .red3].map {
            DSSelectOption(value: $0, label: $0.displayName)
        })
        .tint(DSTheme.allianceColor(for: model.alliance))
    }
}
