import AppKit
import DSCore

/// Controller artwork exactly as stored on disk: straight 8-bit RGBA in image coordinates.
private struct ArtworkBytes {
    let width: Int
    let height: Int
    let red: [Double]
    let green: [Double]
    let blue: [Double]
    let alpha: [Double]

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.bitsPerPixel == 32, image.bitsPerComponent == 8,
              let data = image.dataProvider?.data else { return nil }
        width = image.width
        height = image.height
        let count = width * height
        let bytes = [UInt8](data as Data)
        let row = image.bytesPerRow
        let first = image.alphaInfo == .premultipliedFirst || image.alphaInfo == .first || image.alphaInfo == .noneSkipFirst
        let premultiplied = image.alphaInfo == .premultipliedFirst || image.alphaInfo == .premultipliedLast
        let hasAlpha = image.alphaInfo != .none && image.alphaInfo != .noneSkipFirst && image.alphaInfo != .noneSkipLast
        var reds = [Double](repeating: 0, count: count), greens = reds, blues = reds, alphas = reds
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * row + x * 4, index = y * width + x
                let a = hasAlpha ? Double(bytes[first ? offset : offset + 3]) / 255 : 1
                alphas[index] = a
                let divide = premultiplied && a > 0 ? a : 1
                reds[index] = Double(bytes[first ? offset + 1 : offset]) / 255 / divide
                greens[index] = Double(bytes[offset + (first ? 2 : 1)]) / 255 / divide
                blues[index] = Double(bytes[offset + (first ? 3 : 2)]) / 255 / divide
            }
        }
        red = reds
        green = greens
        blue = blues
        alpha = alphas
    }

    func luminance(_ index: Int) -> Double { 0.299 * red[index] + 0.587 * green[index] + 0.114 * blue[index] }

    func luminance(x: Int, y: Int) -> Double {
        guard x >= 0, y >= 0, x < width, y < height else { return -1 }
        let index = y * width + x
        return alpha[index] >= 0.9 ? luminance(index) : -1
    }

    /// Chamfer distance in pixels from every pixel to the nearest clear pixel (outside counts as clear).
    func distanceToClear() -> [Double] {
        let count = width * height
        var distance = [Double](repeating: Double(width + height), count: count)
        for index in 0..<count where alpha[index] <= 0.02 { distance[index] = 0 }
        let side = 1.0, diagonal = 1.41421356237
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard distance[index] > 0 else { continue }
                var best = Double(width + height)
                if x > 0 { best = min(best, distance[index - 1] + side) }
                if y > 0 {
                    best = min(best, distance[index - width] + side)
                    if x > 0 { best = min(best, distance[index - width - 1] + diagonal) }
                    if x < width - 1 { best = min(best, distance[index - width + 1] + diagonal) }
                }
                distance[index] = best
            }
        }
        if height > 0 {
            for y in stride(from: height - 1, through: 0, by: -1) {
                for x in stride(from: width - 1, through: 0, by: -1) {
                    let index = y * width + x
                    guard distance[index] > 0 else { continue }
                    var best = distance[index]
                    if x < width - 1 { best = min(best, distance[index + 1] + side) }
                    if y < height - 1 {
                        best = min(best, distance[index + width] + side)
                        if x < width - 1 { best = min(best, distance[index + width + 1] + diagonal) }
                        if x > 0 { best = min(best, distance[index + width - 1] + diagonal) }
                    }
                    distance[index] = best
                }
            }
        }
        return distance
    }

}

private func artworkRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/MatchSticksDriverStaion/Resources/Gamepads")
}

/// Luminance of the first fully opaque pixel met when walking from one point of the silhouette
/// towards the inside of the controller along the normal. That is the body the edge pixel belongs
/// to, so a white shell next to a black grip is compared with the shell, never with the grip.
/// Returns nil when no opaque pixel is found within eight pixels.
private func inwardBody(_ bytes: ArtworkBytes, _ distance: [Double], x: Int, y: Int) -> Double? {
    func value(_ px: Int, _ py: Int) -> Double {
        guard px >= 0, py >= 0, px < bytes.width, py < bytes.height else { return 0 }
        return distance[py * bytes.width + px]
    }
    var gx = value(x + 1, y) - value(x - 1, y)
    var gy = value(x, y + 1) - value(x, y - 1)
    if abs(gx) < 1e-9 && abs(gy) < 1e-9 { gx = 0; gy = 1 }
    let length = (gx * gx + gy * gy).squareRoot()
    gx /= length
    gy /= length
    var px = Double(x), py = Double(y)
    for _ in 0..<16 {
        px += gx / 2
        py += gy / 2
        let sampleX = Int(px.rounded()), sampleY = Int(py.rounded())
        guard sampleX >= 0, sampleY >= 0, sampleX < bytes.width, sampleY < bytes.height else { return nil }
        let sample = sampleY * bytes.width + sampleX
        if bytes.alpha[sample] >= 0.98 { return bytes.luminance(sample) }
    }
    return nil
}

