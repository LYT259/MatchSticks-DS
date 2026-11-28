import Foundation
import Darwin
import IOKit

private typealias IOHIDEventSystemClientRef = OpaquePointer
private typealias IOHIDServiceClientRef = OpaquePointer
private typealias IOHIDEventRef = OpaquePointer

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> IOHIDEventSystemClientRef?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: IOHIDEventSystemClientRef, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: IOHIDEventSystemClientRef) -> CFArray?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: IOHIDServiceClientRef, _ property: CFString) -> CFString?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: IOHIDServiceClientRef, _ type: Int64,
                                         _ options: Int32, _ timeout: Int64) -> IOHIDEventRef?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: IOHIDEventRef, _ field: Int32) -> Double

enum MacCPUTicks {
    static func read() -> [[UInt64]]? {
        var count = natural_t()
        var info: processor_info_array_t?
        var infoCount = mach_msg_type_number_t()
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                        &count, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        let raw = Array(UnsafeBufferPointer(start: info, count: Int(infoCount)))
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                      vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size))
        guard Int(count) > 0, Int(infoCount) >= Int(count) * 4 else { return nil }
        return (0..<Int(count)).map { core in
            (0..<4).map { state in UInt64(UInt32(bitPattern: raw[core * 4 + state])) }
        }
    }
}

enum MacMemorySource {
    static func read() -> MacMemoryStatus? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize = vm_size_t()
        guard result == KERN_SUCCESS, host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        return MacMemoryStatus(statistics: statistics, pageSize: UInt64(pageSize),
                               physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }
}

enum MacGPUSource {
    static func read() -> MacGPUStatus? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            let result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
            IOObjectRelease(service)
            guard result == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let status = MacGPUStatus(properties: dictionary) else { continue }
            return status
        }
        return nil
    }
}

final class MacTemperatureSource {
    private let client: IOHIDEventSystemClientRef?

    init() {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)
        if let client {
            _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        }
    }

    deinit {
        if let client {
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(client)).release()
        }
    }

    func read() -> [MacTemperatureReading] {
        guard let client, let services = IOHIDEventSystemClientCopyServices(client) else { return [] }
        var readings: [String: MacTemperatureReading] = [:]
        for index in 0..<CFArrayGetCount(services) {
            let service = unsafeBitCast(CFArrayGetValueAtIndex(services, index), to: IOHIDServiceClientRef.self)
            guard let product = IOHIDServiceClientCopyProperty(service, "Product" as CFString),
                  let event = IOHIDServiceClientCopyEvent(service, 15, 0, 0) else { continue }
            let value = IOHIDEventGetFloatValue(event, 15 << 16)
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release()
            let name = String(product)
            if let reading = MacTemperatureReading(name: name, rawValue: value) {
                readings[name] = reading
            }
        }
        return readings.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum MacProcessMemorySource {
    static func read() -> [MacProcessMemory] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,rss=,comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else { return [] }
            return MacProcessMemory.parsePSOutput(text, currentPID: ProcessInfo.processInfo.processIdentifier)
        } catch {
            return []
        }
    }
}
