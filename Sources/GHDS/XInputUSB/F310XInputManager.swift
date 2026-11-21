import Foundation
import IOKit
import IOUSBHost
import DSCore

@MainActor
final class F310XInputManager {
    static let shared = F310XInputManager()

    var onDevicesChanged: (() -> Void)?
    var onError: ((String) -> Void)?

    private var started = false
    private var lifecycle = F310XInputLifecycle()
    private var sessions: [UInt32: F310XInputSession] = [:]
    private var lastEnumeration = Date.distantPast

    func start() {
        guard !started else { return }
        started = true
        synchronize()
    }

    func stop() {
        started = false
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        _ = lifecycle.synchronize(present: [])
    }

    func pollAll() -> [HIDDeviceSnapshot] {
        if started, Date().timeIntervalSince(lastEnumeration) > 0.5 {
            synchronize()
        }
        return sessions.values.map { $0.snapshot() }.sorted { $0.uniqueID < $1.uniqueID }
    }

    private func synchronize() {
        lastEnumeration = Date()
        let services = matchingInterfaces()
        let changes = lifecycle.synchronize(present: Set(services.keys))
        var changed = false
        for locationID in changes.stop {
            sessions.removeValue(forKey: locationID)?.stop()
            changed = true
        }
        for locationID in changes.start {
            guard let service = services[locationID] else { continue }
            do {
                sessions[locationID] = try F310XInputSession(
                    locationID: locationID, service: service,
                    onEnded: { [weak self] in
                        Task { @MainActor in self?.sessionEnded(locationID) }
                    },
                    onError: { [weak self] message in
                        Task { @MainActor in self?.onError?(message) }
                    })
                changed = true
            } catch {
                lifecycle.startFailed(locationID)
                onError?("F310 XInput 打开失败（location \(String(locationID, radix: 16))）：\(error)")
            }
            IOObjectRelease(service)
        }
        for (locationID, service) in services where !changes.start.contains(locationID) {
            IOObjectRelease(service)
        }
        if changed { onDevicesChanged?() }
    }

    private func sessionEnded(_ locationID: UInt32) {
        sessions.removeValue(forKey: locationID)
        lifecycle.startFailed(locationID)
        onDevicesChanged?()
    }

    private func matchingInterfaces() -> [UInt32: io_service_t] {
        guard let matching = IOServiceMatching("IOUSBInterface") else { return [:] }
        func set(_ key: IOUSBHostMatchingPropertyKey, _ value: NSNumber) {
            CFDictionarySetValue(
                matching,
                Unmanaged.passUnretained(key as NSString).toOpaque(),
                Unmanaged.passUnretained(value).toOpaque())
        }
        set(.vendorID, NSNumber(value: 0x046D))
        set(.productID, NSNumber(value: 0xC21D))
        set(.interfaceNumber, NSNumber(value: 0))

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }
        var result: [UInt32: io_service_t] = [:]
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            guard let number = IORegistryEntryCreateCFProperty(
                service, IOUSBHostPropertyKeyLocationID as CFString, kCFAllocatorDefault, 0
            ).takeRetainedValue() as? NSNumber else {
                IOObjectRelease(service)
                continue
            }
            result[number.uint32Value] = service
        }
        return result
    }
}

private enum F310XInputSessionError: Error {
    case missingInterruptPair
    case invalidDescriptor
    case incompleteTransfer
}

private final class F310XInputSession {
    private let locationID: UInt32
    private let onEnded: () -> Void
    private let onError: (String) -> Void
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt32>()
    private let snapshotBox = F310XInputSnapshotBox()

    private var interface: IOUSBHostInterface?
    private var inputPipe: IOUSBHostPipe?
    private var outputPipe: IOUSBHostPipe?
    private var active = false
    private var initIndex = 0

    private let initPackets: [[UInt8]] = [
        [0x05, 0x20, 0x00, 0x01, 0x00],
        [0x0A, 0x20, 0x00, 0x03, 0x00, 0x01, 0x14],
        [0x06, 0x20, 0x00, 0x02, 0x01, 0x00],
    ]

