import AppKit
import SwiftUI
import DSCore

// MARK: 应用图标运行时外观（2026-11-23）行为测试
//
// 覆盖：IconStyle 枚举解析、四图白名单映射与真实 bundle 加载、
// AppIconCenter 解析矩阵（跟随系统浅/深切换 + 固定模式免疫系统变化 + 图稿缺失静默）、
// 独立设置键持久化 / 重启恢复 / 非法值回默认、界面主题与图标偏好互不影响、
// 设置页即时生效交互与源码放置守卫（并入 General 的 PathBlender 式卡片选择器、
// 像素级几何：80 舞台 / 78×60 双图 30×12 偏移 / 56 单图 / 2pt 外描边 / 等宽列）。

@MainActor
func appIconAppearanceTests(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void) {
    // ===== A. 枚举解析 =====
    check(IconStyle.allCases.map(\.rawValue) == ["color", "monochrome"],
          "icon styles are color and monochrome with stable raw values")
    check(IconStyle(rawValue: "monochrome") == .monochrome && IconStyle(rawValue: "color") == .color,
          "icon style raw values round-trip")
    check(IconStyle(rawValue: "neon") == nil && IconStyle(rawValue: "") == nil,
          "unknown icon style values are rejected instead of guessed")

    // ===== B. 四资源白名单映射 =====
    check(AppIconArtwork.whitelist == ["app-icon-day", "app-icon-night", "app-icon-mono-day", "app-icon-mono-night"],
          "the icon artwork whitelist is exactly the four bundled files")
    check(AppIconArtwork.fileName(style: .color, dark: false) == "app-icon-day" &&
          AppIconArtwork.fileName(style: .color, dark: true) == "app-icon-night" &&
          AppIconArtwork.fileName(style: .monochrome, dark: false) == "app-icon-mono-day" &&
          AppIconArtwork.fileName(style: .monochrome, dark: true) == "app-icon-mono-night",
          "each style/darkness pair maps to its bundled artwork file")
    check(Set([AppIconArtwork.fileName(style: .color, dark: false),
               AppIconArtwork.fileName(style: .color, dark: true),
               AppIconArtwork.fileName(style: .monochrome, dark: false),
               AppIconArtwork.fileName(style: .monochrome, dark: true)]).count == 4,
          "the four style/darkness combinations map to distinct files")

    // ===== C. 真实 bundle 加载：四图均可加载；白名单拒绝清单外文件；同 bundle 重复加载走缓存 =====
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let iconDirectory = repositoryRoot.appendingPathComponent("Sources/MatchSticksDriverStation/Resources/AppIcons")
    func makeArtworkBundle() -> (bundle: Bundle?, directory: URL) {
        let bundleDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MatchSticks-Driver-Station-appicon-\(UUID().uuidString).bundle", isDirectory: true)
        let resourcesDirectory = bundleDirectory.appendingPathComponent("Contents/Resources", isDirectory: true)
        try? FileManager.default.createDirectory(at: resourcesDirectory, withIntermediateDirectories: true)
        for name in AppIconArtwork.whitelist {
            try? FileManager.default.copyItem(at: iconDirectory.appendingPathComponent("\(name).png"),
                                              to: resourcesDirectory.appendingPathComponent("\(name).png"))
        }
        return (Bundle(path: bundleDirectory.path), bundleDirectory)
    }
    let (artworkBundle, bundleDirectory) = makeArtworkBundle()
    let (otherArtworkBundle, otherBundleDirectory) = makeArtworkBundle()
    // 清单外的有效 PNG：白名单必须在加载之前拒绝
    try? FileManager.default.copyItem(at: iconDirectory.appendingPathComponent("app-icon-day.png"),
                                      to: bundleDirectory.appendingPathComponent("Contents/Resources/rogue-icon.png"))
    if let artworkBundle, let otherArtworkBundle {
        for style in IconStyle.allCases {
            for dark in [false, true] {
                let image = AppIconArtwork.image(style: style, dark: dark, bundle: artworkBundle)
                check(image != nil && image!.size.width > 0 && image!.size.height > 0,
                      "\(style.rawValue)/dark=\(dark) artwork loads as a valid image from the bundle")
            }
        }
        check(AppIconArtwork.image(fileName: "rogue-icon", bundle: artworkBundle) == nil,
              "artwork outside the four-file whitelist is refused even when the file exists")
        check(AppIconArtwork.image(fileName: "../../etc/passwd", bundle: artworkBundle) == nil,
              "path-like names are refused by the whitelist before any file access")
        // 缓存：卡片 body 每次求值都取图稿，同 bundle+文件必须命中同一 NSImage，
        // 不再重读 1024 PNG；缓存按 bundle 路径隔离，不同 bundle 互不串对象。
        let firstLoad = AppIconArtwork.image(fileName: "app-icon-day", bundle: artworkBundle)
        let secondLoad = AppIconArtwork.image(fileName: "app-icon-day", bundle: artworkBundle)
        check(firstLoad != nil && firstLoad === secondLoad,
              "reloading the same bundle file returns the identical cached NSImage without re-reading the PNG")
        let otherBundleLoad = AppIconArtwork.image(fileName: "app-icon-day", bundle: otherArtworkBundle)
        check(otherBundleLoad != nil && otherBundleLoad !== firstLoad,
              "the artwork cache isolates by bundle path — different bundles never share objects")
        check(AppIconArtwork.image(fileName: "app-icon-mono-night", bundle: otherArtworkBundle) ===
              AppIconArtwork.image(fileName: "app-icon-mono-night", bundle: otherArtworkBundle),
              "the second bundle also round-trips through its own cache entries")
        check(AppIconArtwork.image(fileName: "rogue-icon", bundle: artworkBundle) == nil &&
              AppIconArtwork.image(fileName: "rogue-icon", bundle: artworkBundle) == nil,
              "refused and missing lookups stay nil — nothing poisoned ever enters the cache")
    } else {
        check(false, "test artwork bundles load")
    }
    try? FileManager.default.removeItem(at: bundleDirectory)
    try? FileManager.default.removeItem(at: otherBundleDirectory)
    check(!FileManager.default.fileExists(atPath: bundleDirectory.path) &&
          !FileManager.default.fileExists(atPath: otherBundleDirectory.path),
          "app-icon test bundles are removed")

    // ===== D. AppIconCenter 解析矩阵：样式 × 外观 × 系统深浅 =====
    let stubArtwork = NSImage(size: NSSize(width: 4, height: 4))
    for style in IconStyle.allCases {
        for mode in AppearanceMode.allCases {
            for systemDark in [false, true] {
                let center = AppIconCenter()
                center.artworkLoader = { _ in stubArtwork }
                center.systemDarkProvider = { systemDark }
                var applied = 0
                center.applier = { _ in applied += 1 }
                center.update(style: style, mode: mode)
                let expectedDark = mode == .system ? systemDark : mode == .dark
                check(center.pushedFileNames == [AppIconArtwork.fileName(style: style, dark: expectedDark)] && applied == 1,
                      "\(style.rawValue)/\(mode.rawValue) with systemDark=\(systemDark) pushes exactly the resolved artwork")
            }
        }
    }

    // 图稿缺失：静默 no-op（绝不把 applicationIconImage 置空）
    let missing = AppIconCenter()
    missing.artworkLoader = { _ in nil }
    var missingApplied = 0
    missing.applier = { _ in missingApplied += 1 }
    missing.update(style: .color, mode: .dark)
    check(missing.pushedFileNames.isEmpty && missingApplied == 0,
          "missing artwork is a quiet no-op instead of clearing the icon")

    // ===== E. 跟随系统：真实系统外观驱动（分布式通知 + 全局 AppleInterfaceStyle）；固定模式免疫 =====
    // 机制（2026-11-23 本机活体验证，公开 API）：系统深浅切换在 DistributedNotificationCenter
    // 投递 AppleInterfaceThemeChangedNotification（真实切换逐条投递、不带方向信息）；
    // 读值唯一免缓存路径是 persistentDomain(forName: "NSGlobalDomain") 的 AppleInterfaceStyle
    // （进程内 CFPreferences 缓存不随外部变化刷新）。测试投递同名通知模拟系统翻转。
    //
    // 等待策略：期望推送的场景用「到达即继续」的条件等待（负载下不再依赖固定 0.6s 假设）；
    // 期望不变的场景（停止观察 / 固定模式 / 界面外观静默）保留明确 quiet window——
    // 「没有再推」只能用静默期证明；重复注册场景在到达期望后再留防假绿静默窗，
    // 防同一投递的第二次推送稍后才到时立即断言而假绿。
    func postSystemAppearanceChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, deliverImmediately: true)
    }
    /// 跑主 runloop 一段固定时间（分布式投递经 distnotd 往返，异步送达）。
    func runMainLoop(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
    /// 条件等待：期望的推送次数到达即返回 true；超时返回 false，由调用方断言失败（不无限挂起）。
    func waitForPushCount(_ center: AppIconCenter, _ expected: Int, timeout: Double = 2.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if center.pushedFileNames.count >= expected { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return center.pushedFileNames.count >= expected
    }

    var systemDark = false
    let previousAppearance = NSApplication.shared.appearance
    let system = AppIconCenter()
    system.artworkLoader = { _ in stubArtwork }
    system.systemDarkProvider = { systemDark }
    system.applier = { _ in }
    system.update(style: .color, mode: .system)
    system.startObservingSystemAppearance()
    systemDark = true
    postSystemAppearanceChanged()
    check(waitForPushCount(system, 2) &&
          system.pushedFileNames == ["app-icon-day", "app-icon-night"],
          "follow-system re-pushes the matching artwork on a system dark switch")
    systemDark = false
    postSystemAppearanceChanged()
    check(waitForPushCount(system, 3) &&
          system.pushedFileNames == ["app-icon-day", "app-icon-night", "app-icon-day"],
          "follow-system re-pushes back on the light flip")

    // 不得重复注册：同一系统翻转只重推一次（到达 4 后再留防假绿静默窗）
    systemDark = true
    system.startObservingSystemAppearance()
    postSystemAppearanceChanged()
    let duplicateArrived = waitForPushCount(system, 4)
    runMainLoop(0.25)
    check(duplicateArrived && system.pushedFileNames.count == 4,
          "a duplicate startObserving does not register a second observer")

    // 停止观察必须清理所有 observer（「不应再推」用明确 quiet window 证明）
    system.stopObservingSystemAppearance()
    systemDark = false
    postSystemAppearanceChanged()
    runMainLoop(0.3)
    check(system.pushedFileNames.count == 4,
          "stopping the observer removes every registration")

    // 改界面外观本身不得被误当系统切换（界面主题固定深色，系统仍浅色 → 图标保持日间）
    let interfacePinned = AppIconCenter()
    var pinnedSystemDark = false
    interfacePinned.artworkLoader = { _ in stubArtwork }
    interfacePinned.systemDarkProvider = { pinnedSystemDark }
    interfacePinned.applier = { _ in }
    NSApplication.shared.appearance = NSAppearance(named: .aqua)
    interfacePinned.update(style: .color, mode: .system)
    interfacePinned.startObservingSystemAppearance()
    NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    // 只跑 runloop、不投递任何系统通知：界面外观变化本身不得触发重推（明确 quiet window）
    runMainLoop(0.3)
    check(interfacePinned.pushedFileNames == ["app-icon-day"],
          "changing the interface appearance is not mistaken for a system switch")
    // 界面固定时，真实系统切换仍驱动「跟随系统」图标
    pinnedSystemDark = true
    postSystemAppearanceChanged()
    check(waitForPushCount(interfacePinned, 2) &&
          interfacePinned.pushedFileNames == ["app-icon-day", "app-icon-night"],
          "with the interface pinned light, a real system dark switch still drives the follow-system icon")
    interfacePinned.stopObservingSystemAppearance()

    // 固定模式对系统切换免疫（「不应再推」用明确 quiet window 证明）
    let fixedLight = AppIconCenter()
    fixedLight.artworkLoader = { _ in stubArtwork }
    fixedLight.systemDarkProvider = { systemDark }
    fixedLight.applier = { _ in }
    fixedLight.update(style: .monochrome, mode: .light)
    fixedLight.startObservingSystemAppearance()
    systemDark = true
    postSystemAppearanceChanged()
    systemDark = false
    postSystemAppearanceChanged()
    runMainLoop(0.3)
    check(fixedLight.pushedFileNames == ["app-icon-mono-day"],
          "fixed light ignores system appearance flips")
    fixedLight.stopObservingSystemAppearance()

    let fixedDark = AppIconCenter()
    fixedDark.artworkLoader = { _ in stubArtwork }
    fixedDark.systemDarkProvider = { systemDark }
    fixedDark.applier = { _ in }
    fixedDark.update(style: .color, mode: .dark)
    fixedDark.startObservingSystemAppearance()
    systemDark = true
    postSystemAppearanceChanged()
    runMainLoop(0.3)
    check(fixedDark.pushedFileNames == ["app-icon-night"],
          "fixed dark pins the dark artwork regardless of the system")
    fixedDark.stopObservingSystemAppearance()

    // 默认系统来源：读全局 AppleInterfaceStyle，不受 NSApp.appearance 覆盖影响
    // （把界面外观固定成与真实系统相反的方向，若来源被覆盖污染必读到反值）
    let globalDark = (UserDefaults.standard.persistentDomain(forName: "NSGlobalDomain")?["AppleInterfaceStyle"] as? String)?
        .caseInsensitiveCompare("Dark") == .orderedSame
    NSApplication.shared.appearance = NSAppearance(named: globalDark ? .aqua : .darkAqua)
    let freshCenter = AppIconCenter()
    check(freshCenter.systemDarkProvider() == globalDark,
          "the default system source reads the global appearance and ignores the app appearance override")
    NSApplication.shared.appearance = previousAppearance

    // ===== F. 独立设置键持久化 / 恢复 / 非法值 =====
    let iconSuiteNames = (0..<3).map { _ in "org.ghfrc.driverstation.test.uitests.appicon.\(UUID().uuidString)" }
    func makeIconSuite(_ name: String) -> UserDefaults { UserDefaults(suiteName: name)! }

    let suite = makeIconSuite(iconSuiteNames[0])
    let model = DSModel(settingsDefaults: suite, persistenceEnabled: true)
    check(model.iconStyle == .color && model.iconAppearance == .system,
          "app icon defaults to color artwork following the system")
    check(suite.object(forKey: "matchsticks.appIconStyle") == nil &&
          suite.object(forKey: "matchsticks.appIconAppearance") == nil,
          "fresh install needs no explicit app-icon overrides")

    // 两维独立：改一个不重置另一个
    model.iconStyle = .monochrome
    check(model.iconAppearance == .system, "changing the icon style never resets the icon appearance")
    model.iconAppearance = .dark
    check(model.iconStyle == .monochrome, "changing the icon appearance never resets the icon style")
    check(suite.string(forKey: "matchsticks.appIconStyle") == "monochrome",
          "icon style persists immediately under its own key")
    check(suite.string(forKey: "matchsticks.appIconAppearance") == "dark",
          "icon appearance persists immediately under its own key")
    check(suite.object(forKey: "matchsticks.appearance") == nil,
          "icon preferences never write the interface theme key")

    // 设置页改动经模型立即推送图稿（注入 center 后验证 wiring）
    model.appIconCenter.artworkLoader = { _ in stubArtwork }
    model.appIconCenter.systemDarkProvider = { true }
    var modelApplied = 0
    model.appIconCenter.applier = { _ in modelApplied += 1 }
    model.iconStyle = .color
    check(model.appIconCenter.pushedFileNames.last == "app-icon-night" && modelApplied == 1,
          "a settings change pushes the resolved artwork through the model immediately")
    model.iconAppearance = .light
    check(model.appIconCenter.pushedFileNames.last == "app-icon-day",
          "pinning the icon appearance re-resolves immediately")

    // 重启恢复 + 启动即设置（loadPersistedSettings 即启动恢复路径；干测试不调 start()）
    let restored = DSModel(settingsDefaults: suite, persistenceEnabled: true)
    restored.appIconCenter.artworkLoader = { _ in stubArtwork }
    restored.appIconCenter.systemDarkProvider = { true }
    var restoredApplied = 0
    restored.appIconCenter.applier = { _ in restoredApplied += 1 }
    restored.loadPersistedSettings()
    check(restored.iconStyle == .color && restored.iconAppearance == .light,
          "icon preferences restore across restart")
    check(restored.appIconCenter.pushedFileNames == ["app-icon-night", "app-icon-day"],
          "startup restore applies the resolved artwork")

    // 损坏 / 未知值安全回默认
    let corruptSuite = makeIconSuite(iconSuiteNames[1])
    for bad in ["neon", "", "COLOR"] {
        corruptSuite.set(bad, forKey: "matchsticks.appIconStyle")
        let corruptModel = DSModel(settingsDefaults: corruptSuite, persistenceEnabled: true)
        corruptModel.loadPersistedSettings()
        check(corruptModel.iconStyle == .color, "unknown stored icon style \(bad) keeps the default color style")
    }
    corruptSuite.set(true, forKey: "matchsticks.appIconStyle")
    let typeCorrupt = DSModel(settingsDefaults: corruptSuite, persistenceEnabled: true)
    typeCorrupt.loadPersistedSettings()
    check(typeCorrupt.iconStyle == .color, "non-string stored icon style is ignored")
    corruptSuite.set(7, forKey: "matchsticks.appIconAppearance")
    let badAppearance = DSModel(settingsDefaults: corruptSuite, persistenceEnabled: true)
    badAppearance.loadPersistedSettings()
    check(badAppearance.iconAppearance == .system, "corrupt stored icon appearance falls back to following the system")
    corruptSuite.set("neon", forKey: "matchsticks.appIconAppearance")
    let unknownAppearance = DSModel(settingsDefaults: corruptSuite, persistenceEnabled: true)
    unknownAppearance.loadPersistedSettings()
    check(unknownAppearance.iconAppearance == .system, "unknown stored icon appearance falls back to following the system")

    // ===== G. 界面主题与图标偏好互不影响 =====
    let previousAppAppearance = NSApplication.shared.appearance
    let themeSuite = makeIconSuite(iconSuiteNames[2])
    let themeModel = DSModel(settingsDefaults: themeSuite, persistenceEnabled: true)
    themeModel.iconAppearance = .dark
    check(NSApplication.shared.appearance == nil,
          "pinning the icon appearance never overrides the interface theme")
    themeModel.appearanceMode = .light
    check(NSApplication.shared.appearance?.name == .aqua,
          "the interface theme still switches normally with icon preferences present")
    check(themeModel.iconAppearance == .dark && themeModel.iconStyle == .color,
          "interface theme changes leave the icon preferences untouched")
    check(themeSuite.string(forKey: "matchsticks.appIconAppearance") == "dark" &&
          themeSuite.object(forKey: "matchsticks.appIconStyle") == nil,
          "icon keys stay separated from the interface theme key")
    NSApplication.shared.appearance = previousAppAppearance

    for name in iconSuiteNames {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    }

    // ===== H. 设置页放置守卫：并入 General 的卡片选择器，无独立面板 / 灰色脚注 / 分段+28px 旧形态 =====
    let settingsSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/MatchSticksDriverStation/Views/SettingsView.swift"), encoding: .utf8)) ?? ""
    let cardsSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/MatchSticksDriverStation/Views/AppIconAppearanceCards.swift"), encoding: .utf8)) ?? ""
    let modelSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/MatchSticksDriverStation/DSModel.swift"), encoding: .utf8)) ?? ""
    let englishTable = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/DSCore/Resources/en.lproj/Localizable.strings"), encoding: .utf8)) ?? ""
    check(!settingsSource.isEmpty && !cardsSource.isEmpty && !modelSource.isEmpty && !englishTable.isEmpty,
          "app-icon placement test loads its source fixtures")
    if let generalStart = settingsSource.range(of: "private var generalPanel")?.lowerBound,
       let generalEnd = settingsSource.range(of: "private var dashboardPanel")?.lowerBound {
        let general = String(settingsSource[generalStart..<generalEnd])
        check(general.contains("settingsSubgroup(tr(\"图标样式\")) {") &&
              general.contains("settingsSubgroup(tr(\"图标外观\")) {"),
              "Icon Style and Icon Appearance form full-width subgroups with the title above the cards")
        check(!general.contains("settingsRow(tr(\"图标样式\"))") &&
              !general.contains("settingsRow(tr(\"图标外观\"))"),
              "icon subgroups no longer squeeze into right-aligned settingsRow rows")
        check(general.contains("AppIconStyleCardPicker(title: tr(\"图标样式\"), selection: $model.iconStyle)"),
              "Icon Style renders the PathBlender-style card picker bound straight to the model inside General")
        check(general.contains("AppIconAppearanceCardPicker(title: tr(\"图标外观\"), style: model.iconStyle, selection: $model.iconAppearance)"),
              "Icon Appearance renders the card picker tracking the current style inside General")
    } else {
        check(false, "General panel source can be located")
    }
    if let subgroupStart = settingsSource.range(of: "private func settingsSubgroup")?.lowerBound {
        let tail = settingsSource[subgroupStart...]
        if let titleUse = tail.range(of: "Text(title)")?.lowerBound,
           let contentUse = tail.range(of: "content()")?.lowerBound {
            check(titleUse < contentUse,
                  "the subgroup helper lays its title out above the card grid")
        } else {
            check(false, "the subgroup helper body can be located")
        }
    } else {
        check(false, "the settingsSubgroup helper exists")
    }
    check(!settingsSource.contains("iconPanel") && !settingsSource.contains("settingsGroup(tr(\"应用图标\"))"),
          "app-icon settings live inside General instead of their own panel group")
    check(!settingsSource.contains("Finder 与启动台图标由应用包提供") && !settingsSource.contains("只影响运行中的 Dock"),
          "the gray Finder/Launchpad explanation footnote is removed from Settings")
    check(!settingsSource.contains("DSSegmentedControl(title: tr(\"图标样式\"") &&
          !settingsSource.contains("DSSegmentedControl(title: tr(\"图标外观\""),
          "icon rows are card pickers, not segmented controls")
    check(!settingsSource.contains("width: 28, height: 28"),
          "the old 28-pixel thumbnails are gone")
    check(!settingsSource.contains("草稿") && !settingsSource.contains("iconDraft") &&
          !settingsSource.contains("保存并应用"),
          "icon settings keep the instant-apply interaction without draft/save mechanics")
    check(modelSource.contains("appIconCenter.update(style: iconStyle, mode: iconAppearance)") &&
          modelSource.contains("appIconCenter.startObservingSystemAppearance()"),
          "startup restores the icon and installs the system-appearance observer")
    check(englishTable.contains("\"图标样式\" = \"Icon Style\";") &&
          englishTable.contains("\"图标外观\" = \"Icon Appearance\";") &&
          englishTable.contains("\"彩色\" = \"Color\";") &&
          englishTable.contains("\"单色\" = \"Monochrome\";"),
          "app-icon labels have English translations")
    check(!englishTable.contains("\"应用图标\" = \"App Icon\";") &&
          !englishTable.contains("Finder 与启动台图标由应用包提供") &&
          !englishTable.contains("图标预览：浅色与深色图稿") &&
          !englishTable.contains("浅色图稿预览") && !englishTable.contains("深色图稿预览"),
          "translations for the removed group title, gray footnote and old preview labels are deleted")

    // ===== I. 卡片实现守卫：Bundle.module 1024 图稿 + 高插值下采样；绝不读 icns / 运行时图标 =====
    check(cardsSource.contains("AppIconArtwork.image(style:"),
          "cards load artwork through the whitelist Bundle.module loader")
    check(cardsSource.contains(".interpolation(.high)"),
          "preview images downsample the 1024-point artwork with high interpolation")
    check(!cardsSource.contains("applicationIconImage") && !cardsSource.contains("NSImage(named:"),
          "cards never read the icns catalog or the running app icon")
    check(cardsSource.contains("previewHeight: CGFloat = 80") && cardsSource.contains("cornerRadius: CGFloat = 7") &&
          cardsSource.contains("selectionRingWidth: CGFloat = 2") && cardsSource.contains("DSTheme.hover"),
          "the preview stage is 80 points tall, neutral-backgrounded, radius 7, selected ring 2 points")
    check(cardsSource.contains("pairWidth: CGFloat = 78") && cardsSource.contains("pairHeight: CGFloat = 60") &&
          cardsSource.contains("pairTileSize: CGFloat = 48") &&
          cardsSource.contains("pairOffsetX: CGFloat = 30") && cardsSource.contains("pairOffsetY: CGFloat = 12") &&
          cardsSource.contains("singleTileSize: CGFloat = 56"),
          "pair container 78×60 with 48-point tiles offset 30×12 and single 56-point artwork match PathBlender")
    check(!cardsSource.contains("cardWidth"),
          "cards carry no fixed width — they split the available width equally like PathBlender's 1fr grid")
    check(cardsSource.components(separatedBy: ".frame(maxWidth: .infinity)").count - 1 >= 2,
          "both the card and its preview stage expand to fill their flexible share")
    check(cardsSource.contains(".focused(") && cardsSource.contains(".accessibilityLabel(") &&
          cardsSource.contains(".isSelected"),
          "cards stay keyboard focusable and screen-reader labeled with selection state")
    check(cardsSource.contains("DSTheme.focusRing"),
          "keyboard focus paints a focus ring like PathBlender's kbd-nav outline")

    // ===== J. 渲染几何：真实画布像素级核对卡片几何（80 舞台、78×60 双图、56 单图、外描边、等宽列、标签在下） =====
    // 像素比对用色类（红/绿/蓝/黄/强调/中性）而非绝对 RGB：SwiftUI 渲染管线按显示色域
    // 重映射分量（如 sRGB 纯红读回 g≈0.15），绝对值断言会随显示环境漂移。
    let previousCardAppearance = NSApplication.shared.appearance
    NSApplication.shared.appearance = NSAppearance(named: .aqua)
    defer { NSApplication.shared.appearance = previousCardAppearance }

    let lightRed = iconSolidImage(red: 1, green: 0, blue: 0)
    let darkGreen = iconSolidImage(red: 0, green: 1, blue: 0)
    let monoBlue = iconSolidImage(red: 0, green: 0, blue: 1)
    let monoYellow = iconSolidImage(red: 1, green: 1, blue: 0)
    func fourWayArtwork(style: IconStyle, dark: Bool) -> NSImage {
        switch (style, dark) {
        case (.color, false): return lightRed
        case (.color, true): return darkGreen
        case (.monochrome, false): return monoBlue
        case (.monochrome, true): return monoYellow
        }
    }

    // J1 双图几何：120×80 舞台内 78×60 容器居中，两张 48pt 图，第二张偏移 (30,12)
    let pairStage = AppIconCardStage(isSelected: false) { AppIconPairArtwork(light: lightRed, dark: darkGreen) }
    if let pairBitmap = iconCardBitmap(pairStage.frame(width: 120, height: 80), width: 120, height: 80) {
        check(iconPixelIs(pairBitmap, x: 36, y: 16, .red) &&
              iconPixelIs(pairBitmap, x: 84, y: 46, .green),
              "the pair stage renders the light tile top-left and the dark tile offset 30×12")
        check(iconPixelIs(pairBitmap, x: 10, y: 40, .neutral) &&
              iconPixelIs(pairBitmap, x: 60, y: 5, .neutral),
              "the stage keeps its neutral background around the 78×60 pair")
        check(iconPixelIs(pairBitmap, x: 4, y: 4, .neutral) &&
              iconPixelEmpty(pairBitmap, x: 1, y: 1),
              "the stage corner is rounded near radius 7 (inside at (4,4), outside at (1,1))")
    } else {
        check(false, "the pair stage renders at 120×80")
    }

    // J2 单图几何：56pt 单图居中于 80pt 舞台
    let singleStage = AppIconCardStage(isSelected: false) { AppIconSingleArtwork(image: lightRed) }
    if let singleBitmap = iconCardBitmap(singleStage.frame(width: 120, height: 80), width: 120, height: 80) {
        check(iconPixelIs(singleBitmap, x: 60, y: 40, .red) &&
              iconPixelIs(singleBitmap, x: 86, y: 66, .red),
              "fixed light/dark cards render one centered 56-point tile")
        check(iconPixelIs(singleBitmap, x: 60, y: 8, .neutral) &&
              iconPixelIs(singleBitmap, x: 92, y: 72, .neutral),
              "the neutral stage stays visible around the single tile")
    } else {
        check(false, "the single stage renders at 120×80")
    }

    // J3 选中描边：2pt 强调色环，外扩 3pt（画在舞台外，不进内部）；未选中无环
    if let ringBitmap = iconCardBitmap(
        AppIconCardStage(isSelected: true) { AppIconSingleArtwork(image: lightRed) }
            .padding(10).frame(width: 140, height: 100), width: 140, height: 100),
       let idleBitmap = iconCardBitmap(pairStage.padding(10).frame(width: 140, height: 100), width: 140, height: 100) {
        check(iconPixelIs(ringBitmap, x: 6, y: 50, .accent) &&
              iconPixelIs(ringBitmap, x: 70, y: 6, .accent),
              "a selected card paints a 2-point accent ring 3 points outside the stage")
        check(iconPixelIs(ringBitmap, x: 14, y: 50, .neutral),
              "the selection ring stays outside the stage interior")
        check(iconPixelEmpty(idleBitmap, x: 6, y: 50),
              "an unselected card paints no ring")
    } else {
        check(false, "ring bitmaps render at 140×100")
    }

    // J4 样式卡：两列等宽；每张恒为该样式浅/深双图；仅选中卡带描边；标签在预览下方。
    // 等宽扫描取 y=15：舞台内部、双图上缘（y=20）之上，整行都是中性舞台底。
    var styleSelection = IconStyle.color
    let stylePicker = AppIconStyleCardPicker(
        title: "样式", selection: Binding(get: { styleSelection }, set: { styleSelection = $0 }),
        artwork: fourWayArtwork)
    if let styleBitmap = iconCardBitmap(
        stylePicker.padding(10).frame(width: 272, height: 150, alignment: .topLeading), width: 272, height: 150) {
        let runs = iconHoverRuns(styleBitmap, y: 15, width: 272)
        check(runs.count == 2 && runs.allSatisfy({ $0 >= 114 && $0 <= 124 }),
              "Icon Style lays out two equal-width preview cards (runs: \(runs))")
        check(iconPixelIs(styleBitmap, x: 46, y: 26, .red) &&
              iconPixelIs(styleBitmap, x: 94, y: 56, .green),
              "the Color card previews its own light/dark pair")
        check(iconPixelIs(styleBitmap, x: 178, y: 26, .blue) &&
              iconPixelIs(styleBitmap, x: 226, y: 56, .yellow),
              "the Monochrome card previews its own light/dark pair")
        check(iconPixelIs(styleBitmap, x: 6, y: 50, .accent) &&
              iconPixelEmpty(styleBitmap, x: 138, y: 50),
              "only the selected style card carries the ring")
        check(iconBandHasClass(styleBitmap, yRange: 99..<140, xRange: 10..<130, .ink) &&
              iconBandHasClass(styleBitmap, yRange: 99..<140, xRange: 142..<262, .ink) &&
              !iconBandHasClass(styleBitmap, yRange: 99..<150, xRange: 0..<272, .neutral),
              "card labels render below the preview stage, never inside it")
    } else {
        check(false, "the style picker renders at 272×150")
    }

    // J5 外观卡：三列等宽；跟随系统=双图、浅/深=对应单图（跟随当前样式）；仅选中卡带描边
    var appearanceSelection = AppearanceMode.dark
    let appearancePicker = AppIconAppearanceCardPicker(
        title: "外观", style: .monochrome,
        selection: Binding(get: { appearanceSelection }, set: { appearanceSelection = $0 }),
        artwork: fourWayArtwork)
    if let appearanceBitmap = iconCardBitmap(
        appearancePicker.padding(10).frame(width: 404, height: 150, alignment: .topLeading), width: 404, height: 150) {
        let runs = iconHoverRuns(appearanceBitmap, y: 15, width: 404)
        check(runs.count == 3 && runs.allSatisfy({ $0 >= 114 && $0 <= 124 }),
              "Icon Appearance lays out three equal-width preview cards (runs: \(runs))")
        check(iconPixelIs(appearanceBitmap, x: 46, y: 26, .blue) &&
              iconPixelIs(appearanceBitmap, x: 94, y: 56, .yellow),
              "Follow System previews the current style as a light/dark pair")
        check(iconPixelIs(appearanceBitmap, x: 202, y: 50, .blue) &&
              iconPixelIs(appearanceBitmap, x: 334, y: 50, .yellow),
              "Light and Dark cards preview single 56-point tiles of the current style")
        check(iconPixelIs(appearanceBitmap, x: 270, y: 50, .accent) &&
              iconPixelEmpty(appearanceBitmap, x: 138, y: 50),
              "only the selected appearance card carries the ring")
    } else {
        check(false, "the appearance picker renders at 404×150")
    }

    // J6 均分全宽（用户强调「一半一半」）：宽画布下两卡各占一半、三卡各占三分之一，
    // 等宽且覆盖几乎全部内宽（固定 120pt 卡片在 300/460 内宽下必然不足）。
    if let wideStyle = iconCardBitmap(
        stylePicker.padding(10).frame(width: 320, height: 150, alignment: .topLeading), width: 320, height: 150) {
        let runs = iconHoverRuns(wideStyle, y: 15, width: 320)
        check(runs.count == 2 && runs.allSatisfy({ $0 >= 130 }) && runs.max()! - runs.min()! <= 2,
              "Icon Style cards split the full width in half (runs: \(runs))")
    } else {
        check(false, "the wide style picker renders at 320×150")
    }
    if let wideAppearance = iconCardBitmap(
        appearancePicker.padding(10).frame(width: 480, height: 150, alignment: .topLeading), width: 480, height: 150) {
        let runs = iconHoverRuns(wideAppearance, y: 15, width: 480)
        check(runs.count == 3 && runs.allSatisfy({ $0 >= 130 }) && runs.max()! - runs.min()! <= 2,
              "Icon Appearance cards split the full width in thirds (runs: \(runs))")
    } else {
        check(false, "the wide appearance picker renders at 480×150")
    }
}

// MARK: - 卡片渲染测试辅助（像素采样均基于 1x 位图，y=0 为顶行；
// 用色类比较规避 SwiftUI 渲染管线的显示色域分量重映射，如 sRGB 纯红读回 g≈0.15）

@MainActor
private func iconCardBitmap<V: View>(_ view: V, width: Int, height: Int) -> NSBitmapImageRep? {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
    renderer.scale = 1
    guard let image = renderer.nsImage,
          image.size.width == CGFloat(width), image.size.height == CGFloat(height),
          let bitmap = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()),
          bitmap.pixelsWide == width, bitmap.pixelsHigh == height else { return nil }
    return bitmap
}

