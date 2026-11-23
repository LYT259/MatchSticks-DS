import SwiftUI
import DSCore
import Darwin

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
        var stallMS: Int?
        lock.lock()
        // 主线程停滞探针（Diag 输出开启时生效）：心跳本应 10ms 一跳，
        // 间隔超过 100ms 说明主 runloop 被阻塞过——记录实际停滞毫秒数。
        let gap = Date().timeIntervalSince(lastBeat)
        if gap > 0.1 { stallMS = Int(gap * 1000) }
        lastBeat = Date()
        lock.unlock()
        // 探针写盘在锁外执行：持锁做文件 I/O 会拖住 ageSeconds()——控制环 20ms
        // 队列每个控制包都在读它，锁内写盘等于把 UI 停滞转嫁给控制环。
        if let stallMS, Diag.enabled {
            Diag.write("UI stall \(stallMS)ms")
        }
    }

    func ageSeconds() -> Double {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastBeat)
    }
}

// MARK: 诊断输出（log() 在 MainActor、心跳探针在主 runloop、测试线程均可能调用；写器自身线程安全）
enum Diag {
    /// 事件日志镜像到 stderr（性能测量 / E2E 验证用；默认关闭，行为零差异）
    static let toStderr = DSEnvironment.isEnabled("LOG_STDERR")
    /// 写入指定文件（open 启动的 GUI 无 stderr 可读时用；常驻 O_APPEND 句柄，懒打开）
    static let filePath = DSEnvironment.string("LOG_FILE")
    static var enabled: Bool { toStderr || ensureFileOutput() }

    private static let writerLock = NSLock()
    private static var fileFD: Int32 = -1
    private static var bootstrapped = false

    /// 切换输出文件为常驻 O_APPEND 句柄（每行一次原子 write(2)，不再逐行 open/seek/close）。
    /// 返回 false = 打开失败（输出保持原目标不变）。
    @discardableResult
    static func setFileOutput(path: String) -> Bool {
        writerLock.lock(); defer { writerLock.unlock() }
        return openFileOutputLocked(path)
    }

    /// 环境变量目标只在首次查询时打开一次（失败不逐行重试）
    private static func ensureFileOutput() -> Bool {
        writerLock.lock(); defer { writerLock.unlock() }
        if !bootstrapped {
            bootstrapped = true
            if let path = filePath { _ = openFileOutputLocked(path) }
        }
        return fileFD >= 0
    }

    private static func openFileOutputLocked(_ path: String) -> Bool {
        if fileFD >= 0 {
            close(fileFD)
            fileFD = -1
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return false }
        fileFD = fd
        return true
    }

    static func write(_ line: String) {
        if toStderr {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        guard ensureFileOutput() else { return }
        writerLock.lock()
        defer { writerLock.unlock() }
        let fd = fileFD
        guard fd >= 0 else { return }
        let data = Data((line + "\n").utf8)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n }
                else if errno == EINTR { continue }
                else { break }
            }
        }
    }
}

// MARK: radio 探测目标盒（主线程写队号，probe 队列读——hostProvider 不再跨线程读 MainActor 状态）

final class RadioTeamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var team = 0
    func set(_ t: Int) { lock.lock(); team = t; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return team }
}

// MARK: - DSModel：应用层唯一状态源（@MainActor + @Observable）

