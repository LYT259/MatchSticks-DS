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

        // ===== OM5P UI stall / 控制环性能回归（2026-11-14）=====

        // ① Diag 常驻输出句柄 + HeartbeatBox 停滞探针
        let diagPath = NSTemporaryDirectory() + "ghds-diag-\(UUID().uuidString).log"
        check(Diag.setFileOutput(path: diagPath), "diag file output opens")
        Diag.write("line-one")
        Diag.write("line-two")
        let diagText = (try? String(contentsOf: URL(fileURLWithPath: diagPath), encoding: .utf8)) ?? ""
        check(diagText.contains("line-one\nline-two"), "diag appends lines in order without truncation")
        try? FileManager.default.removeItem(atPath: diagPath)
        Diag.write("after-unlink")
        check(!FileManager.default.fileExists(atPath: diagPath), "diag handle persists instead of reopening per line")

        let hb = HeartbeatBox()
        let stallPath = NSTemporaryDirectory() + "ghds-diag-stall-\(UUID().uuidString).log"
        Diag.setFileOutput(path: stallPath)
        hb.beat()
        Thread.sleep(forTimeInterval: 0.15)
        hb.beat()
        let stallText = (try? String(contentsOf: URL(fileURLWithPath: stallPath), encoding: .utf8)) ?? ""
        check(stallText.contains("UI stall"), "heartbeat stall probe still fires after a >100ms gap")
        check(hb.ageSeconds() < 0.05, "heartbeat age resets on beat")

        // 并发追加原子性：两线程各 200 行，O_APPEND 单次 write(2) 不丢行、不撕裂
        let linesBefore = stallText.split(separator: "\n").count
        let writeGroup = DispatchGroup()
        for t in 0..<2 {
            writeGroup.enter()
            DispatchQueue.global().async {
                defer { writeGroup.leave() }
                for i in 0..<200 { Diag.write("thread\(t) line\(i)") }
            }
        }
        check(writeGroup.wait(timeout: .now() + 10) == .success, "concurrent diag writes complete without deadlock")
        let afterText = (try? String(contentsOf: URL(fileURLWithPath: stallPath), encoding: .utf8)) ?? ""
        let afterLines = afterText.split(separator: "\n")
        check(afterLines.count == linesBefore + 400, "concurrent appends lose no lines (atomic append)")
        check(afterLines.allSatisfy { $0.hasPrefix("UI stall") || $0.hasPrefix("thread") }, "no torn lines under concurrent append")

        // 并发 beat 风暴（快速连打，不触阈）：无死锁、ageSeconds 仍即时可读
        let hb2 = HeartbeatBox()
        let stormGroup = DispatchGroup()
        for _ in 0..<2 {
            stormGroup.enter()
            DispatchQueue.global().async {
                defer { stormGroup.leave() }
                for _ in 0..<2000 { hb2.beat() }
            }
        }
        check(stormGroup.wait(timeout: .now() + 10) == .success, "concurrent beat storm completes without deadlock")
        check(hb2.ageSeconds() < 0.5, "ageSeconds answers after the beat storm")

        // 逐跳越阈：每个 >100ms 的 beat 都留一行 stall 记录（探针行为回归）
        let hb3 = HeartbeatBox()
        hb3.beat()
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.105)
            hb3.beat()
        }
        let finalStallText = (try? String(contentsOf: URL(fileURLWithPath: stallPath), encoding: .utf8)) ?? ""
        let stallLines = finalStallText.split(separator: "\n").filter { $0.hasPrefix("UI stall") }
        check(stallLines.count >= 31, "every over-threshold beat leaves a stall line")
        check(stallLines.allSatisfy { $0.hasSuffix("ms") }, "stall lines keep their format")

        // ② 手柄：控制快照逐 tick（50Hz）刷新；SwiftUI 可见值 ~10Hz 节流
        final class StickFeed {
            var primary: Float = 0
            var secondary: Float?
            var devices: [HIDDeviceSnapshot] {
                var list = [HIDDeviceSnapshot(uniqueID: "a1:11:s", name: "Bench Stick", vendorID: 0x045E, productID: 0x028E,
                                              axes: [primary], axisUsages: [0x30], buttons: 1, buttonCount: 1,
                                              povs: [], isXbox: true)]
                if let secondary {
                    list.append(HIDDeviceSnapshot(uniqueID: "b2:22:s", name: "Second Stick", vendorID: 0x046D, productID: 0xC215,
                                                  axes: [secondary], axisUsages: [0x30], buttons: 0, buttonCount: 0,
                                                  povs: [], isXbox: false))
                }
                return list
            }
        }

        let jm = DSModel()
        let feed = StickFeed()
        jm.hidPoller = { feed.devices }
        feed.primary = 0.1
        jm.pollAndPublishSnapshot()
        check(jm.joystickSlots.count == 1 && jm.joystickSlots[0].axes.first == 0.1, "first poll publishes the visible slot immediately")
        check(jm.latestPublishedJoysticks.first?.axes.first == 0.1, "control snapshot follows the first poll")
        feed.primary = 0.9
        jm.pollAndPublishSnapshot()
        check(jm.latestPublishedJoysticks.first?.axes.first == 0.9, "control snapshot refreshes on every poll (50Hz control path intact)")
        check(jm.joystickSlots[0].axes.first == 0.1, "visible joystick value is throttled inside the 100ms window")
        Thread.sleep(forTimeInterval: 0.11)
        feed.primary = 0.5
        jm.pollAndPublishSnapshot()
        check(jm.joystickSlots[0].axes.first == 0.5, "visible value catches up after the throttle window")
        check(jm.latestPublishedJoysticks.first?.axes.first == 0.5, "control snapshot stays current after the window")

        // 结构操作不受值节流影响：设备加入与槽位锁定立即发布（过了 0.5s 重扫防抖后）
        Thread.sleep(forTimeInterval: 0.55)
        feed.secondary = 0.2
        jm.pollAndPublishSnapshot()
        check(jm.joystickSlots.count == 2, "device arrival publishes structure immediately")
        jm.toggleLock(0)
        check(jm.joystickSlots[0].lockedDeviceID != nil, "slot locking is immediately visible")

        // 发布速率边界：~20ms 节拍连打 25 次，可见值 ~10Hz、控制快照 25/25
        let jmRate = DSModel()
        let feedRate = StickFeed()
        jmRate.hidPoller = { feedRate.devices }
        var visibleChanges = 0
        var lastVisible: Float?
        let rateStart = Date()
        for i in 0..<25 {
            feedRate.primary = Float(i)
            jmRate.pollAndPublishSnapshot()
            if jmRate.joystickSlots.first?.axes.first != lastVisible {
                visibleChanges += 1
                lastVisible = jmRate.joystickSlots.first?.axes.first
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let rateElapsed = max(Date().timeIntervalSince(rateStart), 0.001)
        let visibleRate = Double(visibleChanges) / rateElapsed
        check(visibleRate <= 20, "visible joystick publish rate stays capped near 10Hz (was 50Hz)")
        check(visibleRate >= 3, "visible joystick values keep refreshing")
        check(jmRate.latestPublishedJoysticks.first?.axes.first == 24, "control snapshot tracked all 25 polls")

        // ③ Mac 状态重采样在后台：主线程睡眠（不跑 runloop）期间采样仍推进
        let sampler = MacStatusMonitor.BackgroundSampler()
        sampler.start()
        Thread.sleep(forTimeInterval: 1.3)
        let macSnap = sampler.latest
        check(macSnap != nil, "mac status sampled while the main thread stayed blocked")
        check(macSnap.map { $0.systemCPUPercent >= 0 && $0.systemCPUPercent <= 100 } == true, "cpu percent stays a valid percentage")
        sampler.stop()

        // ④ 定时器直连主线程（不再逐 tick 包 Task）：runloop 驱动 轮询→快照→节流发布 全链路
        let jmRun = DSModel()
        jmRun.dslogEnabled = false   // 测试不落盘会话日志
        let feedRun = StickFeed()
        feedRun.primary = 0.25
        jmRun.hidPoller = { feedRun.devices }
        jmRun.installTimers()
        let runDeadline = Date().addingTimeInterval(0.3)
        while Date() < runDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        check(jmRun.joystickSlots.count == 1 && jmRun.joystickSlots[0].axes.first == 0.25, "timer-driven polling populates the visible slot")
        check(jmRun.latestPublishedJoysticks.first?.axes.first == 0.25, "timer-driven polling feeds the control snapshot")
        try? FileManager.default.removeItem(atPath: stallPath)

        print("GHDS UI state: \(checks) checks, \(failures.count) failures")
        for failure in failures { print("FAIL: \(failure)") }
        exit(failures.isEmpty ? 0 : 1)
    }
}
