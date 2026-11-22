import SwiftUI
import DSCore

struct OperationView: View {
    let model: DSModel
    var openSettings: () -> Void = {}

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 18) {
                DSPanel(title: tr("驾驶模式")) {
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
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 18) {
                    DSPanel(title: tr("联盟站位")) {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 12) {
                                blueAllianceGroup
                                redAllianceGroup
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                blueAllianceGroup
                                redAllianceGroup
                            }
                        }
                    }
                    DSPanel(title: tr("自动练习")) {
                        HStack(spacing: 18) {
                            duration(tr("自动"), model.practiceAutoTime)
                            Image(systemName: "arrow.right").foregroundStyle(DSTheme.textSecondary)
                            duration(tr("遥控"), model.effectivePracticeTeleopTime)
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
                        Button(tr("调整练习时长"), action: openSettings).buttonStyle(.link)
                    }
                    if model.practiceSeasonYear == 2022 {
                        DSPanel(title: "2022 Timeout") {
                            duration("Timeout", model.timeoutActive ? model.timeoutRemaining : model.timeoutDuration)
                            if model.timeoutActive {
                                ProgressView(value: timeoutProgress)
                                    .tint(DSTheme.accent)
                                    .controlSize(.small)
                                Button(tr("取消 Timeout"), systemImage: "stop.fill") { model.cancelTimeout() }
                                    .buttonStyle(DSActionStyle(color: DSTheme.danger))
                            } else {
                                Button(tr("开始 Timeout"), systemImage: "pause.circle") { model.startTimeout() }
                                    .disabled(model.enabled || model.practiceActive || model.estopEngaged)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(24)
        }
    }

    private var blueAllianceGroup: some View {
        allianceGroup(title: tr("蓝方"), color: DSTheme.allianceBlue, stations: [.blue1, .blue2, .blue3])
    }

    private var redAllianceGroup: some View {
        allianceGroup(title: tr("红方"), color: DSTheme.allianceRed, stations: [.red1, .red2, .red3])
    }

    private func allianceGroup(title: String, color: Color, stations: [AllianceStation]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
            DSSegmentedControl(
                title: title,
                selection: Binding(get: { model.alliance }, set: { model.alliance = $0 }),
                options: stations.map { DSSelectOption(value: $0, label: stationLabel($0)) },
                selectedColor: { _ in color }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stationLabel(_ station: AllianceStation) -> String {
        switch station {
        case .red1: tr("红 1")
        case .red2: tr("红 2")
        case .red3: tr("红 3")
        case .blue1: tr("蓝 1")
        case .blue2: tr("蓝 2")
        case .blue3: tr("蓝 3")
        }
    }

    private func modeRow(_ mode: NIMode, title: String, detail _: String, symbol: String) -> some View {
        let selected = model.mode == mode
        return Button { model.setMode(mode) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 19)).frame(width: 26)
                    .foregroundStyle(selected ? DSTheme.accent : DSTheme.textSecondary)
                Text(title).font(.system(size: 14, weight: .semibold))
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
        .accessibilityLabel(title)
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

    private func duration(_ title: String, _ seconds: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(DSTheme.textSecondary)
            Text(tr("%d 秒", Int(seconds))).font(.system(size: 20, weight: .semibold)).monospacedDigit()
        }
    }

    private var practiceProgress: Double {
        let total = model.currentPracticePhaseDuration
        return total > 0 ? min(1, max(0, 1 - model.practiceRemaining / total)) : 0
    }

    private var timeoutProgress: Double {
        guard model.timeoutDuration > 0 else { return 0 }
        return min(1, max(0, 1 - model.timeoutRemaining / model.timeoutDuration))
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
        case .transitionShift: return "Transition Shift"
        case .allianceShift1: return "Alliance Shift 1"
        case .allianceShift2: return "Alliance Shift 2"
        case .allianceShift3: return "Alliance Shift 3"
        case .allianceShift4: return "Alliance Shift 4"
        case .endgame: return "Endgame"
        case .finished: return tr("练习已结束")
        }
    }
}
