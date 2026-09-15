import SwiftUI
import Charts
import DSCore

// MARK: - Charts 页（电池电压曲线 / roboRIO 每核 CPU / 丢包率）

struct ChartsView: View {
    let model: DSModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("电池电压").font(.headline)
                            Spacer()
                            Text(String(format: "%.2f V", model.batteryVolts))
                                .font(.title3.monospacedDigit().bold())
                                .foregroundStyle(model.robotStatus.brownout ? Color.red : Color.primary)
                        }
                        if model.batteryHistory.count > 1 {
                            Chart(Array(model.batteryHistory.suffix(300).enumerated()), id: \.offset) { i, v in
                                LineMark(x: .value("样本", i), y: .value("V", v))
                                    .interpolationMethod(.catmullRom)
                                AreaMark(x: .value("样本", i), y: .value("V", v))
                                    .interpolationMethod(.catmullRom)
                                    .opacity(0.12)
                            }
                            .chartXAxis(.hidden)
                            .frame(height: 160)
                        } else {
                            placeholder
                        }
                    }
                    .padding(4)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("roboRIO CPU 占用（每核）").font(.headline)
                        if !model.cpuCores.isEmpty {
                            Chart(Array(model.cpuCores.enumerated()), id: \.offset) { core, quad in
                                BarMark(
                                    x: .value("占用", Double(coreLoad(quad))),
                                    y: .value("核", "CPU \(core)")
                                )
                                .foregroundStyle(coreLoad(quad) > 0.8 ? Color.red.gradient : Color.accentColor.gradient)
                                .annotation(position: .trailing) {
                                    Text(String(format: "%.0f%%", coreLoad(quad) * 100))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .chartXScale(domain: 0...1)
                            .frame(height: CGFloat(44 * max(model.cpuCores.count, 1)))
                        } else {
                            placeholder.frame(minHeight: 80)
                        }
                    }
                    .padding(4)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("UDP 链路质量").font(.headline)
                        HStack(spacing: 24) {
                            stat("丢包率", String(format: "%.1f%%", model.lossPercent))
                            stat("已发送", "\(model.txCount)")
                            stat("已接收", "\(model.rxCount)")
                            Spacer()
                        }
                    }
                    .padding(4)
                }
            }
            .padding(14)
        }
    }

    private var placeholder: some View {
        Text("等待遥测数据…")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit().bold())
        }
    }

    private func coreLoad(_ quad: [Float]) -> Float {
        quad.reduce(0, +)
    }
}
