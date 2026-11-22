import SwiftUI
import DSCore

enum GamepadArtworkRegion: String {
    case leftStick, leftStickCap, rightStick, rightStickCap
    case dpad, faceNorth, faceEast, faceSouth, faceWest
    case shoulderL, shoulderR, triggerL, triggerR
    case back, start, guide, share, touchpad, backL, backR, mode, modeLED
}

struct FlightStickPose: Equatable {
    let pitch: Double
    let roll: Double
    let twist: Double
    let offset: CGSize
    static let zero = FlightStickPose(pitch: 0, roll: 0, twist: 0, offset: .zero)
}

struct GamepadArtworkSpec {
    let imageName: String
    let referenceSize: CGSize
    let regions: [GamepadArtworkRegion: CGRect]
    var movingImageName: String? = nil
    var flightPivot: CGPoint? = nil

    func flightPose(left: GamepadStickState, twist: GamepadStickState, in size: CGSize) -> FlightStickPose {
        func clamp(_ value: Float) -> CGFloat {
            value.isFinite ? min(1, max(-1, CGFloat(value))) : 0
        }
        let x = clamp(left.x), y = clamp(left.yUp)
        let scale = min(size.width / referenceSize.width, size.height / referenceSize.height)
        return FlightStickPose(
            pitch: Double(y * 7), roll: Double(x * 7), twist: Double(clamp(twist.x) * 16),
            offset: CGSize(width: x * 30 * scale, height: -y * 30 * scale))
    }

    func flightAnchor(in size: CGSize) -> UnitPoint {
        guard let flightPivot, size.width > 0, size.height > 0,
              referenceSize.width > 0, referenceSize.height > 0 else { return .center }
        let scale = min(size.width / referenceSize.width, size.height / referenceSize.height)
        return UnitPoint(
            x: ((size.width - referenceSize.width * scale) / 2 + flightPivot.x * scale) / size.width,
            y: ((size.height - referenceSize.height * scale) / 2 + flightPivot.y * scale) / size.height)
    }

    func region(_ region: GamepadArtworkRegion, in size: CGSize) -> CGRect {
        guard let source = regions[region], referenceSize.width > 0, referenceSize.height > 0 else {
            return .zero
        }
        let scale = min(size.width / referenceSize.width, size.height / referenceSize.height)
        let origin = CGPoint(
            x: (size.width - referenceSize.width * scale) / 2,
            y: (size.height - referenceSize.height * scale) / 2)
        return CGRect(
            x: origin.x + source.minX * scale,
            y: origin.y + source.minY * scale,
            width: source.width * scale,
            height: source.height * scale)
    }

    func stickCapOffset(for stick: GamepadArtworkRegion,
                        state: GamepadStickState, in size: CGSize) -> CGSize {
        let cap = stick == .leftStick ? GamepadArtworkRegion.leftStickCap : .rightStickCap
        let wellRect = region(stick, in: size)
        let capRect = region(cap, in: size)
        let travelX = max(0, (wellRect.width - capRect.width) / 2)
        let travelY = max(0, (wellRect.height - capRect.height) / 2)
        let x = min(1, max(-1, CGFloat(state.x.isFinite ? state.x : 0)))
        let yUp = min(1, max(-1, CGFloat(state.yUp.isFinite ? state.yUp : 0)))
        return CGSize(width: x * travelX, height: -yUp * travelY)
    }
}

enum GamepadArtworkCatalog {
    static func spec(for skin: GamepadSkin) -> GamepadArtworkSpec {
        switch skin {
        case .dualshock4: return dualshock4
        case .dualsense: return dualsense
        case .xboxSeries, .xboxOne, .xbox360: return xboxSeries
        case .f310, .generic: return f310
        case .extreme3DPro: return extreme3DPro
        case .direwolf4: return direwolf4
        }
    }

