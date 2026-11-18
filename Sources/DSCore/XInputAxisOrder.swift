import Foundation

// MARK: XInput 布局手柄的轴序/符号归一（对齐官方 FRC DS 的 XInput 手柄输出）

/// 官方 FRC DS 对 XInput 手柄下发的轴序 = WPILib `XboxController` 的索引基准：
/// [LeftX, LeftY, LeftTrigger, RightTrigger, RightX, RightY]，Y 族轴按 FRC 约定「向上 = -1」。
///
/// macOS IOHID 直读这类手柄得到的是 **HID usage 序**，两者并不一致。实测样本（2026-11-18
/// 真机联调，飞智冰原狼 4，USB 连接自报 Xbox 360 签名 VID 045E / PID 028E）：
/// usage 序 [X, Y, Z, Rx, Ry, Rz] = [左摇杆X, 左摇杆Y, 左扳机, 右摇杆X, 右摇杆Y, 右扳机]，
/// Z/Rz 为 0…255 扳机量程，其余四轴 ±32768 对称量程，且 Y 族「向上 = +1」与 FRC 约定相反。
/// 若按 usage 序原样透传，机器人侧会读错轴：旋转落到右摇杆 Y（必须上下拨才旋转）、
/// 右摇杆 X 误入右扳机槽位（推过半即触发绑在 RightTrigger 上的动作）。
///
/// 因此对命中 XInput 六轴签名的设备，按官方 DS 的 XInput 序重排并翻转 Y 族符号；
/// 其余布局（Attack3 / Extreme 3D Pro 等 HID 摇杆、带 Slider 的变体、蓝牙模式异形布局）
/// 一律返回 nil 保持 usage 序透传——与官方 DS 对 HID Joystick 类设备的处理一致。
public enum XInputAxisOrder {

    public struct Slot: Sendable, Equatable {
        public let sourceIndex: Int   // usage 序中的下标
        public let negate: Bool       // 下发前取反（Y 族：HID 上=+1 → FRC 上=-1）

        public init(sourceIndex: Int, negate: Bool) {
            self.sourceIndex = sourceIndex
            self.negate = negate
        }
    }

    /// XInput 六轴签名：usage 升序恰为 [X, Y, Z, Rx, Ry, Rz]，Z/Rz 为非对称扳机量程
    /// （logicalMin ≥ 0 且 logicalMax > 0），其余四轴为对称摇杆量程（logicalMin < 0）。
    /// 任一条不满足即不是本策略能判定的布局，返回 nil。
    ///
    /// - Parameters:
    ///   - usages: 轴 usage 列表（须已按 usage 升序，与 HIDInputManager 的排序一致）
    ///   - logicalMins/logicalMaxs: 与 usages 对齐的描述器逻辑范围
    ///   - isXbox: 设备自报 Xbox 系（名称或厂商 ID 判定，见 HIDInputManager.buildRecord）
    public static func map(usages: [UInt32], logicalMins: [Int32], logicalMaxs: [Int32], isXbox: Bool) -> [Slot]? {
        guard isXbox,
              usages == [0x30, 0x31, 0x32, 0x33, 0x34, 0x35],
              logicalMins.count == 6, logicalMaxs.count == 6
        else { return nil }
        // Z(下标2)/Rz(下标5)：扳机量程 0…255 一类，最小值不为负
        guard logicalMins[2] >= 0, logicalMins[5] >= 0,
              logicalMaxs[2] > 0, logicalMaxs[5] > 0
        else { return nil }
        // X/Y/Rx/Ry：对称摇杆量程，最小值必须为负（区分把扳机报在对称轴上的异形布局）
        guard logicalMins[0] < 0, logicalMins[1] < 0, logicalMins[3] < 0, logicalMins[4] < 0
        else { return nil }
        // usage 序 [X, Y, Z, Rx, Ry, Rz] → XInput 序 [X, Y, Z(LT), Rz(RT), Rx(RX), Ry(RY)]，Y/Ry 取反
        return [
            Slot(sourceIndex: 0, negate: false),  // LeftX  ← X
            Slot(sourceIndex: 1, negate: true),   // LeftY  ← Y（上=+1 → 上=-1）
            Slot(sourceIndex: 2, negate: false),  // LeftTrigger ← Z
            Slot(sourceIndex: 5, negate: false),  // RightTrigger ← Rz
            Slot(sourceIndex: 3, negate: false),  // RightX ← Rx
            Slot(sourceIndex: 4, negate: true),   // RightY ← Ry（上=+1 → 上=-1）
        ]
    }

    /// 把 usage 序的轴值按映射重排为 XInput 序。越界的槽位以 0 填充（描述器与轮询间
    /// 理论上不会失衡，防的是异形设备热插拔后的短暂错位）。
    public static func apply(_ map: [Slot], to values: [Float]) -> [Float] {
        map.map { slot in
            guard slot.sourceIndex < values.count else { return 0 }
            return slot.negate ? -values[slot.sourceIndex] : values[slot.sourceIndex]
        }
    }
}
