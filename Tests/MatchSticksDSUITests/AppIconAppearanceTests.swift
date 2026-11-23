import AppKit
import DSCore

// MARK: 应用图标运行时外观（2026-11-23）行为测试
//
// 覆盖：IconStyle 枚举解析、四图白名单映射与真实 bundle 加载、
// AppIconCenter 解析矩阵（跟随系统浅/深切换 + 固定模式免疫系统变化 + 图稿缺失静默）、
// 独立设置键持久化 / 重启恢复 / 非法值回默认、界面主题与图标偏好互不影响、
// 设置页即时生效交互与源码放置守卫（Finder/启动台说明脚注）。

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

    // ===== C. 真实 bundle 加载：四图均可加载；白名单拒绝清单外文件 =====
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let iconDirectory = repositoryRoot.appendingPathComponent("Sources/MatchSticksDS/Resources/AppIcons")
    let bundleDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("MatchSticks-DS-appicon-\(UUID().uuidString).bundle", isDirectory: true)
    let resourcesDirectory = bundleDirectory.appendingPathComponent("Contents/Resources", isDirectory: true)
    try? FileManager.default.createDirectory(at: resourcesDirectory, withIntermediateDirectories: true)
    for name in AppIconArtwork.whitelist {
        try? FileManager.default.copyItem(at: iconDirectory.appendingPathComponent("\(name).png"),
                                          to: resourcesDirectory.appendingPathComponent("\(name).png"))
    }
    // 清单外的有效 PNG：白名单必须在加载之前拒绝
    try? FileManager.default.copyItem(at: iconDirectory.appendingPathComponent("app-icon-day.png"),
                                      to: resourcesDirectory.appendingPathComponent("rogue-icon.png"))
    if let artworkBundle = Bundle(path: bundleDirectory.path) {
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
    } else {
        check(false, "test artwork bundle loads")
    }
    try? FileManager.default.removeItem(at: bundleDirectory)
    check(!FileManager.default.fileExists(atPath: bundleDirectory.path),
          "app-icon test bundle is removed")

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
    func postSystemAppearanceChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, deliverImmediately: true)
        // 分布式投递经 distnotd 往返，异步送达：跑主 runloop 等交付
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
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
    check(system.pushedFileNames == ["app-icon-day", "app-icon-night"],
          "follow-system re-pushes the matching artwork on a system dark switch")
    systemDark = false
    postSystemAppearanceChanged()
    check(system.pushedFileNames == ["app-icon-day", "app-icon-night", "app-icon-day"],
          "follow-system re-pushes back on the light flip")

    // 不得重复注册：同一系统翻转只重推一次
    systemDark = true
    system.startObservingSystemAppearance()
    postSystemAppearanceChanged()
    check(system.pushedFileNames.count == 4,
          "a duplicate startObserving does not register a second observer")

    // 停止观察必须清理所有 observer
    system.stopObservingSystemAppearance()
    systemDark = false
    postSystemAppearanceChanged()
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
    // 只跑 runloop、不投递任何系统通知：界面外观变化本身不得触发重推
    let quietDeadline = Date().addingTimeInterval(0.3)
    while Date() < quietDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    check(interfacePinned.pushedFileNames == ["app-icon-day"],
          "changing the interface appearance is not mistaken for a system switch")
    // 界面固定时，真实系统切换仍驱动「跟随系统」图标
    pinnedSystemDark = true
    postSystemAppearanceChanged()
    check(interfacePinned.pushedFileNames == ["app-icon-day", "app-icon-night"],
          "with the interface pinned light, a real system dark switch still drives the follow-system icon")
    interfacePinned.stopObservingSystemAppearance()

    // 固定模式对系统切换免疫
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

    // ===== H. 设置页放置守卫：独立面板、即时绑定、白名单预览、Finder/启动台说明 =====
    let settingsSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/MatchSticksDS/Views/SettingsView.swift"), encoding: .utf8)) ?? ""
    let modelSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/MatchSticksDS/DSModel.swift"), encoding: .utf8)) ?? ""
    let englishTable = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/DSCore/Resources/en.lproj/Localizable.strings"), encoding: .utf8)) ?? ""
    check(!settingsSource.isEmpty && !modelSource.isEmpty && !englishTable.isEmpty,
          "app-icon placement test loads its source fixtures")
    check(iconSourceOrder(["generalPanel", "iconPanel", "dashboardPanel"], in: settingsSource),
          "the app-icon panel sits between General and Dashboard in Settings")
    check(settingsSource.contains("selection: $model.iconStyle") &&
          settingsSource.contains("selection: $model.iconAppearance"),
          "icon rows bind directly to the model for immediate effect")
    check(!settingsSource.contains("草稿") && !settingsSource.contains("iconDraft") &&
          !settingsSource.contains("保存并应用"),
          "icon settings keep the instant-apply interaction without draft/save mechanics")
    check(settingsSource.contains("AppIconArtwork.image(style:"),
          "previews resolve artwork through the whitelist loader")
    check(settingsSource.contains("Finder 与启动台图标由应用包提供") &&
          settingsSource.contains("只影响运行中的 Dock"),
          "the footnote explains Finder/Launchpad bundle behavior and the running-Dock scope")
    check(modelSource.contains("appIconCenter.update(style: iconStyle, mode: iconAppearance)") &&
          modelSource.contains("appIconCenter.startObservingSystemAppearance()"),
          "startup restores the icon and installs the system-appearance observer")
    check(englishTable.contains("\"应用图标\" = \"App Icon\";") &&
          englishTable.contains("\"图标样式\" = \"Icon Style\";") &&
          englishTable.contains("\"图标外观\" = \"Icon Appearance\";") &&
          englishTable.contains("\"彩色\" = \"Color\";") &&
          englishTable.contains("\"单色\" = \"Monochrome\";"),
          "app-icon labels have English translations")
    check(englishTable.contains("Finder 与启动台图标由应用包提供"),
          "the Finder/Launchpad footnote has an English translation")
}

/// 源码顺序守卫（main.swift 同名 helper 为文件私有，此处独立实现）：
/// 各标记按给定先后出现（全部存在才算通过）。
private func iconSourceOrder(_ markers: [String], in text: String) -> Bool {
    var cursor = text.startIndex
    for marker in markers {
        guard let found = text.range(of: marker, range: cursor..<text.endIndex) else { return false }
        cursor = found.upperBound
    }
    return true
}
