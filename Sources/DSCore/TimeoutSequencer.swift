import Foundation

public struct TimeoutSequencer: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case running
        case finished
    }

    public enum Event: Sendable, Equatable {
        case started
        case warning
        case finished
    }

    public let duration: TimeInterval
    public let warningTime: TimeInterval
    public private(set) var phase: Phase = .idle
    public private(set) var remaining: TimeInterval = 0
    private var warningIssued = false

    public init(duration: TimeInterval = 480, warningTime: TimeInterval = 60) {
        self.duration = duration
        self.warningTime = warningTime
    }

    public mutating func start() -> [Event] {
        guard phase != .running else { return [] }
        warningIssued = false
        guard duration > 0 else {
            phase = .finished
            remaining = 0
            return [.finished]
        }
        phase = .running
        remaining = duration
        var events: [Event] = [.started]
        if duration <= warningTime {
            warningIssued = true
            events.append(.warning)
        }
        return events
    }

    public mutating func tick(_ dt: TimeInterval) -> [Event] {
        guard phase == .running else { return [] }
        let previous = remaining
        remaining = max(0, remaining - dt)
        var events: [Event] = []
        if !warningIssued && previous > warningTime + 0.005 && remaining <= warningTime + 0.005 {
            warningIssued = true
            events.append(.warning)
        }
        if remaining <= 0.005 {
            phase = .finished
            remaining = 0
            events.append(.finished)
        }
        return events
    }

    public mutating func cancel() {
        phase = .idle
        remaining = 0
        warningIssued = false
    }
}
