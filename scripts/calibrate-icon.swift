// calibrate-icon.swift — 图标规范与全幅派生（可重复生成；契约由 scripts/test-icon-geometry.sh 固化）
// 用法：
//   swift scripts/calibrate-icon.swift normalize  --out <dir>
//   swift scripts/calibrate-icon.swift full-bleed --out <dir>
//   swift scripts/calibrate-icon.swift mask [--reference <预渲染png>] [--out <png>]
// 路径默认按脚本位置解析（与 make-icon.swift 同款），任意 cwd 调用结果一致。
//
// 背景（2026-11 图标返修，定量测量定案）：
//   - 用户原稿可见底板约 910–917px/1024 且垂直偏心 8px、角曲率与原生不同——四张运行时/
//     设置图稿必须规范到 1024 画布上的 824×824 参考轮廓（居中；系统 Finder/Mail bundle
//     icns 与原生瓦片均为 824/1024 尺寸锚点）。
//   - 掩膜 baseplate-mask-1024.png = 本机 Apple Music 原生显示瓦片的实际轮廓（用户点名
//     锚点）：macOS 27.3（26C5047e）NSWorkspace 以 1024 渲染 /System/Applications/
//     Music.app，Mail/Podcasts/App Store 交叉验证几何逐字节一致（平台瓦片常量）——
//     824×824 居中于 (100,100)，连续曲率（squircle）角，r/side 中位 0.26304。渲染带
//     ≤12% alpha 的外沿光晕（Liquid Glass 阴影），以 alpha≥128 二值化排除；瓦片边缘为
//     硬边（31→255 单像素跳变），AA 由 3×3 邻域覆盖率重建（0.5 交线不动）。
//     旧 PathBlender 掩膜（近圆弧 r/side≈0.2402）与独立审查测的 bundle icns 旧式图稿
//     （0.2286–0.2311，256px）都不是系统实际显示轮廓，已弃用。
//   - Icon Composer 输入必须全幅不透明：系统图标栈后面永远垫系统底板，带透明边距/圆角
//     的图稿直接编译会在 Stage Manager/侧边透出白圈。full-bleed 模式把 824 底板等比
//     放大到满幅（1024/824）、四角填底板色，系统负责最终原生圆角/尺寸。
import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let CANVAS = 1024
let REFERENCE_SIDE = 824.0
let NATIVE_TILE_APP = "/System/Applications/Music.app"

let args = CommandLine.arguments
let scriptDir = URL(fileURLWithPath: args[0]).absoluteURL.resolvingSymlinksInPath().deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent()
let originalsDir = repoRoot.appendingPathComponent("scripts/icon-assets/originals")
let defaultMaskURL = repoRoot.appendingPathComponent("scripts/icon-assets/baseplate-mask-1024.png")

let artworkNames = ["app-icon-day.png", "app-icon-night.png", "app-icon-mono-day.png", "app-icon-mono-night.png"]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("✗ calibrate-icon: \(message)\n").utf8))
    exit(1)
}

func option(_ name: String, default def: String? = nil) -> String? {
    if let i = args.firstIndex(of: name) {
        guard i + 1 < args.count else { fail("选项 \(name) 缺值") }
        return args[i + 1]
    }
    return def
}

// MARK: - 位图（premultipliedLast RGBA8888，sRGB；与 icon-geometry.swift 同一加载路径）

struct Bitmap {
    let width: Int, height: Int
    var px: [UInt8]
    subscript(x: Int, y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        let i = (y * width + x) * 4
        return (Double(px[i]), Double(px[i + 1]), Double(px[i + 2]), Double(px[i + 3]))
    }
}

func loadBitmap(_ path: String) -> Bitmap {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fail("无法解码图片：\(path)")
    }
    return bitmap(from: img, path: path)
}

