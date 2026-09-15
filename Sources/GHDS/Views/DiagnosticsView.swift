import SwiftUI
import DSCore

// MARK: - Diagnostics 页（版本 / 网络指示 / CAN / 内存 / 故障计数）

struct DiagnosticsView: View {
    let model: DSModel

    var body: some View {
        Form {
            Section("网络指示") {
                HStack(spacing: 20) {
                    LED(label: "Robot (UDP)", on: model.commConnected, onColor: .green, symbol: "arrow.triangle.swap")
                    LED(label: "Robot Radio", on: model.commConnected, onColor: .green, symbol: "wifi")
                    LED(label: "USB", on: model.manualIP == "172.22.11.2", onColor: .green, symbol: "cable.connector")
                    LED(label: "FMS", on: model.robotStatus.raw != 0 && false, onColor: .blue, symbol: "building.2")
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("丢包 \(String(format: "%.1f%%", model.lossPercent))")
                        Text("TX \(model.txCount) · RX \(model.rxCount)")
                    }
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            Section("roboRIO 资源") {
                if model.cpuCores.isEmpty {
                    Text("等待遥测…").foregroundStyle(.secondary)
                } else {
                    ForEach(model.cpuCores.indices, id: \.self) { core in
                        HStack {
                            Text("CPU \(core)").frame(width: 64, alignment: .leading)
                            let load = coreLoad(model.cpuCores[core])
                            ProgressView(value: Double(load))
                                .tint(load > 0.8 ? .red : .accentColor)
                            Text(String(format: "%.0f%%", load * 100))
                                .font(.callout.monospacedDigit()).frame(width: 44)
                        }
                    }
                    HStack {
                        Text("内存").frame(width: 64, alignment: .leading)
                        let used = Double(model.ramUsed), total = Double(max(model.ramTotal, 1))
                        ProgressView(value: used / total)
                        Text(String(format: "%.0f / %.0f MB", used / 1e6, total / 1e6))
                            .font(.callout.monospacedDigit())
                    }
                    LabeledContent("磁盘剩余", value: String(format: "%.1f GB", Double(model.diskFree) / 1e9))
                }
            }

            Section("CAN 总线") {
                LabeledContent("利用率", value: String(format: "%.1f%%", model.can.utilizationPercent * 100))
                LabeledContent("Bus Off", value: "\(model.can.busOffCount)")
                LabeledContent("TX Full", value: "\(model.can.txFullCount)")
                LabeledContent("RX 错误", value: "\(model.can.rxErrorCount)")
                LabeledContent("TX 错误", value: "\(model.can.txErrorCount)")
            }

            Section("电源故障计数") {
                LabeledContent("Disable Faults（通信 / 12V）",
                               value: "\(model.disableFaults.comms) / \(model.disableFaults.twelveV)")
                LabeledContent("Rail 6V / 5V / 3.3V",
                               value: "\(model.railFaults.sixV) / \(model.railFaults.fiveV) / \(model.railFaults.threeV)")
            }

            Section("版本信息（TCP 0x0A）") {
                if model.versionEntries.isEmpty {
                    Text("未收到（需 TCP 通道）").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.versionEntries.enumerated()), id: \.offset) { _, e in
                        LabeledContent("\(e.name)（type \(e.deviceType)）", value: e.version)
                            .font(.callout.monospaced())
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func coreLoad(_ quad: [Float]) -> Float {
        // 四档占用率求和即为该核总占用（readthedocs 0x05 布局）
        quad.reduce(0, +)
    }
}
