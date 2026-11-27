import AppKit
import SwiftUI
import DSCore

// MARK: Mini Driver Station（2026-11-23）行为测试
//
// 覆盖：① 窗口声明守卫（标准标题栏、原生红绿灯位置、宽默认尺寸、可调窗口）；
// ② 主窗口工具区入口位置（trailing 工具区，不压侧栏分割线）；
// ③ 宽横向驾驶台真实渲染几何（安全控件同一横带、延伸至右缘）；
// ④ 窗口切换决策与永不无窗保证（纯状态 + 真实 NSWindow 应用层 + 真实 willClose 事件）；
// ⑤ 机器人刷新反馈（真模型动作 + 旋转状态可结束/可再次触发/拒绝不空转）。

@MainActor
func miniDriverStationTests(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void) {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    func source(_ relativePath: String) -> String {
        (try? String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)) ?? ""
    }
    let appSource = source("Sources/MatchSticksDriverStaion/MatchSticksDriverStaionApp.swift")
    let miniSource = source("Sources/MatchSticksDriverStaion/Views/MiniView.swift")
    let settingsSource = source("Sources/MatchSticksDriverStaion/Views/SettingsView.swift")
    check(!appSource.isEmpty && !miniSource.isEmpty,
          "mini driver station tests load their source fixtures")

    let styleSuiteName = "org.ghfrc.driverstation.test.uitests.mini-style.\(UUID().uuidString)"
    let styleDefaults = UserDefaults(suiteName: styleSuiteName)!
    let styleModel = DSModel(settingsDefaults: styleDefaults, persistenceEnabled: true)
    check(styleModel.miniReferenceStyle == .niClassic,
          "Mini reference defaults to NI Classic")
    styleModel.miniReferenceStyle = .firstModern
    check(styleDefaults.string(forKey: "matchsticks.miniReferenceStyle") == "firstModern",
          "selecting FIRST Modern persists immediately")
    let restoredStyleModel = DSModel(settingsDefaults: styleDefaults, persistenceEnabled: true)
    restoredStyleModel.loadPersistedSettings()
    check(restoredStyleModel.miniReferenceStyle == .firstModern,
          "FIRST Modern survives a settings restore")
    styleDefaults.set("not-a-real-style", forKey: "matchsticks.miniReferenceStyle")
    let invalidStyleModel = DSModel(settingsDefaults: styleDefaults, persistenceEnabled: true)
    invalidStyleModel.loadPersistedSettings()
    check(invalidStyleModel.miniReferenceStyle == .niClassic,
          "invalid persisted style falls back to NI Classic")
    styleDefaults.removePersistentDomain(forName: styleSuiteName)
    check(settingsSource.contains("$model.miniReferenceStyle") &&
          settingsSource.contains("NI Classic") && settingsSource.contains("FIRST Modern"),
          "Settings exposes both Mini UI references")

    // ===== ① 窗口声明：标准标题栏（原生 standardWindowButton 位置与行为，无自绘背景）=====
    let miniScene = String(appSource.slice(from: "Window(\"Mini Driver Station\"", to: "struct RootView"))
    check(!miniScene.isEmpty, "mini window scene declaration can be located")
    check(!miniScene.contains(".windowStyle(.hiddenTitleBar)"),
          "mini window uses the standard title bar instead of hiding it behind a custom background")
    check(!miniSource.contains("WindowTitleSync") && !miniSource.contains("window?.title ="),
          "mini window title comes from the native scene title, not an in-content overlay hack")
    check(!miniSource.contains("frame(width: 420)"),
          "mini content drops the fixed 420-point portrait-ish width")

    // ===== ② 宽横向驾驶台尺寸：默认宽、可自由放宽（参考 FRC Driver Station 驾驶台）=====
    if let sizeRange = miniScene.range(of: "defaultSize(width: ") {
        let tail = String(miniScene[sizeRange.upperBound...])
        let width = Int(tail.prefix { $0.isNumber }) ?? 0
        check(width >= 768,
              "mini window default width fits the full safety strip (≥768, got \(width))")
        check(miniScene.contains(".frame(minWidth: 768,"),
              "mini scene minimum width cannot restore to a clipped 560-point window")
        check(miniSource.contains(".frame(minWidth: 768,"),
              "mini content minimum width keeps every safety control inside the window")
    } else {
        check(false, "mini window declares a default size")
    }
    check(miniScene.contains(".windowResizability(.contentMinSize)"),
          "mini window stays resizable above its content minimum instead of locking content size")

    // ===== ③ 主窗口入口位置：trailing 工具区（右上角，不压侧栏与内容间竖线）=====
    check(appSource.contains("ToolbarItem(placement: .confirmationAction)"),
          "mini entry sits in the trailing toolbar area like mainstream macOS apps")
    check(!appSource.contains("placement: .primaryAction"),
          "mini entry no longer sits in the leading toolbar area over the sidebar divider")

    // ===== ③b 窗口重入（审查修复）：共享 flow 绑定必须保留真实 openMini 兜底 =====
    check(miniSource.contains("openMini: { openWindow(id: \"mini\") }"),
          "MiniView keeps the real openWindow(id: \"mini\") fallback in its flow binding")
    check(!miniSource.contains("openMini: {}"),
          "MiniView never overwrites the shared flow binding with an empty mini opener")

    // ===== ④ 真实渲染几何：宽横向布局 =====
    miniDriverStationRenderTests(check)

    // ===== ⑤ 窗口切换决策（纯状态，可注入）=====
    miniDriverStationWindowFlowTests(check)

    // ===== ⑥ 真实 NSWindow 应用层：隐藏/恢复/关闭事件（永不无窗）=====
    miniDriverStationPresenterTests(check)

    // ===== ⑦ 刷新反馈与模型动作 =====
    miniDriverStationRefreshTests(check)
}

