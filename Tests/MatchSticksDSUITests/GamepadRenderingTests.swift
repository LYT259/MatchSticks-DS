import AppKit
import SwiftUI
import SceneKit
import DSCore

@MainActor
func gamepadRenderingTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let overlay = (try? String(contentsOf: root.appendingPathComponent(
        "Sources/MatchSticksDS/Views/GamepadArtwork/GamepadArtworkOverlay.swift"), encoding: .utf8)) ?? ""
    check(overlay.contains("ThumbstickScene("), "正式手柄界面使用三维摇杆组件")
    check(!overlay.contains("NativeStickCap") && !overlay.contains("stickCapOffset"),
          "正式手柄界面不再平移裁剪摇杆图")

    for skin in [GamepadSkin.f310, .direwolf4, .dualshock4, .dualsense, .xboxSeries] {
        let spec = GamepadArtworkCatalog.spec(for: skin)
        guard let source = NSImage(contentsOf: root.appendingPathComponent(
            "Sources/MatchSticksDS/Resources/Gamepads/\(spec.imageName).png")) else {
            check(false, "\(skin.rawValue) 合成渲染资源可读取")
            continue
        }
        let size = spec.referenceSize
        let left = ThumbstickSceneView(frame: CGRect(origin: .zero, size: size))
        let right = ThumbstickSceneView(frame: CGRect(origin: .zero, size: size))
        guard left.update(spec: spec, region: .leftStick,
                          state: .init(x: 0, yUp: 0, pressed: false), container: size, sourceImage: source),
              right.update(spec: spec, region: .rightStick,
                           state: .init(x: -1, yUp: 0, pressed: true), container: size, sourceImage: source) else {
            check(false, "\(skin.rawValue) 左右三维场景均可合成")
            continue
        }
        check(!left.rendersContinuously && !left.isPlaying, "\(skin.rawValue) 不启动常驻渲染循环")
        let combined = NSImage(size: size)
        combined.lockFocus()
        left.snapshot().draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        right.snapshot().draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        combined.unlockFocus()
        guard let image = combined.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let leftWell = spec.regions[.leftStick], let rightWell = spec.regions[.rightStick] else {
            check(false, "\(skin.rawValue) 合成渲染可读取")
            continue
        }
        check(pixelAlpha(image, at: CGPoint(x: leftWell.midX, y: leftWell.midY), reference: size) > 0 &&
              pixelAlpha(image, at: CGPoint(x: rightWell.midX, y: rightWell.midY), reference: size) > 0,
              "\(skin.rawValue) 合成后左右摇杆都完整可见")
        check(pixelAlpha(image, at: .zero) == 0, "\(skin.rawValue) 合成后没有背景白块")
        if let ring = blueBounds(image) {
            let cap = spec.region(.rightStickCap, in: size)
            check(ring.width > cap.width * 0.5 && ring.height > cap.height * 0.5,
                  "\(skin.rawValue) 按下高亮为跟随三维帽顶的完整圆环，得到 \(ring)")
        } else {
            check(false, "\(skin.rawValue) 按下高亮圆环可测量")
        }
        if let directory = ProcessInfo.processInfo.environment["MATCHSTICKS_DS_RENDER_REVIEW"],
           let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? data.write(to: url.appendingPathComponent("\(skin.rawValue)-composite.png"))
        }
        saveMotionSheet(left: left, right: right, spec: spec, source: source, skin: skin, check: check)
        saveStickCloseUps(spec: spec, source: source, skin: skin)
        if skin == .f310 {
            check(GamepadArtworkImageSource.image(named: "f310") != nil,
                  "SwiftUI 正式布局可以加载原厂手柄资源")
            renderHostedGamepad(check: check)
        }
    }
}

