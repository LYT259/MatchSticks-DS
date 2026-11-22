import AppKit
import SwiftUI

// MARK: - 主窗口标题栏双击
//
// hiddenTitleBar 让 SwiftUI 内容铺满整窗，系统自带的「双击标题栏缩放」不再命中。
// 这里用本地 leftMouseUp 监视器补回 AppKit 的 Zoom / Minimize，跟随系统偏好
// AppleActionOnDoubleClick。只在空白标题栏上处理第二次松键：不吞第二次
// mouseDown，内容视图收到的 mouseUp 因此不会出现落点漂移。

/// 双击门控的纯输入：只有空白标题栏上的第二次松键才放行。
struct MainWindowDoubleClickGate: Equatable {
    let clickCount: Int
    let isHostWindow: Bool
    let isFullScreen: Bool
    let isAboveContentLayoutMaxY: Bool
    let isInteractiveControl: Bool
    let hasAttachedSheet: Bool

    var allowsDoubleClick: Bool {
        clickCount == 2
            && isHostWindow
            && !isFullScreen
            && isAboveContentLayoutMaxY
            && !isInteractiveControl
            && !hasAttachedSheet
    }
}

/// 双击标题栏的动作分派（纯解析，便于回归测试）。
enum MainWindowDoubleClickAction: Equatable {
    case zoom
    case minimize
    case none
    /// 系统 Fill 没有公开的等价 API；用公开 performZoom 作为明确回退，
    /// 不声称与私有原生 Fill 完全等价。
    case fillFallbackZoom

    static func resolve(_ rawValue: String?) -> MainWindowDoubleClickAction {
        switch rawValue {
        case "Minimize": return .minimize
        case "None": return .none
        case "Fill": return .fillFallbackZoom
        case "Maximize", "Zoom": return .zoom
        case nil: return .zoom
        default: return .none
        }
    }

    static func current(defaults: UserDefaults = .standard) -> MainWindowDoubleClickAction {
        resolve(defaults.string(forKey: "AppleActionOnDoubleClick"))
    }
}

/// 挂在 RootView（仅主窗口）上的零尺寸探针：随窗口挂载/移除本地事件监视器。
struct MainWindowDoubleClickHandler: NSViewRepresentable {
    func makeNSView(context: Context) -> MainWindowDoubleClickView {
        MainWindowDoubleClickView()
    }

    func updateNSView(_ nsView: MainWindowDoubleClickView, context: Context) {}
}

final class MainWindowDoubleClickView: NSView {
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window else { return event }
        let gate = MainWindowDoubleClickGate(
            clickCount: event.clickCount,
            isHostWindow: event.window === window,
            isFullScreen: window.styleMask.contains(.fullScreen),
            isAboveContentLayoutMaxY: event.locationInWindow.y >= window.contentLayoutRect.maxY,
            isInteractiveControl: hasInteractiveControl(at: event.locationInWindow, in: window),
            hasAttachedSheet: window.attachedSheet != nil
        )
        guard gate.allowsDoubleClick else { return event }

        switch MainWindowDoubleClickAction.current() {
        case .zoom, .fillFallbackZoom:
            window.performZoom(nil)
            return nil
        case .minimize:
            window.performMiniaturize(nil)
            return nil
        case .none:
            return event
        }
    }

    /// 排除标题栏/工具栏上的已知控件：标准窗口按钮、toolbar items（含 group
    /// subitems）的视图，以及 theme/content 父视图 hitTest 命中的 NSControl
    /// 祖先（覆盖窗口共享等系统控件）。全部用 view 坐标与 bounds 判断。
    private func hasInteractiveControl(at locationInWindow: NSPoint, in window: NSWindow) -> Bool {
        for view in knownControlViews(in: window) {
            guard view.window === window else { continue }
            if view.bounds.contains(view.convert(locationInWindow, from: nil)) { return true }
        }

        guard let root = window.contentView?.superview ?? window.contentView else { return false }
        let point = root.convert(locationInWindow, from: nil)
        var hit = root.hitTest(point)
        while let view = hit {
            if view is NSControl { return true }
            if view === root { break }
            hit = view.superview
        }
        return false
    }

    private func knownControlViews(in window: NSWindow) -> [NSView] {
        let buttonTypes: [NSWindow.ButtonType] = [
            .closeButton, .miniaturizeButton, .zoomButton,
            .toolbarButton, .documentIconButton, .documentVersionsButton,
        ]
        var views: [NSView] = buttonTypes.compactMap { window.standardWindowButton($0) }
        if let toolbar = window.toolbar {
            appendToolbarItemViews(toolbar.items, to: &views)
        }
        return views
    }

    private func appendToolbarItemViews(_ items: [NSToolbarItem], to views: inout [NSView]) {
        for item in items {
            if let view = item.view { views.append(view) }
            if let group = item as? NSToolbarItemGroup {
                appendToolbarItemViews(group.subitems, to: &views)
            }
        }
    }
}
