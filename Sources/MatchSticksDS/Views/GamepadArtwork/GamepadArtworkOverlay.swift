import SwiftUI
import DSCore

struct GamepadArtworkHelp {
    var button: (Int?) -> String?
    var trigger: (UInt32?, Int?) -> String?
    var stick: (UInt32, UInt32?, Int?) -> String
    var dpad: String
}

struct GamepadArtworkOverlay: View {
    let spec: GamepadArtworkSpec
    let layout: GamepadLayout
    let state: GamepadElementState
    let help: GamepadArtworkHelp
    var skin: GamepadSkin

    private var sourceImage: NSImage? { GamepadArtworkImageSource.image(named: spec.imageName) }
    private var playStation: Bool {
        [.dualshock4, .dualsense].contains(skin)
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let container = geometry.size
                ZStack(alignment: .topLeading) {
                    if spec.movingImageName != nil {
                        artworkImage(spec.imageName)
                        flightAssembly(in: container)
                        fixedFlightControls(in: container)
                    } else {
                        stick(.leftStick, state: state.leftStick,
                              usage: (layout.stickUsage.lx, layout.stickUsage.ly),
                              press: layout.stickPress.l, in: container)
                        stick(.rightStick, state: state.rightStick,
                              usage: (layout.stickUsage.rx, layout.stickUsage.ry),
                              press: layout.stickPress.r, in: container)
                        movingControls(in: container)
                        trigger(.triggerL, state: state.triggerL,
                                help: help.trigger(layout.triggerUsage.lt, layout.triggerButton.l), in: container)
                        fixedControls(in: container)
                    }
                }
                .frame(width: container.width, height: container.height)
                .clipped()
            }
            .aspectRatio(spec.referenceSize, contentMode: .fit)
            shoulderControls
        }
    }

    @ViewBuilder private func artworkImage(_ name: String) -> some View {
        if let image = GamepadArtworkImageSource.image(named: name) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .accessibilityHidden(true)
        } else {
            Color.red
                .accessibilityLabel(tr("手柄图片缺失：%@", name))
        }
    }

    private func flightAssembly(in container: CGSize) -> some View {
        let pose = spec.flightPose(left: state.leftStick, twist: state.rightStick, in: container)
        let anchor = spec.flightAnchor(in: container)
        return ZStack(alignment: .topLeading) {
            if let name = spec.movingImageName { artworkImage(name) }
            movingControls(in: container)
            trigger(.triggerL, state: state.triggerL,
                    help: help.trigger(layout.triggerUsage.lt, layout.triggerButton.l), in: container)
            Color.clear
                .frame(width: 80, height: 80)
                .position(spec.flightPivot ?? .zero)
                .help(help.stick(layout.stickUsage.lx, layout.stickUsage.ly, layout.stickPress.l))
                .accessibilityElement()
                .accessibilityLabel(tr("主摇杆与 Z 扭转"))
                .accessibilityValue(tr("X %+.2f，Y %+.2f，Z %+.2f",
                                       state.leftStick.x, state.leftStick.yUp, state.rightStick.x))
        }
        .frame(width: container.width, height: container.height)
        .rotation3DEffect(.degrees(pose.pitch), axis: (x: 1, y: 0, z: 0), anchor: anchor)
        .rotation3DEffect(.degrees(pose.roll), axis: (x: 0, y: 1, z: 0), anchor: anchor)
        .rotationEffect(.degrees(pose.twist), anchor: anchor)
        .offset(pose.offset)
    }

    @ViewBuilder private func movingControls(in container: CGSize) -> some View {
        ForEach(GamepadFace.allCases, id: \.self) { face in
            region(faceRegion(face), pressed: state.face[face] ?? false,
                   help: help.button(layout.face[face]), shape: .ellipse, in: container)
        }
        ForEach(GamepadDirection.allCases, id: \.self) { direction in
            if state.dpad.contains(direction) {
                dpadHighlight(dpadRegion(direction, in: container), help: help.dpad)
            }
        }
    }

    @ViewBuilder private func fixedControls(in container: CGSize) -> some View {
        if spec.movingImageName == nil {
            trigger(.triggerR, state: state.triggerR,
                    help: help.trigger(layout.triggerUsage.rt, layout.triggerButton.r), in: container)
        }
        region(.back, pressed: state.back, help: help.button(layout.back), shape: .rounded, in: container)
        region(.start, pressed: state.start, help: help.button(layout.start), shape: .rounded, in: container)
        region(.guide, pressed: state.guide, help: help.button(layout.guide), shape: .ellipse, in: container)
        region(.share, pressed: state.extras[.share] ?? false,
               help: help.button(layout.extras[.share]), shape: .rounded, in: container)
        region(.touchpad, pressed: state.extras[.touchpad] ?? false,
               help: help.button(layout.extras[.touchpad]), shape: .rounded, in: container)
        region(.backL, pressed: state.extras[.backL] ?? false,
               help: help.button(layout.extras[.backL]), shape: .rounded, in: container)
        region(.backR, pressed: state.extras[.backR] ?? false,
               help: help.button(layout.extras[.backR]), shape: .rounded, in: container)
        region(.mode, pressed: false, help: nil, shape: .rounded, in: container)
        region(.modeLED, pressed: false, help: nil, shape: .ellipse, in: container)
    }

    @ViewBuilder private func fixedFlightControls(in container: CGSize) -> some View {
        region(.shoulderL, pressed: state.shoulderL,
               help: help.button(layout.shoulder.l), shape: .rounded, in: container)
        region(.shoulderR, pressed: state.shoulderR,
               help: help.button(layout.shoulder.r), shape: .rounded, in: container)
        trigger(.triggerR, state: state.triggerR,
                help: help.trigger(layout.triggerUsage.rt, layout.triggerButton.r), in: container)
        fixedControls(in: container)
    }

    @ViewBuilder private func stick(_ region: GamepadArtworkRegion, state: GamepadStickState,
                                    usage: (x: UInt32, y: UInt32?), press: Int?, in container: CGSize) -> some View {
        if let sourceImage {
            ThumbstickScene(spec: spec, region: region, state: state, container: container, sourceImage: sourceImage)
                .help(help.stick(usage.x, usage.y, press))
                .accessibilityElement()
                .accessibilityLabel(region == .leftStick ? tr("左摇杆") : tr("右摇杆"))
                .accessibilityValue(state.pressed ? tr("已按下") : tr("X %+.2f，Y %+.2f", state.x, state.yUp))
        } else {
            Color.red
                .accessibilityLabel(tr("手柄图片缺失：%@", spec.imageName))
        }
    }

    private var shoulderControls: some View {
        let flight = spec.movingImageName != nil
        return HStack(spacing: 12) {
            shoulderChip(flight ? "6" : (playStation ? "L1" : "LB"), pressed: state.shoulderL,
                         help: help.button(layout.shoulder.l))
            triggerChip(flight ? "1" : (playStation ? "L2" : "LT"), state: state.triggerL,
                        help: help.trigger(layout.triggerUsage.lt, layout.triggerButton.l))
            Spacer(minLength: 8)
            shoulderChip(flight ? "7" : (playStation ? "R1" : "RB"), pressed: state.shoulderR,
                         help: help.button(layout.shoulder.r))
            triggerChip(flight ? tr("油门") : (playStation ? "R2" : "RT"), state: state.triggerR,
                        help: help.trigger(layout.triggerUsage.rt, layout.triggerButton.r))
        }
        .frame(maxWidth: .infinity)
    }

    private func shoulderChip(_ label: String, pressed: Bool, help text: String?) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(pressed ? Color.white : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(pressed ? Color.accentColor : DSTheme.surface, in: RoundedRectangle(cornerRadius: 6))
            .modifier(ArtworkHelpAttachment(text: text))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(pressed ? tr("已按下") : tr("已松开"))
    }

    private func triggerChip(_ label: String, state: GamepadTriggerState, help text: String?) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption.weight(.semibold))
            if let depth = state.depth {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DSTheme.button)
                        Capsule()
                            .fill(DSTheme.accent)
                            .frame(width: geometry.size.width * CGFloat(min(1, max(0, depth))))
                    }
                }
                .frame(width: 56, height: 6)
                .clipShape(Capsule())
                Text(String(format: "%.2f", depth))
                    .font(.caption2.monospacedDigit())
            } else {
                Circle()
                    .fill(state.pressed ? Color.accentColor : Color.secondary)
                    .frame(width: 8, height: 8)
            }
        }
        .modifier(ArtworkHelpAttachment(text: text))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(state.depth.map { String(format: "%.2f", $0) } ?? (state.pressed ? tr("已按下") : tr("已松开")))
    }

    @ViewBuilder private func trigger(_ region: GamepadArtworkRegion,
                                      state: GamepadTriggerState, help text: String?, in container: CGSize) -> some View {
        let rect = spec.region(region, in: container)
        if !rect.isEmpty {
            ZStack(alignment: .bottom) {
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
    }

    @ViewBuilder private func region(_ region: GamepadArtworkRegion, pressed: Bool,
                                     help text: String?, shape: ArtworkRegionShape, in container: CGSize) -> some View {
        let rect = spec.region(region, in: container)
        if !rect.isEmpty {
            ArtworkRegionHighlight(pressed: pressed, shape: shape)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .modifier(ArtworkHelpAttachment(text: text))
        }
    }

    private func dpadHighlight(_ rect: CGRect, help text: String?) -> some View {
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
    case ellipse, rounded
}

private struct ArtworkRegionHighlight: View {
    let pressed: Bool
    let shape: ArtworkRegionShape

    var body: some View {
        if shape == .ellipse {
            Ellipse()
                .fill(Color.accentColor.opacity(pressed ? 0.32 : 0))
                .overlay(Ellipse().strokeBorder(Color.accentColor.opacity(pressed ? 1 : 0), lineWidth: 3))
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
