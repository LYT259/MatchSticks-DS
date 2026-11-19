import SwiftUI
import DSCore

// Same status source and safety-gated actions as the main window.
struct MiniView: View {
    let model: DSModel
    // 语言切换 → .id(effective) 整树重建（与主窗 RootView 同一机制）
    @ObservedObject private var language = LanguageManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.teamNumber > 0 ? "TEAM \(model.teamNumber)" : "GH Driver Station")
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    Text(model.connectionDetail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.commConnected ? String(format: "%.2f V", model.batteryVolts) : "— V")
                    .font(.system(size: 20, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(model.commConnected && model.robotStatus.brownout ? Color.red : Color.primary)
            }
            DSBadge(text: model.uiStatus, color: model.uiStatusColor,
                    symbol: model.estopEngaged || model.robotStatus.estop ? "exclamationmark.octagon.fill" : "circle.inset.filled")
            HStack(spacing: 8) {
                Button { model.setEnabled(true) } label: {
                    Label(tr("使能"), systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 22)
                }
                .buttonStyle(DSActionStyle(color: .green, prominent: true))
                .disabled(!model.canEnable || model.remoteEstopReported)
                Button { model.setEnabled(false) } label: {
                    Label(tr("失能"), systemImage: "stop.fill").frame(maxWidth: .infinity, minHeight: 22)
                }
                .buttonStyle(DSActionStyle(color: .primary))
                Button { model.triggerEstop() } label: {
                    Label(tr("急停"), systemImage: "exclamationmark.octagon.fill").frame(maxWidth: .infinity, minHeight: 22)
                }
                .buttonStyle(DSActionStyle(color: .red, prominent: true))
                .disabled(model.estopEngaged)
            }
            Text(model.enableExplanation).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.estopEngaged {
                Button(tr("复位急停（请求重启程序）")) { model.resetEstop() }
                    .buttonStyle(DSActionStyle(color: .primary))
            }
        }
        .padding(20).padding(.top, 16)
        .frame(width: 420)
        .background(DSTheme.surface)
        .id(language.effective)
    }
}
