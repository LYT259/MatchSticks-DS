// MARK: 手柄造型档案：识别 + 语义映射 + 容错（皮肤视图的数据源回归）
//
// 轴序样本锚定 2026-11-18 真机实测（XInputAxisOrder.swift 头注）：
// 冰原狼 4 USB（自报 045E:028E）经归一后 usage 序 [X, Y, Z, Rz, Rx, Ry] =
// [左X, 左Y(上=-1), LT, RT, 右X, 右Y(上=-1)]。按键号按公开惯例落种子，待实测核对。

import Foundation
import DSCore

// MARK: 识别

func gamepadProfileDetectionTests() {
    // F310：X/D 两档 PID + Dual Action 名称（D 档自报名，2026-11-18 台架）
    check(GamepadProfile.detect(vendorID: 0x046D, productID: 0xC216, name: "Logitech Dual Action") == .f310, "F310 D 档 PID C216")
    check(GamepadProfile.detect(vendorID: 0x046D, productID: 0xC21D, name: "Gamepad F310") == .f310, "F310 X 档 PID C21D")
    check(GamepadProfile.detect(vendorID: 0x046D, productID: 0xC218, name: "Logitech Rumblepad 2") == .generic, "F510 D 档 C218 不误标为 F310")
    check(GamepadProfile.detect(vendorID: 0x046D, productID: 0xC215, name: "Logitech Extreme 3D Pro") == .extreme3DPro, "Extreme 3D Pro C215")
    check(GamepadProfile.detect(vendorID: 0x046D, productID: 0x9999, name: "Logitech Dual Action") == .f310, "Dual Action 名称识别")

    // 冰原狼 4：Xbox 360 克隆签名 + 名称救回（名称优先于 VID/PID）
    check(GamepadProfile.detect(vendorID: 0x045E, productID: 0x028E, name: "Xbox 360 Controller") == .xbox360, "045E:028E 签名 → Xbox 360")
    check(GamepadProfile.detect(vendorID: 0x045E, productID: 0x1234, name: "Flydigi Direwolf 4") == .direwolf4, "名称含 Flydigi 优先")
    check(GamepadProfile.detect(vendorID: 0x045E, productID: 0x02D1, name: "Xbox One Controller") == .xboxOne, "Xbox One 有线 PID")
    check(GamepadProfile.detect(vendorID: 0x045E, productID: 0x02E0, name: "Xbox One S Controller") == .xboxOne, "Xbox One S 蓝牙 PID")
    check(GamepadProfile.detect(vendorID: 0x054C, productID: 0x0268, name: "PLAYSTATION(R)3 Controller") == .dualshock3, "DualShock 3 PID")

    // DualShock 4：不能被 Sony Wireless Controller 名称误判成 DualSense
    check(GamepadProfile.detect(vendorID: 0x054C, productID: 0x05C4, name: "Wireless Controller") == .dualshock4, "DualShock 4 V1 PID")
    check(GamepadProfile.detect(vendorID: 0x054C, productID: 0x09CC, name: "DualShock 4 Wireless Controller") == .dualshock4, "DualShock 4 V2 PID 与名称")

    // DualSense：PID + 名称
    check(GamepadProfile.detect(vendorID: 0x054C, productID: 0x0CE6, name: "DualSense Wireless Controller") == .dualsense, "DualSense PID")
    check(GamepadProfile.detect(vendorID: 0x054C, productID: 0x0DF2, name: "DualSense Edge") == .dualsense, "DualSense Edge PID")

    // Xbox Series：USB/BT PID 族
    check(GamepadProfile.detect(vendorID: 0x045E, productID: 0x0B12, name: "Xbox Series X Controller") == .xboxSeries, "Series USB PID")
    check(GamepadProfile.detect(vendorID: 0x045E, productID: 0x0B13, name: "Xbox Series X Controller") == .xboxSeries, "Series BT PID")

    // 未识别 → 通用
    check(GamepadProfile.detect(vendorID: 0x1234, productID: 0x5678, name: "Cool Pad") == .generic, "未知 VID/PID → 通用")

    // 生效皮肤：覆盖优先于识别
    let sample = GamepadSample(name: "Cool Pad", vendorID: 0x1234, productID: 0x5678,
                               axes: [], axisUsages: [])
    check(GamepadProfile.effectiveSkin(sample: sample, override: nil) == .generic, "无覆盖 → 识别结果")
    check(GamepadProfile.effectiveSkin(sample: sample, override: .dualsense) == .dualsense, "覆盖优先")

    check(GamepadProfile.isSelected(nil, override: nil), "自动识别时只勾自动项")
    check(!GamepadProfile.isSelected(.f310, override: nil), "自动识别时不得勾当前生效型号")
    check(GamepadProfile.isSelected(.f310, override: .f310), "手动 F310 时勾 F310")
    check(!GamepadProfile.isSelected(nil, override: .f310), "手动时不得勾自动项")

    // 布局表完备性：每款映射表引用的按键号均在 1…64
    for skin in GamepadSkin.allCases {
        let layout = GamepadLayout.layout(for: skin)
        check(layout.mappedNumbers.isSubset(of: 1...64), "\(skin.rawValue) 映射按键号均在 1…64")
    }
}

