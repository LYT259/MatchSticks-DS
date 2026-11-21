import SwiftUI
import DSCore

struct GamepadArtworkHelp {
    var button: (Int?) -> String?
    var trigger: (UInt32?, Int?) -> String?
    var stick: (UInt32, UInt32, Int) -> String
    var dpad: String
}

struct GamepadArtworkOverlay: View {
    let spec: GamepadArtworkSpec
    let layout: GamepadLayout
    let state: GamepadElementState
    let help: GamepadArtworkHelp
    var skin: GamepadSkin

    var body: some View {
        GeometryReader { geometry in
            let container = geometry.size
            ZStack(alignment: .topLeading) {
                if let url = Bundle.module.url(forResource: spec.imageName, withExtension: "png"),
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .accessibilityHidden(true)
                } else {
                    Color.red
                        .accessibilityLabel(tr("手柄图片缺失：%@", spec.imageName))
                }

                stick(.leftStick, state: state.leftStick,
                      usage: (layout.stickUsage.lx, layout.stickUsage.ly), press: layout.stickPress.l, in: container)
                stick(.rightStick, state: state.rightStick,
                      usage: (layout.stickUsage.rx, layout.stickUsage.ry), press: layout.stickPress.r, in: container)

                ForEach(GamepadFace.allCases, id: \.self) { face in
                    region(faceRegion(face), pressed: state.face[face] ?? false,
                           help: help.button(layout.face[face]), shape: .circle, in: container)
                }
                ForEach(GamepadDirection.allCases, id: \.self) { direction in
                    if state.dpad.contains(direction) {
                        dpadHighlight(dpadRegion(direction, in: container), help: help.dpad, in: container)
                    }
                }

                region(.shoulderL, pressed: state.shoulderL,
                       help: help.button(layout.shoulder.l), shape: .rounded, in: container)
                region(.shoulderR, pressed: state.shoulderR,
                       help: help.button(layout.shoulder.r), shape: .rounded, in: container)
                trigger(.triggerL, state: state.triggerL,
                        help: help.trigger(layout.triggerUsage.lt, layout.triggerButton.l), in: container)
                trigger(.triggerR, state: state.triggerR,
                        help: help.trigger(layout.triggerUsage.rt, layout.triggerButton.r), in: container)

                region(.back, pressed: state.back, help: help.button(layout.back), shape: .rounded, in: container)
                region(.start, pressed: state.start, help: help.button(layout.start), shape: .rounded, in: container)
                region(.guide, pressed: state.guide, help: help.button(layout.guide), shape: .circle, in: container)
                region(.share, pressed: state.extras[.share] ?? false,
                       help: help.button(layout.extras[.share]), shape: .rounded, in: container)
                region(.touchpad, pressed: state.extras[.touchpad] ?? false,
                       help: help.button(layout.extras[.touchpad]), shape: .rounded, in: container)
                region(.backL, pressed: state.extras[.backL] ?? false,
                       help: help.button(layout.extras[.backL]), shape: .rounded, in: container)
                region(.backR, pressed: state.extras[.backR] ?? false,
                       help: help.button(layout.extras[.backR]), shape: .rounded, in: container)
            }
        }
        .aspectRatio(spec.referenceSize, contentMode: .fit)
    }

    @ViewBuilder private func stick(_ region: GamepadArtworkRegion, state: GamepadStickState,
                                    usage: (x: UInt32, y: UInt32), press: Int, in container: CGSize) -> some View {
        let capRegion: GamepadArtworkRegion = region == .leftStick ? .leftStickCap : .rightStickCap
        let well = spec.region(region, in: container)
        let cap = spec.region(capRegion, in: container)
        let light = skin == .direwolf4
        ZStack {
            Circle().fill(light ? Color(white: 0.78) : Color(white: 0.075))
            Circle().strokeBorder(light ? Color.white.opacity(0.45) : Color.white.opacity(0.18), lineWidth: 2)
        }
        .frame(width: well.width, height: well.height)
        .position(x: well.midX, y: well.midY)

        ZStack {
            Circle().fill(state.pressed ? Color.accentColor : (light ? Color(white: 0.86) : Color(white: 0.16)))
            Circle().strokeBorder(state.pressed ? Color.white : Color.black.opacity(0.45), lineWidth: 1.5)
            Circle().strokeBorder(light ? Color.white.opacity(0.55) : Color.white.opacity(0.14), lineWidth: 5)
        }
        .frame(width: cap.width, height: cap.height)
        .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
        .position(x: cap.midX, y: cap.midY)
        .offset(spec.stickCapOffset(for: region, state: state, in: container))
        .help(help.stick(usage.x, usage.y, press))
        .accessibilityElement()
        .accessibilityLabel(region == .leftStick ? tr("左摇杆") : tr("右摇杆"))
        .accessibilityValue(state.pressed ? tr("已按下") : tr("X %+.2f，Y %+.2f", state.x, state.yUp))
    }

    private func trigger(_ region: GamepadArtworkRegion,
                                      state: GamepadTriggerState, help text: String?, in container: CGSize) -> some View {
        let rect = spec.region(region, in: container)
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 7)
                .stroke(state.pressed ? Color.accentColor : Color.clear, lineWidth: 3)
            if let depth = state.depth {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor.opacity(0.28))
                    .frame(height: rect.height * CGFloat(depth))
            } else if state.pressed {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor.opacity(0.28))
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .modifier(ArtworkHelpAttachment(text: text))
    }

    private func region(_ region: GamepadArtworkRegion, pressed: Bool,
                                     help text: String?, shape: ArtworkRegionShape, in container: CGSize) -> some View {
        let rect = spec.region(region, in: container)
        return ArtworkRegionHighlight(pressed: pressed, shape: shape)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .modifier(ArtworkHelpAttachment(text: text))
    }

    private func dpadHighlight(_ rect: CGRect, help text: String?, in container: CGSize) -> some View {
        ArtworkRegionHighlight(pressed: true, shape: .rounded)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .modifier(ArtworkHelpAttachment(text: text))
    }

    private func faceRegion(_ face: GamepadFace) -> GamepadArtworkRegion {
        switch face {
        case .north: return .faceNorth
        case .east: return .faceEast
        case .south: return .faceSouth
        case .west: return .faceWest
        }
    }

    private func dpadRegion(_ direction: GamepadDirection, in container: CGSize) -> CGRect {
        let rect = spec.region(.dpad, in: container)
        switch direction {
        case .up:
            return CGRect(x: rect.midX - rect.width / 4, y: rect.minY,
                          width: rect.width / 2, height: rect.height / 2)
        case .down:
            return CGRect(x: rect.midX - rect.width / 4, y: rect.midY,
                          width: rect.width / 2, height: rect.height / 2)
        case .left:
            return CGRect(x: rect.minX, y: rect.midY - rect.height / 4,
                          width: rect.width / 2, height: rect.height / 2)
        case .right:
            return CGRect(x: rect.midX, y: rect.midY - rect.height / 4,
                          width: rect.width / 2, height: rect.height / 2)
        }
    }
}

private enum ArtworkRegionShape {
    case circle, rounded
}

private struct ArtworkRegionHighlight: View {
    let pressed: Bool
    let shape: ArtworkRegionShape

    var body: some View {
        if shape == .circle {
            Circle()
                .fill(Color.accentColor.opacity(pressed ? 0.32 : 0))
                .overlay(Circle().strokeBorder(Color.accentColor.opacity(pressed ? 1 : 0), lineWidth: 3))
                .shadow(color: Color.accentColor.opacity(pressed ? 0.65 : 0), radius: 5)
        } else {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.accentColor.opacity(pressed ? 0.30 : 0))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.accentColor.opacity(pressed ? 1 : 0), lineWidth: 3))
                .shadow(color: Color.accentColor.opacity(pressed ? 0.65 : 0), radius: 5)
        }
    }
}

private struct ArtworkHelpAttachment: ViewModifier {
    let text: String?
    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}
