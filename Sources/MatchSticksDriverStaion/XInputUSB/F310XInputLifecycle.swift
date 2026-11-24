import Foundation

final class F310XInputSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (report: F310XInputReport, receivedAt: TimeInterval)?

    func update(_ report: F310XInputReport, at receivedAt: TimeInterval) {
        lock.lock()
        value = (report, receivedAt)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        value = nil
        lock.unlock()
    }

    func snapshot(at now: TimeInterval) -> F310XInputReport {
        lock.lock()
        defer { lock.unlock() }
        guard let value, now - value.receivedAt <= 0.1 else { return .neutral }
        return value.report
    }
}

struct F310XInputLifecycle {
    struct Changes: Equatable {
        var start: [UInt32]
        var stop: [UInt32]
    }

    private var tracked: Set<UInt32> = []

    mutating func synchronize(present: Set<UInt32>) -> Changes {
        let changes = Changes(
            start: present.subtracting(tracked).sorted(),
            stop: tracked.subtracting(present).sorted())
        tracked = present
        return changes
    }

    mutating func startFailed(_ locationID: UInt32) {
        tracked.remove(locationID)
    }
}