func bitmap(from img: CGImage, path: String) -> Bitmap {
    guard img.width == CANVAS, img.height == CANVAS else {
        fail("必须是 \(CANVAS)×\(CANVAS)（当前 \(img.width)×\(img.height)）：\(path)")
    }
    guard let ctx = CGContext(data: nil, width: CANVAS, height: CANVAS, bitsPerComponent: 8, bytesPerRow: CANVAS * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("无法创建位图上下文：\(path)")
    }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: CANVAS, height: CANVAS))
    guard let buf = ctx.data else { fail("无法读取位图数据：\(path)") }
    return Bitmap(width: CANVAS, height: CANVAS,
                  px: [UInt8](UnsafeBufferPointer(start: buf.assumingMemoryBound(to: UInt8.self), count: CANVAS * CANVAS * 4)))
}

/// 渲染本机原生应用瓦片（Apple Music，用户点名锚点）为 1024 位图。
/// NSWorkspace 返回系统合成后的显示瓦片（Icon Composer 平台蒙版已应用）——
/// macOS 27.3 实测 Music/Mail/Podcasts/App Store 几何逐字节一致。
func renderNativeTile() -> Bitmap {
    let icon = NSWorkspace.shared.icon(forFile: NATIVE_TILE_APP)
    icon.size = NSSize(width: CANVAS, height: CANVAS)
    guard let tiff = icon.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff), rep.pixelsWide == CANVAS, rep.pixelsHigh == CANVAS,
          let cg = rep.cgImage else {
        fail("无法从 NSWorkspace 取得 \(NATIVE_TILE_APP) 的 \(CANVAS)px 原生瓦片渲染")
    }
    return bitmap(from: cg, path: "NSWorkspace:\(NATIVE_TILE_APP)@\(CANVAS)")
}

func savePNG(_ bm: Bitmap, to path: String) {
    let fm = FileManager.default
    try? fm.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let ctx = CGContext(data: nil, width: bm.width, height: bm.height, bitsPerComponent: 8, bytesPerRow: bm.width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("无法创建输出上下文：\(path)")
    }
    bm.px.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        ctx.data!.copyMemory(from: raw.baseAddress!, byteCount: bm.px.count)
    }
    guard let img = ctx.makeImage() else { fail("无法生成输出图像：\(path)") }
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("无法创建 PNG 写出目标：\(path)")
    }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { fail("写出 PNG 失败：\(path)") }
}

// MARK: - 几何与采样

