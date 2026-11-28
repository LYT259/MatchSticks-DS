import SwiftUI
import Charts
import DSCore

struct MacStatusView: View {
    let model: DSModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                MacCPUPanel(status: model.macStatus, history: model.macCPUHistory)
                MacGPUPanel(status: model.macStatus, history: model.macGPUHistory)
                MacMemoryPanel(status: model.macStatus)
                MacTemperaturePanel(status: model.macStatus, history: model.macTemperatureHistory)
                MacBatteryPanel(status: model.macStatus, history: model.macBatteryHistory)
                DSPanel(title: tr("本机网络")) {
                    Text(model.localNetworkSummary)
                        .font(.callout).foregroundStyle(DSTheme.textSecondary).textSelection(.enabled)
                }
            }
            .padding(24)
        }
    }
}

private struct MacCPUPanel: View {
    let status: MacStatusSnapshot
    let history: [MacCPUHistorySample]

    var body: some View {
        DSPanel(title: tr("CPU"), subtitle: tr("%d 个核心", status.coreCPUPercentages.count)) {
            HStack {
                DSMetric(title: tr("总占用"), value: macPercent(status.systemCPUPercent), symbol: "cpu")
                Spacer()
                Text(tr("最近 10 分钟")).font(.caption).foregroundStyle(DSTheme.textSecondary)
            }
            if status.coreCPUPercentages.isEmpty {
                DSEmptyState(symbol: "cpu", title: tr("正在采集逐核心 CPU 数据"),
                             detail: tr("至少获得两次采样后显示各核心占用。"), minHeight: 100)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                    ForEach(Array(status.coreCPUPercentages.enumerated()), id: \.offset) { index, load in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("CPU \(index)").font(.caption).foregroundStyle(DSTheme.textSecondary)
                                Spacer()
                                Text(macPercent(load)).font(.caption.monospacedDigit())
                            }
                            ProgressView(value: load, total: 100).tint(DSTheme.accent)
                        }
                        .padding(9).background(DSTheme.card, in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            MacMetricHistoryChart(points: history.map {
                MacTimeValue(timestamp: $0.timestamp, value: $0.systemPercent)
            }, color: DSTheme.accent, unit: "%")
        }
    }
}

private struct MacGPUPanel: View {
    let status: MacStatusSnapshot
    let history: [MacGPUHistorySample]

    var body: some View {
        DSPanel(title: tr("GPU"), subtitle: status.gpu?.model) {
            if let gpu = status.gpu {
                HStack(spacing: 20) {
                    DSMetric(title: "Device", value: macOptionalPercent(gpu.deviceUtilization), symbol: "gpu")
                    DSMetric(title: "Renderer", value: macOptionalPercent(gpu.rendererUtilization))
                    DSMetric(title: "Tiler", value: macOptionalPercent(gpu.tilerUtilization))
                }
                macMetricRow(tr("GPU 核心"), value: gpu.coreCount > 0 ? "\(gpu.coreCount)" : tr("不可用"))
                if let memory = gpu.memoryBytes {
                    macMetricRow(tr("GPU 使用中的统一内存"), value: macBytes(memory))
                }
            } else {
                DSEmptyState(symbol: "gpu", title: tr("GPU 数据不可用"),
                             detail: tr("当前系统没有提供可读取的 GPU 性能统计。"), minHeight: 90)
            }
            if let cores = status.gpu?.perCoreUtilization, !cores.isEmpty {
                ForEach(Array(cores.enumerated()), id: \.offset) { index, load in
                    macMetricRow("GPU \(index)", value: macPercent(load))
                }
            } else {
                Text(tr("系统没有提供逐核心 GPU 占用；这里只显示真实可用的指标，不生成逐核心估计值。"))
                    .font(.caption).foregroundStyle(DSTheme.textSecondary)
            }
            MacMetricHistoryChart(points: history.compactMap { sample in
                sample.deviceUtilization.map { MacTimeValue(timestamp: sample.timestamp, value: $0) }
            }, color: DSTheme.accent, unit: "%")
            Text(tr("曲线为 GPU Device 总占用 · 最近 10 分钟"))
                .font(.caption).foregroundStyle(DSTheme.textSecondary)
        }
    }
}

private struct MacMemoryPanel: View {
    let status: MacStatusSnapshot

