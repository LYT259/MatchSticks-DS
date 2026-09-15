import SwiftUI
import DSCore

// MARK: - Operation 页（模式 / Enable / Disable / E-Stop / Alliance / Practice / 重启指令）

struct OperationView: View {
    let model: DSModel
    @State private var confirmReboot = false
    @State private var confirmRestart = false

    var body: some View {
        Form {
            Section("模式") {
                Picker("模式", selection: Binding(
                    get: { model.mode },
                    set: { model.setMode($0) })) {
                    Text("Teleoperated").tag(NIMode.teleoperated)
                    Text("Autonomous").tag(NIMode.autonomous)
                    Text("Test").tag(NIMode.test)
                }
                .pickerStyle(.segmented)
                .disabled(model.enabled) // 使能中禁切模式（NI DS 同款约束）

                Toggle("Practice 时序", isOn: Binding(
                    get: { model.practicePhase != .idle && model.practicePhase != .finished },
                    set: { on in on ? model.startPractice() : model.aStop() }))
                    .disabled(model.estopEngaged)

                if model.practicePhase != .idle {
                    practiceStatus
                }
            }

            Section("使能控制") {
                HStack(spacing: 14) {
                    bigButton(title: "Enable", symbol: "play.fill", role: .green) {
                        model.setEnabled(true)
                    }
                    .disabled(!canEnable)
                    .keyboardShortcut("\\", modifiers: [.command]) // 提示用；真实组合 [ + ] + \ 走事件监听

                    bigButton(title: "Disable", symbol: "stop.fill", role: .gray) {
                        model.setEnabled(false)
                    }
                    .keyboardShortcut(.return, modifiers: [])

                    bigButton(title: model.estopEngaged ? "E-STOPPED" : "E-STOP",
                              symbol: "exclamationmark.octagon.fill", role: .red,
                              prominent: true) {
                        model.triggerEstop()
                    }
                    .disabled(model.estopEngaged)

                    if model.estopEngaged {
                        Button {
                            model.resetEstop()
                        } label: {
                            Label("复位 E-Stop（Esc+I）", systemImage: "arrow.counterclockwise")
                        }
                    }
                }

                HStack {
                    Label(elapsedText, systemImage: "timer")
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(model.enabled ? Color.green : Color.secondary)
                    Spacer()
                    if model.estopEngaged {
                        Text("E-STOP 锁存：按 Esc+I 1 秒或「重启代码」解除")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }
            }

            Section("联盟站位") {
                Picker("Alliance Station", selection: Binding(
                    get: { model.alliance },
                    set: { model.alliance = $0 })) {
                    Text("Red 1").tag(AllianceStation.red1)
                    Text("Red 2").tag(AllianceStation.red2)
                    Text("Red 3").tag(AllianceStation.red3)
                    Text("Blue 1").tag(AllianceStation.blue1)
                    Text("Blue 2").tag(AllianceStation.blue2)
                    Text("Blue 3").tag(AllianceStation.blue3)
                }
                .pickerStyle(.segmented)
            }

            Section("远程指令") {
                HStack {
                    Button("Reboot roboRIO", systemImage: "power.dotted") {
                        confirmReboot = true
                    }
                    .disabled(!model.commConnected)
                    Button("Restart Robot Code", systemImage: "arrow.clockwise.circle") {
                        confirmRestart = true
                    }
                    .disabled(!model.commConnected)
                    Spacer()
                    Button("重扫手柄（F1）", systemImage: "gamecontroller") {
                        model.rescanJoysticks()
                    }
                }
                Text("机器人处于使能状态时重启会造成控制中断（看门狗全停）。仅在确认失能后操作。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("确认重启 roboRIO？", isPresented: $confirmReboot, titleVisibility: .visible) {
            Button("重启 roboRIO", role: .destructive) { model.rebootRoboRIO() }
        } message: {
            Text("机器人将断联约 5 秒。请确认当前已失能。")
        }
        .confirmationDialog("确认重启 Robot Code？", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("重启代码", role: .destructive) { model.restartRobotCode() }
        } message: {
            Text("代码重启期间机器人保持失能。")
        }
    }

    private var canEnable: Bool {
        model.commConnected && !model.estopEngaged && model.watchdogHealthy && !model.enabled
    }

    private var elapsedText: String {
        guard model.enabled else { return "00:00.0" }
        let t = model.enabledElapsed
        return String(format: "%02d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }

    private var practiceStatus: some View {
        HStack {
            Text(model.practicePhase.displayName)
                .font(.callout.weight(.semibold))
            ProgressView(value: practiceProgress)
                .frame(maxWidth: 220)
            Text(String(format: "%.1fs", max(0, model.practiceRemaining)))
                .font(.callout.monospacedDigit())
            Button("A-Stop", role: .destructive) { model.aStop() }
                .keyboardShortcut(.delete, modifiers: [])
        }
        .padding(.vertical, 2)
    }

    private var practiceProgress: Double {
        let total: TimeInterval
        switch model.practicePhase {
        case .delayBeforeAuto, .delayBeforeTeleop: total = model.practiceDelayTime
        case .autonomous: total = model.practiceAutoTime
        case .teleoperated: total = model.practiceTeleopTime
        default: return 0
        }
        guard total > 0 else { return 0 }
        return 1 - max(0, model.practiceRemaining) / total
    }

    private func bigButton(title: String, symbol: String, role: Color, prominent: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 22))
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: prominent ? 72 : 56)
        }
        .buttonStyle(.borderedProminent)
        .tint(role)
        .opacity(prominent ? 1 : 0.92)
    }
}

extension DSModel.PracticePhase {
    var displayName: String {
        switch self {
        case .idle: return "待机"
        case .delayBeforeAuto: return "Auto 前延迟"
        case .autonomous: return "Autonomous"
        case .delayBeforeTeleop: return "Teleop 前延迟"
        case .teleoperated: return "Teleoperated"
        case .finished: return "已结束"
        }
    }
}
