import SwiftUI
import DSCore

enum GamepadArtworkRegion: String {
    case leftStick, leftStickCap, rightStick, rightStickCap
    case dpad, faceNorth, faceEast, faceSouth, faceWest
    case shoulderL, shoulderR, triggerL, triggerR
    case back, start, guide, share, touchpad, backL, backR, mode, modeLED
}

struct GamepadArtworkSpec {
    let imageName: String
    let referenceSize: CGSize
    let regions: [GamepadArtworkRegion: CGRect]

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
        case .dualsense, .dualshock4, .dualshock3: return dualsense
        case .xboxSeries, .xboxOne, .xbox360: return xboxSeries
        case .f310: return f310
        case .extreme3DPro: return extreme3DPro
        case .direwolf4: return direwolf4
        case .generic: return GamepadArtworkSpec(imageName: "generic", referenceSize: .zero, regions: [:])
        }
    }

    private static let dualsense = GamepadArtworkSpec(
        imageName: "dualsense", referenceSize: CGSize(width: 1600, height: 900),
        regions: [
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
        imageName: "extreme3dpro", referenceSize: CGSize(width: 1510, height: 1112),
        regions: [
            .leftStick: CGRect(x: 300, y: 0, width: 400, height: 600),
            .leftStickCap: CGRect(x: 300, y: 0, width: 400, height: 600),
            .rightStick: CGRect(x: 300, y: 0, width: 400, height: 600),
            .rightStickCap: CGRect(x: 300, y: 0, width: 400, height: 600),
            .dpad: CGRect(x: 400, y: 120, width: 120, height: 140),
            .faceNorth: CGRect(x: 550, y: 160, width: 100, height: 90),
            .faceEast: CGRect(x: 490, y: 60, width: 90, height: 100),
            .faceSouth: CGRect(x: 360, y: 130, width: 80, height: 100),
            .faceWest: CGRect(x: 350, y: 40, width: 100, height: 100),
            .shoulderL: CGRect(x: 470, y: 790, width: 120, height: 60),
            .shoulderR: CGRect(x: 620, y: 790, width: 120, height: 60),
            .triggerL: CGRect(x: 350, y: 0, width: 140, height: 160),
            .triggerR: CGRect(x: 1120, y: 760, width: 120, height: 200),
            .back: CGRect(x: 750, y: 790, width: 120, height: 60),
            .start: CGRect(x: 450, y: 850, width: 120, height: 60),
            .guide: CGRect(x: 590, y: 850, width: 120, height: 60),
            .share: CGRect(x: 730, y: 850, width: 120, height: 60),
            .backR: CGRect(x: 1060, y: 800, width: 100, height: 100),
        ])

    private static let direwolf4 = GamepadArtworkSpec(
        imageName: "direwolf4", referenceSize: CGSize(width: 1600, height: 1000),
        regions: [
            .leftStick: CGRect(x: 360, y: 150, width: 170, height: 190),
            .leftStickCap: CGRect(x: 385, y: 170, width: 120, height: 130),
            .rightStick: CGRect(x: 745, y: 310, width: 185, height: 220),
            .rightStickCap: CGRect(x: 770, y: 335, width: 130, height: 145),
            .dpad: CGRect(x: 450, y: 340, width: 180, height: 185),
            .faceNorth: CGRect(x: 1000, y: 115, width: 100, height: 100),
            .faceEast: CGRect(x: 1070, y: 190, width: 100, height: 100),
            .faceSouth: CGRect(x: 965, y: 270, width: 100, height: 100),
            .faceWest: CGRect(x: 900, y: 190, width: 100, height: 100),
            .shoulderL: CGRect(x: 350, y: 50, width: 180, height: 70),
            .shoulderR: CGRect(x: 1030, y: 45, width: 180, height: 70),
            .triggerL: CGRect(x: 365, y: 35, width: 155, height: 60),
            .triggerR: CGRect(x: 1040, y: 30, width: 155, height: 60),
            .back: CGRect(x: 610, y: 180, width: 70, height: 65),
            .start: CGRect(x: 805, y: 180, width: 70, height: 65),
            .guide: CGRect(x: 720, y: 95, width: 100, height: 100),
            .backL: CGRect(x: 260, y: 760, width: 120, height: 110),
            .backR: CGRect(x: 1200, y: 760, width: 120, height: 110),
        ])
}