func gamepadFamilySupportTests() {
    check(GamepadProfile.preferredSkin(for: .dualshock3) == .dualsense, "PS3 默认展示最新 DualSense")
    check(GamepadProfile.preferredSkin(for: .dualshock4) == .dualsense, "PS4 默认展示最新 DualSense")
    check(GamepadProfile.preferredSkin(for: .xbox360) == .xboxSeries, "Xbox 360 默认展示最新 Series")
    check(GamepadProfile.preferredSkin(for: .xboxOne) == .xboxSeries, "Xbox One 默认展示最新 Series")
    check(GamepadProfile.preferredSkin(for: .dualsense) == .dualsense, "PS5 保持自身外观")
    check(GamepadProfile.preferredSkin(for: .xboxSeries) == .xboxSeries, "Xbox Series 保持自身外观")
    check(GamepadProfile.preferredSkin(for: .f310) == .f310, "罗技不被系列规则影响")
    check(GamepadProfile.preferredSkin(for: .direwolf4) == .direwolf4, "冰原狼保留专属外观")

    let ps4 = GamepadSample(name: "Wireless Controller", vendorID: 0x054C, productID: 0x09CC,
                            axes: [], axisUsages: [])
    check(GamepadProfile.effectiveSkin(sample: ps4, override: nil) == .dualsense,
          "PS4 自动使用最新 PS 外观")
    check(GamepadProfile.effectiveSkin(sample: ps4, override: .dualshock4) == .dualshock4,
          "手动仍可指定 PS4 外观")
    check(!GamepadSkin.selectableSkins.contains(.dualshock3) &&
          !GamepadSkin.selectableSkins.contains(.dualshock4) &&
          !GamepadSkin.selectableSkins.contains(.xbox360) &&
          !GamepadSkin.selectableSkins.contains(.xboxOne),
          "选择器只展示各家族最新外观，旧型号仍保留在映射层")
    check(GamepadSkin.selectableSkins.contains(.extreme3DPro), "选择器包含 Extreme 3D Pro 飞行摇杆")
}

// MARK: 冰原狼 4（XInput 归一后语义；轴=已核查，按键=惯例种子待实测）

/// 归一后 usage 序（XInputAxisOrder 重排）：[X, Y, Z, Rz, Rx, Ry]
private let direwolfUsages: [UInt32] = [0x30, 0x31, 0x32, 0x35, 0x33, 0x34]

private func direwolfLayout() -> GamepadLayout { GamepadLayout.layout(for: .direwolf4) }

