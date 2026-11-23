import Foundation
import Sparkle
import DSCore

// MARK: - Sparkle 装配层（MatchSticks DS 专属；不进 test-ui.sh 编译清单）
//
// UX（报告 §5.5 / CLAUDE.md 分发章 / ADR-0004）：
// - 每次启动只在 GitHub 实际可达时检查：UpdateCheckScheduler 先经真实 HTTPS 探测（UpdateReachability：
//   先系统默认路由，失败后明确经非 Wi‑Fi 路径——有线 Ethernet——再探一次），可达才触发 Sparkle 检查；
//   探测成功的 route 同时交给 UpdateURLProtocol，Sparkle feed / enclosure 使用同一路径（默认成功不重复，
//   默认失败而有线成功则两者都走有线）。不可达按有上限的指数退避持续重试，网络路径变化立即唤醒——
//   连上后自动检查并下载，永不阻塞使用、不弹窗。
// - 所有 Sparkle 检查（含 Sparkle 自己的 24h 周期）都经 mayPerform 闸门（ObjC mayPerformUpdateCheck）：
//   可达未确认即拒绝，被拒的周期在 didFinishUpdateCycle 里回到探测路径。静默后台检查失败 /
//   无更新不会调用户驱动，因此周期收尾统一在 didFinishUpdateCycle（无更新 → 角标回无感；
//   失败 → 退避重试）。Sparkle 忙时看门狗有界重试、绝不静默丢弃待触发（见 UpdateCheckScheduler）。
// - 渠道：stable / beta 由 Settings 持久化（DSModel.updateChannel），映射为 Sparkle 原生
//   allowedChannels（appcast 中带 <sparkle:channel>beta</sparkle:channel> 的条目只对 beta 渠道可见）。
//   切换渠道 → 请求一次检查（同样先探测）。feed 地址：MATCHSTICKS_DS_FEED_URL 测试覆盖，否则
//   Info.plist SUFeedURL（GitHub Releases appcast）；绝不嵌入 GitHub 凭证。
// - 发现新版立即后台下载（无需点击）→ 角标圆形 → 点击展开胶囊显示 0–100% → 100% 后再次点击
//   → UpdateSafetyGate 现场求值 → 用已下载包重启安装。
//
// 安全门（安全链级）：更新走 UI 驱动流，进程存续期内安装的唯一触发是 showReady 的回复闭包——
// 下载就绪只落位角标（stash 回复、不调用）；点击角标 → UpdateSafetyGate 现场求值 → 放行才回 .install。
//
// 退出路径语义（Sparkle 固有设计，2026-10-01 本地升级链路 E2E 实测确认）：
// 宿主进程死亡（退出/崩溃/强杀）后，独立的安装器进程会完成挂起的安装，但不会自动重启应用。
// 此行为无法关断，也不构成新风险——进程死亡瞬间机器人已失去 DS、看门狗自动失能输出。
// 双保险：willInstallUpdateOnQuit 拦截返回 YES（若未来落入自动下载驱动路径，同样不调用 handler
// 就不安装）。Sparkle 源码见 SPUAutomaticUpdateDriver.m
// installerDidFinishPreparationAndWillInstallImmediately（“返回 YES 即接管”）。
// 安全依据：DS 运行中重启 = 控制包中断 → robot 侧看门狗自动 disable。

@MainActor
final class UpdateCenter {

    let flow = UpdateFlowModel()
    /// 检查调度（纯状态机）：探测可达 → 检查；不可达退避重试；网络变化唤醒
    let scheduler = UpdateCheckScheduler()

    /// 事件日志（接入 DSModel.log；亦随 Diag 镜像到 stderr/文件，E2E 断言用）
    var logLine: ((String) -> Void)?

    /// E2E 测试钩子：MATCHSTICKS_DS_UPDATE_AUTOTAP=1 时就绪后替操作员点击角标
    /// （安全门照常现场求值；旧 GHDS_UPDATE_AUTOTAP 仍兼容）；
    /// MATCHSTICKS_DS_UPDATE_AUTOTAP_DELAY=<秒> 可延时点击（Leg B 等连接建立后再点，消除竞态）
    private let autoTap = DSEnvironment.isEnabled("UPDATE_AUTOTAP")
    private let autoTapDelay = TimeInterval(DSEnvironment.string("UPDATE_AUTOTAP_DELAY") ?? "") ?? 0

