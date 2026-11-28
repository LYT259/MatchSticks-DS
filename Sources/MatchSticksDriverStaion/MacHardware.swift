import Foundation
import Darwin

struct MacHardwareMath {
    static let historyWindow: TimeInterval = 600

    static func cpuPercentages(previous: [[UInt64]], current: [[UInt64]]) -> [Double] {
        guard !current.isEmpty, previous.count == current.count else { return [] }
        return zip(previous, current).map { old, new in
            guard old.count == new.count, new.count >= 3 else { return 0 }
            let oldTotal = old.reduce(UInt64(0), &+)
            let newTotal = new.reduce(UInt64(0), &+)
            guard newTotal >= oldTotal, new[2] >= old[2] else { return 0 }
            let total = newTotal - oldTotal
            let idle = new[2] - old[2]
            guard total > 0 else { return 0 }
            return min(100, max(0, Double(total - min(total, idle)) / Double(total) * 100))
        }
    }

    static func trimmed<T>(_ values: [T], at now: Date,
                           window: TimeInterval = historyWindow,
                           timestamp: (T) -> Date) -> [T] {
        values.filter {
            let time = timestamp($0)
            return time <= now && time >= now.addingTimeInterval(-window)
        }
    }
}

struct MacGPUStatus: Sendable {
    var model: String
    var coreCount: Int
    var deviceUtilization: Double?
    var rendererUtilization: Double?
    var tilerUtilization: Double?
    var memoryBytes: UInt64?
    var perCoreUtilization: [Double] { [] }

    init?(properties: [String: Any]) {
        guard let statistics = properties["PerformanceStatistics"] as? [String: Any] else { return nil }
        self.model = properties["model"] as? String ?? "GPU"
        self.coreCount = (properties["gpu-core-count"] as? NSNumber)?.intValue ?? 0
        func utilization(_ name: String) -> Double? {
            guard let number = statistics[name] as? NSNumber else { return nil }
            let value = number.doubleValue
            return value.isFinite ? min(100, max(0, value)) : nil
        }
        self.deviceUtilization = utilization("Device Utilization %")
        self.rendererUtilization = utilization("Renderer Utilization %")
        self.tilerUtilization = utilization("Tiler Utilization %")
        self.memoryBytes = (statistics["In use system memory"] as? NSNumber)?.uint64Value
        guard deviceUtilization != nil || rendererUtilization != nil || tilerUtilization != nil else { return nil }
    }
}

struct MacMemoryStatus: Sendable, Equatable {
    var totalBytes: UInt64
    var usedBytes: UInt64
    var availableBytes: UInt64
    var appBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64

    init?(statistics: vm_statistics64, pageSize: UInt64, physicalMemory: UInt64) {
        guard pageSize > 0, physicalMemory > 0 else { return nil }
        let internalPages = UInt64(statistics.internal_page_count) * pageSize
        let purgeable = UInt64(statistics.purgeable_count) * pageSize
        self.appBytes = internalPages - min(internalPages, purgeable)
        self.wiredBytes = UInt64(statistics.wire_count) * pageSize
        self.compressedBytes = UInt64(statistics.compressor_page_count) * pageSize
        self.usedBytes = appBytes + wiredBytes + compressedBytes
        self.availableBytes = (UInt64(statistics.free_count) + UInt64(statistics.inactive_count)) * pageSize
        self.totalBytes = physicalMemory
    }
}

struct MacTemperatureReading: Sendable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var celsius: Double

    init?(name: String, rawValue: Double) {
        guard !name.isEmpty, rawValue.isFinite, (-40...150).contains(rawValue) else { return nil }
        self.name = name
        self.celsius = rawValue
    }
}

extension Array where Element == MacTemperatureReading {
    var socMaximumCelsius: Double? {
        filter { $0.name.hasPrefix("PMU tdie") }.map(\.celsius).max()
    }
    var ssdCelsius: Double? {
        filter { $0.name.hasPrefix("NAND") }.map(\.celsius).max()
    }
    var batteryCelsius: Double? {
        filter { $0.name.hasPrefix("gas gauge battery") }.map(\.celsius).max()
    }
}

struct MacProcessMemory: Sendable, Equatable, Identifiable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    var residentBytes: UInt64
    var isCurrentProcess: Bool

    static func parsePSOutput(_ output: String, currentPID: Int32) -> [MacProcessMemory] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3, let pid = Int32(fields[0]), let kib = UInt64(fields[1]) else { return nil }
            let (bytes, overflow) = kib.multipliedReportingOverflow(by: 1_024)
            guard !overflow else { return nil }
            let path = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            return MacProcessMemory(pid: pid, name: URL(fileURLWithPath: path).lastPathComponent,
                                    residentBytes: bytes, isCurrentProcess: pid == currentPID)
        }.sorted { $0.residentBytes > $1.residentBytes }
    }
}

struct MacCPUHistorySample: Sendable, Identifiable {
    var id: Date { timestamp }
    var timestamp: Date
    var systemPercent: Double
    var loads: [Double]
}

struct MacGPUHistorySample: Sendable, Identifiable {
    var id: Date { timestamp }
    var timestamp: Date
    var deviceUtilization: Double?
    var rendererUtilization: Double?
    var tilerUtilization: Double?
}

struct MacTemperatureHistorySample: Sendable, Identifiable {
    var id: Date { timestamp }
    var timestamp: Date
    var readings: [MacTemperatureReading]
}

struct MacBatteryHistorySample: Sendable, Identifiable {
    var id: Date { timestamp }
    var timestamp: Date
    var percent: Int
    var onAC: Bool
    var charging: Bool?
}

struct CANHistorySample: Sendable, Identifiable {
    var id: Date { timestamp }
    var timestamp: Date
    var utilization: Double
}
