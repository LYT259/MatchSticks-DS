import SwiftUI
import DSCore

struct RobotView: View {
    let model: DSModel
    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                networkPanel
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    resourcesPanel
                    canPanel
                    powerPanel
                }
                versionsPanel
                RobotHistoryView(model: model)
            }
            .padding(24)
        }
    }

    private var networkPanel: some View {
        DSPanel(title: tr("连接检查")) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    connectionRow(tr("机器人通信"), detail: model.connectionDetail,
                                  symbol: "antenna.radiowaves.left.and.right", active: model.commConnected)
                    connectionRow(tr("机器人无线电"), detail: model.radioReachable ? tr("已响应") : tr("尚未检测到响应"),
                                  symbol: "wifi", active: model.radioReachable)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    DSMetric(title: tr("当前丢包率"), value: model.commConnected ? String(format: "%.1f%%", model.lossPercent) : "—",
                             symbol: "waveform.path")
                    Text(tr("累计发送 %d · 接收 %d", Int(model.txCount), Int(model.rxCount)))
                        .font(.caption).monospacedDigit().foregroundStyle(DSTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(alignment: .top) {
                Label(model.manualIP == "172.22.11.2" ? tr("已配置 USB 直连地址") : tr("USB 直连地址未手动指定"), systemImage: "cable.connector")
                Spacer()
                Text(tr("FMS：不提供连接"))
            }
            .font(.caption).foregroundStyle(DSTheme.textSecondary)
        }
    }

    private var resourcesPanel: some View {
        DSPanel(title: tr("机器人资源")) {
            if model.commConnected && !model.cpuCores.isEmpty {
                ForEach(model.cpuCores.indices, id: \.self) { core in
                    let load = coreLoad(model.cpuCores[core])
                    VStack(spacing: 6) {
                        metricRow("CPU \(core)", value: String(format: "%.0f%%", load * 100))
                        ProgressView(value: Double(min(max(load, 0), 1)))
                            .tint(load > 0.8 ? DSTheme.danger : DSTheme.accent)
                            .controlSize(.small)
                    }
                }
                Divider()
                metricRow(tr("内存"), value: model.ramTotal > 0
                          ? String(format: "%.0f / %.0f MB", Double(model.ramUsed) / 1e6, Double(model.ramTotal) / 1e6) : "—")
                if model.ramTotal > 0 {
                    ProgressView(value: min(Double(model.ramUsed) / Double(model.ramTotal), 1))
                        .tint(DSTheme.accent)
                        .controlSize(.small)
                }
                metricRow(tr("可用磁盘"), value: String(format: "%.1f GB", Double(model.diskFree) / 1e9))
            } else {
                emptyTelemetry
            }
        }
    }

    private var canPanel: some View {
        DSPanel(title: tr("CAN 总线")) {
            metricRow(tr("总线利用率"), value: telemetry(String(format: "%.1f%%", model.can.utilizationPercent * 100)))
            Divider()
            metricRow(tr("总线离线次数"), value: telemetry("\(model.can.busOffCount)"))
            metricRow(tr("发送缓冲区已满"), value: telemetry("\(model.can.txFullCount)"))
            metricRow(tr("接收错误"), value: telemetry("\(model.can.rxErrorCount)"))
            metricRow(tr("发送错误"), value: telemetry("\(model.can.txErrorCount)"))
        }
    }

    private var powerPanel: some View {
        DSPanel(title: tr("电源与故障计数")) {
            metricRow(tr("电池电压"), value: telemetry(String(format: "%.2f V", model.batteryVolts)))
            metricRow(tr("通信失能故障"), value: telemetry("\(model.disableFaults.comms)"))
            metricRow(tr("12 V 失能故障"), value: telemetry("\(model.disableFaults.twelveV)"))
            Divider()
            metricRow(tr("6 V 电源故障"), value: telemetry("\(model.railFaults.sixV)"))
            metricRow(tr("5 V 电源故障"), value: telemetry("\(model.railFaults.fiveV)"))
            metricRow(tr("3.3 V 电源故障"), value: telemetry("\(model.railFaults.threeV)"))
        }
    }

    private var versionsPanel: some View {
        DSPanel(title: tr("设备版本"), subtitle: model.commConnected ? nil : tr("未连接；如有记录，显示上次收到的版本")) {
            if model.versionEntries.isEmpty {
                Text(tr("尚未收到版本信息。连接后由机器人程序提供。"))
                    .font(.callout).foregroundStyle(DSTheme.textSecondary)
            } else {
                ForEach(Array(model.versionEntries.enumerated()), id: \.offset) { _, entry in
                    metricRow(tr("%@ · 类型 %d", entry.name, Int(entry.deviceType)), value: entry.version)
                }
            }
        }
    }

    private func connectionRow(_ title: String, detail: String, symbol: String, active: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17)).foregroundStyle(active ? DSTheme.success : DSTheme.textSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(DSTheme.textSecondary).textSelection(.enabled)
            }
        }
    }

    private func metricRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title).foregroundStyle(DSTheme.textSecondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }

    private var emptyTelemetry: some View {
        Label(model.commConnected ? tr("等待控制器回传资源数据") : tr("尚未连接机器人"), systemImage: "waveform.path")
            .font(.callout).foregroundStyle(DSTheme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
    }

    private func telemetry(_ value: String) -> String { model.commConnected ? value : "—" }
    private func coreLoad(_ quad: [Float]) -> Float { quad.reduce(0, +) }
}
