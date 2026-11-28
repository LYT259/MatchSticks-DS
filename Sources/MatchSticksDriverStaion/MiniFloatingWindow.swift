import SwiftUI

@MainActor
enum MiniFloatingWindow {
    static func bottomFrame(for screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let width = min(1280, max(1, visible.width - 32))
        let height = min(200, visible.height)
        return NSRect(x: visible.midX - width / 2,
                      y: visible.minY,
                      width: width,
                      height: height)
    }

    static func configure(_ window: NSWindow, on screen: NSScreen?) {
        guard let screen else { return }
        window.level = .floating
        window.hidesOnDeactivate = false
        var behavior = window.collectionBehavior
        behavior.insert(.canJoinAllSpaces)
        behavior.insert(.fullScreenAuxiliary)
        behavior.remove(.moveToActiveSpace)
        window.collectionBehavior = behavior
        window.styleMask.remove(.resizable)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.isMovable = false
        let target = bottomFrame(for: screen)
        if window.frame != target {
            window.setFrame(target, display: true, animate: false)
        }
    }
}

struct MiniFloatingWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> HostView {
        HostView(frame: .zero)
    }

    func updateNSView(_ view: HostView, context: Context) {}

    final class HostView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyConfiguration()
            observeWindow()
            DispatchQueue.main.async { [weak self] in
                self?.applyConfiguration()
            }
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            applyConfiguration()
        }

        private func applyConfiguration() {
            guard let window else { return }
            MiniFloatingWindow.configure(window, on: window.screen ?? NSScreen.main)
        }

        private func observeWindow() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let notifications: [Notification.Name] = [
                NSWindow.didChangeScreenNotification,
                NSWindow.didMoveNotification,
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
            ]
            observers = notifications.map { name in
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.applyConfiguration()
                    }
                }
            }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
