import SwiftUI
import DSCore

struct GamepadSkinView: View {
    let skin: GamepadSkin
    var layoutSkin: GamepadSkin? = nil
    var mode: GamepadInputMode = .directInput
    let state: GamepadElementState

    private var layout: GamepadLayout { GamepadLayout.layout(for: layoutSkin ?? skin, mode: mode) }

    var body: some View {
        GamepadArtworkOverlay(
            spec: GamepadArtworkCatalog.spec(for: skin), layout: layout, state: state,
            help: GamepadArtworkHelp(
                button: { self.buttonHelp($0) },
                trigger: { self.triggerHelp(triggerUsage: $0, button: $1) },
                stick: { self.stickHelp(lx: $0, ly: $1, press: $2) },
                dpad: dpadHelp),
            skin: skin)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("手柄造型 · %@", skin.displayName))
    }

    private func buttonHelp(_ number: Int?) -> String? {
        number.map { tr("按键 %d", $0) }
    }
    private func buttonHelp(_ number: Int) -> String { tr("按键 %d", number) }

    private func triggerHelp(triggerUsage: UInt32?, button: Int?) -> String? {
        if let triggerUsage, let name = GamepadSkinView.axisName(triggerUsage) {
            return tr("扳机 · 轴 %@", name)
        }
        return button.map { tr("按键 %d", $0) }
    }

    private func stickHelp(lx: UInt32, ly: UInt32?, press: Int?) -> String {
        let xName = GamepadSkinView.axisName(lx) ?? "?"
        let yName = GamepadSkinView.axisName(ly) ?? "?"
        if let press { return tr("摇杆 · 轴 %@/%@ · 按下为按键 %d", xName, yName, press) }
        return tr("摇杆 · 轴 %@/%@", xName, yName)
    }

    private var dpadHelp: String {
        if let pov = layout.dpadPOV { return tr("方向键 · POV %d", pov) }
        return tr("方向键")
    }

    static func axisName(_ usage: UInt32?) -> String? {
        guard let usage else { return nil }
        switch usage {
        case 0x30: return "X"
        case 0x31: return "Y"
        case 0x32: return "Z"
        case 0x33: return "Rx"
        case 0x34: return "Ry"
        case 0x35: return "Rz"
        case 0x36: return "Slider"
        case 0x37: return "Dial"
        case 0x38: return "Wheel"
        default: return nil
        }
    }
}

/// 实机图片按原始宽高比等比显示，保持原生纹理，不使用放大后的低清素材。
struct GamepadSkinScaled: View {
    let skin: GamepadSkin
    var layoutSkin: GamepadSkin? = nil
    var mode: GamepadInputMode = .directInput
    let state: GamepadElementState

    var body: some View {
        GamepadSkinView(skin: skin, layoutSkin: layoutSkin, mode: mode, state: state)
            .frame(maxWidth: 520, maxHeight: 332)
    }
}
