import AppKit
import SwiftUI
import Vision
import DSCore

@MainActor
func driverStationBrandTests(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void) {
    NSApplication.shared.finishLaunching()
    let previousAppearance = NSApplication.shared.appearance
    defer { NSApplication.shared.appearance = previousAppearance }
    let previousPolicy = NSApplication.shared.activationPolicy()
    NSApplication.shared.setActivationPolicy(.accessory)
    defer { NSApplication.shared.setActivationPolicy(previousPolicy) }

    let light = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
        NSColor.red.setFill()
        rect.fill()
        return true
    }
    let dark = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
        NSColor.blue.setFill()
        rect.fill()
        return true
    }
    let model = DSModel(persistenceEnabled: false)
    var dockImage: NSImage?
    model.appIconCenter.artworkLoader = { $0 == "app-icon-day" ? light : dark }
    model.appIconCenter.applier = { dockImage = $0 }
    model.iconAppearance = .light
    model.appearanceMode = .light

    let host = NSHostingView(rootView: DriverStationBrandView(model: model).background(DSTheme.sidebar))
    let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 176, height: 150),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = CGRect(x: 0, y: 0, width: 176, height: 150)
    window.isReleasedWhenClosed = false
    defer { window.close() }

    func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
    }
    func snapshot(named name: String) -> NSBitmapImageRep? {
        settle()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: ".build/review"), withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: ".build/review/\(name).png"))
        }
        return bitmap
    }

    guard let initial = snapshot(named: "brand-light"), let initialIcon = brandColorBounds(in: initial, red: true) else {
        check(false, "the selected icon is rendered in the real AppKit-hosted sidebar")
        return
    }
    let titleObservations = brandTextObservations(in: initial)
    let renderedName = titleObservations.map(\.text).joined(separator: " ")
    check(renderedName.replacingOccurrences(of: " ", with: "") == "MatchSticksDriverStation",
          "the sidebar renders the full product name instead of an abbreviation (actual: \(renderedName))")
    check(dockImage === model.appIconCenter.artwork && model.appIconCenter.artwork === light,
          "the brand and Dock share the exact selected artwork instance")
    guard let title = titleObservations.first(where: { $0.text.contains("MatchSticks") }) else {
        check(false, "the full product title can be located below the selected icon")
        return
    }
    check(initialIcon.bottom < title.top,
          "the selected application icon is above the full product name in the rendered layout")

    model.appearanceMode = .dark
    guard let interfaceDark = snapshot(named: "brand-interface-dark"),
          brandColorBounds(in: interfaceDark, red: true) != nil else {
        check(false, "changing the interface theme does not replace the selected light icon artwork")
        return
    }

    model.iconStyle = .monochrome
    guard let updated = snapshot(named: "brand-monochrome"), let updatedIcon = brandColorBounds(in: updated, red: false) else {
        check(false, "changing icon style immediately renders the newly resolved artwork")
        return
    }
    check(model.appIconCenter.artwork === dark && updatedIcon.top == initialIcon.top && updatedIcon.bottom == initialIcon.bottom,
          "the icon style change replaces the pixels without moving the brand layout")
    check(model.appearanceMode == .dark && model.iconAppearance == .light,
          "the interface theme and icon appearance stay independent")

    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let rootSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/MatchSticksDS/MatchSticksDSApp.swift"), encoding: .utf8)) ?? ""
    check(rootSource.contains("DriverStationBrandView(model: model)") &&
          !rootSource.contains("tr(\"机器人驾驶台\")"),
          "the actual sidebar embeds the branded view and no longer translates the old subtitle")

    let suiteName = "org.ghfrc.driverstation.test.brand.startup.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set("monochrome", forKey: "matchsticks.appIconStyle")
    defaults.set("dark", forKey: "matchsticks.appIconAppearance")
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var restoredDockImage: NSImage?
    let restored = DSModel(settingsDefaults: defaults, persistenceEnabled: true) { center in
        center.artworkLoader = { $0 == "app-icon-mono-night" ? dark : light }
        center.systemDarkProvider = { false }
        center.applier = { restoredDockImage = $0 }
    }
    check(restored.iconStyle == .monochrome && restored.iconAppearance == .dark &&
          restored.appIconCenter.style == .monochrome && restored.appIconCenter.mode == .dark,
          "the first brand render restores icon preferences without waiting for start or an explicit settings reload")
    check(restored.appIconCenter.pushedFileNames == ["app-icon-mono-night"] &&
          restored.appIconCenter.artwork === dark && restoredDockImage === dark,
          "the first brand render pushes monochrome dark artwork exactly once and applies the same NSImage")
}

private func brandColorBounds(in bitmap: NSBitmapImageRep, red: Bool) -> (top: Int, bottom: Int)? {
    var top = Int.max
    var bottom = Int.min
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y),
                  color.alphaComponent > 0.9 else { continue }
            let matches = red
                ? color.redComponent > 0.8 && color.greenComponent < 0.2 && color.blueComponent < 0.2
                : color.blueComponent > 0.8 && color.redComponent < 0.2 && color.greenComponent < 0.2
            if matches {
                top = min(top, y)
                bottom = max(bottom, y)
            }
        }
    }
    return top == Int.max ? nil : (top, bottom)
}

private func brandTextObservations(in bitmap: NSBitmapImageRep) -> [(text: String, top: Int)] {
    guard let image = bitmap.cgImage,
          let context = CGContext(data: nil, width: image.width * 2, height: image.height * 2,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 8,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * 2, height: image.height * 2))
    guard let scaledImage = context.makeImage() else { return [] }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    guard let _ = try? VNImageRequestHandler(cgImage: scaledImage, options: [:]).perform([request]),
          let observations = request.results else { return [] }
    return observations.compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        return (candidate.string, Int((1 - observation.boundingBox.maxY) * CGFloat(bitmap.pixelsHigh)))
    }.sorted { $0.top < $1.top }
}
