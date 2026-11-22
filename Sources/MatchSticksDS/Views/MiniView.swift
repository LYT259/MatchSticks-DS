import SwiftUI
import DSCore

// Same status source and safety-gated actions as the main window.
struct MiniView: View {
    let model: DSModel
    // 与主窗一样由观察驱动刷新，避免切换语言时重建整树。
    @ObservedObject private var language = LanguageManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.teamNumber > 0 ? "TEAM \(model.teamNumber)" : "MatchSticks DS")
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    Text(model.connectionDetail).font(.caption).foregroundStyle(DSTheme.textSecondary)
                }
                Spacer()
                Text(model.commConnected ? String(format: "%.2f V", model.batteryVolts) : "— V")
                    .font(.system(size: 20, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(model.commConnected && model.robotStatus.brownout ? DSTheme.danger : DSTheme.textPrimary)
            }
            DSBadge(text: model.uiStatus, color: model.uiStatusColor,
                    symbol: model.estopEngaged || model.robotStatus.estop ? "exclamationmark.octagon.fill" : "circle.inset.filled")
            HStack(spacing: 8) {
                Button { model.setEnabled(true) } label: {
                    Label(tr("使能"), systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 22)
                }
                .buttonStyle(DSActionStyle(color: DSTheme.success, prominent: true))
                .disabled(!model.canEnable || model.remoteEstopReported)
                Button { model.setEnabled(false) } label: {
                    Label(tr("失能"), systemImage: "stop.fill").frame(maxWidth: .infinity, minHeight: 22)
                }
                .buttonStyle(DSActionStyle())
                Button { model.triggerEstop() } label: {
                    Label(tr("急停"), systemImage: "exclamationmark.octagon.fill").frame(maxWidth: .infinity, minHeight: 22)
                }
                .buttonStyle(DSActionStyle(color: DSTheme.danger, prominent: true))
                .disabled(model.estopEngaged)
            }
            Text(model.enableExplanation).font(.system(size: 11)).foregroundStyle(DSTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.estopEngaged {
                Button(tr("复位急停（请求重启程序）")) { model.resetEstop() }
                    .buttonStyle(DSActionStyle())
            }
        }
        .padding(20).padding(.top, 16)
        .frame(width: 420)
        .background(DSTheme.sidebar)
        .tint(DSTheme.accent)
        .foregroundStyle(DSTheme.textPrimary)
        .overlay(WindowTitleSync(title: tr("迷你驾驶台")))
    }
}

private struct WindowTitleSync: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> WindowTitleView {
        WindowTitleView(title: title)
    }

    func updateNSView(_ view: WindowTitleView, context: Context) {
        view.title = title
    }
}

private final class WindowTitleView: NSView {
    var title: String {
        didSet { window?.title = title }
    }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.title = title
    }
}
