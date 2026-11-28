import AppKit

// Removes the background matte left around a controller silhouette when its artwork was cut
// away from a light (or shadowed) background. Reproducible: the same input always gives the same
// output, and the UI tests (ArtworkIntegrityTests) hold the result to "no visible light fringe".
//
// usage: swift clean-artwork-edges.swift <input.png> <output.png>
//
// What it does, per pixel, in straight (non-premultiplied) RGBA as stored in the file:
//  * A semi-transparent pixel keeps its place on the edge but takes the colour of the opaque
//    body next to it. When it is lighter than that body it was mixed with a light background:
//    its alpha is reduced by that matte fraction, so the edge keeps its anti-aliasing without
//    the pale band. When it is darker than every body pixel around it, it is a cast shadow and
//    becomes fully transparent.
//  * The outermost opaque pixel is compared with the body a few pixels further in. If it is
//    clearly lighter, the matte also reached inside the silhouette and the pixel takes the body
//    colour. A much larger difference means a genuinely different part (a white shell beside a
//    black grip) and is left alone.
//  * Pixels away from any opaque body are dropped.
// Colours inside the silhouette are not touched.

struct Pixels {
    let width: Int
    let height: Int
    var red: [Double]
    var green: [Double]
    var blue: [Double]
    var alpha: [Double]

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.bitsPerPixel == 32, image.bitsPerComponent == 8,
              let data = image.dataProvider?.data else {
            FileHandle.standardError.write("unsupported image: \(url.path)\n".data(using: .utf8)!)
            return nil
        }
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
                reds[index] = min(1, Double(bytes[first ? offset + 1 : offset]) / 255 / divide)
                greens[index] = min(1, Double(bytes[offset + (first ? 2 : 1)]) / 255 / divide)
                blues[index] = min(1, Double(bytes[offset + (first ? 3 : 2)]) / 255 / divide)
            }
        }
        red = reds
        green = greens
        blue = blues
        alpha = alphas
    }

    func luminance(_ index: Int) -> Double { 0.299 * red[index] + 0.587 * green[index] + 0.114 * blue[index] }

    /// Chamfer distance in pixels to the nearest clear pixel; outside the image counts as clear.
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

    func write(to url: URL) -> Bool {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            bytes[index * 4] = UInt8((red[index] * 255).rounded())
            bytes[index * 4 + 1] = UInt8((green[index] * 255).rounded())
            bytes[index * 4 + 2] = UInt8((blue[index] * 255).rounded())
            bytes[index * 4 + 3] = UInt8((alpha[index] * 255).rounded())
        }
        // Straight alpha, like every other artwork in the bundle.
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3, var pixels = Pixels(url: URL(fileURLWithPath: arguments[1])) else {
    print("usage: swift clean-artwork-edges.swift <input.png> <output.png>")
    exit(1)
}
let width = pixels.width, height = pixels.height
let distance = pixels.distanceToClear()
let originalRed = pixels.red, originalGreen = pixels.green, originalBlue = pixels.blue, originalAlpha = pixels.alpha
func originalLuminance(_ index: Int) -> Double { 0.299 * originalRed[index] + 0.587 * originalGreen[index] + 0.114 * originalBlue[index] }

