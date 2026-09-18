import Foundation

// MARK: - .dslog 编码器/读取器（NI DS 日志格式，报告 §5.3「双格式兼容既有分析工具」）
// 依据：frcnetworking.readthedocs.io logging 页（2026-09-16 核查）；大端；头 20B + 条目 34B。
// Trace 位表与 UDP 应答包不同（dslog 专用）：brownout/watchdog/DS-teleop/-/DS-disabled/
// robot-teleop/robot-auton/robot-disabled。
// PDP：16 端口 × 10bit「mostly packed」（0-5→8B、6-11→8B、12-15→5B），值 = 电流 × 8。

public struct DSLogEntry: Sendable, Equatable {
    public var tripTimeMs: Double?      // x/15 ms
    public var packetLossPercent: Double
    public var batteryVolts: Float
    public var cpuPercent: Float?       // roboRIO CPU，x/2 %
    public var brownout: Bool
    public var watchdog: Bool
    public var dsTeleop: Bool           // DS 请求模式 = Teleop
    public var dsDisabled: Bool         // DS 侧失能意图
    public var robotTeleop: Bool
    public var robotAuton: Bool
    public var robotDisabled: Bool
    public var canPercent: Float?       // x/2 %
    public var wifiDB: Int?             // x/2 dB
    public var wifiMb: Int?
    public var pdpCurrents: [Double]?   // 16 端口电流（A）

    public init(tripTimeMs: Double? = nil, packetLossPercent: Double = 0, batteryVolts: Float = 0,
                cpuPercent: Float? = nil, brownout: Bool = false, watchdog: Bool = false,
                dsTeleop: Bool = false, dsDisabled: Bool = true,
                robotTeleop: Bool = false, robotAuton: Bool = false, robotDisabled: Bool = true,
                canPercent: Float? = nil, wifiDB: Int? = nil, wifiMb: Int? = nil,
                pdpCurrents: [Double]? = nil) {
        self.tripTimeMs = tripTimeMs
        self.packetLossPercent = packetLossPercent
        self.batteryVolts = batteryVolts
        self.cpuPercent = cpuPercent
        self.brownout = brownout
        self.watchdog = watchdog
        self.dsTeleop = dsTeleop
        self.dsDisabled = dsDisabled
        self.robotTeleop = robotTeleop
        self.robotAuton = robotAuton
        self.robotDisabled = robotDisabled
        self.canPercent = canPercent
        self.wifiDB = wifiDB
        self.wifiMb = wifiMb
        self.pdpCurrents = pdpCurrents
    }
}

public enum DSLogFormat {
    public static let headerSize = 20
    public static let entrySize = 34
    /// Mac 纪元（2001-01-01）与 1904-01-01 的秒差
    public static let mac1904Offset: TimeInterval = 3_061_152_000

    public static func traceByte(_ e: DSLogEntry) -> UInt8 {
        (e.brownout ? 0x80 : 0) | (e.watchdog ? 0x40 : 0) | (e.dsTeleop ? 0x20 : 0)
            | (e.dsDisabled ? 0x08 : 0) | (e.robotTeleop ? 0x04 : 0)
            | (e.robotAuton ? 0x02 : 0) | (e.robotDisabled ? 0x01 : 0)
    }

    public static func encodeEntry(_ e: DSLogEntry) -> Data {
        var w = ByteWriter()
        w.u8(UInt8(clamping: Int(((e.tripTimeMs ?? 0) * 15).rounded())))          // trip time：x/15 ms
        w.u8(UInt8(clamping: Int((e.packetLossPercent / 4).rounded())))            // loss：x*4 %
        w.u16be(batteryRaw(e.batteryVolts))
        w.u8(UInt8(clamping: Int(((e.cpuPercent ?? 0) * 2).rounded())))            // cpu：x/2 %
        w.u8(traceByte(e))
        w.u8(UInt8(clamping: Int(((e.canPercent ?? 0) * 2).rounded())))            // can：x/2 %
        w.u8(UInt8(clamping: ((e.wifiDB ?? 0) * 2)))                               // wifi dB：x/2
        w.u8(UInt8(clamping: e.wifiMb ?? 0))
        w.u16be(0)                                                                 // unknown
        w.bytes(pdpPacked(e.pdpCurrents))                                          // 21B
        w.u8(0); w.u8(0)                                                           // unknown（尾 2B，条目合计 34）
        return w.data
    }

    public static func batteryRaw(_ volts: Float) -> UInt16 {
        let int = UInt8(clamping: Int(volts))
        let frac = UInt8(clamping: Int((volts - Float(int)) * 256))
        return UInt16(int) << 8 | UInt16(frac)
    }

