import Foundation

// MARK: - MRC 协议（SystemCore / MrcCommDaemon，Comm Version 2）
// 依据：DS_MRCCOMM_UDP_PROTOCOL.md（Compatibility Proxy 逆向，2026-09-16 核查快照；
// 从 FirstDriverStation + MrcCommDaemon 双端反汇编交叉验证）。只收协议事实，未复制其代码。
//
// 与 NI 协议的关键差异：
//   - comm version = 0x02；版本不符时 robot 回 8 字节 0xFF 错误包
//   - 控制字节：bit0 Test / bit1 Auto（独立位，非 2bit 字段）/ bit2 Enabled / bit3 FMS / bit7 E-Stop
//   - Request：bit0 = RequestNormal（清零则 robot 停机）
//   - 应答：24 字节头（payload CRC32C + header CRC32C，均 LE），回送到源端口
//   - 应答 ctrl：bit0-1 RobotMode（0 Unknown/1 Auto/2 Teleop/3 Test）、bit2 Enabled、
//     bit5 HasCode、bit7 E-Stop；status：bit0 WatchdogFed（每包必须）、
//     bit5 HasUserCodeReady、bit6 HasUserCode（5+6 同置才清除「无代码」）
//   - 手柄输出 tag 0x2E：6 槽 × 11B（RGB LED + 左/右/左扳机/右扳机 rumble u16 BE）
//   - TCP 1740 同帧格式；robot→DS 0x13 = OpMode 列表（自定义大端二进制，非 protobuf）

public enum MRCMode: UInt8, Sendable {
    case unknown = 0
    case autonomous = 1
    case teleoperated = 2
    case test = 3
}

public struct MRCControlWord: Sendable, Equatable {
    public var test = false
    public var autonomous = false
    public var enabled = false
    public var fmsAttached = false
    public var estop = false

    public init() {}
    public init(raw: UInt8) {
        test = raw & 0x01 != 0
        autonomous = raw & 0x02 != 0
        enabled = raw & 0x04 != 0
        fmsAttached = raw & 0x08 != 0
        estop = raw & 0x80 != 0
    }
    public var raw: UInt8 {
        (test ? 0x01 : 0) | (autonomous ? 0x02 : 0) | (enabled ? 0x04 : 0)
            | (fmsAttached ? 0x08 : 0) | (estop ? 0x80 : 0)
    }
}

public struct MRCRequestWord: Sendable, Equatable {
    /// bit0 RequestNormal：清零则 robot 停机
    public var normal = true
    public init(normal: Bool = true) { self.normal = normal }
    public init(raw: UInt8) { normal = raw & 0x01 != 0 }
    public var raw: UInt8 { normal ? 0x01 : 0 }
}

// MARK: 手柄输出（0x2E，6 槽位）

public struct MRCSlotOutput: Sendable, Equatable {
    public var ledR: UInt8 = 0
    public var ledG: UInt8 = 0
    public var ledB: UInt8 = 0
    public var leftRumble: UInt16 = 0
    public var rightRumble: UInt16 = 0
    public var leftTriggerRumble: UInt16 = 0
    public var rightTriggerRumble: UInt16 = 0
    public init(ledR: UInt8 = 0, ledG: UInt8 = 0, ledB: UInt8 = 0,
                leftRumble: UInt16 = 0, rightRumble: UInt16 = 0,
                leftTriggerRumble: UInt16 = 0, rightTriggerRumble: UInt16 = 0) {
        self.ledR = ledR; self.ledG = ledG; self.ledB = ledB
        self.leftRumble = leftRumble; self.rightRumble = rightRumble
        self.leftTriggerRumble = leftTriggerRumble; self.rightTriggerRumble = rightTriggerRumble
    }

    /// 联调确定值：MatchSticksDriverStaionSim 与回归应答器回送 0x2E 时用同一 pattern，
    /// 端到端断言「线上字节 = 金样本编码、DS 侧解码 = 同值」。
    public static let loopbackPattern = MRCSlotOutput(
        ledR: 0x20, ledG: 0x40, ledB: 0x80,
        leftRumble: 0x1234, rightRumble: 0x2345,
        leftTriggerRumble: 0x3456, rightTriggerRumble: 0x4567
    )
}

