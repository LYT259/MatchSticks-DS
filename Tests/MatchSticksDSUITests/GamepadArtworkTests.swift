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

    let zero = spec.stickCapOffset(for: .leftStick, state: .init(x: 0, yUp: 0, pressed: false), in: container)
    check(zero == .zero, "artwork 摇杆零值严格回中")
    let moved = spec.stickCapOffset(for: .leftStick, state: .init(x: 2, yUp: -2, pressed: false), in: container)
    check(moved.width == 37.5 && moved.height == 12.5,
          "artwork 摇杆行程按井帽差值钳制且不拉伸（得到 \(moved)")

    check(GamepadArtworkCatalog.spec(for: .dualsense).imageName == "dualsense",
          "PS5 使用 DualSense 实机资源")
    check(GamepadArtworkCatalog.spec(for: .dualshock4).imageName == "dualsense" &&
          GamepadArtworkCatalog.spec(for: .dualshock3).imageName == "dualsense",
          "PS 全系列统一使用 PS5 实机资源")
    check(GamepadArtworkCatalog.spec(for: .xbox360).imageName == "xbox-series" &&
          GamepadArtworkCatalog.spec(for: .xboxOne).imageName == "xbox-series" &&
          GamepadArtworkCatalog.spec(for: .xboxSeries).imageName == "xbox-series",
          "Xbox 全系列统一使用 Series 实机资源")
    check(GamepadArtworkCatalog.spec(for: .f310).imageName == "f310" &&
          GamepadArtworkCatalog.spec(for: .direwolf4).imageName == "direwolf4" &&
          GamepadArtworkCatalog.spec(for: .extreme3DPro).imageName == "extreme3dpro",
          "罗技与冰原狼使用各自实机资源，Extreme 3D Pro 使用飞行摇杆资源")

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
        .faceNorth: CGRect(x: 912.8, y: 100.2, width: 110.4, height: 110.4),
        .faceEast: CGRect(x: 999.2, y: 196.2, width: 110.4, height: 110.4),
        .faceSouth: CGRect(x: 912.8, y: 287.4, width: 110.4, height: 110.4),
        .faceWest: CGRect(x: 821.6, y: 196.2, width: 110.4, height: 110.4),
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
}
