import SwiftUI
import DSCore

// Compile with the actual app model and presentation code. Never call start():
// no sockets, hardware enumeration, saved settings, or physical robot are used.
@main
struct UIStateTests {
    @MainActor static func main() {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            checks += 1
            if !condition() { failures.append(name) }
        }

        let model = DSModel()
        check(model.uiStatus == "未连接机器人", "initial status explains missing connection")
        check(!model.canEnable, "offline enable stays unavailable")
        model.setEnabled(true)
        check(!model.enabled, "offline enable request is refused")
        model.triggerEstop()
        check(model.uiStatus == "急停已锁定", "local estop is immediately visible without robot response")
        check(!model.canEnable, "estop keeps enable unavailable")
        model.resetEstop()
        check(model.uiStatus == "未连接机器人", "reset does not imply a connection")
        check(!model.enabled, "reset never enables")

        model.commState = .connected(host: "127.0.0.1")
        check(model.canEnable, "existing gate remains usable without a joystick or robot-code flag")
        check(model.uiStatus == "已失能", "connected and confirmed disabled")
        check(model.connectionDetail == "127.0.0.1", "connected address is visible")
        model.setEnabled(true)
        check(model.enabled, "enable still routes through original gate")
        check(!model.canEnable, "enabled state does not offer duplicate enable")
        check(model.uiStatus == "等待机器人使能", "request not confused with robot acknowledgement")
        model.robotStatus.enabled = true
        check(model.uiStatus.hasPrefix("已使能"), "acknowledged enabled status")
        model.setEnabled(false)
        check(model.uiStatus == "等待机器人失能", "disable awaits robot acknowledgement")
        model.robotStatus.enabled = false
        check(model.uiStatus == "已失能", "disable acknowledgement")

        model.watchdogHealthy = false
        check(model.uiStatus == "控制已冻结", "watchdog failure is visible")
        check(!model.canEnable, "watchdog gate preserved")
        model.setEnabled(true)
        check(!model.enabled, "watchdog rejects enable")
        model.watchdogHealthy = true
        model.setEnabled(true)
        model.triggerEstop()
        check(!model.enabled && model.estopEngaged, "estop removes enabled intent and latches")
        check(model.uiStatus == "急停已锁定", "estop takes precedence over pending acknowledgement")
        model.setEnabled(true)
        check(!model.enabled, "latched estop refuses enable")
        model.resetEstop()
        check(!model.enabled && !model.estopEngaged, "reset only clears local latch")
        model.robotStatus.estop = true
        check(model.uiStatus == "急停已锁定", "robot estop remains visible until acknowledgement")
        check(model.enableExplanation.contains("仍报告急停"), "remote estop explains recovery instead of implying readiness")
        model.robotStatus.estop = false
        model.robotStatus.brownout = true
        check(model.uiStatus == "电池欠压", "brownout is distinct from disabled")
        model.commState = .searching
        check(model.uiStatus == "未连接机器人", "cached brownout is not presented as current while offline")
        check(model.uiStatusColor == .secondary, "offline status does not retain stale brownout color")
        check(model.connectionDetail == "正在寻找机器人", "search state wording")
        model.robotStatus.brownout = false
        model.robotStatus.enabled = true
        check(model.uiStatus == "未连接机器人", "cached enabled telemetry cannot imply live connection")
        check(!model.uiConnectionEditingLocked, "stale enabled telemetry does not prevent reconnecting")
        model.commState = .connected(host: "127.0.0.1")
        check(model.uiConnectionEditingLocked, "live enabled acknowledgement protects connection editing")
        model.robotStatus.enabled = false
        check(!model.uiConnectionEditingLocked, "live disabled state allows connection editing")

        let practice = DSModel()
        practice.commState = .connected(host: "127.0.0.1")
        practice.startPractice()
        check(practice.practiceActive, "practice button enters original sequencer")
        check(practice.uiConnectionEditingLocked, "practice protects connection settings during delay")
        check(!practice.enabled, "practice begins with existing disabled delay")
        practice.aStop()
        check(!practice.practiceActive && !practice.enabled, "A-Stop ends practice disabled")

        // 2026-09-27 回归：机器人侧急停报告 → 呈现层压住使能（不改 SafetyGate）
        let remote = DSModel()
        remote.commState = .connected(host: "127.0.0.1")
        remote.robotStatus.estop = true
        check(remote.remoteEstopReported, "remote estop is reported while connected")
        check(remote.canEnable, "model-level gate is unchanged by presentation gating")
        remote.commState = .searching
        check(!remote.remoteEstopReported, "stale remote estop is not reported while offline")

