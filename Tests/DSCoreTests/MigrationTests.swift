// MARK: 品牌改名迁移回归（env 三级兼容 / 设置前缀 / 数据目录链 / 旧录制魔数）

import Foundation
import DSCore

// MARK: 环境变量：新前缀 → 过渡前缀 → 旧前缀逐级回退

func environmentCompatibilityTests() {
    check(DSEnvironment.prefix == "MATCHSTICKS_DRIVER_STATION_"
          && DSEnvironment.interimPrefix == "MATCHSTICKS_DS_"
          && DSEnvironment.legacyPrefix == "GHDS_",
          "env 前缀映射固定（新 → 过渡 → 旧）")
    let allThree = [
        "MATCHSTICKS_DRIVER_STATION_FEED_URL": "newest-feed",
        "MATCHSTICKS_DS_FEED_URL": "interim-feed",
        "GHDS_FEED_URL": "old-feed",
    ]
    check(DSEnvironment.string("FEED_URL", environment: allThree) == "newest-feed", "新 env 键优先")
    check(DSEnvironment.string("FEED_URL", environment: [
        "MATCHSTICKS_DS_FEED_URL": "interim-feed",
        "GHDS_FEED_URL": "old-feed",
    ]) == "interim-feed", "过渡 MATCHSTICKS_DS_ 键优先于 GHDS_")
    check(DSEnvironment.string("FEED_URL", environment: ["GHDS_FEED_URL": "old-feed"]) == "old-feed",
          "旧 GHDS_ 键回退兼容")
    check(DSEnvironment.string("FEED_URL", environment: [
        "MATCHSTICKS_DS_FEED_URL": "interim-only",
    ]) == "interim-only", "仅过渡键存在时生效")
    check(DSEnvironment.string("FEED_URL", environment: [:]) == nil, "三级键都缺失返回 nil")
    check(DSEnvironment.string("FEED_URL", environment: [
        "MATCHSTICKS_DRIVER_STATION_FEED_URL": "",
        "MATCHSTICKS_DS_FEED_URL": "interim-feed",
        "GHDS_FEED_URL": "old-feed",
    ]) == "", "新键存在即权威（空值不落回旧键）")
    check(DSEnvironment.string("FEED_URL", environment: [
        "MATCHSTICKS_DS_FEED_URL": "",
        "GHDS_FEED_URL": "old-feed",
    ]) == "", "过渡键存在即权威（空值不落回 GHDS_）")

    check(DSEnvironment.isEnabled("AUTO_SIM", environment: [
        "MATCHSTICKS_DRIVER_STATION_AUTO_SIM": "1",
    ]), "新开关键")
    check(DSEnvironment.isEnabled("AUTO_SIM", environment: [
        "MATCHSTICKS_DS_AUTO_SIM": "1",
    ]), "过渡开关键回退")
    check(DSEnvironment.isEnabled("AUTO_SIM", environment: ["GHDS_AUTO_SIM": "1"]), "旧开关键回退")
    check(!DSEnvironment.isEnabled("AUTO_SIM", environment: [
        "MATCHSTICKS_DRIVER_STATION_AUTO_SIM": "0",
        "MATCHSTICKS_DS_AUTO_SIM": "1",
        "GHDS_AUTO_SIM": "1",
    ]), "新开关键 0 压制两级旧键")
    check(!DSEnvironment.isEnabled("AUTO_SIM", environment: [
        "MATCHSTICKS_DS_AUTO_SIM": "0",
        "GHDS_AUTO_SIM": "1",
    ]), "过渡开关键 0 压制 GHDS_")
    check(!DSEnvironment.isEnabled("AUTO_SIM", environment: ["GHDS_AUTO_SIM": "true"]),
          "开关仅接受 1")

    // 只读最新前缀：测试专用路径覆盖不得回退 MATCHSTICKS_DS_ / GHDS_ alias
    check(DSEnvironment.currentString("APPLICATION_SUPPORT", environment: [
        "MATCHSTICKS_DRIVER_STATION_APPLICATION_SUPPORT": "/tmp/newest-support",
    ]) == "/tmp/newest-support", "currentString 读取最新前缀")
    check(DSEnvironment.currentString("APPLICATION_SUPPORT", environment: [
        "MATCHSTICKS_DS_APPLICATION_SUPPORT": "/tmp/interim-support",
    ]) == nil, "currentString 不读过渡 alias")
    check(DSEnvironment.currentString("APPLICATION_SUPPORT", environment: [
        "GHDS_APPLICATION_SUPPORT": "/tmp/old-support",
    ]) == nil, "currentString 不读旧 alias")
    check(DSEnvironment.currentString("APPLICATION_SUPPORT", environment: [
        "MATCHSTICKS_DRIVER_STATION_APPLICATION_SUPPORT": "/tmp/newest-support",
        "MATCHSTICKS_DS_APPLICATION_SUPPORT": "/tmp/interim-support",
        "GHDS_APPLICATION_SUPPORT": "/tmp/old-support",
    ]) == "/tmp/newest-support", "currentString 三级并存时最新键优先")
}

// MARK: 设置：四类型回退迁移、新键优先、set nil 双删、测试前缀隔离

