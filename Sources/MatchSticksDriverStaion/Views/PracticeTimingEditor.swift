import SwiftUI
import DSCore

struct PracticeTimingEditor: View {
    @Bindable var model: DSModel

    var body: some View {
        VStack(spacing: 0) {
            if model.practiceSeasonYear >= 2026 {
                rebuiltControls
            } else {
                legacyControls
            }
        }
    }

    private var legacyControls: some View {
        VStack(spacing: 14) {
            VStack(spacing: 18) {
                compactSlider(tr("准备时间"), $model.practiceStartDelay, range: 0...30, color: .matchNeutral)
                compactSlider(tr("自动阶段"), $model.practiceAutoTime, range: 1...60, color: .matchNavy)
                compactSlider(tr("Auto → Teleop 过渡"), $model.practiceDelayTime, range: 0...30, color: .matchNeutral)
                compactSlider(tr("遥控阶段"), $model.practiceTeleopTime, range: 15...600, color: .matchBlue)
            }
        }
        .padding(.vertical, 16)
    }

    private var rebuiltControls: some View {
        VStack(spacing: 14) {
            VStack(spacing: 18) {
                compactSlider(tr("准备时间"), $model.practiceStartDelay, range: 0...30, color: .matchNeutral)
                compactSlider(tr("自动阶段"), $model.practiceAutoTime, range: 1...60, color: .matchNavy)
                compactSlider(tr("Auto → Teleop 过渡"), $model.practiceDelayTime, range: 0...30, color: .matchNeutral)
                compactSlider(tr("Transition Shift"), $model.practiceTransitionShiftTime, range: 0...60, color: .matchYellow)
                compactSlider(tr("每个 Alliance Shift"), $model.practiceAllianceShiftTime, range: 1...120, color: .matchBlue)
                compactSlider(tr("Endgame"), $model.practiceEndgameTime, range: 0...120, color: .matchYellow)
            }
        }
        .padding(.vertical, 16)
    }

    private func compactSlider(_ title: String, _ value: Binding<TimeInterval>, range: ClosedRange<Double>, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
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
}

extension DSModel {
    /// 时间线与时长卡共用同一份练习时序配置，滑杆改动即时反映到比例轨道。
    var practiceTimingConfiguration: PracticeTimingConfiguration {
        PracticeTimingConfiguration(
            seasonYear: practiceSeasonYear,
            startDelay: practiceStartDelay,
            autoTime: practiceAutoTime,
            delayTime: practiceDelayTime,
            teleopTime: practiceTeleopTime,
            transitionShift: practiceTransitionShiftTime,
            allianceShift: practiceAllianceShiftTime,
            endgame: practiceEndgameTime
        )
    }
}

extension PracticeTimingConfiguration {
    /// Practice Match 时长卡取值：Autonomous 原始时长 + Teleop 总时长（随滑杆即时变化）。
    var durationCardValues: (auto: TimeInterval, teleop: TimeInterval) {
        (autoTime, teleopTotal)
    }
}

/// m:ss 时钟格式（时长卡与时间线共用；纯函数便于值级测试）。
func practiceClock(_ seconds: TimeInterval) -> String {
    let value = Int(seconds.rounded())
    return String(format: "%d:%02d", value / 60, value % 60)
}

/// Drive 页全宽比赛时间线：真实比例轨道，区段位置与宽度只由时长占比决定，标签不参与几何计算。
/// 标签是轨道的派生层：每个区段都渲染「标题 + 秒数」，靠缩放与裁剪保证可见且不溢出。
struct PracticeMatchTimeline: View {
    let model: DSModel

    private static let clockMinimumWidth: Double = 84

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 12)
                Text(practiceClock(configuration.totalDuration))
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

    private func timelineTrack(_ layout: PracticeTimeline.Layout) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(DSTheme.segmentTrack)
            ForEach(layout.items) { item in
                let presentation = presentation(for: item.segment.kind)
                ZStack {
                    Rectangle().fill(presentation.color)
                    VStack(spacing: 2) {
                        Text(presentation.title)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.5)
                        Text(tr("%d 秒", Int(item.segment.duration)))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .lineLimit(2)
                            .minimumScaleFactor(0.5)
                    }
                    .foregroundStyle(presentation.textColor)
                    .padding(.horizontal, 2)
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
                Text("\(practiceClock(item.segment.start))–\(practiceClock(item.segment.end))")
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

    private var configuration: PracticeTimingConfiguration { model.practiceTimingConfiguration }
}

/// Practice Match 标题下的两张时长卡：Autonomous 与 Teleop 各多少秒（不显示 Transition Shift 摘要卡）。
struct PracticeDurationCards: View {
    let model: DSModel

    var body: some View {
        let values = model.practiceTimingConfiguration.durationCardValues
        return HStack(spacing: 12) {
            durationCard(tr("自动阶段"), value: values.auto,
                         background: .matchNavy, foreground: .white)
            durationCard("Teleop", value: values.teleop,
                         background: .matchBlue, foreground: .white)
        }
        .frame(maxWidth: .infinity)
    }

    private func durationCard(_ title: String, value: TimeInterval,
                              background: Color, foreground: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)
            Text(practiceClock(value))
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
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
