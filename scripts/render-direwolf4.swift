import AppKit

let scale = 4.0
let width = 1968, height = 1364
let resource = "Sources/MatchSticksDS/Resources/Gamepads"

final class SourcePixels {
    let image: CGImage
    let context: CGContext
    init?(path: String) {
        guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        self.image = image
        self.context = context
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    func sample(_ x: Int, _ y: Int) -> NSColor {
        let x = max(0, min(image.width - 1, x)), y = max(0, min(image.height - 1, y))
        let offset = (y * image.width + x) * 4
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        return NSColor(deviceRed: CGFloat(pixels[offset]) / 255,
                       green: CGFloat(pixels[offset + 1]) / 255,
                       blue: CGFloat(pixels[offset + 2]) / 255,
                       alpha: CGFloat(pixels[offset + 3]) / 255)
    }
    func averageColor(_ region: CGRect, darkOnly: Bool = false) -> NSColor? {
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, weight: CGFloat = 0
        for y in max(0, Int(region.minY))..<min(image.height, Int(region.maxY)) {
            for x in max(0, Int(region.minX))..<min(image.width, Int(region.maxX)) {
                let offset = (y * image.width + x) * 4
                let alpha = CGFloat(pixels[offset + 3]) / 255
                let luminance = (CGFloat(pixels[offset]) * 0.2126 + CGFloat(pixels[offset + 1]) * 0.7152 + CGFloat(pixels[offset + 2]) * 0.0722) / 255
                if alpha < 0.05 || (darkOnly && luminance >= 0.65) { continue }
                red += CGFloat(pixels[offset]) / 255 * alpha
                green += CGFloat(pixels[offset + 1]) / 255 * alpha
                blue += CGFloat(pixels[offset + 2]) / 255 * alpha
                weight += alpha
            }
        }
        guard weight > 0 else { return nil }
        return NSColor(deviceRed: red / weight, green: green / weight, blue: blue / weight, alpha: 1)
    }
    func blueSample(_ region: CGRect) -> NSColor? {
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        var bestScore = CGFloat(0.04)
        var color: NSColor?
        for y in max(0, Int(region.minY))..<min(image.height, Int(region.maxY)) {
            for x in max(0, Int(region.minX))..<min(image.width, Int(region.maxX)) {
                let offset = (y * image.width + x) * 4
                let red = CGFloat(pixels[offset]) / 255, green = CGFloat(pixels[offset + 1]) / 255
                let blue = CGFloat(pixels[offset + 2]) / 255
                guard pixels[offset + 3] > 128, blue > green, blue - red > bestScore else { continue }
                bestScore = blue - red
                color = NSColor(deviceRed: red, green: green, blue: blue, alpha: 1)
            }
        }
        return color
    }
}

final class Canvas {
    let width: Int, height: Int
    let bitmap: NSBitmapImageRep
    init(width: Int, height: Int) {
        self.width = width; self.height = height
        bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    }
    func draw(_ body: () -> Void) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        body()
        NSGraphicsContext.current = previous
    }
    func write(_ name: String) throws {
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: URL(fileURLWithPath: "\(resource)/\(name)"))
    }
    func writeCrop(_ name: String, rect: CGRect, clearCap: CGRect? = nil) throws {
        guard let image = bitmap.cgImage?.cropping(to: rect) else { return }
        let output = NSBitmapImageRep(cgImage: image)
        if let clearCap {
            let context = NSGraphicsContext(bitmapImageRep: output)!
            NSGraphicsContext.current = context
            context.cgContext.setBlendMode(.clear)
            context.cgContext.fillEllipse(in: clearCap)
        }
        try output.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(resource)/\(name)"))
    }
}

func rect(_ value: CGRect) -> CGRect {
    CGRect(x: value.minX * scale, y: Double(height) - value.maxY * scale,
           width: value.width * scale, height: value.height * scale)
}

func withScaledPath(_ path: NSBezierPath, _ draw: (NSBezierPath) -> Void) {
    let context = NSGraphicsContext.current!.cgContext
    context.saveGState()
    context.concatenate(CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: 0, ty: Double(height)))
    draw(path)
    context.restoreGState()
}

func gradient(_ colors: [NSColor], _ path: NSBezierPath, angle: CGFloat = 0, radial: Bool = false) {
    guard let gradient = NSGradient(colors: colors) else { return }
    if radial {
        gradient.draw(in: path, relativeCenterPosition: NSPoint(x: 0.08, y: 0.12))
    } else {
        gradient.draw(in: path, angle: angle)
    }
}

