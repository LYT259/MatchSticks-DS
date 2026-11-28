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

        if CommandLine.arguments.contains("--brand-only") {
            driverStationBrandTests(check)
            print("MatchSticks Driver Station brand state: \(checks) checks, \(failures.count) failures")
            for failure in failures { print("FAIL: \(failure)") }
            exit(failures.isEmpty ? 0 : 1)
        }

        if CommandLine.arguments.contains("--mac-only") {
            macHardwareMonitoringTests(check)
            macHardwareInterfaceTests(check)
            print("MatchSticks Driver Station Mac hardware state: \(checks) checks, \(failures.count) failures")
            for failure in failures { print("FAIL: \(failure)") }
            exit(failures.isEmpty ? 0 : 1)
        }

        if CommandLine.arguments.contains("--permission-only") {
            permissionRuntimeMonitorTests(check)
            firewallVerificationProbeTests(check)
            print("MatchSticks Driver Station permission state: \(checks) checks, \(failures.count) failures")
            for failure in failures { print("FAIL: \(failure)") }
            exit(failures.isEmpty ? 0 : 1)
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
        practice.practiceCountdownSpeech = CountdownSpeechSpy()
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
        let estopAudioSuiteName = "org.ghfrc.driverstation.test.uitests.estop-audio.\(UUID().uuidString)"
        let estopAudio = DSModel(settingsDefaults: makeSuite(estopAudioSuiteName), persistenceEnabled: false)
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

        // 主窗口标题栏双击：AppleActionOnDoubleClick 纯解析（无窗口、无 UserDefaults 依赖）
        check(MainWindowDoubleClickAction.resolve(nil) == .zoom, "unset double-click preference falls back to zoom")
        check(MainWindowDoubleClickAction.resolve("Maximize") == .zoom, "Maximize preference zooms")
        check(MainWindowDoubleClickAction.resolve("Zoom") == .zoom, "Zoom preference zooms")
        check(MainWindowDoubleClickAction.resolve("Fill") == .fillFallbackZoom,
              "Fill preference uses public performZoom fallback (not native Fill)")
        check(MainWindowDoubleClickAction.resolve("Minimize") == .minimize, "Minimize preference minimizes")
        check(MainWindowDoubleClickAction.resolve("None") == .none, "None preference leaves the window alone")
        check(MainWindowDoubleClickAction.resolve("FutureValue") == .none, "unknown preference leaves the window alone")

        // 主窗口标题栏双击：纯门控（空白标题栏才放行）
        func gate(clickCount: Int = 2, host: Bool = true, fullScreen: Bool = false,
                  above: Bool = true, control: Bool = false, sheet: Bool = false) -> Bool {
            MainWindowDoubleClickGate(clickCount: clickCount, isHostWindow: host,
                                      isFullScreen: fullScreen, isAboveContentLayoutMaxY: above,
                                      isInteractiveControl: control, hasAttachedSheet: sheet)
                .allowsDoubleClick
        }
        check(gate(), "blank titlebar double click is allowed")
        check(!gate(clickCount: 1), "single click is not a titlebar double click")
        check(!gate(host: false), "clicks from other windows are ignored")
        check(!gate(fullScreen: true), "full screen clicks are ignored")
        check(!gate(above: false), "content-area clicks are ignored")
        check(!gate(control: true), "clicks on interactive controls are ignored")
        check(!gate(sheet: true), "clicks while a sheet is attached are ignored")

        // ===== OM5P UI stall / 控制环性能回归（2026-11-14）=====

        // ① Diag 常驻输出句柄 + HeartbeatBox 停滞探针
        let diagPath = NSTemporaryDirectory() + "MatchSticks-DriverStaion-diag-\(UUID().uuidString).log"
        check(Diag.setFileOutput(path: diagPath), "diag file output opens")
        Diag.write("line-one")
        Diag.write("line-two")
        let diagText = (try? String(contentsOf: URL(fileURLWithPath: diagPath), encoding: .utf8)) ?? ""
        check(diagText.contains("line-one\nline-two"), "diag appends lines in order without truncation")
        try? FileManager.default.removeItem(atPath: diagPath)
        Diag.write("after-unlink")
        check(!FileManager.default.fileExists(atPath: diagPath), "diag handle persists instead of reopening per line")

        let hb = HeartbeatBox()
        let stallPath = NSTemporaryDirectory() + "MatchSticks-DriverStaion-diag-stall-\(UUID().uuidString).log"
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
        gamepadSkinPickerTests(check)
        gamepadSkinPickerInteractionTests(check)
        thumbstickMotionTests(check)
        thumbstickSceneTests(check)
        flightStickSceneTests(check)
        direwolfArtworkTests(check)
        gamepadRenderingTests(check)
        gamepadTriggerRangeTests(check)
        joystickSlotOrderingTests(check)
        joystickSlotDragBoundaryTests(check)
        joystickCardInteractionTests(check)
        appIconAppearanceTests(check)
        driverStationBrandTests(check)
        permissionRuntimeMonitorTests(check)
        firewallVerificationProbeTests(check)
        miniDriverStationTests(check)
        localNetworkDiscoveryTests(check)
        updateChannelTests(check)
        updateSchedulerTests(check)
        updateReachabilityTests(check)
        updateRequestRoutingTests(check)
        updateBadgeBehaviorTests(check)
        appLifecycleTests(check)
        practiceProgressTests(check)
        practiceCountdownSpeechTests(check)
        macHardwareMonitoringTests(check)
        macHardwareInterfaceTests(check)

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

        let suiteNames = (0..<19).map { _ in "org.ghfrc.driverstation.test.uitests.\(UUID().uuidString)" }
        func makeSuite(_ name: String) -> UserDefaults { UserDefaults(suiteName: name)! }

        // ⑤ MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE 解析：非空有效 → 独立 suite；
        //    四级链逐级回退：上一轮 MATCHSTICKS_DRIVER_STATION_ → 过渡 MATCHSTICKS_DS_ → 旧 GHDS_，
        //    新键优先（键存在即为权威，即便为空）；空白/缺失 → 标准域
        let envSuite = DSModel.resolvedSettingsDefaults(environment: ["MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE": suiteNames[0]])
        envSuite.set("probe", forKey: "matchsticks.envProbe")
        check(UserDefaults(suiteName: suiteNames[0])?.string(forKey: "matchsticks.envProbe") == "probe",
              "MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE resolves to an isolated user defaults suite")
        // 旧前缀只做回退：仅在更新一级的键缺失时才被读取
        let interimEnvSuite = DSModel.resolvedSettingsDefaults(environment: ["MATCHSTICKS_DRIVER_STATION_SETTINGS_SUITE": suiteNames[0]])
        interimEnvSuite.set("probe", forKey: "matchsticks.envProbeInterim")
        check(UserDefaults(suiteName: suiteNames[0])?.string(forKey: "matchsticks.envProbeInterim") == "probe",
              "interim MATCHSTICKS_DRIVER_STATION_SETTINGS_SUITE still resolves when the new key is absent")
        let dsEnvSuite = DSModel.resolvedSettingsDefaults(environment: ["MATCHSTICKS_DS_SETTINGS_SUITE": suiteNames[0]])
        dsEnvSuite.set("probe", forKey: "matchsticks.envProbeDS")
        check(UserDefaults(suiteName: suiteNames[0])?.string(forKey: "matchsticks.envProbeDS") == "probe",
              "transitional MATCHSTICKS_DS_SETTINGS_SUITE still resolves when both newer keys are absent")
        let legacyEnvSuite = DSModel.resolvedSettingsDefaults(environment: ["GHDS_SETTINGS_SUITE": suiteNames[0]])
        legacyEnvSuite.set("probe", forKey: "matchsticks.envProbeLegacy")
        check(UserDefaults(suiteName: suiteNames[0])?.string(forKey: "matchsticks.envProbeLegacy") == "probe",
              "legacy GHDS_SETTINGS_SUITE still resolves as the final fallback")
        let priorityEnvSuite = DSModel.resolvedSettingsDefaults(
            environment: ["MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE": suiteNames[0],
                          "MATCHSTICKS_DRIVER_STATION_SETTINGS_SUITE": suiteNames[1],
                          "MATCHSTICKS_DS_SETTINGS_SUITE": suiteNames[1],
                          "GHDS_SETTINGS_SUITE": suiteNames[1]])
        priorityEnvSuite.set("probe", forKey: "matchsticks.envProbePriority")
        check(UserDefaults(suiteName: suiteNames[0])?.string(forKey: "matchsticks.envProbePriority") == "probe" &&
              UserDefaults(suiteName: suiteNames[1])?.string(forKey: "matchsticks.envProbePriority") == nil,
              "the new MATCHSTICKS_DRIVER_STAION prefix takes priority over every fallback prefix")
        let interimPriorityEnvSuite = DSModel.resolvedSettingsDefaults(
            environment: ["MATCHSTICKS_DRIVER_STATION_SETTINGS_SUITE": suiteNames[0],
                          "MATCHSTICKS_DS_SETTINGS_SUITE": suiteNames[1],
                          "GHDS_SETTINGS_SUITE": suiteNames[1]])
        interimPriorityEnvSuite.set("probe", forKey: "matchsticks.envProbeInterimPriority")
        check(UserDefaults(suiteName: suiteNames[0])?.string(forKey: "matchsticks.envProbeInterimPriority") == "probe" &&
              UserDefaults(suiteName: suiteNames[1])?.string(forKey: "matchsticks.envProbeInterimPriority") == nil,
              "the interim MATCHSTICKS_DRIVER_STATION key outranks the older MATCHSTICKS_DS and GHDS keys")
        check(DSModel.resolvedSettingsDefaults(environment: ["MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE": "   "]) === UserDefaults.standard,
              "blank MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE falls back to standard defaults")
        check(DSModel.resolvedSettingsDefaults(
                  environment: ["MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE": "   ",
                                "MATCHSTICKS_DRIVER_STATION_SETTINGS_SUITE": suiteNames[1]]) === UserDefaults.standard,
              "a blank MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE is authoritative and never leaks to an older prefix")
        check(DSModel.resolvedSettingsDefaults(environment: [:]) === UserDefaults.standard,
              "missing MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE falls back to standard defaults")

        // ⑥ manualIP didSet：启用持久化时保存/清除；禁用时不动已有值，但内存仍更新
        let persistSuite = makeSuite(suiteNames[1])
        let persistModel = DSModel(settingsDefaults: persistSuite, persistenceEnabled: true)
        persistModel.manualIP = "10.25.90.2"
        check(persistModel.manualIP == "10.25.90.2", "manualIP updates in memory")
        check(persistSuite.string(forKey: "matchsticks.manualIP") == "10.25.90.2",
              "manualIP didSet persists to the injected suite")
        persistModel.manualIP = ""
        check(persistSuite.object(forKey: "matchsticks.manualIP") == nil,
              "clearing manualIP removes the persisted value through didSet")

        let frozenSuite = makeSuite(suiteNames[2])
        frozenSuite.set("10.0.0.9", forKey: "matchsticks.manualIP")
        let frozenModel = DSModel(settingsDefaults: frozenSuite, persistenceEnabled: false)
        check(!frozenModel.persistenceEnabled, "injected persistence switch is honored")
        frozenModel.manualIP = "127.0.0.1"
        check(frozenModel.manualIP == "127.0.0.1", "manualIP still updates in memory when persistence is disabled")
        check(frozenSuite.string(forKey: "matchsticks.manualIP") == "10.0.0.9",
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

        // 第三方 Radio（Cudy TR1200）：独立地址持久化、恢复、草稿校验与机器人目标解耦
        let cudySuite = makeSuite(suiteNames[16])
        let cudyModel = DSModel(settingsDefaults: cudySuite, persistenceEnabled: true)
        cudyModel.manualRadioIP = "192.168.10.1"
        check(cudyModel.manualRadioIP == "192.168.10.1", "Cudy Radio address updates in memory")
        check(cudySuite.string(forKey: "matchsticks.manualRadioIP") == "192.168.10.1",
              "Cudy Radio address persists independently of the robot manualIP")
        check(cudyModel.currentRadioTarget?.host == "192.168.10.1" && cudyModel.currentRadioTarget?.port == 80,
              "the model exposes the actual third-party Radio probe target")
        cudyModel.manualRadioIP = ""
        check(cudySuite.object(forKey: "matchsticks.manualRadioIP") == nil,
              "clearing the manual Radio address removes the persisted value")

        let restoredRadioSuite = makeSuite(suiteNames[17])
        restoredRadioSuite.set(2590, forKey: "matchsticks.teamNumber")
        restoredRadioSuite.set("192.168.10.1", forKey: "matchsticks.manualRadioIP")
        let restoredRadioModel = DSModel(settingsDefaults: restoredRadioSuite, persistenceEnabled: true)
        restoredRadioModel.loadPersistedSettings()
        check(restoredRadioModel.manualRadioIP == "192.168.10.1" && restoredRadioModel.currentRadioTarget?.host == "192.168.10.1",
              "a saved Cudy Radio address is restored before probing starts")

        let frozenRadioSuite = makeSuite(suiteNames[18])
        frozenRadioSuite.set("192.168.10.9", forKey: "matchsticks.manualRadioIP")
        let frozenRadioModel = DSModel(settingsDefaults: frozenRadioSuite, persistenceEnabled: false)
        frozenRadioModel.manualRadioIP = "192.168.10.1"
        check(frozenRadioModel.currentRadioTarget?.host == "192.168.10.1" &&
              frozenRadioSuite.string(forKey: "matchsticks.manualRadioIP") == "192.168.10.9",
              "disabled persistence still updates the live Radio target without rewriting settings")

        let cudyDraftModel = DSModel(settingsDefaults: makeSuite(suiteNames[16]), persistenceEnabled: true)
        cudyDraftModel.teamNumber = 2590
        cudyDraftModel.manualRadioIP = "192.168.10.1"
        let cudyDraft = ConnectionDraft()
        cudyDraft.load(from: cudyDraftModel)
        check(cudyDraft.radioIPText == "192.168.10.1" && !cudyDraft.hasChanges(comparedTo: cudyDraftModel),
              "the connection draft loads the applied Cudy Radio address")
        cudyDraft.radioIPText = "192.168.10"
        check(cudyDraft.parsedRadioTarget == nil && cudyDraft.hasChanges(comparedTo: cudyDraftModel),
              "an invalid Radio address keeps the draft dirty")
        check(!cudyDraft.apply(to: cudyDraftModel) && cudyDraftModel.manualRadioIP == "192.168.10.1" &&
              cudyDraftModel.manualIP.isEmpty,
              "an invalid Radio address rejects the whole apply without partial robot changes")
        cudyDraft.radioIPText = " 192.168.10.1\n"
        check(cudyDraft.parsedRadioTarget == .manualIP("192.168.10.1") &&
              !cudyDraft.hasChanges(comparedTo: cudyDraftModel),
              "Radio address validation trims harmless surrounding whitespace")
        cudyDraft.targetText = "192.168.10.2"
        check(cudyDraft.apply(to: cudyDraftModel), "robot and Cudy addresses apply together")
        check(cudyDraftModel.manualIP == "192.168.10.2" && cudyDraftModel.manualRadioIP == "192.168.10.1" &&
              cudyDraftModel.teamNumber == 2590,
              "robot and Radio addresses stay independent in the Cudy subnet")
        cudyDraft.radioIPText = ""
        check(cudyDraft.parsedRadioTarget == .automatic && cudyDraft.apply(to: cudyDraftModel),
              "blank Radio input selects automatic team-derived probing")
        check(cudyDraftModel.manualRadioIP.isEmpty && cudyDraftModel.manualIP == "192.168.10.2" &&
              cudyDraftModel.currentRadioTarget?.host == "10.25.90.1",
              "returning to automatic Radio probing does not clear the robot address")
        cudyDraftModel.manualRadioIP = "192.168.10.1"
        cudyDraft.load(from: cudyDraftModel)
        cudyDraft.targetText = "0"
        check(cudyDraft.apply(to: cudyDraftModel) && cudyDraftModel.manualRadioIP == "192.168.10.1",
              "changing the robot target never silently clears the independent Radio address")

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
        rebuiltAudio.practiceCountdownSpeech = CountdownSpeechSpy()
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
            legacyAudio.practiceCountdownSpeech = CountdownSpeechSpy()
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
        stopAudio.practiceCountdownSpeech = CountdownSpeechSpy()
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

        let interruptedAudio = DSModel(settingsDefaults: makeSuite(suiteNames[7]), persistenceEnabled: false)
        interruptedAudio.practiceCountdownSpeech = CountdownSpeechSpy()
        interruptedAudio.practiceSeasonYear = 2026
        interruptedAudio.practiceAutoTime = 0.1
        interruptedAudio.practiceDelayTime = 0.1
        interruptedAudio.practiceStartDelay = 0
        interruptedAudio.practiceTransitionShiftTime = 0.1
        interruptedAudio.practiceAllianceShiftTime = 5
        interruptedAudio.practiceEndgameTime = 5
        var interruptedPlayed: [String] = []
        // 不自动 finishCurrent：模拟音效仍在播放，后续普通音效只能排队
        interruptedAudio.practiceAudio.playHandler = { interruptedPlayed.append($0) }
        interruptedAudio.practiceAudio.finishHandler = {}
        interruptedAudio.startPractice()
        let interruptedDeadline = Date().addingTimeInterval(0.45)
        while Date() < interruptedDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        interruptedAudio.practiceAudio.finishCurrent() // CHARGE 结束 → ENDMATCH
        interruptedAudio.practiceAudio.finishCurrent() // ENDMATCH 结束 → 3BELLS 开始播放
        check(interruptedPlayed == ["CHARGE", "ENDMATCH", "3BELLS"],
              "A-Stop setup: Teleop start is playing while later cues wait in the queue")
        interruptedAudio.aStop()
        check(interruptedPlayed == ["CHARGE", "ENDMATCH", "3BELLS", "FOGHORN"],
              "A-Stop preempts the playing cue and discards queued cues before Foghorn")
        interruptedAudio.practiceAudio.finishCurrent()
        check(interruptedPlayed == ["CHARGE", "ENDMATCH", "3BELLS", "FOGHORN"],
              "no queued practice cue resumes after the A-Stop Foghorn")

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
        check(dashboardSuite.string(forKey: "matchsticks.dashboards") == "AdvantageScope,Shuffleboard",
              "selection persists immediately in canonical order")
        check(dashboardSuite.string(forKey: "matchsticks.dashboardKind") == "AdvantageScope",
              "legacy single-select key mirrors the first selection")
        let restoredDashboard = DSModel(settingsDefaults: dashboardSuite, persistenceEnabled: true)
        restoredDashboard.loadPersistedSettings()
        check(restoredDashboard.dashboardSelection == [.advantageScope, .shuffleboard],
              "multi-selection restores after restart")

        dashboardModel.dashboardSelection = []
        check(dashboardSuite.string(forKey: "matchsticks.dashboards") == "",
              "empty selection persists as an empty list")
        let restoredEmpty = DSModel(settingsDefaults: dashboardSuite, persistenceEnabled: true)
        restoredEmpty.loadPersistedSettings()
        check(restoredEmpty.dashboardSelection.isEmpty,
              "empty selection survives restart instead of falling back to a default")
        check(restoredEmpty.dashboardKind == nil,
              "legacy view reports no selection when all dashboards are unchecked")

        // 旧版单选键：新键缺失 → 直接恢复；新键损坏 → 回退旧键（外部数据容错）
        let legacySuite = makeSuite(suiteNames[9])
        legacySuite.set("Shuffleboard", forKey: "matchsticks.dashboardKind")
        let legacyDashboard = DSModel(settingsDefaults: legacySuite, persistenceEnabled: true)
        legacyDashboard.loadPersistedSettings()
        check(legacyDashboard.dashboardSelection == [.shuffleboard],
              "legacy dashboardKind setting restores as a single selection")
        legacySuite.set("AdvantageScope,Bogus", forKey: "matchsticks.dashboards")
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
        check(frozenDashSuite.object(forKey: "matchsticks.dashboards") == nil,
              "disabled persistence leaves dashboard storage untouched")

        // ⑭ Enable/Disable 音效：默认开启、独立开关、持久化/WebUI、四种映射与安全边界
        let preferenceSuite = makeSuite(suiteNames[12])
        let preferenceModel = DSModel(settingsDefaults: preferenceSuite, persistenceEnabled: true)
        check(preferenceModel.enableDisableSoundsEnabled, "Enable/Disable sounds default to on")
        check(preferenceSuite.object(forKey: "matchsticks.enableDisableSoundsEnabled") == nil,
              "fresh install needs no explicit Enable/Disable sound override")
        preferenceModel.enableDisableSoundsEnabled = false
        check(preferenceSuite.bool(forKey: "matchsticks.enableDisableSoundsEnabled") == false,
              "Enable/Disable sound preference persists immediately")
        let restoredPreference = DSModel(settingsDefaults: preferenceSuite, persistenceEnabled: true)
        restoredPreference.loadPersistedSettings()
        check(!restoredPreference.enableDisableSoundsEnabled, "Enable/Disable sound preference survives restart")
        check(restoredPreference.webSettingsSnapshot()["enableDisableSoundsEnabled"] == "false",
              "WebUI snapshot exposes the new sound preference")
        check(restoredPreference.applyWebSetting(key: "enableDisableSoundsEnabled", value: "true") == nil &&
              restoredPreference.enableDisableSoundsEnabled, "WebUI can enable the new sound preference")
        check(restoredPreference.applyWebSetting(key: "enableDisableSoundsEnabled", value: "maybe") != nil &&
              restoredPreference.enableDisableSoundsEnabled, "invalid WebUI values leave the preference unchanged")

        check(DSModel.enableDisableSoundFileName(mode: .teleoperated, enabled: true, year: 2026) == "3BELLS",
              "Teleop Enable uses the Teleop-start bells")
        check(DSModel.enableDisableSoundFileName(mode: .teleoperated, enabled: false, year: 2026) == "ENDMATCH",
              "Teleop Disable uses the match-end buzzer")
        check(DSModel.enableDisableSoundFileName(mode: .autonomous, enabled: true, year: 2026) == "CHARGE",
              "Auto Enable uses the match-start charge")
        check(DSModel.enableDisableSoundFileName(mode: .autonomous, enabled: false, year: 2026) == "ENDMATCH",
              "Auto Disable uses the auto-end buzzer")
        check(DSModel.enableDisableSoundFileName(mode: .test, enabled: true, year: 2026) == nil &&
              DSModel.enableDisableSoundFileName(mode: .test, enabled: false, year: 2026) == nil,
              "Test mode has no unspecified Enable/Disable cue")

        let cueModel = DSModel(settingsDefaults: makeSuite(suiteNames[13]), persistenceEnabled: false)
        cueModel.commState = .connected(host: "127.0.0.1")
        cueModel.soundsEnabled = false
        var cues: [String] = []
        cueModel.practiceAudio.playHandler = {
            cues.append($0)
            cueModel.practiceAudio.finishCurrent()
        }
        cueModel.practiceAudio.finishHandler = {}
        cueModel.setMode(.autonomous)
        cueModel.setEnabled(true)
        cueModel.setEnabled(true)
        cueModel.setEnabled(false)
        cueModel.setEnabled(false)
        cueModel.setMode(.teleoperated)
        cueModel.setEnabled(true)
        cueModel.setEnabled(false)
        check(cues == ["CHARGE", "ENDMATCH", "3BELLS", "ENDMATCH"],
              "operator cues follow mode and only actual state flips; phase-sound preference is independent")
        cueModel.enableDisableSoundsEnabled = false
        cueModel.setEnabled(true)
        cueModel.setEnabled(false)
        check(cues == ["CHARGE", "ENDMATCH", "3BELLS", "ENDMATCH"],
              "turning off Enable/Disable sounds suppresses only new operator cues")
        cueModel.enableDisableSoundsEnabled = true
        cueModel.setEnabled(true)
        let cuesBeforeEstop = cues
        var estopPlayed = false
        cueModel.estopSoundPlayer = { estopPlayed = true }
        cueModel.triggerEstop()
        check(estopPlayed && cues == cuesBeforeEstop, "E-Stop keeps its own sound without an extra match-end cue")
        cueModel.resetEstop()
        cueModel.enableDisableSoundsEnabled = false
        estopPlayed = false
        cueModel.triggerEstop()
        check(cueModel.estopEngaged && !estopPlayed && cues == cuesBeforeEstop,
              "turning off Enable/Disable sounds also silences the E-Stop horn")
        cueModel.resetEstop()
        cueModel.enableDisableSoundsEnabled = true
        cueModel.triggerEstop()
        check(cueModel.estopEngaged && estopPlayed && cues == cuesBeforeEstop,
              "turning Enable/Disable sounds back on restores the E-Stop horn")

        let readyModel = DSModel(settingsDefaults: makeSuite(suiteNames[13]), persistenceEnabled: false)
        readyModel.commState = .connected(host: "127.0.0.1")
        check(readyModel.enableExplanation.isEmpty, "the ready state no longer shows the area-clear reminder")
        readyModel.commState = .searching
        check(!readyModel.enableExplanation.isEmpty, "the missing-connection explanation remains")

        let deniedModel = DSModel(settingsDefaults: makeSuite(suiteNames[14]), persistenceEnabled: false)
        var deniedCues: [String] = []
        deniedModel.practiceAudio.playHandler = { deniedCues.append($0) }
        deniedModel.setEnabled(true)
        check(!deniedModel.enabled && deniedCues.isEmpty, "safety-gate denial does not play an Enable cue")

        let timeoutCueModel = DSModel(settingsDefaults: makeSuite(suiteNames[15]), persistenceEnabled: false)
        timeoutCueModel.practiceSeasonYear = 2022
        timeoutCueModel.commState = .connected(host: "127.0.0.1")
        timeoutCueModel.setMode(.teleoperated)
        var timeoutCues: [String] = []
        timeoutCueModel.practiceAudio.playHandler = {
            timeoutCues.append($0)
            timeoutCueModel.practiceAudio.finishCurrent()
        }
        timeoutCueModel.practiceAudio.finishHandler = {}
        timeoutCueModel.setEnabled(true)
        timeoutCueModel.startTimeout()
        check(timeoutCues == ["3BELLS"], "starting Timeout auto-disables without an extra match-end cue")
        timeoutCueModel.cancelTimeout()

        let connectedPractice = DSModel(settingsDefaults: makeSuite(suiteNames[15]), persistenceEnabled: false)
        connectedPractice.practiceCountdownSpeech = CountdownSpeechSpy()
        connectedPractice.commState = .connected(host: "127.0.0.1")
        connectedPractice.practiceSeasonYear = 2026
        connectedPractice.practiceAutoTime = 0.1
        connectedPractice.practiceDelayTime = 0.1
        connectedPractice.practiceStartDelay = 0
        connectedPractice.practiceTransitionShiftTime = 0.1
        connectedPractice.practiceAllianceShiftTime = 0.1
        connectedPractice.practiceEndgameTime = 0.1
        var connectedCues: [String] = []
        connectedPractice.practiceAudio.playHandler = {
            connectedCues.append($0)
            connectedPractice.practiceAudio.finishCurrent()
        }
        connectedPractice.practiceAudio.finishHandler = {}
        connectedPractice.startPractice()
        let connectedDeadline = Date().addingTimeInterval(1.4)
        while Date() < connectedDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        check(connectedCues == ["CHARGE", "ENDMATCH", "3BELLS", "PowerUp_LinearPop", "PowerUp_LinearPop",
                                "PowerUp_LinearPop", "PowerUp_LinearPop", "WARNEOM_2026", "ENDMATCH"],
              "connected practice adds no operator cues on automatic enable/disable")

        // ===== Task 2：比赛信息 / 录制持久化（2026-11-22）=====

        let task2SuiteNames = (0..<8).map { _ in "org.ghfrc.driverstation.test.uitests.task2.\(UUID().uuidString)" }

        // ⑮ 比赛信息：赛事 / Game Data / 场次类型 即时落盘、重启恢复、清空不残留、非法场次类型忽略
        let matchSuite = makeSuite(task2SuiteNames[1])
        let matchModel = DSModel(settingsDefaults: matchSuite, persistenceEnabled: true)
        check(matchModel.competition.isEmpty && matchModel.gameData.isEmpty && matchModel.matchType == 0,
              "match info defaults are empty")
        matchModel.competition = "Midwest Regional"
        matchModel.gameData = "LRL"
        matchModel.matchType = 2
        check(matchSuite.string(forKey: "matchsticks.competition") == "Midwest Regional",
              "competition persists immediately")
        check(matchSuite.string(forKey: "matchsticks.gameData") == "LRL",
              "game data persists immediately")
        check(matchSuite.integer(forKey: "matchsticks.matchType") == 2,
              "match type persists immediately")
        let restoredMatch = DSModel(settingsDefaults: matchSuite, persistenceEnabled: true)
        restoredMatch.loadPersistedSettings()
        check(restoredMatch.competition == "Midwest Regional" && restoredMatch.gameData == "LRL" &&
              restoredMatch.matchType == 2,
              "match info round-trips across restart")
        matchModel.competition = ""
        matchModel.gameData = ""
        check(matchSuite.object(forKey: "matchsticks.competition") == nil &&
              matchSuite.object(forKey: "matchsticks.gameData") == nil,
              "clearing text fields removes the stored values instead of persisting empty strings")
        let restoredClearedMatch = DSModel(settingsDefaults: matchSuite, persistenceEnabled: true)
        restoredClearedMatch.loadPersistedSettings()
        check(restoredClearedMatch.competition.isEmpty && restoredClearedMatch.gameData.isEmpty,
              "cleared match info restores as defaults")
        for bad in [-1, 4, 255] {
            matchSuite.set(bad, forKey: "matchsticks.matchType")
            let invalidMatch = DSModel(settingsDefaults: matchSuite, persistenceEnabled: true)
            invalidMatch.loadPersistedSettings()
            check(invalidMatch.matchType == 0, "out-of-range stored match type \(bad) is ignored on restore")
        }
        matchSuite.set(true, forKey: "matchsticks.matchType")
        let booleanMatch = DSModel(settingsDefaults: matchSuite, persistenceEnabled: true)
        booleanMatch.loadPersistedSettings()
        check(booleanMatch.matchType == 0, "non-integer stored match type is ignored on restore")
        for edge in [0, 3] {
            matchSuite.set(edge, forKey: "matchsticks.matchType")
            let edgeMatch = DSModel(settingsDefaults: matchSuite, persistenceEnabled: true)
            edgeMatch.loadPersistedSettings()
            check(edgeMatch.matchType == UInt8(edge), "boundary match type \(edge) restores")
        }
        matchModel.matchType = 3
        let restoredTypeMatch = DSModel(settingsDefaults: matchSuite, persistenceEnabled: true)
        restoredTypeMatch.loadPersistedSettings()
        check(restoredTypeMatch.matchType == 3, "playoff match type restores")
        matchModel.matchType = 0
        let restoredNoneTypeMatch = DSModel(settingsDefaults: matchSuite, persistenceEnabled: true)
        restoredNoneTypeMatch.loadPersistedSettings()
        check(restoredNoneTypeMatch.matchType == 0, "unspecified match type restores as 0")

        let frozenMatchSuite = makeSuite(task2SuiteNames[2])
        let frozenMatch = DSModel(settingsDefaults: frozenMatchSuite, persistenceEnabled: false)
        frozenMatch.competition = "Frozen Regional"
        frozenMatch.gameData = "RRR"
        frozenMatch.matchType = 1
        check(frozenMatch.competition == "Frozen Regional" && frozenMatch.gameData == "RRR" && frozenMatch.matchType == 1,
              "match info still updates in memory when persistence is disabled")
        check(frozenMatchSuite.object(forKey: "matchsticks.competition") == nil &&
              frozenMatchSuite.object(forKey: "matchsticks.gameData") == nil &&
              frozenMatchSuite.object(forKey: "matchsticks.matchType") == nil,
              "disabled persistence leaves match info storage untouched")

        // ⑯ 录制偏好：即时落盘、重启恢复；恢复 true 按既有开关行为开始录制，
        //    但 Application Support 重定向到临时目录，测试绝不写真实用户抓包
        let previousSupportOverride = ProcessInfo.processInfo.environment[AppSupportDirectory.overrideEnvironmentKey]
        let scratchSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MatchSticks-DriverStaion-task2-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchSupport, withIntermediateDirectories: true)
        check(AppSupportDirectory.overrideEnvironmentKey == "MATCHSTICKS_DRIVER_STAION_APPLICATION_SUPPORT",
              "the Application Support override reads only the current MATCHSTICKS_DRIVER_STAION prefix")
        setenv(AppSupportDirectory.overrideEnvironmentKey, scratchSupport.path, 1)
        check(AppSupportDirectory().url.path == scratchSupport.appendingPathComponent("MatchSticksDriverStaion").path,
              "recording tests redirect Application Support to a scratch directory")

        let recordingSuite = makeSuite(task2SuiteNames[3])
        let recordingModel = DSModel(settingsDefaults: recordingSuite, persistenceEnabled: true)
        check(!recordingModel.recording, "packet recording defaults to off")
        recordingModel.recording = true
        check((recordingSuite.object(forKey: "matchsticks.recording") as? NSNumber)?.boolValue == true,
              "recording preference persists immediately")
        check(recordingModel.dsEvents.contains { $0.text.contains("抓包录制开始") },
              "starting recording logs the capture file")
        recordingModel.recording = false
        check((recordingSuite.object(forKey: "matchsticks.recording") as? NSNumber)?.boolValue == false,
              "turning recording off persists false")
        recordingSuite.set(true, forKey: "matchsticks.recording")
        let restoredRecording = DSModel(settingsDefaults: recordingSuite, persistenceEnabled: true)
        restoredRecording.loadPersistedSettings()
        check(restoredRecording.recording, "recording preference restores after restart")
        let scratchCaptures = AppSupportDirectory().subdirectory("captures", create: false)
        let scratchCaptureFiles = (try? FileManager.default.contentsOfDirectory(atPath: scratchCaptures.path)) ?? []
        // 文件名精确到秒：同一秒内两次开始会落到同名文件，故只断言重定向目录里确有抓包、不多于 2 个
        let scratchCaptureCount = scratchCaptureFiles.filter { $0.hasPrefix("capture-") && $0.hasSuffix(".dsrec") }.count
        check((1...2).contains(scratchCaptureCount),
              "recording writes capture files only into the redirected Application Support directory")
        check(restoredRecording.dsEvents.contains { $0.text.contains("抓包录制开始") },
              "restored recording logs its start like a manual toggle")
        restoredRecording.recording = false
        check(!restoredRecording.recording, "recording can be switched off after restore")
        check((recordingSuite.object(forKey: "matchsticks.recording") as? NSNumber)?.boolValue == false,
              "switching recording off after restore persists false")

        let untouchedRecordingSuite = makeSuite(task2SuiteNames[4])
        let untouchedRecording = DSModel(settingsDefaults: untouchedRecordingSuite, persistenceEnabled: true)
        untouchedRecording.loadPersistedSettings()
        check(!untouchedRecording.recording, "fresh install does not record")

        let frozenRecordingSuite = makeSuite(task2SuiteNames[5])
        let frozenRecording = DSModel(settingsDefaults: frozenRecordingSuite, persistenceEnabled: false)
        frozenRecording.recording = true
        frozenRecording.recording = false
        check(frozenRecordingSuite.object(forKey: "matchsticks.recording") == nil,
              "disabled persistence leaves recording storage untouched")

        // ⑰ 外观：system/light/dark 原始值与 NSAppearance 映射；像语言一样落盘并在持久化门控前恢复；
        //    切换经 NSApp.appearance 全局生效；测试结束恢复进程原外观，避免泄漏到其他用例
        let previousAppearance = NSApplication.shared.appearance
        check(AppearanceMode.allCases.map(\.rawValue) == ["system", "light", "dark"],
              "appearance modes are system, light and dark with stable raw values")
        check(AppearanceMode.system.nsAppearance == nil, "system appearance maps to nil so the app follows macOS")
        check(AppearanceMode.light.nsAppearance?.name == .aqua, "light appearance maps to aqua")
        check(AppearanceMode.dark.nsAppearance?.name == .darkAqua, "dark appearance maps to darkAqua")
        check(AppearanceMode.system.colorScheme == nil && AppearanceMode.light.colorScheme == .light &&
              AppearanceMode.dark.colorScheme == .dark,
              "optional color scheme mapping mirrors the appearance")
        check(AppearanceMode(rawValue: "dark") == .dark && AppearanceMode(rawValue: "neon") == nil,
              "appearance raw values round-trip and reject unknown values")

        let appearanceSuite = makeSuite(task2SuiteNames[6])
        let appearanceModel = DSModel(settingsDefaults: appearanceSuite, persistenceEnabled: true)
        check(appearanceModel.appearanceMode == .system, "appearance defaults to following the system")
        check(appearanceSuite.object(forKey: "matchsticks.appearance") == nil,
              "fresh install needs no explicit appearance override")
        appearanceModel.appearanceMode = .dark
        check(appearanceSuite.string(forKey: "matchsticks.appearance") == "dark", "appearance persists immediately")
        check(NSApplication.shared.appearance?.name == .darkAqua, "choosing dark applies the dark app appearance")
        appearanceModel.appearanceMode = .light
        check(NSApplication.shared.appearance?.name == .aqua, "choosing light applies the aqua app appearance")
        appearanceModel.appearanceMode = .system
        check(NSApplication.shared.appearance == nil, "choosing system restores the nil app appearance")
        appearanceModel.appearanceMode = .dark
        let restoredAppearance = DSModel(settingsDefaults: appearanceSuite, persistenceEnabled: true)
        restoredAppearance.loadPersistedSettings()
        check(restoredAppearance.appearanceMode == .dark, "appearance survives restart")
        check(NSApplication.shared.appearance?.name == .darkAqua, "restored appearance is applied to the app on load")
        // 像语言一样：didSet 写入不设门控，所以先显式把 suite 置回 dark 再验证门控前恢复
        appearanceSuite.set("dark", forKey: "matchsticks.appearance")
        let frozenAppearance = DSModel(settingsDefaults: appearanceSuite, persistenceEnabled: false)
        frozenAppearance.loadPersistedSettings()
        check(frozenAppearance.appearanceMode == .dark && NSApplication.shared.appearance?.name == .darkAqua,
              "appearance restores before the persistence guard like language")
        frozenAppearance.appearanceMode = .light
        check(appearanceSuite.string(forKey: "matchsticks.appearance") == "light",
              "appearance writes like language regardless of the persistence switch")
        frozenAppearance.appearanceMode = .system
        appearanceSuite.set("neon", forKey: "matchsticks.appearance")
        let corruptAppearance = DSModel(settingsDefaults: appearanceSuite, persistenceEnabled: true)
        corruptAppearance.loadPersistedSettings()
        check(corruptAppearance.appearanceMode == .system && NSApplication.shared.appearance == nil,
              "unknown stored appearance falls back to system without touching the app appearance")

        // ⑱ 全设置重启往返：Settings 页每个控件取非默认值 → 新模型 loadPersistedSettings 全部恢复
        let restartSuite = makeSuite(task2SuiteNames[7])
        let beforeRestart = DSModel(settingsDefaults: restartSuite, persistenceEnabled: true)
        beforeRestart.languageMode = .english
        beforeRestart.appearanceMode = .dark
        beforeRestart.iconStyle = .monochrome
        beforeRestart.iconAppearance = .dark
        beforeRestart.practiceSeasonYear = 2022
        beforeRestart.dashboardSelection = [.elastic, .shuffleboard]
        beforeRestart.soundsEnabled = false
        beforeRestart.enableDisableSoundsEnabled = false
        beforeRestart.competition = "Midwest Regional"
        beforeRestart.matchType = 3
        beforeRestart.gameData = "LRL"
        beforeRestart.dslogEnabled = false
        beforeRestart.recording = true
        let afterRestart = DSModel(settingsDefaults: restartSuite, persistenceEnabled: true)
        afterRestart.loadPersistedSettings()
        var restartMismatch: [String] = []
        if afterRestart.languageMode != .english { restartMismatch.append("language") }
        if afterRestart.appearanceMode != .dark { restartMismatch.append("appearance") }
        if afterRestart.iconStyle != .monochrome { restartMismatch.append("icon style") }
        if afterRestart.iconAppearance != .dark { restartMismatch.append("icon appearance") }
        if afterRestart.practiceSeasonYear != 2022 { restartMismatch.append("season") }
        if afterRestart.dashboardSelection != [.elastic, .shuffleboard] { restartMismatch.append("dashboards") }
        if afterRestart.soundsEnabled { restartMismatch.append("phase sounds") }
        if afterRestart.enableDisableSoundsEnabled { restartMismatch.append("enable/disable sounds") }
        if afterRestart.competition != "Midwest Regional" { restartMismatch.append("competition") }
        if afterRestart.matchType != 3 { restartMismatch.append("match type") }
        if afterRestart.gameData != "LRL" { restartMismatch.append("game data") }
        if afterRestart.dslogEnabled { restartMismatch.append("session log") }
        if !afterRestart.recording { restartMismatch.append("recording") }
        check(restartMismatch.isEmpty, "every Settings control survives a restart round trip; lost: \(restartMismatch)")
        check(NSApplication.shared.appearance?.name == .darkAqua && LanguageManager.shared.mode == .english,
              "restart applies the restored appearance and language")
        beforeRestart.recording = false
        afterRestart.recording = false
        afterRestart.languageMode = .system
        afterRestart.appearanceMode = .system
        NSApplication.shared.appearance = previousAppearance

        // ⑲ Dashboard 多选分段与 DSSegmentedControl 文字段像素级一致（无图标、同底色、同字号）
        check(renderedDashboardSegmentsMatchSegmentedControl(),
              "Dashboard multi-select segments render exactly like DSSegmentedControl segments")

        if let previousSupportOverride {
            setenv(AppSupportDirectory.overrideEnvironmentKey, previousSupportOverride, 1)
        } else {
            unsetenv(AppSupportDirectory.overrideEnvironmentKey)
        }
        try? FileManager.default.removeItem(at: scratchSupport)
        check(!FileManager.default.fileExists(atPath: scratchSupport.path),
              "recording test scratch directory is removed")

        for name in suiteNames + [estopAudioSuiteName] + task2SuiteNames {
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

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/MatchSticksDriverStaion/Views/SettingsView.swift"), encoding: .utf8)) ?? ""
        let operationSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/MatchSticksDriverStaion/Views/OperationView.swift"), encoding: .utf8)) ?? ""
        let appSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/MatchSticksDriverStaion/MatchSticksDriverStaionApp.swift"), encoding: .utf8)) ?? ""
        let setupSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/MatchSticksDriverStaion/Views/SetupView.swift"), encoding: .utf8)) ?? ""
        let timingSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/MatchSticksDriverStaion/Views/PracticeTimingEditor.swift"), encoding: .utf8)) ?? ""
        let englishTable = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/DSCore/Resources/en.lproj/Localizable.strings"), encoding: .utf8)) ?? ""
        check(!settingsSource.isEmpty && !operationSource.isEmpty && !appSource.isEmpty &&
              !setupSource.isEmpty && !timingSource.isEmpty && !englishTable.isEmpty,
              "UI placement test loads its source fixtures")
        check(setupSource.contains("$draft.radioIPText") && setupSource.contains("Cudy TR1200") &&
              setupSource.contains("model.manualRadioIP"),
              "Connection exposes and synchronizes the independent Cudy TR1200 Radio address field")
        check(!settingsSource.contains("PracticeTimingEditor(model: model)"),
              "Settings no longer contains the practice duration editor")
        check(!operationSource.contains("PracticeTimingEditor(model: model)") &&
              operationSource.components(separatedBy: "PracticeMatchTimeline(model: model)").count - 1 == 1,
              "Drive removes Practice Timing and keeps exactly one Match Timeline")
        check(!settingsSource.contains("applyPracticeTimingPreset") &&
              !operationSource.contains("applyPracticeTimingPreset()") &&
              timingSource.components(separatedBy: "applyPracticeTimingPreset()").count - 1 == 1,
              "the official timing preset stays in the Match Timeline header, exactly once")
        check(!operationSource.contains("openSettings") && !appSource.contains("OperationView(model: model, openSettings:"),
              "the obsolete Adjust Practice Durations navigation is removed")
        check(!appSource.contains("tr(\"驾驶控制\")") && !appSource.contains(": model.uiStatus)"),
              "the Drive Controls status block is removed from the safety bar")
        check(!appSource.contains("tr(\"快捷键仅在前台、非文本输入时生效\")"),
              "the shortcuts footnote is removed from the safety bar")
        check(appSource.contains("if !model.enableExplanation.isEmpty || model.estopEngaged {") &&
              appSource.contains("model.resetEstop()"),
              "the safety bar keeps the conditional explanations and the mouse reset for a latched E-Stop")
        check(!englishTable.contains("\"驾驶控制\" = \"Drive Controls\";") &&
              !englishTable.contains("confirm the area is clear") &&
              !englishTable.contains("Shortcuts apply only in the foreground"),
              "translations for the removed safety-bar texts are deleted")

        // Task 1 放置守卫：恢复左驾驶、右练习赛与时间线的窄分栏；Practice Timing 移除。
        check(!setupSource.contains("1040") && !settingsSource.contains("1040"),
              "Connection and Settings content no longer caps at 1040 points")
        check(setupSource.contains(".frame(maxWidth: .infinity)") &&
              settingsSource.contains(".frame(maxWidth: .infinity)"),
              "Connection and Settings keep filling the available width")
        check(operationSource.contains("DSPanel(title: tr(\"练习赛\"))") &&
              !operationSource.contains("tr(\"自动练习\")"),
              "Drive practice panel is titled Practice Match")
        check(englishTable.contains("\"练习赛\" = \"Practice Match\";"),
              "Practice Match has an English translation")
        check(operationSource.contains("tr(\"开始练习赛\")") &&
              !operationSource.contains("tr(\"开始自动练习\")"),
              "the practice start button says Start Practice Match and still starts the full practice")
        check(englishTable.contains("\"开始练习赛\" = \"Start Practice Match\";") &&
              !englishTable.contains("Start Auto Practice"),
              "Start Practice Match is translated and the Auto wording is retired")
        check(sourceOrder(["DSPanel(title: tr(\"驾驶模式\"))", "DSPanel(title: tr(\"联盟站位\"))", "maintenancePanel",
                           "DSPanel(title: tr(\"练习赛\"))", "DSPanel(title: tr(\"比赛时间线\"),",
                           "PracticeMatchTimeline(model: model)", "if model.practiceSeasonYear == 2022"], in: operationSource),
              "Drive uses the narrow left driving column and the right practice/timeline column")
        check(!operationSource.contains("practiceTimingPanel"),
              "the old practice timing panel is removed")

        check(timingSource.contains("struct PracticeMatchTimeline: View") &&
              timingSource.contains("struct PracticeDurationCards: View") &&
              operationSource.contains("PracticeDurationCards(model: model)") &&
              !timingSource.contains("durationSummary") && !timingSource.contains("transitionTitle") &&
              !timingSource.contains("transitionTotal"),
              "the timeline and the two duration cards move out of the timing editor; " +
              "the Transition Shift summary card is gone")
        check(!operationSource.contains("arrow.right"),
              "the old inline Auto → Teleop duration row is replaced by the two duration cards")
        check(!timingSource.contains("compactSlider") && timingSource.contains("DragGesture(") &&
              timingSource.contains(".onEnded") && timingSource.contains("applyPracticeTimelineConfiguration"),
              "timeline dividers replace sliders with live drag and a single commit on release")
        let committedFields = ["practiceStartDelay": "startDelay", "practiceAutoTime": "autoTime",
                               "practiceDelayTime": "delayTime", "practiceTeleopTime": "teleopTime",
                               "practiceTransitionShiftTime": "transitionShift",
                               "practiceAllianceShiftTime": "allianceShift", "practiceEndgameTime": "endgame"]
        for (property, field) in committedFields {
            check(timingSource.components(separatedBy: "\(property) = configuration.\(field)").count - 1 == 1,
                  "release commits \(property) exactly once from the dragged configuration")
        }
        check(timingSource.contains(".multilineTextAlignment(.center)"),
              "Transition Shift and all other segment titles are explicitly centered")
        check(!timingSource.contains("clockMinimumWidth") &&
              timingSource.components(separatedBy: "ForEach(layout.items)").count - 1 >= 2,
              "every segment, including the 3-second Transition Shift, receives start/end time labels")
        check(timingSource.contains("if item.segment.duration <= 3 {"),
              "any segment of 3 seconds or less, including Transition Shift or Auto→Teleop, suppresses its title and shows only seconds")
        for key in ["拖动分隔线调整各阶段时长；用于下一次练习。", "左右拖动，松开后保存", "拖动调整 %@ 与 %@ 的时长"] {
            check(englishTable.contains("\"\(key)\" = \""), "English translation exists for timeline drag text: \(key)")
        }

        // ===== Drive 时间线改造回归（2026-11-23）：真实渲染几何 / 像素 =====
        // 固定 2026 比例：Auto 20 + 过渡 3 + Transition Shift 10 + 4×25 + Endgame 30 = 163 秒，开始等待 0。
        let timelineModel = DSModel()
        timelineModel.practiceSeasonYear = 2026
        timelineModel.practiceStartDelay = 0
        timelineModel.practiceAutoTime = 20
        timelineModel.practiceDelayTime = 3
        timelineModel.practiceTransitionShiftTime = 10
        timelineModel.practiceAllianceShiftTime = 25
        timelineModel.practiceEndgameTime = 30
        let timelineConfiguration = PracticeTimingConfiguration(
            seasonYear: 2026, startDelay: 0, autoTime: 20, delayTime: 3,
            teleopTime: 0, transitionShift: 10, allianceShift: 25, endgame: 30
        )

        // 值级回归：m:ss 纯函数与时长卡取自 live configuration 的正确字段。
        check(practiceClock(20) == "0:20" && practiceClock(140) == "2:20" &&
              practiceClock(0) == "0:00" && practiceClock(59.6) == "1:00",
              "the m:ss formatter renders 20 s → 0:20 and 140 s → 2:20 with rounding")
        check(timelineModel.practiceTimingConfiguration.durationCardValues.auto == 20 &&
              timelineModel.practiceTimingConfiguration.durationCardValues.teleop == 140,
              "duration cards read Auto and Teleop totals from the live configuration")
        timelineModel.practiceTransitionShiftTime = 12
        check(timelineModel.practiceTimingConfiguration.durationCardValues.teleop == 142,
              "duration card Teleop follows live sub-phase edits")
        timelineModel.practiceTransitionShiftTime = 10

        let dragBoundary = PracticeTimeline.editingBoundaries(for: timelineModel.practiceTimingConfiguration)[2]
        let draggedConfiguration = PracticeTimeline.configuration(
            timelineModel.practiceTimingConfiguration, dragging: dragBoundary, deltaSeconds: 2)
        timelineModel.applyPracticeTimelineConfiguration(draggedConfiguration)
        check(timelineModel.practiceDelayTime == 5 && timelineModel.practiceTransitionShiftTime == 8 &&
              timelineModel.practiceTimingConfiguration.totalDuration == timelineConfiguration.totalDuration,
              "releasing a divider drag commits both adjacent durations to the model without changing total duration")
        timelineModel.practiceDelayTime = 3
        timelineModel.practiceTransitionShiftTime = 10

        // 独立渲染时间线：宽窗（1000）与较窄窗口（560）下轨道都占满全宽、
        // 区段落在比例位置，Transition / Transition Shift 等区段内真实画出了文字。
        for timelineWidth in [1000, 560] {
            guard let bitmap = renderedBitmap(PracticeMatchTimeline(model: timelineModel)
                .frame(width: CGFloat(timelineWidth), height: 160),
                width: timelineWidth, height: 160) else {
                check(false, "match timeline renders a bitmap at \(timelineWidth) points wide")
                continue
            }
            guard let track = timelineTrackBounds(bitmap) else {
                check(false, "match timeline renders a proportional segment track at \(timelineWidth) points wide")
                continue
            }
            let layout = PracticeTimeline.layout(for: timelineConfiguration, totalWidth: Double(timelineWidth))
            check(layout.items.first?.segment.kind == .autonomous,
                  "zero start delay puts Autonomous first on the timeline")
            let probeRow = track.rows.lowerBound + 4
            for item in layout.items {
                let start = Int(item.x.rounded())
                let end = Int((item.x + item.width).rounded()) - 1
                let fill = segmentFill(item.segment.kind)
                if let run = fillRunEdges(bitmap, y: probeRow, middleX: (start + end) / 2, hex: fill) {
                    check(abs(run.start - start) <= 2 && abs(run.end - end) <= 2,
                          "\(item.segment.kind.rawValue) renders at its proportional bounds at \(timelineWidth) points")
                } else {
                    check(false, "\(item.segment.kind.rawValue) renders at its proportional bounds at \(timelineWidth) points")
                }
                if item.segment.duration <= 3 {
                    check(segmentShowsAnyText(bitmap, track: track, start: start, end: end, fill: fill),
                          "a segment of 3 seconds or less shows only its seconds without requiring title space at \(timelineWidth) points")
                } else if item.width >= 8 {
                    check(segmentShowsText(bitmap, track: track, start: start, end: end, fill: fill),
                          "\(item.segment.kind.rawValue) shows its title with fully rendered seconds at \(timelineWidth) points")
                }
            }
            if let autoRun = fillRunEdges(bitmap, y: probeRow, middleX: 4, hex: segmentFill(.autonomous)),
               let endRun = fillRunEdges(bitmap, y: probeRow, middleX: timelineWidth - 5, hex: segmentFill(.endgame)) {
                check(autoRun.start <= 2 && endRun.end >= timelineWidth - 3,
                      "the timeline track spans the full width at \(timelineWidth) points")
            } else {
                check(false, "the timeline track spans the full width at \(timelineWidth) points")
            }
        }

        // 两张时长卡独立渲染：Autonomous 深蓝 + Teleop 蓝并排等宽，无 Transition Shift 黄卡。
        if let cardsBitmap = renderedBitmap(PracticeDurationCards(model: timelineModel)
            .frame(width: 420, height: 96), width: 420, height: 96) {
            let navyPixels = pixelsWhere(cardsBitmap, hex: 0x131F25, xRange: 0..<420, yRange: 0..<96)
            let bluePixels = pixelsWhere(cardsBitmap, hex: 0x007BC0, xRange: 0..<420, yRange: 0..<96)
            let yellowPixels = pixelsWhere(cardsBitmap, hex: 0xF2D14B, xRange: 0..<420, yRange: 0..<96)
            check(!navyPixels.isEmpty && !bluePixels.isEmpty,
                  "Practice Match renders the Autonomous and Teleop duration cards")
            if let navyBox = boundingBox(navyPixels), let blueBox = boundingBox(bluePixels) {
                check(navyBox.maxX < blueBox.minX,
                      "the Autonomous card sits left of the Teleop card")
                check(abs((navyBox.maxX - navyBox.minX) - (blueBox.maxX - blueBox.minX)) <= 12,
                      "the two duration cards share one width")
                check(navyBox.maxY - navyBox.minY >= 50 && blueBox.maxY - blueBox.minY >= 50,
                      "the duration cards keep their card height")
            }
            check(yellowPixels.isEmpty, "no third Transition Shift card renders")
        } else {
            check(false, "duration cards render a bitmap")
        }

        // 整页渲染：左侧 Drive Mode / Alliance Station / 维护，右侧 Practice Match / Match Timeline。
        // ScrollView 在 ImageRenderer 下不出内容，改走真实离屏窗口 + cacheDisplay。
        for (driveWidth, driveHeight) in [(1200, 1150), (760, 1050)] {
            guard let drive = windowRenderedBitmap(OperationView(model: timelineModel)
                .frame(width: CGFloat(driveWidth), height: CGFloat(driveHeight))
                .background(DSTheme.canvas),
                width: driveWidth, height: driveHeight) else {
                check(false, "drive page renders a bitmap at \(driveWidth) points wide")
                continue
            }
            guard let track = timelineTrackBounds(drive) else {
                check(false, "drive page renders the match timeline track at \(driveWidth) points wide")
                continue
            }
            let fillRow = track.rows.lowerBound + 10
            let allianceRows = rowsContaining(drive, hex: 0xFF3B30)
            check(!allianceRows.isEmpty,
                  "alliance station renders its red alliance group at \(driveWidth) points")
            guard let allianceLast = allianceRows.last else { continue }
            let panelRow = allianceLast + 8
            let alliance = whiteRun(drive, y: panelRow, xRange: 0..<(driveWidth / 2))
            // 760pt 下页面高过窗口而出现纵向滚动条：传统样式滚动条占去右侧布局宽度，右栏到达其左侧的内容右缘
            let scrollerWidth = Int(NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
            check(alliance.start <= 30 && alliance.end <= driveWidth / 2 - 8,
                  "Alliance Selection stays narrow in the left driving column at \(driveWidth) points")
            if let trackStart = segmentPixel(drive, y: fillRow, last: false),
               let trackEnd = segmentPixel(drive, y: fillRow, last: true) {
                check(trackStart > driveWidth / 2 - 20 && trackStart > alliance.end + 8,
                      "the match timeline lives in the right practice column at \(driveWidth) points")
                check(trackEnd >= driveWidth - 31 - scrollerWidth,
                      "the timeline track reaches the right content edge at \(driveWidth) points")
            } else {
                check(false, "the timeline track extents can be measured at \(driveWidth) points")
            }
            check(maxVerticalRunOutsideRows(drive, hex: 0xF2D14B, rows: track.rows) < 30,
                  "no leftover Transition Shift card renders outside the timeline at \(driveWidth) points")

            // 上排右列 Practice Match：两张时长卡（Auto 深蓝 + Teleop 蓝），无黄色摘要卡。
            let topRows = 0..<max(1, track.rows.lowerBound - 8)
            let rightColumns = max(0, driveWidth / 2 - 60)..<driveWidth
            let navyPixels = pixelsWhere(drive, hex: 0x131F25, xRange: rightColumns, yRange: topRows)
            check(!navyPixels.isEmpty,
                  "Practice Match shows the Autonomous duration card in the top row at \(driveWidth) points")
            if let navyBox = boundingBox(navyPixels) {
                check(navyBox.maxX - navyBox.minX >= 90 && navyBox.maxY - navyBox.minY >= 50,
                      "the Autonomous card keeps its card size at \(driveWidth) points")
                let blueY = max(0, navyBox.minY - 10)..<(min(driveHeight - 1, navyBox.maxY + 10) + 1)
                let blueX = (navyBox.maxX + 1)..<driveWidth
                let bluePixels = pixelsWhere(drive, hex: 0x007BC0, xRange: blueX, yRange: blueY)
                check(!bluePixels.isEmpty,
                      "the Teleop card sits beside the Autonomous card at \(driveWidth) points")
                check(pixelsWhere(drive, hex: 0xF2D14B, xRange: rightColumns, yRange: topRows).isEmpty,
                      "no Transition Shift summary card remains in the Practice Match panel at \(driveWidth) points")
            }
        }

        // Accessibility：视效缩放/截断不影响语义，每个时间线区段保留「标题 + 秒数」的
        // accessibilityLabel（本测试进程实测 NSHostingView 的 accessibilityChildren 不物化，
        // 运行时 AX 树查询不可行，故以源级守卫 + 像素可见性共同覆盖无障碍信息）。
        check(timingSource.contains(".accessibilityElement(children: .ignore)") &&
              timingSource.contains(".accessibilityLabel(\"\\(presentation.title) \\(tr(\"%d 秒\", Int(item.segment.duration)))\")"),
              "every timeline segment keeps its title-plus-seconds accessibility label")

        // Task 2 放置守卫：外观行与语言行同构（360 宽）；Dashboard 无复选框图标，Launch 与分段控件同排紧邻其右。
        let controlsSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/MatchSticksDriverStaion/Views/DSControls.swift"), encoding: .utf8)) ?? ""
        check(!controlsSource.isEmpty, "UI placement test loads the control source fixture")
        if let generalStart = settingsSource.range(of: "private var generalPanel")?.lowerBound,
           let generalEnd = settingsSource.range(of: "private var dashboardPanel")?.lowerBound {
            let general = String(settingsSource[generalStart..<generalEnd])
            check(general.components(separatedBy: "settingsRow(").count - 1 == 4,
                  "General keeps Language, Appearance, Mini UI Reference and Season as settingsRow rows")
            check(general.contains("settingsSubgroup(tr(\"图标样式\")) {") &&
                  general.contains("settingsSubgroup(tr(\"图标外观\")) {"),
                  "app-icon settings render as full-width subgroups with titles above the cards")
            check(!general.contains("settingsRow(tr(\"图标样式\"))") &&
                  !general.contains("settingsRow(tr(\"图标外观\"))"),
                  "icon subgroups are not squeezed into right-aligned rows")
            check(sourceOrder(["$model.languageMode", "$model.appearanceMode", "$model.miniReferenceStyle",
                               "$model.practiceSeasonYear", "$model.iconStyle", "$model.iconAppearance"], in: general),
                  "the app-icon subgroups sit after Season inside General")
            check(general.contains("AppIconStyleCardPicker(title: tr(\"图标样式\"), selection: $model.iconStyle)") &&
                  general.contains("AppIconAppearanceCardPicker(title: tr(\"图标外观\"), style: model.iconStyle, selection: $model.iconAppearance)"),
                  "app-icon cards bind the model directly for immediate effect inside General")
            check(!general.contains("settingsGroup(tr(\"应用图标\"))") &&
                  !general.contains("Finder 与启动台图标由应用包提供"),
                  "General absorbs the app-icon settings without a separate group or gray footnote")
            check(general.contains("DSSegmentedControl(title: tr(\"外观\"), selection: $model.appearanceMode, options: [") &&
                  general.contains("DSSelectOption(value: AppearanceMode.system, label: tr(\"跟随系统\"))") &&
                  general.contains("DSSelectOption(value: AppearanceMode.light, label: tr(\"浅色\"))") &&
                  general.contains("DSSelectOption(value: AppearanceMode.dark, label: tr(\"深色\"))"),
                  "Appearance is a Follow System / Light / Dark segmented control like Language")
            check(general.components(separatedBy: ".frame(width: 360)").count - 1 == 2,
                  "Appearance and Language rows share the 360-point width")
        } else {
            check(false, "General panel source can be located")
        }
        check(englishTable.contains("\"外观\" = \"Appearance\";") && englishTable.contains("\"浅色\" = \"Light\";") &&
              englishTable.contains("\"深色\" = \"Dark\";"),
              "Appearance labels have English translations")
        if let dashboardStart = settingsSource.range(of: "private var dashboardPanel")?.lowerBound,
           let dashboardEnd = settingsSource.range(of: "private var audioPanel")?.lowerBound {
            let panel = String(settingsSource[dashboardStart..<dashboardEnd])
            check(!panel.contains("checkmark.square") && !panel.contains("\"square\"") && !panel.contains("Image(systemName:"),
                  "Dashboard multi-select renders text-only segments without checkbox icons")
            check(panel.contains("HStack(") && !panel.contains("VStack"),
                  "Launch Dashboard shares the Dashboard row's HStack instead of stacking below")
            if let controlStart = panel.range(of: "DSMultiSelectControl(")?.lowerBound,
               let controlEnd = panel.range(of: ".frame(width: 460)")?.upperBound,
               let launchStart = panel.range(of: "Button(tr(\"启动 Dashboard\"))")?.lowerBound {
                check(controlStart < controlEnd && controlEnd <= launchStart &&
                      panel[controlEnd..<launchStart].allSatisfy(\.isWhitespace),
                      "Launch Dashboard sits immediately to the right of the Dashboard control")
            } else {
                check(false, "Dashboard control and Launch button can be located in the row")
            }
            check(panel.components(separatedBy: "DSSelectOption(value:").count - 1 == 1,
                  "Launch Dashboard is a separate button, not a fourth segment")
            check(panel.contains(".disabled(model.dashboardSelection.isEmpty)"),
                  "Launch Dashboard stays disabled for an empty selection")
        } else {
            check(false, "Dashboard panel source can be located")
        }
        check(!settingsSource.contains("checkmark.square") && !settingsSource.contains("\"square\"") &&
              !controlsSource.contains("checkmark.square") && !controlsSource.contains("\"square\""),
              "neither Settings nor the shared multi-select control renders checkbox icons")

        // 监测区导航放置守卫：侧栏 Diagnostics/Charts 换成 Mac / 机器人 / 摄像头 三个并列入口；
        // 机器人页合并原诊断与三类历史曲线，Mac、摄像头独立成页，维护操作移入 Drive。
        let robotSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/MatchSticksDriverStaion/Views/RobotView.swift"), encoding: .utf8)) ?? ""
        let robotHistorySource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/MatchSticksDriverStaion/Views/RobotHistoryView.swift"), encoding: .utf8)) ?? ""
        let macStatusSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/MatchSticksDriverStaion/Views/MacStatusView.swift"), encoding: .utf8)) ?? ""
        let cameraSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/MatchSticksDriverStaion/Views/CameraView.swift"), encoding: .utf8)) ?? ""
        check(!robotSource.isEmpty && !robotHistorySource.isEmpty && !macStatusSource.isEmpty &&
              !cameraSource.isEmpty,
              "monitor navigation test loads its source fixtures")
        check(appSource.contains("pages: [.mac, .robot, .camera") &&
              !appSource.contains("case .diagnostics") && !appSource.contains("case .charts") &&
              !appSource.contains("DiagnosticsView(") && !appSource.contains("ChartsView("),
              "the sidebar replaces Diagnostics and Charts with Mac, Robot and Camera entries")
        check(appSource.contains("case .mac: MacStatusView(model: model)") &&
              appSource.contains("case .robot: RobotView(model: model)") &&
              appSource.contains("case .camera: CameraView(model: model)"),
              "Mac, Robot and Camera route to their dedicated pages")
        check(appSource.contains("tr(\"Mac\")") && appSource.contains("tr(\"机器人\")") &&
              appSource.contains("tr(\"摄像头\")"),
              "the three monitor pages are titled Mac, Robot and Camera")
        check(robotSource.contains("连接检查") && robotSource.contains("机器人资源") &&
              robotSource.contains("CAN 总线") && robotSource.contains("电源与故障计数") &&
              robotSource.contains("设备版本"),
              "Robot keeps the network, resources, CAN, power and versions diagnostics")
        check(robotSource.contains("RobotHistoryView(model: model)"),
              "Robot embeds the merged history charts")
        check(!robotSource.contains("这台 Mac") && !robotSource.contains("CameraMockPanel") &&
              !robotSource.contains("机器人维护"),
              "Robot no longer hosts Mac status, the camera panel or maintenance")
        check(robotHistorySource.contains("电池电压") && robotHistorySource.contains("机器人 CPU") &&
              robotHistorySource.contains("通信质量"),
              "history keeps the battery, CPU and link charts")
        check(!robotHistorySource.contains("当前读数"),
              "history drops the duplicated current-readings summary")
        check(!macStatusSource.isEmpty && macStatusSource.contains("model.macStatus"),
              "Mac status shows this-Mac readings from macStatus")
        check(cameraSource.contains("CameraMockPanel()"),
              "Camera keeps its own mock panel")
        check(operationSource.contains("机器人维护") &&
              operationSource.contains("model.restartRobotCode()") &&
              operationSource.contains("model.rebootRoboRIO()") &&
              operationSource.components(separatedBy: "confirmationDialog").count - 1 == 2 &&
              operationSource.components(separatedBy: ".disabled(!model.commConnected)").count - 1 == 2,
              "Drive hosts both restart actions behind confirmations and safety disables")
        check(!robotSource.contains("restartRobotCode") && !robotSource.contains("rebootRoboRIO"),
              "Robot no longer offers the restart actions")

        // ===== Permissions 页：权限状态呈现（2026-11-23）=====
        // 宽度与 Settings 一致：不再 1040 封顶，仍填满可用宽度
        let permissionsSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/MatchSticksDriverStaion/Views/PermissionsView.swift"), encoding: .utf8)) ?? ""
        check(!permissionsSource.isEmpty, "permissions source fixture loads")
        check(!permissionsSource.contains("1040") && permissionsSource.contains(".frame(maxWidth: .infinity)"),
              "Permissions content fills the available width like Settings instead of capping at 1040 points")

        // 本地网络证据：连接记录不是权限查询。真实非回环机器人 → success（唯一绿色来源）；
        // 回环模拟器 / 无连接 / 搜索中 → warning，不得显示为已授权
        check(LocalNetworkEvidence(commState: .connected(host: "10.25.90.2")) == .verifiedRobot &&
              LocalNetworkEvidence(commState: .connected(host: "10.25.90.2")).tone == .success,
              "a real robot connection is the only positive local network evidence")
        check(LocalNetworkEvidence(commState: .connected(host: "127.0.0.1")) == .loopbackSimulator &&
              LocalNetworkEvidence(commState: .connected(host: "localhost")) == .loopbackSimulator &&
              LocalNetworkEvidence(commState: .connected(host: "::1")) == .loopbackSimulator &&
              LocalNetworkEvidence(commState: .connected(host: "127.255.255.254")) == .loopbackSimulator &&
              LocalNetworkEvidence(commState: .connected(host: "128.0.0.1")) == .verifiedRobot,
              "loopback simulator hosts (127/8, localhost, ::1) are not robot evidence; 128/8 is not loopback")
        check(LocalNetworkEvidence(commState: .idle).tone == .warning &&
              LocalNetworkEvidence(commState: .searching).tone == .warning &&
              LocalNetworkEvidence(commState: .connected(host: "127.0.0.1")).tone == .warning,
              "no connection, searching and loopback simulator are warnings rather than green")
        check(LocalNetworkEvidence(commState: .connected(host: "10.25.90.2")).badge == "机器人通信正常" &&
              LocalNetworkEvidence(commState: .connected(host: "127.0.0.1")).badge == "已连接本机模拟器" &&
              LocalNetworkEvidence(commState: .idle).badge == "尚未通过连接验证",
              "network badge wording stays with its evidence state")
        check(LocalNetworkEvidence(commState: .connected(host: "10.25.90.2"))
                  .explanation(connectionDetail: "10.25.90.2") == tr("已与 %@ 建立通信，当前连接可用。", "10.25.90.2") &&
              LocalNetworkEvidence(commState: .connected(host: "127.0.0.1"))
                  .explanation(connectionDetail: "127.0.0.1") == tr("本机连接正常，但它不能验证真实机器人所需的本地网络权限。") &&
              LocalNetworkEvidence(commState: .idle)
                  .explanation(connectionDetail: tr("尚未连接"))
                  == tr("目前没有机器人连接记录可用于确认网络访问。连接失败时，可先检查本地网络权限。"),
              "network explanations stay with their evidence state")
        check(LocalNetworkEvidence(commState: .connected(host: "10.25.90.2")).symbol == "checkmark.circle.fill" &&
              LocalNetworkEvidence(commState: .connected(host: "127.0.0.1")).symbol == "info.circle" &&
              LocalNetworkEvidence(commState: .idle).symbol == "info.circle",
              "network badge symbols stay with their evidence state")

        // 色调语义：success / warning / neutral 分别映射主题语义色；neutral 即 textSecondary
        check(PermissionTone.success.color == DSTheme.success &&
              PermissionTone.warning.color == DSTheme.warning &&
              PermissionTone.neutral.color == DSTheme.textSecondary,
              "permission tones map to the theme's success, warning and neutral colors")

        // 键盘快捷键：前台本地事件监听无需 Input Monitoring，徽章为 success；页面不得发起权限请求
        check(permissionsSource.contains("DSBadge(text: tr(\"无需额外授权\"), color: DSTheme.success"),
              "keyboard shortcuts badge uses the semantic success color")
        check(!permissionsSource.contains("CGRequestListenEventAccess") &&
              !permissionsSource.contains("CGRequestPostEventAccess"),
              "permissions page never requests Input Monitoring or Post Event access")
        let shortcutsSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/MatchSticksDriverStaion/Shortcuts.swift"), encoding: .utf8)) ?? ""
        check(shortcutsSource.contains("addLocalMonitorForEvents") &&
              !shortcutsSource.contains("addGlobalMonitorForEvents") &&
              !shortcutsSource.contains("CGEvent.tapCreate"),
              "keyboard shortcuts stay foreground-only local monitors that need no Input Monitoring")

        // 防火墙与本地网络：徽章读取启动级真实证据，不再把未检测写成永久状态
        check(permissionsSource.contains("DSBadge(text: firewallEvidence.badge") &&
                  permissionsSource.contains("color: firewallEvidence.tone.color") &&
                  !permissionsSource.contains("未检测系统防火墙配置"),
              "firewall badge is driven by verification evidence")
        check(permissionsSource.contains("private var networkEvidence: LocalNetworkEvidence { model.permissionMonitor.networkEvidence }") &&
                  !permissionsSource.contains("LocalNetworkEvidence(commState: model.commState)"),
              "local network badge uses launch-scoped evidence instead of recomputing from the current connection")
        check(permissionsSource.contains("if case .waiting(let url) = firewallEvidence") &&
                  permissionsSource.contains("model.restartPermissionVerification()") &&
                  permissionsSource.contains("在同一网络的另一台设备打开："),
              "permissions view exposes the ephemeral verification URL and a recheck action")
        check(englishTable.contains("\"在同一网络的另一台设备打开：\" = \"Open this URL from another device on the same network:\";") &&
                  englishTable.contains("\"验证成功后监听会自动关闭；重新启动应用会重新检测。\" = \"The listener closes after success; relaunch the app to check again.\";"),
              "firewall verification instructions have English translations")

        // Local Network 按钮：只请求打开「隐私与安全性」，不得暗示已直达本地网络子页面；
        // 旧系统的 x-apple.systempreferences 深链保留，成功提示也只说“已请求”而非“已打开”
        check(permissionsSource.contains("Button(tr(\"打开隐私与安全性\"))"),
              "local network button asks to open Privacy & Security without implying the Local Network pane")
        check(permissionsSource.contains(
                  "settingsMessage = tr(\"已请求打开系统设置；若未跳转到对应页面，请按上方路径进入。\")"),
              "opening System Settings reports a request rather than a confirmed pane")
        check(!permissionsSource.contains("打开本地网络设置") && !permissionsSource.contains("已打开系统设置"),
              "local network wording no longer claims the Local Network pane or System Settings was opened")
        check(permissionsSource.contains("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"),
              "local network button keeps the deep link for systems that still honor it")
        check(englishTable.contains("\"打开隐私与安全性\" = \"Open Privacy & Security\";") &&
              englishTable.contains("\"已请求打开系统设置；若未跳转到对应页面，请按上方路径进入。\" = \"Requested to open System Settings; if the right pane didn't come up, follow the path above.\";"),
              "the Privacy & Security button and request wording have English translations")

        print("MatchSticks Driver Station UI state: \(checks) checks, \(failures.count) failures")
        for failure in failures { print("FAIL: \(failure)") }
        exit(failures.isEmpty ? 0 : 1)
    }
}


/// 源码顺序守卫：各标记按给定先后出现（全部存在才算通过）。
private func sourceOrder(_ markers: [String], in text: String) -> Bool {
    var cursor = text.startIndex
    for marker in markers {
        guard let found = text.range(of: marker, range: cursor..<text.endIndex) else { return false }
        cursor = found.upperBound
    }
    return true
}

/// 同一选项、同一选中态下，多选分段控件与 DSSegmentedControl 的渲染逐采样点一致。
@MainActor
private func renderedDashboardSegmentsMatchSegmentedControl() -> Bool {
    let options = DashboardKind.allCases.map { DSSelectOption(value: $0, label: $0.rawValue) }
    let segmented = DSSegmentedControl(title: "Dashboard", selection: .constant(.elastic), options: options)
        .frame(width: 460, height: 32)
    let multiSelect = DSMultiSelectControl(title: "Dashboard", selection: .constant([.elastic]), options: options)
        .frame(width: 460, height: 32)
    guard let segmentedBitmap = renderedBitmap(segmented, width: 460, height: 32),
          let multiSelectBitmap = renderedBitmap(multiSelect, width: 460, height: 32) else { return false }
    let tolerance: CGFloat = 0.02
    var compared = 0
    for x in stride(from: 0, to: 460, by: 4) {
        for y in stride(from: 0, to: 32, by: 2) {
            guard let a = segmentedBitmap.colorAt(x: x, y: y), let b = multiSelectBitmap.colorAt(x: x, y: y) else {
                return false
            }
            if abs(a.redComponent - b.redComponent) > tolerance || abs(a.greenComponent - b.greenComponent) > tolerance ||
               abs(a.blueComponent - b.blueComponent) > tolerance || abs(a.alphaComponent - b.alphaComponent) > tolerance {
                return false
            }
            compared += 1
        }
    }
    return compared == 115 * 16
}

@MainActor
private func renderedBitmap<V: View>(_ view: V, width: Int, height: Int) -> NSBitmapImageRep? {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    guard let image = renderer.nsImage,
          image.size.width == CGFloat(width), image.size.height == CGFloat(height),
          let bitmap = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()),
          bitmap.pixelsWide == width, bitmap.pixelsHigh == height else { return nil }
    return bitmap
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

// MARK: - Drive 时间线改造：像素/几何分析辅助（2026-11-23）
//
// 时间线区段的填充色与 PracticeTimingEditor 的私有配色一一对应：
// 深蓝 Auto / 灰 Transition / 黄 Transition Shift·Endgame / 蓝·红 Alliance Shift。

/// ImageRenderer 对 ScrollView 不出内容；整页用真实离屏窗口布局后 cacheDisplay 捕获（1 px = 1 pt）。
@MainActor
private func windowRenderedBitmap<V: View>(_ view: V, width: Int, height: Int) -> NSBitmapImageRep? {
    let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height),
                          styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // 强制浅色：窗口默认跟系统外观，深色下面板白底/画布色会污染像素断言。
    window.appearance = NSAppearance(named: .aqua)
    let hosting = NSHostingView(rootView: view)
    window.contentView = hosting
    window.orderFront(nil)
    hosting.layoutSubtreeIfNeeded()
    window.layoutIfNeeded()
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else {
        window.orderOut(nil)
        window.close()
        return nil
    }
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    hosting.cacheDisplay(in: NSRect(x: 0, y: 0, width: width, height: height), to: rep)
    NSGraphicsContext.current = nil
    NSGraphicsContext.restoreGraphicsState()
    window.orderOut(nil)
    window.close()
    return rep
}