    /// 16 端口电流 → 21B：0-5（60bit+4pad→8B）、6-11（60bit+4pad→8B）、12-15（40bit→5B），MSB-first
    public static func pdpPacked(_ currents: [Double]?) -> [UInt8] {
        let values = (currents ?? Array(repeating: 0, count: 16)).prefix(16).map {
            UInt16(clamping: Int(($0 * 8).rounded()))
        }
        var out: [UInt8] = []
        var stream: [UInt8] = []
        func push(_ v: UInt16, bits count: Int) {
            for shift in stride(from: count - 1, through: 0, by: -1) {
                stream.append(UInt8((v >> UInt16(shift)) & 1))
            }
        }
        for group in [0..<6, 6..<12, 12..<16] {
            stream.removeAll(keepingCapacity: true)
            for i in group { push(values[i], bits: 10) }
            while stream.count % 8 != 0 { stream.append(0) } // 组尾补齐（4/4/0 bit pad）
            for byteIndex in stride(from: 0, to: stream.count, by: 8) {
                var byte: UInt8 = 0
                for bit in 0..<8 where stream[byteIndex + bit] == 1 { byte |= UInt8(1 << (7 - bit)) }
                out.append(byte)
            }
        }
        return Array(out.prefix(21))
    }

    public static func encodeHeader(version: UInt32, timestamp: Date) -> Data {
        var w = ByteWriter()
        w.u32be(version)
        w.u32be(0)                                                                  // unknown
        w.u32be(UInt32(clamping: Int(timestamp.timeIntervalSinceReferenceDate + mac1904Offset)))
        w.u8(UInt8(clamping: Int((timestamp.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)) * 256)))
        w.u8(0); w.u8(0); w.u8(0); w.u8(0); w.u8(0); w.u8(0); w.u8(0)              // unknown
        return w.data
    }
}

// MARK: 写入器

public final class DSLogWriter {
    private let handle: FileHandle
    private var closed = false
    private let lock = NSLock()

    public init(fileURL: URL, version: UInt32 = 2, timestamp: Date = Date()) throws {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
        }
        try? handle.write(contentsOf: DSLogFormat.encodeHeader(version: version, timestamp: timestamp))
        self.handle = handle
    }

    public func append(_ entry: DSLogEntry) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        handle.write(DSLogFormat.encodeEntry(entry))
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle.close()
    }

    deinit { close() }
}

// MARK: 读取器（回归验证与用户检查用）

public struct DSLogFile {
    public var version: UInt32
    public var timestamp: Date
    public var entries: [DSLogEntry]

    public init(data: Data) throws {
        guard data.count >= DSLogFormat.headerSize else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var r = ByteReader(data)
        version = r.u32be() ?? 0
        _ = r.u32be()
        let secs = TimeInterval(r.u32be() ?? 0)
        let frac = Double(r.u8() ?? 0) / 256
        _ = r.bytes(7) // 头部尾 7B unknown（与 encodeHeader 对齐）
        timestamp = Date(timeIntervalSinceReferenceDate: secs - DSLogFormat.mac1904Offset + frac)

        var out: [DSLogEntry] = []
        while r.remaining >= DSLogFormat.entrySize {
            var e = DSLogEntry()
            e.tripTimeMs = Double(r.u8() ?? 0) / 15
            e.packetLossPercent = Double(r.u8() ?? 0) * 4
            let battery = r.u16be() ?? 0
            e.batteryVolts = Float(battery >> 8) + Float(battery & 0xFF) / 256
            e.cpuPercent = Float(r.u8() ?? 0) / 2
            let trace = r.u8() ?? 0
            e.brownout = trace & 0x80 != 0
            e.watchdog = trace & 0x40 != 0
            e.dsTeleop = trace & 0x20 != 0
            e.dsDisabled = trace & 0x08 != 0
            e.robotTeleop = trace & 0x04 != 0
            e.robotAuton = trace & 0x02 != 0
            e.robotDisabled = trace & 0x01 != 0
            e.canPercent = Float(r.u8() ?? 0) / 2
            e.wifiDB = Int(r.u8() ?? 0) / 2
            e.wifiMb = Int(r.u8() ?? 0)
            _ = r.u16be()
            e.pdpCurrents = Self.decodePDP(r.bytes(21) ?? [])
            _ = r.u8(); _ = r.u8()
            out.append(e)
        }
        entries = out
    }

    public init(fileURL: URL) throws {
        try self.init(data: try Data(contentsOf: fileURL))
    }

    /// 逆打包：10bit 值 ÷8 = 电流
    public static func decodePDP(_ bytes: [UInt8]) -> [Double] {
        guard bytes.count == 21 else { return Array(repeating: 0, count: 16) }
        var currents = Array(repeating: 0.0, count: 16)
        func read10(_ group: [UInt8], _ index: Int) -> UInt16 {
            let base = index * 10
            var v: UInt16 = 0
            for bit in 0..<10 {
                let position = base + bit
                let byteIndex = position / 8
                let bitIndex = 7 - (position % 8)
                if byteIndex < group.count, group[byteIndex] & (1 << bitIndex) != 0 {
                    v |= UInt16(1 << (9 - bit))
                }
            }
            return v
        }
        for i in 0..<6 { currents[i] = Double(read10(Array(bytes[0..<8]), i)) / 8 }
        for i in 0..<6 { currents[6 + i] = Double(read10(Array(bytes[8..<16]), i)) / 8 }
        for i in 0..<4 { currents[12 + i] = Double(read10(Array(bytes[16..<21]), i)) / 8 }
        return currents
    }
}
