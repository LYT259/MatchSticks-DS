import Foundation
import DSCore

/// One thumbstick measured from its calibrated outline in the artwork, in the
/// same units as that outline. The artwork is read as an orthographic photo taken
/// from the front, `cameraPitch` radians away from straight above, so the cap's
/// outline is its top ellipse plus the visible strip of its front side.
struct ThumbstickGeometry: Equatable {
    let capRadius: CGFloat
    let capDepth: CGFloat
    let cameraPitch: CGFloat
    let capThickness: CGFloat
    let stickHeight: CGFloat
    let pivot: CGPoint

    static let viewPitch: CGFloat = 20 * .pi / 180
    static let maxDeflection: CGFloat = 20 * .pi / 180

    static func resolve(cap: CGRect) -> ThumbstickGeometry? {
        guard cap.origin.x.isFinite, cap.origin.y.isFinite, cap.width.isFinite, cap.height.isFinite,
              cap.width > 0, cap.height > 0 else { return nil }
        let outline = cap.height / cap.width
        let pitch = viewPitch
        let radius = cap.width / 2
        let thickness = radius * 0.35
        let depth = radius * min(1.2, max(0.6, (outline - thickness * sin(pitch) / cap.width) / cos(pitch)))
        let height = radius * 1.25
        let topCentre = CGPoint(x: cap.midX, y: cap.minY + depth * cos(pitch))
        return ThumbstickGeometry(
            capRadius: radius, capDepth: depth, cameraPitch: pitch, capThickness: thickness,
            stickHeight: height,
            pivot: CGPoint(x: topCentre.x, y: topCentre.y + height * sin(pitch)))
    }
}

struct ThumbstickPose: Equatable {
    let pivot: CGPoint
    let tiltX: CGFloat
    let tiltY: CGFloat
    let travel: CGSize
    let capSize: CGSize
}

enum ThumbstickMotion {
    static func pose(cap: CGRect, state: GamepadStickState) -> ThumbstickPose {
        guard let geometry = ThumbstickGeometry.resolve(cap: cap) else {
            return ThumbstickPose(pivot: .zero, tiltX: 0, tiltY: 0, travel: .zero, capSize: .zero)
        }
        let x = state.x.isFinite ? min(1, max(-1, CGFloat(state.x))) : 0
        let y = state.yUp.isFinite ? min(1, max(-1, CGFloat(state.yUp))) : 0
        let magnitude = hypot(x, y)
        let gate = magnitude > 1 ? 1 / magnitude : 1
        let tiltX = -y * gate * ThumbstickGeometry.maxDeflection
        let tiltY = x * gate * ThumbstickGeometry.maxDeflection
        let height = geometry.stickHeight
        return ThumbstickPose(
            pivot: geometry.pivot,
            tiltX: tiltX,
            tiltY: tiltY,
            travel: CGSize(
                width: height * sin(tiltY),
                height: -height * (cos(tiltY) * sin(geometry.cameraPitch - tiltX) - sin(geometry.cameraPitch))),
            capSize: cap.size)
    }
}
