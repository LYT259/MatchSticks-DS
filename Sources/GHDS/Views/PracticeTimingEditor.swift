import SwiftUI
import DSCore

struct PracticeTimingEditor: View {
    @Bindable var model: DSModel

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
                Text(clock(totalDuration))
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
            }
            GeometryReader { geometry in
                let items = timelineItems
                let widths = segmentWidths(for: items, totalWidth: geometry.size.width)
                VStack(spacing: 6) {
                    HStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            VStack(spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.75)
                                Text(tr("%d 秒", Int(item.duration)))
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                            }
                            .foregroundStyle(item.textColor)
                            .frame(width: widths[index], height: 64)
                            .background(item.color)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    HStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Text("\(clock(item.start))–\(clock(item.end))")
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(DSTheme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(width: widths[index])
                        }
                    }
                }
            }
            .frame(height: 92)
        }
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
            HStack {
                Text("Teleop")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(clock(model.effectivePracticeTeleopTime))
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color.matchNavy, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
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

    private var totalDuration: TimeInterval {
        model.practiceStartDelay + model.practiceAutoTime + model.practiceDelayTime + model.effectivePracticeTeleopTime
    }

    private var timelineItems: [TimelineItem] {
        var items: [TimelineItem] = []
        var elapsed: TimeInterval = 0
        func append(_ id: String, _ title: String, _ duration: TimeInterval, _ color: Color, _ textColor: Color = .white) {
            guard duration > 0 else { return }
            items.append(TimelineItem(id: id, title: title, duration: duration, start: elapsed,
                                      end: elapsed + duration, color: color, textColor: textColor))
            elapsed += duration
        }
        append("start", tr("开始前等待"), model.practiceStartDelay, .matchNeutral, .matchDarkText)
        append("auto", tr("自动阶段"), model.practiceAutoTime, .matchNavy)
        append("delay", tr("过渡"), model.practiceDelayTime, .matchNeutral, .matchDarkText)
        if model.practiceSeasonYear >= 2026 {
            append("transition", "Transition Shift", model.practiceTransitionShiftTime, .matchYellow, .matchDarkText)
            append("shift1", "Shift 1", model.practiceAllianceShiftTime, .matchBlue)
            append("shift2", "Shift 2", model.practiceAllianceShiftTime, .matchRed)
            append("shift3", "Shift 3", model.practiceAllianceShiftTime, .matchBlue)
            append("shift4", "Shift 4", model.practiceAllianceShiftTime, .matchRed)
            append("endgame", "Endgame", model.practiceEndgameTime, .matchYellow, .matchDarkText)
        } else {
            append("teleop", "Teleop", model.practiceTeleopTime, .matchBlue)
        }
        return items
    }

    private func segmentWidths(for items: [TimelineItem], totalWidth: CGFloat) -> [CGFloat] {
        let minimums = items.map { item -> CGFloat in
            switch item.id {
            case "delay": return 38
            case "transition": return 82
            case "shift1", "shift2", "shift3", "shift4": return 104
            case "auto": return 76
            default: return 92
            }
        }
        let minimumTotal = minimums.reduce(0, +)
        let scale = min(1, totalWidth / max(minimumTotal, 1))
        let bases = minimums.map { $0 * scale }
        let remaining = max(0, totalWidth - bases.reduce(0, +))
        let durationTotal = max(items.reduce(0) { $0 + $1.duration }, 1)
        return items.indices.map { bases[$0] + remaining * items[$0].duration / durationTotal }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let value = Int(seconds.rounded())
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct TimelineItem {
    let id: String
    let title: String
    let duration: TimeInterval
    let start: TimeInterval
    let end: TimeInterval
    let color: Color
    let textColor: Color
}

private extension Color {
    static let matchNavy = Color(red: 0x13 / 255, green: 0x1F / 255, blue: 0x25 / 255)
    static let matchRed = Color(red: 0xC8 / 255, green: 0x16 / 255, blue: 0x23 / 255)
    static let matchBlue = Color(red: 0x00 / 255, green: 0x7B / 255, blue: 0xC0 / 255)
    static let matchYellow = Color(red: 0xF2 / 255, green: 0xD1 / 255, blue: 0x4B / 255)
    static let matchNeutral = Color(red: 0xB9 / 255, green: 0xBE / 255, blue: 0xC4 / 255)
    static let matchDarkText = Color(red: 0x13 / 255, green: 0x1F / 255, blue: 0x25 / 255)
}