var cleanedPartial = 0, droppedShadow = 0, cleanedRim = 0
for y in 0..<height {
    for x in 0..<width {
        let index = y * width + x
        let a = originalAlpha[index]
        if a >= 0.98 {
            guard distance[index] <= 1.5 else { continue }
            // First opaque pixel that is properly inside the silhouette, along the inward normal.
            var gx = 0.0, gy = 0.0
            if x > 0, x < width - 1 { gx = distance[index + 1] - distance[index - 1] }
            if y > 0, y < height - 1 { gy = distance[index + width] - distance[index - width] }
            if abs(gx) < 1e-9, abs(gy) < 1e-9 { gy = 1 }
            let length = (gx * gx + gy * gy).squareRoot()
            gx /= length
            gy /= length
            var px = Double(x), py = Double(y), reference = -1
            for _ in 0..<16 {
                px += gx / 2
                py += gy / 2
                let sampleX = Int(px.rounded()), sampleY = Int(py.rounded())
                guard sampleX >= 0, sampleY >= 0, sampleX < width, sampleY < height else { break }
                let sample = sampleY * width + sampleX
                if originalAlpha[sample] >= 0.98, distance[sample] >= 2.5 {
                    reference = sample
                    break
                }
            }
            guard reference >= 0 else { continue }
            let lighter = originalLuminance(index) - originalLuminance(reference)
            if lighter > 0.10, lighter <= 0.45 {
                pixels.red[index] = originalRed[reference]
                pixels.green[index] = originalGreen[reference]
                pixels.blue[index] = originalBlue[reference]
                cleanedRim += 1
            }
            continue
        }
        guard a > 0.02 else {
            pixels.alpha[index] = 0
            pixels.red[index] = 0
            pixels.green[index] = 0
            pixels.blue[index] = 0
            continue
        }
        // The body this edge pixel belongs to. An edge pixel that touches an opaque pixel of about
        // its own brightness is part of that piece: a white shell beside a black grip stays shell.
        // Otherwise it belongs to the first opaque pixel met walking inwards, which is how a pale
        // pixel lying outside a thin black part is told apart from the white plate behind it.
        let own = originalLuminance(index)
        var body = -1
        var closest = 0.25
        for dy in -1...1 {
            for dx in -1...1 where !(dx == 0 && dy == 0) {
                let sampleX = x + dx, sampleY = y + dy
                guard sampleX >= 0, sampleY >= 0, sampleX < width, sampleY < height else { continue }
                let sample = sampleY * width + sampleX
                guard originalAlpha[sample] >= 0.98 else { continue }
                let difference = abs(originalLuminance(sample) - own)
                if difference <= closest {
                    closest = difference
                    body = sample
                }
            }
        }
        if body < 0 {
            var gx = 0.0, gy = 0.0
            if x > 0, x < width - 1 { gx = distance[index + 1] - distance[index - 1] }
            if y > 0, y < height - 1 { gy = distance[index + width] - distance[index - width] }
            if abs(gx) < 1e-9, abs(gy) < 1e-9 { gy = 1 }
            let length = (gx * gx + gy * gy).squareRoot()
            var px = Double(x) + gx / length / 2, py = Double(y) + gy / length / 2
            for _ in 0..<16 {
                let sampleX = Int(px.rounded()), sampleY = Int(py.rounded())
                guard sampleX >= 0, sampleY >= 0, sampleX < width, sampleY < height else { break }
                let sample = sampleY * width + sampleX
                if originalAlpha[sample] >= 0.98 {
                    body = sample
                    break
                }
                px += gx / length / 2
                py += gy / length / 2
            }
        }
        guard body >= 0 else {
            pixels.alpha[index] = 0
            pixels.red[index] = 0
            pixels.green[index] = 0
            pixels.blue[index] = 0
            droppedShadow += 1
            continue
        }
        let bodyLuminance = originalLuminance(body)
        if own < bodyLuminance - 0.08 {
            // Darker than anything around it: a shadow that was painted outside the controller.
            pixels.alpha[index] = 0
            pixels.red[index] = 0
            pixels.green[index] = 0
            pixels.blue[index] = 0
            droppedShadow += 1
            continue
        }
        let matte = min(1, max(0, (own - bodyLuminance) / max(0.05, 1 - bodyLuminance)))
        // A light background only shows against a dark body; on a light body the same mixture is
        // indistinguishable from the body itself and the alpha is kept as it was.
        let visible = min(1, max(0, (0.6 - bodyLuminance) / 0.5))
        var newAlpha = a * (1 - matte * visible)
        if newAlpha < 0.02 {
            newAlpha = 0
            droppedShadow += 1
        } else {
            cleanedPartial += 1
        }
        pixels.alpha[index] = newAlpha
        pixels.red[index] = newAlpha > 0 ? originalRed[body] : 0
        pixels.green[index] = newAlpha > 0 ? originalGreen[body] : 0
        pixels.blue[index] = newAlpha > 0 ? originalBlue[body] : 0
    }
}
let output = URL(fileURLWithPath: arguments[2])
guard pixels.write(to: output) else {
    print("could not write \(output.path)")
    exit(1)
}
print("cleaned \(arguments[1]): \(width)x\(height), edge pixels recoloured \(cleanedPartial), matte/shadow removed \(droppedShadow), rim recoloured \(cleanedRim)")
