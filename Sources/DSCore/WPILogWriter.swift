import Foundation

// MARK: - WPILog（.wpilog）编码器/读取器——WPILib DataLog 格式（2027 版 VarInt 布局）
// 依据：allwpilib datalog 模块 DataLog.cpp/DataLog.hpp（2026-09-16 核查，读参考不复制）：
//   头部："WPILOG"(6B) + {0x00,0x01}(版本 1.0) + extraHeader 长度 u32 LE + extraHeader
//   记录：[headerLen u8]（= ((tsLen-1)<<4)|((payloadLen-1)<<2)|(entryLen-1)）
//         + entry 变长 LE + payloadSize 变长 LE + timestamp 变长 LE（毫秒）+ payload
//   控制记录（entry 字段=0）：payload[0]=0 START（[id u32LE][name][type][metadata]，三段
//         u32 LE 前缀字符串）；payload[0]=1 FINISH（[id u32LE]）；2 = SET_METADATA
//   数据记录：entry≥1；double=8B LE、boolean=1B、string=u32 LE 前缀、int64=8B LE

public enum WPILogFormat {
    public static let magic = "WPILOG"

    /// 定长「变长整数」：小端字节序，字节数由外部控制字节记录（非 LEB128）
    public static func fixedVarInt(_ value: UInt64, length: Int) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        for _ in 0..<max(length, 1) {
            out.append(UInt8(v & 0xFF))
            v >>= 8
        }
        return out
    }

    public static func varintLength(_ value: UInt64) -> Int {
        var v = value
        var len = 1
        while v >= 256 { v >>= 8; len += 1 }
        return len
    }

    public static func recordHeader(entry: UInt32, timestampMs: Int64, payloadSize: Int) -> [UInt8] {
        let entryLen = varintLength(UInt64(entry))
        let payloadLen = varintLength(UInt64(payloadSize))
        let tsLen = varintLength(UInt64(max(0, timestampMs)))
        var out: [UInt8] = [UInt8(((tsLen - 1) << 4) | ((payloadLen - 1) << 2) | (entryLen - 1))]
        out += fixedVarInt(UInt64(entry), length: entryLen)
        out += fixedVarInt(UInt64(payloadSize), length: payloadLen)
        out += fixedVarInt(UInt64(max(0, timestampMs)), length: tsLen)
        return out
    }

    public static func lengthPrefixedString(_ s: String) -> [UInt8] {
        let utf8 = Array(s.utf8.prefix(Int(UInt32.max)))
        var out: [UInt8] = []
        var len = UInt32(utf8.count).littleEndian
        for _ in 0..<4 { out.append(UInt8(len & 0xFF)); len >>= 8 }
        out += utf8
        return out
    }
}

// MARK: 写入器

public final class WPILogWriter {
    private let handle: FileHandle
    private let lock = NSLock()
    private var closed = false
    private var nextEntryID: UInt32 = 1
    private let timestampProvider: () -> Int64

    public init(fileURL: URL, extraHeader: Data = Data(),
                timestampProvider: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
        }
        var header: [UInt8] = Array(WPILogFormat.magic.utf8)
        header += [0x00, 0x01] // 版本 1.0
        var size = UInt32(extraHeader.count).littleEndian
        for _ in 0..<4 { header.append(UInt8(size & 0xFF)); size >>= 8 }
        header += extraHeader
        try? handle.write(contentsOf: Data(header))
        self.handle = handle
        self.timestampProvider = timestampProvider
    }

    private func write(recordEntry: UInt32, payload: [UInt8], timestampMs: Int64? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        let ts = timestampMs ?? timestampProvider()
        var data = Data(WPILogFormat.recordHeader(entry: recordEntry, timestampMs: ts, payloadSize: payload.count))
        data.append(Data(payload))
        try? handle.write(contentsOf: data)
    }

    /// 注册并发出 START 记录，返回 entry id（从 1 起，0 保留给控制记录）
    @discardableResult
    public func startEntry(name: String, type: String, metadata: String = "") -> UInt32 {
        lock.lock()
        let id = nextEntryID
        nextEntryID += 1
        lock.unlock()

        var payload: [UInt8] = [0x00] // CONTROL_START
        var idLE = id.littleEndian
        for _ in 0..<4 { payload.append(UInt8(idLE & 0xFF)); idLE >>= 8 }
        payload += WPILogFormat.lengthPrefixedString(name)
        payload += WPILogFormat.lengthPrefixedString(type)
        payload += WPILogFormat.lengthPrefixedString(metadata)
        write(recordEntry: 0, payload: payload)
        return id
    }

    public func finishEntry(_ id: UInt32) {
        var payload: [UInt8] = [0x01] // CONTROL_FINISH
        var idLE = id.littleEndian
        for _ in 0..<4 { payload.append(UInt8(idLE & 0xFF)); idLE >>= 8 }
        write(recordEntry: 0, payload: payload)
    }

    public func appendDouble(_ id: UInt32, _ value: Double) {
        var bits = value.bitPattern.littleEndian
        var payload: [UInt8] = []
        for _ in 0..<8 { payload.append(UInt8(bits & 0xFF)); bits >>= 8 }
        write(recordEntry: id, payload: payload)
    }

    public func appendBoolean(_ id: UInt32, _ value: Bool) {
        write(recordEntry: id, payload: [value ? 1 : 0])
    }

    public func appendString(_ id: UInt32, _ value: String) {
        write(recordEntry: id, payload: WPILogFormat.lengthPrefixedString(value))
    }

    public func appendInt64(_ id: UInt32, _ value: Int64) {
        var bits = UInt64(bitPattern: value).littleEndian
        var payload: [UInt8] = []
        for _ in 0..<8 { payload.append(UInt8(bits & 0xFF)); bits >>= 8 }
        write(recordEntry: id, payload: payload)
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle.close()
    }

    deinit { close() }
}

