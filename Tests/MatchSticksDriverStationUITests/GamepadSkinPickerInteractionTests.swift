import AppKit
import SwiftUI
import Vision
import DSCore

private final class GamepadSelectionBox {
    var value: GamepadSkin?
}

@MainActor
func gamepadSkinPickerInteractionTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    NSApplication.shared.finishLaunching()
    let previousPolicy = NSApplication.shared.activationPolicy()
    NSApplication.shared.setActivationPolicy(.accessory)
    defer { NSApplication.shared.setActivationPolicy(previousPolicy) }

    func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }
    func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    func searchField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        return descendants(view).compactMap { $0 as? NSTextField }.first(where: { $0.isEditable })
    }
    func visiblePopover(excluding window: NSWindow) -> NSWindow? {
        NSApp.windows.first { $0 !== window && $0.isVisible && searchField(in: $0.contentView) != nil }
    }
    var captureCount = 0
    func textLabels(in window: NSWindow) -> [String] {
        guard let content = window.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return [] }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        captureCount += 1
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: ".build/review/picker-ocr-\(captureCount).png"))
        }
        guard let image = bitmap.cgImage,
              let scaledContext = CGContext(data: nil, width: image.width * 2, height: image.height * 2,
                                            bitsPerComponent: 8, bytesPerRow: image.width * 8,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        scaledContext.interpolationQuality = .high
        scaledContext.draw(image, in: CGRect(x: 0, y: 0, width: image.width * 2, height: image.height * 2))
        guard let scaledImage = scaledContext.makeImage() else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        if let supported = try? request.supportedRecognitionLanguages() {
            let languages = ["zh-Hans", "en-US"].filter { supported.contains($0) }
            if !languages.isEmpty { request.recognitionLanguages = languages }
        }
        guard let _ = try? VNImageRequestHandler(cgImage: scaledImage, options: [:]).perform([request]),
              let observations = request.results else { return [] }
        return observations.compactMap { $0.topCandidates(1).first?.string }
    }
    func click(_ point: CGPoint, in window: NSWindow) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                            timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                          timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 1, clickCount: 1, pressure: 0) else { return }
        window.makeKey()
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(pending)
        }
        settle()
    }
    func setQuery(_ query: String, in window: NSWindow) {
        guard let field = searchField(in: window.contentView) else { return }
        field.selectText(nil)
        window.makeKey()
        for character in query {
            let text = String(character)
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              characters: text, charactersIgnoringModifiers: text,
                                              isARepeat: false, keyCode: 0) else { continue }
            NSApp.sendEvent(event)
        }
        settle()
    }
    func key(_ code: UInt16, _ characters: String, in window: NSWindow) {
        let modifiers: NSEvent.ModifierFlags = [115, 119, 123, 124, 125, 126].contains(code) ? [.function] : []
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          characters: characters, charactersIgnoringModifiers: characters,
                                          isARepeat: false, keyCode: code) else { return }
        window.makeKey()
        NSApp.postEvent(event, atStart: false)
        if let pending = NSApp.nextEvent(matching: .keyDown, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(pending)
        }
        settle()
    }

    let selection = GamepadSelectionBox()
    let options = [DSSelectOption<GamepadSkin?>(value: nil, label: "Auto-Detect (current: PS5 DualSense)")] +
        GamepadSkin.selectableSkins.map { DSSelectOption(value: Optional($0), label: $0.displayName) }
    let control = DSSelectControl<GamepadSkin?>(
        title: "Gamepad Layout",
        selection: Binding(get: { selection.value }, set: { selection.value = $0 }),
        options: options,
        searchText: { $0?.searchableText ?? "Auto Detect" })
    let host = NSHostingView(rootView: control)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 80),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = CGRect(x: 0, y: 0, width: 320, height: 80)
    host.autoresizingMask = [.width, .height]
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    settle()
    defer {
        visiblePopover(excluding: window)?.close()
        window.close()
    }

    click(CGPoint(x: host.bounds.midX, y: host.bounds.midY), in: window)
    guard let popover = visiblePopover(excluding: window), let field = searchField(in: popover.contentView) else {
        check(false, "打开手柄选择器出现原生搜索框")
        return
    }
    check(field.currentEditor() != nil, "打开后搜索框自动获得编辑焦点")
    setQuery("PS4", in: popover)
    let filtered = textLabels(in: popover)
    check(filtered.contains("PS4 DualShock 4") && !filtered.contains("PS5 DualSense"),
          "实际弹窗输入 PS4 只显示对应型号")
    key(53, "\u{1b}", in: popover)
    check(visiblePopover(excluding: window) == nil, "Escape 关闭搜索弹窗")

    click(CGPoint(x: host.bounds.midX, y: host.bounds.midY), in: window)
    guard let reopened = visiblePopover(excluding: window), let reopenedField = searchField(in: reopened.contentView) else {
        check(false, "选择器可重新打开并恢复搜索框")
        return
    }
    check(reopenedField.stringValue.isEmpty, "关闭后重新打开不残留旧搜索")
    setQuery("PS", in: reopened)
    key(119, "\u{F72F}", in: reopened)
    key(36, "\r", in: reopened)
    check(selection.value == .dualsense, "End 后 Enter 选择最后一项 PS5")
    check(visiblePopover(excluding: window) == nil, "键盘选择后弹窗关闭")

    click(CGPoint(x: host.bounds.midX, y: host.bounds.midY), in: window)
    guard let keyboardPopover = visiblePopover(excluding: window) else {
        check(false, "键盘操作前可重新打开选择器")
        return
    }
    setQuery("PS", in: keyboardPopover)
    key(115, "\u{F729}", in: keyboardPopover)
    key(125, "\u{F701}", in: keyboardPopover)
    key(126, "\u{F700}", in: keyboardPopover)
    key(36, "\r", in: keyboardPopover)
    check(selection.value == .dualshock4, "Home、下、上、Enter 按真实顺序选择 PS4")

    click(CGPoint(x: host.bounds.midX, y: host.bounds.midY), in: window)
    guard let emptyPopover = visiblePopover(excluding: window) else {
        check(false, "空结果测试前可重新打开选择器")
        return
    }
    setQuery("no-such-gamepad", in: emptyPopover)
    check(textLabels(in: emptyPopover).contains(tr("没有匹配的手柄")), "实际弹窗显示无结果提示")
    guard let clearField = searchField(in: emptyPopover.contentView), let content = emptyPopover.contentView else {
        check(false, "清空前搜索框存在")
        return
    }
    let fieldRect = clearField.convert(clearField.bounds, to: content)
    let clearPoint = CGPoint(x: fieldRect.maxX + 16, y: fieldRect.midY)
    click(content.convert(clearPoint, to: nil), in: emptyPopover)
    check(clearField.stringValue.isEmpty && textLabels(in: emptyPopover).contains(GamepadSkin.generic.displayName),
          "清空按钮恢复完整手柄列表")
    check(clearField.currentEditor() != nil, "清空后仍可继续在搜索框输入")
    key(53, "\u{1b}", in: emptyPopover)
    check(visiblePopover(excluding: window) == nil, "完成搜索后 Escape 正常关闭")
}
