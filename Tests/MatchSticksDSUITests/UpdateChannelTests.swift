import AppKit
import DSCore

// MARK: 更新渠道（stable / beta）行为测试（2026-11-23）
//
// 覆盖：枚举与 Sparkle allowedChannels 映射、设置键 matchsticks.updateChannel 即时落盘并
// 镜像旧 ghds.* 键、重启恢复、旧键迁移、损坏值回默认且不回退旧键、禁用持久化不落盘、
// 渠道变化钩子、设置页放置守卫与英文表。

@MainActor
func updateChannelTests(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void) {
    // ===== A. 枚举与 Sparkle 渠道映射 =====
    check(UpdateChannel.allCases.map(\.rawValue) == ["stable", "beta"],
          "update channels are stable and beta with stable raw values")
    check(UpdateChannel(rawValue: "beta") == .beta && UpdateChannel(rawValue: "stable") == .stable,
          "update channel raw values round-trip")
    check(UpdateChannel(rawValue: "Beta") == nil && UpdateChannel(rawValue: "") == nil && UpdateChannel(rawValue: "nightly") == nil,
          "unknown update channel values are rejected instead of guessed")
    // Sparkle 语义：默认渠道永远包含；beta 渠道 = 默认渠道 + beta
    check(UpdateChannel.stable.allowedSparkleChannels.isEmpty,
          "the stable channel only follows Sparkle's default channel")
    check(UpdateChannel.beta.allowedSparkleChannels == ["beta"],
          "the beta channel adds Sparkle's beta channel on top of the default channel")

    // ===== B. 持久化：即时落盘（新旧键）、重启恢复、变化钩子 =====
    let suiteNames = (0..<5).map { _ in "org.ghfrc.driverstation.test.uitests.updatechannel.\(UUID().uuidString)" }
    func makeSuite(_ name: String) -> UserDefaults { UserDefaults(suiteName: name)! }

    let suite = makeSuite(suiteNames[0])
    let model = DSModel(settingsDefaults: suite, persistenceEnabled: true)
    check(model.updateChannel == .stable, "update channel defaults to stable")
    check(suite.object(forKey: "matchsticks.updateChannel") == nil,
          "fresh install needs no explicit channel override")

    var changes: [UpdateChannel] = []
    model.onUpdateChannelChange = { changes.append($0) }
    model.updateChannel = .beta
    check(model.updateChannel == .beta, "channel updates in memory")
    check(suite.string(forKey: "matchsticks.updateChannel") == "beta",
          "channel persists immediately under the new key")
    check(suite.string(forKey: "ghds.updateChannel") == "beta",
          "channel mirrors the legacy key so a rollback still reads the latest choice")
    check(changes == [.beta], "a channel change notifies the updater hook exactly once")
    model.updateChannel = .beta
    check(changes == [.beta], "reassigning the same channel does not notify again")
    check(suite.string(forKey: "matchsticks.updateChannel") == "beta",
          "reassigning the same channel leaves the stored value alone")

    let restored = DSModel(settingsDefaults: suite, persistenceEnabled: true)
    restored.loadPersistedSettings()
    check(restored.updateChannel == .beta, "channel restores across restart")

    // 旧键迁移：仅 ghds.* 存在 → 读到 beta 并补写新键（SettingsStore 迁移规则）
    let legacySuite = makeSuite(suiteNames[1])
    legacySuite.set("beta", forKey: "ghds.updateChannel")
    let legacy = DSModel(settingsDefaults: legacySuite, persistenceEnabled: true)
    legacy.loadPersistedSettings()
    check(legacy.updateChannel == .beta, "legacy ghds.updateChannel migrates on restore")
    check(legacySuite.string(forKey: "matchsticks.updateChannel") == "beta",
          "legacy channel value is copied to the new key during migration")

    // 新键未知值 / 类型不符 → 回默认 stable，且不回退旧键（SettingsStore 规则）
    let corruptSuite = makeSuite(suiteNames[2])
    corruptSuite.set("beta", forKey: "ghds.updateChannel")
    for bad in ["nightly", "", "BETA"] {
        corruptSuite.set(bad, forKey: "matchsticks.updateChannel")
        let corrupt = DSModel(settingsDefaults: corruptSuite, persistenceEnabled: true)
        corrupt.loadPersistedSettings()
        check(corrupt.updateChannel == .stable,
              "unknown stored channel \(bad) keeps the stable default without falling back to the legacy key")
    }
    corruptSuite.set(true, forKey: "matchsticks.updateChannel")
    let typeCorrupt = DSModel(settingsDefaults: corruptSuite, persistenceEnabled: true)
    typeCorrupt.loadPersistedSettings()
    check(typeCorrupt.updateChannel == .stable, "non-string stored channel is ignored")

    // 禁用持久化（AUTO_SIM / 测试注入）：渠道与语言 / 外观同属偏好，didSet 写入不设门控，
    // 落在注入的（隔离）suite；仍可改内存
    let frozenSuite = makeSuite(suiteNames[3])
    let frozen = DSModel(settingsDefaults: frozenSuite, persistenceEnabled: false)
    frozen.updateChannel = .beta
    check(frozen.updateChannel == .beta, "channel still updates in memory when persistence is disabled")
    check(frozenSuite.string(forKey: "matchsticks.updateChannel") == "beta",
          "channel writes like language regardless of the persistence switch (isolated suite)")

    // AUTO_SIM 会话同样按上次选择恢复（与语言 / 外观同属门控前恢复）
    let autoSimSuite = makeSuite(suiteNames[4])
    autoSimSuite.set("beta", forKey: "matchsticks.updateChannel")
    let autoSim = DSModel(settingsDefaults: autoSimSuite, persistenceEnabled: false)
    autoSim.loadPersistedSettings()
    check(autoSim.updateChannel == .beta, "channel restores before the persistence gate like language and appearance")

    for name in suiteNames {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    }

    // ===== C. 设置页放置守卫：独立「软件更新」面板、即时绑定、英文表 =====
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let settingsSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/MatchSticksDS/Views/SettingsView.swift"), encoding: .utf8)) ?? ""
    let englishTable = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/DSCore/Resources/en.lproj/Localizable.strings"), encoding: .utf8)) ?? ""
    check(!settingsSource.isEmpty && !englishTable.isEmpty, "update channel placement test loads its source fixtures")
    check(settingsSource.contains("settingsGroup(tr(\"软件更新\"))"),
          "Settings has a dedicated Software Updates group")
    check(settingsSource.contains("DSSegmentedControl(title: tr(\"更新渠道\"), selection: $model.updateChannel, options: [") &&
          settingsSource.contains("DSSelectOption(value: UpdateChannel.stable, label: tr(\"稳定版\"))") &&
          settingsSource.contains("DSSelectOption(value: UpdateChannel.beta, label: tr(\"测试版\"))"),
          "the update channel is a Stable / Beta segmented control bound directly to the model")
    check(updateSourceOrder(["generalPanel", "updatePanel", "dashboardPanel"], in: settingsSource) &&
          !settingsSource.contains("private var iconPanel"),
          "the Software Updates panel sits after General's integrated App Icon cards, before Dashboard")
    check(settingsSource.contains("测试版会同时接收稳定版与测试版更新"),
          "the footnote explains that beta also receives stable updates")
    check(englishTable.contains("\"软件更新\" = \"Software Updates\";") &&
          englishTable.contains("\"更新渠道\" = \"Update Channel\";") &&
          englishTable.contains("\"稳定版\" = \"Stable\";") &&
          englishTable.contains("\"测试版\" = \"Beta\";"),
          "update channel labels have English translations")
}

/// 源码顺序守卫（各标记按给定先后出现；全部存在才算通过）。
private func updateSourceOrder(_ markers: [String], in text: String) -> Bool {
    var cursor = text.startIndex
    for marker in markers {
        guard let found = text.range(of: marker, range: cursor..<text.endIndex) else { return false }
        cursor = found.upperBound
    }
    return true
}