private func segmentFill(_ kind: PracticeTimeline.SegmentKind) -> UInt32 {
    switch kind {
    case .startDelay, .autoToTeleop: return 0xB9BEC4
    case .autonomous: return 0x131F25
    case .transitionShift, .endgame: return 0xF2D14B
    case .allianceShift1, .allianceShift3, .teleoperated: return 0x007BC0
    case .allianceShift2, .allianceShift4: return 0xC81623
    }
}

private let timelineSegmentHexes: [UInt32] = [0x131F25, 0xB9BEC4, 0xF2D14B, 0xC81623, 0x007BC0]

private func colorComponents(_ hex: UInt32) -> (Double, Double, Double) {
    (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
}

private func colorNear(_ bitmap: NSBitmapImageRep, x: Int, y: Int, hex: UInt32, tolerance: Double = 0.06) -> Bool {
    guard let c = bitmap.colorAt(x: x, y: y) else { return false }
    let expected = colorComponents(hex)
    return abs(Double(c.redComponent) - expected.0) <= tolerance
        && abs(Double(c.greenComponent) - expected.1) <= tolerance
        && abs(Double(c.blueComponent) - expected.2) <= tolerance
}

private func colorDistance(_ bitmap: NSBitmapImageRep, x: Int, y: Int, hex: UInt32) -> Double {
    guard let c = bitmap.colorAt(x: x, y: y) else { return 9 }
    let expected = colorComponents(hex)
    let dr = Double(c.redComponent) - expected.0
    let dg = Double(c.greenComponent) - expected.1
    let db = Double(c.blueComponent) - expected.2
    return (dr * dr + dg * dg + db * db).squareRoot()
}

/// 时间线轨道行：同一行里同时出现深蓝 / 红 / 蓝 / 黄四种区段填充色（滑杆行最多只有一种色调）。
private func timelineTrackBounds(_ bitmap: NSBitmapImageRep) -> (rows: ClosedRange<Int>, midRow: Int)? {
    var rows: [Int] = []
    for y in 0..<bitmap.pixelsHigh {
        var seen: Set<UInt32> = []
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
            for hex in timelineSegmentHexes where colorNear(bitmap, x: x, y: y, hex: hex) {
                seen.insert(hex)
            }
        }
        if seen.contains(0x131F25) && seen.contains(0xC81623) && seen.contains(0x007BC0) && seen.contains(0xF2D14B) {
            rows.append(y)
        }
    }
    guard let first = rows.first, let last = rows.last, last - first <= 100 else { return nil }
    return (first...last, first + (last - first) / 2)
}