/// Every shipped controller artwork keeps a clean silhouette: neither the semi-transparent edge
/// pixels nor the outermost opaque ring is lighter than the body just inside them. A light fringe
/// reads as a white outline on the dark interface, which is what the PS4, Xbox and Extreme 3D Pro
/// artworks had.
func artworkEdgeTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    for name in ["dualshock4", "dualsense", "xbox-series", "f310", "direwolf4", "extreme3dpro-base", "extreme3dpro-handle"] {
        guard let bytes = ArtworkBytes(url: artworkRoot().appendingPathComponent("\(name).png")) else {
            check(false, "\(name) 素材可按原始像素读取")
            continue
        }
        let width = bytes.width, height = bytes.height
        let distance = bytes.distanceToClear()
        for edge in ["半透明边缘像素", "轮廓最外圈"] {
            var light = [Bool](repeating: false, count: width * height)
            var total = 0
            var worst = 0.0
            for index in 0..<(width * height) {
                let isEdge = edge == "半透明边缘像素"
                    ? bytes.alpha[index] > 0.02 && bytes.alpha[index] < 0.98
                    : bytes.alpha[index] >= 0.98 && distance[index] <= 1.5
                guard isEdge else { continue }
                total += 1
                guard let body = inwardBody(bytes, distance, x: index % width, y: index / width) else { continue }
                // What the eye sees: the edge pixel is drawn with its own alpha over the body colour,
                // so the light it adds is alpha times its excess luminance. A faint highlight on a
                // white shell adds almost nothing; a white matte on a black body adds a lot.
                let added = bytes.alpha[index] * max(0, bytes.luminance(index) - body)
                worst = max(worst, added)
                if added > 0.08 { light[index] = true }
            }
            // A matte runs along the silhouette as a continuous band. A light edge pixel next to a
            // darker part of the controller is legitimate and only ever occurs in isolated spots,
            // so only pixels with several flagged neighbours within four pixels count as fringe.
            var integral = [Int](repeating: 0, count: (width + 1) * (height + 1))
            for y in 0..<height {
                var running = 0
                for x in 0..<width {
                    running += light[y * width + x] ? 1 : 0
                    integral[(y + 1) * (width + 1) + x + 1] = integral[y * (width + 1) + x + 1] + running
                }
            }
            func windowCount(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
                integral[y1 * (width + 1) + x1] - integral[y0 * (width + 1) + x1]
                    - integral[y1 * (width + 1) + x0] + integral[y0 * (width + 1) + x0]
            }
            var band = 0
            var fringe = [Bool](repeating: false, count: width * height)
            for index in 0..<(width * height) where light[index] {
                let x = index % width, y = index / width
                let x0 = max(0, x - 4), y0 = max(0, y - 4)
                let x1 = min(width, x + 5), y1 = min(height, y + 5)
                if windowCount(x0, y0, x1, y1) >= 8 {
                    band += 1
                    fringe[index] = true
                }
            }
            if let directory = ProcessInfo.processInfo.environment["MATCHSTICKS_DS_RENDER_REVIEW"] {
                saveEdgeReview(bytes, fringe: fringe, to: URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent("\(name)-edge-\(edge == "半透明边缘像素" ? "partial" : "rim").png"))
            }
            let limit = edge == "半透明边缘像素" ? 0.01 : 0.03
            check(total == 0 || Double(band) / Double(total) <= limit,
                  "\(name) \(edge)不给轮廓添连续亮边（亮边带像素 \(band)/\(total)，最大增亮 \(Int((worst * 255).rounded()))/255，可见阈值 20/255）")
        }
    }
}

