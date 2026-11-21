import Foundation

// MARK: - 手柄造型档案：设备识别 + 语义映射（皮肤视图的数据源，纯逻辑可测）
//
// 证据纪律（与 ds-protocol 档案一致，条目只收「已核查」与「待实测」两类）：
// - 已核查（2026-11-18 真机联调，见 XInputAxisOrder.swift 头注）：
//   飞智冰原狼 4 USB 自报 Xbox 360 签名 VID 045E / PID 028E，
//   usage 序 [X, Y, Z, Rx, Ry, Rz]，Z/Rz 为扳机量程 → 经 XInputAxisOrder 归一后
//   语义稳定为 左摇杆 X/Y、LT=Z、RT=Rz、右摇杆 Rx/Ry（usage 跟随重排，仍可按 usage 取值）。
// - 待实测（映射表按公开惯例落种子，皮肤悬停提示显示原始按键号，台架插入即可核对修正）：
//   各款按键号顺序、DualSense 的轴 usage 分布与方向键形态、Xbox Series 的 Share/Guide 暴露情况。

/// 造型（皮肤）种类：四款原型 + 未识别兜底。
public enum GamepadSkin: String, CaseIterable, Sendable {
    case f310          // 罗技 F310（FRC KoP 黑色款；macOS 上只见 D 档 DirectInput）
    case direwolf4     // 飞智冰原狼 4（USB 模式自报 Xbox 360 签名）
    case dualsense     // PS5 DualSense
    case xboxSeries    // Xbox Series X|S 手柄
    case generic       // 未识别设备的通用示意造型

    public var displayName: String {
        switch self {
        case .f310: return tr("罗技 F310")
        case .direwolf4: return tr("飞智冰原狼 4")
        case .dualsense: return tr("PS5 DualSense")
        case .xboxSeries: return tr("Xbox Series 手柄")
        case .generic: return tr("通用手柄")
        }
    }
}

/// 面键物理方位（与品牌字母解耦：A/B/X/Y 与 △/○/✕/□ 都落在四个方位上）。
public enum GamepadFace: String, CaseIterable, Sendable, Hashable {
    case north, east, south, west
}

/// 方向键方位（同时用于 POV 角度解析）。
public enum GamepadDirection: String, CaseIterable, Sendable, Hashable {
    case up, right, down, left
}

/// 造型附加键（不属于面键/肩键/扳机/摇杆/中央三键的额外实体）。
public enum GamepadExtra: String, CaseIterable, Sendable, Hashable {
    case touchpad   // DualSense 触控板
    case share      // Xbox Series 分享键
    case backL      // 背键左（冰原狼 M1）
    case backR      // 背键右（冰原狼 M2）
}

/// 皮肤绘制用的一次性语义状态快照。
public struct GamepadStickState: Sendable, Equatable {
    /// 上为正（已统一约定：XInput 归一设备的「上=-1」在此翻转为 +1）。
    public var x: Float
    public var yUp: Float
    public var pressed: Bool
    public init(x: Float, yUp: Float, pressed: Bool) {
        self.x = x
        self.yUp = yUp
        self.pressed = pressed
    }
}

public struct GamepadTriggerState: Sendable, Equatable {
    public var pressed: Bool
    /// 0…1 按压深度；nil = 该设备此扳机无模拟量（数字键），视图按开/关呈现。
    public var depth: Float?
    public init(pressed: Bool, depth: Float?) {
        self.pressed = pressed
        self.depth = depth
    }
}

public struct GamepadElementState: Sendable, Equatable {
    public var face: [GamepadFace: Bool]
    public var dpad: Set<GamepadDirection>
    public var shoulderL: Bool
    public var shoulderR: Bool
    public var triggerL: GamepadTriggerState
    public var triggerR: GamepadTriggerState
    public var leftStick: GamepadStickState
    public var rightStick: GamepadStickState
    public var back: Bool
    public var start: Bool
    public var guide: Bool
    public var extras: [GamepadExtra: Bool]
    /// 已按下但未映射到任何造型元素的按键号（1 基）：皮肤下方以编号芯片呈现，不丢信息。
    public var unmapped: [Int]

