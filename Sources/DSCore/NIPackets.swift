import Foundation

// MARK: - NI 协议（roboRIO 1.0 / 2.0）编解码
// 依据：frcnetworking.readthedocs.io（ds_to_rio / rio_to_ds，2026-09-15 核查快照）。
// 事实约定：UDP 控制包每 20ms（DS→1110，FMS 下 1115；robot→1150 回送源端口）；
// UDP tag 框架 = Size(u8, 含 ID 字节) + ID(u8) + Data；TCP 1740 帧 = Size(u16, 含 ID) + ID(u8)。
// 协议年份差异（2014–2026 packet 变体）按报告 §3.1 处理：本实现覆盖现行 0x01 comm version 主干。

/// 操作模式。Control/Status 字节 bit0-1。
public enum NIMode: UInt8, Sendable, CaseIterable, Codable {
    case teleoperated = 0
    case test = 1
    case autonomous = 2

    public var displayName: String {
        switch self {
        case .teleoperated: return "Teleoperated"
        case .test: return "Test"
        case .autonomous: return "Autonomous"
        }
    }
}

/// Alliance 站位 0–5：R1 R2 R3 B1 B2 B3（<3 红，≥3 蓝，%3+1 为站位）。
public enum AllianceStation: UInt8, Sendable, CaseIterable, Codable {
    case red1 = 0, red2, red3, blue1 = 3, blue2, blue3

    public var isRed: Bool { rawValue < 3 }
    public var number: Int { Int(rawValue) % 3 + 1 }
    public var displayName: String { "\(isRed ? "Red" : "Blue") \(number)" }
}

// MARK: 控制字 / 请求字 / 状态字

public struct ControlWord: Sendable, Equatable {
    public var estop = false
    public var fmsAttached = false
    public var enabled = false
    public var mode: NIMode = .teleoperated

    public init() {}

    public init(raw: UInt8) {
        estop = raw & 0x80 != 0
        fmsAttached = raw & 0x08 != 0
        enabled = raw & 0x04 != 0
        mode = NIMode(rawValue: raw & 0x03) ?? .teleoperated
    }

    public var raw: UInt8 {
        (estop ? 0x80 : 0) | (fmsAttached ? 0x08 : 0) | (enabled ? 0x04 : 0) | mode.rawValue
    }
}

/// Request 字节：bit3(0x08) 重启 roboRIO，bit2(0x04) 重启 robot code。
public struct RequestWord: Sendable, Equatable {
    public var rebootRoboRIO = false
    public var restartCode = false

    public init() {}
    public init(rebootRoboRIO: Bool, restartCode: Bool) {
        self.rebootRoboRIO = rebootRoboRIO
        self.restartCode = restartCode
    }
    public init(raw: UInt8) {
        rebootRoboRIO = raw & 0x08 != 0
        restartCode = raw & 0x04 != 0
    }
    public var raw: UInt8 { (rebootRoboRIO ? 0x08 : 0) | (restartCode ? 0x04 : 0) }
    public var isEmpty: Bool { raw == 0 }
}

/// robot→DS Status 字节：E-Stop 0x80 / Brownout 0x10 / 代码启动中 0x08 / Enabled 0x04 / 模式 bits0-1。
public struct RobotStatus: Sendable, Equatable {
    public var estop = false
    public var brownout = false
    public var codeStarting = false
    public var enabled = false
    public var mode: NIMode = .teleoperated

    public init() {}
    public init(raw: UInt8) {
        estop = raw & 0x80 != 0
        brownout = raw & 0x10 != 0
        codeStarting = raw & 0x08 != 0
        enabled = raw & 0x04 != 0
        mode = NIMode(rawValue: raw & 0x03) ?? .teleoperated
    }
    public var raw: UInt8 {
        (estop ? 0x80 : 0) | (brownout ? 0x10 : 0) | (codeStarting ? 0x08 : 0)
            | (enabled ? 0x04 : 0) | mode.rawValue
    }
}

/// robot→DS Trace 字节（回显指示灯）。
public struct RobotTrace: Sendable, Equatable {
    public var hasRobotCode = false
    public var isRoboRIO = false
    public var testMode = false
    public var autonomousMode = false
    public var teleopMode = false
    public var disabled = false

