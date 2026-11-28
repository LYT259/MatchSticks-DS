import AppKit
import SwiftUI
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
    // 会让停顿 5.2s 跨过 5s 开始等待后仍停在「准备自动阶段」。
    let stalled = DSModel(settingsDefaults: suite, persistenceEnabled: false)
    stalled.practiceStartDelay = 5
    stalled.practiceCountdownSpeech = CountdownSpeechSpy()
    stalled.startPractice()
    check(stalled.practicePhase == .delayBeforeAuto, "练习从开始等待进入")
    Thread.sleep(forTimeInterval: 5.2)   // 模拟主线程被阻塞（拖窗口/菜单期间的同步工作）
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
    model.practiceStartDelay = 5
    model.practiceAutoTime = 15
    model.practiceDelayTime = 3
    model.practiceTeleopTime = 135
    model.practiceCountdownSpeech = CountdownSpeechSpy()
    model.startPractice()
    check(model.practicePhase == .delayBeforeAuto && model.practiceRemaining == 5, "开始练习：进入开始等待，剩余 5")
    let start = model.practiceDisplay(at: now)
    check(start.remaining == 5 && start.progress == 0, "开始瞬间显示剩余 5.0、进度 0")
    now += 0.75
    let midway = model.practiceDisplay(at: now)
    check(abs(midway.remaining - 4.25) < 1e-9,
          "两次 tick 之间显示按同一时钟外推：0.75s 后剩 4.25（实际 \(midway.remaining)）")
    check(abs(midway.progress - 0.15) < 1e-9, "进度与剩余同源：1 − 4.25/5 = 0.15（实际 \(midway.progress)）")
    check(model.practiceRemaining == 5 && model.practicePhase == .delayBeforeAuto, "显示外推不推进状态机")
    model.pollAndPublishSnapshot()
    check(abs((model.latestPublishedMatchTime ?? -1) - 4.25) < 1e-4,
          "控制快照 matchTime 与界面剩余同源（实际 \(model.latestPublishedMatchTime.map { "\($0)" } ?? "nil")）")
    now = 1_005.5
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

    // ===== D. 真实窗口：显示帧必须读取与 Practice 相同的单调时钟并连续推进 =====
    hostedPracticeFrameTests(check, settings: suite)
}

private struct HostedPracticeGeometry {
    let columns: Range<Int>
    let contentWidth: Double
}

@MainActor
private func hostedPracticeFrameTests(
    _ check: @MainActor (@autoclosure () -> Bool, String) -> Void,
    settings: UserDefaults
) {
    NSApplication.shared.finishLaunching()
    let previousPolicy = NSApplication.shared.activationPolicy()
    NSApplication.shared.setActivationPolicy(.regular)

    let model = DSModel(settingsDefaults: settings, persistenceEnabled: false)
    model.practiceSeasonYear = 2025
    model.practiceStartDelay = 2
    model.soundsEnabled = false
    model.enableDisableSoundsEnabled = false
    model.practiceCountdownSpeech = CountdownSpeechSpy()

    let width = 1_200
    let height = 360
    let host = NSHostingView(rootView: OperationView(model: model)
        .frame(width: CGFloat(width), height: CGFloat(height))
        .background(DSTheme.canvas))
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    window.isReleasedWhenClosed = false
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    defer {
        model.aStop()
        window.orderOut(nil)
        window.close()
        NSApplication.shared.setActivationPolicy(previousPolicy)
    }

    func snapshot() -> NSBitmapImageRep? {
        NSApplication.shared.updateWindows()
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        host.cacheDisplay(in: host.bounds, to: bitmap)
        NSGraphicsContext.current = nil
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    guard let initial = snapshot(), let geometry = hostedPracticeGeometry(in: initial) else {
        check(false, "hosted Practice view exposes its real duration-card and progress-bar geometry")
        return
    }
    model.startPractice()
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    let hostedViews = descendants(host)
    let progressIndicator = hostedViews.compactMap { $0 as? NSProgressIndicator }.first
    var lastBitmap: NSBitmapImageRep?

    var samples: [(at: TimeInterval, progress: Double)] = []
    var captureFailed = false
    let samplingStart = ProcessInfo.processInfo.systemUptime
    func capture() {
        if let progressIndicator {
            samples.append((ProcessInfo.processInfo.systemUptime, progressIndicator.doubleValue))
            return
        }
        guard let bitmap = snapshot() else {
            captureFailed = true
            return
        }
        samples.append((ProcessInfo.processInfo.systemUptime,
                        hostedPracticeProgress(in: bitmap, geometry: geometry)))
        lastBitmap = bitmap
    }
    let sampleTimer = Timer(timeInterval: 0.008, repeats: true) { _ in
        MainActor.assumeIsolated { capture() }
    }
    RunLoop.main.add(sampleTimer, forMode: .common)
    let stopTimer = Timer(timeInterval: 0.6, repeats: false) { _ in
        MainActor.assumeIsolated {
            NSApplication.shared.stop(nil)
            let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                                           modifierFlags: [], timestamp: 0, windowNumber: 0,
                                           context: nil, subtype: 0, data1: 0, data2: 0)
            if let event { NSApplication.shared.postEvent(event, atStart: true) }
        }
    }
    RunLoop.main.add(stopTimer, forMode: .common)
    NSApplication.shared.run()
    sampleTimer.invalidate()
    stopTimer.invalidate()
    if let finalBitmap = snapshot() { lastBitmap = finalBitmap }
    if captureFailed {
        check(false, "hosted Practice view can be sampled during a real practice")
        return
    }
    if let lastBitmap { saveHostedPracticeReview(lastBitmap, name: "practice-last") }

    let description = samples.map { String(format: "%.3f@%.3fs", $0.progress, $0.at - samplingStart) }
        .joined(separator: ", ")
    print("Hosted Practice progress samples: \(description)")
    guard let first = samples.first, let last = samples.last else {
        check(false, "hosted Practice view produces real frame samples")
        return
    }

    var advanceTimes: [TimeInterval] = []
    for (previous, current) in zip(samples, samples.dropFirst()) where current.progress > previous.progress + 0.001 {
        advanceTimes.append(current.at)
    }
    let elapsed = last.at - first.at
    let advanceRate = elapsed > 0 ? Double(advanceTimes.count) / elapsed : 0
    let closeAdvances = zip(advanceTimes, advanceTimes.dropFirst()).contains { $1 - $0 < 0.09 }
    let regresses = zip(samples, samples.dropFirst()).contains { $1.progress + 0.02 < $0.progress }

    check(samples.count >= 8, "real TimelineView frames are sampled during the hosted Practice run")
    check(first.at - samplingStart < 0.3 && first.progress < 0.5,
          "hosted Practice's first sample is early and does not jump to full (actual \(first.progress) at \(first.at - samplingStart)s)")
    check(last.progress >= first.progress + 0.10,
          "hosted Practice visibly advances during real display-frame sampling (actual \(first.progress) → \(last.progress))")
    check(advanceRate > 12 && closeAdvances,
          "hosted Practice progress advances on display frames, not only the 10 Hz Practice tick (actual \(advanceRate) Hz)")
    check(!regresses, "hosted Practice progress remains monotonic between display frames")
    check(abs(last.progress - model.livePracticeDisplay.progress) < 0.12,
          "hosted native indicator uses the model's real systemUptime clock domain (rendered \(last.progress), model \(model.livePracticeDisplay.progress))")
}