func gamepadProfileDirewolfStateTests() {
    let layout = direwolfLayout()

    // 双摇杆 + 双扳机全量程：左摇杆右上象限、右摇杆左下象限、LT 半按、RT 按满
    let sample = GamepadSample(
        name: "Xbox 360 Controller", vendorID: 0x045E, productID: 0x028E,
        axes: [0.6, -0.8, 0.0, 1.0, -0.4, 0.9],
        axisUsages: direwolfUsages,
        buttons: (1 << 0) | (1 << 4) | (1 << 8) | (1 << 9),  // A(1) LB(5) Guide(9) L3(10)
        povs: [45], mode: .xinput, polarity: GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: true))
    let s = layout.state(for: sample)

    check(s.leftStick.x == 0.6, "左摇杆 X 取自 usage X（得到 \(s.leftStick.x)）")
    check(s.leftStick.yUp == 0.8, "左摇杆 Y 上=-1 翻转为 yUp=+0.8（得到 \(s.leftStick.yUp)）")
    check(s.leftStick.pressed, "L3=按键10 → 左摇杆按下")
    check(s.rightStick.x == -0.4, "右摇杆 X 取自 Rx（usage 重排后仍在位）")
    check(s.rightStick.yUp == -0.9, "右摇杆 Y 上=-1 → yUp=-0.9（下）")
    check(abs((s.triggerL.depth ?? -1) - 0.5) < 1e-6, "LT 归一 0 → 深度 0.5（得到 \(String(describing: s.triggerL.depth))）")
    check(abs((s.triggerR.depth ?? -1) - 1.0) < 1e-6, "RT 归一 +1 → 深度 1.0")
    check(s.triggerL.pressed, "LT 深度 0.5 → 按压态")
    check(s.face[.south] == true, "按键1 → A（南）")
    check(s.face[.north] == false && s.face[.east] == false && s.face[.west] == false, "其余面键未按下")
    check(s.shoulderL && !s.shoulderR, "按键5 → LB")
    check(s.guide, "按键9 → Guide")
    check(s.dpad == [.up, .right], "POV 45° → 上+右")
    check(s.unmapped.isEmpty, "全部已映射按键，无未映射")

    // 中立态：一切归零（扳机静止 -1 → 深度 0、未按压）
    let neutral = layout.state(for: GamepadSample(
        name: "Xbox 360 Controller", vendorID: 0x045E, productID: 0x028E,
        axes: [0, 0, -1, -1, 0, 0], axisUsages: direwolfUsages,
        buttons: 0, povs: [-1], mode: .xinput, polarity: GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: true)))
    check(neutral.leftStick.x == 0 && neutral.leftStick.yUp == 0, "中立左摇杆归零")
    check(neutral.triggerL.pressed == false && neutral.triggerL.depth == 0, "中立 LT 深度 0 未按压")
    check(neutral.dpad.isEmpty, "中立无方向")
    check(neutral.unmapped.isEmpty, "中立无未映射")

    // 未映射自揭示：按键 15（映射表外）按下必须浮出
    let withExtra = layout.state(for: GamepadSample(
        name: "Xbox 360 Controller", vendorID: 0x045E, productID: 0x028E,
        axes: [0, 0, -1, -1, 0, 0], axisUsages: direwolfUsages,
        buttons: 1 << 14, povs: [-1], mode: .xinput, polarity: GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: true)))
    check(withExtra.unmapped == [15], "按键 15 落入未映射（得到 \(withExtra.unmapped)）")

    // POV 其余方向
    func povDirections(_ angle: Int16) -> Set<GamepadDirection> {
        layout.state(for: GamepadSample(axes: [], axisUsages: [], povs: [angle])).dpad
    }
    check(povDirections(0) == [.up], "POV 0° → 上")
    check(povDirections(90) == [.right], "POV 90° → 右")
    check(povDirections(135) == [.right, .down], "POV 135° → 右+下")
    check(povDirections(180) == [.down], "POV 180° → 下")
    check(povDirections(225) == [.down, .left], "POV 225° → 下+左")
    check(povDirections(315) == [.up, .left], "POV 315° → 上+左")
}

// MARK: F310（macOS 实际可见的 D 档：X/Y/Z/Rz 四轴、数字扳机、12 键）