private func rowsContaining(_ bitmap: NSBitmapImageRep, hex: UInt32) -> [Int] {
    (0..<bitmap.pixelsHigh).filter { y in
        stride(from: 0, to: bitmap.pixelsWide, by: 3).contains { colorNear(bitmap, x: $0, y: y, hex: hex) }
    }
}

/// 轨道顶部无文字行上的填充色连续游程：两端即该区段的实际渲染边界（圆角只影响首末段 ≤2px）。
private func fillRunEdges(_ bitmap: NSBitmapImageRep, y: Int, middleX: Int, hex: UInt32) -> (start: Int, end: Int)? {
    guard colorNear(bitmap, x: middleX, y: y, hex: hex) else { return nil }
    var start = middleX
    while start > 0 && colorNear(bitmap, x: start - 1, y: y, hex: hex) { start -= 1 }
    var end = middleX
    while end < bitmap.pixelsWide - 1 && colorNear(bitmap, x: end + 1, y: y, hex: hex) { end += 1 }
    return (start, end)
}

/// 区段内真实画出文字且秒数可见：标题区（上半）有文字像素；秒数必须在标题块下方
/// （相对轨道顶 ≥40 行）以真实字形呈现——≥3 个墨迹行、≥8 像素。
/// 实测基线：560 宽灰色 Transition 段单行秒数被裁剪后仅剩 1 行 3 像素残迹，此规则必须拦下。
private func segmentShowsText(_ bitmap: NSBitmapImageRep, track: (rows: ClosedRange<Int>, midRow: Int),
                              start: Int, end: Int, fill: UInt32) -> Bool {
    let top = track.rows.lowerBound
    var upper = 0
    var deepRows = 0
    var deepPixels = 0
    for y in max(top + 8, 0)...min(top + 56, bitmap.pixelsHigh - 1) {
        var rowInk = 0
        for x in max(start + 1, 0)...min(end - 1, bitmap.pixelsWide - 1) where colorDistance(bitmap, x: x, y: y, hex: fill) > 0.3 {
            rowInk += 1
            if y <= top + 31 { upper += 1 }
        }
        if y >= top + 40 && rowInk > 0 {
            deepRows += 1
            deepPixels += rowInk
        }
    }
    return upper >= 3 && deepRows >= 3 && deepPixels >= 8
}

