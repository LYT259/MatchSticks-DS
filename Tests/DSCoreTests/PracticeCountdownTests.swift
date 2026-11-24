import DSCore

private func countdownCues(in events: [PracticeSequencer.Event]) -> [PracticeCountdownCue] {
    events.compactMap {
        guard case .countdown(let cue) = $0 else { return nil }
        return cue
    }
}

func practiceCountdownTests() {
    // MARK: 长等待：到 3 秒才开始，三个数字与 go 各一次

    var longWait = PracticeSequencer(config: .init(autoTime: 20, teleopTime: 140,
                                                    delayTime: 3, startDelay: 5))
    check(countdownCues(in: longWait.start()).isEmpty, "5 秒等待开始时不提前报数")
    check(longWait.phase == .delayBeforeAuto && longWait.remaining == 5,
          "倒数不改变用户开始等待时长")
    check(countdownCues(in: longWait.tick(1.9)).isEmpty, "剩余 3 秒之前保持安静")
    check(countdownCues(in: longWait.tick(0.2)) == [.three], "跨过 3 秒只报 three")
    check(countdownCues(in: longWait.tick(0)).isEmpty, "同一阈值重复 tick 不重复报数")
    check(countdownCues(in: longWait.tick(0.9)) == [.two], "跨过 2 秒报 two")
    check(countdownCues(in: longWait.tick(1)) == [.one], "跨过 1 秒报 one")
    let goEvents = longWait.tick(1)
    check(countdownCues(in: goEvents) == [.go] && longWait.phase == .autonomous,
          "进入 Autonomous 报 go")
    check(goEvents.contains(.enable), "倒数事件保留 Auto 使能事件")
    check(countdownCues(in: longWait.tick(0.1)).isEmpty, "Auto 期间不再重复倒数")
    check(longWait.config.startDelay == 5, "倒数不修改配置")

    // MARK: 跨 tick / 大步延迟：只报当前数字，不补播早已错过的数字

    var crossed = PracticeSequencer(config: .init(autoTime: 20, teleopTime: 140,
                                                    delayTime: 3, startDelay: 5))
    _ = crossed.start()
    check(countdownCues(in: crossed.tick(1.9)).isEmpty, "大步 tick 尚未到 3 秒不报数")
    check(countdownCues(in: crossed.tick(0.2)) == [.three], "3.1→2.9 的跨 tick 正常报 three")
    check(countdownCues(in: crossed.tick(1.95)) == [.one], "2.9→0.95 跳过 two，只报当前 one")
    check(countdownCues(in: crossed.tick(0.95)) == [.go], "延迟 tick 最终仍进入 Auto 并报 go")

    var stalled = PracticeSequencer(config: .init(autoTime: 20, teleopTime: 140,
                                                   delayTime: 3, startDelay: 5))
    _ = stalled.start()
    let stalledEvents = stalled.tick(5)
    check(countdownCues(in: stalledEvents) == [.go] && stalled.phase == .autonomous,
          "整段等待被错过时不补播 three/two/one，只报 go")

    // MARK: 短等待：使用实际可用时间；0 等待至少有 go

    var threeWait = PracticeSequencer(config: .init(autoTime: 20, teleopTime: 140,
                                                     delayTime: 3, startDelay: 3))
    check(countdownCues(in: threeWait.start()) == [.three], "恰好 3 秒等待立即报 three")

    var twoWait = PracticeSequencer(config: .init(autoTime: 20, teleopTime: 140,
                                                   delayTime: 3, startDelay: 2))
    check(countdownCues(in: twoWait.start()) == [.two], "2 秒等待不补播 three，立即报 two")
    check(countdownCues(in: twoWait.tick(1)) == [.one], "2 秒等待在 1 秒阈值报 one")
    check(countdownCues(in: twoWait.tick(1)) == [.go], "2 秒等待最终报 go")

    var shortWait = PracticeSequencer(config: .init(autoTime: 20, teleopTime: 140,
                                                     delayTime: 3, startDelay: 0.5))
    check(countdownCues(in: shortWait.start()) == [.one], "不足 1 秒只报 one")
    check(countdownCues(in: shortWait.tick(0.5)) == [.go], "不足 1 秒仍最终报 go")

    var immediate = PracticeSequencer(config: .init(autoTime: 20, teleopTime: 140,
                                                     delayTime: 3, startDelay: 0))
    let immediateEvents = immediate.start()
    check(countdownCues(in: immediateEvents) == [.go], "0 等待至少报 go")
    check(immediateEvents.contains(.entered(.autonomous)) && immediateEvents.contains(.enable),
          "0 等待保持立即进入 Auto 并使能")

    // MARK: 重新开始是新练习：允许新一轮完整倒数

    var restarted = PracticeSequencer(config: .init(autoTime: 20, teleopTime: 140,
                                                     delayTime: 3, startDelay: 2))
    _ = restarted.start()
    _ = restarted.tick(1)
    _ = restarted.tick(1)
    check(countdownCues(in: restarted.start()) == [.two], "重新开始重置上一轮倒数状态")
}
