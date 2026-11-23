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
        case .xboxSeries: return xboxSeries
        case .f310, .generic: return f310
        case .extreme3DPro: return extreme3DPro
        case .direwolf4: return direwolf4
        }
    }

    private static let dualshock4 = GamepadArtworkSpec(
        imageName: "dualshock4", referenceSize: CGSize(width: 967, height: 604),
        regions: [
            .leftStick: CGRect(x: 243.20, y: 232.59, width: 173.60, height: 184.20),
            .leftStickCap: CGRect(x: 271.84, y: 260.17, width: 117.71, height: 109.04),
            .rightStick: CGRect(x: 547.43, y: 234.25, width: 177.25, height: 182.73),
            .rightStickCap: CGRect(x: 584.22, y: 259.91, width: 117.80, height: 109.53),
            .dpad: CGRect(x: 89.46, y: 86.55, width: 193.75, height: 183.05),
            .faceNorth: CGRect(x: 754.86, y: 78.28, width: 68.03, height: 63.10),
            .faceEast: CGRect(x: 829.47, y: 135.91, width: 55.00, height: 65.17),
            .faceSouth: CGRect(x: 751.95, y: 208.83, width: 68.19, height: 66.06),
            .faceWest: CGRect(x: 687.77, y: 136.81, width: 58.93, height: 62.59),
            .back: CGRect(x: 263.97, y: 45.82, width: 35.93, height: 60.11),
            .start: CGRect(x: 665.75, y: 45.05, width: 31.64, height: 55.49),
            .guide: CGRect(x: 458.59, y: 291.73, width: 50.14, height: 52.13),
            .touchpad: CGRect(x: 326, y: 31, width: 318, height: 182),
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
        imageName: "direwolf4", referenceSize: CGSize(width: 492, height: 341),
        regions: [
            .leftStick: CGRect(x: 83.87, y: 55.40, width: 86.77, height: 85.50),
            .leftStickCap: CGRect(x: 103.56, y: 69.02, width: 49.37, height: 49.40),
            .rightStick: CGRect(x: 265.56, y: 135.41, width: 76.17, height: 79.66),
            .rightStickCap: CGRect(x: 273.22, y: 144.75, width: 59.71, height: 52),
            .dpad: CGRect(x: 148.87, y: 130.52, width: 71.83, height: 75.39),
            .faceNorth: CGRect(x: 345.69, y: 52.79, width: 31.51, height: 31.86),
            .faceEast: CGRect(x: 375.48, y: 84.24, width: 32.42, height: 31.17),
            .faceSouth: CGRect(x: 344.01, y: 113.65, width: 33.14, height: 31.20),
            .faceWest: CGRect(x: 314.08, y: 82.70, width: 30.99, height: 31.63),
            .back: CGRect(x: 190.72, y: 73.16, width: 32.58, height: 24.90),
            .start: CGRect(x: 265.21, y: 73.60, width: 31.71, height: 24.15),
            .guide: CGRect(x: 230.46, y: 33.47, width: 29.08, height: 35.97),
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

    static func imageMaskingStickCaps(_ image: CGImage, capRegions: [CGRect]) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setBlendMode(.clear)
        for region in capRegions where region.origin.x.isFinite && region.origin.y.isFinite &&
            region.width.isFinite && region.height.isFinite && region.width > 0 && region.height > 0 {
            context.fillEllipse(in: CGRect(x: region.minX, y: CGFloat(height) - region.maxY,
                                           width: region.width, height: region.height))
        }
        return context.makeImage()
    }

    static func imageWithoutStickCaps(named name: String, capRegions: [CGRect]) -> NSImage? {
        let key = "\(name)#without-sticks-\(capRegions)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = image(named: name)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let base = imageWithoutStickCaps(source, capRegions: capRegions) else { return nil }
        let result = NSImage(cgImage: base, size: NSSize(width: base.width, height: base.height))
        cache.setObject(result, forKey: key)
        return result
    }

    static func imageWithoutStickCaps(_ image: CGImage, capRegions: [CGRect]) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let capacity = width * height * 4
        let original = Array(UnsafeBufferPointer(start: context.data!.bindMemory(to: UInt8.self, capacity: capacity), count: capacity))
        let output = context.data!.bindMemory(to: UInt8.self, capacity: capacity)
        for region in capRegions where region.width > 0 && region.height > 0 {
            let clearing = region.insetBy(dx: -region.width * 0.08, dy: -region.height * 0.08)
            let center = CGPoint(x: clearing.midX, y: clearing.midY)
            let radiusX = clearing.width / 2, radiusY = clearing.height / 2
            for y in max(0, Int(clearing.minY.rounded(.down)))...min(height - 1, Int(clearing.maxY.rounded(.up))) {
                for x in max(0, Int(clearing.minX.rounded(.down)))...min(width - 1, Int(clearing.maxX.rounded(.up))) {
                    let dx = (CGFloat(x) + 0.5 - center.x) / radiusX
                    let dy = (CGFloat(y) + 0.5 - center.y) / radiusY
                    guard dx * dx + dy * dy <= 1 else { continue }
                    let sourceX = Int((center.x + dx * radiusX * 1.2).rounded())
                    let sourceY = Int((center.y + dy * radiusY * 1.2).rounded())
                    let destination = (y * width + x) * 4
                    guard sourceX >= 0, sourceX < width, sourceY >= 0, sourceY < height else {
                        output[destination + 3] = 0
                        continue
                    }
                    let source = (sourceY * width + sourceX) * 4
                    for channel in 0..<4 { output[destination + channel] = original[source + channel] }
                }
            }
        }
        return context.makeImage()
    }

    static func crop(_ image: CGImage, rect: CGRect) -> CGImage? {
        guard rect.width > 0, rect.height > 0, rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        return image.cropping(to: rect.integral)
    }
}
