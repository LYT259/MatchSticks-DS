import SwiftUI
import DSCore

// MARK: - 线程安全盒子：主线程写、控制环队列读（避免跨 actor 访问）

final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = DSClient.Snapshot()

    func set(_ s: DSClient.Snapshot) {
        lock.lock(); snapshot = s; lock.unlock()
    }

    func get() -> DSClient.Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }
}

final class HeartbeatBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lastBeat = Date()

    func beat() {
        lock.lock(); lastBeat = Date(); lock.unlock()
    }

    func ageSeconds() -> Double {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastBeat)
    }
}

// MARK: - DSModel：应用层唯一状态源（@MainActor + @Observable）

@MainActor
@Observable
final class DSModel {
    // MARK: 连接与配置

    var teamNumber: Int = 0 {
        didSet { syncClientConfig() }
    }
    var manualIP: String = "" {
        didSet { syncClientConfig() }
    }
    var commState: DSClient.CommState = .idle
    var watchdogHealthy = true

    // MARK: 控制状态（操作员意图）

    var mode: NIMode = .teleoperated
    var alliance: AllianceStation = .red1
    private(set) var enabled = false
    private(set) var estopEngaged = false
    var enabledSince: Date?
    var enabledElapsed: TimeInterval = 0

    // MARK: 机器人回传

    var robotStatus = RobotStatus()
    var robotTrace = RobotTrace()
    var batteryVolts: Float = 0
    var batteryHistory: [Float] = []
    var cpuCores: [[Float]] = []
    var ramUsed: UInt32 = 0
    var ramTotal: UInt32 = 0
    var diskFree: UInt32 = 0
    var can = CANMetrics()
    var joystickOutputs: [JoystickOutput] = []
    var lossPercent: Double = 0
    var txCount: UInt64 = 0
    var rxCount: UInt64 = 0

    // MARK: TCP 通道数据

    var versionEntries: [NICodec.VersionEntry] = []
    var errorMessages: [NICodec.ErrorMessage] = []
    var stdoutLines: [String] = []
    var disableFaults: (comms: UInt16, twelveV: UInt16) = (0, 0)
    var railFaults: (sixV: UInt16, fiveV: UInt16, threeV: UInt16) = (0, 0, 0)

    // MARK: 手柄

    var joystickSlots: [JoystickSlot] = []
    var lastHIDScanAt: Date?

    // MARK: 慢速设置

    var gameData: String = ""
    var competition: String = ""
    var matchType: UInt8 = 0
    var dashboardKind: DashboardKind = .advantageScope

    // MARK: Practice 时序

    enum PracticePhase: String, Sendable {
        case idle, delayBeforeAuto, autonomous, delayBeforeTeleop, teleoperated, finished
    }
    var practicePhase: PracticePhase = .idle
    var practiceRemaining: TimeInterval = 0
    var practiceAutoTime: TimeInterval = 15
    var practiceTeleopTime: TimeInterval = 135
    var practiceDelayTime: TimeInterval = 2
    var soundsEnabled = true

    // MARK: 事件日志

    var dsEvents: [String] = []

    // MARK: 内部

    private let client = DSClient()
    private let snapshotBox = SnapshotBox()
    private let heartbeatBox = HeartbeatBox()
    private var practiceTimer: Timer?
    private var pollTimer: Timer?
    private var tickers: [Timer] = []

    // MARK: 生命周期

    func start() {
        installTimers()
        HIDInputManager.shared.onDevicesChanged = { [weak self] in
            Task { @MainActor in self?.rescanJoysticks() }
        }
        HIDInputManager.shared.start()
        rescanJoysticks()

        client.snapshotProvider = { [snapshotBox] in snapshotBox.get() }
        client.heartbeatAge = { [heartbeatBox] in heartbeatBox.ageSeconds() }
        client.eventHandler = { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.handle(event) }
        }
        client.start()
        log("GH DS 控制环已启动（20ms）")