public extension MRCPackets {
    /// 手柄输出 tag（0x2E）编码：[size u8 = 1 + 11×n][id 0x2E][n × 11B]。
    /// 11B/槽 = LED RGB 3×u8 + 左/右/左扳机/右扳机 rumble 4×u16 BE（协议档案 §MRC）。
    static func slotOutputsTag(_ slots: [MRCSlotOutput]) -> Data {
        let n = min(slots.count, 6)
        var w = ByteWriter()
        w.u8(UInt8(1 + 11 * n))
        w.u8(0x2E)
        for slot in slots.prefix(n) {
            w.u8(slot.ledR); w.u8(slot.ledG); w.u8(slot.ledB)
            w.u16be(slot.leftRumble)
            w.u16be(slot.rightRumble)
            w.u16be(slot.leftTriggerRumble)
            w.u16be(slot.rightTriggerRumble)
        }
        return Data(w.data)
    }
}

// MARK: OpMode（TCP 0x13 列表项）

public struct MRCOpModeInfo: Sendable, Equatable {
    public var name: String
    public var group: String      // Auto / Teleop / Utility
    public var description: String
    public var hash: UInt64       // 0-55 hash / 56-57 robotMode / 58 isEnabled
    public var textColor: UInt32  // ARGB BE
    public var backgroundColor: UInt32

    public init(name: String, group: String, description: String, hash: UInt64,
                textColor: UInt32 = 0xFFFFFFFF, backgroundColor: UInt32 = 0xFF202020) {
        self.name = name
        self.group = group
        self.description = description
        self.hash = hash
        self.textColor = textColor
        self.backgroundColor = backgroundColor
    }

    public var robotMode: UInt8 { UInt8((hash >> 56) & 0x03) }
    public var isEnabledFlag: Bool { (hash >> 58) & 1 != 0 }
}

public enum MRCPackets {
    public static let commVersion: UInt8 = 0x02
    public static let replyHeaderSize = 24

    // MARK: DS → SystemCore 控制包（UDP 1110）

    public static func controlPacket(
        seq: UInt16,
        control: MRCControlWord,
        request: MRCRequestWord = MRCRequestWord(),
        alliance: AllianceStation,
        joysticks: [JoystickData],
        matchTime: Float? = nil
    ) -> Data {
        var w = ByteWriter()
        w.u16be(seq)
        w.u8(commVersion)
        w.u8(control.raw)
        w.u8(request.raw)
        w.u8(alliance.rawValue)

        if let matchTime {
            var tag = ByteWriter()
            tag.f32be(matchTime)
            appendTag(0x07, tag.data, to: &w)
        }
        for js in joysticks {
            var tag = ByteWriter()
            let axes = js.axes.map { JoystickData.encodeAxis($0) }
            tag.u8(UInt8(axes.count))
            for a in axes { tag.i8(a) }
            let buttonCount = max(js.buttonCount, 0)
            tag.u8(UInt8(min(buttonCount, 64)))
            let buttonBytes = buttonCount == 0 ? 0 : (buttonCount + 7) / 8
            for byteIndex in 0 ..< buttonBytes {
                var byte: UInt8 = 0
                for bit in 0 ..< 8 {
                    let index = byteIndex * 8 + bit
                    if index < 64, js.buttons & (1 << UInt64(index)) != 0 { byte |= UInt8(1 << bit) }
                }
                tag.u8(byte)
            }
            tag.u8(UInt8(min(js.povs.count, 255)))
            for pov in js.povs.prefix(255) { tag.i16be(pov) }
            appendTag(0x0C, tag.data, to: &w)
        }
        return w.data
    }

    static func appendTag(_ id: UInt8, _ payload: Data, to w: inout ByteWriter) {
        w.u8(UInt8(payload.count + 1))
        w.u8(id)
        w.bytes(payload)
    }

    public struct ControlPacket: Sendable, Equatable {
        public var seq: UInt16 = 0
        public var control = MRCControlWord()
        public var request = MRCRequestWord()
        public var alliance: AllianceStation = .red1
        public var joysticks: [JoystickData] = []
        public var matchTime: Float?
    }

