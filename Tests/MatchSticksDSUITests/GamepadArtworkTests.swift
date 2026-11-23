import Foundation
import SwiftUI
import DSCore

func gamepadArtworkTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    let spec = GamepadArtworkSpec(
        imageName: "test", referenceSize: CGSize(width: 1200, height: 700),
        regions: [
            .leftStick: CGRect(x: 100, y: 50, width: 200, height: 100),
            .leftStickCap: CGRect(x: 150, y: 75, width: 50, height: 50),
        ])
    let container = CGSize(width: 600, height: 400)
    let mapped = spec.region(.leftStick, in: container)
    check(mapped == CGRect(x: 50, y: 50, width: 100, height: 50),
          "artwork 统一 aspect-fit 映射与纵向留白")

    let zero = ThumbstickMotion.pose(well: mapped, cap: spec.region(.leftStickCap, in: container),
                                     state: .init(x: 0, yUp: 0, pressed: false))
    check(zero.pivot == CGPoint(x: mapped.midX, y: mapped.midY) && zero.tiltX == 0 && zero.tiltY == 0,
          "artwork 三维摇杆零值严格回中且轴心固定")
    let moved = ThumbstickMotion.pose(well: mapped, cap: spec.region(.leftStickCap, in: container),
                                      state: .init(x: 2, yUp: -2, pressed: false))
    check(abs(moved.travel.width - 37.5 / sqrt(2)) < 0.0001 &&
          abs(moved.travel.height - 12.5 / sqrt(2)) < 0.0001,
          "artwork 三维摇杆斜向行程按井口归一化（得到 \(moved.travel)")

    check(GamepadArtworkCatalog.spec(for: .dualsense).imageName == "dualsense",
          "PS5 使用 DualSense 实机资源")
    let generationImages: [GamepadSkin: String] = [
        .dualshock4: "dualshock4", .dualsense: "dualsense", .direwolf4: "direwolf4",
    ]
    for (skin, imageName) in generationImages {
        check(GamepadArtworkCatalog.spec(for: skin).imageName == imageName,
              "\(skin.rawValue) 使用本世代独立实机资源")
    }
    check(GamepadArtworkCatalog.spec(for: .generic).imageName == "f310" &&
          GamepadArtworkCatalog.spec(for: .generic).regions == GamepadArtworkCatalog.spec(for: .f310).regions,
          "通用手柄复用 F310 外观与坐标，不改变映射")
    let ps4 = GamepadArtworkCatalog.spec(for: .dualshock4)
    check(ps4.referenceSize == CGSize(width: 967, height: 604), "PS4 使用干净的官方产品图及原生尺寸")
    check(abs((ps4.regions[.leftStickCap]?.midY ?? -1) - (ps4.regions[.rightStickCap]?.midY ?? 0)) <= 1,
          "PS4 对称布局的双摇杆中心应在同一水平线")
    let d4 = GamepadArtworkCatalog.spec(for: .direwolf4)
    check(d4.referenceSize == CGSize(width: 492, height: 341), "冰原狼 4 使用飞智配置软件中的原生正视素材")
    check((d4.regions[.rightStickCap]?.midY ?? 0) > (d4.regions[.leftStickCap]?.midY ?? 0) &&
          (d4.regions[.rightStickCap]?.midX ?? 0) > (d4.regions[.leftStickCap]?.midX ?? 0),
          "冰原狼 4 正视保留真实的非对称摇杆布局，不强行拉平")
    check(GamepadSkin.selectableSkins.filter { $0.rawValue.hasPrefix("xbox") } == [.xboxSeries] &&
          GamepadArtworkCatalog.spec(for: .xboxSeries).imageName == "xbox-series",
          "Xbox 只保留 Series，360 与 One 不再出现在支持列表")
    check(GamepadArtworkCatalog.spec(for: .f310).imageName == "f310" &&
          GamepadArtworkCatalog.spec(for: .extreme3DPro).imageName == "extreme3dpro-base",
          "罗技使用各自实机资源，Extreme 3D Pro 使用俯视底座资源")
    let flight = GamepadArtworkCatalog.spec(for: .extreme3DPro)
    check(flight.movingImageName == "extreme3dpro-handle" && flight.flightPivot != nil,
          "Extreme 杆身与固定底座分离，并围绕标定枢轴运动")
    let flightNeutral = flight.flightPose(left: .init(x: 0, yUp: 0, pressed: false),
                                          twist: .init(x: 0, yUp: 0, pressed: false), in: container)
    check(flightNeutral == .zero, "Extreme 中立姿态不偏移、不倾斜")
    check(flight.flightPivot == CGPoint(x: 765.5, y: 710),
          "Extreme 球关节使用座圈等宽轮廓标定的中心")
    let flightRight = flight.flightPose(left: .init(x: 1, yUp: 0, pressed: false),
                                        twist: .init(x: 1, yUp: 0, pressed: false), in: container)
    check(flightRight.roll > 0 && flightRight.twist > 0,
          "Extreme 杆身实际右倾，并使用独立 Z 轴扭转")
    let flightForward = flight.flightPose(left: .init(x: 0, yUp: 1, pressed: false),
                                          twist: .init(x: 0, yUp: 0, pressed: false), in: container)
    check(flightForward.pitch > 0, "Extreme 前后倾斜方向与屏幕一致")
    let flightInvalid = flight.flightPose(left: .init(x: .nan, yUp: .infinity, pressed: false),
                                          twist: .init(x: .infinity, yUp: 0, pressed: false), in: container)
    check(flightInvalid == .zero, "Extreme 异常轴值安全回中")

    let calibrated = GamepadArtworkCatalog.spec(for: .dualsense)
    check(calibrated.referenceSize == CGSize(width: 1192, height: 848),
          "DualSense 使用原生图片的透明边界裁切尺寸")
    let imageURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/MatchSticksDS/Resources/Gamepads/dualsense.png")
    let image = NSImage(contentsOf: imageURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    check(image?.width == 1192 && image?.height == 848,
          "DualSense 实际资源与标定参考尺寸一致")
    let expected: [GamepadArtworkRegion: CGRect] = [
        .leftStick: CGRect(x: 317.6, y: 311.4, width: 177.6, height: 177.6),
        .leftStickCap: CGRect(x: 351.2, y: 345, width: 110.4, height: 110.4),
        .rightStick: CGRect(x: 696.8, y: 306.6, width: 177.6, height: 177.6),
        .rightStickCap: CGRect(x: 730.4, y: 345, width: 110.4, height: 110.4),
        .dpad: CGRect(x: 125.6, y: 129, width: 225.6, height: 225.6),
        .faceNorth: CGRect(x: 918, y: 114, width: 76, height: 76),
        .faceEast: CGRect(x: 1003, y: 199, width: 76, height: 76),
        .faceSouth: CGRect(x: 918, y: 284, width: 76, height: 76),
        .faceWest: CGRect(x: 833, y: 199, width: 76, height: 76),
        .shoulderL: CGRect(x: 158, y: 16.2, width: 156, height: 55.2),
        .shoulderR: CGRect(x: 878, y: 16.2, width: 156, height: 55.2),
        .triggerL: CGRect(x: 158, y: 16.2, width: 156, height: 55.2),
        .triggerR: CGRect(x: 878, y: 16.2, width: 156, height: 55.2),
        .back: CGRect(x: 284, y: 57, width: 72, height: 91.2),
        .start: CGRect(x: 821.6, y: 52.2, width: 72, height: 100.8),
        .guide: CGRect(x: 533.6, y: 340.2, width: 110.4, height: 110.4),
        .touchpad: CGRect(x: 360.8, y: 28.2, width: 456, height: 254.4),
    ]
    check(calibrated.regions == expected,
          "原生 DualSense 裁切图的控件标定遵循已验证的仿射变换")

    guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                  bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        check(false, "原生摇杆贴图测试图可创建")
        return
    }
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    context.setFillColor(NSColor.red.cgColor)
    context.fill(CGRect(x: 10, y: 10, width: 16, height: 16))
    guard let source = context.makeImage(),
          let cropped = GamepadArtworkImageSource.crop(source, rect: CGRect(x: 10, y: 10, width: 16, height: 16)),
          let sourceData = source.dataProvider?.data,
          let cropData = cropped.dataProvider?.data else {
        check(false, "原生摇杆贴图可按标定裁剪")
        return
    }
    let sourceBytes = [UInt8](sourceData as Data), cropBytes = [UInt8](cropData as Data)
    check(cropped.width == 16 && cropped.height == 16, "摇杆贴图尺寸与标定一致")
    let sourceOffset = (10 * 64 + 10) * 4
    check(Array(sourceBytes[sourceOffset..<(sourceOffset + 4)]) == Array(cropBytes.prefix(4)),
          "摇杆帽裁剪保留原始像素，不使用纯色替代")

    let xboxURL = imageURL.deletingLastPathComponent().appendingPathComponent("xbox-series.png")
    guard let xbox = NSImage(contentsOf: xboxURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let xboxData = xbox.dataProvider?.data else {
        check(false, "Xbox 原生资源可读取")
        return
    }
    check(xbox.width == 1023 && xbox.height == 736, "Xbox 清理保持原生像素尺寸")
    let xboxBytes = [UInt8](xboxData as Data)
    for (x, y) in [(72, 680), (60, 690), (860, 700), (953, 695)] {
        let alpha = xboxBytes[(y * xbox.width + x) * 4 + 3]
        check(alpha == 0, "Xbox 握把外阴影 (原图 \(x), \(y)) 必须完全透明，当前 alpha \(alpha)")
    }

    for name in ["dualshock4", "direwolf4"] {
        guard let image = NSImage(contentsOf: imageURL.deletingLastPathComponent().appendingPathComponent("\(name).png"))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil), let data = image.dataProvider?.data else {
            check(false, "\(name) 原生透明度可读取")
            continue
        }
        let bytes = [UInt8](data as Data)
        for (x, y) in [(0, 0), (image.width - 1, 0), (0, image.height - 1), (image.width - 1, image.height - 1)] {
            check(bytes[(y * image.width + x) * 4 + 3] == 0, "\(name) 四角必须透明，不得残留白块 (\(x), \(y))")
        }
    }
    let faceNorth = d4.regions[.faceNorth] ?? .zero, faceSouth = d4.regions[.faceSouth] ?? .zero
    let faceWest = d4.regions[.faceWest] ?? .zero, faceEast = d4.regions[.faceEast] ?? .zero
    check(abs(faceNorth.midX - faceSouth.midX) <= 15 && abs(faceWest.midY - faceEast.midY) <= 15,
          "冰原狼 4 原生正视商品图的面键保持菱形几何")

    for skin in GamepadSkin.allCases {
        let artwork = GamepadArtworkCatalog.spec(for: skin)
        let names = [artwork.imageName] + (artwork.movingImageName.map { [$0] } ?? [])
        for name in names {
            let url = imageURL.deletingLastPathComponent().appendingPathComponent("\(name).png")
            guard let native = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                check(false, "\(skin.rawValue) 的图片 \(name).png 必须存在")
                continue
            }
            check(CGSize(width: native.width, height: native.height) == artwork.referenceSize,
                  "\(skin.rawValue) 的 \(name).png 原生像素必须与标定尺寸一致")
        }
    }

    let buildScript = try! String(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
    let resourceNames = Set(GamepadSkin.allCases.flatMap {
        let artwork = GamepadArtworkCatalog.spec(for: $0)
        return [artwork.imageName] + (artwork.movingImageName.map { [$0] } ?? [])
    })
    for name in resourceNames {
        check(buildScript.contains("\(name).png"), "打包脚本必须检查 \(name).png")
    }
    for name in ["playstation1", "dualshock2", "dualshock3", "direwolf1", "direwolf2", "direwolf3"] {
        check(!buildScript.contains("\(name).png"), "打包脚本不再引用已移除的 \(name).png")
        let removed = imageURL.deletingLastPathComponent().appendingPathComponent("\(name).png")
        check(!FileManager.default.fileExists(atPath: removed.path), "已移除型号不再遗留图片 \(name).png")
    }
}
