import Foundation

// MARK: - SHA-1（FIPS 180-1 / RFC 3174），纯 Swift
//
// CryptoKit 只在 Apple 平台可用；NT4 WebSocket 握手的 Sec-WebSocket-Accept 需要同一实现
// 在 macOS / Linux / Windows 上一致，故不依赖系统库。仅用于握手摘要（非安全用途）。

enum SHA1 {
    static func digest(_ message: Data) -> Data {
        var h0: UInt32 = 0x6745_2301
        var h1: UInt32 = 0xEFCD_AB89
        var h2: UInt32 = 0x98BA_DCFE
        var h3: UInt32 = 0x1032_5476
        var h4: UInt32 = 0xC3D2_E1F0

        let messageBits = UInt64(message.count) * 8
        var padded = message
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8((messageBits >> UInt64(shift)) & 0xFF))
        }

        var w = [UInt32](repeating: 0, count: 80)
        padded.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for chunk in stride(from: 0, to: raw.count, by: 64) {
                for i in 0..<16 {
                    let o = chunk + i * 4
                    w[i] = UInt32(raw[o]) << 24 | UInt32(raw[o + 1]) << 16
                        | UInt32(raw[o + 2]) << 8 | UInt32(raw[o + 3])
                }
                for i in 16..<80 {
                    let v = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                    w[i] = v << 1 | v >> 31
                }
                var a = h0, b = h1, c = h2, d = h3, e = h4
                for i in 0..<80 {
                    let f: UInt32
                    let k: UInt32
                    switch i {
                    case 0..<20: f = (b & c) | (~b & d); k = 0x5A82_7999
                    case 20..<40: f = b ^ c ^ d; k = 0x6ED9_EBA1
                    case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1B_BCDC
                    default: f = b ^ c ^ d; k = 0xCA62_C1D6
                    }
                    let temp = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                    e = d
                    d = c
                    c = rotl(b, 30)
                    b = a
                    a = temp
                }
                h0 = h0 &+ a
                h1 = h1 &+ b
                h2 = h2 &+ c
                h3 = h3 &+ d
                h4 = h4 &+ e
            }
        }

        var out = Data(capacity: 20)
        for word in [h0, h1, h2, h3, h4] {
            out.append(UInt8(word >> 24))
            out.append(UInt8(word >> 16 & 0xFF))
            out.append(UInt8(word >> 8 & 0xFF))
            out.append(UInt8(word & 0xFF))
        }
        return out
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        x << n | x >> (32 - n)
    }
}