    public static func decodeControl(_ data: Data) -> ControlPacket? {
        var r = ByteReader(data)
        guard r.remaining >= 6 else { return nil }
        var p = ControlPacket()
        guard let seq = r.u16be(), let version = r.u8(), let control = r.u8(),
              let request = r.u8(), let alliance = r.u8(), version == commVersion else { return nil }
        p.seq = seq
        p.control = MRCControlWord(raw: control)
        p.request = MRCRequestWord(raw: request)
        p.alliance = AllianceStation(rawValue: min(alliance, 5)) ?? .red1

        while !r.isExhausted {
            guard let size = r.u8(), let id = r.u8(), size >= 1 else { return nil }
            guard let payload = r.bytes(Int(size) - 1) else { return nil }
            var tr = ByteReader(Data(payload))
            switch id {
            case 0x07:
                p.matchTime = tr.f32be()
            case 0x0C:
                var js = JoystickData()
                if let axisCount = tr.u8(), let axes = tr.bytes(Int(axisCount)) {
                    js.axes = axes.map { raw in
                        // MRC 语义：负数 ÷128，非负 ÷127（WPILib 同款）
                        let v = Int8(bitPattern: raw)
                        return Float(v) / (v < 0 ? 128.0 : 127.0)
                    }
                    if let buttonCount = tr.u8() {
                        js.buttonCount = Int(buttonCount)
                        let buttonBytes = Int(buttonCount) == 0 ? 0 : (Int(buttonCount) + 7) / 8
                        if let rawButtons = tr.bytes(buttonBytes) {
                            var mask: UInt64 = 0
                            for (byteIndex, byte) in rawButtons.enumerated() {
                                for bit in 0..<8 where byte & (1 << bit) != 0 {
                                    let index = byteIndex * 8 + bit
                                    if index < 64 { mask |= 1 << UInt64(index) }
                                }
                            }
                            js.buttons = mask
                        }
                        if let povCount = tr.u8() {
                            var povs: [Int16] = []
                            for _ in 0..<povCount {
                                if let pov = tr.i16be() { povs.append(pov) } else { return nil }
                            }
                            js.povs = povs
                            p.joysticks.append(js)
                        }
                    }
                }
            default: break
            }
        }
        return p
    }

    // MARK: SystemCore → DS 应答编码（模拟器用；CRC32C ×2）

    public static func replyPacket(
        seq: UInt16,
        mode: MRCMode,
        enabled: Bool,
        estop: Bool = false,
        hasCode: Bool = true,
        watchdogFed: Bool = true,
        hasUserCodeReady: Bool = true,
        hasUserCode: Bool = true,
        batteryVolts: Float,
        flags: UInt8 = 0,
        reserved: [UInt8] = Array(repeating: 0, count: 8),
        payload: Data = Data()
    ) -> Data {
        var ctrl: UInt8 = mode.rawValue & 0x03
        if enabled { ctrl |= 0x04 }
        if hasCode { ctrl |= 0x20 }
        if estop { ctrl |= 0x80 }
        var status: UInt8 = 0
        if watchdogFed { status |= 0x01 }
        if hasUserCodeReady { status |= 0x20 }
        if hasUserCode { status |= 0x40 }
        let bInt = UInt8(clamping: Int(batteryVolts))
        let bFrac = UInt8(clamping: Int((batteryVolts - Float(bInt)) * 256))

        // 头 [0..8)：seq/ver/ctrl/status/batt/flags + [8..16) reserved
        var header: [UInt8] = [UInt8(seq >> 8), UInt8(seq & 0xFF), commVersion, ctrl, status, bInt, bFrac, flags]
        header += Array(reserved.prefix(8))
        // payload CRC32C → [16..20) 小端（LSB first）
        let payloadCRC = CRC32C.checksum([UInt8](payload))
        for shift in stride(from: 0, to: 32, by: 8) {
            header.append(UInt8((payloadCRC >> UInt32(shift)) & 0xFF))
        }
        // header CRC32C（只算 [0..20)）→ [20..24) 小端
        let headerCRC = CRC32C.checksum(header)
        for shift in stride(from: 0, to: 32, by: 8) {
            header.append(UInt8((headerCRC >> UInt32(shift)) & 0xFF))
        }
        var out = Data(header)
        out.append(payload)
        return out
    }

    // MARK: SystemCore → DS 应答（24B 头 + tags）

    public struct ReplyPacket: Sendable, Equatable {
        public var seq: UInt16 = 0
        public var mode: MRCMode = .unknown
        public var enabled = false
        public var estop = false
        public var hasCode = false
        public var watchdogFed = false
        public var hasUserCode = false
        public var hasUserCodeReady = false
        public var batteryVoltage: Float = 0
        public var flags: UInt8 = 0
        public var crcValid = false
        public var slotOutputs: [MRCSlotOutput] = []
    }