let leftWell = CGRect(x: 83.87, y: 55.40, width: 86.77, height: 85.50)
let leftCap = CGRect(x: 103.56, y: 69.02, width: 49.37, height: 49.40)
let rightWell = CGRect(x: 265.56, y: 135.41, width: 76.17, height: 79.66)
let rightCap = CGRect(x: 273.22, y: 144.75, width: 59.71, height: 52.00)
let dpad = CGRect(x: 148.87, y: 130.52, width: 71.83, height: 75.39)
let guide = CGRect(x: 230.46, y: 33.47, width: 29.08, height: 35.97)
let faces: [(String, CGRect)] = [
    ("Y", CGRect(x: 345.69, y: 52.79, width: 31.51, height: 31.86)),
    ("B", CGRect(x: 375.48, y: 84.24, width: 32.42, height: 31.17)),
    ("A", CGRect(x: 344.01, y: 113.65, width: 33.14, height: 31.20)),
    ("X", CGRect(x: 314.08, y: 82.70, width: 30.99, height: 31.63)),
]
let back = CGRect(x: 190.72, y: 73.16, width: 32.58, height: 24.90)
let start = CGRect(x: 265.21, y: 73.60, width: 31.71, height: 24.15)

func drawWell(_ canvas: Canvas, _ well: CGRect, _ cap: CGRect, _ source: SourcePixels) {
    let outer = NSBezierPath(ovalIn: rect(well))
    let edge = source.sample(Int(well.minX + 2), Int(well.midY))
    let lower = source.sample(Int(well.midX), Int(well.maxY - 2))
    let gapX = (well.width - cap.width) / 2, gapY = (well.height - cap.height) / 2
    let blue = source.blueSample(well) ?? source.sample(Int(well.minX + gapX * 0.55), Int(well.midY))
    gradient([edge, blue], outer, radial: true)
    let inner = NSBezierPath(ovalIn: rect(well.insetBy(dx: gapX * 0.22, dy: gapY * 0.22)))
    gradient([lower, edge], inner, radial: true)
    lower.setStroke()
    outer.lineWidth = max(1, min(gapX, gapY) * 0.14 * scale)
    outer.stroke()
    let capShadow = source.sample(Int(cap.midX), Int(cap.maxY - 1))
    let capCenter = source.sample(Int(cap.midX), Int(cap.midY))
    let capPath = NSBezierPath(ovalIn: rect(cap))
    gradient([capCenter, capShadow], capPath, radial: true)
    capShadow.setStroke()
    capPath.lineWidth = 0.7 * scale
    capPath.stroke()
}

func drawButton(_ canvas: Canvas, label: String, region: CGRect, source: SourcePixels) {
    let center = CGPoint(x: region.midX, y: region.midY)
    let light = source.sample(Int(center.x - region.width * 0.16), Int(center.y - region.height * 0.2))
    let edge = source.sample(Int(center.x), Int(region.maxY - 2))
    let path = NSBezierPath(ovalIn: rect(region))
    gradient([light, edge], path, radial: true)
    edge.setStroke()
    path.lineWidth = 0.6 * scale
    path.stroke()
    let color = source.sample(Int(center.x), Int(center.y))
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: region.height * 0.45 * scale, weight: .medium),
        .foregroundColor: color,
    ]
    let text = NSString(string: label)
    let size = text.size(withAttributes: attributes)
    let bounds = rect(region)
    text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
}