func settingsMigrationTests() {
    check(SettingsStore.defaultPrefix == "matchsticks." && SettingsStore.legacyPrefix == "ghds.",
          "设置前缀映射固定")
    let name = "matchsticks-driver-station-settings-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }

    // 默认前缀 = matchsticks.；旧 ghds. 自动参与回退迁移
    defaults.set(254, forKey: "ghds.teamNumber")
    defaults.set("10.25.9.2", forKey: "ghds.manualIP")
    defaults.set(1.25, forKey: "ghds.practiceAutoTime")
    defaults.set(false, forKey: "ghds.soundsEnabled")

    let store = SettingsStore(defaults: defaults)
    check(store.integer("teamNumber") == 254, "旧整型迁移")
    check((defaults.object(forKey: "matchsticks.teamNumber") as? Int) == 254, "旧整型读到后写新键")
    check(store.string("manualIP") == "10.25.9.2", "旧字符串迁移")
    check(defaults.string(forKey: "matchsticks.manualIP") == "10.25.9.2", "旧字符串写到新键")
    check(abs((store.double("practiceAutoTime") ?? 0) - 1.25) < 0.0001, "旧浮点迁移")
    check(defaults.object(forKey: "matchsticks.practiceAutoTime") != nil, "旧浮点写到新键")
    check(store.bool("soundsEnabled") == false, "旧布尔 false 迁移（不被默认值吞掉）")
    check(defaults.object(forKey: "matchsticks.soundsEnabled") != nil, "旧布尔写到新键")
    check(defaults.object(forKey: "ghds.teamNumber") != nil, "迁移不删除旧键")

    // 新键优先
    defaults.set(999, forKey: "ghds.teamNumber")
    check(store.integer("teamNumber") == 254, "新键已存在时不回退旧键")
    defaults.set(1000, forKey: "matchsticks.teamNumber")
    check(store.integer("teamNumber") == 1000, "新键值覆盖旧键")

    // set nil：新旧键同时删除，旧值不复活；这是用户主动清除，不是普通迁移
    defaults.set("10.25.9.9", forKey: "ghds.manualIP")
    check(store.string("manualIP") == "10.25.9.2", "新键优先于旧值")
    store.set("manualIP", nil as String?)
    check(store.string("manualIP") == nil, "删除后读 nil")
    check(defaults.object(forKey: "matchsticks.manualIP") == nil, "新键已删除")
    check(defaults.object(forKey: "ghds.manualIP") == nil, "旧键同时删除，旧值不复活")

    // 正常 set 同步写新旧键：降级回旧版本仍读到最新值（回滚支持）
    store.set("teamNumber", 1234)
    check((defaults.object(forKey: "matchsticks.teamNumber") as? Int) == 1234, "正常 set 写新键")
    check((defaults.object(forKey: "ghds.teamNumber") as? Int) == 1234, "正常 set 同步写旧键（回滚可用）")
    store.set("manualIP", "10.25.9.3")
    check(defaults.string(forKey: "ghds.manualIP") == "10.25.9.3", "字符串 set 同步写旧键")
    store.set("practiceAutoTime", 2.5)
    check(abs(defaults.double(forKey: "ghds.practiceAutoTime") - 2.5) < 0.0001,
          "浮点 set 同步写旧键")
    store.set("soundsEnabled", true)
    check(defaults.bool(forKey: "ghds.soundsEnabled") == true, "布尔 set 同步写旧键")

    // 类型安全：错误类型不迁移，也不遮蔽可用的旧值
    defaults.set("254", forKey: "ghds.textTeam")
    check(store.integer("textTeam") == nil, "字符串旧值不按整型读")
    check(defaults.object(forKey: "matchsticks.textTeam") == nil, "类型不符的旧值不迁移")
    defaults.set(2.5, forKey: "ghds.floatTeam")
    check(store.integer("floatTeam") == nil, "浮点旧值不按整型读（避免截断）")
    defaults.set(true, forKey: "ghds.boolTeam")
    check(store.integer("boolTeam") == nil, "布尔旧值不按整型读")

    // 新键存在但类型不符：新键是权威值，旧值不得回退覆盖
    defaults.set(88, forKey: "ghds.typedTeam")
    defaults.set("bad", forKey: "matchsticks.typedTeam")
    check(store.integer("typedTeam") == nil, "新键类型不符时不回退旧值")
    check(defaults.string(forKey: "matchsticks.typedTeam") == "bad", "类型不符的新键不被旧值覆盖")
    check((defaults.object(forKey: "ghds.typedTeam") as? Int) == 88, "旧键保持原值")
    store.set("typedTeam", 77)
    check(store.integer("typedTeam") == 77, "显式 set 可修复类型不符的新键")
    check((defaults.object(forKey: "ghds.typedTeam") as? Int) == 77, "显式修复同步旧键")

    defaults.set(42, forKey: "matchsticks.textTeam")
    check(store.string("textTeam") == nil, "新键字符串类型不符时不回退旧值")
    check((defaults.object(forKey: "matchsticks.textTeam") as? Int) == 42, "类型不符的新键保持原值")
    store.set("textTeam", "fixed")
    check(store.string("textTeam") == "fixed", "字符串 set 修复新键")
    check(defaults.string(forKey: "ghds.textTeam") == "fixed", "字符串修复同步旧键")

    // 自定义测试前缀默认不读生产旧键；显式 legacyPrefix 才启用迁移
    defaults.set("production", forKey: "ghds.isolated")
    let isolated = SettingsStore(defaults: defaults, prefix: "uitest.")
    check(isolated.string("isolated") == nil, "自定义前缀不意外读取生产 ghds. 键")
    check(defaults.object(forKey: "uitest.isolated") == nil, "未发生跨前缀写入")
    isolated.set("isolated", "uitest-value")
    check(defaults.string(forKey: "uitest.isolated") == "uitest-value", "自定义前缀正常写入")
    check(defaults.string(forKey: "ghds.isolated") == "production", "自定义前缀 set 不碰生产旧键")

    let explicit = SettingsStore(
        defaults: defaults,
        prefix: "custom.",
        legacyPrefix: "custom-legacy."
    )
    defaults.set("legacy", forKey: "custom-legacy.isolated")
    check(explicit.string("isolated") == "legacy", "显式旧前缀可迁移")
    check(defaults.string(forKey: "custom.isolated") == "legacy", "显式旧前缀写到自定义新键")
    explicit.set("isolated", "updated")
    check(defaults.string(forKey: "custom.isolated") == "updated", "显式旧前缀正常 set 写新键")
    check(defaults.string(forKey: "custom-legacy.isolated") == "updated", "显式旧前缀正常 set 同步旧键")
    explicit.set("isolated", nil)
    check(defaults.object(forKey: "custom.isolated") == nil, "显式旧前缀 set nil 删新键")
    check(defaults.object(forKey: "custom-legacy.isolated") == nil, "显式旧前缀 set nil 删旧键")
}

