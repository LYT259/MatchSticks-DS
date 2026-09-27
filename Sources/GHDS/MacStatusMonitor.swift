import Foundation
import IOKit.ps
import Network
import Darwin

// MARK: - Mac 状态监控（NI DS 的 PC 电量/CPU 对应项，§7 功能矩阵「DS 自身监控」）

struct MacStatusSnapshot: Sendable {
    var batteryPercent: Int?     // nil = 无电池（台式机）
    var onAC: Bool?
    var systemCPUPercent: Double
    var processMemoryMB: Double
}

enum MacStatusMonitor {
    private static var lastTicks: (idle: UInt64, total: UInt64)?

    static func snapshot() -> MacStatusSnapshot {
        var s = MacStatusSnapshot(systemCPUPercent: 0, processMemoryMB: 0)
        (s.batteryPercent, s.onAC) = battery()
        s.systemCPUPercent = systemCPU()
        s.processMemoryMB = processMemory()
        return s
    }

    private static func battery() -> (Int?, Bool?) {
        // Copy/Get 语义：Copy 走 takeRetainedValue；IOPSGetPowerSourceDescription 是
        // Get（+0），必须 takeUnretainedValue——此前误用 retained 导致过度释放崩溃
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return (nil, nil)
        }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let capacity = desc[kIOPSCurrentCapacityKey] as? Int else { continue }
            // CLT SDK 未导出 kIOPSStateKey/kIOPSACPowerValue 常量，用文档字面值
            let state = desc["State"] as? String
            return (capacity, state == "AC Power")
        }
        return (nil, nil)
    }

    /// 全系统 CPU 占用（两次采样 tick 差值；首次返回粗略值）
    private static func systemCPU() -> Double {
        var cpuLoad = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &cpuLoad) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        // host_cpu_load_info ticks 顺序：user, system, idle, nice
        let user = UInt64(cpuLoad.cpu_ticks.0)
        let system = UInt64(cpuLoad.cpu_ticks.1)
        let idleTicks = UInt64(cpuLoad.cpu_ticks.2)
        let nice = UInt64(cpuLoad.cpu_ticks.3)
        let busy = user + system + nice
        let all = busy + idleTicks
        guard let last = lastTicks else {
            lastTicks = (UInt64(idleTicks), UInt64(all))
            return 0
        }
        let dTotal = all &- last.total
        let dIdle = idleTicks &- last.idle
        lastTicks = (UInt64(idleTicks), UInt64(all))
        guard dTotal > 0 else { return 0 }
        return Double(dTotal - dIdle) / Double(dTotal) * 100
    }

    private static func processMemory() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576
    }
}

// MARK: - 本机网络指示（NWPathMonitor：WiFi / 有线 / 无连接）

final class NetworkPathMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var _summary = "检测中…"
    private var _satisfied = false

    var summary: String {
        lock.lock(); defer { lock.unlock() }
        return _summary
    }
    var satisfied: Bool {
        lock.lock(); defer { lock.unlock() }
        return _satisfied
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let kind: String
            if path.usesInterfaceType(.wifi) { kind = "WiFi" }
            else if path.usesInterfaceType(.wiredEthernet) { kind = "有线" }
            else if path.status == .satisfied { kind = "其他接口" }
            else { kind = "无连接" }
            self.lock.lock()
            self._summary = kind
            self._satisfied = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "gh.driverstation.netpath"))
    }
}
