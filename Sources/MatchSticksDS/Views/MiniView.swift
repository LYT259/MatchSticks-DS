import SwiftUI
import DSCore

// MARK: - Mini Driver Station：宽横向驾驶台（2026-11-23 重排）
//
// 参考 FRC Driver Station 的横向布局：左起「返回主窗 / 队伍与连接（含刷新）」，
// 中间机器人状态，右侧电池电压与 Enable/Disable/E-Stop 安全控件，同一横带充分利用宽度。
// 状态含义与安全门沿用主窗同一 DSModel 呈现层（uiStatus / canEnable / estopEngaged）。
//
// MiniConsoleBar 是纯渲染内核（不含 @ObservedObject，可被 ImageRenderer 直接位图化，
// 见 UI 测试渲染几何断言）；语言观察与刷新动作绑定留在薄壳 MiniView。

struct MiniView: View {
    let model: DSModel
    let flow: DriverStationWindowFlow
    @State private var refresh = RobotRefreshFlow()
    // 与主窗一样由观察驱动刷新，避免切换语言时重建整树。
    @ObservedObject private var language = LanguageManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MiniConsoleBar(model: model, flow: flow, refresh: refresh)
            .onAppear {
                refresh.bindAction { model.refreshRobotConnection() }
                // 绑定必须完整：openMini 保留真实 openWindow 兜底。这里会覆盖 RootView
                // 的绑定——若换成空闭包，关闭 Mini 后再次从主窗进入就永远打不开 Mini、
                // 主窗却已被收起（窗口重入缺陷）。openMain 同理兜底主窗不存在的情况。
                flow.perform = { effect in
                    DriverStationWindowPresenter.apply(effect,
                                                       openMini: { openWindow(id: "mini") },
                                                       openMain: { openWindow(id: "main") })
                }
                // Mini 上屏：主窗模式下（状态恢复误开）归一回主窗；
                // Mini 模式下完成切换——此刻 Mini 已可见，收起主窗不再有零窗风险。
                flow.send(.miniWindowAppeared)
            }
    }
}

struct MiniConsoleBar: View {
    let model: DSModel
    let flow: DriverStationWindowFlow
    let refresh: RobotRefreshFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                restoreControl
                Divider().frame(height: 42)
                teamAndConnection
                Divider().frame(height: 42)
                statusCluster
                Spacer(minLength: 12)
                voltageBlock
                Divider().frame(height: 42)
                safetyControls
            }
            footnote
        }
        .padding(16)
        .frame(minWidth: 768, minHeight: 128, alignment: .leading)
        .background(DSTheme.canvas)
        .tint(DSTheme.accent)
        .foregroundStyle(DSTheme.textPrimary)
        .buttonStyle(DSActionStyle())
        .onChange(of: model.commState) { _, _ in
            refresh.noteCommStateChange()
        }
        .task(id: refresh.generation) {
            guard refresh.isRefreshing else { return }
            try? await Task.sleep(for: .seconds(RobotRefreshFlow.maxSpinInterval))
            refresh.settle()
        }
    }

    /// 可发现且可测试的恢复主窗方式：隐藏 Mini、带回完整驾驶台。
    private var restoreControl: some View {
        Button { flow.send(.returnToMainTapped) } label: {
            Label(tr("返回完整驾驶台"), systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .help(tr("隐藏迷你驾驶台并恢复完整主窗口。"))
    }

    private var teamAndConnection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(model.teamNumber > 0 ? "TEAM \(model.teamNumber)" : "MatchSticks DS")
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                refreshButton
            }
            Text(model.connectionDetail)
                .font(.system(size: 11)).foregroundStyle(DSTheme.textSecondary)
        }
        .frame(minWidth: 150, alignment: .leading)
    }

    /// 机器人刷新：真实调用模型重搜动作（清 mDNS 节流、重建候选），图标随反馈旋转。
    private var refreshButton: some View {
        Button { refresh.request() } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .medium))
                .rotationEffect(.degrees(refresh.isRefreshing ? 360 : 0))
                .animation(refresh.isRefreshing
                           ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                           : .default,
                           value: refresh.generation)
        }
        .disabled(model.commConnected)
        .help(tr("刷新机器人连接"))
        .accessibilityLabel(tr("刷新机器人连接"))
    }

    private var statusCluster: some View {
        VStack(alignment: .leading, spacing: 4) {
            DSBadge(text: model.uiStatus, color: model.uiStatusColor,
                    symbol: model.estopEngaged || model.robotStatus.estop
                        ? "exclamationmark.octagon.fill" : "circle.inset.filled")
        }
        .fixedSize()
    }

    private var voltageBlock: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(tr("机器人电池")).font(.system(size: 10)).foregroundStyle(DSTheme.textSecondary)
            Text(model.commConnected ? String(format: "%.2f V", model.batteryVolts) : "— V")
                .font(.system(size: 20, weight: .semibold)).monospacedDigit()
                .foregroundStyle(model.commConnected && model.robotStatus.brownout
                                 ? DSTheme.danger : DSTheme.textPrimary)
        }
    }

    /// 与主窗 SafetyControlBar 同一模型、同一安全门；沿横向排布在驾驶台右端。
    private var safetyControls: some View {
        HStack(spacing: 8) {
            Button { model.setEnabled(true) } label: {
                Label(tr("使能"), systemImage: "play.fill").frame(minWidth: 64, minHeight: 26)
            }
            .buttonStyle(DSActionStyle(color: DSTheme.success, prominent: true))
            .disabled(!model.canEnable || model.remoteEstopReported)
            .help(model.remoteEstopReported
                  ? tr("机器人仍报告急停，使能不可用；等待复位生效或到诊断页重启机器人程序。")
                  : tr("使能机器人（需已连接且无急停）"))
            Button { model.setEnabled(false) } label: {
                Label(tr("失能"), systemImage: "stop.fill").frame(minWidth: 64, minHeight: 26)
            }
            .buttonStyle(DSActionStyle())
            .help(tr("失能机器人"))
            Button { model.triggerEstop() } label: {
                Label(tr("急停"), systemImage: "exclamationmark.octagon.fill").frame(minWidth: 64, minHeight: 26)
            }
            .buttonStyle(DSActionStyle(color: DSTheme.danger, prominent: true))
            .disabled(model.estopEngaged)
            .help(tr("急停"))
        }
    }

    private var footnote: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(model.enableExplanation)
                .font(.system(size: 11)).foregroundStyle(DSTheme.textSecondary)
                .lineLimit(1).truncationMode(.tail)
            if model.estopEngaged {
                Button(tr("复位急停（请求重启程序）")) { model.resetEstop() }
                    .buttonStyle(DSActionStyle())
                    .help(tr("请求重启机器人程序以解除急停锁存。快捷键：Esc + I。"))
            }
            Spacer(minLength: 0)
        }
    }
}