        // 2026-09-27 回归：急停触发/复位后控制快照同步刷新（复位竞态修复，DS 侧）
        let snap = DSModel()
        snap.triggerEstop()
        check(snap.latestPublishedSnapshotEstop, "trigger publishes estop bit without waiting for the 50Hz timer")
        snap.resetEstop()
        check(!snap.latestPublishedSnapshotEstop, "reset clears the published estop bit before the request pulse")
        check(snap.enabled == false, "estop path keeps operator disabled")

        // 2026-09-27 回归：连接草稿跨导航保留（RootView 常驻 holder）
        let draft = ConnectionDraft()
        let draftModel = DSModel()
        draftModel.teamNumber = 2590
        draft.load(from: draftModel)
        check(draft.teamNumber == "2590" && !draft.userEdited, "draft loads from model without edit flag")
        draft.manualIP = "10.25.90.2"
        check(draft.userEdited, "editing marks the draft dirty")
        draft.load(from: draftModel)
        check(draft.manualIP.isEmpty && !draft.userEdited, "reload discards edits and clears the flag")

        // 更新安全门映射（Phase 4 / Sparkle 重启门）：点击时刻现场求值自 DSModel 三态
        let upd = DSModel()
        let updateBlockReason: (DSModel) -> String? = { m in
            if case .blocked(let r) = UpdateSafetyGate.evaluate(m.updateGateState) { return r }
            return nil
        }
        check(updateBlockReason(upd) == nil, "update gate allows on fresh offline disabled model")
        upd.triggerEstop()
        check(updateBlockReason(upd)?.contains("急停") == true, "estop latch blocks update restart")
        upd.resetEstop()
        upd.commState = .connected(host: "127.0.0.1")
        check(updateBlockReason(upd)?.contains("通信") == true, "active connection blocks update restart")
        upd.setEnabled(true)
        check(updateBlockReason(upd)?.contains("使能") == true, "enabled intent outranks connection as block reason")
        upd.setEnabled(false)
        check(updateBlockReason(upd)?.contains("通信") == true, "disable falls back to connection block reason")

        // 更新流状态机 + 安全门联动（Phase 4；Sparkle 集成层之外的纯逻辑回归）
        let flow = UpdateFlowModel()
        check(!flow.badgeVisible, "idle badge hidden")
        flow.beganCheck()
        check(flow.badgeVisible && flow.phase == .checking, "checking badge visible")
        flow.updateNotFound()
        check(!flow.badgeVisible && flow.phase == .idle, "no update → quiet idle")
        flow.downloadStarted(version: "9.9.9")
        check(flow.badgeVisible, "downloading badge visible")
        flow.downloadProgress(0.5)
        if case .downloading(let p, _) = flow.phase { check(abs(p - 0.5) < 1e-9, "progress tracked") } else { check(false, "downloading phase") }
        flow.downloadProgress(1.7)
        if case .downloading(let p, _) = flow.phase { check(p == 1.0, "progress clamped to 1") } else { check(false, "downloading phase after clamp") }
        check(flow.requestRestart() == .notReady, "tap before ready is ignored")
        flow.downloadCompleted(version: "9.9.9")
        check(flow.lastBlockReason == nil, "no block reason before any blocked tap")
        // 安全门阻断：使能中点击无效，且状态保持就绪（不进入安装）
        var gateState = UpdateSafetyGate.State(enabled: true, commConnected: false, estopEngaged: false)
        flow.gateStateProvider = { gateState }
        if case .blocked(let r) = flow.requestRestart() { check(r.contains("使能"), "enabled gate blocks restart") } else { check(false, "expected block while enabled") }
        check(flow.lastBlockReason?.contains("使能") == true, "block reason surfaced for tooltip")
        if case .ready = flow.phase {} else { check(false, "blocked tap keeps ready (no install)") }
        // 状态变化后同一角标可放行：现场求值（不缓存判定）
        gateState = UpdateSafetyGate.State(enabled: false, commConnected: false, estopEngaged: false)
        if case .initiated = flow.requestRestart() {} else { check(false, "gate release after state change → initiated") }
        check(flow.phase == .installing, "installing phase after allow")
        check(flow.requestRestart() == .notReady, "double tap ignored")
        // 失败静默：badge 隐藏
        let flow2 = UpdateFlowModel()
        flow2.downloadStarted(version: "x")
        flow2.failedQuietly()
        check(!flow2.badgeVisible && flow2.phase == .failed, "download failure → silent hidden state")
        // 未接安全门（gateStateProvider = nil）：保守阻断
        let flow3 = UpdateFlowModel()
        flow3.downloadCompleted(version: "x")
        if case .blocked(let r) = flow3.requestRestart() { check(r.contains("未接入"), "missing gate provider blocks conservatively") } else { check(false, "expected conservative block") }

        print("GHDS UI state: \(checks) checks, \(failures.count) failures")
        for failure in failures { print("FAIL: \(failure)") }
        exit(failures.isEmpty ? 0 : 1)
    }
}
