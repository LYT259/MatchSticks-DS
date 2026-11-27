import Foundation
import DSCore

// MARK: Practice 进度真实时间推进（2026-11-23）
//
// 覆盖：主 runloop 停顿后按真实 elapsed 追赶到正确阶段（定时器只负责唤醒，不假定准时）；
// 显示用剩余时间与进度条共用同一时钟外推；时钟可注入，确定性问题不靠睡眠证明。

@MainActor
func practiceProgressTests(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void) {
    let suiteName = "org.ghfrc.driverstation.test.uitests.practice-progress.\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    defer { suite.removePersistentDomain(forName: suiteName) }

    // ===== A. 主线程停顿跨越阶段边界：恢复后进入正确阶段 =====
    // 定时器已挂在 .common 模式，但 NSTimer 在主线程停顿后只补发一次：固定 tick(0.1)
    // 会让停顿 0.5s 跨过 0.3s 开始等待后仍停在「准备自动阶段」。
    let stalled = DSModel(settingsDefaults: suite, persistenceEnabled: false)
    stalled.practiceStartDelay = 0.3
    stalled.practiceCountdownSpeech = CountdownSpeechSpy()
    stalled.startPractice()
    check(stalled.practicePhase == .delayBeforeAuto, "练习从开始等待进入")
    Thread.sleep(forTimeInterval: 0.5)   // 模拟主线程被阻塞（拖窗口/菜单期间的同步工作）
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    check(stalled.practicePhase == .autonomous,
          "主线程停顿 0.5s 跨过 0.3s 开始等待后，恢复时按真实时间进入自动阶段（实际 \(stalled.practicePhase.rawValue)）")
    check(stalled.practiceRemaining > 14.5 && stalled.practiceRemaining < 14.9,
          "恢复后的剩余时间按真实经过时间扣减（实际 \(stalled.practiceRemaining)）")
    stalled.aStop()
    check(!stalled.practiceActive && !stalled.enabled, "A-Stop 结束练习且不使能")

    // ===== B. 注入时钟：显示外推、真实 elapsed 追赶、A-Stop =====
    let model = DSModel(settingsDefaults: suite, persistenceEnabled: false)
    var now: TimeInterval = 1_000
    model.practiceClock = { now }
    model.practiceSeasonYear = 2025   // 旧赛季：等待 2 → Auto 15 → 过渡 3 → Teleop 135
    model.practiceStartDelay = 2
    model.practiceAutoTime = 15
    model.practiceDelayTime = 3
    model.practiceTeleopTime = 135
    model.practiceCountdownSpeech = CountdownSpeechSpy()
    model.startPractice()
    check(model.practicePhase == .delayBeforeAuto && model.practiceRemaining == 2, "开始练习：进入开始等待，剩余 2")
    let start = model.practiceDisplay(at: now)
    check(start.remaining == 2 && start.progress == 0, "开始瞬间显示剩余 2.0、进度 0")
    now += 0.75
    let midway = model.practiceDisplay(at: now)
    check(abs(midway.remaining - 1.25) < 1e-9,
          "两次 tick 之间显示按同一时钟外推：0.75s 后剩 1.25（实际 \(midway.remaining)）")
    check(abs(midway.progress - 0.375) < 1e-9, "进度与剩余同源：1 − 1.25/2 = 0.375（实际 \(midway.progress)）")
    check(model.practiceRemaining == 2 && model.practicePhase == .delayBeforeAuto, "显示外推不推进状态机")
    model.pollAndPublishSnapshot()
    check(abs((model.latestPublishedMatchTime ?? -1) - 1.25) < 1e-4,
          "控制快照 matchTime 与界面剩余同源（实际 \(model.latestPublishedMatchTime.map { "\($0)" } ?? "nil")）")
    now = 1_002.5
    let atDeadline = model.practiceDisplay(at: now)
    check(atDeadline.remaining == 0 && atDeadline.progress == 1, "截止后、下一次 tick 前显示夹在 0 / 100%，不出现负数")
    model.practiceTick()
    check(model.practicePhase == .autonomous, "tick 按真实 elapsed 2.5s 进入自动阶段")
    check(abs(model.practiceRemaining - 14.5) < 1e-9,
          "跨阶段余量带入：Auto 剩余 14.5 而非满 15（实际 \(model.practiceRemaining)）")
    check(abs(model.practiceDisplay(at: now).progress - 0.5 / 15) < 1e-9,
          "进入新阶段时进度从余量对应位置开始（0.5/15），实际 \(model.practiceDisplay(at: now).progress)")
    now += 0.25
    check(abs(model.livePracticeDisplay.remaining - 14.25) < 1e-9, "livePracticeDisplay 读取注入时钟")
    // 再停顿 20s（自上次 tick 共 20.25s）：Auto 剩 14.5 → 过渡 3 → Teleop 已进行 2.75s
    now += 20
    model.practiceTick()
    check(model.practicePhase == .teleoperated && abs(model.practiceRemaining - 132.25) < 1e-9,
          "停顿跨过 Auto 与过渡后追到 Teleop 并带入余量（实际 \(model.practicePhase.rawValue) \(model.practiceRemaining)）")
    check(model.mode == .teleoperated, "模式随追赶后的阶段切换")
    // 时钟回退（防御：systemUptime 本身单调）：不推进，基点保持最后有效读数（1022.75），
    // 下一次 tick 从该读数起算，不把回退的 5s 算进比赛。
    now -= 5
    model.practiceTick()
    check(model.practicePhase == .teleoperated && abs(model.practiceRemaining - 132.25) < 1e-9, "时钟倒退不推进状态机")
    now += 5.5
    model.practiceTick()
    check(abs(model.practiceRemaining - 131.75) < 1e-9,
          "回退后下一次 tick 从最后有效读数起算：只扣 0.5s，不多扣回退的 5s（实际 \(model.practiceRemaining)）")
    // A-Stop：显示归零、不再活动、不使能
    model.aStop()
    let stopped = model.livePracticeDisplay
    check(!model.practiceActive && model.practicePhase == .finished && stopped.remaining == 0 && stopped.progress == 0,
          "A-Stop 后显示归零且不再活动")
    check(!model.enabled, "A-Stop 不使能")
    model.pollAndPublishSnapshot()
    check(model.latestPublishedMatchTime == nil, "结束后控制快照不再携带 matchTime")
    now += 100
    model.practiceTick()
    check(model.practicePhase == .finished && model.practiceRemaining == 0, "结束后 tick 空转")

    // ===== C. 时钟加固：非有限读数不推进、不污染基点；之后仍能推进而非冻结 =====
    let hardened = DSModel(settingsDefaults: suite, persistenceEnabled: false)
    var clock: TimeInterval = 2_000
    hardened.practiceClock = { clock }
    hardened.practiceSeasonYear = 2025
    hardened.practiceStartDelay = 0
    hardened.practiceAutoTime = 15
    hardened.practiceDelayTime = 3
    hardened.practiceTeleopTime = 135
    hardened.practiceCountdownSpeech = CountdownSpeechSpy()
    hardened.startPractice()
    check(hardened.practicePhase == .autonomous && hardened.practiceRemaining == 15, "0 秒开始等待直接进入 Auto")
    for bad in [Double.nan, .infinity, -.infinity] {
        clock = bad
        hardened.practiceTick()
        check(hardened.practicePhase == .autonomous && hardened.practiceRemaining == 15,
              "非有限时钟读数 \(bad) 不推进状态机（实际 \(hardened.practicePhase.rawValue) \(hardened.practiceRemaining)）")
        check(hardened.livePracticeDisplay.remaining == 15,
              "非有限读数下显示保持上次 tick 的剩余（读数 \(bad)，实际 \(hardened.livePracticeDisplay.remaining)）")
    }
    clock = 2_000.5
    hardened.practiceTick()
    check(hardened.practicePhase == .autonomous && abs(hardened.practiceRemaining - 14.5) < 1e-9,
          "非有限读数之后仍以最后有效读数为基点推进，不冻结、不跳变（实际 \(hardened.practiceRemaining)）")
    hardened.aStop()

    // 开始时读到非有限值：首个有效读数只建立基点，不把开机以来的 uptime 当成经过时间
    let badStart = DSModel(settingsDefaults: suite, persistenceEnabled: false)
    var startClock: TimeInterval = .nan
    badStart.practiceClock = { startClock }
    badStart.practiceStartDelay = 0
    badStart.practiceCountdownSpeech = CountdownSpeechSpy()
    badStart.startPractice()
    startClock = 2_000
    badStart.practiceTick()
    check(badStart.practicePhase == .autonomous && badStart.practiceRemaining == 15,
          "开始时非有限读数：首个有效 tick 只建立基点（实际 \(badStart.practiceRemaining)）")
    startClock = 2_000.5
    badStart.practiceTick()
    check(abs(badStart.practiceRemaining - 14.5) < 1e-9, "基点建立后正常推进")
    badStart.aStop()

    // ===== D. 视图刷新：进度计算必须直接使用当前帧时间戳，而不是丢弃 TimelineView 的 date =====
    let operationSource = (try? String(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/MatchSticksDriverStaion/Views/OperationView.swift"), encoding: .utf8)) ?? ""
    check(operationSource.contains("TimelineView(.animation") &&
          operationSource.contains("timeline.date.timeIntervalSinceReferenceDate") &&
          !operationSource.contains("let display = model.livePracticeDisplay"),
          "Practice progress uses the current TimelineView frame date instead of the previous model snapshot")

}
