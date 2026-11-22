import SwiftUI
import DSCore

// MARK: - 更新角标（主窗口原生统一工具栏 .primaryAction 区，紧邻「迷你驾驶台」按钮）
//
// 下载中 = 进度环；就绪 = 可点「重启更新」；安全门阻断期间角标可见但点击无效，
// tooltip 说明原因。idle / failed 完全隐藏（无更新无感、失败静默跳过）。

struct UpdateBadge: View {
    let flow: UpdateFlowModel
    let onTap: () -> Void

    var body: some View {
        if flow.badgeVisible {
            Group {
                switch flow.phase {
                case .checking:
                    icon("arrow.triangle.2.circlepath")
                        .help(tr("正在检查更新（后台静默，不影响使用）"))
                case .downloading(let progress, _):
                    progressRing(progress)
                        .help(tr("正在后台下载新版本 %d%%（低优先级，可忽略，不影响使用）", Int(progress * 100)))
                case .ready:
                    readyButton
                case .installing:
                    icon("arrow.down.circle.dotted") 
                        .help(tr("正在安装更新，应用即将重启…"))
                case .idle, .failed:
                    EmptyView()
                }
            }
            .transition(.opacity)
        }
    }

    private var readyButton: some View {
        let blocked = flow.lastBlockReason != nil
        return Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: blocked ? "lock.circle" : "arrow.clockwise.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(tr("重启更新")).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                Capsule().fill(Color.accentColor.opacity(blocked ? 0.15 : 0.9))
            )
            .foregroundStyle(blocked ? Color.accentColor : Color.white)
        }
        .buttonStyle(.plain)
        .help(blocked
              ? tr("暂不能重启更新：%@。角标保留；满足条件后即可点击。", flow.lastBlockReason ?? "")
              : tr("点击重启并安装新版本。机器人使能中、通信活跃或急停锁存期间点击无效（安全门）。"))
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private func progressRing(_ progress: Double) -> some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 15, height: 15)
    }
}
