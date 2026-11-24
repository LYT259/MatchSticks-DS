import AppKit
import SwiftUI
import Vision
import DSCore

@MainActor
func driverStationBrandTests(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void) {
    let brandRed = NSColor.red
    let brandBlue = NSColor.blue
    checkSyntheticBrandPixels(check, brandRed: brandRed, brandBlue: brandBlue)

    NSApplication.shared.finishLaunching()
    let previousAppearance = NSApplication.shared.appearance
    defer { NSApplication.shared.appearance = previousAppearance }
    let previousPolicy = NSApplication.shared.activationPolicy()
    NSApplication.shared.setActivationPolicy(.accessory)
    defer { NSApplication.shared.setActivationPolicy(previousPolicy) }

    let light = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
        brandRed.setFill()
        rect.fill()
        return true
    }
    let dark = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
        brandBlue.setFill()
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

    guard let initial = snapshot(named: "brand-light"), let initialIcon = brandColorBounds(in: initial, matching: brandRed) else {
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
          brandColorBounds(in: interfaceDark, matching: brandRed) != nil else {
        check(false, "changing the interface theme does not replace the selected light icon artwork")
        return
    }

    model.iconStyle = .monochrome
    guard let updated = snapshot(named: "brand-monochrome"), let updatedIcon = brandColorBounds(in: updated, matching: brandBlue) else {
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
        "Sources/MatchSticksDriverStaion/MatchSticksDriverStaionApp.swift"), encoding: .utf8)) ?? ""
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

/// Boundary pixels for the brand detector, independent of the attached display. The AppKit snapshot
/// lives in the display's color space, not sRGB: there sRGB red is no longer (255, 0, 0) and its green
/// channel lands exactly on 51/255 = 0.2000, the value the former `green < 0.2` threshold rejected.
/// Display P3 reproduces that boundary without a wide-gamut display.
@MainActor
private func checkSyntheticBrandPixels(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void,
                                       brandRed: NSColor, brandBlue: NSColor) {
    let space = NSColorSpace.displayP3
    func bitmap(_ codes: [CGFloat]) -> NSBitmapImageRep? {
        guard codes.count == 3, let cgSpace = space.cgColorSpace,
              let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                      space: cgSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(NSColor(colorSpace: space, components: codes + [1], count: 4).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }
    func detected(_ codes: [CGFloat]) -> Bool {
        bitmap(codes).flatMap { brandColorBounds(in: $0, matching: brandRed) } != nil
    }
    func shifted(_ codes: [CGFloat], by steps: CGFloat) -> [CGFloat] {
        codes.map { $0 + steps / 255 }
    }

    let sidebar = NSColor(srgbRed: 0xF1 / 255, green: 0xF1 / 255, blue: 0xF3 / 255, alpha: 1)
    guard let red = brandPixelChannels(of: brandRed, in: space),
          let background = brandPixelChannels(of: sidebar, in: space),
          let blue = brandPixelChannels(of: brandBlue, in: space),
          let otherRed = brandPixelChannels(of: NSColor.systemRed, in: space) else {
        check(false, "every synthetic color can be resolved in Display P3")
        return
    }
    check((red[1] * 255).rounded() == 51,
          "precondition: the declared brand red quantizes to green exactly 51/255 in Display P3 (actual: \(red[1] * 255))")
    check(detected(red), "a brand pixel whose green quantizes to exactly 0.2000 is detected")
    check(detected(shifted(red, by: 1)), "a brand pixel one 8-bit code step above the declared color is detected")
    check(detected(shifted(red, by: -1)), "a brand pixel one 8-bit code step below the declared color is detected")
    check(!detected(shifted(red, by: 2)), "a brand pixel two 8-bit code steps away is a different color")
    check(!detected(background), "a snapshot holding only the sidebar background carries no icon")
    check(!detected(blue), "the other artwork's color is not mistaken for the selected one")
    check(!detected(otherRed), "a different red is not accepted as the declared color")
}

/// Vertical extent of the opaque pixels that render `declared`, resolved in the snapshot's own color space.
private func brandColorBounds(in bitmap: NSBitmapImageRep, matching declared: NSColor) -> (top: Int, bottom: Int)? {
    guard bitmap.colorSpace.colorSpaceModel == .rgb,
          let expected = brandPixelChannels(of: declared, in: bitmap.colorSpace) else { return nil }
    var top = Int.max
    var bottom = Int.min
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.9 else { continue }
            // colorAt hands back the bitmap's raw components (merely tagged Generic RGB), so they
            // already live in bitmap.colorSpace and must not be converted again.
            let channels = [color.redComponent, color.greenComponent, color.blueComponent]
            guard zip(channels, expected).allSatisfy({ abs($0 - $1) <= brandPixelTolerance }) else { continue }
            top = min(top, y)
            bottom = max(bottom, y)
        }
    }
    return top == Int.max ? nil : (top, bottom)
}

/// One 8-bit code step per side around the renderer's quantization, plus an epsilon for floating-point noise on the boundary.
private let brandPixelTolerance: CGFloat = 1 / 255 + 1e-6

/// `color` in `space` rounded to the 8-bit channels the snapshot renderer produces, as 0...1 fractions.
private func brandPixelChannels(of color: NSColor, in space: NSColorSpace) -> [CGFloat]? {
    color.usingColorSpace(space).map { converted in
        [converted.redComponent, converted.greenComponent, converted.blueComponent].map { ($0 * 255).rounded() / 255 }
    }
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