/// 只要求段内存在真实文字墨迹（用于 3 秒 Transition Shift 的“仅秒数”呈现，不要求标题区域）。
private func segmentShowsAnyText(_ bitmap: NSBitmapImageRep, track: (rows: ClosedRange<Int>, midRow: Int),
                                 start: Int, end: Int, fill: UInt32) -> Bool {
    guard end - start >= 2 else { return false }
    for y in track.rows {
        for x in (start + 1)...(end - 1) where colorDistance(bitmap, x: x, y: y, hex: fill) > 0.3 {
            return true
        }
    }
    return false
}

private func segmentPixel(_ bitmap: NSBitmapImageRep, y: Int, last: Bool) -> Int? {
    if last {
        return stride(from: bitmap.pixelsWide - 1, through: 0, by: -1)
            .first { x in timelineSegmentHexes.contains { colorNear(bitmap, x: x, y: y, hex: $0) } }
    }
    return (0..<bitmap.pixelsWide)
        .first { x in timelineSegmentHexes.contains { colorNear(bitmap, x: x, y: y, hex: $0) } }
}

private func pixelsWhere(_ bitmap: NSBitmapImageRep, hex: UInt32,
                         xRange: Range<Int>, yRange: Range<Int>) -> [(x: Int, y: Int)] {
    var result: [(x: Int, y: Int)] = []
    for y in yRange {
        for x in xRange where colorNear(bitmap, x: x, y: y, hex: hex) {
            result.append((x, y))
        }
    }
    return result
}