    public init() {}
    public init(raw: UInt8) {
        hasRobotCode = raw & 0x20 != 0
        isRoboRIO = raw & 0x10 != 0
        testMode = raw & 0x08 != 0
        autonomousMode = raw & 0x04 != 0
        teleopMode = raw & 0x02 != 0
        disabled = raw & 0x01 != 0
    }
    public var raw: UInt8 {
        (hasRobotCode ? 0x20 : 0) | (isRoboRIO ? 0x10 : 0) | (testMode ? 0x08 : 0)
            | (autonomousMode ? 0x04 : 0) | (teleopMode ? 0x02 : 0) | (disabled ? 0x01 : 0)
    }
}

// MARK: 手柄数据

public struct JoystickData: Sendable, Equatable {
    public var axes: [Float]        // 归一化 -1…1
    public var buttonCount: Int
    public var buttons: UInt64      // LSB = 按钮 1
    public var povs: [Int16]        // 0…360，-1 = 未按

    public init(axes: [Float] = [], buttonCount: Int = 0, buttons: UInt64 = 0, povs: [Int16] = []) {
        self.axes = axes
        self.buttonCount = buttonCount
        self.buttons = buttons
        self.povs = povs
    }

    public func isButtonPressed(_ index1Based: Int) -> Bool {
        guard index1Based >= 1, index1Based <= max(buttonCount, 64) else { return false }
        return buttons & (1 << UInt64(index1Based - 1)) != 0
    }

    /// float → int8：(-1…1) → (-128…127)，四舍五入、饱和。
    public static func encodeAxis(_ value: Float) -> Int8 {
        let scaled = (value.clamped(to: -1.0 ... 1.0) * 127.0).rounded()
        return Int8(clamping: Int(scaled))
    }
    public static func decodeAxis(_ raw: Int8) -> Float {
        Float(raw) / 127.0
    }

