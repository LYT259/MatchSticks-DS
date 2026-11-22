import Foundation

func f310XInputReportTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    var neutralBytes = [UInt8](repeating: 0, count: 20)
    neutralBytes[1] = 0x14
    guard let neutral = F310XInputReport.parse(neutralBytes) else {
        check(false, "XInput 中立包可解析")
        return
    }
    check(neutral.axes == [0, 0, 0, 0, 0, 0], "XInput 中立轴与双扳机静止值均为 0")
    check(neutral.triggerDepthL == 0 && neutral.triggerDepthR == 0, "XInput 中立扳机深度为 0")
    check(neutral.buttons == 0 && neutral.pov == -1, "XInput 中立按钮与 POV")

    var allButtons = neutralBytes
    allButtons[2] = 0xF0
    allButtons[3] = 0xF7
    let pressed = F310XInputReport.parse(allButtons)
    check(pressed?.buttons == 0x7FF, "XInput A/B/X/Y/LB/RB/Back/Start/L3/R3/Guide 全部映射到按钮 1…11")

    let povCases: [(UInt8, Int16)] = [
        (0, -1), (1, 0), (5, 315), (4, 270), (6, 225),
        (2, 180), (10, 135), (8, 90), (9, 45),
    ]
    for (raw, angle) in povCases {
        var bytes = neutralBytes
        bytes[2] = raw
        check(F310XInputReport.parse(bytes)?.pov == angle, "XInput POV 原始 \(raw) → \(angle)")
    }

    var analog = neutralBytes
    analog[4] = 128
    analog[5] = 255
    analog[6] = 0x00; analog[7] = 0x80
    analog[8] = 0xFF; analog[9] = 0x7F
    analog[10] = 0xFF; analog[11] = 0x7F
    analog[12] = 0x00; analog[13] = 0x40
    guard let axes = F310XInputReport.parse(analog) else {
        check(false, "XInput 模拟量包可解析")
        return
    }
    check(axes.axes[0] == -1, "XInput LX 负满量程")
    check(axes.axes[1] == -1, "XInput LY 上正原始值转为 FRC 上负")
    check(axes.axes[4] == 1, "XInput RX 正满量程")
    check(abs(axes.axes[5] + 0.5) < 2e-5, "XInput RY 归一后取反（得到 \(axes.axes[5])）")
    check(abs(axes.triggerDepthL - (128.0 / 255.0)) < 1e-6, "XInput LT 保留真实中间深度")
    check(axes.triggerDepthR == 1 && axes.axes[3] == 1, "XInput RT 满行程")
    check(abs(axes.axes[2] - (128.0 / 255.0)) < 1e-6, "XInput LT 输出轴与深度一致")

    check(F310XInputReport.parse(Array(neutralBytes.prefix(19))) == nil, "XInput 短包拒绝")
    var wrongType = neutralBytes
    wrongType[0] = 1
    check(F310XInputReport.parse(wrongType) == nil, "XInput 未知 report type 拒绝")
    var wrongLength = neutralBytes
    wrongLength[1] = 0x13
    check(F310XInputReport.parse(wrongLength) == nil, "XInput 长度标记不匹配拒绝")
    var invalidPOV = neutralBytes
    invalidPOV[2] = 0x03
    check(F310XInputReport.parse(invalidPOV) == nil, "XInput 相反 POV 同时置位拒绝")
}
