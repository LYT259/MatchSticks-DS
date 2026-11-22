import Foundation

// MARK: - SafetyGate：使能门禁纯逻辑（红线 3：使能路径决策集中、可单测）
// 报告 §6 决策 2「安全第一」：所有使能路径经过统一门禁。

public enum SafetyGate {
    public struct State: Sendable, Equatable {
        public var commConnected = false
        public var watchdogHealthy = true
        public var estopEngaged = false
        public var currentlyEnabled = false

        public init(commConnected: Bool = false, watchdogHealthy: Bool = true,
                    estopEngaged: Bool = false, currentlyEnabled: Bool = false) {
            self.commConnected = commConnected
            self.watchdogHealthy = watchdogHealthy
            self.estopEngaged = estopEngaged
            self.currentlyEnabled = currentlyEnabled
        }
    }

    public enum Decision: Sendable, Equatable {
        case allow
        case deny(reason: String)
    }

    public static func evaluateEnable(_ s: State) -> Decision {
        if s.currentlyEnabled { return .allow } // 重复使能无害（幂等）
        if s.estopEngaged { return .deny(reason: tr("E-Stop 已触发，先复位（Esc+I 或重启代码）")) }
        if !s.commConnected { return .deny(reason: tr("无机器人连接")) }
        if !s.watchdogHealthy { return .deny(reason: tr("控制环心跳异常")) }
        return .allow
    }

    public static func canEnable(_ s: State) -> Bool {
        if case .allow = evaluateEnable(s) { return true }
        return false
    }

    /// UI 可用性判定：此刻「按下 Enable 是否有意义」——已使能时为 false。
    /// 与 evaluateEnable 的分工（勿混用）：evaluateEnable 管**使能指令是否放行**
    /// （重复使能按幂等放行，见上），canEnableNow 管**按钮该不该可点**，
    /// 避免已使能时再点 Enable 把 enabledSince 计时器复位。
    public static func canEnableNow(_ s: State) -> Bool {
        if s.currentlyEnabled { return false }
        return canEnable(s)
    }
}

public struct PracticeTimingPreset: Sendable, Equatable {
    public let year: Int
    public let autoTime: TimeInterval
    public let teleopTime: TimeInterval
    public let teleopDelay: TimeInterval
    public let endgameWarningTime: TimeInterval?

    public static let all = [
        PracticeTimingPreset(year: 2022, autoTime: 15, teleopTime: 135, teleopDelay: 0, endgameWarningTime: 30),
        PracticeTimingPreset(year: 2023, autoTime: 15, teleopTime: 135, teleopDelay: 3, endgameWarningTime: 30),
        PracticeTimingPreset(year: 2024, autoTime: 15, teleopTime: 135, teleopDelay: 3, endgameWarningTime: 20),
        PracticeTimingPreset(year: 2025, autoTime: 15, teleopTime: 135, teleopDelay: 3, endgameWarningTime: 20),
        PracticeTimingPreset(year: 2026, autoTime: 20, teleopTime: 140, teleopDelay: 3, endgameWarningTime: nil),
    ]

    public static func forYear(_ year: Int) -> PracticeTimingPreset? {
        all.first { $0.year == year }
    }
}

// MARK: - PracticeSequencer：Practice 时序纯状态机（报告 §2.1 NI DS Practice 语义）
// 阶段：开始等待 → Auto → 过渡 → Teleop（2026 展开六个子阶段）→ 结束；A-Stop 任意时刻中止。

public struct PracticeSequencer: Sendable, Equatable {
    public enum Phase: Sendable, Equatable, CaseIterable {
        case idle
        case delayBeforeAuto
        case autonomous
        case delayBeforeTeleop
        case teleoperated
        case transitionShift
        case allianceShift1
        case allianceShift2
        case allianceShift3
        case allianceShift4
        case endgame
        case finished

        public var isActive: Bool { self != .idle && self != .finished }

        public var displayName: String {
            switch self {
            case .idle: return tr("待机")
            case .delayBeforeAuto: return tr("Auto 前延迟")
            case .autonomous: return "Autonomous"
            case .delayBeforeTeleop: return tr("Teleop 前延迟")
            case .teleoperated: return "Teleoperated"
            case .transitionShift: return "Transition Shift"
            case .allianceShift1: return "Alliance Shift 1"
            case .allianceShift2: return "Alliance Shift 2"
            case .allianceShift3: return "Alliance Shift 3"
            case .allianceShift4: return "Alliance Shift 4"
            case .endgame: return "Endgame"
            case .finished: return tr("已结束")
            }
        }
    }

    public struct TeleopBreakdown: Sendable, Equatable {
        public var transitionShift: TimeInterval
        public var allianceShift: TimeInterval
        public var endgame: TimeInterval
        public var total: TimeInterval { transitionShift + allianceShift * 4 + endgame }

        public init(transitionShift: TimeInterval = 10, allianceShift: TimeInterval = 25, endgame: TimeInterval = 30) {
            self.transitionShift = transitionShift
            self.allianceShift = allianceShift
            self.endgame = endgame
        }
    }

