import AppKit
import SwiftUI
import DSCore

// MARK: 更新角标行为测试（2026-11-23）
//
// 「ChatGPT 式」角标的纯行为侧：
// - 下载中初始为圆形下载图标，点击展开成胶囊显示 0–100%，再点收起；展开/收起只是呈现，
//   不改变下载阶段、进度或版本（下载从不因收起而停止）；
// - 100%（就绪）后再次点击 = 请求安装，沿用 UpdateSafetyGate 点击时刻现场求值；
// - 渲染：收起为紧凑圆形，展开为明显更宽的胶囊；
// - 配色 / 动画只复用 DSTheme 与系统默认动画（源码守卫：不出现自造颜色与时长）。

@MainActor
func updateBadgeBehaviorTests(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void) {
    // ===== A. 下载中点击：只切换展开；收起不改变下载状态 =====
    let flow = UpdateFlowModel()
    check(!flow.isExpanded && !flow.badgeVisible, "badge starts collapsed and hidden")
    check(flow.badgeTapped() == .ignored, "tap while idle is ignored")
    flow.beganCheck()
    check(flow.badgeTapped() == .ignored && !flow.isExpanded, "tap while checking does not expand")
    flow.downloadStarted(version: "9.9.9")
    check(flow.badgeVisible && !flow.isExpanded, "a new download starts as the collapsed download circle")
    check(flow.badgeTapped() == .expansionToggled && flow.isExpanded, "the first tap during download expands the badge")
    if case .downloading(let progress, let version) = flow.phase {
        check(progress == 0 && version == "9.9.9", "expanding leaves the download state untouched")
    } else {
        check(false, "expanding keeps the downloading phase")
    }
    flow.downloadProgress(0.42)
    check(flow.progressPercent == 42, "progress percent follows the download fraction")
    check(flow.badgeTapped() == .expansionToggled && !flow.isExpanded, "the second tap collapses the badge")
    if case .downloading(let progress, let version) = flow.phase {
        check(abs(progress - 0.42) < 1e-9 && version == "9.9.9", "collapsing keeps progress and version")
    } else {
        check(false, "collapsing keeps the downloading phase")
    }
    flow.downloadProgress(0.9)
    if case .downloading(let progress, _) = flow.phase {
        check(abs(progress - 0.9) < 1e-9, "the download keeps advancing while collapsed")
    } else {
        check(false, "download continues while collapsed")
    }
    check(flow.badgeVisible, "the badge stays visible while collapsed")

    // 百分比文本夹在 0–100
    flow.downloadProgress(-0.5)
    check(flow.progressPercent == 0, "negative progress shows 0%")
    flow.downloadProgress(2)
    check(flow.progressPercent == 100, "over-unity progress shows 100%")

    // ===== B. 100% 后点击：请求安装，沿用安全门点击时刻现场求值 =====
    flow.downloadCompleted(version: "9.9.9")
    check(flow.phase == .ready(version: "9.9.9"), "download completion becomes ready")
    var gate = UpdateSafetyGate.State(enabled: true, commConnected: false, estopEngaged: false)
    flow.gateStateProvider = { gate }
    check(flow.badgeTapped() == .installRequested && flow.phase == .ready(version: "9.9.9"),
          "tap at 100% requests installation instead of toggling the capsule")
    if case .blocked = flow.requestRestart() {} else { check(false, "the install request still passes the live safety gate") }
    check(flow.phase == .ready(version: "9.9.9") && flow.lastBlockReason != nil,
          "a blocked install keeps the downloaded update ready and surfaces the reason")
    gate = UpdateSafetyGate.State(enabled: false, commConnected: false, estopEngaged: false)
    check(flow.badgeTapped() == .installRequested, "tap after the gate opens requests installation again")
    check(flow.requestRestart() == .initiated && flow.phase == .installing, "an open gate installs the downloaded update")
    check(flow.badgeTapped() == .ignored, "tap while installing is ignored")

    // 就绪态保留展开：胶囊直接变成「重启更新」
    let readyFlow = UpdateFlowModel()
    readyFlow.downloadStarted(version: "2.0")
    _ = readyFlow.badgeTapped()
    readyFlow.downloadCompleted(version: "2.0")
    check(readyFlow.isExpanded, "an expanded capsule stays expanded when the download completes")

    // 新一轮下载从收起态开始；失败 / 无更新重置展开
    let again = UpdateFlowModel()
    again.downloadStarted(version: "1")
    _ = again.badgeTapped()
    again.downloadStarted(version: "2")
    check(!again.isExpanded, "a new download starts collapsed again")
    _ = again.badgeTapped()
    again.failedQuietly()
    check(!again.isExpanded, "a failed download resets the expansion")
    let idleFlow = UpdateFlowModel()
    idleFlow.downloadStarted(version: "1")
    _ = idleFlow.badgeTapped()
    idleFlow.updateNotFound()
    check(!idleFlow.isExpanded, "a reset flow clears the expansion")

    // ===== C. 渲染：收起 = 紧凑圆形；展开 = 胶囊；就绪收起 = 紧凑 =====
    let rendering = UpdateFlowModel()
    rendering.downloadStarted(version: "9.9.9")
    rendering.downloadProgress(0.4)
    let collapsed = badgeSize(rendering)
    check(collapsed.width > 0 && collapsed.width <= 24 && collapsed.height <= 24 && collapsed.height >= 14,
          "collapsed badge is a compact download circle")
    check(abs(collapsed.width - collapsed.height) <= 1, "collapsed badge is round")
    _ = rendering.badgeTapped()
    let expanded = badgeSize(rendering)
    check(expanded.width >= collapsed.width * 2.5 && expanded.width >= 64,
          "expanded badge widens into a capsule showing the progress")
    check(expanded.height >= 20 && expanded.height <= 30, "expanded badge keeps a capsule height")
    check(expanded.width / expanded.height >= 2.2, "expanded badge is a wide capsule, not a circle")
    rendering.downloadCompleted(version: "9.9.9")
    let readyExpanded = badgeSize(rendering)
    check(readyExpanded.width >= 60, "the ready capsule shows the restart action")
    let readyCollapsedFlow = UpdateFlowModel()
    readyCollapsedFlow.downloadCompleted(version: "9.9.9")
    let readyCollapsed = badgeSize(readyCollapsedFlow)
    check(readyCollapsed.width <= 24 && abs(readyCollapsed.width - readyCollapsed.height) <= 1,
          "a collapsed ready badge is a compact round install affordance")

    // ===== D. 源码守卫：只复用 DSTheme 与系统默认动画 =====
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let badgeSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/MatchSticksDS/Views/UpdateBadge.swift"), encoding: .utf8)) ?? ""
    let englishTable = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/DSCore/Resources/en.lproj/Localizable.strings"), encoding: .utf8)) ?? ""
    check(!badgeSource.isEmpty, "badge source fixture loads")
    check(badgeSource.contains("DSTheme.accent") && badgeSource.contains("DSTheme.textSecondary"),
          "badge colors come from DSTheme")
    check(!badgeSource.contains("Color(red:") && !badgeSource.contains("Color(nsColor:") &&
          !badgeSource.contains("Color(hue:") && !badgeSource.contains(".orange") && !badgeSource.contains(".purple"),
          "badge invents no colors of its own")
    check(!badgeSource.contains("duration:"), "badge uses the system default animation, no invented durations")
    check(badgeSource.contains("ProgressView(value:"), "the capsule uses the system progress indicator")
    check(englishTable.contains("\"正在后台下载新版本 %d%%（低优先级，可忽略，不影响使用）\" = \"Downloading the new version"),
          "the download tooltip has an English translation")
    check(englishTable.contains("\"重启更新\" = \"Restart to Update\";"),
          "the ready action keeps its English translation")
}

/// 角标的内在尺寸（无外部 frame）：收起与展开的差异必须来自视图本身。
@MainActor
private func badgeSize(_ flow: UpdateFlowModel) -> CGSize {
    let renderer = ImageRenderer(content: UpdateBadge(flow: flow) {})
    renderer.scale = 1
    return renderer.nsImage?.size ?? .zero
}