// MARK: - 渲染几何（真实 ImageRenderer 位图采样）
//
// 直接渲染布局内核 MiniConsoleBar（不含 @ObservedObject 语言壳——那会让
// ImageRenderer 整块退化为占位图，见 2026-11-23 排查）。
@MainActor
private func miniDriverStationRenderTests(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void) {
    let width = 768, height = 220
    let previousAppearance = NSApplication.shared.appearance
    NSApplication.shared.appearance = NSAppearance(named: .aqua)
    defer { NSApplication.shared.appearance = previousAppearance }
    let model = DSModel(settingsDefaults: UserDefaults(suiteName: "org.ghfrc.driverstation.test.uitests.mini.\(UUID().uuidString)"),
                        persistenceEnabled: false)
    let bar = MiniConsoleBar(model: model, flow: DriverStationWindowFlow(), refresh: RobotRefreshFlow())
        .frame(width: CGFloat(width), height: CGFloat(height))
    let renderer = ImageRenderer(content: bar)
    renderer.scale = 1
    guard let image = renderer.nsImage,
          let data = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: data) else {
        check(false, "mini console renders into a \(width)×\(height) bitmap")
        return
    }
    check(bitmap.pixelsWide == width && bitmap.pixelsHigh == height,
          "mini console fills the wide landscape frame it is given")

    var greenMinX = width, greenMaxX = 0, greenMinY = height, greenMaxY = 0
    var redMinX = width, redMaxX = 0, redMinY = height, redMaxY = 0
    var sawGreen = false, sawRed = false
    for x in stride(from: 0, to: width, by: 2) {
        for y in stride(from: 0, to: height, by: 2) {
            guard let c = bitmap.colorAt(x: x, y: y) else { continue }
            let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
            if g > 0.55 && g > r + 0.12 && g > b + 0.12 {
                sawGreen = true
                greenMinX = min(greenMinX, x); greenMaxX = max(greenMaxX, x)
                greenMinY = min(greenMinY, y); greenMaxY = max(greenMaxY, y)
            } else if r > 0.8 && r > g + 0.15 && r > b + 0.15 {
                sawRed = true
                redMinX = min(redMinX, x); redMaxX = max(redMaxX, x)
                redMinY = min(redMinY, y); redMaxY = max(redMaxY, y)
            }
        }
    }
    check(sawGreen && sawRed, "mini console renders the Enable (green) and E-Stop (red) safety controls")
    guard sawGreen, sawRed else { return }
    let greenCenterY = Double(greenMinY + greenMaxY) / 2
    let redCenterY = Double(redMinY + redMaxY) / 2
    check(abs(greenCenterY - redCenterY) <= 10,
          "safety controls share one horizontal band (FRC-style landscape console), Δy=\(abs(greenCenterY - redCenterY))")
    let controlsMaxX = max(greenMaxX, redMaxX)
    check(Double(controlsMaxX) >= Double(width) * 0.8,
          "safety controls reach into the right region of the wide console (maxX=\(controlsMaxX))")
    check(redMaxX < width - 16,
          "E-Stop remains fully inside the console instead of clipped at the right edge (maxX=\(redMaxX))")
}

