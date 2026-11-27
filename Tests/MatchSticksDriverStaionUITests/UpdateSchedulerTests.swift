import AppKit
import DSCore

// MARK: 更新检查重试状态机行为测试（2026-11-23）
//
// 调度器是纯逻辑（无定时器、无网络）：每次输入返回一个动作，由 UpdateCenter 执行
// （探测 / 触发检查 / 计时 / 取消计时）。这里逐条覆盖：
// 启动先探测可达再检查、探测失败按有上限的指数退避重试且永不放弃、
// 网络路径变化立即唤醒、同一时刻不重复探测 / 检查、Sparkle 忙时的看门狗、
// 检查结束（无更新 / 失败 / 被闸门拒绝）后的去向。

@MainActor
func updateSchedulerTests(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void) {
    typealias Scheduler = UpdateCheckScheduler

    // ===== A. 退避表：首延 3s，逐次翻倍，上限 15 分钟 =====
    check(Scheduler.backoffDelay(attempt: 1) == 3, "first retry waits 3 seconds")
    check(Scheduler.backoffDelay(attempt: 2) == 6 && Scheduler.backoffDelay(attempt: 3) == 12 &&
          Scheduler.backoffDelay(attempt: 4) == 24, "each retry doubles the previous delay")
    check(Scheduler.backoffDelay(attempt: 9) == 768, "the ninth retry still follows the doubling")
    check(Scheduler.backoffDelay(attempt: 10) == 900 && Scheduler.backoffDelay(attempt: 11) == 900 &&
          Scheduler.backoffDelay(attempt: 50) == 900, "backoff is capped at 15 minutes")
    check(Scheduler.backoffDelay(attempt: 0) == 3 && Scheduler.backoffDelay(attempt: -3) == 3,
          "non-positive attempt counts use the initial delay")

    // ===== B. 启动：先探测 GitHub 可达，可达才触发检查；探测不重复 =====
    let s = Scheduler()
    check(s.state == .idle && !s.reachabilityConfirmed, "scheduler starts idle with reachability unconfirmed")
    check(s.requestCheck() == .probe && s.state == .probing,
          "startup requests a reachability probe, never a check")
    check(s.requestCheck() == .none && s.state == .probing,
          "a second request during a probe is folded in (no duplicate probe)")
    check(s.probeSucceeded() == .check && s.state == .checking(triggerPending: true) && s.reachabilityConfirmed,
          "a reachable probe authorizes exactly one check")
    check(s.requestCheck() == .none, "a request while a check is pending does not start another probe")

    // ===== C. 探测失败：退避等待；计时到期重新探测；再失败退避翻倍 =====
    let w = Scheduler()
    _ = w.requestCheck()
    check(w.probeFailed() == .wait(delay: 3) && w.state == .waiting(attempt: 1, delay: 3) && !w.reachabilityConfirmed,
          "an unreachable probe schedules a 3-second retry")
    check(w.timerFired() == .probe && w.state == .probing, "the backoff timer expiry probes again")
    check(w.timerFired() == .none && w.state == .probing, "a duplicate timer firing while probing does nothing")
    check(w.probeFailed() == .wait(delay: 6) && w.state == .waiting(attempt: 2, delay: 6),
          "the second failure doubles the delay")
    _ = w.timerFired()
    _ = w.probeFailed()
    check(w.state == .waiting(attempt: 3, delay: 12), "the third failure waits 12 seconds")

    // ===== D. 网络变化及时唤醒：不等退避到期；无可用路径也不取消计时（永不失去唤醒源） =====
    // Sparkle 自身不会为「无路径」回调；若取消计时后 NWPathMonitor 的 satisfied 事件丢失，
    // 调度器会无计时地停在 waiting——离线时每次到期探测快速失败并继续退避，代价只是几次 HEAD。
    let n = Scheduler()
    _ = n.requestCheck()
    _ = n.probeFailed()
    check(n.networkChanged(satisfied: false) == .none && n.state == .waiting(attempt: 1, delay: 3),
          "an unsatisfied path keeps the scheduled retry intact (never parks without a wake-up timer)")
    check(n.timerFired() == .probe && n.state == .probing,
          "the retry timer still fires after an unsatisfied path change")
    check(n.networkChanged(satisfied: true) == .none && n.state == .probing,
          "path changes during a probe are noted, never duplicated into a second probe")
    check(n.probeFailed() == .probe && n.state == .probing && n.attempt == 2,
          "a path change during a failing probe retries immediately")
    check(n.probeFailed() == .wait(delay: 12) && n.state == .waiting(attempt: 3, delay: 12),
          "once the path settles the normal backoff resumes")
    check(n.networkChanged(satisfied: true) == .probe && n.state == .probing,
          "a satisfied path wakes the probe immediately instead of waiting out the backoff")
    _ = n.probeFailed()
    check(n.networkChanged(satisfied: false) == .none && n.timerFired() == .probe && n.state == .probing,
          "after an unsatisfied path the timer still re-arms the probe")

    let quiet = Scheduler()
    check(quiet.networkChanged(satisfied: true) == .none && quiet.state == .idle,
          "path changes while idle do nothing")
    _ = quiet.requestCheck()
    check(quiet.networkChanged(satisfied: false) == .none && quiet.state == .probing,
          "an unsatisfied path during a probe only marks the flag; the probe result decides")

    // ===== E. 触发去重：Sparkle 正忙 → 看门狗有界重试，绝不静默丢弃；空闲 → 再次触发 =====
    // Sparkle 的 checkForUpdatesInBackground 在 sessionInProgress 时静默返回、无任何委托回调；
    // 启动期安装器状态探测也不是一轮周期（不会回调 didFinishUpdateCycle）。若看门狗直接放弃，
    // 调度器会卡在 checking 且本次启动不再检查（Sparkle 自己的 24h 周期只有「超期」才查）。
    let busy = Scheduler()
    _ = busy.requestCheck()
    _ = busy.probeSucceeded()
    check(busy.checkTriggerRefused() == .watchdog(delay: 1) && busy.state == .checking(triggerPending: true),
          "a busy updater keeps the trigger pending behind a 1-second watchdog")
    check(busy.requestCheck() == .none && busy.state == .checking(triggerPending: true),
          "a channel-change request while a check is pending folds into the pending trigger")
    for tick in 1...Scheduler.maximumBusyWatchdogs {
        check(busy.watchdogFired(updaterBusy: true) == .watchdog(delay: 1) && busy.state == .checking(triggerPending: true),
              "busy watchdog tick \(tick) re-arms the trigger instead of dropping it")
    }
    check(busy.watchdogFired(updaterBusy: true) == .wait(delay: Scheduler.busyGiveUpDelay) &&
          busy.state == .waiting(attempt: 0, delay: Scheduler.busyGiveUpDelay) && busy.reachabilityConfirmed,
          "after the bounded busy retries the scheduler falls back to a timed re-probe, not a callback Sparkle may never send")
    check(busy.timerFired() == .probe && busy.state == .probing, "the give-up timer brings the scheduler back to the probe path")
    check(busy.probeSucceeded() == .check && busy.reachabilityConfirmed, "a reachable re-probe re-issues the check")
    busy.checkTriggerAccepted()
    check(busy.state == .checking(triggerPending: false), "an accepted trigger clears the pending flag")
    check(busy.watchdogFired(updaterBusy: false) == .none, "no watchdog re-issues without a pending trigger")

    let reported = Scheduler()
    _ = reported.requestCheck()
    _ = reported.probeSucceeded()
    _ = reported.checkTriggerRefused()
    check(reported.checkFinished(.noUpdate) == .none && reported.state == .idle && !reported.reachabilityConfirmed,
          "Sparkle's own cycle reporting back while the trigger is pending clears it (no duplicate check)")
    check(reported.watchdogFired(updaterBusy: false) == .none, "the stale watchdog firing after that report does nothing")

    let freed = Scheduler()
    _ = freed.requestCheck()
    _ = freed.probeSucceeded()
    _ = freed.checkTriggerRefused()
    check(freed.watchdogFired(updaterBusy: false) == .check && freed.state == .checking(triggerPending: true),
          "a freed updater re-issues the check after the watchdog delay")
    freed.checkTriggerAccepted()
    check(freed.state == .checking(triggerPending: false), "an accepted trigger clears the pending flag")

    // 忙态计数在成功触发后归零：下一次被拒重新拥有完整的看门狗预算
    let again = Scheduler()
    _ = again.requestCheck()
    _ = again.probeSucceeded()
    _ = again.checkTriggerRefused()
    _ = again.watchdogFired(updaterBusy: true)
    _ = again.watchdogFired(updaterBusy: true)
    check(again.watchdogFired(updaterBusy: false) == .check, "a freed updater re-issues after several busy ticks")
    again.checkTriggerAccepted()
    _ = again.checkFinished(.noUpdate)
    _ = again.requestCheck()
    _ = again.probeSucceeded()
    _ = again.checkTriggerRefused()
    for _ in 1...Scheduler.maximumBusyWatchdogs { _ = again.watchdogFired(updaterBusy: true) }
    check(again.watchdogFired(updaterBusy: true) == .wait(delay: Scheduler.busyGiveUpDelay),
          "the busy budget is restored for a later refused trigger")

    // ===== F. 检查结束：无更新 → 静默空闲；闸门拒绝 → 立即探测；失败 → 退避重试 =====
    let fresh = Scheduler()
    _ = fresh.requestCheck()
    _ = fresh.probeSucceeded()
    fresh.checkTriggerAccepted()
    check(fresh.checkFinished(.noUpdate) == .none && fresh.state == .idle && !fresh.reachabilityConfirmed,
          "no update → quiet idle with reachability reset")
    check(fresh.checkFinished(.deniedOffline) == .probe && fresh.state == .probing,
          "Sparkle's own periodic check denied by the gate re-enters the probe path")

    let deniedWhileWaiting = Scheduler()
    _ = deniedWhileWaiting.requestCheck()
    _ = deniedWhileWaiting.probeFailed()
    check(deniedWhileWaiting.checkFinished(.deniedOffline) == .none &&
          deniedWhileWaiting.state == .waiting(attempt: 1, delay: 3),
          "a denied Sparkle cycle while already backing off keeps the scheduled retry instead of re-probing")

    let failing = Scheduler()
    _ = failing.requestCheck()
    _ = failing.probeSucceeded()
    failing.checkTriggerAccepted()
    check(failing.checkFinished(.failed) == .wait(delay: 3) && failing.state == .waiting(attempt: 1, delay: 3) &&
          !failing.reachabilityConfirmed,
          "a failed check (feed 404 / download error) backs off instead of hammering GitHub")
    check(failing.checkFinished(.failed) == .none && failing.state == .waiting(attempt: 1, delay: 3),
          "a duplicate finish while already waiting does not stack another retry")

    let deniedWhileProbing = Scheduler()
    _ = deniedWhileProbing.requestCheck()
    check(deniedWhileProbing.checkFinished(.deniedOffline) == .none && deniedWhileProbing.state == .probing,
          "a denied Sparkle cycle while a probe is already in flight adds nothing")

    // 退避在成功后归零
    let recovered = Scheduler()
    _ = recovered.requestCheck()
    _ = recovered.probeFailed()
    _ = recovered.timerFired()
    check(recovered.probeSucceeded() == .check && recovered.attempt == 0, "a successful probe resets the backoff counter")
    recovered.checkTriggerAccepted()
    check(recovered.checkFinished(.failed) == .wait(delay: 3), "the next failure starts again from the 3-second delay")

    // ===== G. 长时间离线：持续重试、退避非递减且有上限，网络随时回来都能继续 =====
    let offline = Scheduler()
    _ = offline.requestCheck()
    var delays: [TimeInterval] = []
    for _ in 0..<12 {
        let action = offline.probeFailed()
        if case .wait(let delay) = action { delays.append(delay) } else {
            check(false, "an offline probe failure must schedule a timed retry")
        }
        check(offline.timerFired() == .probe, "every backoff timer re-arms the probe")
    }
    check(delays == [3, 6, 12, 24, 48, 96, 192, 384, 768, 900, 900, 900],
          "twelve consecutive failures back off to the 15-minute cap and never give up")
    check(offline.state == .probing && !offline.reachabilityConfirmed,
          "the scheduler is still probing after many failures")
    check(offline.probeSucceeded() == .check, "the network returning at any point resumes the check")
}
