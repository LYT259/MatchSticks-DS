import AppKit
import DSCore

// MARK: - 键盘快捷键（NI DS 语义；本阶段为应用前台监听，全局 CGEventTap 属 Phase 4 + Input Monitoring 权限）
//
// Space        = E-Stop
// Enter        = Disable
// [ + ] + \    = Enable（按住 [ 与 ] 再按 \）
// Esc + I      = E-Stop 复位（First DS 语义：按住 Esc 再按 I）
// F1           = 重扫手柄

@MainActor
final class ShortcutManager {
    private var model: DSModel?
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    private var pressedKeys = Set<UInt16>()
    private var escPressedAt: Date?

    private enum Codes {
        static let space: UInt16 = 49
        static let enter: UInt16 = 36
        static let bracketL: UInt16 = 33
        static let bracketR: UInt16 = 30
        static let backslash: UInt16 = 42
        static let esc: UInt16 = 53
        static let i: UInt16 = 34
        static let f1: UInt16 = 122
    }

    func install(model: DSModel) {
        self.model = model
        guard keyDownMonitor == nil else { return }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // 输入框聚焦时不拦截（队伍号 / Game Data 等字段）
            if Self.isTextInputFocused() {
                self.pressedKeys.insert(event.keyCode)
                return event
            }
            return self.handleKeyDown(event)
        }
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self else { return event }
            self.pressedKeys.remove(event.keyCode)
            if event.keyCode == Codes.esc { self.escPressedAt = nil }
            return event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let code = event.keyCode
        pressedKeys.insert(code)

        switch code {
        case Codes.space:
            model?.triggerEstop()
            return nil
        case Codes.enter:
            model?.setEnabled(false)
            return nil
        case Codes.backslash:
            if pressedKeys.contains(Codes.bracketL), pressedKeys.contains(Codes.bracketR) {
                model?.setEnabled(true)
                return nil
            }
        case Codes.i:
            // Esc 按住 ≥0（First DS 为长按 1s；此处按下即计，抬起清零，长按体验一致）
            if let at = escPressedAt, Date().timeIntervalSince(at) >= 0, pressedKeys.contains(Codes.esc) {
                model?.resetEstop()
                return nil
            }
        case Codes.esc:
            escPressedAt = Date()
        case Codes.f1:
            model?.rescanJoysticks()
            return nil
        default:
            break
        }
        return event
    }

    private static func isTextInputFocused() -> Bool {
        guard let firstResponder = NSApp.keyWindow?.firstResponder else { return false }
        return firstResponder is NSTextView || firstResponder is NSTextField
    }
}