// MARK: - 窗口切换决策（纯状态）

@MainActor
private func miniDriverStationWindowFlowTests(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void) {
    // 决策表：入口点击 / 返回主窗 / Mini 被关闭 / 状态恢复误触发
    check(DriverStationWindowFlow.decide(.miniEntryTapped, mode: .main) == (.mini, .showMiniOnly),
          "tapping the mini entry switches to mini only")
    check(DriverStationWindowFlow.decide(.returnToMainTapped, mode: .mini) == (.main, .showMainOnly),
          "the restore control brings the main window back")
    check(DriverStationWindowFlow.decide(.miniWindowClosed, mode: .mini) == (.main, .showMainOnly),
          "closing the mini window always restores the main window (never a UI-less app)")
    check(DriverStationWindowFlow.decide(.miniWindowAppeared, mode: .main) == (.main, .showMainOnly),
          "a restoration-opened mini normalizes back to the main window")
    check(DriverStationWindowFlow.decide(.miniWindowAppeared, mode: .mini) == (.mini, .showMiniOnly),
          "mini appearing in mini mode completes the switch (main retracts only after mini is on screen)")
    // 幂等：重复/过时事件不重复执行窗口动作
    check(DriverStationWindowFlow.decide(.miniEntryTapped, mode: .mini) == (.mini, .none),
          "re-tapping the entry while already in mini does nothing")
    check(DriverStationWindowFlow.decide(.miniWindowClosed, mode: .main) == (.main, .none),
          "a stale close event while main is active does nothing")
    check(DriverStationWindowFlow.decide(.returnToMainTapped, mode: .main) == (.main, .none),
          "a stale restore event while main is active does nothing")

    // 可注入执行器：事件 → 恰好一次窗口效果，模式跟随决策
    let flow = DriverStationWindowFlow()
    var effects: [DriverStationWindowFlow.Effect] = []
    flow.perform = { effects.append($0) }
    check(flow.mode == .main, "fresh launch presents the main window")
    flow.send(.miniEntryTapped)
    check(flow.mode == .mini && effects == [.showMiniOnly], "entry tap opens mini and retracts main exactly once")
    flow.send(.miniEntryTapped)
    check(flow.mode == .mini && effects == [.showMiniOnly], "duplicate entry taps do not stack window actions")
    flow.send(.miniWindowClosed)
    check(flow.mode == .main && effects == [.showMiniOnly, .showMainOnly],
          "mini close restores the main window exactly once")
    flow.send(.miniWindowClosed)
    check(flow.mode == .main && effects == [.showMiniOnly, .showMainOnly],
          "duplicate close events do not stack window actions")
}

// MARK: - 真实 NSWindow 应用层（隐藏主窗 / 恢复主窗 / 真实关闭事件联动）

