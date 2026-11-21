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
    let expected: [GamepadArtworkRegion: CGRect] = [
        .leftStick: CGRect(x: 568, y: 372, width: 148, height: 148),
        .leftStickCap: CGRect(x: 596, y: 400, width: 92, height: 92),
        .rightStick: CGRect(x: 884, y: 368, width: 148, height: 148),
        .rightStickCap: CGRect(x: 912, y: 400, width: 92, height: 92),
        .dpad: CGRect(x: 408, y: 220, width: 188, height: 188),
        .faceNorth: CGRect(x: 1064, y: 196, width: 92, height: 92),
        .faceEast: CGRect(x: 1136, y: 276, width: 92, height: 92),
        .faceSouth: CGRect(x: 1064, y: 352, width: 92, height: 92),
        .faceWest: CGRect(x: 988, y: 276, width: 92, height: 92),
        .shoulderL: CGRect(x: 435, y: 126, width: 130, height: 46),
        .shoulderR: CGRect(x: 1035, y: 126, width: 130, height: 46),
        .triggerL: CGRect(x: 435, y: 126, width: 130, height: 46),
        .triggerR: CGRect(x: 1035, y: 126, width: 130, height: 46),
        .back: CGRect(x: 540, y: 160, width: 60, height: 76),
        .start: CGRect(x: 988, y: 156, width: 60, height: 84),
        .guide: CGRect(x: 748, y: 396, width: 92, height: 92),
        .touchpad: CGRect(x: 604, y: 136, width: 380, height: 212),
    ]
    check(calibrated.regions == expected,
          "清晰无底座 DualSense 的控件标定与已验证的像素匹配一致")
}
