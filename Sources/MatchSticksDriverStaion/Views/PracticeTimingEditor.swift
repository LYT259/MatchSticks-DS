import SwiftUI
import AppKit
import DSCore

extension DSModel {
    func applyPracticeTimelineConfiguration(_ configuration: PracticeTimingConfiguration) {
        practiceStartDelay = configuration.startDelay
        practiceAutoTime = configuration.autoTime
        practiceDelayTime = configuration.delayTime
        practiceTeleopTime = configuration.teleopTime
        practiceTransitionShiftTime = configuration.transitionShift
        practiceAllianceShiftTime = configuration.allianceShift
        practiceEndgameTime = configuration.endgame
    }


    /// 时间线与时长卡共用同一份练习时序配置，拖动分隔线即时反映到比例轨道。
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
    /// Practice Match 时长卡取值：Autonomous 原始时长 + Teleop 总时长（随分隔线拖动即时变化）。
    var durationCardValues: (auto: TimeInterval, teleop: TimeInterval) {
        (autoTime, teleopTotal)
    }
}

/// m:ss 时钟格式（时长卡与时间线共用；纯函数便于值级测试）。
func practiceClock(_ seconds: TimeInterval) -> String {
    let value = Int(seconds.rounded())
    return String(format: "%d:%02d", value / 60, value % 60)
}

private struct PracticeTimelineDragSession {
    let boundary: PracticeTimeline.TimingBoundary
    let initial: PracticeTimingConfiguration
    var current: PracticeTimingConfiguration
    let startX: CGFloat
}