func alphaBBox(_ bm: Bitmap, threshold: Int = 128) -> (x: Int, y: Int, w: Int, h: Int) {
    var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
    for y in 0..<bm.height {
        for x in 0..<bm.width where bm[x, y].a >= Double(threshold) {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    if minX == Int.max { fail("图稿全透明（alpha 包围盒为空）") }
    return (minX, minY, maxX - minX + 1, maxY - minY + 1)
}

/// 双线性采样（premultiplied 域插值，坐标越界钳到边缘）
func samplePremul(_ bm: Bitmap, _ x: Double, _ y: Double) -> (r: Double, g: Double, b: Double, a: Double) {
    let xf = max(0.0, min(Double(bm.width) - 1.001, x))
    let yf = max(0.0, min(Double(bm.height) - 1.001, y))
    let x0 = Int(xf), y0 = Int(yf)
    let tx = xf - Double(x0), ty = yf - Double(y0)
    let x1 = min(x0 + 1, bm.width - 1), y1 = min(y0 + 1, bm.height - 1)
    func mix(_ p: (r: Double, g: Double, b: Double, a: Double), _ q: (r: Double, g: Double, b: Double, a: Double), _ t: Double)
        -> (r: Double, g: Double, b: Double, a: Double) {
        (p.r + (q.r - p.r) * t, p.g + (q.g - p.g) * t, p.b + (q.b - p.b) * t, p.a + (q.a - p.a) * t)
    }
    let top = mix(bm[x0, y0], bm[x1, y0], tx)
    let bottom = mix(bm[x0, y1], bm[x1, y1], tx)
    return mix(top, bottom, ty)
}

/// 底板色：原稿 alpha 包围盒四边中点内缩 3% 处 5×5 采样块的中位数（边框纯色，实测均匀）
func baseplateColor(_ bm: Bitmap, _ bb: (x: Int, y: Int, w: Int, h: Int)) -> (r: Double, g: Double, b: Double) {
    let inset = max(2, max(bb.w, bb.h) * 3 / 100)
    let centers = [(bb.x + bb.w / 2, bb.y + inset), (bb.x + bb.w / 2, bb.y + bb.h - 1 - inset),
                   (bb.x + inset, bb.y + bb.h / 2), (bb.x + bb.w - 1 - inset, bb.y + bb.h / 2)]
    var rs: [Double] = [], gs: [Double] = [], bs: [Double] = []
    for (cx, cy) in centers {
        for dy in -2...2 {
            for dx in -2...2 {
                let x = max(0, min(bm.width - 1, cx + dx)), y = max(0, min(bm.height - 1, cy + dy))
                let p = bm[x, y]
                rs.append(p.r); gs.append(p.g); bs.append(p.b)
            }
        }
    }
    func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
    return (median(rs), median(gs), median(bs))
}

// MARK: - 派生管线

/// 原稿 → 规范稿：等比缩放使 alpha 包围盒最长边 = 824、包围盒中心对齐画布中心，
/// 底板色垫底（补齐掩膜角部与原图非正方形差），再乘参考掩膜（alpha 不超掩膜、
/// 角部连续圆角与参考一致）。输出为 1024 画布规范稿（straight 域描述见注释）。
func normalizeBitmap(original: Bitmap, mask: Bitmap) -> Bitmap {
    let bb = alphaBBox(original)
    let side = Double(max(bb.w, bb.h))
    let scale = REFERENCE_SIDE / side
    let cx = Double(bb.x) + Double(bb.w - 1) / 2   // 包围盒中心（源坐标）
    let cy = Double(bb.y) + Double(bb.h - 1) / 2
    let F = baseplateColor(original, bb)
    var out = Bitmap(width: CANVAS, height: CANVAS, px: [UInt8](repeating: 0, count: CANVAS * CANVAS * 4))
    for y in 0..<CANVAS {
        for x in 0..<CANVAS {
            let sx = (Double(x) + 0.5 - Double(CANVAS) / 2) / scale + cx
            let sy = (Double(y) + 0.5 - Double(CANVAS) / 2) / scale + cy
            let s = samplePremul(original, sx, sy)
            // premultiplied → straight
            let (R, G, B): (Double, Double, Double)
            if s.a <= 0 { (R, G, B) = (0, 0, 0) }
            else { (R, G, B) = (s.r * 255 / s.a, s.g * 255 / s.a, s.b * 255 / s.a) }
            // 原稿（straight alpha=s.a）垫在纯色底板上：RGB 混向底板色，不透明度补满
            let A = s.a / 255
            let mixR = R * A + F.r * (1 - A)
            let mixG = G * A + F.g * (1 - A)
            let mixB = B * A + F.b * (1 - A)
            // 乘参考掩膜：final alpha = 掩膜 alpha（底板已补满），RGB 直通
            let mA = mask[x, y].a
            let fa = mA
            let i = (y * CANVAS + x) * 4
            out.px[i]     = UInt8(max(0, min(255, (mixR * fa / 255).rounded())))
            out.px[i + 1] = UInt8(max(0, min(255, (mixG * fa / 255).rounded())))
            out.px[i + 2] = UInt8(max(0, min(255, (mixB * fa / 255).rounded())))
            out.px[i + 3] = UInt8(max(0, min(255, fa.rounded())))
        }
    }
    return out
}

/// 规范稿 → 全幅输入：以画布为中心放大 1024/824，底板色垫满全画布——输出全幅不透明，
/// 系统负责最终原生圆角/尺寸（Icon Composer 输入契约）。
func fullBleedBitmap(normalized: Bitmap, plate: (r: Double, g: Double, b: Double)) -> Bitmap {
    let k = Double(CANVAS) / REFERENCE_SIDE
    var out = Bitmap(width: CANVAS, height: CANVAS, px: [UInt8](repeating: 0, count: CANVAS * CANVAS * 4))
    for y in 0..<CANVAS {
        for x in 0..<CANVAS {
            let sx = (Double(x) + 0.5 - Double(CANVAS) / 2) / k + Double(CANVAS) / 2
            let sy = (Double(y) + 0.5 - Double(CANVAS) / 2) / k + Double(CANVAS) / 2
            let s = samplePremul(normalized, sx, sy)
            let A = s.a / 255
            let (R, G, B): (Double, Double, Double)
            if s.a <= 0 { (R, G, B) = (0, 0, 0) }
            else { (R, G, B) = (s.r * 255 / s.a, s.g * 255 / s.a, s.b * 255 / s.a) }
            let i = (y * CANVAS + x) * 4
            out.px[i]     = UInt8(max(0, min(255, (R * A + plate.r * (1 - A)).rounded())))
            out.px[i + 1] = UInt8(max(0, min(255, (G * A + plate.g * (1 - A)).rounded())))
            out.px[i + 2] = UInt8(max(0, min(255, (B * A + plate.b * (1 - A)).rounded())))
            out.px[i + 3] = 255
        }
    }
    return out
}

// MARK: - 模式

guard args.count > 1 else { fail("用法：calibrate-icon.swift normalize|full-bleed|mask [--out <路径>]") }
let mode = args[1]

if mode == "mask" {
    let outPath = option("--out", default: defaultMaskURL.path)!
    // 源：预渲染 PNG（--reference，跨机器复现用）或现场 NSWorkspace 渲染本机原生瓦片
    let tile = option("--reference").map { loadBitmap($0) } ?? renderNativeTile()
    // 二值化：alpha≥128 = 平台瓦片轮廓；排除外沿 ≤12% 的 Liquid Glass 光晕。
    // 原生边缘为硬边（单像素 31→255），AA 由 3×3 邻域覆盖率重建——0.5 交线不动，
    // 内缩剖面与 bbox 相对二值轮廓最多偏 1px（几何门容差内）
    var inside = [Bool](repeating: false, count: CANVAS * CANVAS)
    for p in 0..<CANVAS * CANVAS {
        inside[p] = tile.px[p * 4 + 3] >= 128
    }
    var mask = Bitmap(width: CANVAS, height: CANVAS, px: [UInt8](repeating: 0, count: CANVAS * CANVAS * 4))
    for y in 0..<CANVAS {
        for x in 0..<CANVAS {
            var hits = 0
            for dy in -1...1 {
                for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, nx < CANVAS, ny >= 0, ny < CANVAS, inside[ny * CANVAS + nx] { hits += 1 }
                }
            }
            let i = (y * CANVAS + x) * 4
            mask.px[i] = 255; mask.px[i + 1] = 255; mask.px[i + 2] = 255
            mask.px[i + 3] = UInt8((Double(hits) / 9.0 * 255.0).rounded())
        }
    }
    savePNG(mask, to: outPath)
    print("mask written: \(outPath)（源：\(option("--reference") ?? "NSWorkspace 渲染 \(NATIVE_TILE_APP)@\(CANVAS)（macOS 原生瓦片）")）")
} else if mode == "normalize" {
    guard let outDir = option("--out") else { fail("normalize 需要 --out <目录>") }
    let mask = loadBitmap(option("--mask", default: defaultMaskURL.path)!)
    for name in artworkNames {
        let original = loadBitmap(originalsDir.appendingPathComponent(name).path)
        savePNG(normalizeBitmap(original: original, mask: mask), to: URL(fileURLWithPath: outDir).appendingPathComponent(name).path)
    }
    print("normalized 4 artworks to \(outDir)")
} else if mode == "full-bleed" {
    guard let outDir = option("--out") else { fail("full-bleed 需要 --out <目录>") }
    let mask = loadBitmap(option("--mask", default: defaultMaskURL.path)!)
    for name in artworkNames {
        let original = loadBitmap(originalsDir.appendingPathComponent(name).path)
        let normalized = normalizeBitmap(original: original, mask: mask)
        let plate = baseplateColor(original, alphaBBox(original))
        let outName = name.replacingOccurrences(of: "app-icon-", with: "icon-")
        savePNG(fullBleedBitmap(normalized: normalized, plate: plate),
                to: URL(fileURLWithPath: outDir).appendingPathComponent(outName).path)
    }
    print("full-bleed inputs written to \(outDir)（icon-day.png / icon-night.png / icon-mono-day.png / icon-mono-night.png）")
} else {
    fail("未知模式：\(mode)")
}