    /// 闸门拒绝 Sparkle 检查时交给 Sparkle 的错误域 / 码（didFinishUpdateCycle 据此识别「不是真失败」）
    static let offlineDenialDomain = "org.ghfrc.driverstation.update.offline"
    static let offlineDenialCode = 1

    private weak var model: DSModel?
    private var updater: SPUUpdater?
    private var pendingVersion = ""
    /// 点击放行后真正触发安装的唯一 handler（willInstallUpdateOnQuit 拦截接管所得）
    private var immediateInstallHandler: (() -> Void)?
    /// showReadyToInstallAndRelaunch 的回复（immediateInstallHandler 缺席时的兜底路径）
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var reachability: UpdateReachability?
    private var delegate: UpdateDelegate?
    private var driver: SilentUpdateDriver?
    private var routing: UpdateRequestRouting { .shared }
    /// 退避计时与看门狗（调度器只给动作，计时由本类持有；同一时刻各最多一个）
    private var retryTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    // MARK: 接入应用

    func attach(model: DSModel) {
        self.model = model
        flow.gateStateProvider = { [weak model] in model?.updateGateState }
        logLine = { [weak model] line in model?.log(line) }
        model.onUpdateChannelChange = { [weak self] channel in self?.channelChanged(to: channel) }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    fileprivate var channel: UpdateChannel { model?.updateChannel ?? .stable }

    /// feed 地址：环境变量 MATCHSTICKS_DS_FEED_URL（旧 GHDS_FEED_URL 兼容）覆盖（本地升级链路 E2E 用）；
    /// 否则 Info.plist SUFeedURL（生产 = GitHub Releases 托管 appcast）。
    private var feedURLString: String {
        DSEnvironment.string("FEED_URL")
            ?? (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)
            ?? ""
    }

    func start() {
        // 仅 .app bundle 内启用（.build 裸跑 / UI 干测试不打扰）；可用环境变量显式关闭
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        guard !DSEnvironment.isEnabled("DISABLE_UPDATE") else {
            // 日志同时说明新旧 env；旧 GHDS_ 前缀仍经 DSEnvironment 回退生效。
            let legacyNote: String
            switch LanguageManager.shared.currentEffective {
            case .chinese:
                legacyNote = "；旧 GHDS_DISABLE_UPDATE=1 同样生效"
            case .english:
                legacyNote = " / legacy GHDS_DISABLE_UPDATE=1 also applies"
            }
            logLine?(tr("更新组件已禁用（MATCHSTICKS_DS_DISABLE_UPDATE=1）") + legacyNote)
            return
        }
        let delegate = UpdateDelegate(center: self)
        let driver = SilentUpdateDriver(center: self)
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: delegate
        )
        updater.automaticallyChecksForUpdates = true
        // 关键：不开 Sparkle 的「自动下载安装」模式。走 UI 驱动流（showUpdateFound →
        // showReady）才能拿到 showReady 回调（自动下载驱动 SPUAutomaticUpdateDriver 从不
        // 调 showReady，只会静默挂起）；「静默后台下载」体验由我们在 showUpdateFound 里
        // 立即回 .install 保持，UX 与报告 §5.5 一致（无窗、无确认、低打扰）。
        updater.automaticallyDownloadsUpdates = false
        // 测试钩子：缩短检查周期（升级链路 E2E Leg B 防竞态——等连接建立后再放出 appcast）
        if let raw = DSEnvironment.string("UPDATE_CHECK_INTERVAL"),
           let interval = TimeInterval(raw), interval > 0 {
            updater.updateCheckInterval = interval
        }
        self.updater = updater
        self.delegate = delegate
        self.driver = driver
        routing.transport = SystemUpdateRequestTransport()
        URLProtocol.registerClass(UpdateURLProtocol.self)

        do {
            try updater.start()
            let feed = feedURLString.isEmpty ? tr("未配置") : feedURLString
            logLine?(tr("更新组件就绪（当前版本 %@，feed %@，渠道 %@）", currentVersion, feed, channel.displayName))
            let reachability = UpdateReachability(probeURL: URL(string: feedURLString))
            reachability.onResult = { [weak self] result in
                self?.probeFinished(result)
            }
            reachability.onPathChange = { [weak self] satisfied in
                self?.networkPathChanged(satisfied: satisfied)
            }
            reachability.start()
            self.reachability = reachability
            // 启动不再直接调 checkForUpdatesInBackground：Sparkle start() 之后 sessionInProgress
            // 必为 YES（启动期异步探测安装器状态），直接调用会被 Sparkle 丢弃；而且无法保证
            // GitHub 可达。改为先探测，可达才触发。Sparkle 自己的「超期即查」经 mayPerformUpdateCheck
            // 闸门同样被拦到探测路径，不会在离线时空跑。
            apply(scheduler.requestCheck())
        } catch {
            // 配置缺失（feed URL/公钥未配置）等：静默跳过，不影响使用
            logLine?(tr("更新组件未启动：%@（不影响使用）", error.localizedDescription))
        }
    }

