import AppKit
import DSCore

func direwolfArtworkTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    let spec = GamepadArtworkCatalog.spec(for: .direwolf4)
    check(spec.referenceSize == CGSize(width: 1968, height: 1364),
          "冰原狼 4 使用原生 1968×1364 高清重建尺寸")
    let original: [GamepadArtworkRegion: CGRect] = [
        .leftStick: CGRect(x: 83.87, y: 55.40, width: 86.77, height: 85.50),
        .leftStickCap: CGRect(x: 103.56, y: 69.02, width: 49.37, height: 49.40),
        .rightStick: CGRect(x: 265.56, y: 135.41, width: 76.17, height: 79.66),
        .rightStickCap: CGRect(x: 273.22, y: 144.75, width: 59.71, height: 52.00),
        .dpad: CGRect(x: 148.87, y: 130.52, width: 71.83, height: 75.39),
        .faceNorth: CGRect(x: 345.69, y: 52.79, width: 31.51, height: 31.86),
        .faceEast: CGRect(x: 375.48, y: 84.24, width: 32.42, height: 31.17),
        .faceSouth: CGRect(x: 344.01, y: 113.65, width: 33.14, height: 31.20),
        .faceWest: CGRect(x: 314.08, y: 82.70, width: 30.99, height: 31.63),
        .back: CGRect(x: 190.72, y: 73.16, width: 32.58, height: 24.90),
        .start: CGRect(x: 265.21, y: 73.60, width: 31.71, height: 24.15),
        .guide: CGRect(x: 230.46, y: 33.47, width: 29.08, height: 35.97),
    ]
    for (region, rect) in original {
        let actual = spec.regions[region]
        check(actual != nil && abs(actual!.minX - rect.minX * 4) < 0.000001 &&
              abs(actual!.minY - rect.minY * 4) < 0.000001 &&
              abs(actual!.width - rect.width * 4) < 0.000001 &&
              abs(actual!.height - rect.height * 4) < 0.000001,
              "冰原狼 \(region.rawValue) 严格遵循原图的 4 倍仿射标定，实际 \(actual!)")
    }
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let generator = root.appendingPathComponent("scripts/render-direwolf4.swift")
    let source = (try? String(contentsOf: generator, encoding: .utf8)) ?? ""
    check(source.contains("NSGradient") && source.contains("ArtworkContour.paths"),
          "冰原狼使用原轮廓矢量与几何渐变重建，而不是放大位图")
    check(source.contains("a: scale") && source.contains("d: -scale"),
          "生成器使用明确的 4 倍标定矩阵")
    check(!source.contains("sourceImage.draw") && !source.contains("image.draw(in:"),
          "生成器没有把原始图片放大后冒充高清")

    guard let image = NSImage(contentsOf: root.appendingPathComponent(
        "Sources/MatchSticksDriverStaion/Resources/Gamepads/direwolf4.png"))?.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let data = image.dataProvider?.data else {
        check(false, "冰原狼高清资源可读取")
        return
    }
    check(image.width == 1968 && image.height == 1364, "冰原狼实际资源达到高清原生尺寸")
    let bytes = [UInt8](data as Data)
    for (x, y) in [(0, 0), (image.width - 1, 0), (0, image.height - 1), (image.width - 1, image.height - 1)] {
        check(bytes[y * image.bytesPerRow + x * 4 + 3] == 0, "冰原狼高清外壳四角透明，无白块")
    }
    for (name, region) in [("left-stick", GamepadArtworkRegion.leftStick),
                           ("right-stick", .rightStick), ("well-left", .leftStick), ("well-right", .rightStick)] {
        let url = root.appendingPathComponent("Sources/MatchSticksDriverStaion/Resources/Gamepads/direwolf4-\(name).png")
        guard let preview = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            check(false, "冰原狼独立 \(name) 资源存在")
            continue
        }
        let expected = spec.region(region, in: spec.referenceSize)
        check(CGSize(width: preview.width, height: preview.height) == expected.integral.size,
              "冰原狼 \(name) 保留 4 倍井口标定尺寸")
        if name.hasPrefix("well"), let cap = spec.regions[region == .leftStick ? .leftStickCap : .rightStickCap],
           let well = spec.regions[region], let data = preview.dataProvider?.data {
            let alpha = [UInt8](data as Data)
            let x = Int((cap.midX - well.minX).rounded()), y = Int((cap.midY - well.minY).rounded())
            check(alpha[y * preview.bytesPerRow + x * 4 + 3] == 0,
                  "冰原狼 \(name) 中央没有第二只静止帽顶")
        }
    }
}
