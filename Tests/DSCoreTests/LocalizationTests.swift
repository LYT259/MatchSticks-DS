// MARK: 中英双语（Localization.swift / WebUIServer ?lang=）行为测试
//
// 覆盖：system 模式语言解析与回退、手动覆盖立即生效、en 表真实加载（Bundle.module 资源链路）、
// 格式键与 %% 字面百分号、未命中回退中文键、WebUI 首页双语与 ?lang= 覆盖。

import Foundation
import DSCore

func languageResolveTests() {
    check(LanguageManager.resolve(mode: .chinese, preferred: ["ja-JP"]) == .chinese, "手动中文优先于系统语言")
    check(LanguageManager.resolve(mode: .english, preferred: ["zh-Hans-CN"]) == .english, "手动英文优先于系统语言")
    check(LanguageManager.resolve(mode: .system, preferred: ["zh-Hans-CN", "en-US"]) == .chinese, "system: zh-Hans → 中文")
    check(LanguageManager.resolve(mode: .system, preferred: ["zh-Hant-TW"]) == .chinese, "system: zh-Hant → 中文")
    check(LanguageManager.resolve(mode: .system, preferred: ["en-US"]) == .english, "system: en → 英文")
    check(LanguageManager.resolve(mode: .system, preferred: ["ja-JP"]) == .english, "system: 其他语言回退英文")
    check(LanguageManager.resolve(mode: .system, preferred: []) == .english, "system: 空列表回退英文")
}

func languageManagerTests() {
    let m = LanguageManager()
    check(m.mode == .system, "初始跟随系统")
    m.setMode(.english)
    check(m.currentEffective == .english && m.effective == .english, "切英文立即生效（快照与发布值同步）")
    m.setMode(.english) // 幂等
    check(m.effective == .english, "重复设置幂等")
    m.setMode(.chinese)
    check(m.effective == .chinese, "切回中文立即生效")
}

/// 经 shared 实例走完整链路（含 Bundle.module en 表加载——资源未进 bundle 时此处失败）
func enTableTests() {
    LanguageManager.shared.setMode(.english)
    defer { LanguageManager.shared.setMode(.system) }
    check(tr("使能") == "Enable", "en 表基本键")
    check(tr("急停已锁定") == "E-Stop Latched", "en 表状态键（FRC 术语）")
    check(tr("槽位 %d", 3) == "Slot 3", "en 表格式键 %d")
    check(tr("已使能 · %@", "Teleoperated") == "Enabled · Teleoperated", "en 表格式键 %@")
    check(tr("不存在键＿本地化测试") == "不存在键＿本地化测试", "未命中回退中文键")
    check(tr("正在后台下载新版本 %d%%（低优先级，可忽略，不影响使用）", 50).contains("50%"), "%% 字面百分号展开")
    check(tr("控制环吞吐：%.1f Hz（tx=%d rx=%d loss=%.1f%%）", 49.95, 100, 99, 1.0).hasPrefix("Control loop throughput: 50.0 Hz"), "多参数格式键")
    check(tr("尚未连接机器人") == "Not Connected to Robot", "诊断页未连接空状态使用英文")
    check(tr("机器人输出") == "Robot Output", "动态 tr(rawValue) 来源名称：机器人输出")
    check(tr("错误与警告") == "Errors & Warnings", "动态 tr(rawValue) 来源名称：错误与警告")
    check(tr("应用事件") == "App Events", "动态 tr(rawValue) 来源名称：应用事件")
    if case .deny(let reason) = SafetyGate.evaluateEnable(.init(commConnected: false)) {
        check(reason == "No Robot Connection", "无连接时的使能拒绝原因使用英文")
    } else {
        check(false, "无连接时必须拒绝使能")
    }
}

func localizationSourceCoverageTests() {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sources = root.appendingPathComponent("Sources")
    let tableURL = root.appendingPathComponent(
        "Sources/DSCore/Resources/en.lproj/Localizable.strings"
    )
    guard let table = try? String(contentsOf: tableURL, encoding: .utf8) else {
        check(false, "英文资源表必须可读取")
        return
    }

    let entryPattern = #"^\s*"((?:\\.|[^"\\])*)"\s*="#
    let callPattern = #"\btr\(\s*"((?:\\.|[^"\\])*)""#
    let entryRegex = try! NSRegularExpression(
        pattern: entryPattern, options: [.anchorsMatchLines]
    )
    let callRegex = try! NSRegularExpression(pattern: callPattern)
    let tableRange = NSRange(table.startIndex..., in: table)
    let englishKeys = Set(entryRegex.matches(in: table, range: tableRange).map {
        String(table[Range($0.range(at: 1), in: table)!])
    })

    var missing: [String] = []
    let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
    for case let file as URL in files! where file.pathExtension == "swift" {
        guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
        let sourceRange = NSRange(source.startIndex..., in: source)
        for match in callRegex.matches(in: source, range: sourceRange) {
            let matchRange = Range(match.range, in: source)!
            let lineStart = source[..<matchRange.lowerBound].lastIndex(of: "\n")
                .map { source.index(after: $0) } ?? source.startIndex
            guard !source[lineStart..<matchRange.lowerBound].contains("//") else { continue }
            let key = String(source[Range(match.range(at: 1), in: source)!])
            if !englishKeys.contains(key) {
                missing.append("\(file.lastPathComponent): \(key)")
            }
        }
    }
    check(missing.isEmpty, "所有 tr 字面键均有英文翻译；缺失：\(missing)")
}

func webuiLanguageTests() {
    check(WebUIServer.indexHTML(language: .chinese).contains("本机调试与支持页"), "首页中文版文案")
    check(WebUIServer.indexHTML(language: .english).contains("Local debugging and support page"), "首页英文版文案")
    check(WebUIServer.queryLanguageOverride(["lang": "en"]) == .english, "?lang=en → 英文")
    check(WebUIServer.queryLanguageOverride(["lang": "ZH"]) == .chinese, "?lang=ZH 大小写不敏感")
    check(WebUIServer.queryLanguageOverride(["lang": "xx"]) == nil, "非法 lang 回落 App 当前语言")
    check(WebUIServer.queryLanguageOverride([:]) == nil, "缺省 lang 回落 App 当前语言")

    let (env, dir) = makeWebUITempEnv()
    defer { try? FileManager.default.removeItem(at: dir) }
    let en = WebUIServer.route(method: "GET", target: "/index.html?lang=en", body: Data(), env: env)
    check(String(data: en.body, encoding: .utf8)?.contains("Local debugging and support page") == true, "route ?lang=en 返回英文首页")
    let zh = WebUIServer.route(method: "GET", target: "/?lang=zh", body: Data(), env: env)
    check(String(data: zh.body, encoding: .utf8)?.contains("本机调试与支持页") == true, "route ?lang=zh 返回中文首页")
}
