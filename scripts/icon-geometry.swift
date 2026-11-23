// icon-geometry.swift — 图标 alpha 轮廓定量测量（测试基础设施，非生成器）
// 用法：
//   swift scripts/icon-geometry.swift measure <png> [alphaThreshold=128]
//   swift scripts/icon-geometry.swift mask-diff <png> <maskPng>
// 输出 JSON（stdout），失败以非零码退出并报错到 stderr。
// measure：画布尺寸、alpha≥阈值包围盒、可见边长、中心偏移、不透明占比、四角内缩剖面
//          （相对包围盒左上角，按行取该行首个不透明像素的 x 内缩量；仅统计该行不透明
//           像素数 ≥ 行长 10% 的行，避免内部孤点干扰）。
// mask-diff：png 与掩膜逐像素比对——png alpha 超过掩膜 alpha 的最大超出量（掩膜乘法
//          语义下 png 任何像素不得比掩膜更不透明）、掩膜实心区 png 未铺满的比例、
//          两二值轮廓的 IoU。
import Foundation
import CoreGraphics
import ImageIO

struct RGBA {
    let width: Int, height: Int
    let data: [UInt8] // RGBA8888，premultipliedLast；alpha 通道不受预乘影响
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("✗ icon-geometry: \(message)\n").utf8))
    exit(1)
}

func loadRGBA(_ path: String) -> RGBA {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fail("无法解码图片：\(path)")
    }
    let w = img.width, h = img.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("无法创建位图上下文：\(path)")
    }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let buf = ctx.data else { fail("无法读取位图数据：\(path)") }
    return RGBA(width: w, height: h, data: [UInt8](UnsafeBufferPointer(start: buf.assumingMemoryBound(to: UInt8.self), count: w * h * 4)))
}

func alphaAt(_ px: RGBA, _ x: Int, _ y: Int) -> Int { Int(px.data[(y * px.width + x) * 4 + 3]) }

func jsonOut(_ dict: [String: Any]) {
    let order = sortedDict(dict)
    guard let data = try? JSONSerialization.data(withJSONObject: order, options: [.prettyPrinted, .sortedKeys]) else {
        fail("JSON 序列化失败")
    }
    print(String(data: data, encoding: .utf8)!)
}

// 数组值保持顺序：手工拼 JSON
func sortedDict(_ dict: [String: Any]) -> [String: Any] { dict }

let args = CommandLine.arguments
guard args.count >= 3 else {
    fail("用法：icon-geometry.swift measure <png> [threshold] | mask-diff <png> <maskPng>")
}
let mode = args[1]