// MARK: 读取器（回归验证 + 用户检查）

public struct WPILogRecord: Sendable, Equatable {
    public var timestampMs: Int64
    public var entry: UInt32
    public var payload: Data
}

public struct WPILogEntryInfo: Sendable, Equatable {
    public var id: UInt32
    public var name: String
    public var type: String
    public var metadata: String
}

public enum WPILogDecodeError: Error, Equatable {
    case badMagic
    case truncated
}

public struct WPILogFile {
    public var extraHeader: Data
    public var records: [WPILogRecord]
    public var entries: [WPILogEntryInfo] // START 记录解码结果

    public init(data: Data) throws {
        var r = ByteReader(data)
        guard let magicBytes = r.bytes(6), String(decoding: magicBytes, as: UTF8.self) == WPILogFormat.magic else {
            throw WPILogDecodeError.badMagic
        }
        _ = r.bytes(2) // 版本
        var extraSize: UInt32 = 0
        if let s = r.u32le() { extraSize = s }
        extraHeader = Data(r.bytes(Int(extraSize)) ?? [])

        records = []
        entries = []
        while r.remaining > 0 {
            guard let headerLenByte = r.u8() else { throw WPILogDecodeError.truncated }
            let entryLen = Int(headerLenByte & 0x03) + 1      // bits 0-1
            let payloadLen = Int((headerLenByte >> 2) & 0x03) + 1 // bits 2-3
            let tsLen = Int(headerLenByte >> 4) + 1            // bits 4-7（i64 毫秒需 6B，掩 2 位会截断）
            guard let entryBytes = r.bytes(entryLen), let payloadBytes = r.bytes(payloadLen),
                  let tsBytes = r.bytes(tsLen) else { throw WPILogDecodeError.truncated }
            var e: UInt32 = 0
            for (i, b) in entryBytes.enumerated() { e |= UInt32(b) << (8 * i) }
            var size: UInt32 = 0
            for (i, b) in payloadBytes.enumerated() { size |= UInt32(b) << (8 * i) }
            var ts: Int64 = 0
            for (i, b) in tsBytes.enumerated() { ts |= Int64(b) << (8 * i) }
            guard let payload = r.bytes(Int(size)) else { throw WPILogDecodeError.truncated }

            records.append(WPILogRecord(timestampMs: ts, entry: e, payload: Data(payload)))

            if e == 0, payload.count >= 5 {
                let control = payload[0]
                var pr = ByteReader(Data(payload[1...]))
                if control == 0, let id = pr.u32le(), let name = pr.string32le(),
                   let type = pr.string32le(), let metadata = pr.string32le() {
                    entries.append(WPILogEntryInfo(id: id, name: name, type: type, metadata: metadata))
                }
            }
        }
    }

    public init(fileURL: URL) throws {
        try self.init(data: try Data(contentsOf: fileURL))
    }
}

extension ByteReader {
    mutating func u32le() -> UInt32? {
        guard let a = u8(), let b = u8(), let c = u8(), let d = u8() else { return nil }
        return UInt32(a) | UInt32(b) << 8 | UInt32(c) << 16 | UInt32(d) << 24
    }
    mutating func string32le() -> String? {
        guard let n = u32le(), let raw = bytes(Int(n)) else { return nil }
        return String(decoding: raw, as: UTF8.self)
    }
}