    // MARK: 调度动作执行（探测 / 检查 / 计时）

    private func apply(_ action: UpdateCheckScheduler.Action) {
        switch action {
        case .none:
            break
        case .probe:
            cancelTimers()
            routing.deactivate()
            guard let reachability else {
                // 探测器尚未装配（start() 之前不应到达）：按一次失败退避，start() 的 requestCheck 会接管
                apply(scheduler.probeFailed())
                return
            }
            reachability.probe()
        case .check:
            cancelTimers()
            performCheck()
        case .wait(let delay):
            cancelTimers()
            routing.deactivate()
            scheduleRetry(after: delay)
        case .watchdog(delay: let delay):
            cancelTimers()
            scheduleWatchdog(after: delay)
        }
    }

    private func probeFinished(_ result: UpdateProbeResult) {
        if result.reachable {
            if result.route == .wiredEthernet {
                logLine?(tr("默认路由不可达，经有线 Ethernet 连通 GitHub：%@", result.detail))
            }
            routing.activate(route: result.route)
            apply(scheduler.probeSucceeded(route: result.route))
            return
        }
        routing.deactivate()
        let action = scheduler.probeFailed()
        if case .wait(let delay) = action {
            logLine?(tr("GitHub 不可达，%d 秒后重试（第 %d 次）：%@", Int(delay), scheduler.attempt, result.detail))
        }
        apply(action)
    }

    private func networkPathChanged(satisfied: Bool) {
        let action = scheduler.networkChanged(satisfied: satisfied)
        if case .probe = action {
            logLine?(tr("网络路径变化，立即重新探测 GitHub"))
        }
        apply(action)
    }

    private func channelChanged(to channel: UpdateChannel) {
        // Sparkle 每次加载 appcast 都重新读取 allowedChannels（SUAppcastDriver），所以这里只需请求一次检查
        // （同样先探测可达）。检查进行中 / 正在下载 / 已就绪时 Sparkle 会话未结束，请求会被合并，
        // 新渠道在下一个周期生效，不影响已下载的包。更新组件未启动（.app 之外 / 已禁用 / 配置失败）时无事可做。
        guard reachability != nil else { return }
        logLine?(tr("更新渠道切换为 %@（GitHub 可达时重新检查）", channel.displayName))
        apply(scheduler.requestCheck())
    }