func drawCross(_ canvas: Canvas, region: CGRect, source: SourcePixels) {
    let path = NSBezierPath()
    let points: [(CGFloat, CGFloat)] = [
        (0.3, 0), (0.7, 0), (0.7, 0.3), (1, 0.3), (1, 0.7), (0.7, 0.7),
        (0.7, 1), (0.3, 1), (0.3, 0.7), (0, 0.7), (0, 0.3), (0.3, 0.3),
    ]
    for (index, point) in points.enumerated() {
        let x = (region.minX + point.0 * region.width) * scale
        let y = Double(height) - (region.minY + point.1 * region.height) * scale
        if index == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    let light = source.sample(Int(region.midX), Int(region.midY))
    let edge = source.sample(Int(region.midX), Int(region.maxY - 2))
    gradient([light, edge], path, angle: -65)
    edge.setStroke()
    path.lineWidth = 0.8 * scale
    path.stroke()
}

func drawMenu(_ canvas: Canvas, region: CGRect, lines: Int, source: SourcePixels) {
    let bounds = rect(region)
    let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height * 0.25, yRadius: bounds.height * 0.25)
    let center = source.sample(Int(region.midX), Int(region.midY))
    let edge = source.sample(Int(region.midX), Int(region.maxY - 2))
    gradient([center, edge], path, angle: -80)
    edge.setStroke()
    path.lineWidth = 0.5 * scale
    path.stroke()
    center.setStroke()
    for line in 0..<lines {
        let y = bounds.midY + (CGFloat(line) - CGFloat(lines - 1) / 2) * bounds.height * 0.18
        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: bounds.minX + bounds.width * 0.22, y: y))
        rule.line(to: NSPoint(x: bounds.maxX - bounds.width * 0.22, y: y))
        rule.lineWidth = max(1, bounds.height * 0.08)
        rule.stroke()
    }
}

func drawLogo(_ canvas: Canvas, source: SourcePixels) {
    guard let cropped = source.image.cropping(to: guide.integral),
          let context = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8,
                                  bytesPerRow: cropped.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
    let pixels = context.data!.bindMemory(to: UInt8.self, capacity: cropped.width * cropped.height * 4)
    for index in stride(from: 0, to: cropped.width * cropped.height * 4, by: 4) {
        let luminance = (Double(pixels[index]) * 0.2126 + Double(pixels[index + 1]) * 0.7152 + Double(pixels[index + 2]) * 0.0722) / 255
        let alpha: UInt8 = luminance < 0.80 ? 255 : 0
        pixels[index] = 0; pixels[index + 1] = 0; pixels[index + 2] = 0; pixels[index + 3] = alpha
    }
    guard let mask = context.makeImage() else { return }
    for contour in ArtworkContour.paths(image: mask) {
        let context = NSGraphicsContext.current!.cgContext
        context.saveGState()
        context.concatenate(CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
                                              tx: guide.minX * scale, ty: Double(height) - guide.maxY * scale))
        (source.averageColor(guide, darkOnly: true) ?? source.sample(Int(guide.minX + 2), Int(guide.midY))).setFill()
        contour.fill()
        context.restoreGState()
    }
}

@main
struct DirewolfArtworkGenerator {
    static func main() throws {
        guard let source = SourcePixels(path: "\(resource)/direwolf4-reference.png") else {
            fatalError("Cannot read the official Direwolf 4 reference")
        }
        let canvas = Canvas(width: width, height: height)
canvas.draw {
    let bodyColor = source.averageColor(CGRect(x: 200, y: 40, width: 90, height: 50))!
    let middle = source.averageColor(CGRect(x: 200, y: 170, width: 90, height: 70))!
    let lower = source.averageColor(CGRect(x: 100, y: 220, width: 80, height: 60))!
    for contour in ArtworkContour.paths(image: source.image) {
        withScaledPath(contour) { gradient([bodyColor, middle, lower], $0, angle: -78) }
    }
    drawCross(canvas, region: dpad, source: source)
    for (label, region) in faces { drawButton(canvas, label: label, region: region, source: source) }
    drawMenu(canvas, region: back, lines: 2, source: source)
    drawMenu(canvas, region: start, lines: 3, source: source)
    drawLogo(canvas, source: source)
    drawWell(canvas, leftWell, leftCap, source)
    drawWell(canvas, rightWell, rightCap, source)
}
try canvas.write("direwolf4.png")
for (name, well, cap) in [("left", leftWell, leftCap), ("right", rightWell, rightCap)] {
    let bounds = CGRect(x: well.minX * scale, y: well.minY * scale,
                        width: well.width * scale, height: well.height * scale)
    try canvas.writeCrop("direwolf4-\(name)-stick.png", rect: bounds)
    let hole = CGRect(x: (cap.minX - well.minX) * scale,
                      y: (well.maxY - cap.maxY) * scale,
                      width: cap.width * scale, height: cap.height * scale)
    try canvas.writeCrop("direwolf4-well-\(name).png", rect: bounds, clearCap: hole)
}
        print("Generated Direwolf 4 assets at \(width)×\(height), with vector contours and 4× calibration")
    }
}