/// Review image for a fringe check: the artwork on the interface's dark background with the
/// pixels counted as fringe painted red. Written only when a review directory is configured.
private func saveEdgeReview(_ bytes: ArtworkBytes, fringe: [Bool], to url: URL) {
    let count = bytes.width * bytes.height
    guard let context = CGContext(data: nil, width: bytes.width, height: bytes.height, bitsPerComponent: 8,
                                  bytesPerRow: bytes.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    var pixels = [UInt8](repeating: 0, count: count * 4)
    for index in 0..<count {
        let background = 0.11, alpha = bytes.alpha[index]
        let blend = { (channel: Double) -> UInt8 in UInt8(max(0, min(1, alpha * channel + (1 - alpha) * background)) * 255) }
        pixels[index * 4] = blend(bytes.red[index])
        pixels[index * 4 + 1] = blend(bytes.green[index])
        pixels[index * 4 + 2] = blend(bytes.blue[index])
        pixels[index * 4 + 3] = 255
        if fringe[index] { pixels[index * 4] = 255; pixels[index * 4 + 1] = 0; pixels[index * 4 + 2] = 0 }
    }
    pixels.withUnsafeBytes { context.data!.copyMemory(from: $0.bindMemory(to: UInt8.self).baseAddress!, byteCount: pixels.count) }
    // A CGImage's first row is its top row, which is already how the buffer was filled.
    guard let image = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
}

private struct DiscFit {
    let centreX: Double
    let centreY: Double
    let radius: Double
    let inliers: Int
    let error: Double
}

/// Locates a round button: marches outward from an approximate centre along 48 rays, records the
/// darkest point of each ray (the gap that separates the button from the body) and fits a circle
/// to those points, discarding rays that disagree with the others.
private func fittedDisc(_ bytes: ArtworkBytes, startX: Double, startY: Double, rMin: Double, rMax: Double) -> DiscFit? {
    func fit(_ points: [(Double, Double)]) -> (Double, Double, Double, Double)? {
        guard points.count >= 12 else { return nil }
        var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0, sz = 0.0, szx = 0.0, szy = 0.0
        for (x, y) in points {
            let z = x * x + y * y
            sx += x; sy += y; sxx += x * x; syy += y * y; sxy += x * y; sz += z; szx += z * x; szy += z * y
        }
        var matrix = [[sxx, sxy, sx, -szx], [sxy, syy, sy, -szy], [sx, sy, Double(points.count), -sz]]
        for column in 0..<3 {
            var pivot = column
            for row in (column + 1)..<3 where abs(matrix[row][column]) > abs(matrix[pivot][column]) { pivot = row }
            guard abs(matrix[pivot][column]) > 1e-9 else { return nil }
            matrix.swapAt(column, pivot)
            for row in 0..<3 where row != column {
                let factor = matrix[row][column] / matrix[column][column]
                for cell in column..<4 { matrix[row][cell] -= factor * matrix[column][cell] }
            }
        }
        let d = matrix[0][3] / matrix[0][0], e = matrix[1][3] / matrix[1][1]
        let cx = -d / 2, cy = -e / 2
        let radius = (cx * cx + cy * cy - matrix[2][3] / matrix[2][2]).squareRoot()
        guard radius.isFinite, radius > 0 else { return nil }
        return (cx, cy, radius, 0)
    }
    func residual(_ points: [(Double, Double)], _ cx: Double, _ cy: Double, _ radius: Double) -> [Double] {
        points.map { hypot($0.0 - cx, $0.1 - cy) - radius }
    }
    var points: [(Double, Double)] = []
    for step in 0..<48 {
        let angle = Double(step) * 2 * Double.pi / 48
        var best = rMin, bestValue = Double.greatestFiniteMagnitude
        var radius = rMin
        while radius <= rMax {
            let x = startX + radius * cos(angle), y = startY + radius * sin(angle)
            let value = (bytes.luminance(x: Int(x.rounded()), y: Int(y.rounded())) * 2
                + bytes.luminance(x: Int((x + cos(angle)).rounded()), y: Int((y + sin(angle)).rounded()))
                + bytes.luminance(x: Int((x - cos(angle)).rounded()), y: Int((y - sin(angle)).rounded()))) / 4
            if value >= 0 && value < bestValue { bestValue = value; best = radius }
            radius += 0.5
        }
        points.append((startX + best * cos(angle), startY + best * sin(angle)))
    }
    guard let first = fit(points) else { return nil }
    var cx = first.0, cy = first.1, radius = first.2
    var kept = points
    for _ in 0..<3 {
        let errors = residual(kept, cx, cy, radius)
        let meanSquare = errors.reduce(0) { $0 + $1 * $1 } / Double(errors.count)
        let limit = max(1.5, 2.2 * meanSquare.squareRoot())
        let next = zip(kept, errors).filter { abs($0.1) <= limit }.map { $0.0 }
        if next.count < 12 || next.count == kept.count { break }
        kept = next
        if let again = fit(kept) { cx = again.0; cy = again.1; radius = again.2 }
    }
    let errors = residual(kept, cx, cy, radius)
    let error = (errors.reduce(0) { $0 + $1 * $1 } / Double(errors.count)).squareRoot()
    return DiscFit(centreX: cx, centreY: cy, radius: radius, inliers: kept.count, error: error)
}

/// A face-button highlight is an ellipse inscribed in the calibrated rect. It only lines up with
/// the button when the rect is centred on the button's disc and about as wide as the disc, so the
/// test measures the disc in the artwork and compares.
func faceButtonCalibrationTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    // Search band for the gap around the button, and how circular that gap must be. The F310's
    // glossy buttons reflect unevenly, so their gap is measured to about two pixels.
    let bands: [GamepadSkin: (rMin: Double, rMax: Double, error: Double)] = [
        .dualshock4: (26, 44, 1.5), .dualsense: (30, 44, 1.5), .xboxSeries: (26, 44, 1.5), .f310: (13, 27, 3),
    ]
    for (skin, band) in bands.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
        let spec = GamepadArtworkCatalog.spec(for: skin)
        guard let bytes = ArtworkBytes(url: artworkRoot().appendingPathComponent("\(spec.imageName).png")) else {
            check(false, "\(skin.rawValue) 面键标定测试图可读取")
            continue
        }
        for (region, name) in [(GamepadArtworkRegion.faceNorth, "上"), (.faceEast, "右"), (.faceSouth, "下"), (.faceWest, "左")] {
            guard let rect = spec.regions[region] else { check(false, "\(skin.rawValue) \(name)面键有标定框"); continue }
            let startX = rect.midX * Double(bytes.width) / spec.referenceSize.width
            let startY = rect.midY * Double(bytes.height) / spec.referenceSize.height
            guard let disc = fittedDisc(bytes, startX: startX, startY: startY, rMin: band.rMin, rMax: band.rMax),
                  disc.inliers >= 40, disc.error <= band.error else {
                check(false, "\(skin.rawValue) \(name)面键的圆盘可以在标定框附近清楚测量到（偏移的标定框会让暗缝落到搜索范围之外）")
                continue
            }
            let offsetX = disc.centreX - startX, offsetY = disc.centreY - startY
            let width = rect.width * Double(bytes.width) / spec.referenceSize.width
            let height = rect.height * Double(bytes.height) / spec.referenceSize.height
            check(abs(offsetX) <= 2.5 && abs(offsetY) <= 2.5,
                  "\(skin.rawValue) \(name)面键高亮框中心对准按键圆盘（偏差 \(String(format: "%.1f", offsetX)), \(String(format: "%.1f", offsetY)) 像素）")
            check(width >= disc.radius * 2 && height >= disc.radius * 2 && max(width, height) <= disc.radius * 2 + 10,
                  "\(skin.rawValue) \(name)面键高亮框大小贴合圆盘（框 \(String(format: "%.0f", width))x\(String(format: "%.0f", height))，圆盘直径 \(String(format: "%.1f", disc.radius * 2))）")
        }
    }
}