    public static let neutral: GamepadElementState = GamepadElementState(
        face: [.north: false, .east: false, .south: false, .west: false],
        dpad: [], shoulderL: false, shoulderR: false,
        triggerL: GamepadTriggerState(pressed: false, depth: nil),
        triggerR: GamepadTriggerState(pressed: false, depth: nil),
        leftStick: GamepadStickState(x: 0, yUp: 0, pressed: false),
        rightStick: GamepadStickState(x: 0, yUp: 0, pressed: false),
        back: false, start: false, guide: false, extras: [:], unmapped: []
    )
}

public enum GamepadInputMode: String, Sendable {
    case directInput
    case xinput
}

/// 只描述显示样本的物理方向，不改变发往机器人的原始轴。
public struct GamepadStickPolarity: Sendable, Equatable {
    public var xRightIsNegative: Bool
    public var yUpIsNegative: Bool

    public init(xRightIsNegative: Bool, yUpIsNegative: Bool) {
        self.xRightIsNegative = xRightIsNegative
        self.yUpIsNegative = yUpIsNegative
    }
}

/// 从槽位透传的最小输入样本（JoystickCard 现场组装；测试直接构造）。
public struct GamepadSample: Sendable {
    public var name: String
    public var vendorID: Int
    public var productID: Int
    public var axes: [Float]
    /// 与 axes 对齐的 HID usage（XInput 归一设备为重排后的 usage，语义不变）。
    public var axisUsages: [UInt32]
    public var buttons: UInt64
    public var povs: [Int16]
    public var mode: GamepadInputMode
    public var polarity: GamepadStickPolarity

    public init(name: String = "", vendorID: Int = 0, productID: Int = 0,
                axes: [Float], axisUsages: [UInt32], buttons: UInt64 = 0,
                povs: [Int16] = [], mode: GamepadInputMode = .directInput,
                polarity: GamepadStickPolarity = GamepadStickPolarity(
                    xRightIsNegative: false, yUpIsNegative: false)) {
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.axes = axes
        self.axisUsages = axisUsages
        self.buttons = buttons
        self.povs = povs
        self.mode = mode
        self.polarity = polarity
    }
}

// MARK: - 识别

public enum GamepadProfile {

    /// VID/PID + 设备名 → 造型。名称优先于 VID/PID（克隆签名靠名称救回）。
    public static func detect(vendorID: Int, productID: Int, name: String) -> GamepadSkin {
        let lower = name.lowercased()
        // 名称命中优先：冰原狼 4 USB 自报 Xbox 360 签名，真 360 手柄同签名无法区分，
        // 但冰原狼产品名含 Flydigi/Direwolf 时可救回（待实测：macOS 上自报名的实际拼写）。
        if lower.contains("flydigi") || lower.contains("direwolf") || name.contains("冰原狼") {
            return .direwolf4
        }
        if lower.contains("dualsense") || lower.contains("wireless controller") && vendorID == 0x054C {
            return .dualsense
        }
        if lower.contains("dual action") && vendorID == 0x046D {
            return .f310
        }
        switch (vendorID, productID) {
        case (0x046D, 0xC216), (0x046D, 0xC21D):   // F310 D / X 两档
            return .f310
        case (0x054C, 0x0CE6), (0x054C, 0x0DF2):   // DualSense / DualSense Edge
            return .dualsense
        case (0x045E, 0x028E):                     // 冰原狼 4 USB（2026-11-18 真机实测自报签名）
            return .direwolf4
        case (0x045E, 0x0B12), (0x045E, 0x0B13),   // Series X|S USB / BT
             (0x045E, 0x0B20), (0x045E, 0x0B22),   // Series BT（新）/ Elite 2 BT
             (0x045E, 0x02E0), (0x045E, 0x02FD):   // One S BT
            return .xboxSeries
        default:
            return .generic
        }
    }

    /// 生效造型：手动覆盖优先，否则按识别。
    public static func effectiveSkin(sample: GamepadSample, override: GamepadSkin?) -> GamepadSkin {
        override ?? detect(vendorID: sample.vendorID, productID: sample.productID, name: sample.name)
    }

    public static func displayPolarity(vendorID: Int, productID: Int, name: String,
                                       xinputNormalized: Bool) -> GamepadStickPolarity {
        if xinputNormalized {
            return GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: true)
        }
        switch detect(vendorID: vendorID, productID: productID, name: name) {
        case .dualsense:
            return GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: true)
        case .f310:
            return GamepadStickPolarity(xRightIsNegative: true, yUpIsNegative: true)
        default:
            return GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: false)
        }
    }
}

