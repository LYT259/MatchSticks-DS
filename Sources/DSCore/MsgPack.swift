import Foundation

// MARK: - MessagePack 最小子集（NT4 二进制帧用）
// 覆盖：nil/bool/uint/int(8/16/32/64)/float64/str/bin/array——足够承载
// NT4 值帧 [id, ts_us, type_id, value] 与其解码；不做扩展类型。

public enum MsgPackError: Error {
    case truncated
    case unsupported(UInt8)
}

public enum MsgPack {

    public static func pack(_ value: Any) -> Data {
        var out: [UInt8] = []
        append(&out, value)
        return Data(out)
    }

    public static func append(_ out: inout [UInt8], _ value: Any) {
        switch value {
        case let v as Bool:
            out.append(v ? 0xC3 : 0xC2)
        case is NSNull:
            out.append(0xC0)
        case let v as UInt64:
            packUint(&out, v)
        case let v as Int64:
            packInt(&out, v)
        case let v as Int:
            packInt(&out, Int64(v))
        case let v as UInt:
            packUint(&out, UInt64(v))
        case let v as UInt32:
            packUint(&out, UInt64(v))
        case let v as Int32:
            packInt(&out, Int64(v))
        case let v as UInt16:
            packUint(&out, UInt64(v))
        case let v as Int16:
            packInt(&out, Int64(v))
        case let v as UInt8:
            packUint(&out, UInt64(v))
        case let v as Int8:
            packInt(&out, Int64(v))
        case let v as Double:
            out.append(0xCB)
            appendBE64(&out, v.bitPattern)
        case let v as Float:
            out.append(0xCA)
            appendBE32(&out, v.bitPattern)
        case let v as String:
            packString(&out, v)
        case let v as Data:
            packBin(&out, [UInt8](v))
        case let v as [Any]:
            if v.count < 16 { out.append(UInt8(0x90 | v.count)) }
            else {
                out.append(0xDC); appendBE16(&out, UInt16(v.count))
            }
            for item in v { append(&out, item) }
        default:
            out.append(0xC0) // 未知类型按 nil 兜底（wire 上不应出现）
        }
    }

    static func packUint(_ out: inout [UInt8], _ v: UInt64) {
        if v <= 0x7F { out.append(UInt8(v)) }
        else if v <= 0xFF { out.append(0xCC); out.append(UInt8(v)) }
        else if v <= 0xFFFF { out.append(0xCD); appendBE16(&out, UInt16(v)) }
        else if v <= 0xFFFFFFFF { out.append(0xCE); appendBE32(&out, UInt32(v)) }
        else { out.append(0xCF); appendBE64(&out, v) }
    }

    static func packInt(_ out: inout [UInt8], _ v: Int64) {
        if v >= 0 { packUint(&out, UInt64(v)) }
        else if v >= -32 { out.append(UInt8(0xE0 | UInt64(v & 0x1F))) }
        else if v >= -128 { out.append(0xD0); out.append(UInt8(UInt64(v) & 0xFF)) }
        else if v >= -32768 { out.append(0xD1); appendBE16(&out, UInt16(UInt64(v) & 0xFFFF)) }
        else if v >= -2_147_483_648 { out.append(0xD2); appendBE32(&out, UInt32(UInt64(v) & 0xFFFFFFFF)) }
        else { out.append(0xD3); appendBE64(&out, UInt64(bitPattern: v)) }
    }

    static func packString(_ out: inout [UInt8], _ v: String) {
        let utf8 = Array(v.utf8)
        if utf8.count < 32 { out.append(UInt8(0xA0 | utf8.count)) }
        else if utf8.count < 256 { out.append(0xD9); out.append(UInt8(utf8.count)) }
        else if utf8.count < 65536 { out.append(0xDA); appendBE16(&out, UInt16(utf8.count)) }
        else { out.append(0xDB); appendBE32(&out, UInt32(utf8.count)) }
        out += utf8
    }

    static func packBin(_ out: inout [UInt8], _ bytes: [UInt8]) {
        if bytes.count < 256 { out.append(0xC4); out.append(UInt8(bytes.count)) }
        else if bytes.count < 65536 { out.append(0xC5); appendBE16(&out, UInt16(bytes.count)) }
        else { out.append(0xC6); appendBE32(&out, UInt32(bytes.count)) }
        out += bytes
    }

