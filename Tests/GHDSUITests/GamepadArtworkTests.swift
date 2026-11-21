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
          GamepadArtworkCatalog.spec(for: .direwolf4).imageName == "direwolf4",
          "罗技与冰原狼使用各自实机资源")
}