    /// 真正触发 Sparkle 后台检查。Sparkle 正忙（已有会话）时挂看门狗有界重试，
    /// 绝不并发第二个 updater/check。
    private func performCheck() {
        guard let updater else {
            routing.deactivate()
            apply(scheduler.checkFinished(.failed))
            return
        }
        if updater.sessionInProgress {
            logLine?(tr("检查触发被 Sparkle 拒绝（已有检查进行中），稍后重试"))
            apply(scheduler.checkTriggerRefused())
            return
        }
        flow.beganCheck()
        scheduler.checkTriggerAccepted()
        logLine?(tr("GitHub 可达，开始检查更新（渠道 %@）", channel.displayName))
        updater.checkForUpdatesInBackground()
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.apply(self.scheduler.timerFired())
        }
    }

    private func scheduleWatchdog(after delay: TimeInterval) {
        watchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let busy = self.updater?.sessionInProgress ?? true
            self.apply(self.scheduler.watchdogFired(updaterBusy: busy))
        }
    }

    private func cancelTimers() {
        retryTask?.cancel()
        retryTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    // MARK: 安装咽喉点

    /// 角标点击 / AUTOTAP 的唯一入口：现场求值安全门后触发安装
    func requestRestartAndRelaunch() {
        switch flow.requestRestart() {
        case .notReady:
            break
        case .blocked(let reason):
            logLine?(tr("重启更新被安全门阻断：%@", reason))
        case .initiated:
            logLine?(tr("重启更新：安全门放行（%@ → %@），立即安装并重启", currentVersion, pendingVersion))
            triggerInstall()
        }
    }

    private func triggerInstall() {
        if let handler = immediateInstallHandler {
            handler()
        } else if let reply = readyReply {
            reply(.install)
        } else {
            // 理论不可达（ready 必有其一）；防御式回退：回到就绪态
            flow.downloadCompleted(version: pendingVersion)
        }
    }

    // MARK: 驱动回调（SilentUpdateDriver 转发，均在主线程）

    fileprivate func driverFoundUpdate(version: String) {
        pendingVersion = version
        logLine?(tr("发现新版本 %@（开始后台静默下载）", version))
        flow.downloadStarted(version: version)
    }

    fileprivate func driverDownloadProgress(_ fraction: Double) {
        flow.downloadProgress(fraction)
    }

    fileprivate func driverReadyToInstall(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        readyReply = reply
        flow.downloadCompleted(version: pendingVersion)
        logLine?(tr("新版本 %@ 下载就绪（点击角标重启安装；使能/连接/急停锁存期间点击无效）", pendingVersion))
        if autoTap {
            if autoTapDelay > 0 {
                logLine?(tr("AUTOTAP：%ds 后替操作员点击重启更新（安全门照常现场求值）", Int(autoTapDelay)))
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(autoTapDelay))
                    // 延时窗口内可能已被人工安装/状态已变——requestRestartAndRelaunch 自身幂等把关
                    requestRestartAndRelaunch()
                }
            } else {
                logLine?(tr("AUTOTAP：替操作员点击重启更新（安全门照常现场求值）"))
                requestRestartAndRelaunch()
            }
        }
    }

    /// willInstallUpdateOnQuit 拦截（Sparkle 语义：返回 YES 即接管，见文件头注释）
    fileprivate func driverTookOverInstall(installHandler: @escaping () -> Void) {
        immediateInstallHandler = installHandler
    }

    /// 静默后台检查「无更新」不会调到这里（仅用户可见的检查才会）；无更新收尾见 cycleFinished
    fileprivate func driverFoundNoUpdate() {
        flow.updateNotFound()
    }

    /// 下载失败（仅在 showUpdateFound 之后才会被调）：静默、角标隐藏；重试由 cycleFinished 安排
    fileprivate func driverFailed() {
        flow.failedQuietly()
    }

    fileprivate func driverInstalling() {
        flow.beganInstalling()
    }

    // MARK: 周期收尾（SPUUpdaterDelegate.didFinishUpdateCycle；所有检查的唯一收尾点）

    fileprivate func cycleFinished(error: Error?) {
        guard let error else {
            // 周期以「发现更新」结束：驱动在等 showReady 的回复，下载仍需沿用当前 route
            apply(scheduler.checkFinished(.noUpdate))
            return
        }
        routing.deactivate()
        let nsError = error as NSError
        if nsError.domain == Self.offlineDenialDomain && nsError.code == Self.offlineDenialCode {
            // 自己的闸门拒绝的周期：不是失败，回到探测路径（可达后再查）
            apply(scheduler.checkFinished(.deniedOffline))
            return
        }
        guard nsError.domain == SUSparkleErrorDomain,
              let code = SUError(rawValue: Int32(nsError.code)) else { return }
        switch code {
        case .noUpdateError:
            flow.updateNotFound()
            logLine?(tr("更新检查完成：已是最新版本"))
            apply(scheduler.checkFinished(.noUpdate))
        case .installationCanceledError, .installationAuthorizeLaterError:
            apply(scheduler.checkFinished(.noUpdate))
        default:
            // appcast 拉取失败（含私有仓库 404）/ 下载失败：静默、不阻塞，退避后重试
            flow.failedQuietly()
            let action = scheduler.checkFinished(.failed)
            if case .wait(let delay) = action {
                logLine?(tr("更新检查失败（静默跳过，%d 秒后重试）：%@", Int(delay), error.localizedDescription))
            }
            apply(action)
        }
    }
}