@MainActor
private func saveMotionSheet(left: ThumbstickSceneView, right: ThumbstickSceneView,
                             spec: GamepadArtworkSpec, source: NSImage, skin: GamepadSkin,
                             check: (@autoclosure () -> Bool, String) -> Void) {
    let states: [(String, Float, Float, Bool)] = [
        ("neutral", 0, 0, false), ("left", -1, 0, false), ("right", 1, 0, false),
        ("up", 0, 1, false), ("down", 0, -1, false), ("diagonal", 1, 1, false),
        ("pressed", 1, 0, true),
    ]
    let size = spec.referenceSize
    let tile = skin == .direwolf4 ? CGSize(width: size.width / 4, height: size.height / 4) : size
    let sheet = NSImage(size: CGSize(width: tile.width * 3, height: tile.height * 3))
    sheet.lockFocus()
    for (index, item) in states.enumerated() {
        autoreleasepool {
            let state = GamepadStickState(x: item.1, yUp: item.2, pressed: item.3)
            let ready = left.update(spec: spec, region: .leftStick, state: state, container: size, sourceImage: source) &&
                right.update(spec: spec, region: .rightStick, state: state, container: size, sourceImage: source)
            check(ready, "\(skin.rawValue) \(item.0) 三维状态可渲染")
            guard ready else { return }
            let frame = CGRect(x: CGFloat(index % 3) * tile.width,
                               y: CGFloat(2 - index / 3) * tile.height, width: tile.width, height: tile.height)
            left.snapshot().draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
            right.snapshot().draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
            NSString(string: item.0).draw(at: frame.origin, withAttributes: [
                .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.systemBlue,
            ])
        }
    }
    sheet.unlockFocus()
    guard let directory = ProcessInfo.processInfo.environment["MATCHSTICKS_DS_RENDER_REVIEW"],
          let image = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try? data.write(to: root.appendingPathComponent("\(skin.rawValue)-motion-sheet.png"))
}

/// Enlarged per-state close-ups of both sticks, written only for review runs.
@MainActor
private func saveStickCloseUps(spec: GamepadArtworkSpec, source: NSImage, skin: GamepadSkin) {
    guard skin != .generic, let directory = ProcessInfo.processInfo.environment["MATCHSTICKS_DS_RENDER_REVIEW"],
          let data = stickCloseUps(spec: spec, source: source, skin: skin) else { return }
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try? data.write(to: root.appendingPathComponent("\(skin.rawValue)-stick-closeups.png"))
}