func gamepadProfileF310StateTests() {
    let layout = GamepadLayout.layout(for: .f310, mode: .directInput)
    let polarity = GamepadProfile.displayPolarity(vendorID: 0x046D, productID: 0xC216,
                                                  name: "Logitech Dual Action", xinputNormalized: false)

    let s = layout.state(for: GamepadSample(
        name: "Logitech Dual Action", vendorID: 0x046D, productID: 0xC216,
        axes: [0.75, -0.8, -0.5, 0.9],
        axisUsages: [0x30, 0x31, 0x32, 0x35],
        buttons: (1 << 6) | (1 << 7),
        povs: [270], mode: .directInput, polarity: polarity))
    check(s.leftStick.x == -0.75 && s.leftStick.yUp == 0.8,
          "F310 D 左摇杆：原始 X 正号显示左、Y 负号显示上（得到 \(s.leftStick.x), \(s.leftStick.yUp)）")
    check(s.rightStick.x == 0.5 && s.rightStick.yUp == -0.9,
          "F310 D 右摇杆：Z/Rz 同时修正 X/Y 方向（得到 \(s.rightStick.x), \(s.rightStick.yUp)）")
    check(s.triggerL.pressed && s.triggerL.depth == nil, "LT 数字扳机：按压、无伪造深度")
    check(s.triggerR.pressed && s.triggerR.depth == nil, "RT 数字扳机：按压、无伪造深度")
    check(s.dpad == [.left], "POV 270° → 左")

    let expectedFaces: [(number: Int, position: GamepadFace)] = [
        (1, .west), (2, .south), (3, .east), (4, .north),
    ]
    for item in expectedFaces {
        let state = layout.state(for: GamepadSample(
            name: "Logitech Dual Action", vendorID: 0x046D, productID: 0xC216,
            axes: [0, 0, 0, 0], axisUsages: [0x30, 0x31, 0x32, 0x35],
            buttons: 1 << (item.number - 1), povs: [-1], mode: .directInput, polarity: polarity))
        for face in GamepadFace.allCases {
            check(state.face[face] == (face == item.position),
                  "F310 D 按键 \(item.number) 只点亮 \(item.position)；检查 \(face)")
        }
    }
}

func gamepadProfileF310XInputStateTests() {
    let layout = GamepadLayout.layout(for: .f310, mode: .xinput)
    let state = layout.state(for: GamepadSample(
        name: "Gamepad F310", vendorID: 0x046D, productID: 0xC21D,
        axes: [0.5, -0.75, 0, 1, -0.25, 0.5],
        axisUsages: [0x30, 0x31, 0x32, 0x35, 0x33, 0x34],
        buttons: (1 << 0) | (1 << 8) | (1 << 10),
        povs: [45], mode: .xinput,
        polarity: GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: true)))
    check(state.face[.south] == true && state.face[.north] == false, "F310 X 按钮1 → A")
    check(state.leftStick.pressed && state.guide, "F310 X L3=按钮9、Guide=按钮11")
    check(state.leftStick.x == 0.5 && state.leftStick.yUp == 0.75, "F310 X 左摇杆方向")
    check(state.rightStick.x == -0.25 && state.rightStick.yUp == -0.5, "F310 X 右摇杆方向")
    check(state.triggerL.depth == 0.5 && state.triggerR.depth == 1, "F310 X LT/RT 使用真实模拟量")
    check(state.dpad == [.up, .right], "F310 X POV 方向")
}

