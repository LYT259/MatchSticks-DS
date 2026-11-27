import SwiftUI
import DSCore

struct MiniFIRSTModernView: View {
    let model: DSModel
    let flow: DriverStationWindowFlow
    let refresh: RobotRefreshFlow

    private let modes: [NIMode] = [.teleoperated, .autonomous, .test]

    var body: some View {
        HStack(spacing: 12) {
            modeList
            Divider()
            operationPane
            Divider()
            telemetryPane
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(DSTheme.canvas)
    }

    private var modeList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("驾驶模式")).font(.system(size: 11, weight: .semibold)).foregroundStyle(DSTheme.textSecondary)
            ForEach(modes, id: \.rawValue) { mode in
                Button { model.setMode(mode) } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(model.mode == mode ? DSTheme.accent : DSTheme.textSecondary.opacity(0.35))
                            .frame(width: 8, height: 8)
                        Text(mode.displayName)
                            .font(.system(size: 12, weight: model.mode == mode ? .semibold : .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(model.mode == mode ? DSTheme.accentDim : DSTheme.surface,
                                in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                        model.mode == mode ? DSTheme.accent : DSTheme.line))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(model.enabled)
                .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .frame(width: 210)
    }

    private var operationPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                MiniAlliancePicker(model: model).frame(width: 150)
                DSBadge(text: model.uiStatus, color: model.uiStatusColor,
                        symbol: model.estopEngaged ? "exclamationmark.octagon.fill" : "circle.inset.filled")
            }
            MiniSafetyControls(model: model)
            HStack(spacing: 14) {
                Text("Team: \(model.teamNumber > 0 ? String(model.teamNumber) : "—")")
                Text("IP: \(model.connectionDetail)")
                    .lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 11)).foregroundStyle(DSTheme.textSecondary)
            Text(model.enableExplanation)
                .font(.system(size: 10)).foregroundStyle(DSTheme.textSecondary)
                .lineLimit(1).truncationMode(.tail)
        }
        .frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
    }

    private var telemetryPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Battery Voltage").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(model.commConnected ? String(format: "%.2f V", model.batteryVolts) : "— V")
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(model.robotStatus.brownout ? DSTheme.danger : DSTheme.textPrimary)
                MiniRefreshButton(model: model, refresh: refresh)
                MiniRestoreButton(flow: flow)
            }
            Canvas { context, size in
                let baseline = Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1))
                context.fill(baseline, with: .color(DSTheme.line))
                let history = model.batteryHistory.map(Double.init)
                guard history.count >= 2 else { return }
                let low = history.min() ?? 0
                let high = history.max() ?? 0
                let span = max(0.1, high - low)
                let points = history.enumerated().map { index, value in
                    CGPoint(x: CGFloat(index) / CGFloat(history.count - 1) * size.width,
                            y: size.height - CGFloat((value - low) / span) * max(1, size.height - 8) - 4)
                }
                var line = Path()
                line.addLines(points)
                context.stroke(line, with: .color(DSTheme.warning), lineWidth: 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(tr("机器人电压历史"))
        }
        .frame(minWidth: 240, maxWidth: .infinity)
    }
}
