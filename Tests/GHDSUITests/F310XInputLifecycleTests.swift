import Foundation
import DSCore

func f310XInputLifecycleTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    let box = F310XInputSnapshotBox()
    let active = F310XInputReport(
        axes: [1, 1, 1, 1, 1, 1], buttons: 1, pov: 90,
        triggerDepthL: 1, triggerDepthR: 1)
    box.update(active, at: 1)
    check(box.snapshot(at: 1.05) == active, "XInput 新鲜快照原样返回")
    check(box.snapshot(at: 1.101) == .neutral, "XInput 超过 100ms 无有效包立即归零")
    box.update(active, at: 2)
    check(box.snapshot(at: 2.01) == active, "XInput 后续有效包恢复输入")
    box.clear()
    check(box.snapshot(at: 2.02) == .neutral, "XInput 清理后保持中立")

    var lifecycle = F310XInputLifecycle()
    var changes = lifecycle.synchronize(present: [1])
    check(changes.start == [1] && changes.stop.isEmpty, "首次发现设备只启动一次")
    changes = lifecycle.synchronize(present: [1])
    check(changes.start.isEmpty && changes.stop.isEmpty, "同一设备重复枚举不重复启动")
    changes = lifecycle.synchronize(present: [1, 2])
    check(changes.start == [2] && changes.stop.isEmpty, "第二只设备独立启动")
    changes = lifecycle.synchronize(present: [2])
    check(changes.start.isEmpty && changes.stop == [1], "拔线只停止消失设备")
    changes = lifecycle.synchronize(present: [2])
    check(changes.start.isEmpty && changes.stop.isEmpty, "持续拔出不重复清理")
    lifecycle.startFailed(2)
    changes = lifecycle.synchronize(present: [2])
    check(changes.start == [2] && changes.stop.isEmpty, "打开失败后允许重试")
    _ = lifecycle.synchronize(present: [])

    let hid = HIDDeviceSnapshot(
        uniqueID: "hid-x", name: "Gamepad F310", vendorID: 0x046D, productID: 0xC21D,
        axes: [], axisUsages: [], buttons: 0, buttonCount: 0, povs: [], isXbox: true,
        mode: .xinput,
        polarity: GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: true),
        usbLocationID: 0x1234)
    let xinput = HIDDeviceSnapshot(
        uniqueID: "xinputusb-x", name: "Gamepad F310", vendorID: 0x046D, productID: 0xC21D,
        axes: [0, 0, -1, -1, 0, 0], axisUsages: [0x30, 0x31, 0x32, 0x35, 0x33, 0x34],
        buttons: 0, buttonCount: 11, povs: [-1], isXbox: true,
        mode: .xinput,
        polarity: GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: true),
        usbLocationID: 0x1234)
    let other = HIDDeviceSnapshot(
        uniqueID: "hid-other", name: "DualSense Wireless Controller", vendorID: 0x054C, productID: 0x0CE6,
        axes: [], axisUsages: [], buttons: 0, buttonCount: 0, povs: [], isXbox: false,
        mode: .directInput,
        polarity: GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: true),
        usbLocationID: 0x9999)
    let merged = GamepadDeviceCatalog.merged(hid: [hid, other], xinput: [xinput])
    check(merged.map(\.uniqueID) == ["hid-other", "xinputusb-x"],
          "同 location 优先 XInput reader，其他 HID 保留且不重复")
}
