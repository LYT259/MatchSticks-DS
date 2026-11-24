import Foundation

// MARK: - 更新检查调度（纯状态机；Sparkle 无关，test-ui.sh 干测试覆盖）
//
// 规则：任何一次 Sparkle 检查之前，必须先由真实 HTTPS 请求确认 GitHub 可达（探测：先系统默认路由，
// 失败再明确试一次有线 Ethernet，见 UpdateReachability）。不可达 → 按有上限的指数退避计时重试，
// 网络路径变化立即唤醒；探测成功 → 触发检查。同一时刻最多一个探测、一个检查、一个计时；
// Sparkle 自己的周期检查由 `mayPerformUpdateCheck` 闸门按 `reachabilityConfirmed` 放行或拒绝，
// 拒绝即回到探测路径。等待期间永远持有一个唤醒源（计时或路径事件），Sparkle 忙时看门狗有界重试、
// 绝不静默丢弃待触发。
//
// 本类不持有定时器与网络：每次输入返回一个 Action，由 UpdateCenter 执行
// （探测 / 触发检查 / 计时 / 看门狗），从而可以逐转移做行为测试。

@MainActor
final class UpdateCheckScheduler {

    enum State: Equatable {
        case idle                                           // 无待办（无更新 / 未开始）
        case probing                                       // HTTPS 探测进行中
        case waiting(attempt: Int, delay: TimeInterval)    // 退避计时中
        case checking(triggerPending: Bool)                // 检查进行中；pending = 触发被 Sparkle 忙态拒绝、等看门狗重试
    }

    enum Action: Equatable {
        case none
        case probe                             // 立即发一次 HTTPS 探测
        case check                             // 可达已确认 → 立即触发 Sparkle 检查
        case wait(delay: TimeInterval)        // 退避计时（网络变化 / 到期 → probe）
        case watchdog(delay: TimeInterval)     // Sparkle 忙：短暂等待后再试触发
    }

    enum CheckResult: Equatable {
        case noUpdate         // 本轮检查完成且无新版 → 静默空闲（Sparkle 自己的周期照常）
        case failed           // appcast 拉取 / 下载失败 → 退避后重试
        case deniedOffline    // Sparkle 自己发起的检查被闸门拒绝 → 立即走探测路径
    }

    static let initialRetryDelay: TimeInterval = 3
    static let maximumRetryDelay: TimeInterval = 15 * 60
    static let triggerWatchdogDelay: TimeInterval = 1
    static let maximumBusyWatchdogs: Int = 10
    static let busyGiveUpDelay: TimeInterval = 30

    private(set) var state: State = .idle
    /// 当前可达是否已被真实请求确认（UpdateCenter 的 mayPerformUpdateCheck 闸门读取）
    private(set) var reachabilityConfirmed = false
    /// 当前探测成功并授权给 Sparkle 请求的路径；探测失败 / 周期结束即清除。
    private(set) var updateRoute: UpdateProbeRoute?
    /// 连续失败次数（探测成功归零）
    private(set) var attempt = 0
    private var pathChangedDuringProbe = false
    /// 连续「看门狗到期 Sparkle 仍忙」次数（成功触发 / 新一轮探测归零）
    private var busyWatchdogCount = 0