if mode == "measure" {
    let px = loadRGBA(args[2])
    let threshold = args.count > 3 ? Int(args[3]) ?? 128 : 128
    var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
    for y in 0..<px.height {
        for x in 0..<px.width where alphaAt(px, x, y) >= threshold {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    if minX == Int.max { jsonOut(["canvas": "\(px.width)x\(px.height)", "alphaThreshold": threshold, "visible": false]); exit(0) }
    let spanX = maxX - minX + 1, spanY = maxY - minY + 1
    let cx = Double(minX + maxX) / 2 - Double(px.width - 1) / 2
    let cy = Double(minY + maxY) / 2 - Double(px.height - 1) / 2
    var opaque = 0
    for i in stride(from: 3, to: px.data.count, by: 4) where px.data[i] >= threshold { opaque += 1 }
    // 角内缩剖面：顶边以下 d 像素行，行首不透明像素相对包围盒左边的内缩量
    let side = max(spanX, spanY)
    let insets: [[String: Any]] = [2, 4, 8, 16, 32, 64, 96, 128].map { d in
        let y = minY + d
        guard y <= maxY else { return ["d": d, "inset": -1] }
        var rowOpaque = 0
        for x in minX...maxX where alphaAt(px, x, y) >= threshold { rowOpaque += 1 }
        guard rowOpaque * 10 >= spanX else { return ["d": d, "inset": -1] }
        var firstX = maxX
        for x in minX...maxX where alphaAt(px, x, y) >= threshold { firstX = x; break }
        return ["d": d, "inset": firstX - minX]
    }
    jsonOut([
        "canvas": "\(px.width)x\(px.height)",
        "alphaThreshold": threshold,
        "visible": true,
        "bbox": ["x": minX, "y": minY, "w": spanX, "h": spanY],
        "visibleSide": max(spanX, spanY),
        "centerOffsetPx": ["dx": (cx * 100).rounded() / 100, "dy": (cy * 100).rounded() / 100],
        "opaqueFraction": Double(opaque) / Double(px.width * px.height),
        "cornerInsetProfile": insets,
        "normalizedCornerInsetProfile": insets.map { e in
            ["d": e["d"] as! Int, "insetOverSide": (e["inset"] as! Int) < 0 ? -1.0 :
                (Double(e["inset"] as! Int) / Double(side) * 10000).rounded() / 10000]
        },
        // 圆角半径估计：每个剖面点按圆弧反解 r_d = (inset+d)+sqrt(2*inset*d)（由
        // inset = r - sqrt(r²-(r-d)²) 整理），取有效点（inset≥2）的中位数；连续曲率
        // （squircle）轮廓各点 r_d 随 d 递减，中位数给出稳定的可比估计
        "cornerRadiusProfile": insets.compactMap { e -> [String: Any]? in
            let d = e["d"] as! Int, ins = e["inset"] as! Int
            guard ins >= 2 else { return nil }
            let dd = Double(d), ii = Double(ins)
            let r = ii + dd + (2 * ii * dd).squareRoot()
            return ["d": d, "r": (r * 100).rounded() / 100, "rOverSide": (r / Double(side) * 100000).rounded() / 100000]
        },
        "cornerRadiusMedianROverSide": {
            let rs = insets.compactMap { e -> Double? in
                let d = e["d"] as! Int, ins = e["inset"] as! Int
                guard ins >= 2 else { return nil }
                let dd = Double(d), ii = Double(ins)
                return (ii + dd + (2 * ii * dd).squareRoot()) / Double(side)
            }
            guard !rs.isEmpty else { return -1.0 }
            return (rs.sorted()[rs.count / 2] * 100000).rounded() / 100000
        }(),
    ])
} else if mode == "mask-diff" {
    guard args.count >= 4 else { fail("mask-diff 需要 <png> <maskPng>") }
    let a = loadRGBA(args[2]), b = loadRGBA(args[3])
    guard a.width == b.width, a.height == b.height else {
        fail("尺寸不一致：\(args[2]) \(a.width)x\(a.height) vs \(args[3]) \(b.width)x\(b.height)")
    }
    var excess = 0           // png alpha 超过掩膜 alpha 的最大超出量（全像素）
    var uncovered = 0       // 掩膜实心（≥200）而 png 未铺满（<200）的像素数
    var maskSolid = 0
    var either = 0, both = 0 // IoU 统计（阈值 128）
    for i in stride(from: 3, to: a.data.count, by: 4) {
        let pa = Int(a.data[i]), ma = Int(b.data[i])
        if pa > ma + excess { excess = pa - ma }
        if ma >= 200 { maskSolid += 1; if pa < 200 { uncovered += 1 } }
        let pb = pa >= 128, mb = ma >= 128
        if pb || mb { either += 1 }
        if pb && mb { both += 1 }
    }
    jsonOut([
        "canvas": "\(a.width)x\(a.height)",
        "maxAlphaExcess": excess,
        "uncoveredInMaskFraction": maskSolid == 0 ? 1.0 : (Double(uncovered) / Double(maskSolid) * 1000000).rounded() / 1000000,
        "contourIoU": either == 0 ? 1.0 : (Double(both) / Double(either) * 1000000).rounded() / 1000000,
    ])
} else {
    fail("未知模式：\(mode)")
}
