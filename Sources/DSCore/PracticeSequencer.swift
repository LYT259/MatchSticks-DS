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
        if s.estopEngaged { return .deny(reason: "E-Stop 已触发，先复位（Esc+I 或重启代码）") }
        if !s.commConnected { return .deny(reason: "无机器人连接") }
        if !s.watchdogHealthy { return .deny(reason: "控制环心跳异常") }
        return .allow
    }

    public static func canEnable(_ s: State) -> Bool {
        if case .allow = evaluateEnable(s) { return true }
        return false
    }
}

// MARK: - PracticeSequencer：Practice 时序纯状态机（报告 §2.1 NI DS Practice 语义）
// 阶段：延迟 → Auto → 延迟 → TeleOp → 结束；A-Stop 任意时刻中止。

public struct PracticeSequencer: Sendable, Equatable {
    public enum Phase: Sendable, Equatable, CaseIterable {
        case idle
        case delayBeforeAuto
        case autonomous
        case delayBeforeTeleop
        case teleoperated
        case finished

        public var isActive: Bool { self != .idle && self != .finished }

        public var displayName: String {
            switch self {
            case .idle: return "待机"
            case .delayBeforeAuto: return "Auto 前延迟"
            case .autonomous: return "Autonomous"
            case .delayBeforeTeleop: return "Teleop 前延迟"
            case .teleoperated: return "Teleoperated"
            case .finished: return "已结束"
            }
        }
    }

    public struct Config: Sendable, Equatable {
        public var autoTime: TimeInterval
        public var teleopTime: TimeInterval
        public var delayTime: TimeInterval

        public init(autoTime: TimeInterval = 15, teleopTime: TimeInterval = 135, delayTime: TimeInterval = 2) {
            self.autoTime = autoTime
            self.teleopTime = teleopTime
            self.delayTime = delayTime
        }
    }

    public enum Event: Sendable, Equatable {
        case entered(Phase)   // 阶段切换（调用方负责对应模式切换）
        case enable           // 使能输出意图
        case disable          // 失能输出意图
        case finished         // 全程结束
        case aborted          // A-Stop
    }

    public private(set) var phase: Phase = .idle
    public private(set) var remaining: TimeInterval = 0
    public private(set) var config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func start() -> [Event] {
        phase = .delayBeforeAuto
        remaining = config.delayTime
        return [.entered(.delayBeforeAuto)]
    }

    /// A-Stop：立即失能并结束
    public mutating func abort() -> [Event] {
        guard phase.isActive else { return [] }
        phase = .finished
        remaining = 0
        return [.disable, .aborted, .finished]
    }

    /// 周期推进（建议 0.1s）；返回本 tick 累积的控制意图。
    /// 5ms 容差：抵消浮点累加误差与定时器抖动，避免阶段切换晚一拍。
    public mutating func tick(_ dt: TimeInterval) -> [Event] {
        guard phase.isActive else { return [] }
        remaining -= dt
        if remaining > 0.005 { return [] }

        switch phase {
        case .delayBeforeAuto:
            phase = .autonomous
            remaining = config.autoTime
            return [.entered(.autonomous), .enable]
        case .autonomous:
            phase = .delayBeforeTeleop
            remaining = config.delayTime
            return [.entered(.delayBeforeTeleop), .disable]
        case .delayBeforeTeleop:
            phase = .teleoperated
            remaining = config.teleopTime
            return [.entered(.teleoperated), .enable]
        case .teleoperated:
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
        case .delayBeforeAuto, .delayBeforeTeleop: return config.delayTime
        case .autonomous: return config.autoTime
        case .teleoperated: return config.teleopTime
        default: return 0
        }
    }
}
