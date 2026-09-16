import Foundation

// MARK: - CRC32C（Castagnoli，iSCSI/SSE4.2 多项式）
// 依据：MRC V2 协议（FirstDriverStation 0x37e010 处 SSE4.2 CRC32 指令 + 反射表溯源）
// 多项式（反射）：0x82F63B78；初值 0xFFFFFFFF；终值异或 0xFFFFFFFF
// 测试向量：CRC32C("123456789") == 0xE3069283

public enum CRC32C {
    private static let table: [UInt32] = {
        let poly: UInt32 = 0x82F63B78
        return (0..<256).map { i -> UInt32 in
            var crc = UInt32(i)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ poly : crc >> 1
            }
            return crc
        }
    }()

    public static func checksum(_ data: Data) -> UInt32 {
        checksum([UInt8](data))
    }

    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