// MARK: Application Support 测试辅助

private func makeMigrationBase(_ label: String) -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("matchsticks-driver-station-\(label)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

private func makeMigrationDirectory(_ url: URL) {
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

private func isSymbolicLink(_ url: URL) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
}

private func migrationTemporaryArtifacts(in root: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
    ) else { return [] }
    var found: [URL] = []
    for case let url as URL in enumerator where url.lastPathComponent.contains(".matchsticks-migration-") {
        found.append(url)
    }
    return found
}

/// 迁移在后台执行：copyItem 被闸门挡住时，初始化必须已经返回。
private final class GatedCopyFileManager: FileManager {
    let gate = DispatchSemaphore(value: 0)

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        _ = gate.wait(timeout: .now() + 10)
        try super.copyItem(at: srcURL, to: dstURL)
    }
}

/// 指定文件复制失败：用于验证失败清理临时文件且保留旧目录。
private final class FailingCopyFileManager: FileManager {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try super.copyItem(at: srcURL, to: dstURL)
        if srcURL.lastPathComponent == "fail.dslog" {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// 在复制指定文件时暂停，便于测试“迁移进行中新建同名新文件”的并发覆盖防线。
private final class PausedCopyFileManager: FileManager {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.lastPathComponent == "race.dslog" {
            started.signal()
            _ = release.wait(timeout: .now() + 10)
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}

// MARK: Application Support：双旧源链式补齐、旧目录保留、不覆盖新文件

func appSupportDirectoryTests() {
    check(AppSupportDirectory.name == "MatchSticksDriverStation"
          && AppSupportDirectory.interimName == "MatchSticksDS"
          && AppSupportDirectory.legacyName == "GHDriverStation",
          "Application Support 目录映射固定（新 → 过渡 → 旧）")
    let fm = FileManager.default
    let base = makeMigrationBase("support")
    defer { try? fm.removeItem(at: base) }

    // 双旧源各放数据：同路径文件以过渡目录（较新）为准，旧目录只补缺口
    let interim = base.appendingPathComponent(AppSupportDirectory.interimName, isDirectory: true)
    let legacy = base.appendingPathComponent(AppSupportDirectory.legacyName, isDirectory: true)
    let interimLogs = interim.appendingPathComponent("Logs", isDirectory: true)
    let legacyLogs = legacy.appendingPathComponent("Logs", isDirectory: true)
    let legacyCaptures = legacy.appendingPathComponent("captures", isDirectory: true)
    makeMigrationDirectory(interimLogs)
    makeMigrationDirectory(legacyLogs)
    makeMigrationDirectory(legacyCaptures)
    try! Data("interim-log".utf8).write(to: interimLogs.appendingPathComponent("old.dslog"))
    try! Data("legacy-log".utf8).write(to: legacyLogs.appendingPathComponent("old.dslog"))
    try! Data("old-capture".utf8).write(to: legacyCaptures.appendingPathComponent("old.dsrec"))

    let resolved = AppSupportDirectory(baseURL: base)
    check(resolved.waitForMigration(timeout: 10), "后台迁移可等待完成")
    check(resolved.url.lastPathComponent == AppSupportDirectory.name,
          "优先使用 MatchSticksDriverStation 新目录")
    let newLogs = resolved.subdirectory("Logs")
    let newCaptures = resolved.subdirectory("captures")
    check((try? String(contentsOf: newLogs.appendingPathComponent("old.dslog"), encoding: .utf8)) == "interim-log",
          "新旧源同路径文件以过渡目录（较新）内容为准")
    check(fm.fileExists(atPath: newCaptures.appendingPathComponent("old.dsrec").path),
          "仅旧目录有的录制补齐到新目录")
    check((try? String(contentsOf: interimLogs.appendingPathComponent("old.dslog"), encoding: .utf8)) == "interim-log",
          "过渡目录文件保留且未改写")
    check((try? String(contentsOf: legacyLogs.appendingPathComponent("old.dslog"), encoding: .utf8)) == "legacy-log",
          "旧目录文件保留且未改写")
    check(fm.fileExists(atPath: legacyCaptures.appendingPathComponent("old.dsrec").path),
          "旧目录录制保留")

    // 新目录已有同名文件时不覆盖
    let conflict = newLogs.appendingPathComponent("old.dslog")
    try! Data("new-log".utf8).write(to: conflict)
    let rerun = AppSupportDirectory(baseURL: base)
    check(rerun.waitForMigration(timeout: 10), "重复迁移可等待完成")
    check((try? String(contentsOf: conflict, encoding: .utf8)) == "new-log", "补齐不覆盖新目录已有文件")

    // 新目录独有文件保留；后续新出现的旧文件仍可补齐（含更旧目录来源）
    let newOnly = newLogs.appendingPathComponent("new-only.dslog")
    try! Data("new-only".utf8).write(to: newOnly)
    let interimOnly = interimLogs.appendingPathComponent("late-interim.dslog")
    try! Data("late-interim".utf8).write(to: interimOnly)
    let oldOnly = legacyLogs.appendingPathComponent("late-old.dslog")
    try! Data("late-old".utf8).write(to: oldOnly)
    let late = AppSupportDirectory(baseURL: base)
    check(late.waitForMigration(timeout: 10), "后出现的旧文件迁移可等待完成")
    check((try? String(contentsOf: newOnly, encoding: .utf8)) == "new-only", "新目录独有文件保留")
    check(fm.fileExists(atPath: newLogs.appendingPathComponent("late-interim.dslog").path),
          "后出现的过渡目录文件继续补齐")
    check(fm.fileExists(atPath: newLogs.appendingPathComponent("late-old.dslog").path),
          "后出现的旧目录文件继续补齐")
    check(migrationTemporaryArtifacts(in: resolved.url).isEmpty, "迁移不遗留临时文件")
}

// MARK: Application Support：新目录不可用时按新 → 旧顺序回退

func appSupportChainedFallbackTests() {
    let fm = FileManager.default

    // 新路径被普通文件占位 → 回退过渡目录 MatchSticksDS
    let interimBlockedBase = makeMigrationBase("fallback-interim")
    defer { try? fm.removeItem(at: interimBlockedBase) }
    let interimBlocked = interimBlockedBase
        .appendingPathComponent(AppSupportDirectory.interimName, isDirectory: true)
    makeMigrationDirectory(interimBlocked)
    try! Data("placeholder".utf8).write(
        to: interimBlockedBase.appendingPathComponent(AppSupportDirectory.name))

    let interimFallback = AppSupportDirectory(baseURL: interimBlockedBase)
    check(interimFallback.url.lastPathComponent == AppSupportDirectory.interimName,
          "新目录不可用时先回退 MatchSticksDS")
    check(interimFallback.waitForMigration(timeout: 1), "回退时不启动迁移")
    check(interimFallback.subdirectory("Logs").path.hasPrefix(interimBlocked.path),
          "回退过渡目录后的日志仍落在该目录")

    // 新路径与过渡路径都不可用 → 回退旧目录 GHDriverStation
    let legacyBlockedBase = makeMigrationBase("fallback-legacy")
    defer { try? fm.removeItem(at: legacyBlockedBase) }
    let legacyBlocked = legacyBlockedBase
        .appendingPathComponent(AppSupportDirectory.legacyName, isDirectory: true)
    makeMigrationDirectory(legacyBlocked)
    try! Data("placeholder".utf8).write(
        to: legacyBlockedBase.appendingPathComponent(AppSupportDirectory.name))
    try! Data("placeholder".utf8).write(
        to: legacyBlockedBase.appendingPathComponent(AppSupportDirectory.interimName))

    let legacyFallback = AppSupportDirectory(baseURL: legacyBlockedBase)
    check(legacyFallback.url.lastPathComponent == AppSupportDirectory.legacyName,
          "过渡目录也不可用时回退 GHDriverStation")
    check(legacyFallback.waitForMigration(timeout: 1), "回退旧目录时不启动迁移")
    check(legacyFallback.subdirectory("Logs").path.hasPrefix(legacyBlocked.path),
          "回退旧目录后的日志仍落在该目录")

    // 过渡路径是符号链接 → 不跟随，继续回退旧目录
    let symlinkBase = makeMigrationBase("fallback-symlink")
    defer { try? fm.removeItem(at: symlinkBase) }
    let symlinkTarget = symlinkBase.appendingPathComponent("outside", isDirectory: true)
    makeMigrationDirectory(symlinkTarget)
    let symlinkLegacy = symlinkBase
        .appendingPathComponent(AppSupportDirectory.legacyName, isDirectory: true)
    makeMigrationDirectory(symlinkLegacy)
    try! fm.createSymbolicLink(
        at: symlinkBase.appendingPathComponent(AppSupportDirectory.interimName),
        withDestinationURL: symlinkTarget
    )
    try! Data("placeholder".utf8).write(
        to: symlinkBase.appendingPathComponent(AppSupportDirectory.name))

    let symlinkFallback = AppSupportDirectory(baseURL: symlinkBase)
    check(symlinkFallback.url.lastPathComponent == AppSupportDirectory.legacyName,
          "过渡目录是符号链接时不跟随，回退旧目录")
    let symlinkLeak = symlinkTarget.appendingPathComponent("Logs", isDirectory: true)
    check(!fm.fileExists(atPath: symlinkLeak.path), "回退不写穿过渡符号链接")
}

// MARK: Application Support：迁移后台执行，不阻塞初始化

func appSupportMigrationBackgroundTests() {
    let fm = FileManager.default
    let base = makeMigrationBase("background")
    defer { try? fm.removeItem(at: base) }

    // 大文件放最旧源 GHDriverStation：验证链条末端的源也在后台补齐
    let legacyLogs = base
        .appendingPathComponent(AppSupportDirectory.legacyName, isDirectory: true)
        .appendingPathComponent("Logs", isDirectory: true)
    makeMigrationDirectory(legacyLogs)
    let payload = Data(repeating: 0x5A, count: 256 * 1024)
    try! payload.write(to: legacyLogs.appendingPathComponent("big.dslog"))

    let gated = GatedCopyFileManager()
    let started = Date()
    let resolved = AppSupportDirectory(baseURL: base, fileManager: gated)
    let elapsed = Date().timeIntervalSince(started)
    check(elapsed < 3.0, "初始化不等待后台迁移（\(String(format: "%.3f", elapsed))s）")
    let earlyCopy = resolved.subdirectory("Logs", create: false).appendingPathComponent("big.dslog")
    check(!fm.fileExists(atPath: earlyCopy.path), "初始化返回时迁移尚未完成")

    gated.gate.signal()
    check(resolved.waitForMigration(timeout: 10), "后台迁移可等待完成")
    let copied = resolved.subdirectory("Logs", create: false).appendingPathComponent("big.dslog")
    check((try? Data(contentsOf: copied)) == payload, "后台迁移完成后文件内容完整")
}

// MARK: Application Support：源/目标符号链接一律跳过

func appSupportSymlinkTests() {
    let fm = FileManager.default

    // 源符号链接：指向目录树之外的文件/目录都不复制（双旧源都验证）
    let sourceBase = makeMigrationBase("symlink-source")
    defer { try? fm.removeItem(at: sourceBase) }
    let sourceOutside = sourceBase.appendingPathComponent("outside", isDirectory: true)
    makeMigrationDirectory(sourceOutside)
    let outsideFile = sourceOutside.appendingPathComponent("outside.txt")
    try! Data("outside".utf8).write(to: outsideFile)

    let sourceLegacy = sourceBase.appendingPathComponent(AppSupportDirectory.legacyName, isDirectory: true)
    let sourceLegacyLogs = sourceLegacy.appendingPathComponent("Logs", isDirectory: true)
    makeMigrationDirectory(sourceLegacyLogs)
    try! Data("legacy-real".utf8).write(to: sourceLegacyLogs.appendingPathComponent("real.dslog"))
    try! fm.createSymbolicLink(
        at: sourceLegacyLogs.appendingPathComponent("link.dslog"),
        withDestinationURL: outsideFile
    )
    try! fm.createSymbolicLink(
        at: sourceLegacy.appendingPathComponent("LinkDir"),
        withDestinationURL: sourceOutside
    )
    let sourceInterim = sourceBase.appendingPathComponent(AppSupportDirectory.interimName, isDirectory: true)
    let sourceInterimLogs = sourceInterim.appendingPathComponent("Logs", isDirectory: true)
    makeMigrationDirectory(sourceInterimLogs)
    try! Data("interim-real".utf8).write(to: sourceInterimLogs.appendingPathComponent("real.dslog"))
    try! fm.createSymbolicLink(
        at: sourceInterimLogs.appendingPathComponent("link.dslog"),
        withDestinationURL: outsideFile
    )

    let sourceResolved = AppSupportDirectory(baseURL: sourceBase)
    check(sourceResolved.waitForMigration(timeout: 10), "源符号链接场景迁移可等待完成")
    let sourceNewLogs = sourceResolved.subdirectory("Logs", create: false)
    check((try? String(contentsOf: sourceNewLogs.appendingPathComponent("real.dslog"), encoding: .utf8)) == "interim-real",
          "双源同路径时过渡目录普通文件先落位")
    check(!fm.fileExists(atPath: sourceNewLogs.appendingPathComponent("link.dslog").path),
          "源文件符号链接不复制")
    check(!fm.fileExists(atPath: sourceResolved.url.appendingPathComponent("LinkDir").path),
          "源目录符号链接不复制")
    check((try? String(contentsOf: outsideFile, encoding: .utf8)) == "outside", "源链接指向的外部文件未被改写")

    // 目标符号链接：不覆盖、不写穿、不在其下递归
    let destinationBase = makeMigrationBase("symlink-destination")
    defer { try? fm.removeItem(at: destinationBase) }
    let destinationOutside = destinationBase.appendingPathComponent("outside", isDirectory: true)
    makeMigrationDirectory(destinationOutside)
    let destinationOutsideFile = destinationOutside.appendingPathComponent("outside.txt")
    try! Data("outside".utf8).write(to: destinationOutsideFile)

    let destinationLegacy = destinationBase.appendingPathComponent(AppSupportDirectory.legacyName, isDirectory: true)
    let destinationLegacyLogs = destinationLegacy.appendingPathComponent("Logs", isDirectory: true)
    makeMigrationDirectory(destinationLegacyLogs)
    try! Data("legacy".utf8).write(to: destinationLegacyLogs.appendingPathComponent("real.dslog"))
    let destinationLegacyLinkDir = destinationLegacy.appendingPathComponent("LinkDir", isDirectory: true)
    makeMigrationDirectory(destinationLegacyLinkDir)
    try! Data("evil".utf8).write(to: destinationLegacyLinkDir.appendingPathComponent("evil.txt"))

    let destinationRoot = destinationBase.appendingPathComponent(AppSupportDirectory.name, isDirectory: true)
    let destinationLogs = destinationRoot.appendingPathComponent("Logs", isDirectory: true)
    makeMigrationDirectory(destinationLogs)
    try! fm.createSymbolicLink(
        at: destinationLogs.appendingPathComponent("real.dslog"),
        withDestinationURL: destinationOutsideFile
    )
    try! fm.createSymbolicLink(
        at: destinationRoot.appendingPathComponent("LinkDir"),
        withDestinationURL: destinationOutside
    )

    let destinationResolved = AppSupportDirectory(baseURL: destinationBase)
    check(destinationResolved.waitForMigration(timeout: 10), "目标符号链接场景迁移可等待完成")
    check((try? String(contentsOf: destinationOutsideFile, encoding: .utf8)) == "outside",
          "目标文件符号链接不被写穿")
    check(!fm.fileExists(atPath: destinationOutside.appendingPathComponent("evil.txt").path),
          "目标目录符号链接不被跟随递归")
    check(isSymbolicLink(destinationLogs.appendingPathComponent("real.dslog")), "目标符号链接保持原样")
    check(isSymbolicLink(destinationRoot.appendingPathComponent("LinkDir")), "目标目录符号链接保持原样")

    // 根目录符号链接：源根不迁移；目标根不可用时回退，均不写穿
    let sourceRootBase = makeMigrationBase("symlink-source-root")
    defer { try? fm.removeItem(at: sourceRootBase) }
    let sourceRootOutside = sourceRootBase.appendingPathComponent("outside", isDirectory: true)
    makeMigrationDirectory(sourceRootOutside)
    try! Data("outside-root".utf8).write(to: sourceRootOutside.appendingPathComponent("old.dslog"))
    try! fm.createSymbolicLink(
        at: sourceRootBase.appendingPathComponent(AppSupportDirectory.legacyName, isDirectory: true),
        withDestinationURL: sourceRootOutside
    )
    try! fm.createSymbolicLink(
        at: sourceRootBase.appendingPathComponent(AppSupportDirectory.interimName, isDirectory: true),
        withDestinationURL: sourceRootOutside
    )
    let sourceRootResolved = AppSupportDirectory(baseURL: sourceRootBase)
    check(sourceRootResolved.url.lastPathComponent == AppSupportDirectory.name, "源根符号链接场景仍使用新目录")
    check(sourceRootResolved.waitForMigration(timeout: 1), "双源根均为符号链接时不产生任何迁移")
    let sourceRootLeak = sourceRootResolved.url.appendingPathComponent("old.dslog")
    check(!fm.fileExists(atPath: sourceRootLeak.path), "源根符号链接不被跟随迁移")
    let sourceRootOutsideText = try? String(
        contentsOf: sourceRootOutside.appendingPathComponent("old.dslog"),
        encoding: .utf8
    )
    check(sourceRootOutsideText == "outside-root", "源根符号链接指向的外部文件保持原样")

    let targetRootBase = makeMigrationBase("symlink-target-root")
    defer { try? fm.removeItem(at: targetRootBase) }
    let targetRootOutside = targetRootBase.appendingPathComponent("outside", isDirectory: true)
    makeMigrationDirectory(targetRootOutside)
    let targetRootLegacyLogs = targetRootBase
        .appendingPathComponent(AppSupportDirectory.legacyName, isDirectory: true)
        .appendingPathComponent("Logs", isDirectory: true)
    makeMigrationDirectory(targetRootLegacyLogs)
    try! Data("legacy-root".utf8).write(to: targetRootLegacyLogs.appendingPathComponent("old.dslog"))
    try! fm.createSymbolicLink(
        at: targetRootBase.appendingPathComponent(AppSupportDirectory.name, isDirectory: true),
        withDestinationURL: targetRootOutside
    )
    let targetRootResolved = AppSupportDirectory(baseURL: targetRootBase)
    check(targetRootResolved.url.lastPathComponent == AppSupportDirectory.legacyName,
          "目标根是符号链接时回退（过渡目录不存在则落到旧目录）")
    check(targetRootResolved.waitForMigration(timeout: 1), "目标根符号链接场景不启动迁移")
    let targetRootLeak = targetRootOutside
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("old.dslog")
    check(!fm.fileExists(atPath: targetRootLeak.path), "目标根符号链接不被写穿")
}

// MARK: Application Support：多实例并发迁移不产生半文件/临时文件残留

func appSupportConcurrentMigrationTests() {
    let fm = FileManager.default
    let base = makeMigrationBase("concurrent")
    defer { try? fm.removeItem(at: base) }

    // 两个旧源都铺数据：并发实例下链条仍完整补齐
    let interim = base.appendingPathComponent(AppSupportDirectory.interimName, isDirectory: true)
    let legacy = base.appendingPathComponent(AppSupportDirectory.legacyName, isDirectory: true)
    var expected: [(components: [String], data: Data)] = []
    for index in 0..<24 {
        let source = index % 2 == 0 ? interim : legacy
        let components = ["Logs", "session-\(index % 4)", "file-\(index).dslog"]
        let url = components.reduce(source) { $0.appendingPathComponent($1) }
        makeMigrationDirectory(url.deletingLastPathComponent())
        let data = Data((0..<(32 * 1024 + index)).map { UInt8(($0 + index) % 251) })
        try! data.write(to: url)
        expected.append((components, data))
    }

    let instances = (0..<6).map { _ in AppSupportDirectory(baseURL: base) }
    for (index, instance) in instances.enumerated() {
        check(instance.waitForMigration(timeout: 20), "并发实例 \(index) 迁移可等待完成")
    }

    let newRoot = base.appendingPathComponent(AppSupportDirectory.name, isDirectory: true)
    for item in expected {
        let copied = item.components.reduce(newRoot) { $0.appendingPathComponent($1) }
        check((try? Data(contentsOf: copied)) == item.data,
              "并发迁移文件完整：\(item.components.joined(separator: "/"))")
    }
    check(migrationTemporaryArtifacts(in: newRoot).isEmpty, "并发迁移不遗留临时文件")
    let retained = ["Logs", "session-0", "file-0.dslog"].reduce(interim) { $0.appendingPathComponent($1) }
    check(fm.fileExists(atPath: retained.path), "并发迁移保留过渡目录")
    let retainedLegacy = ["Logs", "session-1", "file-1.dslog"].reduce(legacy) { $0.appendingPathComponent($1) }
    check(fm.fileExists(atPath: retainedLegacy.path), "并发迁移保留旧目录")
}

// MARK: Application Support：迁移进行中新建同名文件不被覆盖

func appSupportConcurrentOverwriteTests() {
    let fm = FileManager.default
    let base = makeMigrationBase("concurrent-overwrite")
    defer { try? fm.removeItem(at: base) }

    let interimLogs = base
        .appendingPathComponent(AppSupportDirectory.interimName, isDirectory: true)
        .appendingPathComponent("Logs", isDirectory: true)
    makeMigrationDirectory(interimLogs)
    try! Data("interim-race".utf8).write(to: interimLogs.appendingPathComponent("race.dslog"))
    let legacyLogs = base
        .appendingPathComponent(AppSupportDirectory.legacyName, isDirectory: true)
        .appendingPathComponent("Logs", isDirectory: true)
    makeMigrationDirectory(legacyLogs)
    try! Data("legacy-race".utf8).write(to: legacyLogs.appendingPathComponent("race.dslog"))

    let paused = PausedCopyFileManager()
    let resolved = AppSupportDirectory(baseURL: base, fileManager: paused)
    let reachedCopy = paused.started.wait(timeout: .now() + 10) == .success
    check(reachedCopy, "迁移进入文件复制阶段")

    let newLogs = resolved.subdirectory("Logs")
    let target = newLogs.appendingPathComponent("race.dslog")
    try! Data("new-race".utf8).write(to: target)
    paused.release.signal()

    check(resolved.waitForMigration(timeout: 10), "并发覆盖场景迁移可等待完成")
    check((try? String(contentsOf: target, encoding: .utf8)) == "new-race",
          "迁移不覆盖并发出现的新文件")
    check(migrationTemporaryArtifacts(in: resolved.url).isEmpty, "并发覆盖失败后清理临时文件")
    check((try? String(contentsOf: interimLogs.appendingPathComponent("race.dslog"), encoding: .utf8)) == "interim-race",
          "并发覆盖场景过渡目录保持原样")
    check((try? String(contentsOf: legacyLogs.appendingPathComponent("race.dslog"), encoding: .utf8)) == "legacy-race",
          "并发覆盖场景旧目录保持原样")
}

// MARK: Application Support：单文件复制失败清理临时文件、保留旧目录、继续其他文件

func appSupportFailureCleanupTests() {
    let fm = FileManager.default
    let base = makeMigrationBase("failure")
    defer { try? fm.removeItem(at: base) }

    // 过渡源放「好文件 + 坏文件」，旧源放同名好文件与独有文件：
    // 过渡源失败不阻断本源其他文件，也不阻断旧源继续补齐
    let interimLogs = base
        .appendingPathComponent(AppSupportDirectory.interimName, isDirectory: true)
        .appendingPathComponent("Logs", isDirectory: true)
    makeMigrationDirectory(interimLogs)
    try! Data("good".utf8).write(to: interimLogs.appendingPathComponent("good.dslog"))
    try! Data("fail".utf8).write(to: interimLogs.appendingPathComponent("fail.dslog"))
    let legacyLogs = base
        .appendingPathComponent(AppSupportDirectory.legacyName, isDirectory: true)
        .appendingPathComponent("Logs", isDirectory: true)
    makeMigrationDirectory(legacyLogs)
    try! Data("legacy-good".utf8).write(to: legacyLogs.appendingPathComponent("legacy-only.dslog"))

    let failing = FailingCopyFileManager()
    let resolved = AppSupportDirectory(baseURL: base, fileManager: failing)
    check(resolved.waitForMigration(timeout: 10), "失败场景迁移可等待完成")

    let newLogs = resolved.subdirectory("Logs", create: false)
    check((try? String(contentsOf: newLogs.appendingPathComponent("good.dslog"), encoding: .utf8)) == "good",
          "单个文件失败不阻断同源其他文件")
    check(!fm.fileExists(atPath: newLogs.appendingPathComponent("fail.dslog").path),
          "失败文件不留下半成品")
    check((try? String(contentsOf: newLogs.appendingPathComponent("legacy-only.dslog"), encoding: .utf8)) == "legacy-good",
          "过渡源失败不阻断旧源补齐")
    check((try? String(contentsOf: interimLogs.appendingPathComponent("fail.dslog"), encoding: .utf8)) == "fail",
          "失败后过渡目录文件保持原样")
    check(migrationTemporaryArtifacts(in: resolved.url).isEmpty, "失败后清理临时文件")
}

// MARK: Application Support：MATCHSTICKS_DRIVER_STATION_APPLICATION_SUPPORT 测试路径覆盖

func appSupportOverrideTests() {
    let fm = FileManager.default
    let base = makeMigrationBase("override")
    defer { try? fm.removeItem(at: base) }
    check(AppSupportDirectory.overrideEnvironmentKey == "MATCHSTICKS_DRIVER_STATION_APPLICATION_SUPPORT",
          "路径覆盖 env 名为 MATCHSTICKS_DRIVER_STATION_APPLICATION_SUPPORT")
    let environment = [AppSupportDirectory.overrideEnvironmentKey: base.path]

    // 覆盖根下放入旧目录数据：验证 DSModel/WebUI/日志/抓包共用同一覆盖来源。
    let legacyLogs = base
        .appendingPathComponent(AppSupportDirectory.legacyName, isDirectory: true)
        .appendingPathComponent("Logs", isDirectory: true)
    makeMigrationDirectory(legacyLogs)
    try! Data("override-old-log".utf8).write(to: legacyLogs.appendingPathComponent("old.dslog"))

    check(AppSupportDirectory.applicationSupportBaseURL(environment: environment).path == base.path,
          "MATCHSTICKS_DRIVER_STATION_APPLICATION_SUPPORT 覆盖 Application Support 根")
    let resolved = AppSupportDirectory(environment: environment)
    check(resolved.waitForMigration(timeout: 10), "覆盖根场景迁移可等待完成")
    check(resolved.url.path == base.appendingPathComponent(AppSupportDirectory.name).path,
          "覆盖根下仍使用 MatchSticksDriverStation 新目录")
    let logs = resolved.subdirectory("Logs")
    let captures = resolved.subdirectory("captures")
    check(fm.fileExists(atPath: logs.appendingPathComponent("old.dslog").path),
          "覆盖根下的旧日志补齐到新目录")
    check(logs.path.hasPrefix(resolved.url.path), "WebUI/日志目录与覆盖根同源")
    check(captures.path.hasPrefix(resolved.url.path), "抓包目录与覆盖根同源")

    // 旧 alias 不生效：纯解析不触碰真实 Application Support
    let decoy = base.appendingPathComponent("legacy-alias-decoy", isDirectory: true)
    let interimOnly = ["MATCHSTICKS_DS_APPLICATION_SUPPORT": decoy.path]
    check(AppSupportDirectory.applicationSupportBaseURL(environment: interimOnly).path != decoy.path,
          "MATCHSTICKS_DS_APPLICATION_SUPPORT 不作为 alias")
    let oldOnly = ["GHDS_APPLICATION_SUPPORT": decoy.path]
    check(AppSupportDirectory.applicationSupportBaseURL(environment: oldOnly).path != decoy.path,
          "GHDS_APPLICATION_SUPPORT 不作为 alias")
    let bothOld = [
        "MATCHSTICKS_DS_APPLICATION_SUPPORT": decoy.path,
        "GHDS_APPLICATION_SUPPORT": decoy.path,
    ]
    check(AppSupportDirectory.applicationSupportBaseURL(environment: bothOld).path != decoy.path,
          "两级旧 alias 同时设置也不生效")
    let all = [
        AppSupportDirectory.overrideEnvironmentKey: base.path,
        "MATCHSTICKS_DS_APPLICATION_SUPPORT": decoy.path,
        "GHDS_APPLICATION_SUPPORT": decoy.path,
    ]
    check(AppSupportDirectory.applicationSupportBaseURL(environment: all).path == base.path,
          "三级并存时最新键优先")
}

// MARK: .dsrec：旧录制魔数 GHDSREC1 保持可回放

func legacyReplayCompatibilityTests() {
    check(PacketRecorder.magic == "GHDSREC1", "录制格式魔数保持 GHDSREC1（命名即契约）")

    var writer = ByteWriter()
    writer.f32be(0.25)
    writer.u8(RecordedDirection.responseIn.rawValue)
    let payload = Data([0xAA, 0xBB, 0xCC])
    writer.u32be(UInt32(payload.count))
    let legacy = Data("GHDSREC1".utf8) + writer.data + payload

    do {
        let source = try ReplaySource(data: legacy)
        check(source.records.count == 1, "旧魔数文件可解析")
        check(source.records.first?.direction == .responseIn, "旧录制方向字段兼容")
        check(source.records.first?.payload == payload, "旧录制载荷兼容")
        check(abs((source.records.first?.time ?? 0) - 0.25) < 0.0001, "旧录制时间戳兼容")
    } catch {
        check(false, "旧 GHDSREC1 录制应可读取（\(error)）")
    }

    check((try? ReplaySource(data: Data("MATCHSTICKS-DRIVER-STATION".utf8))) == nil, "其他魔数仍拒绝")
}