@MainActor
@Observable
final class DSModel {
    static let isAutoSim = DSEnvironment.isEnabled("AUTO_SIM")
    /// log() 时间戳 formatter：创建一次复用（每次新建 DateFormatter 约 1ms，
    /// 消息高峰期会放大主线程负担）
    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// 设置域解析：非空有效的 `MATCHSTICKS_DS_SETTINGS_SUITE`（旧 `GHDS_SETTINGS_SUITE` 兼容）
    /// → 独立 UserDefaults suite（测试 / 并行会话隔离），否则标准域。
    /// 无效名字（UserDefaults 拒绝创建）同样回退标准域。
    nonisolated static func resolvedSettingsDefaults(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UserDefaults {
        let name = (DSEnvironment.string("SETTINGS_SUITE", environment: environment) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let defaults = UserDefaults(suiteName: name) else {
            return .standard
        }
        return defaults
    }

    /// `DSModel()` 保持原行为（环境变量解析设置域，AUTO_SIM 禁用持久化）。
    /// 测试可注入临时 suite 与持久化开关；manualIP 等写入必须真实经过 didSet。
    init(settingsDefaults: UserDefaults? = nil, persistenceEnabled: Bool? = nil) {
        settings = SettingsStore(defaults: settingsDefaults ?? Self.resolvedSettingsDefaults())
        persistenceAllowed = persistenceEnabled ?? !Self.isAutoSim
    }

    // MARK: 连接与配置

    var teamNumber: Int = 0 {
        didSet {
            settings.set("teamNumber", teamNumber)
            radioTeamBox.set(teamNumber)
            syncClientConfig()
        }
    }
    var manualIP: String = "" {
        didSet {
            // AUTO_SIM / 禁用持久化的会话仍更新内存与 client 配置，仅跳过落盘
            if persistenceEnabled {
                settings.set("manualIP", manualIP.isEmpty ? nil : manualIP)
            }
            syncClientConfig()
        }
    }
    /// 已应用手动地址的提示（读 model，不读编辑中的草稿）。
    /// 普通手动地址：自动发现已关闭，仅向该地址发送；
    /// 合法 127/8 且已设队号：明确提示这是本机回环地址，不是真实机器人。
    var appliedManualIPWarning: String? {
        let address = manualIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        if teamNumber > 0, Self.isLoopbackIPv4(address) {
            return tr("已应用手动地址 %@：该地址指向本机，而非真实机器人；自动发现已关闭，仅向该地址发送。", address)
        }
        return tr("已应用手动地址 %@：自动发现已关闭，仅向该地址发送。", address)
    }

    static func isLoopbackIPv4(_ address: String) -> Bool {
        var addr = in_addr()
        guard inet_pton(AF_INET, address, &addr) == 1 else { return false }
        return UInt32(bigEndian: addr.s_addr) >> 24 == 127
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
    /// App Nap 抑制令牌（见 start()）：随模型常驻，进程退出即失效，故不调 endActivity
    private var latencyToken: NSObjectProtocol?
    private(set) var watchdogNotFed = false
    private var watchdogMissCount = 0
    var macStatus = MacStatusSnapshot(systemCPUPercent: 0, processMemoryMB: 0)
    var localNetworkSummary = tr("检测中…")
    private let networkMonitor = NetworkPathMonitor()
    private let macStatusSampler = MacStatusMonitor.BackgroundSampler()
    private var wpilogWriter: WPILogWriter?
    var commState: DSClient.CommState = .idle
    var watchdogHealthy = true

    /// 遥测显示合并（性能修复 2026-09-27）：应答包 50Hz 到达，逐包写 @Observable 属性
    /// 会让状态栏/安全栏/驾驶页每 20ms 失效重建一次。这里只暂存最新载荷，至少间隔
    /// 100ms 才发布到可观察属性（显示 10Hz 足够）。控制路径不受影响：控制环读的是
    /// snapshotBox（仅操作员意图），看门狗喂狗核算与电池历史采样仍逐应答执行。
    private var pendingResponse: NICodec.ResponsePacket?
    private var lastTelemetryPublishAt: TimeInterval = 0

    // MARK: 控制状态（操作员意图）

    var mode: NIMode = .teleoperated
    var alliance: AllianceStation = .red1 {
        didSet { settings.set("alliance", String(alliance.rawValue)) }
    }
    private(set) var enabled = false
    private(set) var estopEngaged = false
    var estopSoundPlayer: (() -> Void)?
    private var estopSound: NSSound?
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
    var stdoutLines: [LogLine] = []
    var disableFaults: (comms: UInt16, twelveV: UInt16) = (0, 0)
    var railFaults: (sixV: UInt16, fiveV: UInt16, threeV: UInt16) = (0, 0, 0)

    // MARK: 手柄

    /// UI 可见槽位镜像（@Observable）：结构变化（增删/移动）立即发布；轴/按键
    /// 实时值由 publishVisibleSlotsIfDue 以 ≥100ms 节流刷新——50Hz 逐 tick 写
    /// @Observable 数组会让 USB 页每 20ms 整页失效重建。控制路径不读它（见 controlSlots）。
    var joystickSlots: [JoystickSlot] = []
    var lastHIDScanAt: Date?
    /// 控制槽位（非 UI 发布）：50Hz 每 tick 刷新最新手柄值并进控制快照。结构真值在此，
    /// rebuildSlots/moveSlot 先改它，再按需发布到 joystickSlots。
    private var controlSlots: [JoystickSlot] = []
    private var lastSlotsPublishAt: TimeInterval = 0
    /// HID 轮询源（默认真实 IOKit 主线程轮询；测试注入假设备流）。
    /// 50Hz 调用、保持主线程——IOKit 路径未在其他线程验证过，不擅自迁移。
    var hidPoller: @MainActor () -> [HIDDeviceSnapshot] = { GamepadInputManager.shared.pollAll() }

    // MARK: 慢速设置（比赛信息；空串视为清除，不落盘）

    var gameData: String = "" {
        didSet {
            if persistenceEnabled {
                settings.set("gameData", gameData.isEmpty ? nil : gameData)
            }
        }
    }
    var competition: String = "" {
        didSet {
            if persistenceEnabled {
                settings.set("competition", competition.isEmpty ? nil : competition)
            }
        }
    }
    var matchType: UInt8 = 0 {
        didSet {
            if persistenceEnabled { settings.set("matchType", Int(matchType)) }
        }
    }
    // MARK: Dashboard 选择（多选 0–3 个；空选择只禁用 Launch）

    /// 真源：多选集合（无序）。展示与启动一律走 `selectedDashboards`（字母序），
    /// didSet 即时落盘；重启时优先读 `dashboards`，缺失则回退旧版单选键。
    var dashboardSelection: Set<DashboardKind> = [.advantageScope] {
        didSet { persistDashboardSelection() }
    }
    /// 规范顺序（AdvantageScope、Elastic、Shuffleboard）：UI 左中右与启动顺序同源。
    var selectedDashboards: [DashboardKind] {
        DashboardKind.allCases.filter { dashboardSelection.contains($0) }
    }
    /// 旧版单选设置 / WebUI 旧键的兼容视图：读首个选中项（无选中为 nil），写等于只选该项。
    var dashboardKind: DashboardKind? {
        get { selectedDashboards.first }
        set {
            if let newValue { dashboardSelection = [newValue] } else { dashboardSelection = [] }
        }
    }
    /// 启动器：默认真实 `open -a`；测试注入记录闭包，绝不打开外部 App。
    var dashboardLauncher = DashboardLauncher()

    // MARK: Practice 时序

    enum PracticePhase: String, Sendable {
        case idle, delayBeforeAuto, autonomous, delayBeforeTeleop, teleoperated
        case transitionShift, allianceShift1, allianceShift2, allianceShift3, allianceShift4, endgame
        case finished
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
    var practiceStartDelay: TimeInterval = 2 {
        didSet { settings.set("practiceStartDelay", practiceStartDelay) }
    }
    var practiceSeasonYear = 2026 {
        didSet {
            settings.set("practiceSeasonYear", practiceSeasonYear)
            if timeoutActive { cancelTimeout() }
        }
    }
    /// 年份下拉的展示顺序：新 → 旧（2026、2025、…）。
    /// 只改 UI 顺序；`PracticeTimingPreset.all` 的事实顺序保持原样。
    var practiceSeasonYearChoices: [Int] {
        PracticeTimingPreset.all.map(\.year).sorted(by: >)
    }
    var practiceTransitionShiftTime: TimeInterval = 10 {
        didSet { settings.set("practiceTransitionShiftTime", practiceTransitionShiftTime) }
    }
    var practiceAllianceShiftTime: TimeInterval = 25 {
        didSet { settings.set("practiceAllianceShiftTime", practiceAllianceShiftTime) }
    }
    var practiceEndgameTime: TimeInterval = 30 {
        didSet { settings.set("practiceEndgameTime", practiceEndgameTime) }
    }
    var effectivePracticeTeleopTime: TimeInterval {
        guard practiceSeasonYear >= 2026 else { return practiceTeleopTime }
        return practiceTransitionShiftTime + practiceAllianceShiftTime * 4 + practiceEndgameTime
    }
    var currentPracticePhaseDuration: TimeInterval { sequencer.phaseDuration }
    var soundsEnabled = true {
        didSet { settings.set("soundsEnabled", soundsEnabled) }
    }
    var enableDisableSoundsEnabled = true {
        didSet { settings.set("enableDisableSoundsEnabled", enableDisableSoundsEnabled) }
    }
    var timeoutDuration: TimeInterval = 480
    var timeoutRemaining: TimeInterval = 0
    var timeoutActive: Bool { timeoutSequencer.phase == .running }

    // MARK: 界面语言（中英双语：默认跟随系统，可手动覆盖；查找逻辑在 DSCore/Localization.swift）

    var languageMode = LanguageMode.system {
        didSet {
            settings.set("language", languageMode.rawValue)
            LanguageManager.shared.setMode(languageMode)
        }
    }

    // MARK: 界面外观（跟随系统 / 浅色 / 深色；与语言同属 UI 偏好，经 NSApp.appearance 全局生效）

    var appearanceMode = AppearanceMode.system {
        didSet {
            settings.set("appearance", appearanceMode.rawValue)
            NSApplication.shared.appearance = appearanceMode.nsAppearance
        }
    }

    // MARK: 应用图标（运行中 Dock 图标；独立两维偏好：样式 × 外观，与界面主题互不影响）

    var iconStyle = IconStyle.color {
        didSet {
            settings.set("appIconStyle", iconStyle.rawValue)
            appIconCenter.update(style: iconStyle, mode: iconAppearance)
        }
    }
    var iconAppearance = AppearanceMode.system {
        didSet {
            settings.set("appIconAppearance", iconAppearance.rawValue)
            appIconCenter.update(style: iconStyle, mode: iconAppearance)
        }
    }
    let appIconCenter = AppIconCenter()

    // MARK: 事件日志

    var dsEvents: [LogLine] = []

    // MARK: 抓包录制（设置页开关；报告 §6 决策 3。重启按上次偏好恢复：true 即按开关原义开始录制）

    var recording = false {
        didSet {
            if persistenceEnabled { settings.set("recording", recording) }
            updateRecorder()
        }
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

    // MARK: 图表历史（1Hz 采样，机器人页历史曲线的真实时间序列）

    var cpuHistory: [CPUPoint] = []
    var lossHistory: [LossPoint] = []

    // MARK: 内部

    private let client = DSClient()
    private let snapshotBox = SnapshotBox()
    private let heartbeatBox = HeartbeatBox()
    private let radioTeamBox = RadioTeamBox()
    private let settings: SettingsStore
    private var appSupportDirectory: AppSupportDirectory?
    private let persistenceAllowed: Bool
    private var lastBatterySampleAt: TimeInterval = 0
    private var radioProbe: RadioProbe?
    /// NI 服务发现（`_ni._tcp` Bonjour 浏览，start() 启动）：默认真实 NWBrowser，测试注入假浏览器（无套接字）。
    var makeLocalNetworkDiscovery: @MainActor () -> LocalNetworkDiscovery = { LocalNetworkDiscovery() }
    private var localNetworkDiscovery: LocalNetworkDiscovery?
    private let nt4Server = NT4Server(port: 6767)
    private var webUI: WebUIServer?
    private let opModeHashBox = OpModeHashBox()
    private var sequencer = PracticeSequencer()
    let practiceAudio = PracticeAudioPlayer()
    private var practiceTimer: Timer?
    private var timeoutSequencer = TimeoutSequencer()
    private var timeoutTimer: Timer?
    private var pollTimer: Timer?
    private var tickers: [Timer] = []
    // 吞吐汇总行状态（打包版 E2E 判活断言用；Diag 镜像，不进 UI 日志）
    private var statsTickCount = 0
    private var lastThroughputTick: (tx: UInt64, at: TimeInterval)?

    // MARK: 生命周期

    var persistenceEnabled: Bool { persistenceAllowed }

    func loadPersistedSettings() {
        // 语言 / 外观不受 AUTO_SIM 门控影响：模拟器会话同样按上次选择显示（写入侧 didSet 本就不设门控）
        if let raw = settings.string("language"), let mode = LanguageMode(rawValue: raw) {
            languageMode = mode
        }
        if let raw = settings.string("appearance"), let mode = AppearanceMode(rawValue: raw) {
            appearanceMode = mode
        }
        // 图标偏好与语言/外观同属 UI 偏好：门控前恢复（AUTO_SIM 会话同样按上次选择显示图标）
        if let raw = settings.string("appIconStyle"), let style = IconStyle(rawValue: raw) {
            iconStyle = style
        }
        if let raw = settings.string("appIconAppearance"), let appearance = AppearanceMode(rawValue: raw) {
            iconAppearance = appearance
        }
        guard persistenceEnabled else { return }
        if let t = settings.integer("teamNumber"), t > 0 { teamNumber = t }
        if let ip = settings.string("manualIP") { manualIP = ip }
        if let raw = settings.string("alliance"), let a = AllianceStation(rawValue: UInt8(raw) ?? 255) { alliance = a }
        // 新多选键优先；缺失或损坏时回退旧版单选键（空串 = 全部取消，属合法值）
        if let stored = settings.string("dashboards").flatMap(DashboardKind.selection(from:)) {
            dashboardSelection = stored
        } else if let kind = settings.string("dashboardKind").flatMap(DashboardKind.init(rawValue:)) {
            dashboardSelection = [kind]
        }
        if let v = settings.double("practiceAutoTime"), v >= 1 { practiceAutoTime = v }
        if let v = settings.double("practiceTeleopTime"), v >= 15 { practiceTeleopTime = v }
        if let v = settings.double("practiceDelayTime"), v >= 0 { practiceDelayTime = v }
        if let v = settings.double("practiceStartDelay"), v >= 0 { practiceStartDelay = v }
        if let year = settings.integer("practiceSeasonYear"), PracticeTimingPreset.forYear(year) != nil {
            practiceSeasonYear = year
        }
        if let v = settings.double("practiceTransitionShiftTime"), v >= 0 { practiceTransitionShiftTime = v }
        if let v = settings.double("practiceAllianceShiftTime"), v >= 1 { practiceAllianceShiftTime = v }
        if let v = settings.double("practiceEndgameTime"), v >= 0 { practiceEndgameTime = v }
        if let b = settings.bool("soundsEnabled") { soundsEnabled = b }
        if let b = settings.bool("enableDisableSoundsEnabled") { enableDisableSoundsEnabled = b }
        if let b = settings.bool("dslogEnabled") { dslogEnabled = b }
        // 比赛信息：空串不落盘（见 didSet），恢复时只在有值时赋值；场次类型只接受 0...3
        if let v = settings.string("competition") { competition = v }
        if let v = settings.string("gameData") { gameData = v }
        if let v = settings.integer("matchType"), (0...3).contains(v) { matchType = UInt8(v) }
        if let b = settings.bool("recording") { recording = b }
        if let raw = settings.string("protocolKind"), let kind = DSClient.ProtocolKind(rawValue: raw) {
            protocolKind = kind
        }
    }

    /// 多选即时落盘：新键存规范顺序的逗号列表（空串 = 全不选），旧单选键同步为首选项。
    private func persistDashboardSelection() {
        guard persistenceEnabled else { return }
        settings.set("dashboards", selectedDashboards.map(\.rawValue).joined(separator: ","))
        settings.set("dashboardKind", dashboardKind?.rawValue)
    }

    /// 数据目录首次使用时解析（DSModel 初始化不触碰用户目录；UI 干测试不产生副作用）。
    /// 旧目录补齐由 AppSupportDirectory 在后台队列执行，不阻塞主线程；
    /// WebUI 日志列表、dslog、抓包录制全部由此返回的同一实例派生。
    /// 测试可用 `MATCHSTICKS_DS_APPLICATION_SUPPORT` 覆盖 Application Support 根。
    private func appSupport() -> AppSupportDirectory {
        if let appSupportDirectory { return appSupportDirectory }
        let resolved = AppSupportDirectory()
        appSupportDirectory = resolved
        return resolved
    }

    func start() {
        // 幂等：installTimers 往 main runloop 加 4 个定时器且从不清理，
        // 重复执行（多窗口 / 状态恢复再跑一次 .task）会叠加定时器与心跳源
        guard !startInvoked else { return }
        startInvoked = true

        // 安全链级：控制环 20ms 与 UI 心跳看门狗都是延迟敏感的常驻活动。应用进入
        // 后台/未激活时 macOS 的 App Nap 会把 DispatchSourceTimer 节流，控制包间隔
        // 拉长会吃掉 robot 侧约 200ms 看门狗余量，也可能让本进程心跳看门狗误判。
        // .latencyCritical 对该进程关闭 App Nap 与相关节流。
        latencyToken = ProcessInfo.processInfo.beginActivity(
            options: [.latencyCritical],
            reason: "MatchSticks DS 控制环 20ms 与安全看门狗：停发控制包即触发机器人看门狗失能")
        loadPersistedSettings()
        // 启动恢复后显式设置运行时图标（默认安装也在此时首次推送日间图稿），
        // 并开始监听系统深浅（跟随系统模式随系统重推；固定模式不受影响）
        appIconCenter.update(style: iconStyle, mode: iconAppearance)
        appIconCenter.startObservingSystemAppearance()
        installTimers()
        networkMonitor.start()
        macStatusSampler.start()
        GamepadInputManager.shared.onDevicesChanged = { [weak self] in
            Task { @MainActor in self?.rescanJoysticks() }
        }
        GamepadInputManager.shared.onError = { [weak self] message in
            Task { @MainActor in self?.log(message) }
        }
        GamepadInputManager.shared.start()
        rescanJoysticks()

        client.snapshotProvider = { [snapshotBox] in snapshotBox.get() }
        syncClientConfig()
        client.heartbeatAge = { [heartbeatBox] in heartbeatBox.ageSeconds() }
        // 冷启动伪触发修复：HeartbeatBox 的 lastBeat 在模型创建时初始化，而 beat 定时器
        // 要到 runloop 下一轮才首跳——控制环在 client.start() 后 20ms 内读到的心跳年龄
        // 实为「应用启动耗时」（实测 0.3–1s），必然 >200ms 误判冻结并强清使能。
        // 这里在控制环启动前同步喂一次，把年龄归零；定时器随即接管（真冻结仍会触发）。
        heartbeatBox.beat()
        client.recordSink = { [recorderBox] dir, data in recorderBox.record(dir, data) }
        client.eventHandler = { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.handle(event) }
        }
        // radio 选址（root cause ②，2026-10-31 真机确认）：
        // - 纯函数 RadioProbe.autoTarget 决定目标——普通自动 = 队号派生 10.T.E.1:80，
        //   与 roboRIO manualIP 无关（旧实现填手动 IP 后 radio 灯亮来自 roboRIO:80）；
        // - AUTO_SIM 保持 127.0.0.1 + 模拟 radio 端口 8080；
        // - hostProvider 只捕获值盒（不跨线程读 MainActor 属性）；队号变化经 radioTeamBox 生效。
        radioTeamBox.set(teamNumber)
        let probe = RadioProbe(configuration: RadioProbe.Configuration())
        probe.hostProvider = { [radioTeamBox] in
            RadioProbe.autoTarget(autoSim: DSModel.isAutoSim, teamNumber: radioTeamBox.get())
        }
        probe.onResult = { [weak self] ok in
            Task { @MainActor in self?.applyRadioResult(ok) }
        }
        probe.start()
        radioProbe = probe

        started = true
        nt4Server.onLog = { [weak self] line in
            Task { @MainActor in self?.log(line) }
        }
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
                        self.log(tr("NT4 首个机器人写入：%@", name))
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

        startLocalNetworkDiscovery()
        startWebUI()
        client.start()
        log(tr("MatchSticks DS 控制环已启动（20ms）"))

        if DSModel.isAutoSim {
            manualIP = "127.0.0.1"
            log(tr("MATCHSTICKS_DS_AUTO_SIM=1：自动连接本机模拟器 127.0.0.1"))
        }
        if DSEnvironment.isEnabled("AUTO_MRC") {
            protocolKind = .mrc
            log(tr("MATCHSTICKS_DS_AUTO_MRC=1：切换 MRC V2 协议（SystemCore）"))
        }
    }

    private func syncClientConfig() {
        client.updateConfig { cfg in
            cfg.teamNumber = self.teamNumber
            cfg.manualIP = self.manualIP.isEmpty ? nil : self.manualIP
            cfg.protocolKind = self.protocolKind
        }
    }

    /// 机器人重搜动作：默认走真实 DSClient.refreshConnection()；测试注入记录闭包。
    var robotConnectionRefresher: (() -> Void)?

    /// 手动刷新机器人连接（迷你驾驶台刷新按钮）：未连接时执行真重搜
    /// （清 mDNS 解析节流/缓存、重建发送候选）；已连接时拒绝——不打断活跃控制链路
    /// （重建候选会触发 autoDisabled，等于误失能）。返回是否真的执行了重搜。
    @discardableResult
    func refreshRobotConnection() -> Bool {
        guard !commConnected else {
            log(tr("已连接机器人，无需刷新；刷新仅在未连接时重新搜索。"))
            return false
        }
        if let robotConnectionRefresher {
            robotConnectionRefresher()
        } else {
            client.refreshConnection()
        }
        log(tr("已请求重新搜索机器人"))
        return true
    }

    /// Radio 探测结果落库：仅真实翻转时写日志。
    /// RadioProbe.onResult 本身只在值变化时回调；这里再守一次，重复回调与直接调用都不刷。
    func applyRadioResult(_ reachable: Bool) {
        guard reachable != radioReachable else { return }
        radioReachable = reachable
        log(reachable ? tr("Radio 状态：已响应") : tr("Radio 状态：无响应"))
    }

    /// 本机网络摘要落库：从「检测中…」进入实际状态、以及实际状态变化时各记一条；
    /// 相同摘要重复上报不刷日志（NWPathMonitor 回调可能很频繁）。
    @discardableResult
    func applyLocalNetworkSummary(_ summary: String) -> Bool {
        guard summary != localNetworkSummary else { return false }
        localNetworkSummary = summary
        guard summary != tr("检测中…") else { return false }
        log(tr("本机网络状态：%@", summary))
        return true
    }

    /// 启动一次 NI 服务发现（幂等；仅 AUTO_SIM 跳过——E2E 不浏览网络上无关的机器人；
    /// autoSim 缺省跟随会话 AUTO_SIM 标志，测试显式传入）。
    /// 不看 teamNumber / manualIP：默认队号 0、空手动地址同样启动，首次 start() 即触发系统本地网络
    /// 授权询问。浏览结果只写日志：不进发送轮转、不自动连接（控制客户端的 mDNS 解析独立于此）。
    func startLocalNetworkDiscovery(autoSim: Bool? = nil) {
        guard !(autoSim ?? DSModel.isAutoSim), localNetworkDiscovery == nil else { return }
        let discovery = makeLocalNetworkDiscovery()
        discovery.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handleLocalNetworkDiscovery(event) }
        }
        discovery.start()
        localNetworkDiscovery = discovery
    }

    private func handleLocalNetworkDiscovery(_ event: LocalNetworkDiscoveryEvent) {
        switch event {
        case .policyDenied:
            log(tr("本地网络授权被拒绝：请在「系统设置 → 隐私与安全性 → 本地网络」中允许 MatchSticks DS，然后重新打开应用。"))
        case .failed(let reason):
            log(tr("NI 服务发现失败：%@", reason))
        case .services(let names):
            log(names.isEmpty ? tr("NI 服务发现：当前没有 NI 设备")
                              : tr("NI 服务发现：%@", names.joined(separator: ", ")))
        case .waiting(let reason):
            Diag.write(tr("NI 服务发现等待：%@", reason))
        case .ready:
            Diag.write(tr("NI 服务发现已就绪"))
        }
    }

    // MARK: 主线程 50Hz：轮询 HID → 刷新槽位 → 填快照盒子
    // 定时器都挂在主 runloop 上，回调天然在主线程：直接 MainActor.assumeIsolated 直达，
    // 不再每 tick 包一层 Task { @MainActor }（50Hz×4 个定时器的无谓堆分配 + 执行器跳转）。

    func installTimers() {
        updateDSLogWriter()
        let dslog = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.appendDSLogEntry() }
        }
        RunLoop.main.add(dslog, forMode: .common)
        let poll = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAndPublishSnapshot() }
        }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll

        let beat = Timer(timeInterval: 0.01, repeats: true) { [heartbeatBox] _ in
            heartbeatBox.beat()
        }
        RunLoop.main.add(beat, forMode: .common)

        let elapsed = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let since = self.enabledSince else { return }
                self.enabledElapsed = Date().timeIntervalSince(since)
            }
        }
        RunLoop.main.add(elapsed, forMode: .common)
        tickers.append(elapsed)
    }

    private var lastRescan = Date.distantPast

    func pollAndPublishSnapshot() {
        // 控制路径（50Hz）：每 tick 刷新手柄实时值进 controlSlots（列表重建 0.5s 防抖）
        let devices = hidPoller()
        for (i, slot) in controlSlots.enumerated() {
            guard let device = devices.first(where: { $0.uniqueID == slot.uniqueID }) else { continue }
            controlSlots[i].apply(device)
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
        snap.joysticks = controlSlots.prefix(6).map(\.data)
        snap.joystickDescriptors = controlSlots.prefix(6).map(\.descriptor)
        snap.matchTime = practiceTimeTag
        if !gameData.isEmpty { snap.gameData = gameData }
        if !competition.isEmpty || matchType != 0 {
            snap.matchInfo = .init(competition: competition, type: matchType)
        }
        snapshotBox.set(snap)
        // UI 路径：可见手柄值 ~10Hz 节流发布（控制快照在上面已每 tick 发布）
        publishVisibleSlotsIfDue()
    }

    /// 可见手柄值节流发布（≥100ms 一次；结构变化走 publishVisibleSlotsNow 立即发布）
    private func publishVisibleSlotsIfDue() {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastSlotsPublishAt >= 0.1 else { return }
        lastSlotsPublishAt = now
        joystickSlots = controlSlots
    }

    private func publishVisibleSlotsNow() {
        lastSlotsPublishAt = Date().timeIntervalSinceReferenceDate
        joystickSlots = controlSlots
    }

    private var practiceTimeTag: Float? {
        guard practicePhase != .idle, practicePhase != .finished else { return nil }
        return Float(max(0, practiceRemaining))
    }

    var commConnected: Bool {
        if case .connected = commState { return true }
        return false
    }

    // MARK: 更新安全门状态映射（UpdateCenter 读取；点击重启时刻现场求值，不缓存）
    var updateGateState: UpdateSafetyGate.State {
        UpdateSafetyGate.State(
            enabled: enabled,
            commConnected: commConnected,
            estopEngaged: estopEngaged
        )
    }

    // MARK: WebUI（localhost:6768；报告 §6/§7——日志列表/下载、设置查看覆盖、状态）

    private func startWebUI() {
        guard webUI == nil else { return }
        let logsDirectory = appSupport().subdirectory("Logs")
        let env = WebUIServer.Environment(
            logsDirectory: { logsDirectory },
            listSettings: { [weak self] in
                guard let self else { return [:] }
                return DispatchQueue.main.sync {
                    MainActor.assumeIsolated { self.webSettingsSnapshot() }
                }
            },
            applySetting: { [weak self] key, value in
                guard let self else { return tr("应用未就绪") }
                return DispatchQueue.main.sync {
                    MainActor.assumeIsolated { self.applyWebSetting(key: key, value: value) }
                }
            },
            status: { [weak self] in
                guard let self else { return [:] }
                return DispatchQueue.main.sync {
                    MainActor.assumeIsolated { self.webStatusSnapshot() }
                }
            }
        )
        let server = WebUIServer(port: 6768, environment: env)
        server.onLog = { [weak self] line in
            Task { @MainActor in self?.log(line) }
        }
        server.start()
        webUI = server
    }

    /// 设置快照（字符串值；白名单与 applyWebSetting 一致）
    func webSettingsSnapshot() -> [String: String] {
        [
            "teamNumber": String(teamNumber),
            "manualIP": manualIP,
            "protocolKind": protocolKind.rawValue,
            "alliance": String(alliance.rawValue),
            // 旧单选键保留（首个选中项；无选中为空串），新客户端读 dashboards 拿完整多选
            "dashboardKind": dashboardKind?.rawValue ?? "",
            "dashboards": selectedDashboards.map(\.rawValue).joined(separator: ","),
            "practiceAutoTime": String(practiceAutoTime),
            "practiceTeleopTime": String(practiceTeleopTime),
            "practiceDelayTime": String(practiceDelayTime),
            "soundsEnabled": soundsEnabled ? "true" : "false",
            "enableDisableSoundsEnabled": enableDisableSoundsEnabled ? "true" : "false",
            "dslogEnabled": dslogEnabled ? "true" : "false",
            "language": languageMode.rawValue,
        ]
    }

    /// 设置覆盖（逐键校验；范围与 loadPersistedSettings 同源）。返回 nil = 应用成功。
    func applyWebSetting(key: String, value: String) -> String? {
        switch key {
        case "teamNumber":
            guard let t = Int(value), (0...99999).contains(t) else { return tr("队伍号须为 0–99999 的整数") }
            teamNumber = t
        case "manualIP":
            guard value.count <= 45 else { return tr("地址过长") }
            manualIP = value
        case "protocolKind":
            guard let kind = DSClient.ProtocolKind(rawValue: value) else { return tr("未知协议：%@", value) }
            protocolKind = kind
        case "alliance":
            guard let raw = UInt8(value), let a = AllianceStation(rawValue: raw) else { return tr("非法站位值") }
            alliance = a
        case "dashboardKind":
            // 旧键 = 单选语义（WebUI 旧客户端兼容）；空串 = 全部取消（与快照可往返）
            if value.isEmpty {
                dashboardSelection = []
            } else if let d = DashboardKind(rawValue: value) {
                dashboardKind = d
            } else {
                return tr("未知 Dashboard：%@", value)
            }
        case "dashboards":
            // 新键 = 逗号分隔多选；空串 = 全部取消
            guard let selection = DashboardKind.selection(from: value) else {
                return tr("Dashboard 须为 AdvantageScope / Elastic / Shuffleboard 的逗号分隔列表")
            }
            dashboardSelection = selection
        case "practiceAutoTime":
            guard let v = Double(value), v >= 1 else { return tr("自动阶段时长须 ≥1 秒") }
            practiceAutoTime = v
        case "practiceTeleopTime":
            guard let v = Double(value), v >= 15 else { return tr("遥控阶段时长须 ≥15 秒") }
            practiceTeleopTime = v
        case "practiceDelayTime":
            guard let v = Double(value), v >= 0 else { return tr("延迟须 ≥0 秒") }
            practiceDelayTime = v
        case "soundsEnabled":
            guard value == "true" || value == "false" else { return tr("须为 true/false") }
            soundsEnabled = (value == "true")
        case "enableDisableSoundsEnabled":
            guard value == "true" || value == "false" else { return tr("须为 true/false") }
            enableDisableSoundsEnabled = (value == "true")
        case "dslogEnabled":
            guard value == "true" || value == "false" else { return tr("须为 true/false") }
            dslogEnabled = (value == "true")
        case "language":
            // system / chinese / english（LanguageMode.rawValue）；改动经 didSet 即时生效并落盘
            guard let mode = LanguageMode(rawValue: value) else { return tr("语言须为 system/chinese/english") }
            languageMode = mode
        default:
            return tr("未知设置项：%@", key)
        }
        log(tr("WebUI 设置覆盖：%@ = %@", key, value))
        return nil
    }

    /// 状态快照（P5 打包 E2E 经 /api/status 断言；含更新门现场求值）
    func webStatusSnapshot() -> [String: String] {
        let gate = UpdateSafetyGate.evaluate(updateGateState)
        let comm: String
        switch commState {
        case .idle: comm = "idle"
        case .searching: comm = "searching"
        case .connected(let host): comm = "connected(\(host))"
        }
        var dict: [String: String] = [
            "commState": comm,
            "enabled": enabled ? "true" : "false",
            "estopEngaged": estopEngaged ? "true" : "false",
            "teamNumber": String(teamNumber),
            "updateGateAllowed": gate == UpdateSafetyGate.Decision.allow ? "true" : "false",
        ]
        if case .blocked(let reason) = gate { dict["updateGateReason"] = reason }
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            dict["appVersion"] = v
        }
        return dict
    }

    var canEnable: Bool {
        !timeoutActive && SafetyGate.canEnableNow(SafetyGate.State(
            commConnected: commConnected,
            watchdogHealthy: watchdogHealthy,
            estopEngaged: estopEngaged,
            currentlyEnabled: enabled
        ))
    }

    /// 最近一次发布到控制环快照的 estop 位（UI 状态回归用：
    /// 验证急停触发/复位后快照同步刷新，不再依赖 50Hz 定时器时序）
    var latestPublishedSnapshotEstop: Bool { snapshotBox.get().control.estop }

    /// 最近一次发布到控制环快照的手柄数据（控制路径行为回归用）
    var latestPublishedJoysticks: [JoystickData] { snapshotBox.get().joysticks }

    // MARK: 操作员指令（安全门全部集中在这里）

    private enum EnableSoundSource { case operatorAction, automatic }

    func setEnabled(_ on: Bool) {
        setEnabled(on, soundSource: .operatorAction)
    }

    private func setEnabled(_ on: Bool, soundSource: EnableSoundSource) {
        // 幂等：与当前状态相同则不动作——否则重复点 Enable 会把 enabledSince
        // 计时器复位并重复写日志（迷你视图 ENABLE 曾因此可被误点）
        if on == enabled { return }
        if on {
            guard !timeoutActive else {
                log(tr("拒绝使能：%@", tr("Timeout 进行中")))
                return
            }
            let state = SafetyGate.State(
                commConnected: commConnected,
                watchdogHealthy: watchdogHealthy,
                estopEngaged: estopEngaged,
                currentlyEnabled: enabled
            )
            let decision = SafetyGate.evaluateEnable(state)
            guard case .allow = decision else {
                if case .deny(let reason) = decision { log(tr("拒绝使能：%@", reason)) }
                return
            }
        }
        enabled = on
        enabledSince = on ? Date() : nil
        if !on { enabledElapsed = 0 }
        log(on ? "ENABLED（\(mode.displayName)）" : "Disabled")
        if soundSource == .operatorAction { playEnableDisableSound() }
    }

    func triggerEstop() {
        guard !estopEngaged else { return }
        estopEngaged = true
        enabled = false
        enabledSince = nil
        // 同步刷新控制快照：否则快照盒里还是 ≤20ms 前的 estop=0，急停位上线被拖延
        pollAndPublishSnapshot()
        cancelTimeout()
        practiceAudio.stop()
        playEstopSound()
        log(tr("E-STOP 触发（Space）"))
    }

    /// FDS 语义复位：重启 robot code 解除 E-Stop 锁存
    func resetEstop() {
        guard estopEngaged else { return }
        estopEngaged = false
        // 竞态修复（2026-09-27 E2E 发现）：请求脉冲持续 ~120ms，期间若快照盒仍是旧值
        // （estop=1），发出的包会同时带 restartCode 请求与 estop 位——模拟器/机器人
        // 先清锁存又被同包 estop 位重新锁上，复位永久失效。控制环与脉冲都排在本
        // MainActor 回合之后，此处同步刷新保证脉冲窗口内的每个包都已是 estop=0。
        pollAndPublishSnapshot()
        client.sendRequestPulse(RequestWord(rebootRoboRIO: false, restartCode: true))
        log(tr("E-Stop 复位请求已发送（重启 robot code）"))
    }

    func rebootRoboRIO() {
        guard commConnected else { log(tr("Reboot 拒绝：无连接")); return }
        client.sendRequestPulse(RequestWord(rebootRoboRIO: true, restartCode: false))
        log(tr("已请求 roboRIO 重启"))
    }

    func restartRobotCode() {
        guard commConnected else { log(tr("Restart Code 拒绝：无连接")); return }
        client.sendRequestPulse(RequestWord(rebootRoboRIO: false, restartCode: true))
        log(tr("已请求重启 robot code"))
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
        log(tr("OpMode 选择：%@（hash 0x%@）", op.name, String(op.hash, radix: 16)))
    }

    // MARK: Dashboard 启动

    /// 一次启动全部选中项（空选择 = 无动作）；返回实际提交给系统的项，便于测试。
    /// 启动失败逐项记录，不因一项失败中断其余项。
    @discardableResult
    func launchSelectedDashboards() -> [DashboardKind] {
        let outcome = dashboardLauncher.launch(selectedDashboards)
        for kind in outcome.launched {
            log(tr("尝试启动 Dashboard：%@", kind.rawValue))
        }
        for kind in DashboardKind.allCases {
            guard let reason = outcome.failures[kind] else { continue }
            log(tr("启动 Dashboard 失败：%@（%@）——请确认已安装该应用", kind.rawValue, reason))
        }
        return outcome.launched
    }

    // MARK: Practice 时序

    func applyPracticeTimingPreset() {
        guard let preset = PracticeTimingPreset.forYear(practiceSeasonYear) else { return }
        practiceAutoTime = preset.autoTime
        practiceTeleopTime = preset.teleopTime
        practiceDelayTime = preset.teleopDelay
        practiceStartDelay = 0
        practiceTransitionShiftTime = 10
        practiceAllianceShiftTime = 25
        practiceEndgameTime = 30
    }

    func startPractice() {
        guard !sequencer.phase.isActive, !timeoutActive else { return }
        practiceAudio.stop()
        let breakdown: PracticeSequencer.TeleopBreakdown? = practiceSeasonYear >= 2026
            ? .init(transitionShift: practiceTransitionShiftTime, allianceShift: practiceAllianceShiftTime,
                    endgame: practiceEndgameTime)
            : nil
        sequencer = PracticeSequencer(config: .init(
            autoTime: practiceAutoTime, teleopTime: effectivePracticeTeleopTime, delayTime: practiceDelayTime,
            startDelay: practiceStartDelay, teleopBreakdown: breakdown,
            teleopWarningTime: PracticeTimingPreset.forYear(practiceSeasonYear)?.endgameWarningTime
        ))
        applyPracticeEvents(sequencer.start())
        practiceTimer?.invalidate()
        // 与 installTimers 一致用 .common 模式：scheduledTimer 默认 .default 模式，
        // 拖窗口/跟踪菜单期间不触发——比赛时序会在这些时刻停摆
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.practiceTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        practiceTimer = t
    }

    func aStop() {
        applyPracticeEvents(sequencer.abort())
        practiceTimer?.invalidate()
        practiceTimer = nil
    }

    func startTimeout() {
        guard practiceSeasonYear == 2022, !timeoutActive, !practiceActive, !estopEngaged else { return }
        setEnabled(false, soundSource: .automatic)
        practiceAudio.stop()
        timeoutSequencer = TimeoutSequencer(duration: timeoutDuration)
        applyTimeoutEvents(timeoutSequencer.start())
        guard timeoutActive else { return }
        timeoutTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.timeoutTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        timeoutTimer = timer
    }

    func cancelTimeout() {
        let wasActive = timeoutActive
        timeoutSequencer.cancel()
        timeoutRemaining = 0
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        if wasActive {
            practiceAudio.stop()
            log("Timeout cancelled")
        }
    }

    private func timeoutTick() {
        applyTimeoutEvents(timeoutSequencer.tick(0.1))
        timeoutRemaining = timeoutSequencer.remaining
        if !timeoutActive {
            timeoutTimer?.invalidate()
            timeoutTimer = nil
        }
    }

    private func applyTimeoutEvents(_ events: [TimeoutSequencer.Event]) {
        for event in events {
            switch event {
            case .started:
                timeoutRemaining = timeoutSequencer.remaining
                log("Timeout started")
            case .warning:
                playPracticeSound(.timeoutWarning)
                log("Timeout warning: 1:00 remaining")
            case .finished:
                timeoutRemaining = 0
                setEnabled(false, soundSource: .automatic)
                playPracticeSound(.timeoutEnd)
                log("Timeout ended")
            }
        }
    }

    private func practiceTick() {
        applyPracticeEvents(sequencer.tick(0.1))
        practiceRemaining = max(0, sequencer.remaining)
        if !sequencer.phase.isActive {
            practiceTimer?.invalidate()
            practiceTimer = nil
        }
    }

    private func applyPracticeEvents(_ events: [PracticeSequencer.Event]) {
        for event in events {
            switch event {
            case .entered(let phase):
                let previousPhase = practicePhase
                practicePhase = mapPhase(phase)
                practiceRemaining = sequencer.remaining
                switch phase {
                case .autonomous: setMode(.autonomous)
                case .teleoperated, .transitionShift, .allianceShift1, .allianceShift2,
                     .allianceShift3, .allianceShift4, .endgame: setMode(.teleoperated)
                default: break
                }
                if previousPhase == .autonomous && phase == .teleoperated {
                    playPracticeSound(.autoEnd)
                }
                switch phase {
                case .autonomous: playPracticeSound(.matchStart)
                case .delayBeforeTeleop: playPracticeSound(.autoEnd)
                case .teleoperated, .transitionShift: playPracticeSound(.teleopStart)
                case .allianceShift1, .allianceShift2, .allianceShift3, .allianceShift4:
                    playPracticeSound(.allianceShift)
                case .endgame: playPracticeSound(.endgame)
                default: break
                }
                if phase.isActive { log("Practice → \(phase.displayName)") }
            case .enable: setEnabled(true, soundSource: .automatic)
            case .disable: setEnabled(false, soundSource: .automatic)
            case .finished:
                if practicePhase != .finished { playPracticeSound(.matchEnd) }
                practicePhase = .finished
                log(tr("Practice 结束"))
            case .endgameWarning:
                playPracticeSound(.endgame)
            case .aborted:
                practicePhase = .finished
                playPracticeSoundImmediately(.matchStopped)
                log(tr("A-STOP：Practice 中止"))
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
        case .transitionShift: return .transitionShift
        case .allianceShift1: return .allianceShift1
        case .allianceShift2: return .allianceShift2
        case .allianceShift3: return .allianceShift3
        case .allianceShift4: return .allianceShift4
        case .endgame: return .endgame
        case .finished: return .finished
        }
    }

    private func playEstopSound() {
        if let estopSoundPlayer {
            estopSoundPlayer()
            return
        }
        if estopSound == nil {
            guard let url = Bundle.module.url(forResource: "FOGHORN", withExtension: "wav") else { return }
            estopSound = NSSound(contentsOf: url, byReference: false)
        }
        _ = estopSound?.play()
    }

    private func playPracticeSound(_ event: PracticeSoundEvent) {
        guard soundsEnabled,
              let filename = PracticeSoundCatalog.fileName(for: event, year: practiceSeasonYear) else { return }
        practiceAudio.enqueue(filename)
    }

    private func playPracticeSoundImmediately(_ event: PracticeSoundEvent) {
        let filename = soundsEnabled ? PracticeSoundCatalog.fileName(for: event, year: practiceSeasonYear) : nil
        practiceAudio.playImmediately(filename)
    }

    static func enableDisableSoundFileName(mode: NIMode, enabled: Bool, year: Int) -> String? {
        let event: PracticeSoundEvent
        switch (mode, enabled) {
        case (.teleoperated, true): event = .teleopStart
        case (.teleoperated, false): event = .matchEnd
        case (.autonomous, true): event = .matchStart
        case (.autonomous, false): event = .autoEnd
        case (.test, _): return nil
        }
        return PracticeSoundCatalog.fileName(for: event, year: year)
    }

    private func playEnableDisableSound() {
        guard enableDisableSoundsEnabled,
              let filename = Self.enableDisableSoundFileName(
                  mode: mode, enabled: enabled, year: practiceSeasonYear
              ) else { return }
        practiceAudio.enqueue(filename)
    }

    // MARK: 事件处理（client 事件 → 主线程状态）

    private func handle(_ event: DSClient.Event) {
        switch event {
        case .commState(let s):
            commState = s
        case .response(let p):
            // 逐应答执行（不随显示节流）：喂狗核算 + 电池历史采样（5Hz 内部节流）
            if p.watchdogFed {
                watchdogMissCount = 0
                if watchdogNotFed { watchdogNotFed = false; log(tr("Watchdog 恢复喂狗")) }
            } else {
                watchdogMissCount += 1
                if watchdogMissCount == 5 {
                    watchdogNotFed = true
                    log(tr("⚠️ Watchdog Not Fed（连续 5 应答未喂狗）"))
                }
            }
            appendBattery(p.batteryVoltage)
            pendingResponse = p
            publishTelemetryIfDue()
        case .tcpEvent(let e):
            handleTCP(e)
        case .opModes(let list):
            if list != opModes {
                opModes = list
                log(tr("收到 OpMode 列表（%d 项）", list.count))
            }
        case .stats(let loss, _, let tx, let rx):
            lossPercent = loss
            txCount = tx
            rxCount = rx
            // 控制环吞吐汇总行（stats 事件 1Hz；每 5s 一条）：打包版 E2E 判活依据——
            // 不能只看建链/进程存在，要看到控制包在按节拍持续发出（2026-09-16 教训）。
            statsTickCount += 1
            let nowT = Date().timeIntervalSinceReferenceDate
            if statsTickCount % 5 == 0, let last = lastThroughputTick, nowT > last.at {
                let hz = Double(tx &- last.tx) / (nowT - last.at)
                Diag.write(tr("控制环吞吐：%.1f Hz（tx=%d rx=%d loss=%.1f%%）", hz, tx, rx, loss))
            }
            if statsTickCount % 5 == 0 { lastThroughputTick = (tx, nowT) }
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
            log(tr("看门狗触发：UI 冻结 >200ms，已冻结使能输出"))
        case .watchdogRecovered:
            watchdogHealthy = true
            log(tr("看门狗恢复：控制环心跳正常"))
        case .autoDisabled(let reason):
            enabled = false
            enabledSince = nil
            log(tr("自动失能：%@", reason))
        case .log(let line):
            log(line)
        }
    }

    /// 发布暂存的遥测到可观察属性（≥100ms 一次；见 pendingResponse 注释）
    private func publishTelemetryIfDue() {
        guard let p = pendingResponse else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastTelemetryPublishAt >= 0.1 else { return }
        pendingResponse = nil
        lastTelemetryPublishAt = now
        robotStatus = p.status
        robotTrace = p.trace
        batteryVolts = p.batteryVoltage
        cpuCores = p.cpu.cores
        ramUsed = p.ramUsedBytes
        ramTotal = p.ramTotalBytes
        diskFree = p.diskFreeBytes
        can = p.can
        if !p.joystickOutputs.isEmpty { joystickOutputs = p.joystickOutputs }
    }

    private func handleTCP(_ e: NICodec.TCPEvent) {
        switch e {
        case .versions(let v):
            if v != versionEntries {
                versionEntries = v
                log(tr("收到版本信息（%d 项）", v.count))
            }
        case .error(var m):
            m.rowID = nextRowID()          // 协议 seq 会回绕，行身份由 DS 侧分配
            errorMessages.insert(m, at: 0)
            if errorMessages.count > 500 { errorMessages.removeLast() }
        case .stdout(let m):
            stdoutLines.append(LogLine(id: nextRowID(), text: m.message))
            if stdoutLines.count > 2000 { stdoutLines.removeFirst(1000) }
        case .disableFaults(let comms, let twelve):
            disableFaults = (comms, twelve)
        case .railFaults(let six, let five, let three):
            railFaults = (six, five, three)
        case .unknown:
            break
        }
    }

    // MARK: 手柄槽位（手动座次权威：重扫/插拔不重排，新手柄追加到末尾）

    /// 座次记忆：全部见过的设备按座次记录。离线设备保留原座次（重连回原位），
    /// 全新手柄追加到最后。封顶防频繁插拔无限增长。
    private var seatMemory: [String] = []

    func rescanJoysticks() {
        rebuildSlots(from: hidPoller())
    }

    private func rebuildSlots(from snapshots: [HIDDeviceSnapshot]) {
        controlSlots = snapshots
            .sorted { seatRank($0.uniqueID) < seatRank($1.uniqueID) }
            .enumerated()
            .map { JoystickSlot(index: $0.offset, device: $0.element) }
        rememberNewcomers(snapshots)
        lastHIDScanAt = Date()
        // 结构变化不等节流窗口：立即发布到可见槽位
        publishVisibleSlotsNow()
    }

    func moveSlot(_ index: Int, up: Bool) {
        let target = up ? index - 1 : index + 1
        guard controlSlots.indices.contains(index), controlSlots.indices.contains(target) else { return }
        controlSlots.swapAt(index, target)
        for i in controlSlots.indices { controlSlots[i].index = i }
        rewriteSeats()
        publishVisibleSlotsNow()
    }

    // MARK: 手柄造型（VID/PID 自动识别 + 手动覆盖；覆盖按 uniqueID 持久化）

    /// 生效造型：覆盖优先，否则按 VID/PID/名称识别（GamepadProfile.detect）。
    func gamepadSkin(for slot: JoystickSlot) -> GamepadSkin {
        GamepadProfile.effectiveSkin(
            sample: GamepadSample(slot: slot),
            override: gamepadSkinOverride(for: slot))
    }

    /// 手动覆盖（nil = 回自动识别）。key 含 uniqueID：同款两只手柄可分别指定。
    func gamepadSkinOverride(for slot: JoystickSlot) -> GamepadSkin? {
        settings.string("gamepadSkin." + slot.uniqueID).flatMap(GamepadSkin.init(rawValue:))
    }

    func setGamepadSkinOverride(_ skin: GamepadSkin?, for slot: JoystickSlot) {
        settings.set("gamepadSkin." + slot.uniqueID, skin?.rawValue)
    }

    /// 座次键：记忆中的名次；没见过的设备排最后，彼此按 uniqueID（即快照序）定先后
    private func seatRank(_ id: String) -> (Int, String) {
        (seatMemory.firstIndex(of: id) ?? Int.max, id)
    }

    /// 结构变化只追加新面孔；离线设备留在原座次上（重连回原位），不打乱他人
    private func rememberNewcomers(_ snapshots: [HIDDeviceSnapshot]) {
        for d in snapshots where !seatMemory.contains(d.uniqueID) {
            seatMemory.append(d.uniqueID)
        }
        if seatMemory.count > 16 { seatMemory.removeFirst(seatMemory.count - 16) }
    }

    /// 手动调整座次：在场设备按新座次记录，离线设备退到末尾（彼此保留相对先后）
    private func rewriteSeats() {
        let present = controlSlots.map(\.uniqueID)
        let presentSet = Set(present)
        var memory = present
        memory.append(contentsOf: seatMemory.filter { !presentSet.contains($0) })
        seatMemory = Array(memory.prefix(16))
    }

    // MARK: .dslog 采样（1Hz）

    private func updateDSLogWriter() {
        if dslogEnabled {
            guard dslogWriter == nil else { return }
            let dir = appSupport().subdirectory("Logs")
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy_MM_dd HH_mm_ss"
            let base = formatter.string(from: Date())
            do {
                dslogWriter = try DSLogWriter(fileURL: dir.appendingPathComponent(base + ".dslog"))
                wpilogWriter = try WPILogWriter(fileURL: dir.appendingPathComponent(base + ".wpilog"))
                startWPILogEntries()
                log(tr("会话日志记录开始（.dslog + .wpilog）"))
            } catch {
                log(tr("日志启动失败：%@", error.localizedDescription))
                dslogEnabled = false
            }
        } else {
            dslogWriter?.close(); dslogWriter = nil
            finishWPILogEntries()
            wpilogWriter?.close(); wpilogWriter = nil
        }
    }

    private func appendDSLogEntry() {
        // 读后台采样缓存（IOKit/mach 重采样已移出主线程）；日志写器仍在本主线程 tick 内
        if let sampled = macStatusSampler.latest {
            macStatus = sampled
        }
        applyLocalNetworkSummary(networkMonitor.summary)
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
        let text = "[\(Self.logTimeFormatter.string(from: Date()))] \(line)"
        if Diag.enabled {
            Diag.write(text)
        }
        dsEvents.append(LogLine(id: nextRowID(), text: text))
        if dsEvents.count > 1000 { dsEvents.removeFirst(500) }
    }

    /// 列表行身份发号器：滑窗截断（removeFirst）会让 `id: \.offset` 的全部行身份
    /// 整体漂移，SwiftUI diff 与 proxy.scrollTo 都会错位
    private func nextRowID() -> Int {
        rowIDCounter += 1
        return rowIDCounter
    }
    private var rowIDCounter = 0
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
    /// 与 axes 对齐的 HID usage（皮肤语义映射用；XInput 归一设备为重排后的 usage）。
    var axisUsages: [UInt32]
    var buttons: UInt64
    var buttonCount: Int
    var povs: [Int16]
    var isXbox: Bool
    var mode: GamepadInputMode
    var polarity: GamepadStickPolarity
    var usbLocationID: UInt32?
    var triggerAxisRange: GamepadTriggerRange

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

    init(index: Int, device: HIDDeviceSnapshot) {
        self.index = index
        self.uniqueID = device.uniqueID
        self.name = device.name
        self.vendorID = device.vendorID
        self.productID = device.productID
        self.axes = device.axes
        self.axisUsages = device.axisUsages
        self.buttons = device.buttons
        self.buttonCount = device.buttonCount
        self.povs = device.povs
        self.isXbox = device.isXbox
        self.mode = device.mode
        self.polarity = device.polarity
        self.usbLocationID = device.usbLocationID
        self.triggerAxisRange = device.triggerAxisRange
    }

    mutating func apply(_ device: HIDDeviceSnapshot) {
        axes = device.axes
        axisUsages = device.axisUsages
        buttons = device.buttons
        povs = device.povs
        name = device.name
        mode = device.mode
        polarity = device.polarity
        usbLocationID = device.usbLocationID
        triggerAxisRange = device.triggerAxisRange
    }
}

