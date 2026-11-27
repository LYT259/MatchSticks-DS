import Foundation
import DSCore

private func countdownCues(in events: [PracticeSequencer.Event]) -> [PracticeCountdownCue] {
    events.compactMap {
        guard case .countdown(let cue) = $0 else { return nil }
        return cue
    }
}

func practiceCountdownTests() {
    check(PracticeCountdownPlan.minimumStartDelay == 5, "准备时间开启至少 5 秒")
    check(PracticeCountdownPlan.cues(for: 0).isEmpty, "0 秒关闭准备播报")
    for delay in 1..<5 {
        check(PracticeCountdownPlan.cues(for: TimeInterval(delay)).isEmpty,
              "\(delay) 秒不完整，不能开启准备播报")
    }
    check(PracticeCountdownPlan.cues(for: 5) == [.driversBehindLine, .three, .two, .one, .go],
          "5 秒完整播报 Drivers behind the line, in 3, 2, 1, go")
    check(PracticeCountdownPlan.cues(for: 6) == [.driversBehindLine, .four, .three, .two, .one, .go],
          "6 秒从 4 倒数")
    check(PracticeCountdownPlan.cues(for: 7) == [.driversBehindLine, .five, .four, .three, .two, .one, .go],
          "7 秒从 5 倒数")
    check(PracticeCountdownPlan.cues(for: 30) == [.driversBehindLine, .ten, .nine, .eight, .seven, .six,
                                                   .five, .four, .three, .two, .one, .go],
          "长等待最多从 10 倒数到 1 再 go")

    var five = PracticeSequencer(config: .init(autoTime: 20, teleopTime: 140, delayTime: 3, startDelay: 5))
    check(countdownCues(in: five.start()) == [.driversBehindLine], "开始时先说 Drivers behind the line, in")
    check(five.phase == .delayBeforeAuto && five.remaining == 5, "倒数不改变准备时长")
    check(countdownCues(in: five.tick(1.9)).isEmpty, "尚未到 3 秒时不提前报数")
    check(countdownCues(in: five.tick(0.2)) == [.three], "3 秒报 three")
    check(countdownCues(in: five.tick(0)).isEmpty, "同一阈值不重复播报")
    check(countdownCues(in: five.tick(0.9)) == [.two], "2 秒报 two")
    check(countdownCues(in: five.tick(1)) == [.one], "1 秒报 one")
    let go = five.tick(1)
    check(countdownCues(in: go) == [.go] && five.phase == .autonomous, "进入 Auto 报 go")
    check(go.contains(.enable), "倒数不改变使能事件")
    check(countdownCues(in: five.tick(0.1)).isEmpty, "Auto 后不再重复倒数")

    var seven = PracticeSequencer(config: .init(autoTime: 20, teleopTime: 140, delayTime: 3, startDelay: 7))
    _ = seven.start()
    check(countdownCues(in: seven.tick(2.1)) == [.five], "7 秒等待到剩 5 秒时报 five")
    check(countdownCues(in: seven.tick(1)) == [.four], "随后到 4 秒报 four")
    check(countdownCues(in: seven.tick(1)) == [.three], "随后到 3 秒报 three")

    var stalled = PracticeSequencer(config: .init(autoTime: 20, teleopTime: 140, delayTime: 3, startDelay: 5))
    _ = stalled.start()
    let stalledEvents = stalled.tick(5)
    check(countdownCues(in: stalledEvents) == [.go], "整段等待被错过时不补播数字，只报 go")

    var immediate = PracticeSequencer(config: .init(autoTime: 20, teleopTime: 140, delayTime: 3, startDelay: 0))
    let immediateEvents = immediate.start()
    check(countdownCues(in: immediateEvents) == [.go], "0 秒不播报准备句，只在 Auto 报 go")
    check(immediateEvents.contains(.entered(.autonomous)) && immediateEvents.contains(.enable),
          "0 秒保持立即进入 Auto 并使能")

    var restarted = PracticeSequencer(config: .init(autoTime: 20, teleopTime: 140, delayTime: 3, startDelay: 5))
    _ = restarted.start()
    _ = restarted.tick(2)
    check(countdownCues(in: restarted.start()) == [.driversBehindLine], "重新开始重新播报开头句")
}
