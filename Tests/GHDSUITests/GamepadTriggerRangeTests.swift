import Foundation
import DSCore

func gamepadTriggerRangeTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    func snapshot(skin: String, axes: [Float]) -> HIDDeviceSnapshot {
        let ps = skin == "ps4"
        return HIDDeviceSnapshot(
            uniqueID: skin, name: ps ? "Wireless Controller" : "Logitech Dual Action",
            vendorID: ps ? 0x054C : 0x046D, productID: ps ? 0x05C4 : 0xC216,
            axes: axes, axisUsages: [0x30, 0x31, 0x32, 0x35, 0x33, 0x34],
            buttons: 0, buttonCount: 14, povs: [-1], isXbox: !ps,
            mode: ps ? .directInput : .xinput,
            polarity: GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: true),
            usbLocationID: nil)
    }

    let ps = snapshot(skin: "ps4", axes: [0.1, -0.2, 0.3, 0.4, -1, 0])
        .normalizingAnalogTriggers(logicalMins: [0x30: 0, 0x31: 0, 0x32: 0, 0x35: 0, 0x33: 0, 0x34: 0])
    check(ps.axes == [0.1, -0.2, 0.3, 0.4, 0, 0.5],
          "PS4 扳机未按为 0、半按为 0.5，四摇杆轴保持不变（得到 \(ps.axes)）")
    check(ps.triggerAxisRange == .zeroToOne, "PS4 扳机轴记录实际输出量程")

    let xinput = snapshot(skin: "xinput", axes: [0, 0, -1, 1, 0, 0])
        .normalizingAnalogTriggers(logicalMins: [0x30: -32768, 0x31: -32768, 0x32: 0, 0x35: 0, 0x33: -32768, 0x34: -32768])
    check(xinput.axes == [0, 0, 0, 1, 0, 0], "XInput 扳机静止为 0、满按为 1")
    check(xinput.triggerAxisRange == .zeroToOne, "XInput 扳机轴记录实际输出量程")

    let unsignedStick = snapshot(skin: "ps4", axes: [0.1, -0.2, 0.3, -1, 0, 0.4])
        .normalizingAnalogTriggers(logicalMins: [0x30: -128, 0x31: -128, 0x32: -128, 0x35: -128, 0x33: -128, 0x34: -128])
    check(unsignedStick.axes == [0.1, -0.2, 0.3, -1, 0, 0.4] && unsignedStick.triggerAxisRange == .signed,
          "非无符号 HID 量程不得臆造扳机零点")

    let state = GamepadLayout.layout(for: .dualshock4).state(for: GamepadSample(
        axes: [0, 0, 0, 0, 0, 1], axisUsages: [0x30, 0x31, 0x32, 0x35, 0x33, 0x34],
        triggerAxisRange: .zeroToOne))
    check(state.triggerL.depth == 0 && !state.triggerL.pressed, "0…1 扳机静止时不点亮")
    check(state.triggerR.depth == 1 && state.triggerR.pressed, "0…1 扳机满按深度为 1")
    let half = GamepadLayout.layout(for: .direwolf4).state(for: GamepadSample(
        axes: [0, 0, 0.5, 0, 0, 0], axisUsages: [0x30, 0x31, 0x32, 0x35, 0x33, 0x34],
        triggerAxisRange: .zeroToOne))
    check(half.triggerL.depth == 0.5 && half.triggerL.pressed, "0…1 扳机保留半按行程")
}
