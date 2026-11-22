// MatchSticks DS 应用图标生成器（CoreGraphics 直绘，无外部依赖）
// 用法：swift scripts/make-icon.swift <输出目录>
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let S = 1024

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// 背景：深海军蓝，微弱对角渐变
let bgColors = [CGColor(srgbRed: 0.055, green: 0.086, blue: 0.153, alpha: 1),
                CGColor(srgbRed: 0.024, green: 0.035, blue: 0.070, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(S)), end: CGPoint(x: CGFloat(S), y: 0), options: [])

// 信号弧线（驾驶台遥测意象）：三段同心弧，绿色渐淡
let center = CGPoint(x: CGFloat(S) / 2, y: CGFloat(S) / 2 + 60)
for (radius, alpha, width) in [(300.0, 0.95, 64.0), (420.0, 0.55, 48.0), (540.0, 0.28, 36.0)] {
    ctx.setStrokeColor(CGColor(srgbRed: 0.20, green: 0.86, blue: 0.45, alpha: alpha))
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: radius, startAngle: .pi * 1.18, endAngle: .pi * 1.82, clockwise: false)
    ctx.strokePath()
}

// 中心节点：绿色实心圆
ctx.setFillColor(CGColor(srgbRed: 0.20, green: 0.86, blue: 0.45, alpha: 1))
ctx.fillEllipse(in: CGRect(x: center.x - 90, y: center.y - 90, width: 180, height: 180))

// 底部字标 "MATCHSTICKS DS"
let font = CTFontCreateWithName("SFProDisplay-Bold" as CFString, 88, nil)
let attrs: [CFString: Any] = [
    kCTFontAttributeName: font,
    kCTForegroundColorAttributeName: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92),
]
let attrStr = CFAttributedStringCreate(nil, "MATCHSTICKS DS" as CFString, attrs as CFDictionary)!
let line = CTLineCreateWithAttributedString(attrStr)
let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
ctx.textPosition = CGPoint(x: (CGFloat(S) - bounds.width) / 2, y: 120)
CTLineDraw(line, ctx)

let image = ctx.makeImage()!

// 多尺寸 iconset
let iconset = URL(fileURLWithPath: "\(outDir)/AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let dest = CGImageDestinationCreateWithURL(iconset.appendingPathComponent("icon_512x512@2x.png") as CFURL,
                                           UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)

// 缩放出其他尺寸
for (name, side) in [("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32),
                     ("icon_32x32@2x.png", 64), ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
                     ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512), ("icon_512x512.png", 512)] {
    let scaled = ctx.makeImage()!
    let w = side, h = side
    let sctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                         space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    sctx.interpolationQuality = .high
    sctx.draw(scaled, in: CGRect(x: 0, y: 0, width: w, height: h))
    let small = sctx.makeImage()!
    let d = CGImageDestinationCreateWithURL(iconset.appendingPathComponent(name) as CFURL,
                                            UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, small, nil)
    CGImageDestinationFinalize(d)
}
print("iconset written to \(iconset.path)")