    private var listedProcesses: [MacProcessMemory] {
        let top = Array(status.processes.prefix(8))
        guard !top.contains(where: \.isCurrentProcess),
              let current = status.processes.first(where: { $0.isCurrentProcess }) else { return top }
        return top + [current]
    }

    var body: some View {
        DSPanel(title: tr("内存")) {
            if let memory = status.memory {
                macMetricRow(tr("物理内存"), value: tr("已用 %@ / 共 %@", macBytes(memory.usedBytes), macBytes(memory.totalBytes)))
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        memorySegment(memory.appBytes, total: memory.totalBytes, width: geometry.size.width, color: DSTheme.accent)
                        memorySegment(memory.wiredBytes, total: memory.totalBytes, width: geometry.size.width, color: DSTheme.warning)
                        memorySegment(memory.compressedBytes, total: memory.totalBytes, width: geometry.size.width, color: DSTheme.success)
                    }
                    .background(DSTheme.card, in: RoundedRectangle(cornerRadius: 5))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .frame(height: 12)
                .accessibilityLabel(tr("内存分类：App、联动内存、已压缩"))
                macMetricRow(tr("App 内存"), value: macBytes(memory.appBytes))
                macMetricRow(tr("联动内存"), value: macBytes(memory.wiredBytes))
                macMetricRow(tr("已压缩"), value: macBytes(memory.compressedBytes))
                macMetricRow(tr("可用内存"), value: macBytes(memory.availableBytes))
            } else {
                Text(tr("物理内存数据暂不可用")).font(.callout).foregroundStyle(DSTheme.textSecondary)
            }
            Divider()
            macMetricRow("Driver Station", value: String(format: "%.0f MB", status.processMemoryMB))
            Text(tr("主要进程（按常驻内存排序）")).font(.caption).foregroundStyle(DSTheme.textSecondary)
            if listedProcesses.isEmpty {
                Text(tr("进程内存数据暂不可用")).font(.callout).foregroundStyle(DSTheme.textSecondary)
            } else {
                ForEach(listedProcesses) { process in
                    HStack(spacing: 8) {
                        Text(process.name).lineLimit(1).truncationMode(.middle)
                        if process.isCurrentProcess { DSBadge(text: "Driver Station", color: DSTheme.accent) }
                        Spacer(minLength: 8)
                        Text(macBytes(process.residentBytes)).monospacedDigit().foregroundStyle(DSTheme.textSecondary)
                    }
                    .font(.callout)
                    .accessibilityLabel(process.isCurrentProcess ? "Driver Station" : process.name)
                    .accessibilityValue(macBytes(process.residentBytes))
                }
            }
        }
    }

    private func memorySegment(_ value: UInt64, total: UInt64, width: CGFloat, color: Color) -> some View {
        Rectangle().fill(color)
            .frame(width: width * CGFloat(min(value, total)) / CGFloat(max(1, total)))
            .frame(maxHeight: .infinity)
    }
}

private struct MacTemperaturePanel: View {
    let status: MacStatusSnapshot
    let history: [MacTemperatureHistorySample]
    private var readings: [MacTemperatureReading] { history.last?.readings ?? status.temperatures }

