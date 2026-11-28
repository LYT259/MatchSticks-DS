import Foundation
import Darwin

private struct MacHistoryTestPoint {
    let timestamp: Date
}

@MainActor
func macHardwareMonitoringTests(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void) {
    let previous = [
        [UInt64(0), 0, 1000, 0],
        [100, 0, 900, 0],
        [10, 20, 970, 0],
    ]
    let current = [
        [UInt64(50), 50, 1050, 0],
        [100, 100, 900, 0],
        [10, 20, 970, 0],
    ]
    let loads = MacHardwareMath.cpuPercentages(previous: previous, current: current)
    check(loads.count == 3, "CPU delta keeps the available core count")
    check(abs(loads[0] - 200.0 / 3.0) < 0.0001, "CPU delta excludes idle ticks for each core")
    check(abs(loads[1] - 100) < 0.0001, "CPU delta supports a fully busy core")
    check(loads[2] == 0, "CPU delta without elapsed ticks returns zero instead of NaN")
    check(MacHardwareMath.cpuPercentages(previous: previous, current: []).isEmpty,
          "CPU delta handles a temporarily unavailable processor sample")

    let now = Date(timeIntervalSince1970: 10_000)
    let points = [-601, -600, -599, 0, 1].map { MacHistoryTestPoint(timestamp: now.addingTimeInterval($0)) }
    let trimmed = MacHardwareMath.trimmed(points, at: now) { $0.timestamp }
    check(trimmed.map(\.timestamp) == [now.addingTimeInterval(-600), now.addingTimeInterval(-599), now],
          "Mac history keeps exactly the latest 600 seconds and excludes future samples")

    let gpu = MacGPUStatus(properties: [
        "model": "Apple M5 Pro",
        "gpu-core-count": 16,
        "PerformanceStatistics": [
            "Device Utilization %": 21,
            "Renderer Utilization %": 20,
            "Tiler Utilization %": 10,
            "In use system memory": UInt64(512 * 1024 * 1024),
        ],
    ])
    check(gpu?.coreCount == 16 && gpu?.model == "Apple M5 Pro", "GPU registry parsing preserves model and core count")
    check(gpu?.deviceUtilization == 21 && gpu?.rendererUtilization == 20 && gpu?.tilerUtilization == 10,
          "GPU registry parsing reads device, renderer and tiler utilization")
    check(gpu?.perCoreUtilization.isEmpty == true, "GPU registry parsing never invents per-core percentages")
    check(gpu?.memoryBytes == UInt64(512 * 1024 * 1024), "GPU registry parsing reads active unified memory")

    let processes = MacProcessMemory.parsePSOutput("""
      20 1024 /Applications/Driver Station.app/Contents/MacOS/Driver Station
      10 2048 /Applications/Example.app/Contents/MacOS/Example App
      malformed
      30 nope /Applications/Bad.app/Contents/MacOS/Bad
    """, currentPID: 20)
    check(processes.count == 2 && processes[0].pid == 10 && processes[1].pid == 20,
          "Process memory parsing skips malformed rows and sorts by resident bytes")
    check(processes[0].name == "Example App" && processes[1].isCurrentProcess,
          "Process memory parsing preserves display names and identifies Driver Station")

    let backwards = MacHardwareMath.cpuPercentages(previous: current, current: previous)
    check(backwards.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 100 },
          "CPU tick regression never yields a negative or non-finite percentage")

    var statistics = vm_statistics64()
    statistics.free_count = 400
    statistics.active_count = 1_000
    statistics.inactive_count = 500
    statistics.wire_count = 200
    statistics.internal_page_count = 800
    statistics.purgeable_count = 100
    statistics.speculative_count = 50
    statistics.compressor_page_count = 300
    let memory = MacMemoryStatus(statistics: statistics, pageSize: 4_096, physicalMemory: 10_000 * 4_096)!
    check(memory.appBytes == 700 * 4_096 && memory.wiredBytes == 200 * 4_096 &&
          memory.compressedBytes == 300 * 4_096,
          "Memory categories use internal pages once and do not add active or speculative pages again")
    check(memory.usedBytes == 1_200 * 4_096 && memory.availableBytes == 900 * 4_096 &&
          memory.totalBytes == 10_000 * 4_096,
          "Memory used and available totals are derived from real counters")
    check(MacMemoryStatus(statistics: statistics, pageSize: 0, physicalMemory: 0) == nil,
          "Invalid page geometry is unavailable rather than a fabricated memory value")

    check(MacTemperatureReading(name: "PMU tdie1", rawValue: 47.25)?.celsius == 47.25,
          "A real HID temperature reading is retained")
    for invalid in [Double.nan, .infinity, -9_200, -50, 180] {
        check(MacTemperatureReading(name: "invalid", rawValue: invalid) == nil,
              "Invalid HID temperature \(invalid) is excluded")
    }
    let temperatures = [
        MacTemperatureReading(name: "PMU tdie1", rawValue: 43)!,
        MacTemperatureReading(name: "PMU tdie2", rawValue: 48)!,
        MacTemperatureReading(name: "PMU tcal", rawValue: 38)!,
        MacTemperatureReading(name: "NAND CH0 temp", rawValue: 35)!,
        MacTemperatureReading(name: "gas gauge battery", rawValue: 30)!,
    ]
    check(temperatures.socMaximumCelsius == 48 && temperatures.ssdCelsius == 35 &&
          temperatures.batteryCelsius == 30,
          "Temperature summaries retain their actual sensor boundaries without guessing CPU or GPU mappings")

    let suiteName = "org.ghfrc.driverstation.test.mac-history.\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    defer { suite.removePersistentDomain(forName: suiteName) }
    let historyModel = DSModel(settingsDefaults: suite, persistenceEnabled: false)
    let sampled = MacStatusSnapshot(systemCPUPercent: 12.5, coreCPUPercentages: [10, 20],
                                    processMemoryMB: 128, memory: memory, gpu: gpu,
                                    temperatures: temperatures, processes: processes,
                                    batteryPercent: 74, onAC: true, isCharging: true, sampledAt: now)
    historyModel.recordMacStatusSample(sampled)
    check(historyModel.macCPUHistory.count == 1 && historyModel.macCPUHistory[0].loads == [10, 20],
          "A Mac sample records the real per-core CPU loads")
    check(historyModel.macGPUHistory.count == 1 && historyModel.macGPUHistory[0].deviceUtilization == 21,
          "A Mac sample records the GPU history when the registry is available")
    check(historyModel.macTemperatureHistory[0].readings.count == temperatures.count &&
          historyModel.macBatteryHistory[0].onAC && historyModel.macBatteryHistory[0].percent == 74 &&
          historyModel.macBatteryHistory[0].charging == true,
          "A Mac sample retains temperatures, the battery charging state and AC power state")
    historyModel.recordMacStatusSample(MacStatusSnapshot(systemCPUPercent: 30,
                                                          processMemoryMB: 140,
                                                          sampledAt: now.addingTimeInterval(1)))
    check(historyModel.macGPUHistory.count == 1 && historyModel.macTemperatureHistory.count == 1 &&
          historyModel.macBatteryHistory.count == 1,
          "Unavailable GPU, temperature and battery readings do not become fake zero-valued history")
    historyModel.recordMacStatusSample(MacStatusSnapshot(systemCPUPercent: 1, processMemoryMB: 1,
                                                          sampledAt: now.addingTimeInterval(601)))
    check(historyModel.macCPUHistory.map(\.timestamp) == [now.addingTimeInterval(1), now.addingTimeInterval(601)],
          "Mac history drops expired samples and retains the 600-second boundary (actual \(historyModel.macCPUHistory.map(\.timestamp)))")
    historyModel.recordCANSample(utilization: 50, connected: false, at: now)
    check(historyModel.canHistory.isEmpty, "Disconnected CAN readings do not create a misleading zero history")
    historyModel.recordCANSample(utilization: 20, connected: true, at: now.addingTimeInterval(-3_601))
    historyModel.recordCANSample(utilization: 30, connected: true, at: now.addingTimeInterval(-3_600))
    historyModel.recordCANSample(utilization: 40, connected: true, at: now)
    check(historyModel.canHistory.map(\.utilization) == [30, 40], "CAN history is continuous and keeps the last hour")
}