private func boundingBox(_ pixels: [(x: Int, y: Int)]) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
    guard let first = pixels.first else { return nil }
    var box = (minX: first.0, maxX: first.0, minY: first.1, maxY: first.1)
    for pixel in pixels {
        box.minX = min(box.minX, pixel.0)
        box.maxX = max(box.maxX, pixel.0)
        box.minY = min(box.minY, pixel.1)
        box.maxY = max(box.maxY, pixel.1)
    }
    return box
}

/// 面板白底的最长横向白条（DSTheme.surface 浅色 = 0xFFFFFF）；可选只扫描指定横向区间。
private func whiteRun(_ bitmap: NSBitmapImageRep, y: Int, xRange: Range<Int>? = nil) -> (start: Int, end: Int) {
    let xs = xRange ?? 0..<bitmap.pixelsWide
    var best = (start: 0, end: -1)
    var runStart: Int? = nil
    for x in xs {
        if colorNear(bitmap, x: x, y: y, hex: 0xFFFFFF, tolerance: 0.02) {
            if runStart == nil { runStart = x }
        } else if let start = runStart {
            if x - 1 - start > best.end - best.start { best = (start, x - 1) }
            runStart = nil
        }
    }
    if let start = runStart, xs.upperBound - 1 - start > best.end - best.start {
        best = (start, xs.upperBound - 1)
    }
    return best
}

private func maxVerticalRun(_ bitmap: NSBitmapImageRep, hex: UInt32) -> Int {
    var best = 0
    for x in 0..<bitmap.pixelsWide {
        var run = 0
        for y in 0..<bitmap.pixelsHigh {
            if colorNear(bitmap, x: x, y: y, hex: hex) {
                run += 1
                best = max(best, run)
            } else {
                run = 0
            }
        }
    }
    return best
}

private func maxVerticalRunOutsideRows(_ bitmap: NSBitmapImageRep, hex: UInt32, rows: ClosedRange<Int>) -> Int {
    var best = 0
    for x in 0..<bitmap.pixelsWide {
        var run = 0
        for y in 0..<bitmap.pixelsHigh where !rows.contains(y) {
            if colorNear(bitmap, x: x, y: y, hex: hex) {
                run += 1
                best = max(best, run)
            } else {
                run = 0
            }
        }
    }
    return best
}