    /// 解码应答；CRC 不符返回 nil（坏包拒绝，不降级）
    public static func decodeReply(_ data: Data) -> ReplyPacket? {
        guard data.count >= replyHeaderSize else { return nil }
        let bytes = [UInt8](data)

        // header CRC：头 [0..20)
        let headerCRC = UInt32(bytes[20]) | UInt32(bytes[21]) << 8 | UInt32(bytes[22]) << 16 | UInt32(bytes[23]) << 24
        guard CRC32C.checksum(Array(bytes[0..<20])) == headerCRC else { return nil }
        // payload CRC：[24..]
        let payloadCRC = UInt32(bytes[16]) | UInt32(bytes[17]) << 8 | UInt32(bytes[18]) << 16 | UInt32(bytes[19]) << 24
        guard CRC32C.checksum(Array(bytes[24...])) == payloadCRC else { return nil }

        var p = ReplyPacket()
        p.seq = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        guard bytes[2] == commVersion else { return nil }
        let ctrl = bytes[3]
        p.mode = MRCMode(rawValue: ctrl & 0x03) ?? .unknown
        p.enabled = ctrl & 0x04 != 0
        p.hasCode = ctrl & 0x20 != 0
        p.estop = ctrl & 0x80 != 0
        let status = bytes[4]
        p.watchdogFed = status & 0x01 != 0
        p.hasUserCodeReady = status & 0x20 != 0
        p.hasUserCode = status & 0x40 != 0
        p.batteryVoltage = Float(bytes[5]) + Float(bytes[6]) / 256
        p.flags = bytes[7]

        // tags
        var r = ByteReader(Data(bytes[24...]))
        while !r.isExhausted {
            guard let size = r.u8(), let id = r.u8(), size >= 1 else { return nil }
            guard let payload = r.bytes(Int(size) - 1) else { return nil }
            if id == 0x2E, payload.count % 11 == 0, payload.count / 11 <= 6 {
                var tr = ByteReader(Data(payload))
                while !tr.isExhausted {
                    var slot = MRCSlotOutput()
                    slot.ledR = tr.u8() ?? 0
                    slot.ledG = tr.u8() ?? 0
                    slot.ledB = tr.u8() ?? 0
                    slot.leftRumble = tr.u16be() ?? 0
                    slot.rightRumble = tr.u16be() ?? 0
                    slot.leftTriggerRumble = tr.u16be() ?? 0
                    slot.rightTriggerRumble = tr.u16be() ?? 0
                    p.slotOutputs.append(slot)
                }
            }
        }
        p.crcValid = true
        return p
    }

    /// 版本错误包（0xFF）：[seq u16][0xFF][errorCode][0×4]
    public static func decodeErrorPacket(_ data: Data) -> UInt8? {
        guard data.count >= 8, data[2] == 0xFF else { return nil }
        return data[3]
    }

    // MARK: OpMode 列表（TCP 0x13，自定义大端二进制——非 protobuf）

    public static func opModesTag(_ opModes: [MRCOpModeInfo]) -> Data {
        var payload = ByteWriter()
        payload.u8(UInt8(min(opModes.count, 255)))
        for op in opModes {
            payload.string8(String(op.name.prefix(64)))
            payload.string8(String(op.group.prefix(64)))
            payload.string8(String(op.description.prefix(64)))
            var hash = op.hash.bigEndian
            for _ in 0..<8 { payload.u8(UInt8(hash & 0xFF)); hash >>= 8 }
            var color = op.textColor.bigEndian
            for _ in 0..<4 { payload.u8(UInt8(color & 0xFF)); color >>= 8 }
            var bg = op.backgroundColor.bigEndian
            for _ in 0..<4 { payload.u8(UInt8(bg & 0xFF)); bg >>= 8 }
        }
        return tcpFrame(id: 0x13, payload: payload.data)
    }

    public static func decodeOpModes(_ payload: Data) -> [MRCOpModeInfo] {
        var r = ByteReader(payload)
        guard let count = r.u8() else { return [] }
        var out: [MRCOpModeInfo] = []
        for _ in 0..<count {
            guard let name = r.string8(), let group = r.string8(), let desc = r.string8(),
                  !name.isEmpty, !group.isEmpty, !desc.isEmpty else { return out }
            var hashBytes: UInt64 = 0
            for _ in 0..<8 {
                guard let b = r.u8() else { return out }
                hashBytes = hashBytes << 8 | UInt64(b)
            }
            var color: UInt32 = 0
            for _ in 0..<4 {
                guard let b = r.u8() else { return out }
                color = color << 8 | UInt32(b)
            }
            var bg: UInt32 = 0
            for _ in 0..<4 {
                guard let b = r.u8() else { return out }
                bg = bg << 8 | UInt32(b)
            }
            out.append(MRCOpModeInfo(name: name, group: group, description: desc,
                                     hash: hashBytes, textColor: color, backgroundColor: bg))
        }
        return out
    }

    public static func tcpFrame(id: UInt8, payload: Data) -> Data {
        var w = ByteWriter()
        w.u16be(UInt16(payload.count + 1))
        w.u8(id)
        w.bytes(payload)
        return w.data
    }
}
