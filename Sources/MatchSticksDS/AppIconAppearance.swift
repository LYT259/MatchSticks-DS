import AppKit
import DSCore

// MARK: - 应用图标运行时外观（样式 × 外观两维偏好，参考 PathBlender app-icon.ts / dock-icon.ts）
//
// 语义：设置页提供互相独立的「图标样式」（彩色 / 单色）与「图标外观」（跟随系统 / 固定浅色 /
// 固定深色），经 DSModel 的 didSet 即时生效并落独立设置键（appIconStyle / appIconAppearance），
// 与界面主题（appearanceMode → NSApp.appearance）互不影响。运行时把两维解析为四张白名单
// Bundle.module 图稿之一，显式推给 NSApplication.shared.applicationIconImage。
//
// 「跟随系统」的真实系统深浅来源（2026-11-23 本机活体切换实证，全部公开 API）：
// - 触发：DistributedNotificationCenter 的 AppleInterfaceThemeChangedNotification——系统每次
//   浅/深切换逐条投递，通知本身不带方向信息，由读侧解析新值；
// - 读值：全局 AppleInterfaceStyle（NSGlobalDomain）。进程内 CFPreferences 缓存不随外部变化
//   刷新（实测切换后 0.5s 仍返回旧值、CFPreferencesAppSynchronize 不失效缓存），plist 文件
//   落盘更慢；persistentDomain(forName:) 每次回 cfprefsd 取值，实测通知到达瞬间即新值——
//   只能用它。键缺失 = 浅色（macOS 浅色模式不写该键）。
// NSApp.effectiveAppearance 不能当「系统」来源：界面外观固定（NSApp.appearance 覆盖）时它
// 跟随覆盖值、系统切换也不再改变它，会把图标跟随系统误绑到界面主题上。
// Finder / 启动台图标由应用包内的 icon catalog 随系统渲染；运行时固定选择只影响 Dock。

/// 图标样式（彩色 / 单色）：两维图标偏好之一；另一维是图标外观（复用 AppearanceMode）。
enum IconStyle: String, CaseIterable, Sendable {
    case color = "color"
    case monochrome = "monochrome"
}

/// 四张白名单图稿（Bundle.module 文件名，不含扩展名）。
/// 资源只能来自这四个文件：加载入口只接受 style/dark 组合或清单内文件名，
/// 不存在接受任意路径的入口（清单外的名字在访问文件系统之前即被拒绝）。
enum AppIconArtwork {
    static let whitelist: Set<String> = [
        "app-icon-day", "app-icon-night", "app-icon-mono-day", "app-icon-mono-night",
    ]

    /// 已加载图稿缓存：键 = bundle 路径 + 文件名（不同 bundle 互不串味）。设置页卡片
    /// body 每次求值都取图稿，命中即返回同一 NSImage，不再重读 1024 PNG；缺失（nil）
    /// 不入缓存。NSCache 自身线程安全，任意线程并发加载共享同一份缓存。
    private static let loadedImages = NSCache<NSString, NSImage>()

    /// 样式 × 深浅 → 图稿文件名。
    static func fileName(style: IconStyle, dark: Bool) -> String {
        switch (style, dark) {
        case (.color, false): return "app-icon-day"
        case (.color, true): return "app-icon-night"
        case (.monochrome, false): return "app-icon-mono-day"
        case (.monochrome, true): return "app-icon-mono-night"
        }
    }

    /// 按白名单文件名加载（清单外一律 nil；不接受的路径形态同样被清单拒绝）。
    /// 白名单在缓存与文件系统之前拒绝；命中缓存返回同一实例，未命中才读盘一次。
    static func image(fileName: String, bundle: Bundle = .module) -> NSImage? {
        guard whitelist.contains(fileName),
              let url = bundle.url(forResource: fileName, withExtension: "png") else { return nil }
        let key = "\(bundle.bundlePath)|\(fileName)" as NSString
        if let cached = loadedImages.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        loadedImages.setObject(image, forKey: key)
        return image
    }

    /// 按样式 × 深浅加载白名单图稿。
    static func image(style: IconStyle, dark: Bool, bundle: Bundle = .module) -> NSImage? {
        image(fileName: fileName(style: style, dark: dark), bundle: bundle)
    }
}

/// 运行时图标中心：解析两维偏好，向 Dock 与侧栏品牌区提供同一份图稿。
/// artworkLoader / systemDarkProvider / applier 可注入（UI 干测试不触碰真实 Dock 与
/// 真实系统外观；图稿缺失时静默 no-op，绝不把图标置空）。
@Observable
@MainActor
final class AppIconCenter {
    /// 系统深浅切换的分布式通知名（Apple 惯用名，非 AppKit API；机制见文件头注释）。
    static let systemAppearanceChangedNotificationName = "AppleInterfaceThemeChangedNotification"

    /// 真实系统是否深色：读全局 AppleInterfaceStyle（免缓存路径见文件头注释；
    /// 键缺失 = 浅色，只认 "Dark"）。与 NSApp.appearance 覆盖无关。
    static func systemPrefersDark() -> Bool {
        let style = UserDefaults.standard
            .persistentDomain(forName: "NSGlobalDomain")?["AppleInterfaceStyle"] as? String
        return style?.caseInsensitiveCompare("Dark") == .orderedSame
    }

    private(set) var pushedFileNames: [String] = []
    private(set) var artwork: NSImage?

    var style: IconStyle = .color
    var mode: AppearanceMode = .system

    @ObservationIgnored var artworkLoader: (String) -> NSImage? = { AppIconArtwork.image(fileName: $0) }
    @ObservationIgnored var systemDarkProvider: () -> Bool = { AppIconCenter.systemPrefersDark() }
    @ObservationIgnored var applier: (NSImage) -> Void = { NSApplication.shared.applicationIconImage = $0 }

    @ObservationIgnored private var distributedObserver: NSObjectProtocol?

    /// 偏好变化入口（设置页 didSet / 启动恢复后各调一次）：更新两维并立即重推。
    func update(style: IconStyle, mode: AppearanceMode) {
        self.style = style
        self.mode = mode
        reapply()
    }

    /// 解析当前两维偏好（跟随系统读 systemDarkProvider）并显式推送图稿。
    func reapply() {
        let dark = mode == .system ? systemDarkProvider() : mode == .dark
        let name = AppIconArtwork.fileName(style: style, dark: dark)
        guard let image = artworkLoader(name) else { return }
        pushedFileNames.append(name)
        artwork = image
        applier(image)
    }

    /// 监听真实系统深浅切换（分布式通知）：仅跟随系统模式重推；固定浅色/深色不受影响。
    /// 重复调用不重复注册。
    func startObservingSystemAppearance() {
        guard distributedObserver == nil else { return }
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(Self.systemAppearanceChangedNotificationName),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemAppearanceChanged()
            }
        }
    }

    /// 停止观察并清理全部 observer。
    func stopObservingSystemAppearance() {
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
        }
        distributedObserver = nil
    }

    private func systemAppearanceChanged() {
        guard mode == .system else { return }
        reapply()
    }

    deinit {
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
        }
    }
}
