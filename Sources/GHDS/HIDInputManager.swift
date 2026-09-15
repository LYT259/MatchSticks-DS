import Foundation
import IOKit
import IOKit.hid

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
        let hatElements: [IOHIDElement]
        let isXbox: Bool
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
        let uniqueID = String(format: "%04x:%04x", vendorID, productID) + (serial.isEmpty ? ":\(name.hashValue)" : ":\(serial)")

        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
            return nil
        }

        var axisElements: [(IOHIDElement, UInt32, Int32, Int32)] = []
        var buttonElements: [(IOHIDElement, Int)] = []
        var hatElements: [IOHIDElement] = []

        for element in elements {
            let type = IOHIDElementGetType(element)
            let usagePage = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            guard usagePage == kHIDPage_GenericDesktop || type == kIOHIDElementTypeInput_Button else { continue }

            if type == kIOHIDElementTypeInput_Button {
                buttonElements.append((element, Int(usage)))
            } else if usage == kHIDUsage_GD_Hatswitch {
                hatElements.append(element)
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
        return DeviceRecord(
            device: device, uniqueID: uniqueID, name: name,
            vendorID: vendorID, productID: productID,
            axisElements: axisElements, buttonElements: buttonElements, hatElements: hatElements,
            isXbox: isXbox
        )
    }

    /// 全量轮询（控制环对齐：每 UI 帧或每快照调用一次）
    func pollAll() -> [HIDDeviceSnapshot] {
        enumerateDeviceListIfNeeded()
        var result: [HIDDeviceSnapshot] = []
        for record in deviceRecords {
            var axes: [Float] = []
            for (element, _, minV, maxV) in record.axisElements {
                var value: Unmanaged<IOHIDValue>!
                let ok = IOHIDDeviceGetValue(record.device, element, &value)
                if ok == kIOReturnSuccess, let v = value {
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
                var value: Unmanaged<IOHIDValue>!
                if IOHIDDeviceGetValue(record.device, element, &value) == kIOReturnSuccess, let v = value {
                    if IOHIDValueGetIntegerValue(v.takeUnretainedValue()) != 0, number >= 1, number <= 64 {
                        buttons |= 1 << UInt64(number - 1)
                    }
                    highestButton = max(highestButton, number)
                }
            }

            var povs: [Int16] = []
            for element in record.hatElements {
                var value: Unmanaged<IOHIDValue>!
                if IOHIDDeviceGetValue(record.device, element, &value) == kIOReturnSuccess, let v = value {
                    let raw = Int(IOHIDValueGetIntegerValue(v.takeUnretainedValue()))
                    povs.append(raw >= 0 && raw <= 7 ? Int16(raw * 45) : -1)
                } else {
                    povs.append(-1)
                }
            }

            result.append(HIDDeviceSnapshot(
                uniqueID: record.uniqueID, name: record.name,
                vendorID: record.vendorID, productID: record.productID,
                axes: axes, axisUsages: record.axisElements.map(\.usage),
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