/// The Direwolf 4 guide highlight must sit on the Home emblem printed between the two small buttons.
func direwolfGuideCalibrationTest(_ check: (@autoclosure () -> Bool, String) -> Void) {
    let spec = GamepadArtworkCatalog.spec(for: .direwolf4)
    guard let bytes = ArtworkBytes(url: artworkRoot().appendingPathComponent("\(spec.imageName).png")),
          let rect = spec.regions[.guide] else {
        check(false, "冰原狼 4 Home 键标定可读取")
        return
    }
    // Just past the emblem: the two small buttons sit close on either side and must stay outside.
    let window = rect.insetBy(dx: -rect.width * 0.15, dy: -rect.height * 0.15)
    var sumX = 0.0, sumY = 0.0, count = 0
    var minX = Double.greatestFiniteMagnitude, maxX = -Double.greatestFiniteMagnitude
    var minY = Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
    for y in max(0, Int(window.minY))..<min(bytes.height, Int(window.maxY)) {
        for x in max(0, Int(window.minX))..<min(bytes.width, Int(window.maxX))
        where bytes.alpha[y * bytes.width + x] >= 0.9 && bytes.luminance(y * bytes.width + x) < 0.5 {
            sumX += Double(x); sumY += Double(y); count += 1
            minX = min(minX, Double(x)); maxX = max(maxX, Double(x))
            minY = min(minY, Double(y)); maxY = max(maxY, Double(y))
        }
    }
    guard count > 200 else { check(false, "冰原狼 4 Home 键 Logo 可以在标定框附近找到"); return }
    let offsetX = sumX / Double(count) - rect.midX, offsetY = sumY / Double(count) - rect.midY
    check(abs(offsetX) <= 8 && abs(offsetY) <= 8,
          "冰原狼 4 Home 键高亮框中心对准 Logo（偏差 \(String(format: "%.1f", offsetX)), \(String(format: "%.1f", offsetY)) 像素）")
    check(rect.width >= (maxX - minX) * 0.8 && rect.width <= (maxX - minX) * 1.4 &&
              rect.height >= (maxY - minY) * 0.8 && rect.height <= (maxY - minY) * 1.4,
          "冰原狼 4 Home 键高亮框大小贴合 Logo（框 \(String(format: "%.0f", rect.width))x\(String(format: "%.0f", rect.height))，Logo \(String(format: "%.0f", maxX - minX))x\(String(format: "%.0f", maxY - minY))）")
}

func artworkIntegrityTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    artworkEdgeTests(check)
    faceButtonCalibrationTests(check)
    direwolfGuideCalibrationTest(check)
}
