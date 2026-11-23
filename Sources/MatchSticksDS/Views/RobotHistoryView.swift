import SwiftUI
import Charts
import DSCore

// Separate observation boundaries keep 50 Hz telemetry from rebuilding history charts.
// Embedded inside RobotView's ScrollView, so this stack carries no padding of its own.
struct RobotHistoryView: View {
    let model: DSModel
    var body: some View {
        VStack(spacing: 16) {
            BatteryHistoryPanel(model: model)
            CPUHistoryPanel(model: model)
            LinkHistoryPanel(model: model)
        }
    }
}

private struct BatteryHistoryPanel: View {
    let model: DSModel
    var body: some View {
        DSPanel(title: tr("电池电压")) {
            if model.batteryHistory.count > 1 {
                Chart(Array(model.batteryHistory.suffix(300).enumerated()), id: \.offset) { index, value in
                    LineMark(x: .value(tr("采样序号"), index + 1), y: .value(tr("电压"), value))
                        .foregroundStyle(DSTheme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartXAxisLabel(tr("采样序号（由早到晚）"))
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 180)
                Text(tr("电压采样未记录时间戳，横轴表示收到数据的顺序。"))
                    .font(.caption).foregroundStyle(DSTheme.textSecondary)
            } else {
                emptyState(tr("等待电池电压采样"), detail: tr("连接机器人后显示电压变化。"))
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
                .font(.callout.monospacedDigit()).foregroundStyle(DSTheme.textSecondary)
            }
    }
}

private struct CPUHistoryPanel: View {
    let model: DSModel
    var body: some View {
        DSPanel(title: tr("机器人 CPU")) {
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
                emptyState(tr("等待 CPU 采样"), detail: tr("控制器回传核心负载后显示历史曲线。"))
            }
        }
    }

    private var cpuHistoryChart: some View {
        let coreCount = model.cpuHistory.map(\.loads.count).max() ?? 0
        return Chart {
            ForEach(0..<coreCount, id: \.self) { core in
                let points = model.cpuHistory.filter { core < $0.loads.count }
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value(tr("时间"), point.t), y: .value(tr("占用率"), point.loads[core]),
                             series: .value(tr("核心"), core))
                        .foregroundStyle(by: .value(tr("核心"), "CPU \(core)"))
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                }
                ForEach(Array(points.prefix(points.count == 1 ? 1 : 0).enumerated()), id: \.offset) { _, point in
                    PointMark(x: .value(tr("时间"), point.t), y: .value(tr("占用率"), point.loads[core]))
                        .foregroundStyle(by: .value(tr("核心"), "CPU \(core)"))
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
    }

}

private struct LinkHistoryPanel: View {
    let model: DSModel
    var body: some View {
        DSPanel(title: tr("通信质量")) {
            if model.lossHistory.count > 1 {
                Chart(Array(model.lossHistory.suffix(180).enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value(tr("时间"), point.t), y: .value(tr("丢包率"), point.loss))
                        .foregroundStyle(DSTheme.warning)
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
                emptyState(tr("等待通信采样"), detail: tr("开始连接后显示链路统计。"))
            }
            Text(tr("累计发送 %d 个数据包 · 接收 %d 个数据包", Int(model.txCount), Int(model.rxCount)))
                .font(.caption).monospacedDigit().foregroundStyle(DSTheme.textSecondary)
        }
    }

}

private func emptyState(_ title: String, detail: String) -> some View {
    DSEmptyState(symbol: "chart.xyaxis.line", title: title, detail: detail, minHeight: 130)
}