/// 真实比例比赛时间线：拖动相邻阶段的分隔线调整时长，松开后一次性写回模型。
struct PracticeMatchTimeline: View {
    let model: DSModel
    @State private var dragSession: PracticeTimelineDragSession?
    @State private var hoveredBoundaryID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(tr("应用官方时序")) { model.applyPracticeTimingPreset() }
                    .buttonStyle(DSActionStyle())
                    .controlSize(.small)
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
            .frame(height: 100)
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
                        if item.segment.duration <= 3 {
                            Text(tr("%d 秒", Int(item.segment.duration)))
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                        } else {
                            Text(presentation.title)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(2)
                                .minimumScaleFactor(0.5)
                            Text(tr("%d 秒", Int(item.segment.duration)))
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .lineLimit(2)
                                .minimumScaleFactor(0.5)
                        }
                    }
                    .foregroundStyle(presentation.textColor)
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                }
                .frame(width: CGFloat(item.width), height: 64)
                .clipped()
                .offset(x: CGFloat(item.x))
                .help("\(presentation.title) \(tr("%d 秒", Int(item.segment.duration)))")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(presentation.title) \(tr("%d 秒", Int(item.segment.duration)))")
            }
            ForEach(PracticeTimeline.editingBoundaries(for: configuration)) { boundary in
                dividerHandle(boundary, layout: layout)
            }
        }
        .frame(width: CGFloat(layout.totalWidth), height: 64, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 每一段都显示开始与结束时刻，不用宽度阈值隐藏窄段（包括 3 秒 Transition Shift）。
    private func timelineClocks(_ layout: PracticeTimeline.Layout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.items) { item in
                VStack(spacing: 0) {
                    Text(practiceClock(item.segment.start))
                    Text(practiceClock(item.segment.end))
                }
                .font(.system(size: 8).monospacedDigit())
                .foregroundStyle(DSTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .frame(width: CGFloat(item.width))
                .offset(x: CGFloat(item.x))
            }
        }
        .frame(width: CGFloat(layout.totalWidth), height: 24, alignment: .topLeading)
    }

    private func dividerHandle(_ boundary: PracticeTimeline.TimingBoundary,
                               layout: PracticeTimeline.Layout) -> some View {
        let handleWidth: Double = 14
        let rawX = layout.totalDuration > 0
            ? boundary.offset / layout.totalDuration * layout.totalWidth : 0
        let x = min(max(rawX, 0), layout.totalWidth)
        let offsetX = min(max(x - handleWidth / 2, 0), max(0, layout.totalWidth - handleWidth))
        let active = hoveredBoundaryID == boundary.id || dragSession?.boundary.id == boundary.id
        let values = boundaryValues(boundary)
        return ZStack {
            Rectangle()
                .fill(active ? DSTheme.textPrimary.opacity(0.65) : DSTheme.textSecondary.opacity(0.35))
                .frame(width: 1, height: 64)
                .offset(x: CGFloat(x - offsetX - handleWidth / 2))
            if active {
                Capsule()
                    .fill(DSTheme.card)
                    .frame(width: 8, height: 24)
                    .overlay(Capsule().stroke(DSTheme.textSecondary, lineWidth: 0.7))
            }
        }
        .frame(width: handleWidth, height: 64)
        .contentShape(Rectangle())
        .offset(x: offsetX)
        .onHover { inside in
            if inside {
                hoveredBoundaryID = boundary.id
                NSCursor.resizeLeftRight.push()
            } else {
                if hoveredBoundaryID == boundary.id { hoveredBoundaryID = nil }
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in updateDrag(boundary, value: value, layout: layout) }
                .onEnded { _ in finishDrag() }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("拖动调整 %@ 与 %@ 的时长",
                               presentation(for: boundary.left).title,
                               presentation(for: boundary.right).title))
        .accessibilityValue("\(tr("%d 秒", Int(values.left))) / \(tr("%d 秒", Int(values.right)))")
        .accessibilityHint(tr("左右拖动，松开后保存"))
        .accessibilityAdjustableAction { adjustment in
            switch adjustment {
            case .increment: adjust(boundary, deltaSeconds: 1)
            case .decrement: adjust(boundary, deltaSeconds: -1)
            @unknown default: break
            }
        }
       }

    private func updateDrag(_ boundary: PracticeTimeline.TimingBoundary,
                            value: DragGesture.Value,
                            layout: PracticeTimeline.Layout) {
        var session = dragSession ?? PracticeTimelineDragSession(
            boundary: boundary, initial: configuration, current: configuration,
            startX: value.startLocation.x)
        let secondsPerPoint = layout.totalWidth > 0 ? layout.totalDuration / layout.totalWidth : 0
        session.current = PracticeTimeline.configuration(
            session.initial, dragging: boundary,
            deltaSeconds: (value.location.x - session.startX) * secondsPerPoint)
        dragSession = session
    }

    private func finishDrag() {
        guard let session = dragSession else { return }
        model.applyPracticeTimelineConfiguration(session.current)
        dragSession = nil
        hoveredBoundaryID = nil
    }

    private func adjust(_ boundary: PracticeTimeline.TimingBoundary, deltaSeconds: TimeInterval) {
        let updated = PracticeTimeline.configuration(configuration, dragging: boundary,
                                                     deltaSeconds: deltaSeconds)
        model.applyPracticeTimelineConfiguration(updated)
        dragSession = nil
    }

    private func boundaryValues(_ boundary: PracticeTimeline.TimingBoundary) -> (left: TimeInterval, right: TimeInterval) {
        switch (boundary.left, boundary.right) {
        case (.startDelay, .autonomous): return (configuration.startDelay, configuration.autoTime)
        case (.autonomous, .autoToTeleop): return (configuration.autoTime, configuration.delayTime)
        case (.autoToTeleop, .transitionShift): return (configuration.delayTime, configuration.transitionShift)
        case (.autoToTeleop, .teleoperated): return (configuration.delayTime, configuration.teleopTime)
        case (.transitionShift, .allianceShift1): return (configuration.transitionShift, configuration.allianceShift)
        case (.allianceShift4, .endgame): return (configuration.allianceShift, configuration.endgame)
        default: return (0, 0)
        }
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

    private var configuration: PracticeTimingConfiguration {
        dragSession?.current ?? model.practiceTimingConfiguration
    }
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