// MARK: - 逐款映射表

public struct GamepadLayout: Sendable {

    // MARK: 映射字段（全部为 HID 按键号，1 基；usage 为 GenericDesktop 轴页代码）

    /// 面键四方位 → 按键号。
    public let face: [GamepadFace: Int]
    /// 肩键（LB/L1、RB/R1）。
    public let shoulder: (l: Int, r: Int)
    /// 数字扳机（无模拟量的设备；有模拟量时仍作按压态兜底）。
    public let triggerButton: (l: Int?, r: Int?)
    /// 摇杆按下（L3/R3）。
    public let stickPress: (l: Int, r: Int)
    /// 中央键（Back/View/Select/Create；Start/Menu/Options；Guide/PS）。
    public let back: Int?
    public let start: Int?
    public let guide: Int?
    /// 附加键。
    public let extras: [GamepadExtra: Int]
    /// 方向键：Hatswitch 下标（多数设备）或按键号（无帽设备）。两者并存时 POV 优先。
    public let dpadPOV: Int?
    public let dpadButtons: [GamepadDirection: Int]?
    /// 摇杆轴 usage。
    public let stickUsage: (lx: UInt32, ly: UInt32, rx: UInt32, ry: UInt32)
    /// 模拟扳机轴 usage（0…255 类量程归一为 -1…+1，静止 -1）。
    public let triggerUsage: (lt: UInt32?, rt: UInt32?)

    init(face: [GamepadFace: Int], shoulder: (l: Int, r: Int),
         triggerButton: (l: Int?, r: Int?), stickPress: (l: Int, r: Int),
         back: Int?, start: Int?, guide: Int?, extras: [GamepadExtra: Int],
         dpadPOV: Int?, dpadButtons: [GamepadDirection: Int]?,
         stickUsage: (lx: UInt32, ly: UInt32, rx: UInt32, ry: UInt32),
         triggerUsage: (lt: UInt32?, rt: UInt32?)) {
        self.face = face
        self.shoulder = shoulder
        self.triggerButton = triggerButton
        self.stickPress = stickPress
        self.back = back
        self.start = start
        self.guide = guide
        self.extras = extras
        self.dpadPOV = dpadPOV
        self.dpadButtons = dpadButtons
        self.stickUsage = stickUsage
        self.triggerUsage = triggerUsage
    }