    var body: some View {
        DSPanel(title: tr("温度"), subtitle: tr("最近 10 分钟")) {
            if readings.isEmpty {
                DSEmptyState(symbol: "thermometer.medium", title: tr("未检测到可用的温度传感器"),
                             detail: tr("读取失败或当前硬件不提供温度数据时，不会显示估计温度。"), minHeight: 100)
            } else {
                HStack(spacing: 20) {
                    DSMetric(title: tr("SoC 最高温"), value: macTemperature(readings.socMaximumCelsius), symbol: "thermometer.medium")
                    DSMetric(title: "SSD", value: macTemperature(readings.ssdCelsius))
                    DSMetric(title: tr("电池温度"), value: macTemperature(readings.batteryCelsius))
                }
                MacTemperatureHistoryChart(history: history)
                DisclosureGroup(tr("全部传感器")) {
                    VStack(spacing: 8) {
                        ForEach(readings) { reading in
                            macMetricRow(reading.name, value: macTemperature(reading.celsius))
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.callout)
                Text(tr("SoC 取 PMU tdie 传感器最高值。其他名称来自系统；没有依据时不猜测其与 CPU 或 GPU 的对应关系。"))
                    .font(.caption).foregroundStyle(DSTheme.textSecondary)
            }
            Divider()
            macMetricRow(tr("风扇转速"), value: tr("不可用"))
            Text(tr("风扇转速不可用：macOS 未授权当前应用读取风扇；本应用不安装特权辅助工具。"))
                .font(.caption).foregroundStyle(DSTheme.textSecondary)
        }
    }
}

private struct MacBatteryPanel: View {
    let status: MacStatusSnapshot
    let history: [MacBatteryHistorySample]

    var body: some View {
        DSPanel(title: tr("电池电量"), subtitle: tr("最近 10 分钟")) {
            if let percent = status.batteryPercent {
                HStack {
                    DSMetric(title: tr("电量"), value: "\(percent)%", symbol: "battery.75percent")
                    Spacer()
                    DSBadge(text: status.isCharging == true ? tr("正在充电") :
                                (status.onAC == true ? tr("外接电源") : tr("电池供电")),
                            color: status.isCharging == true ? DSTheme.success : DSTheme.textSecondary,
                            symbol: status.isCharging == true ? "bolt.fill" : "powerplug")
                }
                MacBatteryHistoryChart(points: history)
                Text(tr("绿色区间为正在充电；其余时间为未充电。仅保留最近 10 分钟。"))
                    .font(.caption).foregroundStyle(DSTheme.textSecondary)
            } else {
                macMetricRow(tr("供电方式"), value: tr("外接电源"))
                Text(tr("没有检测到电池。")).font(.caption).foregroundStyle(DSTheme.textSecondary)
            }
        }
    }
}

private struct MacTimeValue: Identifiable {
    var id: Date { timestamp }
    let timestamp: Date
    let value: Double
}

private struct MacMetricHistoryChart: View {
    let points: [MacTimeValue]
    let color: Color
    let unit: String

    var body: some View {
        if points.count > 1 {
            Chart(points) { point in
                LineMark(x: .value(tr("时间"), point.timestamp), y: .value(tr("占用率"), point.value))
                    .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.8))
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: macHistoryDomain(points.map(\.timestamp)))
            .chartXAxis { macTimeAxis }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel { if let number = value.as(Double.self) { Text("\(Int(number))\(unit)") } }
                }
            }
            .frame(height: 145)
        } else {
            DSEmptyState(symbol: "chart.xyaxis.line", title: tr("正在积累历史数据"),
                         detail: tr("至少获得两次采样后显示曲线。"), minHeight: 100)
        }
    }
}

private struct MacTemperatureSeries: Identifiable {
    var id: String { name }
    let name: String
    let color: Color
    let points: [MacTimeValue]
}

