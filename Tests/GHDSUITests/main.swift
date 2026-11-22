import AppKit
import SwiftUI
import DSCore

fileprivate final class FocusTestProbe: NSObject, NSTextFieldDelegate {
    var textEditingEndedCount = 0
    var buttonActionCount = 0

    func controlTextDidEndEditing(_ notification: Notification) {
        textEditingEndedCount += 1
    }

    @objc func focusButtonClicked(_ sender: NSButton) {
        buttonActionCount += 1
    }
}

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
        check(DSTheme.allianceRed == DSTheme.danger &&
              [AllianceStation.red1, .red2, .red3].allSatisfy { DSTheme.allianceColor(for: $0) == DSTheme.danger },
              "red alliance selections use semantic danger color")
        check(DSTheme.allianceBlue == DSTheme.accent &&
              [AllianceStation.blue1, .blue2, .blue3].allSatisfy { DSTheme.allianceColor(for: $0) == DSTheme.accent },
              "blue alliance selections use semantic accent color")
        check(renderedAllianceSelectionMatches(.red1, red: 1, green: 59 / 255, blue: 48 / 255),
              "rendered red selection uses semantic danger pixels")
        check(renderedAllianceSelectionMatches(.blue1, red: 0, green: 122 / 255, blue: 1),
              "rendered blue selection uses semantic accent pixels")
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
        check(model.uiStatusColor == DSTheme.textSecondary, "offline status does not retain stale brownout color")
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

        // E-Stop 全场雾号：首次触发立即播放，锁存期间不叠放，复位本身静音
        let estopAudio = DSModel(settingsDefaults: makeSuite("ghds.uitests.estop-audio"), persistenceEnabled: false)
        var estopAudioPlayCount = 0
        estopAudio.estopSoundPlayer = { estopAudioPlayCount += 1 }
        estopAudio.triggerEstop()
        check(estopAudioPlayCount == 1 && estopAudio.estopEngaged, "E-Stop plays the field foghorn immediately")
        estopAudio.triggerEstop()
        check(estopAudioPlayCount == 1, "latched E-Stop does not replay the foghorn")
        estopAudio.resetEstop()
        check(estopAudioPlayCount == 1, "E-Stop reset stays silent")
        estopAudio.triggerEstop()
        check(estopAudioPlayCount == 2, "a new E-Stop after reset plays the foghorn again")

        // 2026-09-27 回归：连接草稿跨导航保留（RootView 常驻 holder）
        let draft = ConnectionDraft()
        let draftModel = DSModel()
        draftModel.teamNumber = 2590
        draft.load(from: draftModel)
        check(draft.targetText == "2590" && !draft.userEdited, "draft loads from model without edit flag")
        draft.targetText = "10.25.90.2"
        check(draft.userEdited, "editing marks the draft dirty")
        draft.load(from: draftModel)
        check(draft.targetText == "2590" && !draft.userEdited, "reload discards edits and clears the flag")

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
                                              povs: [], isXbox: true, mode: .directInput,
                                              polarity: GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: false),
                                              usbLocationID: nil)]
                if let secondary {
                    list.append(HIDDeviceSnapshot(uniqueID: "b2:22:s", name: "Second Stick", vendorID: 0x046D, productID: 0xC215,
                                                  axes: [secondary], axisUsages: [0x30], buttons: 0, buttonCount: 0,
                                                  povs: [], isXbox: false, mode: .directInput,
                                                  polarity: GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: false),
                                                  usbLocationID: nil))
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

        // 结构操作不受值节流影响：设备加入立即发布（过了 0.5s 重扫防抖后）
        Thread.sleep(forTimeInterval: 0.55)
        feed.secondary = 0.2
        jm.pollAndPublishSnapshot()
        check(jm.joystickSlots.count == 2, "device arrival publishes structure immediately")

        // 手动座次权威：上移后过了 0.5s 重扫防抖窗口也不回弹（回归：曾按 uniqueID 整体重排）
        jm.moveSlot(1, up: true)
        check(jm.joystickSlots[0].uniqueID == "b2:22:s" && jm.joystickSlots[1].uniqueID == "a1:11:s",
              "moveSlot swaps immediately")
        Thread.sleep(forTimeInterval: 0.55)
        jm.pollAndPublishSnapshot()
        check(jm.joystickSlots[0].uniqueID == "b2:22:s" && jm.joystickSlots[1].uniqueID == "a1:11:s",
              "manual seat order survives the rescan debounce window")

        // 拔出再插回：离线设备保留座次（Second Stick 回 0 号），在场设备顺延
        feed.secondary = nil
        Thread.sleep(forTimeInterval: 0.55)
        jm.pollAndPublishSnapshot()
        check(jm.joystickSlots.count == 1 && jm.joystickSlots[0].uniqueID == "a1:11:s",
              "device removal compacts slots without reshuffling")
        feed.secondary = 0.3
        Thread.sleep(forTimeInterval: 0.55)
        jm.pollAndPublishSnapshot()
        check(jm.joystickSlots.count == 2 && jm.joystickSlots[0].uniqueID == "b2:22:s" && jm.joystickSlots[1].uniqueID == "a1:11:s",
              "returning device reclaims its remembered seat")

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

        // 皮肤状态提取不得改变发往机器人的原始输入（DualSense / F310 D 档）
        let outputSnapshots = [
            HIDDeviceSnapshot(uniqueID: "dualsense-test", name: "DualSense Wireless Controller",
                              vendorID: 0x054C, productID: 0x0CE6,
                              axes: [0.25, -0.8, -0.5, 0.9, 0, 0],
                              axisUsages: [0x30, 0x31, 0x32, 0x35, 0x33, 0x34],
                              buttons: 1 << 1, buttonCount: 14, povs: [90], isXbox: false,
                              mode: .directInput,
                              polarity: GamepadProfile.displayPolarity(vendorID: 0x054C, productID: 0x0CE6,
                                                                       name: "DualSense Wireless Controller", xinputNormalized: false),
                              usbLocationID: 0x100),
            HIDDeviceSnapshot(uniqueID: "f310-d-test", name: "Logitech Dual Action",
                              vendorID: 0x046D, productID: 0xC216,
                              axes: [0.75, -0.8, -0.5, 0.9],
                              axisUsages: [0x30, 0x31, 0x32, 0x35],
                              buttons: 1 << 0, buttonCount: 12, povs: [270], isXbox: false,
                              mode: .directInput,
                              polarity: GamepadProfile.displayPolarity(vendorID: 0x046D, productID: 0xC216,
                                                                       name: "Logitech Dual Action", xinputNormalized: false),
                              usbLocationID: 0x200),
        ]
        for snapshot in outputSnapshots {
            let slot = JoystickSlot(index: 0, device: snapshot)
            let originalAxes = slot.data.axes
            let originalButtons = slot.data.buttons
            let originalPOVs = slot.data.povs
            let skin = GamepadProfile.detect(vendorID: snapshot.vendorID, productID: snapshot.productID, name: snapshot.name)
            _ = GamepadLayout.layout(for: skin, mode: snapshot.mode).state(for: GamepadSample(slot: slot))
            check(slot.data.axes == originalAxes, "\(snapshot.name) 皮肤提取不改变原始轴")
            check(slot.data.buttons == originalButtons, "\(snapshot.name) 皮肤提取不改变按钮")
            check(slot.data.povs == originalPOVs, "\(snapshot.name) 皮肤提取不改变 POV")
        }

        f310XInputReportTests(check)
        f310XInputLifecycleTests(check)
        gamepadArtworkTests(check)
        gamepadTriggerRangeTests(check)

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

        // ===== 设置域隔离 / manualIP 持久化 / 已应用地址警告 / 状态日志（2026-11-21）=====

        let suiteNames = (0..<12).map { _ in "ghds.uitests.\(UUID().uuidString)" }
        func makeSuite(_ name: String) -> UserDefaults { UserDefaults(suiteName: name)! }

        // ⑤ GHDS_SETTINGS_SUITE 解析：非空有效 → 独立 suite；空白/缺失 → 标准域
        let envSuite = DSModel.resolvedSettingsDefaults(environment: ["GHDS_SETTINGS_SUITE": suiteNames[0]])
        envSuite.set("probe", forKey: "ghds.envProbe")
        check(UserDefaults(suiteName: suiteNames[0])?.string(forKey: "ghds.envProbe") == "probe",
              "GHDS_SETTINGS_SUITE resolves to an isolated user defaults suite")
        check(DSModel.resolvedSettingsDefaults(environment: ["GHDS_SETTINGS_SUITE": "   "]) === UserDefaults.standard,
              "blank GHDS_SETTINGS_SUITE falls back to standard defaults")
        check(DSModel.resolvedSettingsDefaults(environment: [:]) === UserDefaults.standard,
              "missing GHDS_SETTINGS_SUITE falls back to standard defaults")

        // ⑥ manualIP didSet：启用持久化时保存/清除；禁用时不动已有值，但内存仍更新
        let persistSuite = makeSuite(suiteNames[1])
        let persistModel = DSModel(settingsDefaults: persistSuite, persistenceEnabled: true)
        persistModel.manualIP = "10.25.90.2"
        check(persistModel.manualIP == "10.25.90.2", "manualIP updates in memory")
        check(persistSuite.string(forKey: "ghds.manualIP") == "10.25.90.2",
              "manualIP didSet persists to the injected suite")
        persistModel.manualIP = ""
        check(persistSuite.object(forKey: "ghds.manualIP") == nil,
              "clearing manualIP removes the persisted value through didSet")

        let frozenSuite = makeSuite(suiteNames[2])
        frozenSuite.set("10.0.0.9", forKey: "ghds.manualIP")
        let frozenModel = DSModel(settingsDefaults: frozenSuite, persistenceEnabled: false)
        check(!frozenModel.persistenceEnabled, "injected persistence switch is honored")
        frozenModel.manualIP = "127.0.0.1"
        check(frozenModel.manualIP == "127.0.0.1", "manualIP still updates in memory when persistence is disabled")
        check(frozenSuite.string(forKey: "ghds.manualIP") == "10.0.0.9",
              "disabled persistence leaves the stored manualIP untouched")

        // ⑦ 已应用手动地址警告：基于 model（非草稿）；127/8 + teamNumber>0 明确本机
        let warnModel = DSModel(settingsDefaults: makeSuite(suiteNames[3]), persistenceEnabled: true)
        check(warnModel.appliedManualIPWarning == nil, "no applied-address warning when manualIP is empty")
        warnModel.manualIP = "10.25.90.2"
        let ordinaryWarning = warnModel.appliedManualIPWarning ?? ""
        check(ordinaryWarning.contains("自动发现已关闭") && ordinaryWarning.contains("仅向该地址发送"),
              "ordinary manual address warns that auto-discovery is off and traffic targets only that address")
        check(!ordinaryWarning.contains("本机"), "ordinary manual address is not described as loopback")
        warnModel.teamNumber = 2590
        warnModel.manualIP = "127.0.0.1"
        let loopbackWarning = warnModel.appliedManualIPWarning ?? ""
        check(loopbackWarning.contains("本机") && loopbackWarning.contains("真实机器人"),
              "127/8 with a team number explicitly points at this Mac, not a real robot")
        check(loopbackWarning.contains("自动发现已关闭") && loopbackWarning.contains("仅向该地址发送"),
              "loopback warning keeps the auto-discovery/single-target semantics")
        warnModel.manualIP = "127.255.255.254"
        check((warnModel.appliedManualIPWarning ?? "").contains("本机"),
              "the whole 127/8 range is treated as loopback")
        warnModel.manualIP = "128.0.0.1"
        check(!(warnModel.appliedManualIPWarning ?? "").contains("本机"), "128/8 is not loopback")
        warnModel.manualIP = "127.0.0"
        check(!(warnModel.appliedManualIPWarning ?? "").contains("本机"),
              "invalid address is not misclassified as loopback")
        warnModel.manualIP = "10.25.90.2"
        let warnDraft = ConnectionDraft()
        warnDraft.load(from: warnModel)
        warnDraft.targetText = "127.0.0.1"
        check(!(warnModel.appliedManualIPWarning ?? "").contains("本机"),
              "warning follows the applied model value, not the editable draft")

        // 单目标连接草稿（2026-11-22）：解析、旧双值恢复、team/IP 映射、脏检查
        check(ConnectionDraft.parseTarget(" 2590 ") == .team(2590),
              "team target trims whitespace")
        check(ConnectionDraft.parseTarget("0") == .team(0),
              "zero remains the USB-only team target")
        check(ConnectionDraft.parseTarget(" 10.25.90.2\n") == .manualIP("10.25.90.2"),
              "IPv4 target trims whitespace")
        check(ConnectionDraft.parseTarget("") == nil, "empty target is invalid")
        check(ConnectionDraft.parseTarget("-1") == nil, "negative team is invalid")
        check(ConnectionDraft.parseTarget("abc") == nil, "non-numeric team is invalid")
        check(ConnectionDraft.parseTarget("10.25.90") == nil, "incomplete IPv4 is invalid")
        check(ConnectionDraft.parseTarget("999.1.1.1") == nil, "out-of-range IPv4 is invalid")

        let parsedDraft = ConnectionDraft()
        parsedDraft.targetText = " 10.25.90.2 "
        check(parsedDraft.parsedTarget == .manualIP("10.25.90.2"),
              "draft exposes the parsed, trimmed IP target")
        parsedDraft.targetText = " 2590 "
        check(parsedDraft.parsedTarget == .team(2590),
              "draft exposes the parsed, trimmed team target")

        let targetModel = DSModel(settingsDefaults: makeSuite(suiteNames[11]), persistenceEnabled: true)
        targetModel.teamNumber = 2590
        targetModel.manualIP = "127.0.0.1"
        let targetDraft = ConnectionDraft()
        targetDraft.load(from: targetModel)
        check(targetDraft.targetText == "127.0.0.1" && !targetDraft.hasChanges(comparedTo: targetModel),
              "legacy dual values load the address that actually takes precedence")

        targetDraft.targetText = "2590"
        check(targetDraft.hasChanges(comparedTo: targetModel), "switching from IP to team is a change")
        check(targetDraft.apply(to: targetModel), "valid team target applies")
        check(targetModel.teamNumber == 2590 && targetModel.manualIP.isEmpty,
              "team target clears the old manual IP")
        check(!targetDraft.hasChanges(comparedTo: targetModel), "applied team target is no longer dirty")

        targetDraft.targetText = "10.25.90.2"
        check(targetDraft.apply(to: targetModel), "valid IP applies without requiring a separate team field")
        check(targetModel.teamNumber == 2590 && targetModel.manualIP == "10.25.90.2",
              "IP target preserves team identity for radio and presentation")
        check(!targetDraft.hasChanges(comparedTo: targetModel), "applied IP target is no longer dirty")

        targetDraft.targetText = "10.25.90"
        check(!targetDraft.apply(to: targetModel), "invalid target is rejected")
        check(targetModel.teamNumber == 2590 && targetModel.manualIP == "10.25.90.2",
              "invalid target does not mutate applied settings")

        targetDraft.targetText = "0"
        check(targetDraft.apply(to: targetModel), "zero target applies")
        check(targetModel.teamNumber == 0 && targetModel.manualIP.isEmpty,
              "zero clears manual IP and selects USB-only behavior")

        let kindDraft = ConnectionDraft()
        kindDraft.load(from: targetModel)
        check(!kindDraft.hasChanges(comparedTo: targetModel), "clean draft matches the applied model")
        kindDraft.protocolKind = .mrc
        check(kindDraft.hasChanges(comparedTo: targetModel) && kindDraft.targetText == "0",
              "protocolKind change marks the draft dirty without touching target text")

        let invalidDraft = ConnectionDraft()
        invalidDraft.load(from: targetModel)
        invalidDraft.targetText = "10.25.90"
        check(invalidDraft.parsedTarget == nil && invalidDraft.hasChanges(comparedTo: targetModel),
              "invalid text keeps a restorable dirty state")
        check(!invalidDraft.apply(to: targetModel), "invalid draft cannot be applied")
        check(targetModel.teamNumber == 0 && targetModel.manualIP.isEmpty,
              "rejected invalid draft leaves the applied model untouched")
        invalidDraft.load(from: targetModel)
        check(invalidDraft.targetText == "0" && !invalidDraft.userEdited,
              "reload restores the applied target and clears the edit flag")

        // ⑧ Radio 状态日志：仅真实翻转回调记录，重复不刷
        let radioModel = DSModel(settingsDefaults: makeSuite(suiteNames[4]), persistenceEnabled: true)
        func radioLogCount(_ needle: String) -> Int {
            radioModel.dsEvents.filter { $0.text.contains(needle) }.count
        }
        radioModel.applyRadioResult(false)
        check(!radioModel.radioReachable, "initial false result keeps radio offline")
        check(radioLogCount("Radio 状态") == 0, "initial no-response is not logged as a flip")
        radioModel.applyRadioResult(true)
        check(radioModel.radioReachable, "radio response flips state")
        check(radioLogCount("Radio 状态：已响应") == 1, "first response flip is logged")
        radioModel.applyRadioResult(true)
        check(radioLogCount("Radio 状态") == 1, "duplicate response does not spam the event log")
        radioModel.applyRadioResult(false)
        check(!radioModel.radioReachable, "radio timeout flips state")
        check(radioLogCount("Radio 状态：无响应") == 1, "first no-response flip is logged")
        radioModel.applyRadioResult(false)
        check(radioLogCount("Radio 状态") == 2, "duplicate no-response does not spam the event log")

        // ⑨ 本机网络状态：检测中 → 实际状态记录一次；变化记录；重复不刷
        let netModel = DSModel(settingsDefaults: makeSuite(suiteNames[5]), persistenceEnabled: true)
        func netLogCount(_ needle: String) -> Int {
            netModel.dsEvents.filter { $0.text.contains(needle) }.count
        }
        netModel.applyLocalNetworkSummary(tr("检测中…"))
        check(netModel.localNetworkSummary == tr("检测中…"), "placeholder summary stays in place")
        check(netLogCount("本机网络状态") == 0, "placeholder is not logged")
        netModel.applyLocalNetworkSummary("WiFi")
        check(netModel.localNetworkSummary == "WiFi", "first real network summary is published")
        check(netLogCount("本机网络状态：WiFi") == 1, "first real network status is logged")
        netModel.applyLocalNetworkSummary("WiFi")
        check(netLogCount("本机网络状态") == 1, "duplicate network summary does not spam the event log")
        netModel.applyLocalNetworkSummary("有线")
        check(netModel.localNetworkSummary == "有线", "changed network summary is published")
        check(netLogCount("本机网络状态：WiFi") == 1 && netLogCount("本机网络状态：有线") == 1,
              "network status change is logged exactly once")
        netModel.applyLocalNetworkSummary("有线")
        check(netLogCount("本机网络状态") == 2, "repeated changed status is not logged again")

        // ⑩ 年份官方时序：一键应用只改设置，并使年份与独立开始前等待跨启动恢复
        let seasonSuite = makeSuite(suiteNames[6])
        let seasonModel = DSModel(settingsDefaults: seasonSuite, persistenceEnabled: true)
        check(seasonModel.practiceSeasonYear == 2026, "practice season defaults to 2026")
        seasonModel.practiceSeasonYear = 2022
        seasonModel.applyPracticeTimingPreset()
        check(seasonModel.practiceAutoTime == 15 && seasonModel.practiceTeleopTime == 135 &&
              seasonModel.practiceDelayTime == 0 && seasonModel.practiceStartDelay == 0,
              "2022 preset applies official timing without an extra transition")
        check(!seasonModel.practiceActive && !seasonModel.enabled, "applying a season preset never starts or enables a robot")
        let restoredSeason = DSModel(settingsDefaults: seasonSuite, persistenceEnabled: true)
        restoredSeason.loadPersistedSettings()
        check(restoredSeason.practiceSeasonYear == 2022 && restoredSeason.practiceStartDelay == 0 &&
              restoredSeason.practiceDelayTime == 0, "season and independent start delay persist")
        seasonModel.practiceSeasonYear = 2026
        seasonModel.applyPracticeTimingPreset()
        check(seasonModel.practiceAutoTime == 20 && seasonModel.practiceTeleopTime == 140 &&
              seasonModel.practiceDelayTime == 3 && seasonModel.practiceStartDelay == 0,
              "2026 preset includes shifts and endgame inside 140-second Teleop")
        check(seasonModel.practiceTransitionShiftTime == 10 && seasonModel.practiceAllianceShiftTime == 25 &&
              seasonModel.practiceEndgameTime == 30 && seasonModel.effectivePracticeTeleopTime == 140,
              "2026 official Teleop breakdown sums to 140 seconds")
        seasonModel.practiceAllianceShiftTime = 30
        check(seasonModel.effectivePracticeTeleopTime == 160, "2026 Teleop total follows the shared Alliance Shift slider")
        let restoredBreakdown = DSModel(settingsDefaults: seasonSuite, persistenceEnabled: true)
        restoredBreakdown.loadPersistedSettings()
        check(restoredBreakdown.practiceTransitionShiftTime == 10 && restoredBreakdown.practiceAllianceShiftTime == 30 &&
              restoredBreakdown.practiceEndgameTime == 30 && restoredBreakdown.effectivePracticeTeleopTime == 160,
              "2026 breakdown values persist and recompute Teleop")

        // ⑪ 季节音效：目录映射与顺序播放、停止时清空队列
        let expectedEndgames = [
            2022: "WARNEOM_2022_2023", 2023: "WARNEOM_2022_2023",
            2024: "Guitar", 2025: "Sonar", 2026: "WARNEOM_2026",
        ]
        for (year, filename) in expectedEndgames {
            check(PracticeSoundCatalog.fileName(for: .endgame, year: year) == filename,
                  "\(year) endgame uses the official season file")
        }
        for year in 2022...2026 {
            check(PracticeSoundCatalog.fileName(for: .matchStart, year: year) == "CHARGE", "match start stays official \(year)")
            check(PracticeSoundCatalog.fileName(for: .autoEnd, year: year) == "ENDMATCH", "auto end stays official \(year)")
            check(PracticeSoundCatalog.fileName(for: .teleopStart, year: year) == "3BELLS", "teleop start stays official \(year)")
            check(PracticeSoundCatalog.fileName(for: .matchEnd, year: year) == "ENDMATCH", "match end stays official \(year)")
            check(PracticeSoundCatalog.fileName(for: .allianceShift, year: year) == "PowerUp_LinearPop", "shift stays official \(year)")
        }
        let player = PracticeAudioPlayer()
        var played: [String] = []
        player.playHandler = { played.append($0) }
        player.finishHandler = {}
        player.enqueue("CHARGE")
        player.enqueue("3BELLS")
        check(played == ["CHARGE"], "audio queue does not overlap the next sound")
        player.finishCurrent()
        check(played == ["CHARGE", "3BELLS"], "audio queue advances in order")
        player.enqueue("ENDMATCH")
        player.stop()
        player.finishCurrent()
        check(played == ["CHARGE", "3BELLS"], "stopping clears pending audio")

        let rebuiltAudio = DSModel(settingsDefaults: makeSuite(suiteNames[7]), persistenceEnabled: false)
        rebuiltAudio.practiceSeasonYear = 2026
        rebuiltAudio.practiceAutoTime = 0.1
        rebuiltAudio.practiceDelayTime = 0.1
        rebuiltAudio.practiceStartDelay = 0
        rebuiltAudio.practiceTransitionShiftTime = 0.1
        rebuiltAudio.practiceAllianceShiftTime = 0.1
        rebuiltAudio.practiceEndgameTime = 0.1
        var rebuiltPlayed: [String] = []
        rebuiltAudio.practiceAudio.playHandler = {
            rebuiltPlayed.append($0)
            rebuiltAudio.practiceAudio.finishCurrent()
        }
        rebuiltAudio.practiceAudio.finishHandler = {}
        rebuiltAudio.startPractice()
        let audioDeadline = Date().addingTimeInterval(1.4)
        while Date() < audioDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        check(rebuiltPlayed == ["CHARGE", "ENDMATCH", "3BELLS", "PowerUp_LinearPop", "PowerUp_LinearPop",
                                "PowerUp_LinearPop", "PowerUp_LinearPop", "WARNEOM_2026", "ENDMATCH"],
              "2026 practice plays official cues in chronological order")

        let legacySeasons = [
            (year: 2022, warning: "WARNEOM_2022_2023"),
            (year: 2023, warning: "WARNEOM_2022_2023"),
            (year: 2024, warning: "Guitar"),
            (year: 2025, warning: "Sonar"),
        ]
        for season in legacySeasons {
            let legacyAudio = DSModel(settingsDefaults: makeSuite(suiteNames[7]), persistenceEnabled: false)
            legacyAudio.practiceSeasonYear = season.year
            legacyAudio.practiceAutoTime = 0.1
            legacyAudio.practiceTeleopTime = 0.1
            legacyAudio.practiceDelayTime = 0
            legacyAudio.practiceStartDelay = 0
            var legacyPlayed: [String] = []
            legacyAudio.practiceAudio.playHandler = {
                legacyPlayed.append($0)
                legacyAudio.practiceAudio.finishCurrent()
            }
            legacyAudio.practiceAudio.finishHandler = {}
            legacyAudio.startPractice()
            let legacyDeadline = Date().addingTimeInterval(0.8)
            while Date() < legacyDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            check(legacyPlayed == ["CHARGE", "ENDMATCH", "3BELLS", season.warning, "ENDMATCH"],
                  "\(season.year) practice plays its warning before the match-end Buzzer")
        }

        let stopAudio = DSModel(settingsDefaults: makeSuite(suiteNames[7]), persistenceEnabled: false)
        stopAudio.practiceStartDelay = 0
        var stopPlayed: [String] = []
        stopAudio.practiceAudio.playHandler = {
            stopPlayed.append($0)
            stopAudio.practiceAudio.finishCurrent()
        }
        stopAudio.practiceAudio.finishHandler = {}
        stopAudio.startPractice()
        stopAudio.aStop()
        check(stopPlayed == ["CHARGE", "FOGHORN"], "A-Stop plays match-stopped Foghorn")

        check(PracticeSoundCatalog.fileName(for: .timeoutWarning, year: 2022) == "Fanfare",
              "2022 Timeout warning uses the official trumpet Fanfare")
        check(PracticeSoundCatalog.fileName(for: .timeoutWarning, year: 2023) == nil,
              "later seasons do not inherit the 2022 Timeout Fanfare")

        let timeoutAudio = DSModel(settingsDefaults: makeSuite(suiteNames[7]), persistenceEnabled: false)
        timeoutAudio.practiceSeasonYear = 2022
        timeoutAudio.timeoutDuration = 0.3
        var timeoutPlayed: [String] = []
        timeoutAudio.practiceAudio.playHandler = {
            timeoutPlayed.append($0)
            timeoutAudio.practiceAudio.finishCurrent()
        }
        timeoutAudio.practiceAudio.finishHandler = {}
        timeoutAudio.startTimeout()
        check(timeoutAudio.timeoutActive && timeoutAudio.timeoutRemaining > 0, "2022 Timeout starts its countdown")
        timeoutAudio.setEnabled(true)
        check(!timeoutAudio.enabled, "Timeout does not allow enabling the robot")
        timeoutAudio.startPractice()
        check(!timeoutAudio.practiceActive, "Timeout and normal practice are mutually exclusive")
        let timeoutDeadline = Date().addingTimeInterval(1)
        while Date() < timeoutDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        check(timeoutPlayed == ["Fanfare", "ENDMATCH"], "Timeout plays Fanfare at warning and Buzzer at zero")
        check(!timeoutAudio.timeoutActive && timeoutAudio.timeoutRemaining == 0 && !timeoutAudio.enabled,
              "Timeout finishes disabled without starting a match")

        let cancelTimeout = DSModel(settingsDefaults: makeSuite(suiteNames[7]), persistenceEnabled: false)
        cancelTimeout.practiceSeasonYear = 2022
        cancelTimeout.soundsEnabled = false
        cancelTimeout.startTimeout()
        cancelTimeout.cancelTimeout()
        check(!cancelTimeout.timeoutActive && cancelTimeout.timeoutRemaining == 0, "cancel stops and clears Timeout")
        cancelTimeout.startTimeout()
        cancelTimeout.triggerEstop()
        check(!cancelTimeout.timeoutActive && cancelTimeout.estopEngaged, "E-Stop cancels Timeout")

        let unsupportedTimeout = DSModel(settingsDefaults: makeSuite(suiteNames[7]), persistenceEnabled: false)
        unsupportedTimeout.practiceSeasonYear = 2023
        unsupportedTimeout.startTimeout()
        check(!unsupportedTimeout.timeoutActive, "Timeout audio simulation is specific to the 2022 rules")
        // ⑫ 比赛年份：下拉新→旧；Preset.all 事实顺序不变
        let orderedYearModel = DSModel()
        check(orderedYearModel.practiceSeasonYearChoices == [2026, 2025, 2024, 2023, 2022],
              "season picker lists years newest first")
        check(PracticeTimingPreset.all.map(\.year) == [2022, 2023, 2024, 2025, 2026],
              "preset fact order is untouched by UI ordering")

        // ⑬ Dashboard 多选：字母序、即时持久化、重启恢复、旧键兼容、空选择
        check(DashboardKind.allCases.map(\.rawValue) == ["AdvantageScope", "Elastic", "Shuffleboard"],
              "dashboard controls are ordered AdvantageScope, Elastic, Shuffleboard")
        let dashboardSuite = makeSuite(suiteNames[8])
        let dashboardModel = DSModel(settingsDefaults: dashboardSuite, persistenceEnabled: true)
        check(dashboardModel.selectedDashboards == [.advantageScope],
              "fresh install keeps the legacy AdvantageScope default")
        dashboardModel.dashboardSelection = [.shuffleboard, .advantageScope]
        check(dashboardModel.selectedDashboards == [.advantageScope, .shuffleboard],
              "selection is presented in alphabetical order")
        check(dashboardSuite.string(forKey: "ghds.dashboards") == "AdvantageScope,Shuffleboard",
              "selection persists immediately in canonical order")
        check(dashboardSuite.string(forKey: "ghds.dashboardKind") == "AdvantageScope",
              "legacy single-select key mirrors the first selection")
        let restoredDashboard = DSModel(settingsDefaults: dashboardSuite, persistenceEnabled: true)
        restoredDashboard.loadPersistedSettings()
        check(restoredDashboard.dashboardSelection == [.advantageScope, .shuffleboard],
              "multi-selection restores after restart")

        dashboardModel.dashboardSelection = []
        check(dashboardSuite.string(forKey: "ghds.dashboards") == "",
              "empty selection persists as an empty list")
        let restoredEmpty = DSModel(settingsDefaults: dashboardSuite, persistenceEnabled: true)
        restoredEmpty.loadPersistedSettings()
        check(restoredEmpty.dashboardSelection.isEmpty,
              "empty selection survives restart instead of falling back to a default")
        check(restoredEmpty.dashboardKind == nil,
              "legacy view reports no selection when all dashboards are unchecked")

        // 旧版单选键：新键缺失 → 直接恢复；新键损坏 → 回退旧键（外部数据容错）
        let legacySuite = makeSuite(suiteNames[9])
        legacySuite.set("Shuffleboard", forKey: "ghds.dashboardKind")
        let legacyDashboard = DSModel(settingsDefaults: legacySuite, persistenceEnabled: true)
        legacyDashboard.loadPersistedSettings()
        check(legacyDashboard.dashboardSelection == [.shuffleboard],
              "legacy dashboardKind setting restores as a single selection")
        legacySuite.set("AdvantageScope,Bogus", forKey: "ghds.dashboards")
        let corruptDashboard = DSModel(settingsDefaults: legacySuite, persistenceEnabled: true)
        corruptDashboard.loadPersistedSettings()
        check(corruptDashboard.dashboardSelection == [.shuffleboard],
              "corrupt multi-select value falls back to the legacy key")

        // WebUI：旧键仍按单选生效，新键支持逗号多选；非法项拒绝且不改现状
        check(dashboardModel.applyWebSetting(key: "dashboardKind", value: "Elastic") == nil &&
              dashboardModel.dashboardSelection == [.elastic],
              "WebUI legacy key maps to a single selection")
        check(dashboardModel.applyWebSetting(key: "dashboards", value: "AdvantageScope, Shuffleboard") == nil &&
              dashboardModel.selectedDashboards == [.advantageScope, .shuffleboard],
              "WebUI multi-select key accepts a comma-separated list")
        check(dashboardModel.applyWebSetting(key: "dashboards", value: "AdvantageScope,Unknown") != nil &&
              dashboardModel.selectedDashboards == [.advantageScope, .shuffleboard],
              "unknown dashboard entries are rejected without changing state")
        check(dashboardModel.applyWebSetting(key: "dashboards", value: "") == nil &&
              dashboardModel.dashboardSelection.isEmpty,
              "clearing all dashboards through the WebUI key is allowed")
        dashboardModel.dashboardSelection = [.elastic, .shuffleboard]
        let webSnapshot = dashboardModel.webSettingsSnapshot()
        check(webSnapshot["dashboardKind"] == "Elastic" && webSnapshot["dashboards"] == "Elastic,Shuffleboard",
              "WebUI snapshot exposes both the legacy key and the full selection")
        check(dashboardModel.applyWebSetting(key: "dashboardKind", value: "") == nil &&
              dashboardModel.dashboardSelection.isEmpty,
              "empty legacy key clears the selection for snapshot round-trips")

        // 启动器注入：测试只记录调用，绝不打开真实 App；单项失败不阻断其余项
        let launchModel = DSModel(settingsDefaults: makeSuite(suiteNames[10]), persistenceEnabled: false)
        var opened: [String] = []
        launchModel.dashboardLauncher.open = { opened.append($0.applicationName) }
        launchModel.dashboardSelection = [.shuffleboard, .elastic]
        let launched = launchModel.launchSelectedDashboards()
        check(opened == ["Elastic", "shuffleboard"],
              "launch opens every selected dashboard in alphabetical order")
        check(launched == [.elastic, .shuffleboard],
              "launch reports the dashboards handed to the system")
        opened.removeAll()
        launchModel.dashboardSelection = []
        check(launchModel.launchSelectedDashboards().isEmpty && opened.isEmpty,
              "empty selection launches nothing")

        enum FakeLaunchError: Error { case missing }
        launchModel.dashboardSelection = [.advantageScope, .elastic, .shuffleboard]
        launchModel.dashboardLauncher.open = { kind in
            if kind == .elastic { throw FakeLaunchError.missing }
            opened.append(kind.applicationName)
        }
        let partial = launchModel.launchSelectedDashboards()
        check(opened == ["AdvantageScope", "shuffleboard"] && partial == [.advantageScope, .shuffleboard],
              "one failed dashboard does not stop the remaining launches")
        check(launchModel.dsEvents.contains { $0.text.contains("启动 Dashboard 失败") && $0.text.contains("Elastic") },
              "a failed dashboard launch is logged")

        // 任意 1–3 个组合：一次启动恰好全部选中项，顺序恒为字母序
        let subsetModel = DSModel(settingsDefaults: makeSuite(suiteNames[10]), persistenceEnabled: false)
        var plan: [String] = []
        subsetModel.dashboardLauncher.open = { plan.append($0.applicationName) }
        let allDashboards = DashboardKind.allCases
        var matchingSubsets = 0
        for mask in 1..<(1 << allDashboards.count) {
            let subset = Set(allDashboards.indices.filter { mask & (1 << $0) != 0 }.map { allDashboards[$0] })
            subsetModel.dashboardSelection = subset
            plan.removeAll()
            let result = subsetModel.launchSelectedDashboards()
            let expected = allDashboards.filter { subset.contains($0) }
            if result == expected && plan == expected.map(\.applicationName) { matchingSubsets += 1 }
        }
        check(matchingSubsets == 7, "every 1–3 dashboard combination launches exactly the selected apps")

        // 禁用持久化（AUTO_SIM / 测试注入）只改内存，不写正式设置
        let frozenDashSuite = makeSuite(suiteNames[10])
        let frozenDash = DSModel(settingsDefaults: frozenDashSuite, persistenceEnabled: false)
        frozenDash.dashboardSelection = [.elastic]
        check(frozenDash.selectedDashboards == [.elastic], "selection still updates in memory")
        check(frozenDashSuite.object(forKey: "ghds.dashboards") == nil,
              "disabled persistence leaves dashboard storage untouched")

        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }

        // ===== 点击输入框外部退出编辑（2026-11-21）=====
        // 真实 AppKit 焦点回归：字段编辑器存在 → 空白点击结束编辑且保留文字 → 重新聚焦后框内点击保持编辑。
        // 再用 delegate 结束通知、按钮 target/action 与跨字段切换证明不是“无条件 resign 后 AppKit 又聚焦”。
        let previousActivationPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        let focusWindow = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 320, height: 160),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        focusWindow.isReleasedWhenClosed = false
        let focusContent = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        focusWindow.contentView = focusContent
        let focusField = NSTextField(frame: NSRect(x: 20, y: 100, width: 200, height: 24))
        let secondField = NSTextField(frame: NSRect(x: 20, y: 60, width: 200, height: 24))
        focusContent.addSubview(focusField)
        focusContent.addSubview(secondField)
        let focusProbe = FocusTestProbe()
        focusField.delegate = focusProbe
        let focusButton = NSButton(title: "Done", target: focusProbe,
                                   action: #selector(FocusTestProbe.focusButtonClicked(_:)))
        focusButton.frame = NSRect(x: 240, y: 96, width: 64, height: 28)
        focusButton.bezelStyle = .rounded
        focusContent.addSubview(focusButton)
        focusWindow.orderFront(nil)
        focusWindow.makeFirstResponder(focusField)

        let shortcutManager = ShortcutManager()
        shortcutManager.install(model: DSModel())

        func click(_ point: NSPoint) {
            let timestamp = ProcessInfo.processInfo.systemUptime
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                timestamp: timestamp,
                                                windowNumber: focusWindow.windowNumber, context: nil,
                                                eventNumber: 0, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                              timestamp: timestamp,
                                              windowNumber: focusWindow.windowNumber, context: nil,
                                              eventNumber: 1, clickCount: 1, pressure: 0) else {
                check(false, "synthetic left-click events are created")
                return
            }
            // 按钮 / 新聚焦的文本视图会在 mouseDown 内跟踪 mouseUp；先把 up 入队，
            // 让 AppKit 的跟踪循环取走它，否则 sendEvent(down) 会阻塞等待真实鼠标抬起。
            NSApp.postEvent(up, atStart: true)
            NSApp.sendEvent(down)
            if let pendingUp = NSApp.nextEvent(matching: .leftMouseUp, until: Date(),
                                              inMode: .default, dequeue: true) {
                NSApp.sendEvent(pendingUp)
            }
        }

        focusField.stringValue = "2590"
        focusField.selectText(nil)
        // 初始化焦点本身可能产生结束编辑通知；之后的计数只反映交互导致的结束。
        focusProbe.textEditingEndedCount = 0
        // 保持 manager 与生产生命周期一致：应用常驻持有；鼠标监听闭包不捕获 self。
        withExtendedLifetime(shortcutManager) {
            check(focusField.currentEditor() != nil, "focused text field owns an active field editor")
            click(NSPoint(x: 270, y: 30))
            check(focusField.currentEditor() == nil, "clicking outside the text field ends editing")
            check(focusProbe.textEditingEndedCount == 1,
                  "clicking outside reports exactly one end-editing notification")
            check(focusField.stringValue == "2590", "clicking outside keeps the entered text")
            focusField.selectText(nil)
            check(focusField.currentEditor() != nil, "refocusing the text field starts editing again")
            click(NSPoint(x: 60, y: 112))
            check(focusField.currentEditor() != nil, "clicking inside the text field keeps editing")
            check(focusProbe.textEditingEndedCount == 1,
                  "clicking inside does not end editing again")
            check(focusField.stringValue == "2590", "clicking inside keeps the entered text")

            click(NSPoint(x: 272, y: 110))
            check(focusProbe.buttonActionCount == 1, "clicking the button triggers its action exactly once")
            check(focusField.currentEditor() == nil, "clicking the button ends text editing")

            focusField.selectText(nil)
            check(focusField.currentEditor() != nil, "first field regains editing before the second-field click")
            click(NSPoint(x: 60, y: 72))
            check(focusField.currentEditor() == nil, "clicking the second field releases the first editor")
            check(secondField.currentEditor() != nil, "clicking the second field starts editing there")
        }
        focusWindow.orderOut(nil)
        focusWindow.close()
        NSApplication.shared.setActivationPolicy(previousActivationPolicy)

        print("GHDS UI state: \(checks) checks, \(failures.count) failures")
        for failure in failures { print("FAIL: \(failure)") }
        exit(failures.isEmpty ? 0 : 1)
    }
}


@MainActor
private func renderedAllianceSelectionMatches(_ station: AllianceStation, red: CGFloat, green: CGFloat, blue: CGFloat) -> Bool {
    let options = [
        DSSelectOption(value: AllianceStation.red1, label: "Red 1"),
        DSSelectOption(value: AllianceStation.blue1, label: "Blue 1"),
    ]
    let control = DSSegmentedControl(
        title: "Alliance Station",
        selection: .constant(station),
        options: options,
        selectedColor: DSTheme.allianceColor(for:)
    )
    .frame(width: 240, height: 32)
    let renderer = ImageRenderer(content: control)
    renderer.scale = 1
    guard let image = renderer.nsImage,
          let data = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: data) else { return false }
    let x = station == .red1 ? 12 : 228
    guard let color = bitmap.colorAt(x: x, y: 16) else { return false }
    let tolerance: CGFloat = 0.03
    return abs(color.redComponent - red) < tolerance
        && abs(color.greenComponent - green) < tolerance
        && abs(color.blueComponent - blue) < tolerance
}
