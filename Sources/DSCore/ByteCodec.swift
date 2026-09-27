import Foundation

// MARK: - 大端字节读写（协议层唯一入口；外部输入不可信：全部带边界检查，坏包返回 nil 而非崩溃）

public struct ByteWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func i8(_ v: Int8) { data.append(UInt8(bitPattern: v)) }

    public mutating func u16be(_ v: UInt16) {
        data.append(UInt8(v >> 8 & 0xFF)); data.append(UInt8(v & 0xFF))
    }
    public mutating func i16be(_ v: Int16) { u16be(UInt16(bitPattern: v)) }
    public mutating func u32be(_ v: UInt32) {
        data.append(UInt8(v >> 24 & 0xFF)); data.append(UInt8(v >> 16 & 0xFF))
        data.append(UInt8(v >> 8 & 0xFF)); data.append(UInt8(v & 0xFF))
    }
    public mutating func f32be(_ v: Float) { u32be(v.bitPattern) }

    public mutating func bytes<D: Sequence>(_ seq: D) where D.Element == UInt8 {
        for b in seq { data.append(b) }
    }

    /// u8 长度前缀字符串（TCP tag 内字符串约定）
    public mutating func string8(_ s: String) {
        let utf8 = Array(s.utf8.prefix(255))
        u8(UInt8(utf8.count)); bytes(utf8)
    }

    /// u16 长度前缀字符串（TCP 0x0B 错误消息字段约定）
    public mutating func string16(_ s: String) {
        let utf8 = Array(s.utf8.prefix(Int(UInt16.max)))
        u16be(UInt16(utf8.count)); bytes(utf8)
    }
}

public struct ByteReader {
    public let data: [UInt8]
    public private(set) var offset = 0

    public init(_ data: Data) { self.data = [UInt8](data) }
    public init(_ bytes: [UInt8]) { self.data = bytes }

    public var remaining: Int { data.count - offset }
    public var isExhausted: Bool { remaining <= 0 }

    /// 回退到已解析位置（TCP 帧不完整时整帧回退）
    public mutating func rewind(to position: Int) {
        offset = max(0, min(position, data.count))
    }

    public mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return data[offset]
    }
    public mutating func i8() -> Int8? { u8().map(Int8.init(bitPattern:)) }
    public mutating func u16be() -> UInt16? {
        guard let hi = u8(), let lo = u8() else { return nil }
        return UInt16(hi) << 8 | UInt16(lo)
    }
    public mutating func i16be() -> Int16? { u16be().map(Int16.init(bitPattern:)) }
    public mutating func u32be() -> UInt32? {
        guard let a = u16be(), let b = u16be() else { return nil }
        return UInt32(a) << 16 | UInt32(b)
    }
    public mutating func f32be() -> Float? {
        u32be().map { Float(bitPattern: $0) }
    }
    public mutating func bytes(_ n: Int) -> [UInt8]? {
        guard n >= 0, remaining >= n else { return nil }
        defer { offset += n }
        return Array(data[offset ..< offset + n])
    }
    public mutating func string8() -> String? {
        guard let n = u8(), let raw = bytes(Int(n)) else { return nil }
        return String(decoding: raw, as: UTF8.self)
    }
    public mutating func string16() -> String? {
        guard let n = u16be(), let raw = bytes(Int(n)) else { return nil }
        return String(decoding: raw, as: UTF8.self)
    }
}