    /// 退避表：首延 3 秒，逐次翻倍，上限 15 分钟。
    static func backoffDelay(attempt: Int) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        let delay = initialRetryDelay * pow(2, Double(min(exponent, 30)))
        return min(delay, maximumRetryDelay)
    }

    // MARK: 输入

    /// 需要一次检查（启动 / 渠道变化 / Sparkle 周期被拒）：空闲或等待中 → 立即探测；
    /// 已在探测或检查中 → 合并（不重复）。
    func requestCheck() -> Action {
        switch state {
        case .idle, .waiting:
            beginProbe()
            return .probe
        case .probing, .checking:
            return .none
        }
    }

    /// 探测结果：GitHub 实际响应（任何 HTTP 状态码，含私有仓库 404）= 可达。
    func probeSucceeded(route: UpdateProbeRoute = .defaultRoute) -> Action {
        state = .checking(triggerPending: true)
        reachabilityConfirmed = true
        updateRoute = route
        attempt = 0
        pathChangedDuringProbe = false
        busyWatchdogCount = 0
        return .check
    }

    /// 探测失败（无连接 / DNS / TLS / 超时）：退避计时；若探测期间路径变化则立即再探一次。
    func probeFailed() -> Action {
        reachabilityConfirmed = false
        updateRoute = nil
        attempt += 1
        let immediate = pathChangedDuringProbe
        pathChangedDuringProbe = false
        if immediate {
            state = .probing
            return .probe
        }
        let delay = Self.backoffDelay(attempt: attempt)
        state = .waiting(attempt: attempt, delay: delay)
        return .wait(delay: delay)
    }

    /// 网络路径变化（NWPathMonitor，默认路径 ∥ 有线 Ethernet 路径任一可用即 satisfied）：
    /// 等待中且路径可用 → 立即探测；路径不可用 → 保留计时（每次到期探测快速失败后继续退避，
    /// 绝不失去唤醒源）；探测中 → 记录标记，由探测结果决定。
    func networkChanged(satisfied: Bool) -> Action {
        switch state {
        case .waiting:
            guard satisfied else { return .none }
            beginProbe()
            return .probe
        case .probing:
            pathChangedDuringProbe = true
            return .none
        case .idle, .checking:
            return .none
        }
    }

    /// 退避计时到期。
    func timerFired() -> Action {
        guard case .waiting = state else { return .none }
        beginProbe()
        return .probe
    }

    /// 触发被 Sparkle 拒绝（已有会话进行中）：挂看门狗短暂等待。
    func checkTriggerRefused() -> Action {
        state = .checking(triggerPending: true)
        busyWatchdogCount = 0
        return .watchdog(delay: Self.triggerWatchdogDelay)
    }

    /// 触发已被 Sparkle 接受。
    func checkTriggerAccepted() {
        state = .checking(triggerPending: false)
        busyWatchdogCount = 0
    }

    /// 看门狗到期：Sparkle 已空闲 → 再次触发；仍忙 → 有界地再等（最多 maximumBusyWatchdogs 次），
    /// 预算耗尽则转入定时重探（busyGiveUpDelay），绝不静默丢弃——Sparkle 的
    /// checkForUpdatesInBackground 在忙时静默返回且不回调，启动期安装器状态探测也不是一轮周期。
    func watchdogFired(updaterBusy: Bool) -> Action {
        guard case .checking(let pending) = state, pending else { return .none }
        guard updaterBusy else {
            busyWatchdogCount = 0
            return .check
        }
        busyWatchdogCount += 1
        if busyWatchdogCount <= Self.maximumBusyWatchdogs {
            return .watchdog(delay: Self.triggerWatchdogDelay)
        }
        busyWatchdogCount = 0
        updateRoute = nil
        state = .waiting(attempt: attempt, delay: Self.busyGiveUpDelay)
        return .wait(delay: Self.busyGiveUpDelay)
    }

    /// 一轮 Sparkle 检查结束（delegate didFinishUpdateCycle）。待触发标志随状态转移一并清除：
    /// Sparkle 自己的周期已替我们查过，不再补发第二个检查。
    func checkFinished(_ result: CheckResult) -> Action {
        reachabilityConfirmed = false
        updateRoute = nil
        busyWatchdogCount = 0
        switch result {
        case .noUpdate:
            state = .idle
            return .none
        case .failed:
            guard case .waiting = state else {
                attempt += 1
                let delay = Self.backoffDelay(attempt: attempt)
                state = .waiting(attempt: attempt, delay: delay)
                return .wait(delay: delay)
            }
            return .none
        case .deniedOffline:
            // 被拒的周期 = 此刻应有一次检查：空闲 / 待触发 → 立即探测；已在退避或探测中 → 照旧
            switch state {
            case .probing, .waiting: return .none
            case .idle, .checking:
                beginProbe()
                return .probe
            }
        }
    }

    private func beginProbe() {
        state = .probing
        updateRoute = nil
        pathChangedDuringProbe = false
    }
}
