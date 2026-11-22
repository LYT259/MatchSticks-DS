import Foundation
@testable import DSCore

func timeoutSequencerTests() {
    var sequence = TimeoutSequencer()
    check(sequence.duration == 480 && sequence.warningTime == 60, "2022 Timeout 默认 8 分钟，剩余 1 分钟提示")
    check(sequence.start() == [.started] && sequence.phase == .running && sequence.remaining == 480,
          "Timeout 开始只进入计时，不使能机器人")
    for _ in 0..<4199 { _ = sequence.tick(0.1) }
    check(abs(sequence.remaining - 60.1) < 0.001, "Timeout 提示前保持准确倒计时")
    check(sequence.tick(0.1) == [.warning] && abs(sequence.remaining - 60) < 0.001,
          "Timeout 剩余 60 秒发一次警告")
    check(sequence.tick(0.1).isEmpty, "Timeout 警告不重复")
    for _ in 0..<598 { _ = sequence.tick(0.1) }
    check(sequence.tick(0.1) == [.finished] && sequence.phase == .finished && sequence.remaining == 0,
          "Timeout 归零只发结束事件，不自动开始比赛")
    check(sequence.tick(0.1).isEmpty, "Timeout 结束后空转")

    var short = TimeoutSequencer(duration: 60)
    check(short.start() == [.started, .warning], "缩短测试在起点立即发一次警告")
    check(short.tick(0.1).isEmpty, "起点警告之后仍不重复")

    short.cancel()
    check(short.phase == .idle && short.remaining == 0, "取消 Timeout 回到空闲并清零")
    check(short.tick(0.1).isEmpty, "取消后不再产生提示或结束事件")
}