    init(locationID: UInt32, service: io_service_t,
         onEnded: @escaping () -> Void, onError: @escaping (String) -> Void) throws {
        self.locationID = locationID
        self.onEnded = onEnded
        self.onError = onError
        queue = DispatchQueue(label: "org.ghfrc.driverstation.f310-xinput.\(locationID)")
        queue.setSpecific(key: queueKey, value: locationID)
        var openError: Error?
        queue.sync {
            do {
                let host = try IOUSBHostInterface(__ioService: service, options: [], queue: queue) { [weak self] _, _, _ in
                    self?.finish(message: "F310 XInput 设备已断开")
                }
                interface = host
                let addresses = try Self.interruptAddresses(for: host)
                inputPipe = try host.copyPipe(withAddress:addresses.input)
                outputPipe = try host.copyPipe(withAddress:addresses.output)
                guard inputPipe != nil, outputPipe != nil else {
                    throw F310XInputSessionError.missingInterruptPair
                }
                active = true
                writeNextInitPacket()
            } catch {
                openError = error
                cleanup()
            }
        }
        if let openError { throw openError }
    }

    func snapshot() -> HIDDeviceSnapshot {
        let report = snapshotBox.snapshot(at: Date.timeIntervalSinceReferenceDate)
        return HIDDeviceSnapshot(
            uniqueID: String(format: "046d:c21d:xinputusb:%08x", locationID),
            name: "Gamepad F310", vendorID: 0x046D, productID: 0xC21D,
            axes: report.axes,
            axisUsages: [0x30, 0x31, 0x32, 0x35, 0x33, 0x34],
            buttons: report.buttons, buttonCount: 11, povs: [report.pov], isXbox: true,
            mode: .xinput,
            polarity: GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: true),
            usbLocationID: locationID)
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == locationID {
            active = false
            cleanup()
        } else {
            queue.sync {
                active = false
                cleanup()
            }
        }
    }

    private func writeNextInitPacket() {
        guard active, let outputPipe else { return }
        guard initIndex < initPackets.count else {
            scheduleRead()
            return
        }
        let packet = initPackets[initIndex]
        initIndex += 1
        let data = NSMutableData(bytes: packet, length: packet.count)
        do {
            try outputPipe.enqueueIORequest(with: data, completionTimeout: 0) { [weak self] status, count in
                guard let self, active else { return }
                guard status == kIOReturnSuccess, count == packet.count else {
                    finish(message: "F310 XInput 激活写入失败：IOReturn \(status)")
                    return
                }
                writeNextInitPacket()
            }
        } catch {
            finish(message: "F310 XInput 激活请求失败：\(error)")
        }
    }

    private func scheduleRead() {
        guard active, let inputPipe else { return }
        guard let data = NSMutableData(capacity: 64) else { return }
        do {
            try inputPipe.enqueueIORequest(with: data, completionTimeout: 0) { [weak self] status, count in
                guard let self, active else { return }
                guard status == kIOReturnSuccess else {
                    finish(message: "F310 XInput 读取失败：IOReturn \(status)")
                    return
                }
                if count == 20, let report = F310XInputReport.parse(Array(data as Data)) {
                    snapshotBox.update(report, at: Date.timeIntervalSinceReferenceDate)
                }
                scheduleRead()
            }
        } catch {
            finish(message: "F310 XInput 读取请求失败：\(error)")
        }
    }

    private func finish(message: String) {
        guard active else { return }
        active = false
        cleanup()
        onError(message)
        onEnded()
    }

    private func cleanup() {
        snapshotBox.clear()
        inputPipe = nil
        outputPipe = nil
        interface?.destroy()
        interface = nil
    }

    private static func interruptAddresses(for interface: IOUSBHostInterface) throws -> (input: Int, output: Int) {
        let descriptor = interface.configurationDescriptor
        let totalLength = Int(descriptor.pointee.wTotalLength)
        let bytes = UnsafeRawPointer(descriptor).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        var currentInterface = -1
        var input: Int?
        var output: Int?
        while offset + 1 < totalLength {
            let length = Int(bytes[offset])
            let type = Int(bytes[offset + 1])
            guard length >= 2, offset + length <= totalLength else {
                throw F310XInputSessionError.invalidDescriptor
            }
            if type == 4, length >= 3 {
                currentInterface = Int(bytes[offset + 2])
            } else if type == 5, length >= 4, currentInterface == 0 {
                let address = Int(bytes[offset + 2])
                let attributes = Int(bytes[offset + 3]) & 0x03
                if attributes == 0x03 {
                    if address & 0x80 != 0 {
                        input = address
                    } else {
                        output = address
                    }
                }
            }
            offset += length
        }
        guard let input, let output else { throw F310XInputSessionError.missingInterruptPair }
        return (input, output)
    }
}