private func saveHostedPracticeReview(_ bitmap: NSBitmapImageRep, name: String) {
    guard let directory = ProcessInfo.processInfo.environment["MATCHSTICKS_DRIVER_STAION_RENDER_REVIEW"],
          let data = bitmap.representation(using: .png, properties: [:]) else { return }
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try? data.write(to: root.appendingPathComponent("\(name).png"))
}

private func hostedPracticeGeometry(in bitmap: NSBitmapImageRep) -> HostedPracticeGeometry? {
    for y in 0..<bitmap.pixelsHigh {
        var navyColumns: [Int] = []
        var blueColumns: [Int] = []
        var hasRed = false
        var hasYellow = false
        for x in (bitmap.pixelsWide / 2)..<bitmap.pixelsWide {
            if hostedPracticePixel(bitmap, x: x, y: y, hex: 0x131F25) { navyColumns.append(x) }
            if hostedPracticePixel(bitmap, x: x, y: y, hex: 0x007BC0) { blueColumns.append(x) }
            if hostedPracticePixel(bitmap, x: x, y: y, hex: 0xC81623) { hasRed = true }
            if hostedPracticePixel(bitmap, x: x, y: y, hex: 0xF2D14B) { hasYellow = true }
        }
        if navyColumns.count > 30, blueColumns.count > 30, !hasRed, !hasYellow,
           let left = navyColumns.min(), let right = blueColumns.max(), right - left > 200 {
            return HostedPracticeGeometry(columns: left..<(right + 1), contentWidth: Double(right - left + 1))
        }
    }
    return nil
}

private func hostedPracticeProgress(in bitmap: NSBitmapImageRep, geometry: HostedPracticeGeometry) -> Double {
    var longestRun = 0
    for y in 0..<bitmap.pixelsHigh {
        var run = 0
        for x in geometry.columns {
            if hostedPracticePixel(bitmap, x: x, y: y, hex: 0x007AFF) ||
                hostedPracticePixel(bitmap, x: x, y: y, hex: 0xAAAAAA) {
                run += 1
                longestRun = max(longestRun, run)
            } else {
                run = 0
            }
        }
    }
    return min(1, Double(longestRun) / geometry.contentWidth)
}

private func hostedPracticePixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int, hex: UInt32) -> Bool {
    guard let bytes = bitmap.bitmapData else { return false }
    let offset = y * bitmap.bytesPerRow + x * 4
    let red = Int((hex >> 16) & 0xFF)
    let green = Int((hex >> 8) & 0xFF)
    let blue = Int(hex & 0xFF)
    return abs(Int(bytes[offset]) - red) <= 6 &&
        abs(Int(bytes[offset + 1]) - green) <= 6 &&
        abs(Int(bytes[offset + 2]) - blue) <= 6
}