        if ProcessInfo.processInfo.environment["GHDS_AUTO_SIM"] == "1" {
            manualIP = "127.0.0.1"
            log("GHDS_AUTO_SIM=1：自动连接本机模拟器 127.0.0.1")
        }
    }

    private func syncClientConfig() {
        client.updateConfig { cfg in
            cfg.teamNumber = self.teamNumber
            cfg.manualIP = self.manualIP.isEmpty ? nil : self.manualIP
        }
    }

    // MARK: 主线程 50Hz：轮询 HID → 刷新槽位 → 填快照盒子

    private func installTimers() {
        let poll = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollAndPublishSnapshot() }
        }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll

        let beat = Timer(timeInterval: 0.01, repeats: true) { [heartbeatBox] _ in
            heartbeatBox.beat()
        }
        RunLoop.main.add(beat, forMode: .common)

        let elapsed = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let since = self.enabledSince else { return }
                self.enabledElapsed = Date().timeIntervalSince(since)
            }
        }
        RunLoop.main.add(elapsed, forMode: .common)
        tickers.append(elapsed)
    }

    private var lastRescan = Date.distantPast

    private func pollAndPublishSnapshot() {
        // 刷新手柄实时值（UI 的 USB 页同源；列表重建 0.5s 防抖）
        let devices = HIDInputManager.shared.pollAll()
        for (i, slot) in joystickSlots.enumerated() {
            guard let device = devices.first(where: { $0.uniqueID == slot.uniqueID }) else { continue }
            joystickSlots[i].apply(device)
        }
        if Date().timeIntervalSince(lastRescan) > 0.5 {
            lastRescan = Date()
            rebuildSlots(from: devices)
        }

        var snap = DSClient.Snapshot()
        snap.control.mode = mode
        snap.control.enabled = enabled && watchdogHealthy && commConnected
        snap.control.estop = estopEngaged
        snap.alliance = alliance
        snap.joysticks = joystickSlots.prefix(6).map(\.data)
        snap.joystickDescriptors = joystickSlots.prefix(6).map(\.descriptor)
        snap.matchTime = practiceTimeTag
        if !gameData.isEmpty { snap.gameData = gameData }
        if !competition.isEmpty || matchType != 0 {
            snap.matchInfo = .init(competition: competition, type: matchType)
        }
        snapshotBox.set(snap)
    }

    private var practiceTimeTag: Float? {
        guard practicePhase != .idle, practicePhase != .finished else { return nil }
        return Float(max(0, practiceRemaining))
    }

    var commConnected: Bool {
        if case .connected = commState { return true }
        return false
    }

    // MARK: 操作员指令（安全门全部集中在这里）

    func setEnabled(_ on: Bool) {
        if on {
            guard !estopEngaged else { log("拒绝使能：E-Stop 已触发，先复位（Esc+I 或重启代码）"); return }
            guard commConnected else { log("拒绝使能：无机器人连接"); return }
            guard watchdogHealthy else { log("拒绝使能：控制环心跳异常"); return }
        }
        enabled = on
        enabledSince = on ? Date() : nil
        if !on { enabledElapsed = 0 }
        log(on ? "ENABLED（\(mode.displayName)）" : "Disabled")
    }

    func triggerEstop() {
        guard !estopEngaged else { return }
        estopEngaged = true
        enabled = false
        enabledSince = nil
        log("E-STOP 触发（Space）")
    }

    /// FDS 语义复位：重启 robot code 解除 E-Stop 锁存
    func resetEstop() {
        guard estopEngaged else { return }
        estopEngaged = false
        client.sendRequestPulse(RequestWord(rebootRoboRIO: false, restartCode: true))
        log("E-Stop 复位请求已发送（重启 robot code）")
    }

    func rebootRoboRIO() {
        guard commConnected else { log("Reboot 拒绝：无连接"); return }
        client.sendRequestPulse(RequestWord(rebootRoboRIO: true, restartCode: false))
        log("已请求 roboRIO 重启")
    }

    func restartRobotCode() {
        guard commConnected else { log("Restart Code 拒绝：无连接"); return }
        client.sendRequestPulse(RequestWord(rebootRoboRIO: false, restartCode: true))
        log("已请求重启 robot code")
    }

    // MARK: 模式

    func setMode(_ m: NIMode) {
        mode = m
    }

    // MARK: Practice 时序

    func startPractice() {
        guard practicePhase == .idle || practicePhase == .finished else { return }
        practicePhase = .delayBeforeAuto
        practiceRemaining = practiceDelayTime
        setMode(.autonomous)
        practiceTimer?.invalidate()
        practiceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.practiceTick() }
        }
        beep()
        log("Practice 开始：\(Int(practiceDelayTime))s 后进入 Autonomous")
    }

    func aStop() {
        practiceTimer?.invalidate()
        practiceTimer = nil
        practicePhase = .finished
        setEnabled(false)
        log("A-STOP：Practice 中止")
        beep()
    }

    private func practiceTick() {
        practiceRemaining -= 0.1
        if practiceRemaining > 0 { return }

        switch practicePhase {
        case .delayBeforeAuto:
            practicePhase = .autonomous
            practiceRemaining = practiceAutoTime
            setEnabled(true)
            beep()
        case .autonomous:
            practicePhase = .delayBeforeTeleop
            practiceRemaining = practiceDelayTime
            setEnabled(false)
            setMode(.teleoperated)
            beep()
        case .delayBeforeTeleop:
            practicePhase = .teleoperated
            practiceRemaining = practiceTeleopTime
            setEnabled(true)
            beep()
        case .teleoperated:
            practiceTimer?.invalidate()
            practiceTimer = nil
            practicePhase = .finished
            setEnabled(false)
            log("Practice 结束")
            beep()
        default: break
        }
    }

    private func beep() {
        guard soundsEnabled else { return }
        NSSound.beep()
    }

    // MARK: 事件处理（client 事件 → 主线程状态）

    private func handle(_ event: DSClient.Event) {
        switch event {
        case .commState(let s):
            commState = s
        case .response(let p):
            robotStatus = p.status
            robotTrace = p.trace
            batteryVolts = p.batteryVoltage
            appendBattery(p.batteryVoltage)
            cpuCores = p.cpu.cores
            ramUsed = p.ramUsedBytes
            ramTotal = p.ramTotalBytes
            diskFree = p.diskFreeBytes
            can = p.can
            if !p.joystickOutputs.isEmpty { joystickOutputs = p.joystickOutputs }
        case .tcpEvent(let e):
            handleTCP(e)
        case .stats(let loss, _, let tx, let rx):
            lossPercent = loss
            txCount = tx
            rxCount = rx
        case .watchdogTripped:
            watchdogHealthy = false
            enabled = false
            enabledSince = nil
            log("看门狗触发：UI 冻结 >200ms，已冻结使能输出")
        case .watchdogRecovered:
            watchdogHealthy = true
            log("看门狗恢复：控制环心跳正常")
        case .autoDisabled(let reason):
            enabled = false
            enabledSince = nil
            log("自动失能：\(reason)")
        case .log(let line):
            log(line)
        }
    }

    private func handleTCP(_ e: NICodec.TCPEvent) {
        switch e {
        case .versions(let v):
            if v != versionEntries {
                versionEntries = v
                log("收到版本信息（\(v.count) 项）")
            }
        case .error(let m):
            errorMessages.insert(m, at: 0)
            if errorMessages.count > 500 { errorMessages.removeLast() }
        case .stdout(let m):
            stdoutLines.append(m.message)
            if stdoutLines.count > 2000 { stdoutLines.removeFirst(1000) }
        case .disableFaults(let comms, let twelve):
            disableFaults = (comms, twelve)
        case .railFaults(let six, let five, let three):
            railFaults = (six, five, three)
        case .unknown:
            break
        }
    }

    // MARK: 手柄槽位（锁定 = 设备钉住槽位索引）

    func rescanJoysticks() {
        rebuildSlots(from: HIDInputManager.shared.pollAll())
    }

    private func rebuildSlots(from snapshots: [HIDDeviceSnapshot]) {
        var slots = [JoystickSlot?](repeating: nil, count: max(snapshots.count, joystickSlots.count))

        var used = Set<String>()
        for slot in joystickSlots {
            guard let lockID = slot.lockedDeviceID,
                  let device = snapshots.first(where: { $0.uniqueID == lockID }) else { continue }
            let index = min(slot.index, slots.count - 1)
            slots[index] = JoystickSlot(index: index, device: device, lockedDeviceID: lockID)
            used.insert(lockID)
        }

        var fill = snapshots.filter { !used.contains($0.uniqueID) }.makeIterator()
        for i in slots.indices where slots[i] == nil {
            if let device = fill.next() {
                var s = joystickSlots.first { $0.uniqueID == device.uniqueID }
                    ?? JoystickSlot(index: i, device: device)
                s.index = i
                s.apply(device)
                s.lockedDeviceID = nil
                slots[i] = s
            }
        }
        joystickSlots = slots.compactMap { $0 }
        lastHIDScanAt = Date()
    }

    func moveSlot(_ index: Int, up: Bool) {
        let target = up ? index - 1 : index + 1
        guard joystickSlots.indices.contains(index), joystickSlots.indices.contains(target) else { return }
        joystickSlots.swapAt(index, target)
        for (i, _) in joystickSlots.enumerated() { joystickSlots[i].index = i }
    }

    func toggleLock(_ index: Int) {
        guard joystickSlots.indices.contains(index) else { return }
        joystickSlots[index].lockedDeviceID = joystickSlots[index].lockedDeviceID == nil
            ? joystickSlots[index].uniqueID
            : nil
    }

    // MARK: 日志

    private func appendBattery(_ v: Float) {
        batteryHistory.append(v)
        if batteryHistory.count > 600 { batteryHistory.removeFirst(batteryHistory.count - 600) }
    }

    func log(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        dsEvents.append("[\(formatter.string(from: Date()))] \(line)")
        if dsEvents.count > 1000 { dsEvents.removeFirst(500) }
    }
}