func gamepadProfileExtreme3DProStateTests() {
    let layout = GamepadLayout.layout(for: .extreme3DPro, mode: .directInput)
    let polarity = GamepadProfile.displayPolarity(vendorID: 0x046D, productID: 0xC215,
                                                  name: "Logitech Extreme 3D Pro", xinputNormalized: false)
    let state = layout.state(for: GamepadSample(
        name: "Logitech Extreme 3D Pro", vendorID: 0x046D, productID: 0xC215,
        axes: [0.5, -0.75, 0.25, 0],
        axisUsages: [0x30, 0x31, 0x32, 0x36],
        buttons: 0xFFF, povs: [270], mode: .directInput, polarity: polarity))
    check(state.leftStick.x == 0.5 && state.leftStick.yUp == 0.75, "Extreme 3D Pro 主摇杆 X/Y")
    check(state.rightStick.x == 0.25 && state.rightStick.yUp == 0,
          "Extreme 3D Pro Z 扭转只进入右侧 X，不伪造右摇杆 Y")
    check(state.triggerR.depth == 0.5 && state.triggerR.pressed, "Extreme 3D Pro Slider 保留模拟油门")
    check(state.triggerL.pressed && state.triggerL.depth == nil, "Extreme 3D Pro 快速扳机按钮 1 为数字态")
    check(state.face[.north] == true && state.face[.east] == true &&
          state.face[.south] == true && state.face[.west] == true,
          "Extreme 3D Pro 拇指键与顶部按钮 2…5")
    check(state.shoulderL && state.shoulderR && state.back && state.start && state.guide,
          "Extreme 3D Pro 按钮 6…10 均有独立位置")
    check(state.extras[.share] == true && state.extras[.backR] == true,
          "Extreme 3D Pro 按钮 11/12 均有独立位置")
    check(state.dpad == [.left], "Extreme 3D Pro POV 帽")
    check(state.unmapped.isEmpty, "Extreme 3D Pro 全部 12 按钮均已映射，无遗漏")
}

// MARK: DualSense（模拟扳机优先、数字兜底）与通用款

func gamepadProfileDualsenseStateTests() {
    let layout = GamepadLayout.layout(for: .dualsense)

    // 轴形态 A（待实测种子）：扳机在 Rx/Ry
    let analog = layout.state(for: GamepadSample(
        name: "DualSense Wireless Controller", vendorID: 0x054C, productID: 0x0CE6,
        axes: [0, 0, 0, 0, 1.0, -1.0],   // Rx=L2 按满，Ry=R2 静止
        axisUsages: [0x30, 0x31, 0x32, 0x35, 0x33, 0x34],
        buttons: 1 << 0,                 // □(1)
        povs: [-1]))
    check(abs((analog.triggerL.depth ?? -1) - 1.0) < 1e-6, "L2 轴 Rx 按满 → 深度 1.0")
    check(analog.triggerR.depth == 0 && !analog.triggerR.pressed, "R2 轴静止 → 深度 0")
    check(analog.face[.west] == true, "按键1 → □（西）")

    // 轴形态 B（模拟缺失）：退回数字扳机 7/8；PS=13、触控板=14
    let digital = layout.state(for: GamepadSample(
        name: "DualSense Wireless Controller", vendorID: 0x054C, productID: 0x0CE6,
        axes: [0, 0, 0, 0], axisUsages: [0x30, 0x31, 0x32, 0x35],
        buttons: (1 << 6) | (1 << 12) | (1 << 13),  // 7(L2) 13(PS) 14(触控板)
        povs: [-1]))
    check(digital.triggerL.pressed && digital.triggerL.depth == nil, "无模拟轴时 L2 走按键 7")
    check(digital.guide, "按键13 → PS")
    check(digital.extras[.touchpad] == true, "按键14 → 触控板")
}

func gamepadProfileDualshock4StateTests() {
    let polarity = GamepadProfile.displayPolarity(
        vendorID: 0x054C, productID: 0x09CC,
        name: "Wireless Controller", xinputNormalized: false)
    check(!polarity.xRightIsNegative && polarity.yUpIsNegative, "DualShock 4 与 DualSense 使用相同 Y 方向约定")

    let state = GamepadLayout.layout(for: .dualshock4, mode: .directInput).state(for: GamepadSample(
        name: "Wireless Controller", vendorID: 0x054C, productID: 0x09CC,
        axes: [0.25, -0.8, -0.5, 0.9, 0, 1],
        axisUsages: [0x30, 0x31, 0x32, 0x35, 0x33, 0x34],
        buttons: (1 << 12) | (1 << 13), povs: [45], mode: .directInput, polarity: polarity))
    check(state.leftStick.x == 0.25 && state.leftStick.yUp == 0.8, "DualShock 4 左摇杆方向")
    check(state.rightStick.x == -0.5 && state.rightStick.yUp == -0.9, "DualShock 4 右摇杆方向")
    check(state.guide && state.extras[.touchpad] == true, "DualShock 4 PS=13、触控板=14")
    check(state.triggerR.depth == 1 && state.triggerR.pressed, "DualShock 4 模拟 R2")
    check(state.dpad == [.up, .right], "DualShock 4 POV")
}