@MainActor
private func miniDriverStationPresenterTests(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void) {
    let previousActivationPolicy = NSApplication.shared.activationPolicy()
    NSApplication.shared.setActivationPolicy(.prohibited)
    defer { NSApplication.shared.setActivationPolicy(previousActivationPolicy) }

    // ===== A. 窗口重入安全（审查修复）：Mini 场景窗口不存在时绝不先隐藏主窗 =====
    // macOS 14+ 不保证已关闭的 SwiftUI 场景窗口残留在 NSApp.windows——本测试进程
    // 此刻没有任何 Mini 标识窗口，等价于「关闭后被系统回收」的再次进入。
    check(NSApp.windows.first { $0.identifier == DriverStationWindowPresenter.miniWindowIdentifier } == nil,
          "precondition: no stale mini window exists before the re-entry scenarios")
    let mainWindow = makeOffscreenDriverStationWindow(identifier: DriverStationWindowPresenter.mainWindowIdentifier)
    mainWindow.orderFront(nil)
    var fallbackOpens = 0
    DriverStationWindowPresenter.apply(.showMiniOnly, openMini: { fallbackOpens += 1 })
    check(fallbackOpens == 1,
          "re-entry with no mini window falls back to the real openWindow path")
    check(mainWindow.isVisible,
          "the fallback path never hides the main window first (no zero-visible-window state)")
    mainWindow.makeKeyAndOrderFront(nil)

    var miniWindow: NSWindow?
    check(mainWindow.isVisible, "offscreen fixture main window starts visible")

    let flow = DriverStationWindowFlow()
    var miniOpenCount = 0
    flow.perform = { effect in
        DriverStationWindowPresenter.apply(effect, openMini: {
            miniOpenCount += 1
            let window = makeOffscreenDriverStationWindow(identifier: DriverStationWindowPresenter.miniWindowIdentifier)
            window.makeKeyAndOrderFront(nil)
            miniWindow = window
        })
    }

    // ===== B. 全周期重入回归：入口 → Mini 上屏 → 真实 performClose → 再次入口 =====
    flow.send(.miniEntryTapped)
    check(miniOpenCount == 1, "showMiniOnly actually opens the mini window")
    check(miniWindow?.isVisible == true, "the fallback-created mini window is on screen")
    check(mainWindow.isVisible,
          "the fallback entry keeps the main window visible until mini is on screen (never zero windows)")
    flow.send(.miniWindowAppeared)
    check(!mainWindow.isVisible && miniWindow?.isVisible == true,
          "mini appearing completes the switch: main retracts, mini stays visible")

    // 恢复主窗：主窗回前台、Mini 收起
    flow.send(.returnToMainTapped)
    check(mainWindow.isVisible && miniWindow?.isVisible != true,
          "the restore control shows main and dismisses mini")

    // 直接走 presenter：恢复主窗对已隐藏主窗同样有效（仅 Mini 可见时点击恢复）
    mainWindow.orderOut(nil)
    DriverStationWindowPresenter.apply(.showMainOnly, openMini: {})
    check(mainWindow.isVisible, "showMainOnly un-hides an orderOut main window")

    // ===== C. 真实红绿灯关闭 → 再次入口（窗口重入核心回归）=====
    var closedCount = 0
    let closeFlow = DriverStationWindowFlow()
    closeFlow.perform = { effect in
        DriverStationWindowPresenter.apply(effect, openMini: {
            let window = miniWindow
                ?? makeOffscreenDriverStationWindow(identifier: DriverStationWindowPresenter.miniWindowIdentifier)
            window.makeKeyAndOrderFront(nil)
            miniWindow = window
        })
    }
    mainWindow.orderOut(nil)
    closeFlow.send(.miniEntryTapped)
    guard let miniForClose = miniWindow else {
        check(false, "close-path fixture mini window exists")
        mainWindow.close()
        return
    }
    miniForClose.makeKeyAndOrderFront(nil)
    let hosting = NSHostingView(rootView: MiniWindowCloseObserver {
        closeFlow.send(.miniWindowClosed)
        closedCount += 1
    })
    miniForClose.contentView = hosting
    let closeDeadline = Date().addingTimeInterval(0.2)
    while Date() < closeDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    miniForClose.performClose(nil)
    check(closedCount == 1, "closing the mini window via the red button fires the close observer exactly once")
    check(closeFlow.mode == .main, "the close event routes through the window flow")
    check(mainWindow.isVisible, "the real red-button close restores the hidden main window")

    // 再次入口：真实关闭过的 Mini 回到屏幕、主窗收起（macOS 不回收窗口的分支；
    // 「回收后再次进入」分支由开头 A 段在 NSApp.windows 真实无 Mini 时覆盖）
    closeFlow.send(.miniEntryTapped)
    check(miniForClose.isVisible && !mainWindow.isVisible,
          "re-entry after a real close shows a visible mini window and retracts main")
    miniForClose.performClose(nil)
    check(closedCount == 2, "a second real close fires the observer again")
    check(mainWindow.isVisible, "a second close still restores the main window (the cycle is stable)")

    mainWindow.close()
    miniWindow?.close()
}