@MainActor
private func stickCloseUps(spec: GamepadArtworkSpec, source: NSImage, skin: GamepadSkin) -> Data? {
    let states: [(String, Float, Float, Bool)] = [
        ("neutral", 0, 0, false), ("left", -1, 0, false), ("right", 1, 0, false),
        ("up", 0, 1, false), ("down", 0, -1, false), ("diagonal", 1, 1, false),
        ("pressed", 1, 0, true),
    ]
    let zoom: CGFloat = skin == .direwolf4 ? 1 : 3
    let container = CGSize(width: spec.referenceSize.width * zoom, height: spec.referenceSize.height * zoom)
    func closeUp(_ region: GamepadArtworkRegion) -> CGRect {
        let well = spec.region(region, in: container)
        let padding = well.width * 0.35
        return CGRect(x: well.minX - padding, y: well.minY - padding,
                      width: well.width + padding * 2, height: well.height + padding * 2).integral
    }
    let boxes = [closeUp(.leftStick), closeUp(.rightStick)]
    let cell = CGSize(width: boxes.map(\.width).max() ?? 0, height: boxes.map(\.height).max() ?? 0)
    guard cell.width > 0, cell.height > 0 else { return nil }
    let sheet = NSImage(size: CGSize(width: cell.width * 2, height: cell.height * CGFloat(states.count)))
    sheet.lockFocus()
    for (index, item) in states.enumerated() {
        for (column, region) in [GamepadArtworkRegion.leftStick, .rightStick].enumerated() {
            let box = boxes[column]
            let origin = CGPoint(x: CGFloat(column) * cell.width + (cell.width - box.width) / 2,
                                 y: CGFloat(states.count - 1 - index) * cell.height + (cell.height - box.height) / 2)
            let view = ThumbstickSceneView(frame: CGRect(origin: .zero, size: container))
            if view.update(spec: spec, region: region, state: .init(x: item.1, yUp: item.2, pressed: item.3),
                           container: container, sourceImage: source),
               let image = view.snapshot().cgImage(forProposedRect: nil, context: nil, hints: nil)?.cropping(to: box) {
                NSImage(cgImage: image, size: box.size).draw(in: CGRect(origin: origin, size: box.size))
            }
            NSString(string: item.0).draw(at: origin, withAttributes: [
                .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.systemBlue,
            ])
        }
    }
    sheet.unlockFocus()
    guard let image = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

@MainActor
private func renderHostedGamepad(check: (@autoclosure () -> Bool, String) -> Void) {
    guard GamepadArtworkImageSource.image(named: "f310") != nil else { return }
    let hosting = NSHostingView(rootView: GamepadSkinView(skin: .f310, state: .neutral)
        .frame(width: 520, height: 400))
    hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
    let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 520, height: 400),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderFront(nil)
    defer { window.orderOut(nil); window.close() }
    hosting.layoutSubtreeIfNeeded()
    hosting.display()
    let scenes = sceneViews(in: hosting)
    check(scenes.count == 2 && scenes.allSatisfy { $0.bounds.width > 0 && $0.bounds.height > 0 },
          "SwiftUI 正式布局包含两个有实际尺寸的三维摇杆视图")
    check(scenes.allSatisfy { $0.errorDescription == nil }, "SwiftUI 三维场景没有资源或几何错误")
    guard scenes.count == 2 else { return }
    let size = scenes[0].bounds.size
    let combined = NSImage(size: size)
    combined.lockFocus()
    scenes[0].snapshot().draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
    scenes[1].snapshot().draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
    combined.unlockFocus()
    guard let image = combined.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        check(false, "SwiftUI 中的三维场景可直接生成渲染图")
        return
    }
    let bitmap = NSBitmapImageRep(cgImage: image)
    var opaque = 0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
            if bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.5 { opaque += 1 }
        }
    }
    check(opaque > 1_000, "SwiftUI 正式布局实际绘制完整手柄而不是空白")
    if let directory = ProcessInfo.processInfo.environment["MATCHSTICKS_DS_RENDER_REVIEW"],
       let data = bitmap.representation(using: .png, properties: [:]) {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: root.appendingPathComponent("f310-hosted.png"))
    }
}

private func sceneViews(in view: NSView) -> [ThumbstickSceneView] {
    view.subviews.flatMap { child -> [ThumbstickSceneView] in
        (child as? ThumbstickSceneView).map { [$0] } ?? sceneViews(in: child)
    }
}

private func pixelAlpha(_ image: CGImage, at point: CGPoint, reference: CGSize? = nil) -> UInt8 {
    let reference = reference ?? CGSize(width: image.width, height: image.height)
    let x = Int((point.x * CGFloat(image.width) / reference.width).rounded())
    let y = Int((point.y * CGFloat(image.height) / reference.height).rounded())
    guard x >= 0, y >= 0, x < image.width, y < image.height else { return 0 }
    let color = NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)
    return UInt8(((color?.alphaComponent ?? 0) * 255).rounded())
}

private func blueBounds(_ image: CGImage) -> CGRect? {
    let bitmap = NSBitmapImageRep(cgImage: image)
    var minX = image.width, minY = image.height, maxX = -1, maxY = -1
    for y in 0..<image.height {
        for x in 0..<image.width {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                  color.blueComponent > 0.78 && color.greenComponent > 0.3 &&
                  color.redComponent < 0.4 && color.alphaComponent > 0 else { continue }
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}
