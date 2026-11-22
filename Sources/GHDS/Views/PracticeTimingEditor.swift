import SwiftUI
import DSCore

struct PracticeTimingEditor: View {
    @Bindable var model: DSModel

    private static let labelMinimumWidth: Double = 56
    private static let clockMinimumWidth: Double = 84

    var body: some View {
        VStack(spacing: 0) {
            timeline
                .padding(16)
            Divider().padding(.leading, 16)
            if model.practiceSeasonYear >= 2026 {
                rebuiltControls
            } else {
                legacyControls
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("比赛时间线"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(clock(configuration.totalDuration))
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
            }
            GeometryReader { geometry in
                let layout = PracticeTimeline.layout(for: configuration,
                                                     totalWidth: geometry.size.width)
                VStack(spacing: 6) {
                    timelineTrack(layout)
                    timelineClocks(layout)
                }
                .frame(width: CGFloat(layout.totalWidth), alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(height: 84)
        }
    }

    /// 真实比例轨道：区段位置与宽度只由时长占比决定，标签不参与几何计算。
    private func timelineTrack(_ layout: PracticeTimeline.Layout) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(DSTheme.segmentTrack)
            ForEach(layout.items) { item in
                let presentation = presentation(for: item.segment.kind)
                ZStack {
                    Rectangle().fill(presentation.color)
                    if item.width >= Self.labelMinimumWidth {
                        VStack(spacing: 2) {
                            Text(presentation.title)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(2)
                                .minimumScaleFactor(0.75)
                            Text(tr("%d 秒", Int(item.segment.duration)))
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                        }
                        .foregroundStyle(presentation.textColor)
                        .padding(.horizontal, 4)
                    }
                }
                .frame(width: CGFloat(item.width), height: 64)
                .clipped()
                .offset(x: CGFloat(item.x))
                .help("\(presentation.title) \(tr("%d 秒", Int(item.segment.duration)))")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(presentation.title) \(tr("%d 秒", Int(item.segment.duration)))")
            }
        }
        .frame(width: CGFloat(layout.totalWidth), height: 64, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 时间刻度同样是标签层：只显示在宽度足够的区段，不反向影响轨道。
    private func timelineClocks(_ layout: PracticeTimeline.Layout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(PracticeTimeline.labels(in: layout, minimumWidth: Self.clockMinimumWidth)) { item in
                Text("\(clock(item.segment.start))–\(clock(item.segment.end))")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(DSTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: CGFloat(item.width), alignment: .leading)
                    .offset(x: CGFloat(item.x))
            }
        }
        .frame(width: CGFloat(layout.totalWidth), height: 12, alignment: .topLeading)
    }

    private var legacyControls: some View {
        VStack(spacing: 0) {
            fullSlider(tr("开始前等待"), $model.practiceStartDelay, range: 0...30, color: .matchNeutral)
            Divider().padding(.leading, 16)
            fullSlider(tr("自动阶段"), $model.practiceAutoTime, range: 1...60, color: .matchNavy)
            Divider().padding(.leading, 16)
            fullSlider(tr("Auto → Teleop 过渡"), $model.practiceDelayTime, range: 0...30, color: .matchNeutral)
            Divider().padding(.leading, 16)
            fullSlider(tr("遥控阶段"), $model.practiceTeleopTime, range: 15...600, color: .matchBlue)
            Divider().padding(.leading, 16)
            durationSummary
                .padding(16)
        }
    }

    private var rebuiltControls: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 18) {
                    compactSlider(tr("开始前等待"), $model.practiceStartDelay, range: 0...30, color: .matchNeutral)
                    compactSlider(tr("自动阶段"), $model.practiceAutoTime, range: 1...60, color: .matchNavy)
                    compactSlider(tr("Auto → Teleop 过渡"), $model.practiceDelayTime, range: 0...30, color: .matchNeutral)
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 18) {
                    compactSlider(tr("Transition Shift"), $model.practiceTransitionShiftTime, range: 0...60, color: .matchYellow)
                    compactSlider(tr("每个 Alliance Shift"), $model.practiceAllianceShiftTime, range: 1...120, color: .matchBlue)
                    compactSlider(tr("Endgame"), $model.practiceEndgameTime, range: 0...120, color: .matchYellow)
                }
                .frame(maxWidth: .infinity)
            }
            durationSummary
        }
        .padding(16)
    }

    private var durationSummary: some View {
        HStack(spacing: 12) {
            durationCard(tr("自动阶段"), value: configuration.autoTime,
                         background: .matchNavy, foreground: .white)
            durationCard(transitionTitle, value: configuration.transitionTotal,
                         background: .matchYellow, foreground: .matchDarkText)
            durationCard("Teleop", value: configuration.teleopTotal,
                         background: .matchBlue, foreground: .white)
        }
        .frame(maxWidth: .infinity)
    }

    private func durationCard(_ title: String, value: TimeInterval,
                              background: Color, foreground: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(clock(value))
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func fullSlider(_ title: String, _ value: Binding<TimeInterval>, range: ClosedRange<Double>, color: Color) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            Slider(value: value, in: range, step: 1)
                .accessibilityLabel(title)
                .tint(color)
                .frame(width: 240)
            Text(tr("%d 秒", Int(value.wrappedValue)))
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minHeight: 56)
    }

    private func compactSlider(_ title: String, _ value: Binding<TimeInterval>, range: ClosedRange<Double>, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(tr("%d 秒", Int(value.wrappedValue)))
                    .font(.system(size: 12).monospacedDigit())
            }
            Slider(value: value, in: range, step: 1)
                .accessibilityLabel(title)
                .tint(color)
                .controlSize(.small)
        }
    }

    /// 时间线与摘要卡片使用同一份配置，Start Delay 等滑杆改动即时反映到比例轨道。
    private var configuration: PracticeTimingConfiguration {
        PracticeTimingConfiguration(
            seasonYear: model.practiceSeasonYear,
            startDelay: model.practiceStartDelay,
            autoTime: model.practiceAutoTime,
            delayTime: model.practiceDelayTime,
            teleopTime: model.practiceTeleopTime,
            transitionShift: model.practiceTransitionShiftTime,
            allianceShift: model.practiceAllianceShiftTime,
            endgame: model.practiceEndgameTime
        )
    }

    /// 旧赛季没有 Transition Shift，用 Auto → Teleop 过渡表示；不虚构阶段。
    private var transitionTitle: String {
        configuration.usesRebuiltTeleop ? "Transition Shift" : tr("Auto → Teleop 过渡")
    }

    private func presentation(for kind: PracticeTimeline.SegmentKind) -> (title: String, color: Color, textColor: Color) {
        switch kind {
        case .startDelay: return (tr("开始前等待"), .matchNeutral, .matchDarkText)
        case .autonomous: return (tr("自动阶段"), .matchNavy, .white)
        case .autoToTeleop: return (tr("过渡"), .matchNeutral, .matchDarkText)
        case .transitionShift: return ("Transition Shift", .matchYellow, .matchDarkText)
        case .allianceShift1: return ("Shift 1", .matchBlue, .white)
        case .allianceShift2: return ("Shift 2", .matchRed, .white)
        case .allianceShift3: return ("Shift 3", .matchBlue, .white)
        case .allianceShift4: return ("Shift 4", .matchRed, .white)
        case .endgame: return ("Endgame", .matchYellow, .matchDarkText)
        case .teleoperated: return ("Teleop", .matchBlue, .white)
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let value = Int(seconds.rounded())
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private extension Color {
    static let matchNavy = Color(red: 0x13 / 255, green: 0x1F / 255, blue: 0x25 / 255)
    static let matchRed = Color(red: 0xC8 / 255, green: 0x16 / 255, blue: 0x23 / 255)
    static let matchBlue = Color(red: 0x00 / 255, green: 0x7B / 255, blue: 0xC0 / 255)
    static let matchYellow = Color(red: 0xF2 / 255, green: 0xD1 / 255, blue: 0x4B / 255)
    static let matchNeutral = Color(red: 0xB9 / 255, green: 0xBE / 255, blue: 0xC4 / 255)
    static let matchDarkText = Color(red: 0x13 / 255, green: 0x1F / 255, blue: 0x25 / 255)
}
