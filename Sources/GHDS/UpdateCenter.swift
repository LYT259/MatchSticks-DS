import Foundation
import Sparkle
import DSCore

// MARK: - Sparkle 装配层（GHDS 专属；不进 test-ui.sh 编译清单）
//
// UX（报告 §5.5 / CLAUDE.md 分发章）：启动静默查 → 静默后台下载 → 固定角落进度角标
// （可忽略、无弹窗）→ 点击一键重启安装；下载失败静默跳过、下次启动再试、永不阻塞使用。
//
// 安全门（安全链级）：更新走 UI 驱动流，进程存续期内安装的唯一触发是 showReady 的
// 回复闭包——下载就绪只落位角标（stash 回复、不调用）；点击角标 → UpdateSafetyGate
// 现场求值 → 放行才回 .install（Sparkle 随即终止本进程、安装器原子替换并重启）。
//
// 退出路径语义（Sparkle 固有设计，2026-10-01 本地升级链路 E2E 实测确认）：
// 宿主进程死亡（退出/崩溃/强杀）后，独立的安装器进程会完成挂起的安装，但不会自动
// 重启应用。此行为无法关断，也不构成新风险——进程死亡瞬间机器人已失去 DS、看门狗
// 自动失能输出；完成安装不会让任何电机得电。安全门管控的是「进程存续期内的更新
// 触发」，这正是操作员可误触的唯一路径。
// 双保险：willInstallUpdateOnQuit 拦截返回 YES（若未来落入自动下载驱动路径，同样
// 不调用 handler 就不安装）。Sparkle 源码见 SPUAutomaticUpdateDriver.m
// installerDidFinishPreparationAndWillInstallImmediately（“返回 YES 即接管”）。
// 安全依据：DS 运行中重启 = 控制包中断 → robot 侧看门狗自动 disable。

@MainActor
final class UpdateCenter {

    let flow = UpdateFlowModel()

    /// 事件日志（接入 DSModel.log；亦随 Diag 镜像到 stderr/文件，E2E 断言用）
    var logLine: ((String) -> Void)?

    /// E2E 测试钩子：GHDS_UPDATE_AUTOTAP=1 时就绪后替操作员点击角标（安全门照常现场求值）；
    /// GHDS_UPDATE_AUTOTAP_DELAY=<秒> 可延时点击（Leg B 等连接建立后再点，消除竞态）
    private let autoTap = ProcessInfo.processInfo.environment["GHDS_UPDATE_AUTOTAP"] == "1"
    private let autoTapDelay = TimeInterval(ProcessInfo.processInfo.environment["GHDS_UPDATE_AUTOTAP_DELAY"] ?? "") ?? 0

    private var updater: SPUUpdater?
    private var pendingVersion = ""
    /// 点击放行后真正触发安装的唯一 handler（willInstallUpdateOnQuit 拦截接管所得）
    private var immediateInstallHandler: (() -> Void)?
    /// showReadyToInstallAndRelaunch 的回复（immediateInstallHandler 缺席时的兜底路径）
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?

    // MARK: 接入应用

    func attach(model: DSModel) {
        flow.gateStateProvider = { [weak model] in model?.updateGateState }
        logLine = { [weak model] line in model?.log(line) }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func start() {
        // 仅 .app bundle 内启用（.build 裸跑 / UI 干测试不打扰）；可用环境变量显式关闭
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        guard ProcessInfo.processInfo.environment["GHDS_DISABLE_UPDATE"] != "1" else {
            logLine?(tr("更新组件已禁用（GHDS_DISABLE_UPDATE=1）"))
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
        if let raw = ProcessInfo.processInfo.environment["GHDS_UPDATE_CHECK_INTERVAL"],
           let interval = TimeInterval(raw), interval > 0 {
            updater.updateCheckInterval = interval
        }
        self.updater = updater
        self.delegate = delegate
        self.driver = driver

        do {
            try updater.start()
            let feed = ProcessInfo.processInfo.environment["GHDS_FEED_URL"]
                ?? (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? tr("未配置"))
            logLine?(tr("更新组件就绪（当前版本 %@，feed %@）", currentVersion, feed))
            // 启动即静默检查（不等 24h 周期；后台低打扰，无更新完全无感）
            updater.checkForUpdatesInBackground()
            flow.beganCheck()
        } catch {
            // 配置缺失（feed URL/公钥未配置）等：静默跳过，不影响使用
            logLine?(tr("更新组件未启动：%@（不影响使用）", error.localizedDescription))
        }
    }

    private var delegate: UpdateDelegate?
    private var driver: SilentUpdateDriver?

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

    fileprivate func driverFoundNoUpdate() {
        logLine?(tr("更新检查完成：已是最新版本"))
        flow.updateNotFound()
    }

    fileprivate func driverFailed(_ error: Error? = nil) {
        // 国内可达性：下载失败静默跳过、下次启动再试、永不阻塞使用（报告 §5.5）。
        // 静默 ≠ 无诊断：错误镜像到事件日志（不弹窗）。
        let detail = error.map { "：\($0.localizedDescription)" } ?? ""
        logLine?(tr("更新检查/下载失败（静默跳过，下次启动再试）%@", detail))
        flow.failedQuietly()
    }

    fileprivate func driverInstalling() {
        flow.beganInstalling()
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
        center?.driverFailed(error)
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


// MARK: - SPUUpdaterDelegate：feed 覆盖（测试钩子）+ 安装接管（安全门咽喉点）

@MainActor
private final class UpdateDelegate: NSObject, SPUUpdaterDelegate {

    weak var center: UpdateCenter?
    init(center: UpdateCenter) { self.center = center }

    /// feed 地址：环境变量 GHDS_FEED_URL 覆盖（本地升级链路 E2E 用）；
    /// 否则回落 Info.plist SUFeedURL（生产 = GitHub Releases 托管 appcast）。
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["GHDS_FEED_URL"]
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
