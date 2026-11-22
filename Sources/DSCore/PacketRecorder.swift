import Foundation

// MARK: - 抓包录制 / 回放（报告 §6 决策 3「录制即测试」、§9 Phase 0 关键路径）
//
// .dsrec 格式（自描述、追加写）：
//   Header: "GHDSREC1" (8 字节)
//   注意：魔数属格式契约，品牌改名后保持 "GHDSREC1"——旧录制文件仍可回放。
//   记录:   [t 相对秒 f32 BE][direction u8][len u32 BE][payload]
// 用途：
//   - DS 侧录制真实 roboRIO 收发包 → 离线回归（无硬件时的协议回归基准）
//   - 模拟器 --replay 模式按录制应答回放 → DS 端解析行为与真机逐字节一致

public enum RecordedDirection: UInt8, Sendable, CaseIterable {
    case controlOut = 0   // DS → robot 控制包（UDP 1110）
    case responseIn = 1   // robot → DS 应答包（UDP 1150）
    case tcpOut = 2       // DS → robot TCP 帧
    case tcpIn = 3        // robot → DS TCP 帧
}

public final class PacketRecorder {
    public static let magic = "GHDSREC1"
    private let handle: FileHandle
    private let start = Date()
    private var closed = false
    private let lock = NSLock()

    public init(fileURL: URL) throws {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
        }
        try? handle.write(contentsOf: Data(PacketRecorder.magic.utf8))
        self.handle = handle
    }

    public func record(_ direction: RecordedDirection, _ payload: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        var w = ByteWriter()
        w.f32be(Float(-start.timeIntervalSinceNow))
        w.u8(direction.rawValue)
        w.u32be(UInt32(payload.count))
        handle.write(Data(w.data))
        handle.write(payload)
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle.close()
    }

    deinit { close() }
}

// MARK: 回放源

public struct ReplayRecord: Sendable, Equatable {
    public var time: Double
    public var direction: RecordedDirection
    public var payload: Data
}

public enum ReplayError: Error, Equatable {
    case badMagic
    case truncated
}

public struct ReplaySource {
    public private(set) var records: [ReplayRecord]

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, String(decoding: bytes[0..<8], as: UTF8.self) == PacketRecorder.magic else {
            throw ReplayError.badMagic
        }
        var r = ByteReader(Data(bytes[8...]))
        var out: [ReplayRecord] = []
        while r.remaining > 0 {
            guard let t = r.f32be(), let dirRaw = r.u8(), let len = r.u32be(),
                  let dir = RecordedDirection(rawValue: dirRaw),
                  let payload = r.bytes(Int(len)) else { throw ReplayError.truncated }
            out.append(ReplayRecord(time: Double(t), direction: dir, payload: Data(payload)))
        }
        records = out
    }

    public init(fileURL: URL) throws {
        try self.init(data: try Data(contentsOf: fileURL))
    }

    /// 按「一组应答对应一个控制包」分组：从游标处取 responseIn，直到遇到 controlOut 边界。
    /// 返回 (本批应答, 是否推进了游标)；末尾循环回放由调用方 rewind 控制。
    public func responseBatch(from index: Int) -> (batch: [Data], next: Int) {
        var batch: [Data] = []
        var i = index
        // 跳过开头可能存在的 controlOut 记录（上一组自己的边界）
        while i < records.count, records[i].direction == .controlOut { i += 1 }
        while i < records.count, records[i].direction == .responseIn {
            batch.append(records[i].payload)
            i += 1
        }
        // 推进到下一个 controlOut（其后的 responseIn 属下一组）
        while i < records.count, records[i].direction != .controlOut { i += 1 }
        return (batch, i)
    }

    public var tcpOutFrames: [Data] {
        records.filter { $0.direction == .tcpOut }.map(\.payload)
    }
}
