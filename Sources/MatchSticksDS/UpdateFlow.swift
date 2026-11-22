import SwiftUI
import DSCore

// MARK: - 更新流状态机（Sparkle 无关；test-ui.sh 干测试覆盖）
//
// 「ChatGPT 式」UX（报告 §5.5）的纯状态侧：下载进度 → 就绪 → 点击重启安装。
// 安全门纪律：requestRestart() 在点击时刻现场求值 UpdateSafetyGate，
// 不缓存判定（下载完成到点击之间机器人状态可能变化）；未接入门状态时保守阻断。

@MainActor
@Observable
final class UpdateFlowModel {

    enum Phase: Equatable {
        case idle                    // 完全无感（无更新 / 检查完毕）
        case checking
        case downloading(progress: Double, version: String)
        case ready(version: String)
        case failed                  // 下载失败静默跳过，下次启动再试
        case installing
    }

    private(set) var phase: Phase = .idle
    /// 最近一次阻断原因（角标 tooltip 用；nil = 当前无阻断记录）
    private(set) var lastBlockReason: String?

    /// 安全门状态源；nil = 未接入（保守阻断）。生产环境由 UpdateCenter 注入 DSModel。
    var gateStateProvider: (() -> UpdateSafetyGate.State?)?

    enum RestartOutcome: Equatable {
        case initiated
        case blocked(reason: String)
        case notReady
    }

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

    // MARK: 供更新驱动（UpdateCenter）回调喂数据

    func beganCheck() {
        if phase == .idle || phase == .failed { phase = .checking }
    }

    func updateNotFound() {
        if phase != .installing { phase = .idle }
    }

    func downloadStarted(version: String) {
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
    }

    var badgeVisible: Bool {
        switch phase {
        case .idle, .failed: return false
        case .checking, .downloading, .ready, .installing: return true
        }
    }
}
