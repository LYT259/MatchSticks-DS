import SwiftUI
import DSCore

struct OperationView: View {
    let model: DSModel
    var openConnection: () -> Void = {}
    var openSettings: () -> Void = {}
    var openControllers: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 18) {
                        DSPanel(title: tr("驾驶模式"), subtitle: tr("失能后可切换模式。")) {
                            VStack(spacing: 8) {
                                modeRow(.teleoperated, title: tr("遥控"), detail: tr("用手柄直接控制机器人"), symbol: "gamecontroller")
                                modeRow(.autonomous, title: tr("自动"), detail: tr("运行机器人预设的自动程序"), symbol: "point.topleft.down.to.point.bottomright.curvepath")
                                modeRow(.test, title: tr("测试"), detail: tr("调试机器人程序中的测试功能"), symbol: "wrench.and.screwdriver")
                            }
                            .disabled(model.enabled)
                            if model.protocolKind == .mrc {
                                Divider()
                                opModePicker
                            }
                        }
                        DSPanel(title: tr("联盟站位")) {
                            DSSegmentedControl(title: tr("联盟站位"), selection: Binding(get: { model.alliance }, set: { model.alliance = $0 }), options: [
                                DSSelectOption(value: AllianceStation.red1, label: tr("红 1")),
                                DSSelectOption(value: AllianceStation.red2, label: tr("红 2")),
                                DSSelectOption(value: AllianceStation.red3, label: tr("红 3")),
                                DSSelectOption(value: AllianceStation.blue1, label: tr("蓝 1")),
                                DSSelectOption(value: AllianceStation.blue2, label: tr("蓝 2")),
                                DSSelectOption(value: AllianceStation.blue3, label: tr("蓝 3")),
                            ], selectedColor: DSTheme.allianceColor(for:))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 18) {
                        DSPanel(title: tr("操作前检查")) {
                            readinessRow(tr("机器人连接"), detail: model.connectionDetail, ready: model.commConnected, symbol: "network", action: openConnection)
                            Divider()
                            readinessRow(tr("机器人程序"), detail: model.commConnected && model.robotTrace.hasRobotCode ? tr("已检测到运行中的程序") : tr("等待机器人回传状态"), ready: model.commConnected && model.robotTrace.hasRobotCode, symbol: "curlybraces")
                            Divider()
                            readinessRow(tr("手柄输入"), detail: model.joystickSlots.isEmpty ? tr("未检测到手柄 · 点击检查") : tr("%d 个手柄 · 点击检查", model.joystickSlots.count), ready: !model.joystickSlots.isEmpty, symbol: "gamecontroller", action: openControllers)
                        }
                        DSPanel(title: tr("自动练习"), subtitle: tr("按设定时序依次运行自动与遥控阶段。")) {
                            HStack(spacing: 18) {
                                duration(tr("自动"), model.practiceAutoTime)
                                Image(systemName: "arrow.right").foregroundStyle(DSTheme.textSecondary)
                                duration(tr("遥控"), model.practiceTeleopTime)
                            }
                            if model.practicePhase != .idle {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(model.practicePhase.displayName)
                                        Spacer()
                                        Text(String(format: "%.1f s", max(0, model.practiceRemaining))).monospacedDigit()
                                    }.font(.callout)
                                    ProgressView(value: practiceProgress)
                                        .tint(DSTheme.accent)
                                        .controlSize(.small)
                                }
                            }
                            if model.practiceActive {
                                Button(tr("停止练习（A-Stop）"), systemImage: "stop.fill") { model.aStop() }
                                    .buttonStyle(DSActionStyle(color: DSTheme.danger))
                                    .keyboardShortcut(.delete, modifiers: [])
                            } else {
                                Button(tr("开始自动练习"), systemImage: "play.circle") { model.startPractice() }
                                    .disabled(model.estopEngaged)
                            }
                            Text(tr("开始后将按时序自动请求使能。阶段间延迟 %d 秒。", Int(model.practiceDelayTime)))
                                .font(.caption).foregroundStyle(DSTheme.textSecondary)
                            Button(tr("调整练习时长"), action: openSettings).buttonStyle(.link)
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
                    .foregroundStyle(selected ? DSTheme.accent : DSTheme.textSecondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(DSTheme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? DSTheme.accent : DSTheme.textSecondary.opacity(0.4))
            }
            .padding(12)
            .background(selected ? DSTheme.accentDim : DSTheme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? DSTheme.accent.opacity(0.5) : DSTheme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var opModePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("SystemCore 程序")).font(.callout.weight(.semibold))
            if model.opModes.isEmpty {
                Text(tr("等待机器人提供 OpMode 列表…")).font(.callout).foregroundStyle(DSTheme.textSecondary)
            } else {
                DSSelectControl(title: "OpMode", selection: Binding(get: { model.selectedOpModeHash }, set: { hash in
                    if let op = model.opModes.first(where: { $0.hash == hash }) { model.selectOpMode(op) }
                }), options: [DSSelectOption(value: UInt64(0), label: tr("选择程序"))] + model.opModes.map {
                    DSSelectOption(value: $0.hash, label: "\($0.group) · \($0.name)")
                })
                .frame(maxWidth: 420)
                Text(tr("所选程序将在使能时发送给机器人。")).font(.caption).foregroundStyle(DSTheme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func readinessRow(_ title: String, detail: String, ready: Bool, symbol: String, action: (() -> Void)? = nil) -> some View {
        let content = HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(DSTheme.textSecondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                Text(detail).font(.system(size: 12)).foregroundStyle(DSTheme.textSecondary).multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? DSTheme.success : DSTheme.textSecondary)
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
            Text(title).font(.caption).foregroundStyle(DSTheme.textSecondary)
            Text(tr("%d 秒", Int(seconds))).font(.system(size: 20, weight: .semibold)).monospacedDigit()
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
        case .idle: return tr("待机")
        case .delayBeforeAuto: return tr("准备自动阶段")
        case .autonomous: return tr("自动阶段")
        case .delayBeforeTeleop: return tr("准备遥控阶段")
        case .teleoperated: return tr("遥控阶段")
        case .finished: return tr("练习已结束")
        }
    }
}