    public struct Config: Sendable, Equatable {
        public var autoTime: TimeInterval
        public var teleopTime: TimeInterval
        public var delayTime: TimeInterval
        public var startDelay: TimeInterval
        public var teleopBreakdown: TeleopBreakdown?
        public var teleopWarningTime: TimeInterval?

        public init(autoTime: TimeInterval = 15, teleopTime: TimeInterval = 135, delayTime: TimeInterval = 2,
                    startDelay: TimeInterval? = nil, teleopBreakdown: TeleopBreakdown? = nil,
                    teleopWarningTime: TimeInterval? = nil) {
            self.autoTime = autoTime
            self.teleopTime = teleopTime
            self.delayTime = delayTime
            self.startDelay = startDelay ?? delayTime
            self.teleopBreakdown = teleopBreakdown
            self.teleopWarningTime = teleopWarningTime
        }
    }

    public enum Event: Sendable, Equatable {
        case entered(Phase)   // 阶段切换（调用方负责对应模式切换）
        case enable           // 使能输出意图
        case disable          // 失能输出意图
        case finished         // 全程结束
        case aborted          // A-Stop
        case endgameWarning   // 2022–2025 Teleop 内提示，不改变当前阶段
    }

    public private(set) var phase: Phase = .idle
    public private(set) var remaining: TimeInterval = 0
    public private(set) var config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func start() -> [Event] {
        if config.startDelay > 0 {
            phase = .delayBeforeAuto
            remaining = config.startDelay
            return [.entered(.delayBeforeAuto)]
        }
        phase = .autonomous
        remaining = config.autoTime
        return [.entered(.autonomous), .enable]
    }

    /// A-Stop：立即失能并结束
    public mutating func abort() -> [Event] {
        guard phase.isActive else { return [] }
        phase = .finished
        remaining = 0
        return [.disable, .aborted, .finished]
    }

    private mutating func enterTeleop() -> [Event] {
        if let breakdown = config.teleopBreakdown {
            phase = .transitionShift
            remaining = breakdown.transitionShift
            return [.entered(.transitionShift), .enable]
        }
        phase = .teleoperated
        remaining = config.teleopTime
        var events: [Event] = [.entered(.teleoperated), .enable]
        if let warning = config.teleopWarningTime, warning >= config.teleopTime {
            events.append(.endgameWarning)
        }
        return events
    }

    /// 周期推进（建议 0.1s）；返回本 tick 累积的控制意图。
    /// 5ms 容差：抵消浮点累加误差与定时器抖动，避免阶段切换晚一拍。
    public mutating func tick(_ dt: TimeInterval) -> [Event] {
        guard phase.isActive else { return [] }
        remaining -= dt
        var events: [Event] = []
        if phase == .teleoperated, let warning = config.teleopWarningTime,
           remaining + dt > warning + 0.005, remaining <= warning + 0.005 {
            events.append(.endgameWarning)
        }
        if remaining > 0.005 { return events }

        switch phase {
        case .delayBeforeAuto:
            phase = .autonomous
            remaining = config.autoTime
            return [.entered(.autonomous), .enable]
        case .autonomous:
            if config.delayTime > 0 {
                phase = .delayBeforeTeleop
                remaining = config.delayTime
                return [.entered(.delayBeforeTeleop), .disable]
            }
            return enterTeleop()
        case .delayBeforeTeleop:
            return enterTeleop()
        case .teleoperated:
            phase = .finished
            remaining = 0
            return events + [.disable, .finished]
        case .transitionShift:
            phase = .allianceShift1
            remaining = config.teleopBreakdown?.allianceShift ?? 0
            return [.entered(.allianceShift1)]
        case .allianceShift1:
            phase = .allianceShift2
            remaining = config.teleopBreakdown?.allianceShift ?? 0
            return [.entered(.allianceShift2)]
        case .allianceShift2:
            phase = .allianceShift3
            remaining = config.teleopBreakdown?.allianceShift ?? 0
            return [.entered(.allianceShift3)]
        case .allianceShift3:
            phase = .allianceShift4
            remaining = config.teleopBreakdown?.allianceShift ?? 0
            return [.entered(.allianceShift4)]
        case .allianceShift4:
            phase = .endgame
            remaining = config.teleopBreakdown?.endgame ?? 0
            return [.entered(.endgame)]
        case .endgame:
            phase = .finished
            remaining = 0
            return [.disable, .finished]
        case .idle, .finished:
            return []
        }
    }

    /// 当前阶段总时长（进度条用）
    public var phaseDuration: TimeInterval {
        switch phase {
        case .delayBeforeAuto: return config.startDelay
        case .delayBeforeTeleop: return config.delayTime
        case .autonomous: return config.autoTime
        case .teleoperated: return config.teleopTime
        case .transitionShift: return config.teleopBreakdown?.transitionShift ?? 0
        case .allianceShift1, .allianceShift2, .allianceShift3, .allianceShift4:
            return config.teleopBreakdown?.allianceShift ?? 0
        case .endgame: return config.teleopBreakdown?.endgame ?? 0
        default: return 0
        }
    }
}
