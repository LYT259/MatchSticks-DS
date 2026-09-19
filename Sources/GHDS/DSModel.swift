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
    static let isAutoSim = ProcessInfo.processInfo.environment["GHDS_AUTO_SIM"] == "1"

    // MARK: 连接与配置

    var teamNumber: Int = 0 {
        didSet {
            settings.set("teamNumber", teamNumber)
            syncClientConfig()
        }
    }
    var manualIP: String = "" {
        didSet {
            settings.set("manualIP", manualIP.isEmpty ? nil : manualIP)
            syncClientConfig()
        }
    }
    var radioReachable = false
    var opModes: [MRCOpModeInfo] = []
    var selectedOpModeHash: UInt64 = 0
    var protocolKind: DSClient.ProtocolKind = .ni {
        didSet {
            settings.set("protocolKind", protocolKind.rawValue)
            syncClientConfig()
            if protocolKind == .mrc, started {
                nt4Server.start()
                nt4Server.publish(name: "/Dscomm/Control/ControlData", type: "proto:mrc.proto.ProtobufControlData")
            }
        }
    }
    private var started = false
    private var startInvoked = false   // start() 幂等：多窗口/状态恢复会让 .task 再跑一次
    private(set) var watchdogNotFed = false
    private var watchdogMissCount = 0
    var macStatus = MacStatusSnapshot(systemCPUPercent: 0, processMemoryMB: 0)
    var localNetworkSummary = "检测中…"
    private let networkMonitor = NetworkPathMonitor()
    private var wpilogWriter: WPILogWriter?
    var commState: DSClient.CommState = .idle
    var watchdogHealthy = true

    // MARK: 控制状态（操作员意图）

    var mode: NIMode = .teleoperated
    var alliance: AllianceStation = .red1 {
        didSet { settings.set("alliance", String(alliance.rawValue)) }
    }
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
    var dashboardKind: DashboardKind = .advantageScope {
        didSet { settings.set("dashboardKind", dashboardKind.rawValue) }
    }

    // MARK: Practice 时序

    enum PracticePhase: String, Sendable {
        case idle, delayBeforeAuto, autonomous, delayBeforeTeleop, teleoperated, finished
    }
    var practicePhase: PracticePhase = .idle
    var practiceRemaining: TimeInterval = 0
    var practiceAutoTime: TimeInterval = 15 {
        didSet { settings.set("practiceAutoTime", practiceAutoTime) }
    }
    var practiceTeleopTime: TimeInterval = 135 {
        didSet { settings.set("practiceTeleopTime", practiceTeleopTime) }
    }
    var practiceDelayTime: TimeInterval = 2 {
        didSet { settings.set("practiceDelayTime", practiceDelayTime) }
    }
    var soundsEnabled = true {
        didSet { settings.set("soundsEnabled", soundsEnabled) }
    }

    // MARK: 事件日志

    var dsEvents: [String] = []

    // MARK: 抓包录制（Setup 页开关；报告 §6 决策 3）

    var recording = false {
        didSet { updateRecorder() }
    }
    private let recorderBox = RecorderBox()

    // MARK: .dslog 会话日志（NI DS 习惯：全程记录，AdvantageScope/dslog viewer 可读）

    var dslogEnabled = true {
        didSet {
            settings.set("dslogEnabled", dslogEnabled)
            updateDSLogWriter()
        }
    }
    private var dslogWriter: DSLogWriter?

    // MARK: 图表历史（1Hz 采样，Charts 页真实时间序列）

    var cpuHistory: [CPUPoint] = []
    var lossHistory: [LossPoint] = []

    // MARK: 内部

    private let client = DSClient()
    private let snapshotBox = SnapshotBox()
    private let heartbeatBox = HeartbeatBox()
    private let settings = SettingsStore()
    private var lastBatterySampleAt: TimeInterval = 0
    private var radioProbe: RadioProbe?
    private let nt4Server = NT4Server(port: 6767)
    private let opModeHashBox = OpModeHashBox()
    private var sequencer = PracticeSequencer()
    private var practiceTimer: Timer?
    private var pollTimer: Timer?
    private var tickers: [Timer] = []

    // MARK: 生命周期

    var persistenceEnabled: Bool { !DSModel.isAutoSim }

    func loadPersistedSettings() {
        guard persistenceEnabled else { return }
        if let t = settings.integer("teamNumber"), t > 0 { teamNumber = t }
        if let ip = settings.string("manualIP") { manualIP = ip }
        if let raw = settings.string("alliance"), let a = AllianceStation(rawValue: UInt8(raw) ?? 255) { alliance = a }
        if let kind = settings.string("dashboardKind").flatMap(DashboardKind.init(rawValue:)) { dashboardKind = kind }
        if let v = settings.double("practiceAutoTime"), v >= 1 { practiceAutoTime = v }
        if let v = settings.double("practiceTeleopTime"), v >= 15 { practiceTeleopTime = v }
        if let v = settings.double("practiceDelayTime"), v >= 0 { practiceDelayTime = v }
        if let b = settings.bool("soundsEnabled") { soundsEnabled = b }
        if let b = settings.bool("dslogEnabled") { dslogEnabled = b }
        if let raw = settings.string("protocolKind"), let kind = DSClient.ProtocolKind(rawValue: raw) {
            protocolKind = kind
        }
    }

    func start() {
        // 幂等：installTimers 往 main runloop 加 4 个定时器且从不清理，
        // 重复执行（多窗口 / 状态恢复再跑一次 .task）会叠加定时器与心跳源
        guard !startInvoked else { return }
        startInvoked = true
        loadPersistedSettings()
        installTimers()
        networkMonitor.start()
        HIDInputManager.shared.onDevicesChanged = { [weak self] in
            Task { @MainActor in self?.rescanJoysticks() }
        }
        HIDInputManager.shared.start()
        rescanJoysticks()

        client.snapshotProvider = { [snapshotBox] in snapshotBox.get() }
        syncClientConfig()
        client.heartbeatAge = { [heartbeatBox] in heartbeatBox.ageSeconds() }
        client.recordSink = { [recorderBox] dir, data in recorderBox.record(dir, data) }
        client.eventHandler = { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.handle(event) }
        }
        let probe = RadioProbe(configuration: {
            var c = RadioProbe.Configuration()
            if DSModel.isAutoSim { c.port = 8080 } // 模拟器 radio 走非特权端口
            return c
        }())
        probe.hostProvider = { [weak self] in
            guard let self else { return nil }
            if !self.manualIP.isEmpty { return (self.manualIP, probe.configuration.port) }
            guard self.teamNumber > 0 else { return nil }
            let t = self.teamNumber
            return (String(format: "10.%d.%d.1", t / 100, t % 100), probe.configuration.port)
        }
        probe.onResult = { [weak self] ok in
            Task { @MainActor in self?.radioReachable = ok }
        }
        probe.start()
        radioProbe = probe

        started = true
        // MRC：NT4 server（6767）随协议启动；ControlData 经 20ms tick 下发
        if protocolKind == .mrc {
            nt4Server.start()
            nt4Server.publish(name: "/Dscomm/Control/ControlData", type: "proto:mrc.proto.ProtobufControlData")
            var nt4ValueCount = 0
            nt4Server.onValue = { [weak self] name, value in
                Task { @MainActor in
                    guard let self else { return }
                    nt4ValueCount += 1
                    if nt4ValueCount == 1 {
                        self.log("NT4 首个机器人写入：\(name)")
                    }
                }
            }
            client.tickHook = { [snapshotBox, opModeHashBox, nt4Server] in
                let snap = snapshotBox.get()
                var cw: UInt32 = 0
                if snap.control.enabled { cw |= 1 }
                if snap.control.mode == .autonomous { cw |= 2 }
                if snap.control.mode == .test { cw |= 4 }
                if snap.control.fmsAttached { cw |= 8 }
                if snap.control.estop { cw |= 128 }
                let joysticks = snap.joysticks.map {
                    ProtobufLite.JoystickWire(buttons: $0.buttons, buttonCount: $0.buttonCount,
                                              axes: $0.axes,
                                              povsPacked: Self.packPOVs($0.povs))
                }
                let data = ProtobufLite.mrcControlData(
                    controlWord: cw,
                    matchTimeSec: Int32(snap.matchTime ?? 0),
                    joysticks: joysticks,
                    currentOpMode: snap.control.enabled ? opModeHashBox.get() : 0,
                    gameData: snap.gameData ?? ""
                )
                nt4Server.set(name: "/Dscomm/Control/ControlData", .raw(data))
            }
        }

        client.start()
        log("GH DS 控制环已启动（20ms）")

        if DSModel.isAutoSim {
            manualIP = "127.0.0.1"
            log("GHDS_AUTO_SIM=1：自动连接本机模拟器 127.0.0.1")
        }
        if ProcessInfo.processInfo.environment["GHDS_AUTO_MRC"] == "1" {
            protocolKind = .mrc
            log("GHDS_AUTO_MRC=1：切换 MRC V2 协议（SystemCore）")
        }
    }

    private func syncClientConfig() {
        client.updateConfig { cfg in
            cfg.teamNumber = self.teamNumber
            cfg.manualIP = self.manualIP.isEmpty ? nil : self.manualIP
            cfg.protocolKind = self.protocolKind
        }
    }

    // MARK: 主线程 50Hz：轮询 HID → 刷新槽位 → 填快照盒子

    private func installTimers() {
        updateDSLogWriter()
        let dslog = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.appendDSLogEntry() }
        }
        RunLoop.main.add(dslog, forMode: .common)
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

    var canEnable: Bool {
        SafetyGate.canEnableNow(SafetyGate.State(
            commConnected: commConnected,
            watchdogHealthy: watchdogHealthy,
            estopEngaged: estopEngaged,
            currentlyEnabled: enabled
        ))
    }

    // MARK: 操作员指令（安全门全部集中在这里）

    func setEnabled(_ on: Bool) {
        // 幂等：与当前状态相同则不动作——否则重复点 Enable 会把 enabledSince
        // 计时器复位并重复写日志（迷你视图 ENABLE 曾因此可被误点）
        if on == enabled { return }
        if on {
            let state = SafetyGate.State(
                commConnected: commConnected,
                watchdogHealthy: watchdogHealthy,
                estopEngaged: estopEngaged,
                currentlyEnabled: enabled
            )
            let decision = SafetyGate.evaluateEnable(state)
            guard case .allow = decision else {
                if case .deny(let reason) = decision { log("拒绝使能：\(reason)") }
                return
            }
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

    static func packPOVs(_ povs: [Int16]) -> UInt32 {
        // u32 打包前两个 POV（低 16 位 = POV0），未按 = 0xFFFF
        let p0 = povs.first.map { UInt32(UInt16(bitPattern: $0)) } ?? 0xFFFF
        let p1 = povs.dropFirst().first.map { UInt32(UInt16(bitPattern: $0)) } ?? 0xFFFF
        return p0 | (p1 << 16)
    }

    func selectOpMode(_ op: MRCOpModeInfo) {
        selectedOpModeHash = op.hash
        opModeHashBox.set(op.hash)
        log("OpMode 选择：\(op.name)（hash 0x\(String(op.hash, radix: 16))）")
    }

    // MARK: Practice 时序

    func startPractice() {
        guard !sequencer.phase.isActive else { return }
        sequencer = PracticeSequencer(config: .init(
            autoTime: practiceAutoTime, teleopTime: practiceTeleopTime, delayTime: practiceDelayTime
        ))
        applyPracticeEvents(sequencer.start())
        practiceTimer?.invalidate()
        practiceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.practiceTick() }
        }
    }

    func aStop() {
        applyPracticeEvents(sequencer.abort())
        practiceTimer?.invalidate()
        practiceTimer = nil
    }

    private func practiceTick() {
        applyPracticeEvents(sequencer.tick(0.1))
        if !sequencer.phase.isActive {
            practiceTimer?.invalidate()
            practiceTimer = nil
        }
    }

    private func applyPracticeEvents(_ events: [PracticeSequencer.Event]) {
        for event in events {
            switch event {
            case .entered(let phase):
                practicePhase = mapPhase(phase)
                practiceRemaining = sequencer.remaining
                switch phase {
                case .autonomous: setMode(.autonomous)
                case .teleoperated: setMode(.teleoperated)
                default: break
                }
                if phase.isActive { beep(); log("Practice → \(phase.displayName)") }
            case .enable: setEnabled(true)
            case .disable: setEnabled(false)
            case .finished:
                practicePhase = .finished
                log("Practice 结束")
                beep()
            case .aborted:
                practicePhase = .finished
                log("A-STOP：Practice 中止")
            }
        }
    }

    private func mapPhase(_ phase: PracticeSequencer.Phase) -> PracticePhase {
        switch phase {
        case .idle: return .idle
        case .delayBeforeAuto: return .delayBeforeAuto
        case .autonomous: return .autonomous
        case .delayBeforeTeleop: return .delayBeforeTeleop
        case .teleoperated: return .teleoperated
        case .finished: return .finished
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
            // MRC：WatchdogFed 连续缺失 ≥5 → 「Watchdog Not Fed」告警（First DS 语义）
            if p.watchdogFed {
                watchdogMissCount = 0
                if watchdogNotFed { watchdogNotFed = false; log("Watchdog 恢复喂狗") }
            } else {
                watchdogMissCount += 1
                if watchdogMissCount == 5 {
                    watchdogNotFed = true
                    log("⚠️ Watchdog Not Fed（连续 5 应答未喂狗）")
                }
            }
        case .tcpEvent(let e):
            handleTCP(e)
        case .opModes(let list):
            if list != opModes {
                opModes = list
                log("收到 OpMode 列表（\(list.count) 项）")
            }
        case .stats(let loss, _, let tx, let rx):
            lossPercent = loss
            txCount = tx
            rxCount = rx
            lossHistory.append(LossPoint(t: Date(), loss: loss))
            if lossHistory.count > 300 { lossHistory.removeFirst(lossHistory.count - 300) }
            if !cpuCores.isEmpty {
                let loads = cpuCores.map { $0.reduce(0, +) }
                cpuHistory.append(CPUPoint(t: Date(), loads: loads))
                if cpuHistory.count > 300 { cpuHistory.removeFirst(cpuHistory.count - 300) }
            }
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

    // MARK: .dslog 采样（1Hz）

    private func updateDSLogWriter() {
        if dslogEnabled {
            guard dslogWriter == nil else { return }
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GHDriverStation/Logs", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy_MM_dd HH_mm_ss"
            let base = formatter.string(from: Date())
            do {
                dslogWriter = try DSLogWriter(fileURL: dir.appendingPathComponent(base + ".dslog"))
                wpilogWriter = try WPILogWriter(fileURL: dir.appendingPathComponent(base + ".wpilog"))
                startWPILogEntries()
                log("会话日志记录开始（.dslog + .wpilog）")
            } catch {
                log("日志启动失败：\(error.localizedDescription)")
                dslogEnabled = false
            }
        } else {
            dslogWriter?.close(); dslogWriter = nil
            finishWPILogEntries()
            wpilogWriter?.close(); wpilogWriter = nil
        }
    }

    private func appendDSLogEntry() {
        macStatus = MacStatusMonitor.snapshot()
        localNetworkSummary = networkMonitor.summary
        appendWPILogSamples()
        guard let w = dslogWriter, commConnected else { return }
        var entry = DSLogEntry()
        entry.packetLossPercent = lossPercent
        entry.batteryVolts = batteryVolts
        entry.cpuPercent = cpuCores.map { $0.reduce(0, +) }.max()
        entry.brownout = robotStatus.brownout
        entry.watchdog = !watchdogHealthy
        entry.dsTeleop = mode == .teleoperated
        entry.dsDisabled = !enabled
        entry.robotTeleop = robotTrace.teleopMode
        entry.robotAuton = robotTrace.autonomousMode
        entry.robotDisabled = robotTrace.disabled
        entry.canPercent = can.utilizationPercent
        w.append(entry)
    }

    // MARK: WPILog 条目

    private var wpilogIDs: (battery: UInt32, loss: UInt32, cpu: UInt32, can: UInt32, enabled: UInt32, mode: UInt32, radio: UInt32)?

    private func startWPILogEntries() {
        guard let w = wpilogWriter else { return }
        wpilogIDs = (
            w.startEntry(name: "/DS/Battery", type: "double"),
            w.startEntry(name: "/DS/Loss", type: "double"),
            w.startEntry(name: "/DS/RoboRIO CPU", type: "double"),
            w.startEntry(name: "/DS/CAN Util", type: "double"),
            w.startEntry(name: "/DS/Enabled", type: "boolean"),
            w.startEntry(name: "/DS/Mode", type: "string"),
            w.startEntry(name: "/DS/Radio Reachable", type: "boolean")
        )
    }

    private func appendWPILogSamples() {
        guard let w = wpilogWriter, let ids = wpilogIDs else { return }
        w.appendDouble(ids.battery, Double(batteryVolts))
        w.appendDouble(ids.loss, lossPercent)
        w.appendDouble(ids.cpu, Double(cpuCores.map { $0.reduce(0, +) }.max() ?? 0))
        w.appendDouble(ids.can, Double(can.utilizationPercent))
        w.appendBoolean(ids.enabled, enabled)
        w.appendString(ids.mode, mode.displayName)
        w.appendBoolean(ids.radio, radioReachable)
    }

    private func finishWPILogEntries() {
        guard let ids = wpilogIDs, let w = wpilogWriter else { return }
        w.finishEntry(ids.battery); w.finishEntry(ids.loss); w.finishEntry(ids.cpu)
        w.finishEntry(ids.can); w.finishEntry(ids.enabled); w.finishEntry(ids.mode)
        w.finishEntry(ids.radio)
    }

    // MARK: 日志

    private func appendBattery(_ v: Float) {
        // 5Hz 节流：应答 50Hz 全量入列会造成 12s 窗口与 50Hz UI 失效
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastBatterySampleAt >= 0.2 else { return }
        lastBatterySampleAt = now
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

// MARK: OpMode hash 盒（主线程写、控制环读）

final class OpModeHashBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func set(_ v: UInt64) { lock.lock(); value = v; lock.unlock() }
    func get() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - 录制开关（线程安全）

extension DSModel {
    fileprivate func updateRecorder() {
        if recording {
            recorderBox.start { url in
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                return url.appendingPathComponent("capture-\(formatter.string(from: Date())).dsrec")
            }
            if let name = recorderBox.currentFileName { log("抓包录制开始：\(name)") }
        } else {
            recorderBox.stop()
        }
    }
}

final class RecorderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: PacketRecorder?
    private(set) var currentFileName: String?

    func record(_ dir: RecordedDirection, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        recorder?.record(dir, data)
    }

    func start(naming: @escaping (URL) -> URL) {
        lock.lock(); defer { lock.unlock() }
        guard recorder == nil else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GHDriverStation/captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = naming(dir)
        do {
            recorder = try PacketRecorder(fileURL: url)
            currentFileName = url.lastPathComponent
        } catch {
            currentFileName = nil
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        recorder?.close()
        recorder = nil
        currentFileName = nil
    }
}

struct CPUPoint: Sendable {
    var t: Date
    var loads: [Float]
}

struct LossPoint: Sendable {
    var t: Date
    var loss: Double
}

// MARK: - Dashboard

enum DashboardKind: String, CaseIterable, Identifiable {
    case advantageScope = "AdvantageScope"
    case shuffleboard = "Shuffleboard"
    case elastic = "Elastic"
    var id: String { rawValue }
}
