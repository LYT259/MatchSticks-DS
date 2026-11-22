// Practice 时间线纯逻辑：比例布局、赛季切换、边界值与 Sequencer 开始等待回归。
// 布局单位是抽象宽度（Double），测试不需要 SwiftUI。

import Foundation
import DSCore

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

func practiceTimelineTests() {
    // MARK: 摘要时长：2026 用 Transition Shift，旧赛季回退 Auto→Teleop 过渡

    let legacy = PracticeTimingConfiguration(
        seasonYear: 2025, startDelay: 0, autoTime: 15, delayTime: 3,
        teleopTime: 135, transitionShift: 10, allianceShift: 25, endgame: 30
    )
    check(!legacy.usesRebuiltTeleop, "2025 无重建 Teleop 子阶段")
    check(legacy.teleopTotal == 135, "旧赛季 Teleop 使用单一 teleopTime")
    check(legacy.transitionTotal == 3, "旧赛季 Transition 使用 practiceDelayTime，不虚构 Transition Shift")
    check(legacy.totalDuration == 153, "旧赛季总时长 = 开始等待 + Auto + 过渡 + Teleop")

    let rebuilt = PracticeTimingConfiguration(
        seasonYear: 2026, startDelay: 2, autoTime: 20, delayTime: 3,
        teleopTime: 140, transitionShift: 10, allianceShift: 25, endgame: 30
    )
    check(rebuilt.usesRebuiltTeleop, "2026 使用重建 Teleop 子阶段")
    check(rebuilt.teleopTotal == 140, "2026 Teleop = Transition + 4 × Shift + Endgame")
    check(rebuilt.transitionTotal == 10, "2026 Transition 使用 practiceTransitionShiftTime")
    check(rebuilt.totalDuration == 165, "2026 总时长 = 开始等待 + Auto + 过渡 + Teleop 子阶段之和")
    check(PracticeTimingPreset.forYear(2026)?.teleopTime == rebuilt.teleopTotal,
          "2026 官方 Teleop 时长与子阶段之和一致")

    var ignoredTeleopTime = rebuilt
    ignoredTeleopTime.teleopTime = 999
    check(ignoredTeleopTime.teleopTotal == 140 && ignoredTeleopTime.totalDuration == 165,
          "2026 不再叠加旧 teleopTime 字段")

    // MARK: 区段切分：顺序、连续性、0 秒开始等待

    let rebuiltKinds: [PracticeTimeline.SegmentKind] = [
        .startDelay, .autonomous, .autoToTeleop, .transitionShift,
        .allianceShift1, .allianceShift2, .allianceShift3, .allianceShift4, .endgame,
    ]
    let rebuiltSegments = PracticeTimeline.segments(for: rebuilt)
    check(rebuiltSegments.map(\.kind) == rebuiltKinds, "2026 区段顺序与 Sequencer 阶段一致")
    check(rebuiltSegments.first?.start == 0, "时间线从 0 开始")
    check(near(rebuiltSegments.last?.end ?? -1, 165), "2026 区段累计等于总时长")
    for (previous, next) in zip(rebuiltSegments, rebuiltSegments.dropFirst()) {
        check(near(previous.end, next.start), "区段首尾相接：\(previous.kind) → \(next.kind)")
    }

    let legacyKinds: [PracticeTimeline.SegmentKind] = [.autonomous, .autoToTeleop, .teleoperated]
    check(PracticeTimeline.segments(for: legacy).map(\.kind) == legacyKinds,
          "旧赛季无 Transition Shift / Alliance Shift 区段")

    var zeroStart = rebuilt
    zeroStart.startDelay = 0
    check(PracticeTimeline.segments(for: zeroStart).map(\.kind) == Array(rebuiltKinds.dropFirst()),
          "0 秒开始等待不生成空区段")

    // MARK: 真实比例轨道（固定最小宽度不得混入几何）

    let width = 1000.0
    let layout = PracticeTimeline.layout(for: rebuilt, totalWidth: width)
    check(layout.items.count == rebuiltSegments.count, "轨道区段数与时长区段数一致")
    check(near(layout.totalWidth, width), "轨道总宽等于可用宽度")
    check(near(layout.items.reduce(0) { $0 + $1.width }, width), "比例宽度之和等于轨道总宽")
    check(near(layout.totalDuration, 165), "布局携带真实总时长")

    let startItem = layout.items[0]
    check(startItem.id == .startDelay, "开始等待位于轨道最左")
    check(near(startItem.x, 0), "开始等待起点为 0")
    check(near(startItem.width, 2.0 / 165.0 * width), "开始等待宽度 = 2/165 × 轨道宽")

    let autoItem = layout.items[1]
    check(near(autoItem.x, startItem.width), "Auto 紧接开始等待")
    check(near(autoItem.width, 20.0 / 165.0 * width), "Auto 宽度 = 20/165 × 轨道宽")

    // 典型值 → 0 → 边界值：开始等待区段的宽度与后续区段起点同步变化
    let zeroLayout = PracticeTimeline.layout(for: zeroStart, totalWidth: width)
    check(zeroLayout.items.first?.id == .autonomous && near(zeroLayout.items[0].x, 0),
          "0 秒开始等待：Auto 从 0 位置开始")
    check(near(zeroLayout.items[0].width, 20.0 / 163.0 * width), "0 秒开始等待时 Auto 占比按 163 秒总时长计算")

    var longStart = rebuilt
    longStart.startDelay = 30
    let longLayout = PracticeTimeline.layout(for: longStart, totalWidth: width)
    let longStartItem = longLayout.items[0]
    let longAutoItem = longLayout.items[1]
    check(near(longStartItem.width, 30.0 / 193.0 * width), "30 秒开始等待宽度 = 30/193 × 轨道宽")
    check(near(longAutoItem.x, longStartItem.width), "边界值：Auto 起点随开始等待右移")
    check(longAutoItem.width < autoItem.width, "边界值：Auto 自身宽度按比例缩小")
    check(near(longAutoItem.width, 20.0 / 193.0 * width), "边界值：Auto 宽度 = 20/193 × 轨道宽")

    // 只有开始等待一段时占满整条轨道
    let onlyStart = PracticeTimingConfiguration(
        seasonYear: 2026, startDelay: 30, autoTime: 0, delayTime: 0,
        teleopTime: 0, transitionShift: 0, allianceShift: 0, endgame: 0
    )
    let onlyStartLayout = PracticeTimeline.layout(for: onlyStart, totalWidth: width)
    check(onlyStartLayout.items.count == 1, "仅剩开始等待一个区段")
    check(near(onlyStartLayout.items[0].width, width), "单区段占满轨道")
    check(near(onlyStartLayout.items[0].x, 0), "单区段从 0 开始")

    // 总时长为 0 / 宽度为 0：空轨道，不除零、不产生 NaN
    let emptyConfiguration = PracticeTimingConfiguration(
        seasonYear: 2026, startDelay: 0, autoTime: 0, delayTime: 0,
        teleopTime: 0, transitionShift: 0, allianceShift: 0, endgame: 0
    )
    check(PracticeTimeline.segments(for: emptyConfiguration).isEmpty, "总时长 0 不生成区段")
    let emptyLayout = PracticeTimeline.layout(for: emptyConfiguration, totalWidth: width)
    check(emptyLayout.items.isEmpty && emptyLayout.totalDuration == 0, "总时长 0 返回空轨道")
    check(emptyLayout.totalWidth == width, "总时长 0 仍保留有效轨道宽")

    let zeroWidthLayout = PracticeTimeline.layout(for: rebuilt, totalWidth: 0)
    check(zeroWidthLayout.items.isEmpty && zeroWidthLayout.totalWidth == 0, "宽度 0 返回空轨道")
    check(!zeroWidthLayout.totalDuration.isNaN, "宽度 0 不产生 NaN")

    // 外部输入不可信：负值与 NaN/Infinity 按 0 处理
    let malformed = PracticeTimingConfiguration(
        seasonYear: 2026, startDelay: -3, autoTime: .nan, delayTime: .infinity,
        teleopTime: 0, transitionShift: -1, allianceShift: .nan, endgame: 30
    )
    check(malformed.teleopTotal == 30, "畸形子阶段时长按 0 处理")
    check(malformed.totalDuration == 30, "畸形总时长只保留有效值")
    let malformedLayout = PracticeTimeline.layout(for: malformed, totalWidth: width)
    check(malformedLayout.items.count == 1 && malformedLayout.items[0].id == .endgame,
          "畸形配置只保留有效区段")
    check(near(malformedLayout.items[0].width, width), "畸形配置的有效区段仍占满轨道")

    // MARK: 标签是轨道的派生层，不反向影响几何

    let titleLabels = PracticeTimeline.labels(in: layout, minimumWidth: 60)
    check(titleLabels.allSatisfy { $0.width >= 60 }, "标签只落在宽度足够的区段")
    check(!titleLabels.contains { $0.id == .startDelay }, "2 秒开始等待区段过窄，不显示标签")
    check(titleLabels.contains { $0.id == .autonomous }, "Auto 区段宽度足够，显示标签")
    for label in titleLabels {
        guard let track = layout.items.first(where: { $0.id == label.id }) else {
            check(false, "标签必须对应轨道区段 \(label.id.rawValue)")
            continue
        }
        check(label.x == track.x && label.width == track.width, "标签几何沿用轨道：\(label.id.rawValue)")
    }
    check(PracticeTimeline.labels(in: longLayout, minimumWidth: 60).contains { $0.id == .startDelay },
          "开始等待拉长后标签出现")
    check(layout.items == PracticeTimeline.layout(for: rebuilt, totalWidth: width).items,
          "标签阈值不改变轨道几何")

    // MARK: 赛季切换：2025 单一 Teleop，2026 六段 Teleop

    let legacyLayout = PracticeTimeline.layout(for: legacy, totalWidth: width)
    check(legacyLayout.items.last?.id == .teleoperated, "旧赛季以单一 Teleop 结束")
    check(!legacyLayout.items.contains { $0.id == .transitionShift || $0.id == .endgame },
          "旧赛季不虚构 Transition / Endgame 区段")
    let rebuiltLayout = PracticeTimeline.layout(for: rebuilt, totalWidth: width)
    check(rebuiltLayout.items.last?.id == .endgame, "2026 以 Endgame 结束")
    check(rebuiltLayout.items.contains { $0.id == .transitionShift }, "2026 含 Transition Shift 区段")
    check(near(legacyLayout.totalDuration, 153) && near(rebuiltLayout.totalDuration, 165),
          "赛季切换改变总时长与比例")

    // MARK: Sequencer 开始等待行为保持不变（回归）

    var waiting = PracticeSequencer(config: .init(autoTime: 20, teleopTime: 140,
                                                  delayTime: 3, startDelay: 2))
    let waitingStart = waiting.start()
    check(waiting.phase == .delayBeforeAuto && waiting.remaining == 2, "开始等待进入 delayBeforeAuto")
    check(!waitingStart.contains(.enable), "开始等待期间不使能")
    check(waiting.phaseDuration == 2, "开始等待进度使用独立 startDelay")

    var waitingEvents: [PracticeSequencer.Event] = []
    for _ in 0..<19 { waitingEvents += waiting.tick(0.1) }
    check(waiting.phase == .delayBeforeAuto, "等待未满 2 秒不提前进入 Auto")
    waitingEvents += waiting.tick(0.1)
    check(waiting.phase == .autonomous && waiting.remaining == 20, "等待 2 秒后进入 Auto")
    check(waitingEvents.contains(.enable), "进入 Auto 才使能")

    var immediate = PracticeSequencer(config: .init(autoTime: 20, teleopTime: 140,
                                                    delayTime: 3, startDelay: 0))
    let immediateEvents = immediate.start()
    check(immediate.phase == .autonomous && immediate.remaining == 20, "0 秒开始等待直接进入 Auto")
    check(immediateEvents.contains(.enable), "0 秒开始等待立即使能")

    var zeroSequencer = PracticeSequencer(config: .init(autoTime: 0, teleopTime: 0,
                                                        delayTime: 0, startDelay: 0))
    _ = zeroSequencer.start()
    for _ in 0..<3 { _ = zeroSequencer.tick(0.1) }
    check(zeroSequencer.phase == .finished, "总时长 0 的时序安全结束")
    check(zeroSequencer.remaining == 0, "总时长 0 不产生负数剩余")
}
