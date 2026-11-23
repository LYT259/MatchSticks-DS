import AppKit
import SwiftUI
import DSCore

@main
struct GitHubStarButtonTests {
    // 可访问名称与帮助文案的查找键（中文即键），须与 GitHubStarButton 里的 tr() 字面键一致。
    static let nameKey = "在 GitHub 上给 MatchSticks DS 点 Star"
    static let helpKey = "在默认浏览器中打开 MatchSticks DS 的 GitHub 仓库页面"

    @MainActor
    static func main() {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            checks += 1
            if !condition() { failures.append(name) }
        }

        let expectedURL = URL(string: "https://github.com/LYT259/MatchSticks-DS")!
        check(GitHubStarButton.repositoryURL == expectedURL &&
              GitHubStarButton.repositoryURL.absoluteString == "https://github.com/LYT259/MatchSticks-DS",
              "repository URL is exact")

        NSApplication.shared.finishLaunching()
        NSApplication.shared.setActivationPolicy(.accessory)
        enableEnhancedUserInterface()
        var openedURLs: [URL] = []
        let host = NSHostingView(rootView: GitHubStarButton { openedURLs.append($0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 50),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 120, height: 50)
        window.orderFront(nil)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        check(openedURLs.isEmpty, "rendering the button does not open the browser")

        let node = firstAccessibilityNode(role: NSAccessibility.Role.button.rawValue, in: host)
        check(node != nil, "the star control is exposed as a native accessibility button")
        let name = node.flatMap { axAttribute($0, "accessibilityLabel") as? String } ?? ""
        let help = node.flatMap { axAttribute($0, "accessibilityHelp") as? String } ?? ""
        check(name.contains("GitHub") && name.contains("MatchSticks DS"),
              "the button has an explicit native accessible name naming the repository (got: \"\(name)\")")
        check(help.contains("GitHub") && (help.contains("浏览器") || help.lowercased().contains("browser")),
              "the button has help text saying it opens the repository in the browser (got: \"\(help)\")")
        check(node.flatMap { axAttribute($0, "accessibilityValue") } == nil,
              "the control is a plain link, not a toggle showing star state")

        let point = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
        let timestamp = ProcessInfo.processInfo.systemUptime
        if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                        timestamp: timestamp, windowNumber: window.windowNumber,
                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
           let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                       timestamp: timestamp, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 1, clickCount: 1, pressure: 0) {
            window.makeKey()
            NSApp.postEvent(up, atStart: true)
            NSApp.sendEvent(down)
            if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(),
                                              inMode: .default, dequeue: true) {
                NSApp.sendEvent(pending)
            }
        } else {
            check(false, "star-button test mouse events are created")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        check(openedURLs == [expectedURL],
              "one click opens the exact repository URL through the injected opener exactly once")

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/MatchSticksDS/Views/GitHubStarButton.swift"), encoding: .utf8)) ?? ""
        let appSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/MatchSticksDS/MatchSticksDSApp.swift"), encoding: .utf8)) ?? ""
        let englishTable = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/DSCore/Resources/en.lproj/Localizable.strings"), encoding: .utf8)) ?? ""
        let starScript = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
            "scripts/test-star-link.sh"), encoding: .utf8)) ?? ""

        check(!viewSource.isEmpty && !appSource.isEmpty && !englishTable.isEmpty && !starScript.isEmpty,
              "star-button source fixtures load")
        check(viewSource.contains("NSWorkspace.shared.open"),
              "the default opener delegates to the system browser")
        check(viewSource.contains("tr(\"\(nameKey)\")") && viewSource.contains("tr(\"\(helpKey)\")"),
              "the accessible name and help text are localized through tr()")
        check(englishTable.contains("\"\(nameKey)\" = ") && englishTable.contains("\"\(helpKey)\" = "),
              "the accessible name and help text have English translations in the en table")
        check(!viewSource.contains("URLSession") && !viewSource.contains("WKWebView") &&
              !viewSource.contains("telemetry") && !viewSource.contains("analytics"),
              "the star link has no remote status, web view, or analytics path")
        check(!viewSource.contains("UserDefaults") && !viewSource.contains("SettingsStore") &&
              !viewSource.contains("isLoggedIn") && !viewSource.contains("starCount") &&
              !viewSource.contains("api.github.com") && !viewSource.contains("GITHUB_TOKEN"),
              "the star link reads no login state, star count, or GitHub API")
        check(!viewSource.contains(".primaryAction"),
              "the star toolbar comment follows beta's confirmationAction placement")
        check(starScript.contains("Sources/MatchSticksDS/LocalNetworkDiscovery.swift"),
              "the standalone Star build compiles beta's LocalNetworkDiscovery source")
        check(starScript.contains("Sources/MatchSticksDS/UpdateChannel.swift"),
              "the standalone Star build includes auto-update's UpdateChannel source when integrated")
        check(sourceOrder([
            "ToolbarItem(placement: .confirmationAction)",
            "windowFlow.send(.miniEntryTapped)",
            "UpdateBadge(flow: updates.flow)",
            "GitHubStarButton()"
        ], in: appSource), "star button remains inside beta's toolbar beside the window-flow mini view and updates")
        check(appSource.contains("UpdateBadge(flow: updates.flow) { updates.requestRestartAndRelaunch() }"),
              "the update badge tap action is unchanged")
        check(appSource.components(separatedBy: "GitHubStarButton()").count == 2,
              "the main toolbar contains exactly one GitHub Star button")

        window.close()
        print("GitHub Star: \(checks) checks, \(failures.count) failures")
        for failure in failures { print("FAIL: \(failure)") }
        exit(failures.isEmpty ? 0 : 1)
    }

    /// SwiftUI 的辅助功能树仅在辅助技术接入后才构建；VoiceOver 接入时设置的正是 AXEnhancedUserInterface。
    /// 该写入接口自 10.10 起标记弃用，但仍是进程内设置此属性的唯一途径；按 selector 调用，只影响本测试进程。
    private static func enableEnhancedUserInterface() {
        let selector = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        guard NSApp.responds(to: selector) else { return }
        _ = NSApp.perform(selector, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
    }

    /// SwiftUI 的 AccessibilityNode 以 ObjC 非正式协议响应 AX getter（Swift 侧不可 as? 转换），故按 selector 动态读取。
    private static func axAttribute(_ element: AnyObject, _ getter: String) -> Any? {
        let selector = NSSelectorFromString(getter)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }

    private static func firstAccessibilityNode(role: String, in object: Any, depth: Int = 0) -> AnyObject? {
        guard depth < 10 else { return nil }
        let element = object as AnyObject
        if axAttribute(element, "accessibilityRole") as? String == role { return element }
        for child in axAttribute(element, "accessibilityChildren") as? [Any] ?? [] {
            if let found = firstAccessibilityNode(role: role, in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private static func sourceOrder(_ markers: [String], in text: String) -> Bool {
        var cursor = text.startIndex
        for marker in markers {
            guard let found = text.range(of: marker, range: cursor..<text.endIndex) else { return false }
            cursor = found.upperBound
        }
        return true
    }
}
