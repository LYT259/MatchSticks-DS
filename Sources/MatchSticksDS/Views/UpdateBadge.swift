import SwiftUI
import DSCore

// MARK: - 更新角标（主窗口原生统一工具栏 .primaryAction 区，紧邻「迷你驾驶台」按钮）
//
// 形态（2026-11-23）：发现新版立即后台下载（无需点击）。顶部初始为圆形下载图标
// （环随进度填充，内含下载箭头），点击展开成胶囊显示系统进度条 + 0–100%，再点收起——
// 展开/收起只是呈现，下载从不因收起而停止。100%（就绪）后再次点击 = 请求安装：
// UpdateCenter.requestRestartAndRelaunch 在点击时刻现场求值 UpdateSafetyGate；阻断期间
// 角标可见但点击无效，tooltip 说明原因。
// checking 只在 GitHub 实际可达、真正开始检查时短暂出现；idle / failed 完全隐藏
// （失败静默，网络恢复后自动重试）。
// 配色只用 DSTheme，动画只用系统默认（.default），不自造颜色与时长。

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
                    tapControl {
                        if flow.showsCapsule {
                            progressCapsule(progress)
                        } else {
                            downloadCircle(progress)
                        }
                    }
                    .help(tr("正在后台下载新版本 %d%%（低优先级，可忽略，不影响使用）", flow.progressPercent))
                case .ready:
                    // 胶囊自带按钮（避免按钮嵌套）；收起圆形经 tapControl 转发为安装请求
                    Group {
                        if flow.showsCapsule { readyButton } else { tapControl { readyCircle } }
                    }
                    .help(readyHelp)
                case .installing:
                    icon("arrow.down.circle.dotted")
                        .help(tr("正在安装更新，应用即将重启…"))
                case .idle, .failed:
                    EmptyView()
                }
            }
            .animation(.default, value: flow.showsCapsule)
            .transition(.opacity)
        }
    }

    private var readyHelp: String {
        let blocked = flow.lastBlockReason != nil
        return blocked
            ? tr("暂不能重启更新：%@。角标保留；满足条件后即可点击。", flow.lastBlockReason ?? "")
            : tr("点击重启并安装新版本。机器人使能中、通信活跃或急停锁存期间点击无效（安全门）。")
    }

    /// 点击：下载中切换展开（下载照常）；就绪时转发为安装请求（安全门在 UpdateCenter 现场求值）。
    private func tapControl<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Button {
            if flow.badgeTapped() == .installRequested { onTap() }
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
    }

    private var readyButton: some View {
        let blocked = flow.lastBlockReason != nil
        return Button(action: onTap) {
            Label(tr("重启更新"), systemImage: blocked ? "lock.circle" : "arrow.clockwise.circle.fill")
        }
        .buttonStyle(DSActionStyle(color: blocked ? DSTheme.accentText : DSTheme.accent, prominent: !blocked))
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(DSTheme.textSecondary)
            .padding(.horizontal, 4)
    }

    /// 收起态：圆形下载图标，外环随进度填充。
    private func downloadCircle(_ progress: Double) -> some View {
        ZStack {
            Circle()
                .stroke(DSTheme.textSecondary.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(DSTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "arrow.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DSTheme.accent)
        }
        .frame(width: 18, height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("正在下载更新"))
        .accessibilityValue("\(flow.progressPercent)%")
    }

    /// 展开态：胶囊 = 下载图标 + 系统进度条 + 0–100%。
    private func progressCapsule(_ progress: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13, weight: .semibold))
            ProgressView(value: progress)
                .tint(DSTheme.accent)
                .frame(width: 84)
            Text("\(flow.progressPercent)%")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 32, alignment: .trailing)
        }
        .foregroundStyle(DSTheme.accent)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(minHeight: 24)
        .background(DSTheme.accentDim, in: Capsule())
        .overlay(Capsule().strokeBorder(DSTheme.accent, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("正在下载更新"))
        .accessibilityValue("\(flow.progressPercent)%")
    }

    /// 就绪收起态：圆形「重启更新」图标；阻断时锁形。
    private var readyCircle: some View {
        let blocked = flow.lastBlockReason != nil
        return Image(systemName: blocked ? "lock.circle.fill" : "arrow.clockwise.circle.fill")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(blocked ? DSTheme.textSecondary : DSTheme.accent)
            .frame(width: 18, height: 18)
            .accessibilityLabel(tr("重启更新"))
    }
}
