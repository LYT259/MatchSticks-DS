// MARK: XInput 轴序归一：飞智冰原狼 4 实测布局 → 官方 FRC DS XInput 序（2026-11-18 真机联调修复）

import Foundation
import DSCore

/// 实测签名（USB、自报 Xbox 360 VID 045E/PID 028E）：
/// usage 序 [X, Y, Z, Rx, Ry, Rz]，X/Y/Rx/Ry ±32768 对称量程，Z/Rz 0…255 扳机量程。
private let direwolfUsages: [UInt32] = [0x30, 0x31, 0x32, 0x33, 0x34, 0x35]
private let direwolfMins: [Int32] = [-32768, -32768, 0, -32768, -32768, 0]
private let direwolfMaxs: [Int32] = [32767, 32767, 255, 32767, 32767, 255]

func xinputAxisOrderDirewolfLayout() {
    guard let map = XInputAxisOrder.map(usages: direwolfUsages, logicalMins: direwolfMins,
                                        logicalMaxs: direwolfMaxs, isXbox: true) else {
        check(false, "冰原狼 4 实测六轴签名应命中 XInput 映射")
        return
    }
    check(map.count == 6, "映射覆盖六轴（\(map.count)）")

    // usage 序输入（X, Y, Z, Rx, Ry, Rz）→ XInput 序输出（LX, LY, LT, RT, RX, RY）
    // 中立态：摇杆全 0、双扳机静止 -1
    check(XInputAxisOrder.apply(map, to: [0, 0, -1, 0, 0, -1]) == [0, 0, -1, -1, 0, 0],
          "中立态：双扳机槽（axis2/3）静止均为 -1")
    // 左摇杆右（X=+1）→ LeftX = +1
    check(XInputAxisOrder.apply(map, to: [1, 0, -1, 0, 0, -1])[0] == 1, "左摇杆右 → LeftX=+1")
    // 左摇杆上（实测 Y=+1，与 FRC 约定相反）→ LeftY 翻转为 -1
    check(XInputAxisOrder.apply(map, to: [0, 1, -1, 0, 0, -1])[1] == -1, "左摇杆上（Y 原始 +1）→ LeftY=-1")
    // 右摇杆右（Rx=+1）→ RightX = +1（旋转轴回到左右拨）
    check(XInputAxisOrder.apply(map, to: [0, 0, -1, 1, 0, -1])[4] == 1, "右摇杆右（Rx）→ RightX=+1")
    // 右摇杆上（Ry=+1）→ RightY 翻转为 -1
    check(XInputAxisOrder.apply(map, to: [0, 0, -1, 0, 1, -1])[5] == -1, "右摇杆上（Ry 原始 +1）→ RightY=-1")
    // 左扳机按满（Z=+1）→ LeftTrigger = +1
    check(XInputAxisOrder.apply(map, to: [0, 0, 1, 0, 0, -1])[2] == 1, "左扳机满 → LeftTrigger=+1")
    // 右扳机按满（Rz=+1）→ RightTrigger = +1（原 usage 序里它排在第 6 位）
    check(XInputAxisOrder.apply(map, to: [0, 0, -1, 0, 0, 1])[3] == 1, "右扳机满（Rz）→ RightTrigger=+1")
    // 修复前错位回归锚点：右摇杆右绝不能再出现在 axis3（右扳机槽）
    check(XInputAxisOrder.apply(map, to: [0, 0, -1, 1, 0, -1])[3] == -1, "右摇杆右不再落入 RightTrigger 槽")
}

func xinputAxisOrderNonXboxPassthrough() {
    // 同布局但非 Xbox 自报（isXbox=false）：不重排，保持 usage 序透传
    let map = XInputAxisOrder.map(usages: direwolfUsages, logicalMins: direwolfMins,
                                  logicalMaxs: direwolfMaxs, isXbox: false)
    check(map == nil, "非 Xbox 设备不套 XInput 映射")
}

func xinputAxisOrderRejectsNonSignatures() {
    // 带 Slider 的 7 轴变体：不在可判定签名内
    let withSlider = XInputAxisOrder.map(
        usages: [0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36],
        logicalMins: [-32768, -32768, 0, -32768, -32768, 0, 0],
        logicalMaxs: [32767, 32767, 255, 32767, 32767, 255, 255],
        isXbox: true)
    check(withSlider == nil, "七轴（含 Slider）不套 XInput 映射")

    // Z 为对称量程（-32768…32767）：不是扳机签名，防把「Z=右摇杆」类 DirectInput 布局误判
    let symmetricZ = XInputAxisOrder.map(
        usages: direwolfUsages,
        logicalMins: [-32768, -32768, -32768, -32768, -32768, 0],
        logicalMaxs: [32767, 32767, 32767, 32767, 32767, 255],
        isXbox: true)
    check(symmetricZ == nil, "Z 对称量程（非扳机）不套 XInput 映射")

    // X 起始非负（异形描述器）：摇杆对称性不成立
    let asymmetricX = XInputAxisOrder.map(
        usages: direwolfUsages,
        logicalMins: [0, -32768, 0, -32768, -32768, 0],
        logicalMaxs: [255, 32767, 255, 32767, 32767, 255],
        isXbox: true)
    check(asymmetricX == nil, "X 非对称量程不套 XInput 映射")
}

func xinputAxisOrderApplyBoundsSafety() {
    guard let map = XInputAxisOrder.map(usages: direwolfUsages, logicalMins: direwolfMins,
                                        logicalMaxs: direwolfMaxs, isXbox: true) else {
        check(false, "映射应生成")
        return
    }
    // 描述器与轮询值数失衡（热插拔瞬间的防御路径）：越界槽位补 0 而非越界崩溃
    let short = XInputAxisOrder.apply(map, to: [0, 1])
    check(short == [0, -1, 0, 0, 0, 0], "短输入越界补 0（得到 \(short)）")
}
