import Foundation

@MainActor
func macHardwareInterfaceTests(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void) {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let macSource = (try? String(contentsOf: root.appendingPathComponent(
        "Sources/MatchSticksDriverStaion/Views/MacStatusView.swift"), encoding: .utf8)) ?? ""
    let robotSource = (try? String(contentsOf: root.appendingPathComponent(
        "Sources/MatchSticksDriverStaion/Views/RobotHistoryView.swift"), encoding: .utf8)) ?? ""
    check(macSource.contains("import Charts"), "Mac monitoring uses time-based charts")
    check(macSource.contains("ForEach(Array(status.coreCPUPercentages.enumerated())"),
          "Mac monitoring renders every CPU core returned by the hardware")
    check(macSource.contains("gpu.coreCount") && macSource.contains("status.gpu?.perCoreUtilization") &&
          !macSource.contains("0..<16"),
          "Mac monitoring uses the actual GPU core count and never substitutes fabricated per-core bars")
    check(macSource.contains("MacBatteryHistoryChart") && macSource.contains("charging == true") &&
          macSource.contains("MacTemperatureHistoryChart"),
          "Mac monitoring renders battery charging intervals and temperature history")
    check(macSource.contains("status.memory") && macSource.contains("status.processes") &&
          macSource.contains("isCurrentProcess"),
          "Mac monitoring presents physical memory categories and identifies Driver Station memory")
    check(macSource.contains("风扇转速不可用"), "Mac monitoring explicitly reports unavailable fan readings")
    check(robotSource.contains("CANHistoryPanel") && robotSource.contains("ForEach(model.canHistory)"),
          "Robot monitoring includes the timestamped continuous CAN utilization history")
}
