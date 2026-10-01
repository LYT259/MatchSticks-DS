// MARK: Phase 4：更新安全门全状态矩阵 + WebUI/摄像头/rumble（后续阶段并入本文件）

import DSCore

func updateSafetyGateMatrix() {
    // 全 8 组合：仅 (失能, 未连接, 无锁存) 放行
    let cases: [(Bool, Bool, Bool, UpdateSafetyGate.Decision, String)] = [
        (false, false, false, .allow, "唯一放行：失能+未连接+无锁存"),
        (true,  false, false, .blocked(reason: ""), "使能即阻断"),
        (false, true,  false, .blocked(reason: ""), "连接即阻断"),
        (false, false, true,  .blocked(reason: ""), "急停锁存即阻断"),
        (true,  true,  false, .blocked(reason: ""), "使能+连接"),
        (true,  false, true,  .blocked(reason: ""), "使能+锁存"),
        (false, true,  true,  .blocked(reason: ""), "连接+锁存"),
        (true,  true,  true,  .blocked(reason: ""), "三态全真"),
    ]
    for (enabled, connected, estop, expected, label) in cases {
        let decision = UpdateSafetyGate.evaluate(.init(
            enabled: enabled, commConnected: connected, estopEngaged: estop))
        switch (decision, expected) {
        case (.allow, .allow):
            check(true, label)
        case (.blocked(let r), .blocked):
            check(!r.isEmpty, "\(label)：阻断原因非空")
        default:
            check(false, "\(label)：期望 \(expected)，得到 \(decision)")
        }
    }
}

func updateSafetyGateReasonPrecedence() {
    // 阻断原因优先级：使能 > 连接 > 急停锁存（多条同时满足时报最显著的一条）
    guard case .blocked(let r1) = UpdateSafetyGate.evaluate(.init(enabled: true, commConnected: true, estopEngaged: true)) else {
        check(false, "三态全真应阻断"); return
    }
    check(r1.contains("使能"), "优先报使能中（得到：\(r1)）")
    guard case .blocked(let r2) = UpdateSafetyGate.evaluate(.init(enabled: false, commConnected: true, estopEngaged: true)) else {
        check(false, "连接+锁存应阻断"); return
    }
    check(r2.contains("通信"), "其次报通信活跃（得到：\(r2)）")
    guard case .blocked(let r3) = UpdateSafetyGate.evaluate(.init(enabled: false, commConnected: false, estopEngaged: true)) else {
        check(false, "仅锁存应阻断"); return
    }
    check(r3.contains("急停"), "最后报急停锁存（得到：\(r3)）")
}

func updateSafetyGateBlockingDrivesUiState() {
    // 放行/阻断的可判定性：Decision 可判等（UI 干测试据此断言角标可点态）
    check(UpdateSafetyGate.evaluate(.init(enabled: false, commConnected: false, estopEngaged: false)) == .allow,
          "失能+未连接+无锁存 == .allow")
    check(UpdateSafetyGate.evaluate(.init(enabled: true, commConnected: false, estopEngaged: false)) != .allow,
          "任一为真 != .allow")
}

func runAllPhase4Tests() {
    runTest("updateSafetyGateMatrix", updateSafetyGateMatrix)
    runTest("updateSafetyGateReasonPrecedence", updateSafetyGateReasonPrecedence)
    runTest("updateSafetyGateBlockingDrivesUiState", updateSafetyGateBlockingDrivesUiState)
}
