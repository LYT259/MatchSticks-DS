import Foundation

struct F310XInputReport: Equatable, Sendable {
    var axes: [Float]
    var buttons: UInt64
    var pov: Int16
    var triggerDepthL: Float
    var triggerDepthR: Float

    static let neutral = F310XInputReport(
        axes: [0, 0, -1, -1, 0, 0], buttons: 0, pov: -1,
        triggerDepthL: 0, triggerDepthR: 0)

    static func parse(_ bytes: [UInt8]) -> F310XInputReport? {
        guard bytes.count == 20, bytes[0] == 0, bytes[1] == 0x14 else { return nil }
        let control = bytes[2]
        let face = bytes[3]
        guard let pov = povAngle(control & 0x0F) else { return nil }

        var buttons: UInt64 = 0
        let mappings: [(value: UInt8, mask: UInt8, button: UInt64)] = [
            (face, 0x10, 1), (face, 0x20, 2), (face, 0x40, 3), (face, 0x80, 4),
            (face, 0x01, 5), (face, 0x02, 6),
            (control, 0x20, 7), (control, 0x10, 8),
            (control, 0x40, 9), (control, 0x80, 10), (face, 0x04, 11),
        ]
        for mapping in mappings where mapping.value & mapping.mask != 0 {
            buttons |= 1 << (mapping.button - 1)
        }

        let depthL = Float(bytes[4]) / 255
        let depthR = Float(bytes[5]) / 255
        let leftX = normalized(int16(bytes, at: 6))
        let leftY = normalized(int16(bytes, at: 8))
        let rightX = normalized(int16(bytes, at: 10))
        let rightY = normalized(int16(bytes, at: 12))
        return F310XInputReport(
            axes: [leftX, -leftY, depthL * 2 - 1, depthR * 2 - 1, rightX, -rightY],
            buttons: buttons, pov: pov,
            triggerDepthL: depthL, triggerDepthR: depthR)
    }

    private static func int16(_ bytes: [UInt8], at index: Int) -> Int16 {
        Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
    }

    private static func normalized(_ raw: Int16) -> Float {
        raw >= 0 ? Float(raw) / 32767 : Float(raw) / 32768
    }

    private static func povAngle(_ raw: UInt8) -> Int16? {
        switch raw {
        case 0: return -1
        case 1: return 0
        case 5: return 315
        case 4: return 270
        case 6: return 225
        case 2: return 180
        case 10: return 135
        case 8: return 90
        case 9: return 45
        default: return nil
        }
    }
}
