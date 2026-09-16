import Foundation

// MARK: - ProtobufLite：MRC 控制平面所需的极简 protobuf wire 编码
// 只实现用到的三种 wire type：varint(0)/fixed64(1)/length-delimited(2)。
// 消息布局来自 MrcComm.proto（2026-09-16 核查）：
//   ProtobufControlData: ControlWord=5 varint, MatchTime=2 int32,
//     Joysticks=3 repeated JoystickData, CurrentOpMode=4 fixed64, GameData=6 string
//   ProtobufJoystickData: AvailableButtons=1 uint64, Buttons=2 uint64,
//     AvailableAxes=3 uint32, Axes=4 repeated sint32(zigzag), POVCount=5,
//     POVs=6 uint32(4×int16 打包)

public enum ProtobufLite {

    static func key(_ field: UInt32, _ wireType: UInt32) -> [UInt8] {
        packVarint((UInt64(field) << 3) | UInt64(wireType))
    }

    public static func packVarint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    static func varintField(_ field: UInt32, _ value: UInt64) -> [UInt8] {
        key(field, 0) + packVarint(value)
    }

    static func fixed64Field(_ field: UInt32, _ value: UInt64) -> [UInt8] {
        key(field, 1) + Self.packFixed64(value)
    }

    static func packFixed64(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        for _ in 0..<8 { out.append(UInt8(v & 0xFF)); v >>= 8 }
        return out
    }

    static func lengthDelimitedField(_ field: UInt32, _ bytes: [UInt8]) -> [UInt8] {
        key(field, 2) + packVarint(UInt64(bytes.count)) + bytes
    }

    static func stringField(_ field: UInt32, _ value: String) -> [UInt8] {
        lengthDelimitedField(field, Array(value.utf8))
    }

    /// sint32 zigzag
    static func zigzag32(_ value: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: (value << 1) ^ (value >> 31)))
    }

    // MARK: ProtobufControlData（/Dscomm/Control/ControlData 的 payload）

    public struct JoystickWire {
        public var buttons: UInt64        // 已按下的按钮位
        public var buttonCount: Int       // AvailableButtons
        public var axes: [Float]          // 内部编码为 zigzag int32（×127 量化）
        public var povsPacked: UInt32     // 4×int16 打包

        public init(buttons: UInt64, buttonCount: Int, axes: [Float], povsPacked: UInt32 = 0xFFFFFFFF) {
            self.buttons = buttons
            self.buttonCount = buttonCount
            self.axes = axes
            self.povsPacked = povsPacked
        }
    }

    public static func mrcJoystickData(_ js: JoystickWire) -> [UInt8] {
        var out: [UInt8] = []
        out += varintField(1, js.buttons)                          // AvailableButtons
        out += varintField(2, js.buttons)                          // Buttons（同掩码）
        out += varintField(3, UInt64(max(js.axes.count, js.buttonCount)))
        var axesPayload: [UInt8] = []
        for axis in js.axes {
            let quantized = Int32((Double(axis) * 127.0).rounded())
            axesPayload += packVarint(zigzag32(quantized))
        }
        out += lengthDelimitedField(4, axesPayload)                // repeated sint32 Axes
        out += varintField(5, 1)                                   // POVCount
        out += varintField(6, UInt64(js.povsPacked))               // POVs（4×int16 打包）
        return out
    }

    public static func mrcControlData(
        controlWord: UInt32,
        matchTimeSec: Int32,
        joysticks: [JoystickWire],
        currentOpMode: UInt64,
        gameData: String
    ) -> Data {
        var out: [UInt8] = []
        out += varintField(2, UInt64(UInt32(bitPattern: matchTimeSec))) // MatchTime int32
        for js in joysticks {
            out += lengthDelimitedField(3, mrcJoystickData(js))
        }
        out += fixed64Field(4, currentOpMode)                      // CurrentOpMode fixed64
        out += varintField(5, UInt64(controlWord))                 // ControlWord
        out += stringField(6, gameData)                            // GameData
        return Data(out)
    }
}