    static func appendBE16(_ out: inout [UInt8], _ v: UInt16) {
        out.append(UInt8(v >> 8)); out.append(UInt8(v & 0xFF))
    }
    static func appendBE32(_ out: inout [UInt8], _ v: UInt32) {
        out.append(UInt8(v >> 24)); out.append(UInt8(v >> 16 & 0xFF))
        out.append(UInt8(v >> 8 & 0xFF)); out.append(UInt8(v & 0xFF))
    }
    static func appendBE64(_ out: inout [UInt8], _ v: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8((v >> UInt64(shift)) & 0xFF))
        }
    }

    // MARK: 解码（流式：返回已消费的值数组 + 剩余偏移）

    public static func unpackAll(_ data: Data) throws -> [Any] {
        var values: [Any] = []
        var offset = 0
        while offset < data.count {
            let (value, consumed) = try unpackOne(data, offset)
            values.append(value)
            offset += consumed
        }
        return values
    }

    public static func unpackFirst(_ data: Data) throws -> Any {
        let (value, _) = try unpackOne(data, 0)
        return value
    }

    static func unpackOne(_ data: Data, _ offset: Int) throws -> (Any, Int) {
        let bytes: [UInt8] = [UInt8](data)
        guard offset < bytes.count else { throw MsgPackError.truncated }
        let b = bytes[offset]
        switch b {
        case 0xC0: return (NSNull(), 1)
        case 0xC2: return (false, 1)
        case 0xC3: return (true, 1)
        case 0xCB:
            guard offset + 9 <= bytes.count else { throw MsgPackError.truncated }
            var bits: UInt64 = 0
            for i in 0..<8 { bits = bits << 8 | UInt64(bytes[offset + 1 + i]) }
            return (Double(bitPattern: bits), 9)
        case 0xCA:
            guard offset + 5 <= bytes.count else { throw MsgPackError.truncated }
            var bits: UInt32 = 0
            for i in 0..<4 { bits = bits << 8 | UInt32(bytes[offset + 1 + i]) }
            return (Double(Float(bitPattern: bits)), 5)
        case 0xCC: return try uintAt(bytes, offset, 1, 1)
        case 0xCD: return try uintAt(bytes, offset, 2, 1)
        case 0xCE: return try uintAt(bytes, offset, 4, 1)
        case 0xCF: return try uintAt(bytes, offset, 8, 1)
        case 0xD0:
            guard offset + 2 <= bytes.count else { throw MsgPackError.truncated }
            return (Int64(Int8(bitPattern: bytes[offset + 1])), 2)
        case 0xD1:
            guard offset + 3 <= bytes.count else { throw MsgPackError.truncated }
            var v: Int16 = 0
            for i in 0..<2 { v = v << 8 | Int16(bytes[offset + 1 + i]) }
            return (Int64(v), 3)
        case 0xD2:
            guard offset + 5 <= bytes.count else { throw MsgPackError.truncated }
            var v: Int32 = 0
            for i in 0..<4 { v = v << 8 | Int32(bytes[offset + 1 + i]) }
            return (Int64(v), 5)
        case 0xD3:
            guard offset + 9 <= bytes.count else { throw MsgPackError.truncated }
            var v: UInt64 = 0
            for i in 0..<8 { v = v << 8 | UInt64(bytes[offset + 1 + i]) }
            return (Int64(bitPattern: v), 9)
        case 0xD9: return try strAt(bytes, offset, 1, 2)
        case 0xDA: return try strAt(bytes, offset, 2, 3)
        case 0xDB: return try strAt(bytes, offset, 4, 5)
        case 0xC4: return try binAt(bytes, offset, 1, 2)
        case 0xC5: return try binAt(bytes, offset, 2, 3)
        case 0xC6: return try binAt(bytes, offset, 4, 5)
        case 0x90...0x9F:
            return try arrayAt(bytes, offset, Int(b & 0x0F), 1)
        case 0xDC:
            guard offset + 3 <= bytes.count else { throw MsgPackError.truncated }
            let count = Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
            return try arrayAt(bytes, offset, count, 3)
        case 0xA0...0xBF:
            // fixstr：长度在控制字节低 5 位，后跟 utf8 字节
            let length = Int(b & 0x1F)
            guard offset + 1 + length <= bytes.count else { throw MsgPackError.truncated }
            return (String(decoding: bytes[offset + 1 ..< offset + 1 + length], as: UTF8.self),
                    1 + length)
        case 0x00...0x7F: return (Int64(b), 1)
        case 0xE0...0xFF: return (Int64(Int8(bitPattern: b)), 1)
        default: throw MsgPackError.unsupported(b)
        }
    }

    static func uintAt(_ bytes: [UInt8], _ offset: Int, _ len: Int, _ header: Int) throws -> (Any, Int) {
        guard offset + header + len <= bytes.count else { throw MsgPackError.truncated }
        var v: UInt64 = 0
        for i in 0..<len { v = v << 8 | UInt64(bytes[offset + header + i]) }
        return (Int64(bitPattern: v), header + len)
    }
    static func strAt(_ bytes: [UInt8], _ offset: Int, _ lenLen: Int, _ header: Int) throws -> (Any, Int) {
        var length = 0
        for i in 0..<lenLen { length = length << 8 | Int(bytes[offset + 1 + i]) }
        guard offset + header + length <= bytes.count else { throw MsgPackError.truncated }
        return (String(decoding: bytes[offset + header ..< offset + header + length], as: UTF8.self),
                header + length)
    }
    static func binAt(_ bytes: [UInt8], _ offset: Int, _ lenLen: Int, _ header: Int) throws -> (Any, Int) {
        var length = 0
        for i in 0..<lenLen { length = length << 8 | Int(bytes[offset + 1 + i]) }
        guard offset + header + length <= bytes.count else { throw MsgPackError.truncated }
        return (Data(bytes[offset + header ..< offset + header + length]), header + length)
    }
    static func arrayAt(_ bytes: [UInt8], _ offset: Int, _ count: Int, _ header: Int) throws -> (Any, Int) {
        var consumed = header
        var items: [Any] = []
        for _ in 0..<count {
            let (v, c) = try Self.unpackOne(Data(bytes), offset + consumed)
            items.append(v)
            consumed += c
        }
        return (items, consumed)
    }
}