// MARK: - 静默用户驱动：无窗口、无弹窗，全部状态喂 UpdateFlowModel

@MainActor
private final class SilentUpdateDriver: NSObject, SPUUserDriver {

    weak var center: UpdateCenter?
    init(center: UpdateCenter) { self.center = center }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // 静默授权：自动检查 + 自动下载；不发送系统概况
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: true,
            automaticUpdateDownloading: NSNumber(value: true),
            sendSystemProfile: false
        ))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        // 本应用不提供手动检查入口（无弹窗 UX）；该回调不会被触发
        cancellation()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // 静默自动下载：发现即回 .install（Sparkle 走后台下载，无确认弹窗）
        center?.driverFoundUpdate(version: appcastItem.versionString)
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        // “未找到更新”在 Sparkle 里也走 error 形态；按无更新处理
        center?.driverFoundNoUpdate()
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        center?.driverFailed()
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {}

    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        receivedLength = 0
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        if expectedLength > 0 {
            center?.driverDownloadProgress(Double(receivedLength) / Double(expectedLength))
        }
    }

    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {
        center?.driverDownloadProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        center?.driverReadyToInstall(reply: reply)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        center?.driverInstalling()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {}
}


// MARK: - SPUUpdaterDelegate：feed 覆盖（测试钩子）+ 渠道过滤 + 可达闸门 + 安装接管（安全门咽喉点）

@MainActor
private final class UpdateDelegate: NSObject, SPUUpdaterDelegate {

    weak var center: UpdateCenter?
    private var routing: UpdateRequestRouting { .shared }
    init(center: UpdateCenter) { self.center = center }

    /// feed 地址：环境变量 MATCHSTICKS_DS_FEED_URL（旧 GHDS_FEED_URL 兼容）覆盖
    /// （本地升级链路 E2E 用）；否则回落 Info.plist SUFeedURL（生产 = GitHub Releases 托管 appcast）。
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        DSEnvironment.string("FEED_URL")
    }

    /// feed 查询参数只携带本进程随机路由 token；URLProtocol 在发往源站前移除。
    nonisolated func feedParameters(for updater: SPUUpdater, sendingSystemProfile: Bool) -> [[String: String]] {
        UpdateRequestRouting.shared.feedParameters()
    }

    /// enclosure 是公开可标记的下载请求；重定向由更新 transport 内部跟随，保持同一非 Wi‑Fi 路径。
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        routing.markDownload(request)
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool {
        false
    }

    /// 渠道过滤（Sparkle 原生）：stable = 仅默认渠道；beta = 默认渠道 + beta。
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        center?.channel.allowedSparkleChannels ?? []
    }

    /// 可达闸门：GitHub 可达未经真实请求确认时拒绝一切检查（含 Sparkle 自己的周期检查）；
    /// 被拒的周期在 didFinishUpdateCycle 中回到探测路径。
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard center?.scheduler.reachabilityConfirmed == true else {
            throw NSError(domain: UpdateCenter.offlineDenialDomain, code: UpdateCenter.offlineDenialCode,
                          userInfo: [NSLocalizedDescriptionKey: "GitHub unreachable; update check deferred"])
        }
    }

    /// 一轮检查结束的唯一收尾点（静默后台的失败 / 无更新不会调用户驱动）
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        center?.cycleFinished(error: error)
    }

    /// 安装咽喉点（见 UpdateCenter 文件头）：返回 true 接管——此后仅当
    /// 本进程主动调用 installHandler 才会安装（含应用退出路径）。
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock installHandler: @escaping () -> Void) -> Bool {
        center?.driverTookOverInstall(installHandler: installHandler)
        return true
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { true }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        center?.logLine?(tr("更新：应用即将重启（安装器接管）"))
    }
}