// MARK: - 手柄槽位模型

struct JoystickSlot: Identifiable {
    var id: String { uniqueID }
    var index: Int
    var uniqueID: String
    var name: String
    var vendorID: Int
    var productID: Int
    var axes: [Float]
    var buttons: UInt64
    var buttonCount: Int
    var povs: [Int16]
    var lockedDeviceID: String?
    var isXbox: Bool

    var data: JoystickData {
        JoystickData(axes: axes, buttonCount: buttonCount, buttons: buttons, povs: povs)
    }

    var descriptor: NICodec.JoystickDescriptor {
        var d = NICodec.JoystickDescriptor()
        d.index = index
        d.isXbox = isXbox
        d.type = isXbox ? 1 : 20 // XInput Gamepad / HID Joystick
        d.name = String(name.prefix(60))
        d.buttonCount = buttonCount
        d.povCount = povs.count
        return d
    }

    init(index: Int, device: HIDDeviceSnapshot, lockedDeviceID: String? = nil) {
        self.index = index
        self.uniqueID = device.uniqueID
        self.name = device.name
        self.vendorID = device.vendorID
        self.productID = device.productID
        self.axes = device.axes
        self.buttons = device.buttons
        self.buttonCount = device.buttonCount
        self.povs = device.povs
        self.lockedDeviceID = lockedDeviceID
        self.isXbox = device.isXbox
    }

    mutating func apply(_ device: HIDDeviceSnapshot) {
        axes = device.axes
        buttons = device.buttons
        povs = device.povs
        name = device.name
    }
}

// MARK: - Dashboard

enum DashboardKind: String, CaseIterable, Identifiable {
    case advantageScope = "AdvantageScope"
    case shuffleboard = "Shuffleboard"
    case elastic = "Elastic"
    var id: String { rawValue }
}
