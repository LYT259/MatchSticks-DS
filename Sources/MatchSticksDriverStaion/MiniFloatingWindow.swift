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
        window.setFrame(bottomFrame(for: screen), display: true, animate: false)
    }
}

struct MiniFloatingWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> HostView {
        HostView(frame: .zero)
    }

    func updateNSView(_ view: HostView, context: Context) {}

    final class HostView: NSView {
        private var screenObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyConfiguration()
            observeWindowScreen()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            applyConfiguration()
        }

        private func applyConfiguration() {
            guard let window else { return }
            MiniFloatingWindow.configure(window, on: window.screen ?? NSScreen.main)
        }

        private func observeWindowScreen() {
            if let screenObserver {
                NotificationCenter.default.removeObserver(screenObserver)
                self.screenObserver = nil
            }
            guard let window else { return }
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applyConfiguration()
                }
            }
        }

        deinit {
            if let screenObserver {
                NotificationCenter.default.removeObserver(screenObserver)
            }
        }
    }
}