private enum IconPixelClass: Equatable {
    case empty, red, green, blue, yellow, accent, neutral, ink, other
}

private func iconClass(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> IconPixelClass {
    guard let color = bitmap.colorAt(x: x, y: y) else { return .other }
    if color.alphaComponent < 0.15 { return .empty }
    let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
    if r > 0.7 && g < 0.4 && b < 0.4 { return .red }
    if g > 0.7 && r < 0.4 && b < 0.4 { return .green }
    if b > 0.7 && r < 0.4 && g < 0.4 { return .blue }
    if r > 0.7 && g > 0.7 && b < 0.4 { return .yellow }
    if b > 0.8 && g > 0.3 && g < 0.7 && r < 0.3 { return .accent }
    if r > 0.85 && g > 0.85 && b > 0.85 { return .neutral }
    if r < 0.6 && g < 0.6 && b < 0.6 { return .ink }
    return .other
}

private func iconPixelIs(_ bitmap: NSBitmapImageRep, x: Int, y: Int, _ expected: IconPixelClass) -> Bool {
    iconClass(bitmap, x: x, y: y) == expected
}

private func iconPixelEmpty(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> Bool {
    iconClass(bitmap, x: x, y: y) == .empty
}

/// 沿水平线统计「中性舞台色」连续段长度（≥40 才计），用于等宽列校验。
private func iconHoverRuns(_ bitmap: NSBitmapImageRep, y: Int, width: Int) -> [Int] {
    var runs: [Int] = []
    var run = 0
    for x in 0..<width {
        if iconClass(bitmap, x: x, y: y) == .neutral {
            run += 1
        } else {
            if run >= 40 { runs.append(run) }
            run = 0
        }
    }
    if run >= 40 { runs.append(run) }
    return runs
}

private func iconBandHasClass(_ bitmap: NSBitmapImageRep, yRange: Range<Int>, xRange: Range<Int>,
                              _ wanted: IconPixelClass) -> Bool {
    for y in yRange {
        for x in xRange {
            if iconClass(bitmap, x: x, y: y) == wanted {
                return true
            }
        }
    }
    return false
}

private func iconSolidImage(red: Double, green: Double, blue: Double) -> NSImage {
    NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1).setFill()
        rect.fill()
        return true
    }
}
