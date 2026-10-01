import SwiftUI
import DSCore

struct DiagnosticsView: View {
    let model: DSModel
    @State private var confirmReboot = false
    @State private var confirmRestart = false
    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                networkPanel
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    resourcesPanel
                    canPanel
                    powerPanel
                    computerPanel
                }
                cameraMockPanel
                versionsPanel
                maintenancePanel
            }
            .padding(24)
        }
        .confirmationDialog("确认重启机器人控制器？", isPresented: $confirmReboot, titleVisibility: .visible) {
            Button("重启控制器", role: .destructive) { model.rebootRoboRIO() }
        } message: {
            Text("机器人将暂时断开连接。请确认当前已失能。")
        }
        .confirmationDialog("确认重启机器人程序？", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("重启程序", role: .destructive) { model.restartRobotCode() }
        } message: {
            Text("重启会中断当前程序。请先确认机器人已失能。")
        }
    }

    private var networkPanel: some View {
        DSPanel(title: "连接检查") {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    connectionRow("机器人通信", detail: model.connectionDetail,
                                  symbol: "antenna.radiowaves.left.and.right", active: model.commConnected)
                    connectionRow("机器人无线电", detail: model.radioReachable ? "已响应" : "尚未检测到响应",
                                  symbol: "wifi", active: model.radioReachable)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    DSMetric(title: "当前丢包率", value: model.commConnected ? String(format: "%.1f%%", model.lossPercent) : "—",
                             symbol: "waveform.path")
                    Text("累计发送 \(model.txCount) · 接收 \(model.rxCount)")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(alignment: .top) {
                Label(model.manualIP == "172.22.11.2" ? "已配置 USB 直连地址" : "USB 直连地址未手动指定", systemImage: "cable.connector")
                Spacer()
                Text("FMS：不提供连接")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var resourcesPanel: some View {
        DSPanel(title: "机器人资源", subtitle: model.commConnected ? "控制器回传" : "连接后显示实时数据") {
            if model.commConnected && !model.cpuCores.isEmpty {
                ForEach(model.cpuCores.indices, id: \.self) { core in
                    let load = coreLoad(model.cpuCores[core])
                    VStack(spacing: 6) {
                        metricRow("CPU \(core)", value: String(format: "%.0f%%", load * 100))
                        ProgressView(value: Double(min(max(load, 0), 1)))
                            .tint(load > 0.8 ? .red : .accentColor)
                    }
                }
                Divider()
                metricRow("内存", value: model.ramTotal > 0
                          ? String(format: "%.0f / %.0f MB", Double(model.ramUsed) / 1e6, Double(model.ramTotal) / 1e6) : "—")
                if model.ramTotal > 0 {
                    ProgressView(value: min(Double(model.ramUsed) / Double(model.ramTotal), 1))
                }
                metricRow("可用磁盘", value: String(format: "%.1f GB", Double(model.diskFree) / 1e9))
            } else {
                emptyTelemetry
            }
        }
    }

    private var canPanel: some View {
        DSPanel(title: "CAN 总线") {
            metricRow("总线利用率", value: telemetry(String(format: "%.1f%%", model.can.utilizationPercent * 100)))
            Divider()
            metricRow("总线离线次数", value: telemetry("\(model.can.busOffCount)"))
            metricRow("发送缓冲区已满", value: telemetry("\(model.can.txFullCount)"))
            metricRow("接收错误", value: telemetry("\(model.can.rxErrorCount)"))
            metricRow("发送错误", value: telemetry("\(model.can.txErrorCount)"))
        }
    }

    private var powerPanel: some View {
        DSPanel(title: "电源与故障计数") {
            metricRow("电池电压", value: telemetry(String(format: "%.2f V", model.batteryVolts)))
            metricRow("通信失能故障", value: telemetry("\(model.disableFaults.comms)"))
            metricRow("12 V 失能故障", value: telemetry("\(model.disableFaults.twelveV)"))
            Divider()
            metricRow("6 V 电源故障", value: telemetry("\(model.railFaults.sixV)"))
            metricRow("5 V 电源故障", value: telemetry("\(model.railFaults.fiveV)"))
            metricRow("3.3 V 电源故障", value: telemetry("\(model.railFaults.threeV)"))
        }
    }

    private var computerPanel: some View {
        DSPanel(title: "这台 Mac") {
            if let pct = model.macStatus.batteryPercent {
                metricRow("电池", value: "\(pct)%")
                metricRow("供电方式", value: model.macStatus.onAC == true ? "外接电源" : "电池供电")
            } else {
                metricRow("供电方式", value: "外接电源")
            }
            metricRow("系统 CPU", value: String(format: "%.0f%%", model.macStatus.systemCPUPercent))
            metricRow("应用内存", value: String(format: "%.0f MB", model.macStatus.processMemoryMB))
            Divider()
            Text(model.localNetworkSummary)
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var versionsPanel: some View {
        DSPanel(title: "设备版本", subtitle: model.commConnected ? nil : "未连接；如有记录，显示上次收到的版本") {
            if model.versionEntries.isEmpty {
                Text("尚未收到版本信息。连接后由机器人程序提供。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.versionEntries.enumerated()), id: \.offset) { _, entry in
                    metricRow("\(entry.name) · 类型 \(entry.deviceType)", value: entry.version)
                }
            }
        }
    }

    private var cameraMockPanel: some View {
        DSPanel(title: "摄像头", subtitle: "模拟器 MOCK 图像源（真实 SystemCore 流协议待实测）") {
            CameraMockPanel()
        }
    }

    private var maintenancePanel: some View {
        DSPanel(title: "机器人维护", subtitle: "重启会中断控制。请先确认机器人已失能。") {
            HStack(spacing: 12) {
                Button("重启机器人程序", systemImage: "arrow.clockwise") { confirmRestart = true }
                    .buttonStyle(DSActionStyle())
                    .disabled(!model.commConnected)
                Button("重启控制器", systemImage: "power") { confirmReboot = true }
                    .buttonStyle(DSActionStyle(color: .secondary))
                    .disabled(!model.commConnected)
                Spacer(minLength: 0)
            }
        }
    }

    private func connectionRow(_ title: String, detail: String, symbol: String, active: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17)).foregroundStyle(active ? Color.green : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func metricRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }

    private var emptyTelemetry: some View {
        Label(model.commConnected ? "等待控制器回传资源数据" : "尚未连接机器人", systemImage: "waveform.path")
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
    }

    private func telemetry(_ value: String) -> String { model.commConnected ? value : "—" }
    private func coreLoad(_ quad: [Float]) -> Float { quad.reduce(0, +) }
}
