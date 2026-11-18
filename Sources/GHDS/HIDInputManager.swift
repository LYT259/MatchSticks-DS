import Foundation
import IOKit
import IOKit.hid
import DSCore

// MARK: - HID 手柄枚举与轮询（IOHIDManager：可见所有 HID 设备，含 FRC 常用 Attack3 / Extreme 3D Pro）

struct HIDDeviceSnapshot: Sendable {
    var uniqueID: String
    var name: String
    var vendorID: Int
    var productID: Int
    var axes: [Float]
    var axisUsages: [UInt32]
    var buttons: UInt64
    var buttonCount: Int
    var povs: [Int16]
    var isXbox: Bool
}

@MainActor
final class HIDInputManager {
    static let shared = HIDInputManager()

    var onDevicesChanged: (() -> Void)?

    private var manager: IOHIDManager?
    private var deviceRecords: [DeviceRecord] = []

    struct DeviceRecord {
        let device: IOHIDDevice
        let uniqueID: String
        let name: String
        let vendorID: Int
        let productID: Int
        let axisElements: [(element: IOHIDElement, usage: UInt32, min: Int32, max: Int32)]
        let buttonElements: [(element: IOHIDElement, number: Int)]
        let hatElements: [(element: IOHIDElement, min: Int, max: Int)]
        let isXbox: Bool
        // 命中 XInput 六轴签名时非 nil：usage 序 → 官方 FRC DS XInput 轴序的重排映射
        // （含 Y 族符号翻转）。见 XInputAxisOrder 的布局实测说明。
        let xinputMap: [XInputAxisOrder.Slot]?
    }

    private init() {}

    func start() {
        guard manager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_MultiAxisController],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(m, matches as CFArray)