extension GamepadSample {
    /// 槽位 → 皮肤映射输入样本（纯转换，无状态）。
    init(slot: JoystickSlot) {
        self.init(name: slot.name, vendorID: slot.vendorID, productID: slot.productID,
                  axes: slot.axes, axisUsages: slot.axisUsages,
                  buttons: slot.buttons, povs: slot.povs,
                  mode: slot.mode, polarity: slot.polarity,
                  triggerAxisRange: slot.triggerAxisRange)
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
            recorderBox.start(directory: appSupport().subdirectory("captures")) { url in
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                return url.appendingPathComponent("capture-\(formatter.string(from: Date())).dsrec")
            }
            if let name = recorderBox.currentFileName { log(tr("抓包录制开始：%@", name)) }
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

    func start(directory: URL, naming: @escaping (URL) -> URL) {
        lock.lock(); defer { lock.unlock() }
        guard recorder == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = naming(directory)
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

/// 带稳定身份的单行日志（Console / DS 事件列表用）
struct LogLine: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
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

/// 声明顺序即展示与启动顺序（字母序：AdvantageScope、Elastic、Shuffleboard）。
/// rawValue 是持久化值与 WebUI 旧键取值，改名属契约变更，不顺手改。
enum DashboardKind: String, CaseIterable, Identifiable {
    case advantageScope = "AdvantageScope"
    case elastic = "Elastic"
    case shuffleboard = "Shuffleboard"

    var id: String { rawValue }

    /// `open -a` 的应用名：与既有启动逻辑逐项一致（Shuffleboard 安装名是小写）。
    var applicationName: String {
        switch self {
        case .advantageScope: return "AdvantageScope"
        case .elastic: return "Elastic"
        case .shuffleboard: return "shuffleboard"
        }
    }

    /// 逗号分隔列表解析（持久化新键与 WebUI 新键共用）。
    /// 空串 = 全部取消（合法）；含未知项 = 非法（nil），由调用方决定回退或报错。
    static func selection(from raw: String) -> Set<DashboardKind>? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        var result: Set<DashboardKind> = []
        for token in trimmed.split(separator: ",") {
            let name = token.trimmingCharacters(in: .whitespaces)
            guard let kind = DashboardKind(rawValue: name) else { return nil }
            result.insert(kind)
        }
        return result
    }
}

/// Dashboard 启动（一次启动所有选中项）。
/// `open` 可注入：单元测试只记录调用，绝不真正打开外部 App。
struct DashboardLauncher {
    /// 默认实现：`/usr/bin/open -a <应用名>`（沿用原有启动路径）。
    static func openWithSystem(_ kind: DashboardKind) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", kind.applicationName]
        try process.run()
    }

    var open: (DashboardKind) throws -> Void = DashboardLauncher.openWithSystem

    /// 按字母序启动；单项失败不阻断其余项。返回成功提交给系统的项与失败原因。
    func launch(_ kinds: [DashboardKind]) -> (launched: [DashboardKind], failures: [DashboardKind: String]) {
        let ordered = DashboardKind.allCases.filter { kinds.contains($0) }
        var launched: [DashboardKind] = []
        var failures: [DashboardKind: String] = [:]
        for kind in ordered {
            do {
                try open(kind)
                launched.append(kind)
            } catch {
                failures[kind] = error.localizedDescription
            }
        }
        return (launched, failures)
    }
}