    /// 各款映射表。按键号证据状态见文件头注（冰原狼轴序已核查；按键号待实测）。
    public static func layout(for skin: GamepadSkin, mode: GamepadInputMode = .directInput) -> GamepadLayout {
        switch skin {
        case .f310:
            if mode == .xinput {
                return GamepadLayout(
                    face: [.south: 1, .east: 2, .west: 3, .north: 4],
                    shoulder: (l: 5, r: 6),
                    triggerButton: (l: nil, r: nil),
                    stickPress: (l: 9, r: 10),
                    back: 7, start: 8, guide: 11,
                    extras: [:],
                    dpadPOV: 0, dpadButtons: nil,
                    stickUsage: (lx: 0x30, ly: 0x31, rx: 0x33, ry: 0x34),
                    triggerUsage: (lt: 0x32, rt: 0x35))
            }
            // F310 D 档（046D:C216）实测：X1/A2/B3/Y4，肩 5/6、数字扳机 7/8、
            // Back 9 / Start 10、L3/R3 11/12，右摇杆 = Z/Rz。
            return GamepadLayout(
                face: [.west: 1, .south: 2, .east: 3, .north: 4],
                shoulder: (l: 5, r: 6),
                triggerButton: (l: 7, r: 8),
                stickPress: (l: 11, r: 12),
                back: 9, start: 10, guide: nil,
                extras: [:],
                dpadPOV: 0, dpadButtons: nil,
                stickUsage: (lx: 0x30, ly: 0x31, rx: 0x32, ry: 0x35),
                triggerUsage: (lt: nil, rt: nil))
        case .direwolf4:
            // Xbox 360 兼容序（xpad 惯例）：A1 B2 X3 Y4、LB5 RB6、Back7 Start8、Guide9、L3/R3 10/11；
            // M1/M2 背键暴露形态未知（待实测）——不落表，按「未映射芯片」自揭示。
            // 轴 = 已核查实测签名（经 XInputAxisOrder 归一，usage 跟随重排）。
            return GamepadLayout(
                face: [.south: 1, .east: 2, .west: 3, .north: 4],
                shoulder: (l: 5, r: 6),
                triggerButton: (l: nil, r: nil),
                stickPress: (l: 10, r: 11),
                back: 7, start: 8, guide: 9,
                extras: [:],
                dpadPOV: 0, dpadButtons: nil,
                stickUsage: (lx: 0x30, ly: 0x31, rx: 0x33, ry: 0x34),
                triggerUsage: (lt: 0x32, rt: 0x35))
        case .dualsense:
            // PS HID 惯例序：□1 ✕2 ○3 △4、L1 5 R1 6、L2 7 R2 8、Create 9 Options 10、L3/R3 11/12、
            // PS 13、触控板 14。轴：左摇杆 X/Y，右摇杆 Z/Rz，扳机 Rx/Ry（macOS 暴露形态待实测，
            // 触发路径：模拟优先、数字兜底）。方向键 POV 0 待实测（若实为按键将落入未映射自揭示）。
            return GamepadLayout(
                face: [.west: 1, .south: 2, .east: 3, .north: 4],
                shoulder: (l: 5, r: 6),
                triggerButton: (l: 7, r: 8),
                stickPress: (l: 11, r: 12),
                back: 9, start: 10, guide: 13,
                extras: [.touchpad: 14],
                dpadPOV: 0, dpadButtons: nil,
                stickUsage: (lx: 0x30, ly: 0x31, rx: 0x32, ry: 0x35),
                triggerUsage: (lt: 0x33, rt: 0x34))
        case .xboxSeries:
            // Xbox One/Series HID 惯例序：A1 B2 X3 Y4、LB5 RB6、View7 Menu8、L3/R3 9/10、Share 11
            // （Guide 常不暴露）。轴 = 六轴 XInput 签名语义（同冰原狼，usage 取归一后语义）。
            return GamepadLayout(
                face: [.south: 1, .east: 2, .west: 3, .north: 4],
                shoulder: (l: 5, r: 6),
                triggerButton: (l: nil, r: nil),
                stickPress: (l: 9, r: 10),
                back: 7, start: 8, guide: nil,
                extras: [.share: 11],
                dpadPOV: 0, dpadButtons: nil,
                stickUsage: (lx: 0x30, ly: 0x31, rx: 0x33, ry: 0x34),
                triggerUsage: (lt: 0x32, rt: 0x35))
        case .generic:
            // 未识别设备：编号即标签（面键 1–4、肩 5/6、数字扳机 7/8、9/10、L3/R3 11/12），
            // 摇杆取最常见的 X/Y + Z/Rz 布局；不匹配的按键全部落入未映射芯片，不误导。
            return GamepadLayout(
                face: [.north: 1, .east: 2, .south: 3, .west: 4],
                shoulder: (l: 5, r: 6),
                triggerButton: (l: 7, r: 8),
                stickPress: (l: 11, r: 12),
                back: 9, start: 10, guide: nil,
                extras: [:],
                dpadPOV: 0, dpadButtons: nil,
                stickUsage: (lx: 0x30, ly: 0x31, rx: 0x32, ry: 0x35),
                triggerUsage: (lt: nil, rt: nil))
        }
    }

    // MARK: 状态提取

