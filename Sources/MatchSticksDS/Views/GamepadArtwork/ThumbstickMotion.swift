import Foundation
import DSCore

struct ThumbstickPose: Equatable {
    let pivot: CGPoint
    let tiltX: CGFloat
    let tiltY: CGFloat
    let travel: CGSize
    let capSize: CGSize
}

enum ThumbstickMotion {
    static func pose(well: CGRect, cap: CGRect, state: GamepadStickState) -> ThumbstickPose {
        let pivot = CGPoint(x: well.midX, y: well.midY)
        guard well.origin.x.isFinite, well.origin.y.isFinite,
              well.width.isFinite, well.height.isFinite,
              cap.origin.x.isFinite, cap.origin.y.isFinite,
              cap.width.isFinite, cap.height.isFinite,
              well.width > 0, well.height > 0, cap.width > 0, cap.height > 0 else {
            return ThumbstickPose(pivot: pivot, tiltX: 0, tiltY: 0, travel: .zero, capSize: .zero)
        }
        let x = state.x.isFinite ? min(1, max(-1, CGFloat(state.x))) : 0
        let y = state.yUp.isFinite ? min(1, max(-1, CGFloat(state.yUp))) : 0
        let magnitude = hypot(x, y)
        let normalization = magnitude > 1 ? 1 / magnitude : 1
        let inputX = x * normalization
        let inputY = y * normalization
        let travelX = max(0, (well.width - cap.width) / 2)
        let travelY = max(0, (well.height - cap.height) / 2)
        let radius = cap.width / 2
        let angleX = asin(min(1, travelX / radius))
        let angleY = asin(min(1, travelY / radius))
        return ThumbstickPose(
            pivot: pivot,
            tiltX: -inputY * angleY,
            tiltY: inputX * angleX,
            travel: CGSize(width: inputX * travelX, height: -inputY * travelY),
            capSize: cap.size)
    }
}
