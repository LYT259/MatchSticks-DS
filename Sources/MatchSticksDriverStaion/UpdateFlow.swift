import SwiftUI
import DSCore

// MARK: - 更新流状态机（Sparkle 无关；test-ui.sh 干测试覆盖）
//
// 「ChatGPT 式」UX（报告 §5.5）的纯状态侧：下载进度 → 就绪 → 点击重启安装。
// 角标形态：下载中初始为圆形下载图标，点击展开成胶囊显示 0–100%，再点收起；
// 展开/收起只是呈现（isExpanded），不改变下载阶段、进度或版本——下载从不因收起而停止。
// 就绪（100%）后再次点击 = 请求安装：沿用 UpdateSafetyGate 在点击时刻现场求值，
// 不缓存判定（下载完成到点击之间机器人状态可能变化）；未接入门状态时保守阻断。

@MainActor
@Observable
final class UpdateFlowModel {

    enum Phase: Equatable {
        case idle                    // 完全无感（无更新 / 检查完毕）
        case checking                // Sparkle 检查进行中（仅 GitHub 可达后才会进入）
        case downloading(progress: Double, version: String)
        case ready(version: String)
        case failed                  // 下载失败静默跳过，网络恢复后自动重试
        case installing
    }

    private(set) var phase: Phase = .idle
    /// 胶囊展开态（纯呈现）：收起/展开不影响下载；新一轮下载从收起态开始。
    private(set) var isExpanded = false
    /// 最近一次阻断原因（角标 tooltip 用；nil = 当前无阻断记录）
    private(set) var lastBlockReason: String?

    /// 安全门状态源；nil = 未接入（保守阻断）。生产环境由 UpdateCenter 注入 DSModel。
    var gateStateProvider: (() -> UpdateSafetyGate.State?)?

    enum RestartOutcome: Equatable {
        case initiated
        case blocked(reason: String)
        case notReady
    }

    /// 角标点击的呈现层语义：下载中 = 切换展开；就绪 = 请求安装（视图转发给 onTap）；
    /// 其余阶段忽略。
    enum BadgeTap: Equatable {
        case expansionToggled
        case installRequested
        case ignored
    }

    // MARK: 供更新驱动（UpdateCenter）回调喂数据

    func beganCheck() {
        if phase == .idle || phase == .failed { phase = .checking }
    }

    func updateNotFound() {
        if phase != .installing { phase = .idle }
        isExpanded = false
    }

    func downloadStarted(version: String) {
        isExpanded = false
        phase = .downloading(progress: 0, version: version)
    }

    func downloadProgress(_ fraction: Double) {
        guard case .downloading(_, let version) = phase else { return }
        phase = .downloading(progress: min(max(fraction, 0), 1), version: version)
    }

    func downloadCompleted(version: String) {
        if phase != .installing { phase = .ready(version: version) }
    }

    /// 安装阶段（点击放行后 / 安装器接管后）
    func beganInstalling() {
        phase = .installing
    }

    func failedQuietly() {
        if phase != .installing { phase = .failed }
        isExpanded = false
    }

    var badgeVisible: Bool {
        switch phase {
        case .idle, .failed: return false
        case .checking, .downloading, .ready, .installing: return true
        }
    }

    // MARK: 角标呈现

    /// 下载进度百分数（0–100，四舍五入并夹紧）；非下载阶段为 0。
    var progressPercent: Int {
        guard case .downloading(let progress, _) = phase else { return 0 }
        return min(max(Int((progress * 100).rounded()), 0), 100)
    }

    /// 就绪态仍沿用上次展开：胶囊直接变成「重启更新」。
    var showsCapsule: Bool {
        switch phase {
        case .downloading, .ready: return isExpanded
        case .checking, .installing, .idle, .failed: return false
        }
    }

    /// 角标点击：下载中只切换展开（下载照常）；就绪时请求安装。
    @discardableResult
    func badgeTapped() -> BadgeTap {
        switch phase {
        case .downloading:
            isExpanded.toggle()
            return .expansionToggled
        case .ready:
            return .installRequested
        case .checking, .installing, .idle, .failed:
            return .ignored
        }
    }

    // MARK: 安装咽喉点

    /// 点击「重启更新」：唯一放行通道，现场求值安全门
    func requestRestart() -> RestartOutcome {
        guard case .ready = phase else { return .notReady }
        guard let state = gateStateProvider?() else {
            lastBlockReason = tr("驾驶台状态未接入（安全门保守阻断）")
            return .blocked(reason: lastBlockReason!)
        }
        switch UpdateSafetyGate.evaluate(state) {
        case .blocked(let reason):
            lastBlockReason = reason
            return .blocked(reason: reason)
        case .allow:
            lastBlockReason = nil
            phase = .installing
            return .initiated
        }
    }
}
