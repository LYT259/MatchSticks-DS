import SwiftUI
import DSCore

struct OperationView: View {
    let model: DSModel
    var openSetup: () -> Void = {}
    var openControllers: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 18) {
                        DSPanel(title: "驾驶模式", subtitle: "失能后可切换模式。") {
                            VStack(spacing: 8) {
                                modeRow(.teleoperated, title: "遥控", detail: "用手柄直接控制机器人", symbol: "gamecontroller")
                                modeRow(.autonomous, title: "自动", detail: "运行机器人预设的自动程序", symbol: "point.topleft.down.to.point.bottomright.curvepath")
                                modeRow(.test, title: "测试", detail: "调试机器人程序中的测试功能", symbol: "wrench.and.screwdriver")
                            }
                            .disabled(model.enabled)
                            if model.protocolKind == .mrc {
                                Divider()
                                opModePicker
                            }
                        }
                        DSPanel(title: "联盟站位") {
                            Picker("联盟站位", selection: Binding(get: { model.alliance }, set: { model.alliance = $0 })) {
                                Text("红 1").tag(AllianceStation.red1)
                                Text("红 2").tag(AllianceStation.red2)
                                Text("红 3").tag(AllianceStation.red3)
                                Text("蓝 1").tag(AllianceStation.blue1)
                                Text("蓝 2").tag(AllianceStation.blue2)
                                Text("蓝 3").tag(AllianceStation.blue3)
                            }
                            .pickerStyle(.segmented).labelsHidden()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 18) {
                        DSPanel(title: "操作前检查") {
                            readinessRow("机器人连接", detail: model.connectionDetail, ready: model.commConnected, symbol: "network", action: openSetup)
                            Divider()
                            readinessRow("机器人程序", detail: model.commConnected && model.robotTrace.hasRobotCode ? "已检测到运行中的程序" : "等待机器人回传状态", ready: model.commConnected && model.robotTrace.hasRobotCode, symbol: "curlybraces")
                            Divider()
                            readinessRow("手柄输入", detail: model.joystickSlots.isEmpty ? "未检测到手柄 · 点击检查" : "\(model.joystickSlots.count) 个手柄 · 点击检查", ready: !model.joystickSlots.isEmpty, symbol: "gamecontroller", action: openControllers)
                        }
                        DSPanel(title: "自动练习", subtitle: "按设定时序依次运行自动与遥控阶段。") {
                            HStack(spacing: 18) {
                                duration("自动", model.practiceAutoTime)
                                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                                duration("遥控", model.practiceTeleopTime)
                            }
                            if model.practicePhase != .idle {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(model.practicePhase.displayName)
                                        Spacer()
                                        Text(String(format: "%.1f s", max(0, model.practiceRemaining))).monospacedDigit()
                                    }.font(.callout)
                                    ProgressView(value: practiceProgress)
                                }
                            }
                            if model.practiceActive {
                                Button("停止练习（A-Stop）", systemImage: "stop.fill") { model.aStop() }
                                    .buttonStyle(DSActionStyle(color: .red))
                                    .keyboardShortcut(.delete, modifiers: [])
                            } else {
                                Button("开始自动练习", systemImage: "play.circle") { model.startPractice() }
                                    .disabled(model.estopEngaged)
                            }
                            Text("开始后将按时序自动请求使能。阶段间延迟 \(Int(model.practiceDelayTime)) 秒。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("调整练习时长", action: openSetup).buttonStyle(.link)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
    }

    private func modeRow(_ mode: NIMode, title: String, detail: String, symbol: String) -> some View {
        let selected = model.mode == mode
        return Button { model.setMode(mode) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 19)).frame(width: 26)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .padding(12)
            .background(selected ? Color.accentColor.opacity(0.08) : DSTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var opModePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SystemCore 程序").font(.callout.weight(.semibold))
            if model.opModes.isEmpty {
                Text("等待机器人提供 OpMode 列表…").font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("OpMode", selection: Binding(get: { model.selectedOpModeHash }, set: { hash in
                    if let op = model.opModes.first(where: { $0.hash == hash }) { model.selectOpMode(op) }
                })) {
                    Text("选择程序").tag(UInt64(0))
                    ForEach(model.opModes, id: \.hash) { op in
                        Text("\(op.group) · \(op.name)").tag(op.hash)
                    }
                }
                Text("所选程序将在使能时发送给机器人。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func readinessRow(_ title: String, detail: String, ready: Bool, symbol: String, action: (() -> Void)? = nil) -> some View {
        let content = HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? Color.green : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content.accessibilityElement(children: .combine)
        }
    }

    private func duration(_ title: String, _ seconds: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(Int(seconds)) 秒").font(.system(size: 20, weight: .semibold)).monospacedDigit()
        }
    }

    private var practiceProgress: Double {
        let total: TimeInterval
        switch model.practicePhase {
        case .delayBeforeAuto, .delayBeforeTeleop: total = model.practiceDelayTime
        case .autonomous: total = model.practiceAutoTime
        case .teleoperated: total = model.practiceTeleopTime
        default: return 0
        }
        return total > 0 ? min(1, max(0, 1 - model.practiceRemaining / total)) : 0
    }
}

extension DSModel.PracticePhase {
    var displayName: String {
        switch self {
        case .idle: return "待机"
        case .delayBeforeAuto: return "准备自动阶段"
        case .autonomous: return "自动阶段"
        case .delayBeforeTeleop: return "准备遥控阶段"
        case .teleoperated: return "遥控阶段"
        case .finished: return "练习已结束"
        }
    }
}