    /// HID hatswitch 原始值 → DS POV 角度（0/45/…/315，-1 = 未按）。
    ///
    /// 为什么要按描述器的逻辑范围判定：macOS 上八向帽的实现并不统一——
    /// 0…7（无中立位）、0…8（0 = HID「Not detected」）、1…8（0 = 越界中立）都存在。
    /// 旧实现把「raw 落在 0…7 之外」一律当未按，于是 0…8 / 1…8 设备同时错两处：
    /// 归位值 0 被上报成「POV 0°」（实为未按），偏转角 8 被上报成未按。
    ///
    /// 本函数只修**可判定**的部分（中立态识别 + 越界拒绝），角度次序仍沿用
    /// 「1 位 = 0°（正北）顺时针 +45°」的直序假设；HID Usage Tables 的 8 位帽
    /// 用法表次序（NE,NW,SW,SE,N,W,S,E）与之不同，真机设备矩阵核对前不凭文档改判
    /// ——见 docs/protocol/ds-protocol-2026.md「待实测（手柄 POV）」。
    public static func povAngle(raw: Int, logicalMin: Int, logicalMax: Int) -> Int16 {
        let stateCount = logicalMax - logicalMin + 1
        guard stateCount >= 2 else { return -1 }
        let hasNullState = stateCount >= 9 || logicalMin >= 1
        if hasNullState {
            // 0 为中立/未按；有效偏转从 1 起（logicalMin ≥ 1 时以 logicalMin 为准）
            let first = max(1, logicalMin)
            guard raw >= first, raw < first + 8 else { return -1 }
            return Int16((raw - first) * 45)
        }
        // 无中立位（典型 0…7）：直序映射，越界即未按
        guard raw >= logicalMin, raw - logicalMin < 8 else { return -1 }
        return Int16((raw - logicalMin) * 45)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: 遥测结构

public struct CANMetrics: Sendable, Equatable {
    public var utilizationPercent: Float = 0
    public var busOffCount: UInt32 = 0
    public var txFullCount: UInt32 = 0
    public var rxErrorCount: UInt8 = 0
    public var txErrorCount: UInt8 = 0
    public init() {}
}

public struct CPUInfo: Sendable, Equatable {
    /// 每核四档占用率（time-critical / above-normal / normal / low）
    public var cores: [[Float]] = []
    public init() {}
}

public struct JoystickOutput: Sendable, Equatable {
    public var outputs: UInt32 = 0
    public var leftRumble: UInt16 = 0
    public var rightRumble: UInt16 = 0
    public init() {}
}

// MARK: - 编解码器

public enum NICodec {
    public static let commVersion: UInt8 = 0x01
    public static let udpControlPort: UInt16 = 1110   // FMS 下 1115
    public static let udpResponsePort: UInt16 = 1150
    public static let tcpPort: UInt16 = 1740

    // MARK: DS → roboRIO 控制包（UDP 1110）

    /// dateSent/timezoneSent 首连时各发送一次（robot 置 requestDate=1 触发）。
    public static func controlPacket(
        seq: UInt16,
        control: ControlWord,
        request: RequestWord,
        alliance: AllianceStation,
        joysticks: [JoystickData],
        matchTime: Float? = nil,
        date: Date? = nil,
        timeZone: String? = nil
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

        // 每个手柄一个 0x0C tag
        for js in joysticks {
            var tag = ByteWriter()
            let axes = js.axes.map { JoystickData.encodeAxis($0) }
            tag.u8(UInt8(axes.count))
            for a in axes { tag.i8(a) }

            let buttonBits = max(js.buttonCount, 0)
            tag.u8(UInt8(min(buttonBits, 64)))
            let buttonBytes = buttonBits == 0 ? 0 : (buttonBits + 7) / 8
            for byteIndex in 0 ..< buttonBytes {
                var byte: UInt8 = 0
                for bit in 0 ..< 8 {
                    let index = byteIndex * 8 + bit
                    if index < 64, js.buttons & (1 << UInt64(index)) != 0 { byte |= UInt8(1 << bit) }
                }
                tag.u8(byte)
            }

            let povs = js.povs
            tag.u8(UInt8(min(povs.count, 255)))
            for pov in povs.prefix(255) { tag.i16be(pov) }
            appendTag(0x0C, tag.data, to: &w)
        }

        if let date {
            var tag = ByteWriter()
            let cal = Calendar(identifier: .gregorian)
            let tz = TimeZone(identifier: "UTC")!
            let c = cal.dateComponents(in: tz, from: date)
            tag.u32be(UInt32(truncatingIfNeeded: Int(date.timeIntervalSince1970 * 1_000_000)))
            tag.u8(UInt8(clamping: c.second ?? 0))
            tag.u8(UInt8(clamping: c.minute ?? 0))
            tag.u8(UInt8(clamping: c.hour ?? 0))
            tag.u8(UInt8(clamping: (c.day ?? 1)))
            tag.u8(UInt8(clamping: (c.month ?? 1) - 1))          // 0 = January
            tag.u8(UInt8(clamping: (c.year ?? 1900) - 1900))      // 1900 起算
            appendTag(0x0F, tag.data, to: &w)
        }

        if let timeZone {
            var tag = ByteWriter()
            tag.bytes(Array(timeZone.utf8.prefix(64)))
            appendTag(0x10, tag.data, to: &w)
        }

        return w.data
    }

    /// UDP tag：Size(u8 含 ID) + ID(u8) + Data
    public static func appendTag(_ id: UInt8, _ payload: Data, to w: inout ByteWriter) {
        w.u8(UInt8(payload.count + 1))
        w.u8(id)
        w.bytes(payload)
    }

    // MARK: roboRIO → DS 应答包（UDP 1150）

    public struct ResponsePacket: Sendable, Equatable {
        public var seq: UInt16 = 0
        public var status = RobotStatus()
        public var trace = RobotTrace()
        public var batteryVoltage: Float = 0        // XX + YY/256
        public var requestDate = false
        public var battery: UInt16 = 0
        public var joystickOutputs: [JoystickOutput] = []
        public var diskFreeBytes: UInt32 = 0
        public var cpu = CPUInfo()
        public var ramUsedBytes: UInt32 = 0
        public var ramTotalBytes: UInt32 = 0
        public var can = CANMetrics()
        /// NI 协议无此概念（恒 true）；MRC 应答 bit0（连续 5 包缺失 → DS 显示 Watchdog Not Fed）
        public var watchdogFed = true
    }

    public static func decodeResponse(_ data: Data) -> ResponsePacket? {
        var r = ByteReader(data)
        guard r.remaining >= 8 else { return nil }
        var p = ResponsePacket()
        guard let seq = r.u16be(), let version = r.u8(), let status = r.u8(),
              let trace = r.u8(), let battery = r.u16be(), let requestDate = r.u8(),
              version == commVersion else { return nil }
        p.seq = seq
        p.status = RobotStatus(raw: status)
        p.trace = RobotTrace(raw: trace)
        p.battery = battery
        p.batteryVoltage = Float(battery >> 8) + Float(battery & 0xFF) / 256.0
        p.requestDate = requestDate == 0x01

        while !r.isExhausted {
            guard let size = r.u8(), let id = r.u8(), size >= 1 else { return nil }
            guard let payload = r.bytes(Int(size) - 1) else { return nil }
            var tr = ByteReader(payload)
            switch id {
            case 0x01: // Joystick Output（可多个 7 字节记录拼接）
                while tr.remaining >= 7 {
                    var out = JoystickOutput()
                    out.outputs = tr.u32be() ?? 0
                    out.leftRumble = tr.u16be() ?? 0
                    out.rightRumble = tr.u16be() ?? 0
                    p.joystickOutputs.append(out)
                }
            case 0x04: // Disk：剩余空间 u32
                p.diskFreeBytes = tr.u32be() ?? 0
            case 0x05: // CPU：首 4 字节 float = 核数，随后每核 4 个 float
                if let count = tr.f32be() {
                    let n = Int(count.rounded())
                    for _ in 0 ..< min(max(n, 0), 16) {
                        let quad = [tr.f32be(), tr.f32be(), tr.f32be(), tr.f32be()]
                        if quad.allSatisfy({ $0 != nil }) {
                            p.cpu.cores.append(quad.map { $0 ?? 0 })
                        } else { break }
                    }
                }
            case 0x06: // RAM
                p.ramUsedBytes = tr.u32be() ?? 0
                p.ramTotalBytes = tr.u32be() ?? 0
            case 0x0E: // CAN 指标
                p.can.utilizationPercent = tr.f32be() ?? 0
                p.can.busOffCount = tr.u32be() ?? 0
                p.can.txFullCount = tr.u32be() ?? 0
                p.can.rxErrorCount = tr.u8() ?? 0
                p.can.txErrorCount = tr.u8() ?? 0
            default: break // 0x08 PDP log、0x09 未知：跳过
            }
        }
        return p
    }

    // MARK: DS → robot：解码控制包（模拟器用）

    public struct ControlPacket: Sendable, Equatable {
        public var seq: UInt16 = 0
        public var control = ControlWord()
        public var request = RequestWord()
        public var alliance: AllianceStation = .red1
        public var joysticks: [JoystickData] = []
        public var matchTime: Float?
        public var date: Date?
        public var timeZone: String?
    }

    public static func decodeControl(_ data: Data) -> ControlPacket? {
        var r = ByteReader(data)
        guard r.remaining >= 6 else { return nil }
        var p = ControlPacket()
        guard let seq = r.u16be(), let version = r.u8(), let control = r.u8(),
              let request = r.u8(), let alliance = r.u8(), version == commVersion else { return nil }
        p.seq = seq
        p.control = ControlWord(raw: control)
        p.request = RequestWord(raw: request)
        p.alliance = AllianceStation(rawValue: min(alliance, 5)) ?? .red1

        var date = DateComponents()
        var hasDate = false

        while !r.isExhausted {
            guard let size = r.u8(), let id = r.u8(), size >= 1 else { return nil }
            guard let payload = r.bytes(Int(size) - 1) else { return nil }
            var tr = ByteReader(payload)
            switch id {
            case 0x07: // Countdown（比赛时间，秒）
                p.matchTime = tr.f32be()
            case 0x0C: // Joystick（每 tag 一个手柄）
                var js = JoystickData()
                if let axisCount = tr.u8(),
                   let axes = tr.bytes(Int(axisCount)) {
                    js.axes = axes.map { JoystickData.decodeAxis(Int8(bitPattern: $0)) }
                    if let buttonCount = tr.u8() {
                        js.buttonCount = Int(buttonCount)
                        let buttonBytes = Int(buttonCount) == 0 ? 0 : (Int(buttonCount) + 7) / 8
                        if let rawButtons = tr.bytes(buttonBytes) {
                            var mask: UInt64 = 0
                            for (byteIndex, byte) in rawButtons.enumerated() {
                                for bit in 0 ..< 8 where byte & (1 << bit) != 0 {
                                    let index = byteIndex * 8 + bit
                                    if index < 64 { mask |= 1 << UInt64(index) }
                                }
                            }
                            js.buttons = mask
                        }
                        if let povCount = tr.u8() {
                            var povs: [Int16] = []
                            for _ in 0 ..< povCount {
                                if let pov = tr.i16be() { povs.append(pov) } else { return nil }
                            }
                            js.povs = povs
                            p.joysticks.append(js)
                        }
                    }
                }
            case 0x0F: // Date
                if let micros = tr.u32be(), let sec = tr.u8(), let minute = tr.u8(),
                   let hour = tr.u8(), let day = tr.u8(), let month0 = tr.u8(), let yearOff = tr.u8() {
                    date.second = Int(sec); date.minute = Int(minute); date.hour = Int(hour)
                    date.day = Int(day); date.month = Int(month0) + 1; date.year = 1900 + Int(yearOff)
                    hasDate = true
                    p.date = Date(timeIntervalSince1970: TimeInterval(micros) / 1_000_000)
                }
            case 0x10: // Timezone
                p.timeZone = String(decoding: payload, as: UTF8.self)
            default: break
            }
        }
        if hasDate, let tz = p.timeZone {
            p.date = Calendar(identifier: .gregorian).date(from: inTimeZone(date, tz))
        }
        return p
    }

    private static func inTimeZone(_ c: DateComponents, _ tzName: String) -> DateComponents {
        var d = c
        d.timeZone = TimeZone(identifier: tzName)
        return d
    }

    // MARK: TCP 1740 帧化（双向共用）

    public static let tcpKeepAlive = Data([0x00, 0x00])

    /// 从流缓冲提取全部完整帧；返回（帧列表，剩余未完成字节）。
    public static func extractTCPFrames(from buffer: Data) -> (frames: [(id: UInt8, payload: Data)], remainder: Data) {
        var frames: [(UInt8, Data)] = []
        var r = ByteReader(buffer)
        while r.remaining >= 2 {
            let frameStart = r.offset
            guard let size = r.u16be() else { break }
            if size == 0 { frames.append((0, Data())); continue } // keepalive
            guard size >= 1, let id = r.u8() else { r.rewind(to: frameStart); break }
            guard let payload = r.bytes(Int(size) - 1) else { r.rewind(to: frameStart); break }
            frames.append((id, Data(payload)))
        }
        let remainder = Data(r.data[r.offset...])
        return (frames, remainder)
    }

    public static func tcpFrame(id: UInt8, payload: Data) -> Data {
        var w = ByteWriter()
        w.u16be(UInt16(payload.count + 1))
        w.u8(id)
        w.bytes(payload)
        return w.data
    }

    // MARK: TCP tag 编码（DS → robot）

    public struct JoystickDescriptor: Sendable, Equatable {
        public var index: Int = 0
        public var isXbox = false
        public var type: Int8 = 20          // HID Joystick；见 readthedocs 枚举表
        public var name = ""
        public var axisTypes: [UInt8] = []  // 0 X / 1 Y / 2 Z / 3 Twist / 4 Throttle
        public var buttonCount = 0
        public var povCount = 0
        public init() {}
    }

    public static func joystickDescriptorTag(_ joysticks: [JoystickDescriptor]) -> Data {
        var payload = ByteWriter()
        for js in joysticks {
            payload.u8(UInt8(js.index))
            payload.u8(js.isXbox ? 1 : 0)
            payload.i8(js.type)
            payload.string8(js.name)
            payload.u8(UInt8(min(js.axisTypes.count, 255)))
            for t in js.axisTypes.prefix(255) { payload.u8(t) }
            payload.u8(UInt8(min(js.buttonCount, 255)))
            payload.u8(UInt8(min(js.povCount, 255)))
        }
        return tcpFrame(id: 0x02, payload: payload.data)
    }

    public static func gameDataTag(_ gameData: String) -> Data {
        var payload = ByteWriter()
        payload.string8(gameData)
        return tcpFrame(id: 0x0E, payload: payload.data)
    }

    public static func matchInfoTag(competition: String, matchType: UInt8) -> Data {
        var payload = ByteWriter()
        payload.string8(competition)
        payload.u8(matchType)
        return tcpFrame(id: 0x07, payload: payload.data)
    }

    // MARK: TCP tag 解码（robot → DS）

    public struct VersionEntry: Sendable, Equatable {
        public var deviceType: UInt8 = 0   // 0 Software / 2 CAN Talon / 8 PDP / 9 PCM
        public var name = ""
        public var version = ""
        public init() {}
    }

    public struct ErrorMessage: Sendable, Equatable {
        public var timestamp: Float = 0
        public var seq: UInt16 = 0
        public var errorCode: Int32 = 0
        public var flags: UInt8 = 0        // bit0 error / bit1 isLVcode
        public var details = ""
        public var location = ""
        public var callStack = ""
        /// 列表行身份（DS 侧插入时赋值）：协议 seq 会回绕、时间戳可重复，
        /// 不足以做 ForEach 的稳定 id——用偏移量作 id 时滑窗截断会让全部行身份漂移
        public var rowID = 0
        public init() {}
    }

    public struct StdoutMessage: Sendable, Equatable {
        public var timestamp: Float = 0
        public var seq: UInt16 = 0
        public var message = ""
        public init() {}
    }

    public enum TCPEvent: Sendable, Equatable {
        case versions([VersionEntry])
        case error(ErrorMessage)
        case stdout(StdoutMessage)
        case disableFaults(comms: UInt16, twelveV: UInt16)
        case railFaults(sixV: UInt16, fiveV: UInt16, threeV: UInt16)
        case unknown(id: UInt8)
    }

    public static func decodeTCPEvent(id: UInt8, payload: Data) -> TCPEvent? {
        var r = ByteReader(payload)
        switch id {
        case 0x0A:
            var entries: [VersionEntry] = []
            while r.remaining >= 6 {
                // 终止符：6 个 0x00
                if r.data[r.offset ..< r.offset + 6].allSatisfy({ $0 == 0 }) { break }
                var e = VersionEntry()
                guard let type = r.u8(), let _ = r.u16be(), let _ = r.u8(),
                      let name = r.string8(), let version = r.string8() else { break }
                e.deviceType = type
                e.name = name
                e.version = version
                entries.append(e)
            }
            return .versions(entries)
        case 0x0B:
            var m = ErrorMessage()
            guard let ts = r.f32be(), let seq = r.u16be(), let _ = r.u16be(),
                  let code = r.u32be(), let flags = r.u8(),
                  let details = r.string16(), let location = r.string16(),
                  let callStack = r.string16() else { return nil }
            m.timestamp = ts; m.seq = seq; m.errorCode = Int32(bitPattern: code); m.flags = flags
            m.details = details; m.location = location; m.callStack = callStack
            return .error(m)
        case 0x0C:
            var m = StdoutMessage()
            guard let ts = r.f32be(), let seq = r.u16be() else { return nil }
            m.timestamp = ts; m.seq = seq
            m.message = String(decoding: r.data[r.offset...], as: UTF8.self)
            return .stdout(m)
        case 0x04:
            guard let comms = r.u16be(), let twelve = r.u16be() else { return nil }
            return .disableFaults(comms: comms, twelveV: twelve)
        case 0x05:
            guard let six = r.u16be(), let five = r.u16be(), let three = r.u16be() else { return nil }
            return .railFaults(sixV: six, fiveV: five, threeV: three)
        default:
            return .unknown(id: id)
        }
    }
}