    private static let dualshock4 = GamepadArtworkSpec(
        imageName: "dualshock4", referenceSize: CGSize(width: 2344, height: 1524),
        regions: [
            .leftStick: CGRect(x: 542.56, y: 403.51, width: 442.58, height: 491.98),
            .leftStickCap: CGRect(x: 615.08, y: 511.28, width: 279.09, height: 261.32),
            .rightStick: CGRect(x: 1325.67, y: 438.50, width: 429.05, height: 422),
            .rightStickCap: CGRect(x: 1386.34, y: 502.24, width: 294.61, height: 279.41),
            .dpad: CGRect(x: 213.36, y: 95.12, width: 436.49, height: 457.25),
            .faceNorth: CGRect(x: 1782.10, y: 95.63, width: 188.95, height: 166.06),
            .faceEast: CGRect(x: 1978.07, y: 253.25, width: 210.20, height: 190.41),
            .faceSouth: CGRect(x: 1799.20, y: 438.42, width: 191.05, height: 159.13),
            .faceWest: CGRect(x: 1647.48, y: 251.94, width: 193.71, height: 180.45),
            .back: CGRect(x: 652.74, y: 69.75, width: 79.10, height: 130.16),
            .start: CGRect(x: 1600.33, y: 85.53, width: 81.47, height: 115.10),
            .guide: CGRect(x: 1104.01, y: 627.12, width: 132, height: 126.97),
            .touchpad: CGRect(x: 788, y: 58, width: 770, height: 367),
        ])

    private static let dualsense = GamepadArtworkSpec(
        imageName: "dualsense", referenceSize: CGSize(width: 1192, height: 848),
        regions: [
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
        ])

    private static let xboxSeries = GamepadArtworkSpec(
        imageName: "xbox-series", referenceSize: CGSize(width: 1023, height: 736),
        regions: [
            .leftStick: CGRect(x: 190, y: 135, width: 140, height: 145),
            .leftStickCap: CGRect(x: 215, y: 160, width: 90, height: 90),
            .rightStick: CGRect(x: 565, y: 290, width: 145, height: 150),
            .rightStickCap: CGRect(x: 590, y: 315, width: 95, height: 95),
            .dpad: CGRect(x: 310, y: 295, width: 145, height: 150),
            .faceNorth: CGRect(x: 705, y: 115, width: 75, height: 75),
            .faceEast: CGRect(x: 775, y: 190, width: 75, height: 75),
            .faceSouth: CGRect(x: 705, y: 255, width: 75, height: 75),
            .faceWest: CGRect(x: 640, y: 190, width: 75, height: 75),
            .shoulderL: CGRect(x: 190, y: 45, width: 135, height: 60),
            .shoulderR: CGRect(x: 700, y: 45, width: 135, height: 60),
            .triggerL: CGRect(x: 205, y: 30, width: 115, height: 55),
            .triggerR: CGRect(x: 700, y: 30, width: 115, height: 55),
            .back: CGRect(x: 415, y: 185, width: 55, height: 55),
            .start: CGRect(x: 550, y: 185, width: 60, height: 55),
            .guide: CGRect(x: 465, y: 75, width: 90, height: 90),
            .share: CGRect(x: 480, y: 245, width: 60, height: 45),
        ])

    private static let f310 = GamepadArtworkSpec(
        imageName: "f310", referenceSize: CGSize(width: 755, height: 556),
        regions: [
            .leftStick: CGRect(x: 210, y: 290, width: 135, height: 140),
            .leftStickCap: CGRect(x: 230, y: 310, width: 95, height: 95),
            .rightStick: CGRect(x: 405, y: 290, width: 135, height: 140),
            .rightStickCap: CGRect(x: 425, y: 310, width: 95, height: 95),
            .dpad: CGRect(x: 110, y: 165, width: 145, height: 145),
            .faceNorth: CGRect(x: 540, y: 155, width: 75, height: 75),
            .faceEast: CGRect(x: 590, y: 210, width: 65, height: 70),
            .faceSouth: CGRect(x: 540, y: 260, width: 75, height: 75),
            .faceWest: CGRect(x: 490, y: 210, width: 75, height: 70),
            .shoulderL: CGRect(x: 120, y: 65, width: 120, height: 55),
            .shoulderR: CGRect(x: 515, y: 65, width: 120, height: 55),
            .triggerL: CGRect(x: 130, y: 55, width: 105, height: 50),
            .triggerR: CGRect(x: 520, y: 55, width: 105, height: 50),
            .back: CGRect(x: 285, y: 170, width: 50, height: 40),
            .start: CGRect(x: 425, y: 170, width: 50, height: 40),
            .guide: CGRect(x: 340, y: 185, width: 80, height: 65),
            .mode: CGRect(x: 300, y: 235, width: 45, height: 30),
            .modeLED: CGRect(x: 350, y: 255, width: 15, height: 15),
        ])