        let context = Unmanaged.passRetained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { context, _, _, _ in
            guard let context else { return }
            let mgr = Unmanaged<HIDInputManager>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                mgr.enumerateDevices()
                mgr.onDevicesChanged?()
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { context, _, _, _ in
            guard let context else { return }
            let mgr = Unmanaged<HIDInputManager>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                mgr.enumerateDevices()
                mgr.onDevicesChanged?()
            }
        }, context)

        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode!.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        enumerateDevices()
    }

    private func enumerateDevices() {
        guard let m = manager, let devices = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> else { return }
        var records: [DeviceRecord] = []
        for device in devices {
            guard let record = buildRecord(device) else { continue }
            records.append(record)
        }
        records.sort { $0.uniqueID < $1.uniqueID }
        deviceRecords = records
    }

    private func buildRecord(_ device: IOHIDDevice) -> DeviceRecord? {
        func prop(_ key: String) -> Any? { IOHIDDeviceGetProperty(device, key as CFString) }
        let name = (prop(kIOHIDProductKey) as? String) ?? "未命名设备"
        let vendorID = (prop(kIOHIDVendorIDKey) as? Int) ?? 0
        let productID = (prop(kIOHIDProductIDKey) as? Int) ?? 0
        let serial = (prop(kIOHIDSerialNumberKey) as? String) ?? ""
        let uniqueID = String(format: "%04x:%04x", vendorID, productID) + (serial.isEmpty ? ":\(name)" : ":\(serial)")

        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
            return nil
        }

        var axisElements: [(IOHIDElement, UInt32, Int32, Int32)] = []
        var buttonElements: [(IOHIDElement, Int)] = []
        var hatElements: [(IOHIDElement, Int, Int)] = []

        for element in elements {
            let type = IOHIDElementGetType(element)
            let usagePage = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            guard usagePage == kHIDPage_GenericDesktop || type == kIOHIDElementTypeInput_Button else { continue }

            if type == kIOHIDElementTypeInput_Button {
                // 只接受标准按钮：Button 页（0x09）或 GenericDesktop 上编号 ≤64 的按钮。
                // Consumer 页（0x0C，音量/媒体键）的 usage 是千位级功能码，若当作按钮号
                // 会使 buttonCount 虚高（实测可达 233），控制包 0x0C tag 声明的按键数
                // 与实际字节数便不再一致（协议层按 64 位截断，字节数却按原值算）。
                if (usagePage == kHIDPage_Button || usagePage == kHIDPage_GenericDesktop),
                   usage >= 1, usage <= 64 {
                    buttonElements.append((element, Int(usage)))
                }
            } else if usage == kHIDUsage_GD_Hatswitch {
                // 记录描述器的逻辑范围：八向帽在 macOS 上有 0…7 / 0…8 / 1…8 三种实现，
                // 中立态位置取决于此（见 JoystickData.povAngle 的说明）
                hatElements.append((element, IOHIDElementGetLogicalMin(element), IOHIDElementGetLogicalMax(element)))
            } else if type == kIOHIDElementTypeInput_Misc || type == kIOHIDElementTypeInput_Axis {
                // 常见轴 usage：X/Y/Z/Rx/Ry/Rz/Slider/Dial/Wheel
                let axisUsages: [UInt32] = [0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38]
                if axisUsages.contains(usage) {
                    axisElements.append((element, UInt32(usage), Int32(IOHIDElementGetLogicalMin(element)), Int32(IOHIDElementGetLogicalMax(element))))
                }
            }
        }

        guard !axisElements.isEmpty || !buttonElements.isEmpty else { return nil }
        axisElements.sort { $0.1 < $1.1 }
        buttonElements.sort { $0.1 < $1.1 }

        let isXbox = name.lowercased().contains("xbox") || vendorID == 0x045E
        let xinputMap = XInputAxisOrder.map(
            usages: axisElements.map { $0.1 },
            logicalMins: axisElements.map { $0.2 },
            logicalMaxs: axisElements.map { $0.3 },
            isXbox: isXbox
        )
        return DeviceRecord(
            device: device, uniqueID: uniqueID, name: name,
            vendorID: vendorID, productID: productID,
            axisElements: axisElements, buttonElements: buttonElements, hatElements: hatElements,
            isXbox: isXbox, xinputMap: xinputMap
        )
    }

    /// IOHIDDeviceGetValue 的 out 参数在 macOS 27 SDK 导入为非 Optional 指针
    /// （UnsafeMutablePointer<Unmanaged<IOHIDValue>>）：直接把 IUO 变量以 & 传入，
    /// Swift 会在调用前隐式强解包，nil 即 Trap 5——2026-11-14 F310 真机首崩点。
    /// 以 Optional 存储 + 内存重绑定传递（Optional<Unmanaged<T>> 与 Unmanaged<T>
    /// 同尺寸，指针 nil 位即 .none），失败/未写入一律返回 nil。
    private static func hidValue(_ device: IOHIDDevice, _ element: IOHIDElement) -> Unmanaged<IOHIDValue>? {
        var value: Unmanaged<IOHIDValue>? = nil
        let result = withUnsafeMutablePointer(to: &value) { ptr in
            ptr.withMemoryRebound(to: Unmanaged<IOHIDValue>.self, capacity: 1) {
                IOHIDDeviceGetValue(device, element, $0)
            }
        }
        return result == kIOReturnSuccess ? value : nil
    }

    /// 全量轮询（控制环对齐：每 UI 帧或每快照调用一次）
    func pollAll() -> [HIDDeviceSnapshot] {
        enumerateDeviceListIfNeeded()
        var result: [HIDDeviceSnapshot] = []
        for record in deviceRecords {
            var axes: [Float] = []
            for (element, _, minV, maxV) in record.axisElements {
                if let v = Self.hidValue(record.device, element) {
                    let raw = Int(IOHIDValueGetIntegerValue(v.takeUnretainedValue()))
                    let lo = Int(minV), hi = Int(maxV)
                    let span = hi - lo
                    let normalized = span == 0 ? 0.0 : (Double(raw - lo) / Double(span)) * 2 - 1
                    axes.append(Float(normalized))
                } else {
                    axes.append(0)
                }
            }

            var buttons: UInt64 = 0
            var highestButton = 0
            for (element, number) in record.buttonElements {
                if let v = Self.hidValue(record.device, element) {
                    if IOHIDValueGetIntegerValue(v.takeUnretainedValue()) != 0, number >= 1, number <= 64 {
                        buttons |= 1 << UInt64(number - 1)
                    }
                    highestButton = max(highestButton, number)
                }
            }

            var povs: [Int16] = []
            for (element, hatMin, hatMax) in record.hatElements {
                if let v = Self.hidValue(record.device, element) {
                    let raw = Int(IOHIDValueGetIntegerValue(v.takeUnretainedValue()))
                    povs.append(JoystickData.povAngle(raw: raw, logicalMin: hatMin, logicalMax: hatMax))
                } else {
                    povs.append(-1)
                }
            }

            // XInput 签名设备：重排为官方 FRC DS 的 XInput 轴序（含 Y 族符号翻转），
            // 机器人侧 XboxController 的轴索引才与官方 DS 直连时一致
            let emittedAxes: [Float]
            let emittedUsages: [UInt32]
            if let xinputMap = record.xinputMap {
                emittedAxes = XInputAxisOrder.apply(xinputMap, to: axes)
                emittedUsages = xinputMap.map { record.axisElements[$0.sourceIndex].usage }
            } else {
                emittedAxes = axes
                emittedUsages = record.axisElements.map(\.usage)
            }

            result.append(HIDDeviceSnapshot(
                uniqueID: record.uniqueID, name: record.name,
                vendorID: record.vendorID, productID: record.productID,
                axes: emittedAxes, axisUsages: emittedUsages,
                buttons: buttons, buttonCount: max(highestButton, record.buttonElements.count),
                povs: povs, isXbox: record.isXbox
            ))
        }
        return result
    }

    private var lastEnumeration = Date.distantPast
    private func enumerateDeviceListIfNeeded() {
        // 轮询路径轻量防抖：列表 0.5s 内不重建
        guard Date().timeIntervalSince(lastEnumeration) > 0.5 else { return }
        lastEnumeration = Date()
        guard let m = manager, let devices = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>,
              devices.count != deviceRecords.count else { return }
        enumerateDevices()
    }
}
