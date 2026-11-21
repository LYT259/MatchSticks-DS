import SwiftUI
import DSCore

struct DSStatusBar: View {
    let model: DSModel

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("机器人状态")).font(.system(size: 11)).foregroundStyle(DSTheme.textSecondary)
                Label(model.uiStatus, systemImage: statusSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(model.uiStatusColor)
            }
            .frame(minWidth: 170, alignment: .leading)
            Spacer(minLength: 0)
            statusItem(tr("通信"), active: model.commConnected)
            statusItem(tr("程序"), active: model.commConnected && model.robotTrace.hasRobotCode)
            statusItem(tr("手柄"), active: !model.joystickSlots.isEmpty)
            Divider().frame(height: 30)
            VStack(alignment: .trailing, spacing: 5) {
                Text(tr("机器人电池")).font(.system(size: 11)).foregroundStyle(DSTheme.textSecondary)
                Text(model.commConnected ? String(format: "%.2f V", model.batteryVolts) : "— V")
                    .font(.system(size: 19, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(batteryColor)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
        .background(DSTheme.sidebar, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DSTheme.line))
        .accessibilityElement(children: .contain)
    }

    private var statusSymbol: String {
        if model.estopEngaged || model.robotStatus.estop { return "exclamationmark.octagon.fill" }
        if !model.watchdogHealthy || model.robotStatus.brownout { return "exclamationmark.triangle.fill" }
        return model.commConnected ? "circle.inset.filled" : "antenna.radiowaves.left.and.right.slash"
    }

    private func statusItem(_ label: String, active: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: active ? "checkmark.circle.fill" : "minus.circle")
                .font(.system(size: 14)).foregroundStyle(active ? DSTheme.success : DSTheme.textSecondary)
            Text(label).font(.system(size: 11)).foregroundStyle(DSTheme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("%@：%@", label, active ? tr("已检测到") : tr("未检测到")))
    }

    private var batteryColor: Color {
        guard model.commConnected else { return .secondary }
        if model.robotStatus.brownout || model.batteryVolts < 7 { return .red }
        if model.batteryVolts < 11 { return .orange }
        return .primary
    }
}

// Shared compact indicator, with explicit text and without a glow effect.
struct LED: View {
    let label: String
    let on: Bool
    let onColor: Color
    let symbol: String
    var offText: String? = nil

    var body: some View {
        Label(on ? label : (offText ?? label), systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(on ? onColor : DSTheme.textSecondary)
            .accessibilityLabel(tr("%@：%@", label, on ? tr("已检测到") : (offText ?? tr("未检测到"))))
    }
}

// MARK: 迷你曲线

struct Sparkline: View {
    let values: [Float]

    var body: some View {
        GeometryReader { geo in
            let pts = normalizedPoints(size: geo.size)
            Path { p in
                guard pts.count > 1 else { return }
                p.move(to: pts[0])
                for pt in pts.dropFirst() { p.addLine(to: pt) }
            }
            .stroke(DSTheme.accent, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
    }

    private func normalizedPoints(size: CGSize) -> [CGPoint] {
        guard let minV = values.min(), let maxV = values.max(), maxV > minV else { return [] }
        let span = maxV - minV
        return values.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) / CGFloat(values.count - 1) * size.width,
                    y: size.height - CGFloat((v - minV) / span) * size.height)
        }
    }
}