func gamepadDirectionAndPolarityTests() {
    let dualsensePolarity = GamepadProfile.displayPolarity(
        vendorID: 0x054C, productID: 0x0CE6,
        name: "DualSense Wireless Controller", xinputNormalized: false)
    check(!dualsensePolarity.xRightIsNegative && dualsensePolarity.yUpIsNegative,
          "DualSense 原始样本 X 右正、Y 上负")

    let state = GamepadLayout.layout(for: .dualsense, mode: .directInput).state(for: GamepadSample(
        name: "DualSense Wireless Controller", vendorID: 0x054C, productID: 0x0CE6,
        axes: [0.25, -0.8, -0.5, 0.9, 0, 0],
        axisUsages: [0x30, 0x31, 0x32, 0x35, 0x33, 0x34],
        povs: [-1], mode: .directInput, polarity: dualsensePolarity))
    check(state.leftStick.x == 0.25 && state.leftStick.yUp == 0.8,
          "DualSense 左摇杆 X 不变、Y 上负转显示上正")
    check(state.rightStick.x == -0.5 && state.rightStick.yUp == -0.9,
          "DualSense 右摇杆 X 不变、Y 下正转显示下负")

    let xinputPolarity = GamepadProfile.displayPolarity(
        vendorID: 0x045E, productID: 0x028E,
        name: "Xbox 360 Controller", xinputNormalized: true)
    check(!xinputPolarity.xRightIsNegative && xinputPolarity.yUpIsNegative,
          "XInput 归一样本保持 X 右正、Y 上负")

    let genericPolarity = GamepadProfile.displayPolarity(
        vendorID: 0x1234, productID: 0x5678, name: "Cool Pad", xinputNormalized: false)
    check(!genericPolarity.xRightIsNegative && !genericPolarity.yUpIsNegative,
          "通用 HID 保持既有方向约定")
}

func gamepadProfileGenericStateTests() {
    let layout = GamepadLayout.layout(for: .generic)
    let s = layout.state(for: GamepadSample(
        name: "Cool Pad", vendorID: 0x1234, productID: 0x5678,
        axes: [0, 0, 0, 0], axisUsages: [0x30, 0x31, 0x32, 0x35],
        buttons: (1 << 2) | (1 << 14),  // 3(南) 15(表外)
        povs: [90]))
    check(s.face[.south] == true, "通用款按键3 → 南")
    check(s.dpad == [.right], "通用款 POV 90° → 右")
    check(s.unmapped == [15], "通用款按键15 未映射")
}

// MARK: 容错（外部输入不可信：长度失衡/非有限值/越界 POV 下标）

func gamepadProfileRobustnessTests() {
    let layout = direwolfLayout()

    // usage 与轴值长度失衡（热插拔瞬间）：取不到的轴回落 0，不越界
    let mismatch = layout.state(for: GamepadSample(
        axes: [0.5], axisUsages: direwolfUsages, povs: []))
    check(mismatch.leftStick.x == 0.5 && mismatch.leftStick.yUp == 0, "失衡数组安全回落")
    check(mismatch.rightStick.x == 0 && mismatch.rightStick.yUp == 0, "缺失右摇杆轴回落 0")

    // 非有限值（NaN/Inf）钳到 0 而非透传
    let nan = layout.state(for: GamepadSample(
        axes: [Float.nan, .infinity, 0, -1, 0, 0], axisUsages: direwolfUsages))
    check(nan.leftStick.x == 0 && nan.leftStick.yUp == 0, "NaN/Inf 轴值钳到 0")

    // POV 下标越界（povs 为空但表配 POV 0）：无方向、不崩
    check(layout.state(for: GamepadSample(axes: [], axisUsages: [])).dpad.isEmpty, "空 povs 无方向")

    // 未识别款（generic）也吃同一套容错
    _ = GamepadLayout.layout(for: .generic).state(for: GamepadSample(axes: [], axisUsages: []))
    check(true, "通用款空样本可求状态")
}
