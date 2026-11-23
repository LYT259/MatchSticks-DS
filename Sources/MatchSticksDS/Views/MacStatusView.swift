import SwiftUI
import DSCore

struct MacStatusView: View {
    let model: DSModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                macPanel
            }
            .padding(24)
        }
    }

    private var macPanel: some View {
        DSPanel(title: tr("Mac 状态")) {
            if let pct = model.macStatus.batteryPercent {
                metricRow(tr("电池"), value: "\(pct)%")
                metricRow(tr("供电方式"), value: model.macStatus.onAC == true ? tr("外接电源") : tr("电池供电"))
            } else {
                metricRow(tr("供电方式"), value: tr("外接电源"))
            }
            metricRow(tr("系统 CPU"), value: String(format: "%.0f%%", model.macStatus.systemCPUPercent))
            metricRow(tr("应用内存"), value: String(format: "%.0f MB", model.macStatus.processMemoryMB))
            Divider()
            Text(model.localNetworkSummary)
                .font(.callout).foregroundStyle(DSTheme.textSecondary).textSelection(.enabled)
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
}
