import SwiftUI
import DSCore

struct MiniNIClassicView: View {
    let model: DSModel
    let flow: DriverStationWindowFlow
    let refresh: RobotRefreshFlow

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullBody
            compactBody
        }
    }

    private var compactBody: some View {
        HStack(spacing: 8) {
            MiniRestoreButton(flow: flow)
            VStack(alignment: .leading, spacing: 4) {
                Text("Team # \(model.teamNumber > 0 ? String(model.teamNumber) : "—")")
                    .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                Text(model.mode.displayName)
                    .font(.system(size: 11, weight: .medium))
                Text(model.uiStatus)
                    .font(.system(size: 10)).foregroundStyle(model.uiStatusColor)
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(width: 130, alignment: .leading)
            MiniAlliancePicker(model: model).frame(width: 110)
            Spacer(minLength: 0)
            MiniSafetyControls(model: model)
            MiniRefreshButton(model: model, refresh: refresh)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(DSTheme.canvas)
    }

    private var fullBody: some View {
        HStack(spacing: 12) {
            MiniRestoreButton(flow: flow)
            statusPane
            Divider()
            operationPane
            Divider()
            controlPane
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(DSTheme.canvas)
    }

    private var statusPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Team #").font(.system(size: 11)).foregroundStyle(DSTheme.textSecondary)
                Text(model.teamNumber > 0 ? String(model.teamNumber) : "—")
                    .font(.system(size: 18, weight: .semibold)).monospacedDigit()
                Spacer()
                Text(model.commConnected ? String(format: "%.2f V", model.batteryVolts) : "— V")
                    .font(.system(size: 17, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(model.robotStatus.brownout ? DSTheme.danger : DSTheme.textPrimary)
            }
            HStack {
                MiniStatusLights(model: model)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.mode.displayName).font(.system(size: 12, weight: .semibold))
                    Text(model.uiStatus).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(model.uiStatusColor)
                        .lineLimit(2).minimumScaleFactor(0.8)
                }
            }
        }
        .frame(width: 240)
        .padding(10)
        .background(DSTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DSTheme.line))
    }

    private var operationPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            MiniModePicker(model: model)
            HStack(spacing: 10) {
                MiniAlliancePicker(model: model).frame(width: 150)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("已使能时间")).font(.system(size: 10)).foregroundStyle(DSTheme.textSecondary)
                    Text(String(format: "%02d:%04.1f", Int(model.enabledElapsed) / 60,
                                model.enabledElapsed.truncatingRemainder(dividingBy: 60)))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                }
            }
            HStack {
                Text("\(tr("PC 电池")): \(model.macStatus.batteryPercent.map { "\($0)%" } ?? "—")")
                Text("CPU: \(Int(model.macStatus.systemCPUPercent.rounded()))%")
                Spacer()
            }
            .font(.system(size: 11)).foregroundStyle(DSTheme.textSecondary)
        }
        .frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
    }

    private var controlPane: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack {
                MiniRefreshButton(model: model, refresh: refresh)
                if model.estopEngaged {
                    Button(tr("复位急停")) { model.resetEstop() }
                }
            }
            MiniSafetyControls(model: model)
            Text(model.enableExplanation)
                .font(.system(size: 10)).foregroundStyle(DSTheme.textSecondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 300, alignment: .trailing)
        }
    }
}