    /// 输入样本 → 皮肤语义状态。容错：轴/usage 数失衡、非有限值、未知 usage 一律安全回落。
    public func state(for sample: GamepadSample) -> GamepadElementState {
        var s = GamepadElementState.neutral

        func pressed(_ number: Int?) -> Bool {
            guard let number, number >= 1, number <= 64 else { return false }
            return sample.buttons & (1 << UInt64(number - 1)) != 0
        }
        func axis(_ usage: UInt32?) -> Float? {
            guard let usage, let i = sample.axisUsages.firstIndex(of: usage),
                  sample.axes.indices.contains(i) else { return nil }
            let v = sample.axes[i]
            return v.isFinite ? max(-1, min(1, v)) : 0
        }
        /// 归一 -1…+1 → 深度 0…1（扳机量程静止 -1、按满 +1）。
        func depth(_ v: Float) -> Float { max(0, min(1, (v + 1) / 2)) }

        for (pos, number) in face { s.face[pos] = pressed(number) }
        s.shoulderL = pressed(shoulder.l)
        s.shoulderR = pressed(shoulder.r)

        s.triggerL = triggerState(lt: triggerUsage.lt, lButton: triggerButton.l, axis: axis, pressed: pressed, depth: depth)
        s.triggerR = triggerState(lt: triggerUsage.rt, lButton: triggerButton.r, axis: axis, pressed: pressed, depth: depth)

        s.leftStick = stickState(x: axis(stickUsage.lx), y: axis(stickUsage.ly), press: stickPress.l,
                                 polarity: sample.polarity, pressed: pressed)
        s.rightStick = stickState(x: axis(stickUsage.rx), y: axis(stickUsage.ry), press: stickPress.r,
                                  polarity: sample.polarity, pressed: pressed)

        s.back = pressed(back)
        s.start = pressed(start)
        s.guide = pressed(guide)
        for (key, number) in extras { s.extras[key] = pressed(number) }

        s.dpad = dpadDirections(sample: sample)

        s.unmapped = unmappedNumbers(sample: sample)
        return s
    }

    private func triggerState(lt: UInt32?, lButton: Int?, axis: (UInt32?) -> Float?,
                              pressed: (Int?) -> Bool, depth: (Float) -> Float) -> GamepadTriggerState {
        if let analog = axis(lt) {
            let d = depth(analog)
            return GamepadTriggerState(pressed: d > 0.02 || pressed(lButton), depth: d)
        }
        let down = pressed(lButton)
        return GamepadTriggerState(pressed: down, depth: nil)
    }

    private func stickState(x: Float?, y: Float?, press: Int,
                            polarity: GamepadStickPolarity, pressed: (Int?) -> Bool) -> GamepadStickState {
        let rawX = x ?? 0
        let rawY = y ?? 0
        return GamepadStickState(
            x: polarity.xRightIsNegative ? -rawX : rawX,
            yUp: polarity.yUpIsNegative ? -rawY : rawY,
            pressed: pressed(press))
    }

    private func dpadDirections(sample: GamepadSample) -> Set<GamepadDirection> {
        var result: Set<GamepadDirection> = []
        if let povIndex = dpadPOV, sample.povs.indices.contains(povIndex) {
            let angle = sample.povs[povIndex]
            if angle >= 0 {
                // 0°=上，顺时针 45° 步进；POV 角度语义见 JoystickData.povAngle
                if angle >= 338 || angle <= 22 { result.insert(.up) }
                if angle >= 23 && angle <= 67 { result.insert(.up); result.insert(.right) }
                if angle >= 68 && angle <= 112 { result.insert(.right) }
                if angle >= 113 && angle <= 157 { result.insert(.right); result.insert(.down) }
                if angle >= 158 && angle <= 202 { result.insert(.down) }
                if angle >= 203 && angle <= 247 { result.insert(.down); result.insert(.left) }
                if angle >= 248 && angle <= 292 { result.insert(.left) }
                if angle >= 293 && angle <= 337 { result.insert(.left); result.insert(.up) }
            }
            return result
        }
        if let buttons = dpadButtons {
            for (dir, number) in buttons where sample.buttons & (1 << UInt64(max(0, number - 1))) != 0 {
                result.insert(dir)
            }
        }
        return result
    }

    /// 本表引用到的全部按键号（未映射计算的排除集；测试做表完备性断言）。
    public var mappedNumbers: Set<Int> {
        var numbers = Set<Int>()
        numbers.formUnion(face.values)
        numbers.insert(shoulder.l); numbers.insert(shoulder.r)
        if let l = triggerButton.l { numbers.insert(l) }
        if let r = triggerButton.r { numbers.insert(r) }
        numbers.insert(stickPress.l); numbers.insert(stickPress.r)
        [back, start, guide].forEach { if let n = $0 { numbers.insert(n) } }
        numbers.formUnion(extras.values)
        if let buttons = dpadButtons { numbers.formUnion(buttons.values) }
        return numbers
    }

    private func unmappedNumbers(sample: GamepadSample) -> [Int] {
        (1...64).filter { sample.buttons & (1 << UInt64($0 - 1)) != 0 && !mappedNumbers.contains($0) }
    }
}