    private static let extreme3DPro = GamepadArtworkSpec(
        imageName: "extreme3dpro-base", referenceSize: CGSize(width: 1510, height: 1112),
        regions: [
            .dpad: CGRect(x: 724, y: 244, width: 80, height: 80),
            .faceNorth: CGRect(x: 816, y: 262, width: 43, height: 62),
            .faceEast: CGRect(x: 669, y: 264, width: 42, height: 61),
            .faceSouth: CGRect(x: 687, y: 322, width: 67, height: 86),
            .faceWest: CGRect(x: 774, y: 324, width: 67, height: 85),
            .shoulderL: CGRect(x: 552, y: 369, width: 64, height: 102),
            .shoulderR: CGRect(x: 477, y: 329, width: 73, height: 113),
            .triggerL: CGRect(x: 725, y: 39, width: 75, height: 38),
            .triggerR: CGRect(x: 589, y: 885, width: 169, height: 121),
            .back: CGRect(x: 539, y: 484, width: 60, height: 109),
            .start: CGRect(x: 475, y: 458, width: 56, height: 135),
            .guide: CGRect(x: 536, y: 616, width: 63, height: 105),
            .share: CGRect(x: 476, y: 615, width: 53, height: 127),
            .backR: CGRect(x: 930, y: 364, width: 67, height: 72),
        ],
        movingImageName: "extreme3dpro-handle", flightPivot: CGPoint(x: 797, y: 662))

    private static let direwolf4 = GamepadArtworkSpec(
        imageName: "direwolf4", referenceSize: CGSize(width: 913, height: 657),
        regions: [
            .leftStick: CGRect(x: 136, y: 77.31, width: 150.97, height: 150.75),
            .leftStickCap: CGRect(x: 143.13, y: 86.66, width: 96.69, height: 96.48),
            .rightStick: CGRect(x: 482.65, y: 207.85, width: 154.54, height: 162.51),
            .rightStickCap: CGRect(x: 487.79, y: 217.99, width: 105.86, height: 100.14),
            .dpad: CGRect(x: 221.26, y: 185.99, width: 159.75, height: 171.38),
            .faceNorth: CGRect(x: 641.32, y: 66.95, width: 69.06, height: 60.15),
            .faceEast: CGRect(x: 702.85, y: 120.22, width: 69.27, height: 67.10),
            .faceSouth: CGRect(x: 637.60, y: 171.37, width: 70.52, height: 71.80),
            .faceWest: CGRect(x: 576.03, y: 114.50, width: 70.12, height: 68),
            .back: CGRect(x: 338.34, y: 103.25, width: 53.46, height: 45.83),
            .start: CGRect(x: 479.10, y: 102.67, width: 57.98, height: 48.76),
            .guide: CGRect(x: 412.07, y: 36.97, width: 59.05, height: 68),
        ])
}

enum GamepadArtworkImageSource {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = GamepadSkin.allCases.count
        return cache
    }()

    static func image(named name: String) -> NSImage? {
        let key = name as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static func crop(_ image: CGImage, rect: CGRect) -> CGImage? {
        guard rect.width > 0, rect.height > 0, rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        return image.cropping(to: rect.integral)
    }
}
