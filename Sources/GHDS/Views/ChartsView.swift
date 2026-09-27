import SwiftUI
import Charts
import DSCore

// Separate observation boundaries keep 50 Hz current readings from rebuilding history charts.
struct ChartsView: View {
    let model: DSModel
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                CurrentReadingsPanel(model: model)
                BatteryHistoryPanel(model: model)
                CPUHistoryPanel(model: model)
                LinkHistoryPanel(model: model)
            }
            .padding(24)
        }
    }
}

private struct CurrentReadingsPanel: View {
    let model: DSModel
    var body: some View {
                DSPanel(title: "当前读数", subtitle: model.commConnected ? "来自机器人回传" : "未连接机器人；下方保留已采集的历史") {
                    HStack(spacing: 24) {
                        DSMetric(title: "电池电压", value: model.commConnected ? String(format: "%.2f V", model.batteryVolts) : "—",
                                 symbol: "battery.100percent", color: model.robotStatus.brownout && model.commConnected ? .red : .primary)
                        DSMetric(title: "丢包率", value: model.commConnected ? String(format: "%.1f%%", model.lossPercent) : "—",
                                 symbol: "waveform.path")
                        DSMetric(title: "累计接收", value: "\(model.rxCount)", symbol: "arrow.down")
                    }
                }
    }
}

private struct BatteryHistoryPanel: View {
    let model: DSModel
    var body: some View {
        DSPanel(title: "电池电压", subtitle: "最近 300 个回传采样 · 单位 V") {
            if model.batteryHistory.count > 1 {
                Chart(Array(model.batteryHistory.suffix(300).enumerated()), id: \.offset) { index, value in
                    LineMark(x: .value("采样序号", index + 1), y: .value("电压", value))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartXAxisLabel("采样序号（由早到晚）")
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 180)
                Text("电压采样未记录时间戳，横轴表示收到数据的顺序。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                emptyState("等待电池电压采样", detail: "连接机器人后显示电压变化。")
            }
        }
    }

}

private struct LiveCPULabel: View {
    let model: DSModel
    var body: some View {
            if model.commConnected && !model.cpuCores.isEmpty {
                Text(model.cpuCores.enumerated().map { core, loads in
                    String(format: "CPU %d  %.0f%%", core, loads.reduce(0, +) * 100)
                }.joined(separator: "   ·   "))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
    }
}

private struct CPUHistoryPanel: View {
    let model: DSModel
    var body: some View {
        DSPanel(title: "机器人 CPU", subtitle: "每个核心分别显示 · 最近保留的采样") {
            LiveCPULabel(model: model)
            if model.cpuHistory.contains(where: { !$0.loads.isEmpty }) {
                cpuHistoryChart
                    .chartYScale(domain: 0...1)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: [0.0, 0.25, 0.5, 0.75, 1.0]) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text("\(Int(number * 100))%")
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.hour().minute().second())
                        }
                    }
                    .frame(height: 180)
            } else {
                emptyState("等待 CPU 采样", detail: "控制器回传核心负载后显示历史曲线。")
            }
        }
    }

    private var cpuHistoryChart: some View {
        let coreCount = model.cpuHistory.map(\.loads.count).max() ?? 0
        return Chart {
            ForEach(0..<coreCount, id: \.self) { core in
                let points = model.cpuHistory.filter { core < $0.loads.count }
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("时间", point.t), y: .value("占用率", point.loads[core]),
                             series: .value("核心", core))
                        .foregroundStyle(by: .value("核心", "CPU \(core)"))
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                }
                ForEach(Array(points.prefix(points.count == 1 ? 1 : 0).enumerated()), id: \.offset) { _, point in
                    PointMark(x: .value("时间", point.t), y: .value("占用率", point.loads[core]))
                        .foregroundStyle(by: .value("核心", "CPU \(core)"))
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
    }

}

private struct LinkHistoryPanel: View {
    let model: DSModel
    var body: some View {
        DSPanel(title: "通信质量", subtitle: "丢包率 · 最近 180 个采样") {
            if model.lossHistory.count > 1 {
                Chart(Array(model.lossHistory.suffix(180).enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("时间", point.t), y: .value("丢包率", point.loss))
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                }
                .chartYScale(domain: 0...max(5, (model.lossHistory.suffix(180).map(\.loss).max() ?? 0) * 1.15))
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Double.self) { Text(String(format: "%.0f%%", number)) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute().second())
                    }
                }
                .frame(height: 140)
            } else {
                emptyState("等待通信采样", detail: "开始连接后显示链路统计。")
            }
            Text("累计发送 \(model.txCount) 个数据包 · 接收 \(model.rxCount) 个数据包")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

}

private func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line").font(.system(size: 24)).foregroundStyle(.tertiary)
            Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 130)
    }