private struct MacTemperatureHistoryChart: View {
    let history: [MacTemperatureHistorySample]
    private var series: [MacTemperatureSeries] {
        func points(_ keyPath: KeyPath<[MacTemperatureReading], Double?>) -> [MacTimeValue] {
            history.compactMap { sample in
                sample.readings[keyPath: keyPath].map { MacTimeValue(timestamp: sample.timestamp, value: $0) }
            }
        }
        return [
            MacTemperatureSeries(name: tr("SoC 最高温"), color: DSTheme.danger, points: points(\.socMaximumCelsius)),
            MacTemperatureSeries(name: "SSD", color: DSTheme.warning, points: points(\.ssdCelsius)),
            MacTemperatureSeries(name: tr("电池温度"), color: DSTheme.success, points: points(\.batteryCelsius)),
        ].filter { !$0.points.isEmpty }
    }

    var body: some View {
        if series.contains(where: { $0.points.count > 1 }) {
            Chart(series) { item in
                ForEach(item.points) { point in
                    LineMark(x: .value(tr("时间"), point.timestamp), y: .value(tr("温度"), point.value),
                             series: .value(tr("传感器"), item.name))
                        .foregroundStyle(item.color).lineStyle(StrokeStyle(lineWidth: 1.6))
                }
            }
            .chartYScale(domain: 0...max(60, (history.last?.readings.map(\.celsius).max() ?? 0) + 10))
            .chartXScale(domain: macHistoryDomain(history.map(\.timestamp)))
            .chartXAxis { macTimeAxis }
            .chartYAxis { AxisMarks(position: .leading) }
            .chartLegend(.hidden)
            .frame(height: 160)
            HStack(spacing: 16) {
                ForEach(series) { item in
                    Label(item.name, systemImage: "circle.fill").foregroundStyle(item.color).font(.caption)
                }
            }
        } else {
            DSEmptyState(symbol: "chart.xyaxis.line", title: tr("正在积累温度历史"),
                         detail: tr("至少获得两次采样后显示曲线。"), minHeight: 100)
        }
    }
}

private struct MacBatteryHistoryChart: View {
    let points: [MacBatteryHistorySample]

    var body: some View {
        if points.count > 1 {
            Chart(Array(points.enumerated()), id: \.element.id) { index, point in
                if point.charging == true {
                    RectangleMark(xStart: .value(tr("开始"), point.timestamp),
                                  xEnd: .value(tr("结束"), index + 1 < points.count ? points[index + 1].timestamp : Date()),
                                  yStart: .value(tr("最小"), 0), yEnd: .value(tr("最大"), 100))
                        .foregroundStyle(DSTheme.success.opacity(0.15))
                }
                LineMark(x: .value(tr("时间"), point.timestamp), y: .value(tr("电量"), point.percent))
                    .foregroundStyle(DSTheme.success).lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: macHistoryDomain(points.map(\.timestamp)))
            .chartXAxis { macTimeAxis }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel { if let number = value.as(Double.self) { Text("\(Int(number))%") } }
                }
            }
            .frame(height: 160)
        } else {
            DSEmptyState(symbol: "battery.75percent", title: tr("正在积累电池历史"),
                         detail: tr("至少获得两次采样后显示曲线。"), minHeight: 100)
        }
    }
}

private var macTimeAxis: some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
        AxisGridLine()
        AxisValueLabel(format: .dateTime.hour().minute().second())
    }
}

private func macHistoryDomain(_ timestamps: [Date]) -> ClosedRange<Date> {
    let end = timestamps.max() ?? Date()
    return end.addingTimeInterval(-MacHardwareMath.historyWindow)...end
}

private func macMetricRow(_ title: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
        Text(title).foregroundStyle(DSTheme.textSecondary)
        Spacer(minLength: 8)
        Text(value).monospacedDigit().multilineTextAlignment(.trailing).textSelection(.enabled)
    }
    .font(.callout)
}

private func macPercent(_ value: Double) -> String { String(format: "%.0f%%", value) }
private func macOptionalPercent(_ value: Double?) -> String { value.map(macPercent) ?? "—" }
private func macTemperature(_ value: Double?) -> String { value.map { String(format: "%.1f °C", $0) } ?? "—" }
private func macBytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .memory)
}