@MainActor
private func makeOffscreenDriverStationWindow(identifier: NSUserInterfaceItemIdentifier) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 480, height: 320),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.identifier = identifier
    return window
}

// MARK: - 刷新反馈（真动作 + 旋转状态可结束 / 可再次触发）

@MainActor
private func miniDriverStationRefreshTests(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void) {
    // 模型层：未连接 → 注入的刷新动作被真实调用；已连接 → 不打断链路、不假装刷新
    let refreshModel = DSModel(settingsDefaults: UserDefaults(suiteName: "org.ghfrc.driverstation.test.uitests.refresh.\(UUID().uuidString)"),
                               persistenceEnabled: false)
    var refreshCalls = 0
    refreshModel.robotConnectionRefresher = { refreshCalls += 1 }
    check(refreshModel.refreshRobotConnection(),
          "refresh while disconnected reports a real re-search was requested")
    check(refreshCalls == 1, "the injected robot re-search action runs exactly once per request")
    check(refreshModel.dsEvents.contains { $0.text.contains("重新搜索") },
          "requesting a re-search is logged where the operator can see it")
    refreshModel.commState = .connected(host: "127.0.0.1")
    check(!refreshModel.refreshRobotConnection(),
          "refresh while connected does not claim a re-search")
    check(refreshCalls == 1,
          "refresh while connected does not touch the live control link")
    check(refreshModel.dsEvents.contains { $0.text.contains("已连接") },
          "refresh while connected explains itself in the log")

    // 未注入（生产路径）：调用真实 DSClient.refreshConnection（未 start → 无副作用，不崩溃）
    let productionModel = DSModel(settingsDefaults: UserDefaults(suiteName: "org.ghfrc.driverstation.test.uitests.refresh2.\(UUID().uuidString)"),
                                  persistenceEnabled: false)
    check(productionModel.refreshRobotConnection(),
          "the production refresh path stays callable without a started control loop")

    // 反馈流：注入时钟；点击 → 动作 + 旋转开始；超时或通信变化 → 结束；可再次触发
    var now = Date(timeIntervalSinceReferenceDate: 0)
    var actions = 0
    let refresh = RobotRefreshFlow(clock: { now }, action: { actions += 1; return true })
    check(!refresh.isRefreshing, "idle refresh feedback does not spin")
    refresh.request()
    check(actions == 1 && refresh.isRefreshing, "clicking refresh performs the action and starts the spin")
    now += 0.1
    refresh.settle()
    check(refresh.isRefreshing, "the spin keeps going while the re-search is in flight")
    now += RobotRefreshFlow.maxSpinInterval
    refresh.settle()
    check(!refresh.isRefreshing, "the spin ends after the bounded in-flight window")

    refresh.request()
    check(actions == 2 && refresh.isRefreshing && refresh.generation == 2,
          "a second click triggers the action again with a fresh spin generation")
    now += 0.1
    refresh.noteCommStateChange()
    check(!refresh.isRefreshing, "a robot communication change ends the spin early")

    // 动作拒绝（已连接）：不转、不计数——视觉反馈不允许脱离真实动作
    let refused = RobotRefreshFlow(clock: { now }, action: { actions += 1; return false })
    refused.request()
    check(!refused.isRefreshing, "a refused re-search never starts a fake spin")
    refused.request()
    check(actions == 4, "each click still reaches the action so the model can explain refusals")
    check(!refused.isRefreshing, "repeated refused clicks never spin")
}

extension String {
    /// 从 `from`（不含）到 `to`（不含）截取；任一标记缺失返回空串（守卫测试可分辨）。
    func slice(from start: String, to end: String) -> Substring {
        guard let startRange = range(of: start) else { return Substring() }
        guard let endRange = range(of: end, range: startRange.upperBound..<endIndex) else { return Substring() }
        return self[startRange.upperBound..<endRange.lowerBound]
    }
}
