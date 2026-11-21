import SwiftUI
import DSCore

// MARK: - 手柄造型皮肤：按下即点亮（呈现层，映射真值在 DSCore/GamepadProfile）
//
// PS / Xbox 按系列使用最新实机图片，F310 与冰原狼使用各自实机图片；
// 动态控件按 GamepadArtwork 标定覆盖。通用设备保留 360×220 矢量示意。

/// 单个可点亮按键面：圆 + 符号。
private struct FaceKey: View {
    let label: String
    let pressed: Bool
    let diameter: CGFloat
    var helpText: String? = nil

    var body: some View {
        ZStack {
            Circle()
                .fill(pressed ? Color.accentColor : DSTheme.surface)
            Circle().strokeBorder(DSTheme.line.opacity(pressed ? 0 : 0.7))
            Text(label)
                .font(.system(size: diameter * 0.42, weight: .semibold))
                .foregroundStyle(pressed ? Color.white : Color.secondary)
        }
        .frame(width: diameter, height: diameter)
        .modifier(HelpAttachment(text: helpText))
    }
}

/// 中央小胶囊键（Back/View/Create、Start/Menu/Options）。
private struct CenterPill: View {
    let label: String
    let pressed: Bool
    var helpText: String? = nil

    var body: some View {
        ZStack {
            Capsule()
                .fill(pressed ? Color.accentColor : DSTheme.surface)
            Capsule().strokeBorder(DSTheme.line.opacity(pressed ? 0 : 0.7))
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(pressed ? Color.white : Color.secondary)
        }
        .frame(width: 34, height: 14)
        .modifier(HelpAttachment(text: helpText))
    }
}

/// 中央圆键（Guide/PS）。
private struct GuideKey: View {
    let label: String
    let pressed: Bool
    var helpText: String? = nil

    var body: some View {
        FaceKey(label: label, pressed: pressed, diameter: 22, helpText: helpText)
    }
}

/// 肩键胶囊（LB/RB、L1/R1）。
private struct ShoulderKey: View {
    let label: String
    let pressed: Bool
    var helpText: String? = nil

    var body: some View {
        ZStack {
            Capsule()
                .fill(pressed ? Color.accentColor : DSTheme.surface)
            Capsule().strokeBorder(DSTheme.line.opacity(pressed ? 0 : 0.7))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(pressed ? Color.white : Color.secondary)
        }
        .frame(width: 40, height: 16)
        .modifier(HelpAttachment(text: helpText))
    }
}

/// 扳机：模拟量 = 左→右填充的量规；数字 = 整体开/关。
private struct TriggerGauge: View {
    let label: String
    let state: GamepadTriggerState
    var helpText: String? = nil

    var body: some View {
        let fraction: CGFloat = state.depth.map { CGFloat($0) } ?? (state.pressed ? 1 : 0)
        ZStack(alignment: .leading) {
            Capsule().fill(DSTheme.surface)
            GeometryReader { geo in
                Capsule()
                    .fill(Color.accentColor.opacity(state.pressed ? 0.55 : 0.28))
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
            .clipShape(Capsule())
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .padding(.leading, 9)
                Spacer()
            }
        }
        .frame(width: 54, height: 17)
        .overlay(Capsule().strokeBorder(state.pressed ? Color.accentColor.opacity(0.9) : DSTheme.line.opacity(0.7), lineWidth: state.pressed ? 1.4 : 1))
        .modifier(HelpAttachment(text: helpText))
    }
}

/// 摇杆：井 + 拇指帽（帽上点位随实际轴值移动；按下整帽点亮）。
private struct StickWell: View {
    let state: GamepadStickState
    var helpText: String? = nil
    private let wellRadius: CGFloat = 28
    private let capRadius: CGFloat = 14

    var body: some View {
        let travel = wellRadius - capRadius - 3
        // yUp 上为正 → 屏幕 y 取负
        let offsetX = CGFloat(state.x) * travel
        let offsetY = CGFloat(-state.yUp) * travel
        return ZStack {
            Circle().fill(DSTheme.canvas)
            Circle().strokeBorder(DSTheme.line.opacity(0.7))
            // 井内方向基线（细微，便于读位置）
            Circle().strokeBorder(DSTheme.line.opacity(0.25))
                .frame(width: wellRadius * 1.35, height: wellRadius * 1.35)
            Circle()
                .fill(state.pressed ? Color.accentColor : DSTheme.surface)
                .frame(width: capRadius * 2, height: capRadius * 2)
                .overlay(Circle().strokeBorder(state.pressed ? Color.clear : DSTheme.line.opacity(0.7), lineWidth: 1))
                .shadow(color: .black.opacity(state.pressed ? 0.25 : 0.12), radius: 1.5, y: 1)
                .offset(x: offsetX, y: offsetY)
        }
        .frame(width: wellRadius * 2, height: wellRadius * 2)
        .modifier(HelpAttachment(text: helpText))
    }
}

/// 十字形底座（单一路径：fill + stroke 无接缝）。
private struct PlusShape: Shape {
    var armLength: CGFloat  // 中心到臂端
    var armWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        // 纵臂 + 横臂（两矩形并入同一 Path，描边只在并集外沿）
        path.addRoundedRect(
            in: CGRect(x: c.x - armWidth / 2, y: c.y - armLength,
                       width: armWidth, height: armLength * 2),
            cornerSize: CGSize(width: armWidth / 2.6, height: armWidth / 2.6))
        path.addRoundedRect(
            in: CGRect(x: c.x - armLength, y: c.y - armWidth / 2,
                       width: armLength * 2, height: armWidth),
            cornerSize: CGSize(width: armWidth / 2.6, height: armWidth / 2.6))
        return path
    }
}

/// 十字方向键：十字底座 + 四臂端指示点（各方向独立点亮，支持斜向双亮）。
private struct DpadCross: View {
    let directions: Set<GamepadDirection>
    var helpText: String? = nil
    private let armLength: CGFloat = 19  // 中心到臂端
    private let armWidth: CGFloat = 14
    private let dotRadius: CGFloat = 4.5

    var body: some View {
        ZStack {
            PlusShape(armLength: armLength, armWidth: armWidth)
                .fill(DSTheme.surface)
                .overlay(PlusShape(armLength: armLength, armWidth: armWidth)
                    .stroke(DSTheme.line.opacity(0.75), lineWidth: 1))
            ForEach(GamepadDirection.allCases, id: \.self) { dir in
                Circle()
                    .fill(directions.contains(dir) ? Color.accentColor : DSTheme.line.opacity(0.5))
                    .frame(width: dotRadius * 2, height: dotRadius * 2)
                    .offset(offset(for: dir))
            }
        }
        .frame(width: armLength * 2 + 4, height: armLength * 2 + 4)
        .modifier(HelpAttachment(text: helpText))
    }

    private func offset(for dir: GamepadDirection) -> CGSize {
        let tip = armLength - dotRadius - 3  // 指示点贴臂端内侧
        switch dir {
        case .up: return CGSize(width: 0, height: -tip)
        case .down: return CGSize(width: 0, height: tip)
        case .left: return CGSize(width: -tip, height: 0)
        case .right: return CGSize(width: tip, height: 0)
        }
    }
}

/// 附加键芯片（背键 M1/M2、分享键等小件）。
private struct ExtraChip: View {
    let label: String
    let pressed: Bool
    var helpText: String? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(pressed ? Color.accentColor : DSTheme.surface)
            RoundedRectangle(cornerRadius: 6).strokeBorder(DSTheme.line.opacity(pressed ? 0 : 0.7))
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(pressed ? Color.white : Color.secondary)
        }
        .frame(width: 30, height: 15)
        .modifier(HelpAttachment(text: helpText))
    }
}

/// help 修饰的空实现（避免每个部件写两遍 if let）。
private struct HelpAttachment: ViewModifier {
    let text: String?
    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}

/// 手柄机身轮廓（单一路径：fill + stroke 干净出并集，替代多形状同色叠合）。
/// 设计稿 360×220 坐标系；非对称款与对称款只在握把张角上不同（元素布局决定观感差异）。
private struct GamepadBody: Shape {
    enum Kind { case asymmetric, symmetric }
    let kind: Kind

    func path(in rect: CGRect) -> Path {
        // 等比映射到实际 rect（设计稿宽高 360×220）
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 360 * rect.width, y: rect.minY + y / 220 * rect.height)
        }
        var path = Path()
        let grip: CGFloat = kind == .asymmetric ? 1 : 0.86  // 对称款握把收拢
        // 锚点（非对称款；X 中轴 = 180，左右镜像）
        let topL = p(122, 50), topR = p(238, 50)
        let shoulderL = p(64, 74), shoulderR = p(296, 74)
        let outerTopL = p(34, 128), outerTopR = p(326, 128)
        let outerBotL = p(40, 196), outerBotR = p(320, 196)
        let gripBotL = p(88, 204), gripBotR = p(272, 204)
        let innerBotL = p(116, 158), innerBotR = p(244, 158)
        let notchL = p(136, 168), notchR = p(224, 168)
        let center = p(180, 172)
        // 对称款：握把向内收
        func pinch(_ pt: CGPoint, toward center: CGPoint, amount: CGFloat) -> CGPoint {
            CGPoint(x: center.x + (pt.x - center.x) * amount, y: pt.y + (pt.y - center.y) * 0)
        }
        let gl = pinch(outerTopL, toward: .init(x: 180, y: 0), amount: grip)
        let gr = pinch(outerTopR, toward: .init(x: 180, y: 0), amount: grip)
        let bl = pinch(outerBotL, toward: .init(x: 180, y: 0), amount: grip)
        let br = pinch(outerBotR, toward: .init(x: 180, y: 0), amount: grip)
        let gbl = pinch(gripBotL, toward: .init(x: 180, y: 0), amount: 1 - (1 - grip) * 0.5)
        let gbr = pinch(gripBotR, toward: .init(x: 180, y: 0), amount: 1 - (1 - grip) * 0.5)

        path.move(to: topL)
        path.addQuadCurve(to: topR, control: p(180, 42))
        path.addQuadCurve(to: shoulderR, control: p(268, 50))
        path.addQuadCurve(to: gr, control: p(318, 92))
        path.addQuadCurve(to: br, control: p(334, 178))
        path.addQuadCurve(to: gbr, control: p(300, 212))
        path.addQuadCurve(to: innerBotR, control: p(258, 196))
        path.addQuadCurve(to: notchR, control: p(234, 152))
        path.addQuadCurve(to: center, control: p(200, 178))
        path.addQuadCurve(to: notchL, control: p(160, 178))
        path.addQuadCurve(to: innerBotL, control: p(126, 152))
        path.addQuadCurve(to: gbl, control: p(102, 196))
        path.addQuadCurve(to: bl, control: p(60, 212))
        path.addQuadCurve(to: gl, control: p(26, 178))
        path.addQuadCurve(to: shoulderL, control: p(42, 92))
        path.addQuadCurve(to: topL, control: p(92, 50))
        path.closeSubpath()
        return path
    }
}

// MARK: - 皮肤主视图

struct GamepadSkinView: View {
    let skin: GamepadSkin
    var layoutSkin: GamepadSkin? = nil
    var mode: GamepadInputMode = .directInput
    let state: GamepadElementState

    private var layout: GamepadLayout { GamepadLayout.layout(for: layoutSkin ?? skin, mode: mode) }

    var body: some View {
        ZStack {
            if skin == .generic {
                bodyPlate
                elements
            } else {
                GamepadArtworkOverlay(
                    spec: GamepadArtworkCatalog.spec(for: skin), layout: layout, state: state,
                    help: GamepadArtworkHelp(
                        button: { self.buttonHelp($0) },
                        trigger: { self.triggerHelp(triggerUsage: $0, button: $1) },
                        stick: { self.stickHelp(lx: $0, ly: $1, press: $2) },
                        dpad: dpadHelp),
                    skin: skin)
            }
        }
        .frame(width: skin == .generic ? 360 : nil, height: skin == .generic ? 220 : nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("手柄造型 · %@", skin.displayName))
    }

    // MARK: 机身底板

    @ViewBuilder private var bodyPlate: some View {
        // 单一路径机身：填充 + 描边（同色叠合无法描边，故用自定义 Shape）
        GamepadBody(kind: skin == .dualsense || skin == .dualshock4 || skin == .dualshock3 ? .symmetric : .asymmetric)
            .fill(DSTheme.canvas)
            .overlay(
                GamepadBody(kind: skin == .dualsense || skin == .dualshock4 || skin == .dualshock3 ? .symmetric : .asymmetric)
                    .stroke(DSTheme.line, lineWidth: 1.2))
    }

    // MARK: 元素布置（设计稿坐标）

    @ViewBuilder private var elements: some View {
        switch skin {
        case .f310, .extreme3DPro, .direwolf4, .xbox360, .xboxOne, .xboxSeries: asymmetricLayout
        case .dualsense, .dualshock4, .dualshock3: dualsenseLayout
        case .generic: genericLayout
        }
    }

    /// Xbox 系非对称布置（F310 / 冰原狼4 / Xbox Series 共用骨架，符号与附加键各异）。
    private var asymmetricLayout: some View {
        ZStack {
            // 肩键 + 扳机（顶缘量规）
            ShoulderKey(label: shoulderGlyphL, pressed: state.shoulderL, helpText: buttonHelp(layout.shoulder.l))
                .position(x: 92, y: 30)
            ShoulderKey(label: shoulderGlyphR, pressed: state.shoulderR, helpText: buttonHelp(layout.shoulder.r))
                .position(x: 268, y: 30)
            TriggerGauge(label: triggerGlyphL, state: state.triggerL, helpText: triggerHelp(triggerUsage: layout.triggerUsage.lt, button: layout.triggerButton.l))
                .position(x: 92, y: 12)
            TriggerGauge(label: triggerGlyphR, state: state.triggerR, helpText: triggerHelp(triggerUsage: layout.triggerUsage.rt, button: layout.triggerButton.r))
                .position(x: 268, y: 12)

            // 方向键（左上）
            DpadCross(directions: state.dpad, helpText: dpadHelp)
                .position(x: 106, y: 92)

            // 面键（右上）
            faceCluster.position(x: 254, y: 92)

            // 中央键
            if let backNumber = layout.back {
                CenterPill(label: backGlyph, pressed: state.back, helpText: buttonHelp(backNumber))
                    .position(x: 152, y: 74)
            }
            if let startNumber = layout.start {
                CenterPill(label: startGlyph, pressed: state.start, helpText: buttonHelp(startNumber))
                    .position(x: 203, y: 74)
            }
            if let guideNumber = layout.guide {
                GuideKey(label: guideGlyph, pressed: state.guide, helpText: buttonHelp(guideNumber))
                    .position(x: 180, y: 46)
            }
            if let shareNumber = layout.extras[.share] {
                ExtraChip(label: tr("分享"), pressed: state.extras[.share] ?? false, helpText: buttonHelp(shareNumber))
                    .position(x: 212, y: 44)
            }

            // 双摇杆（低位，Xbox 式左高右低）
            StickWell(state: state.leftStick, helpText: stickHelp(lx: layout.stickUsage.lx, ly: layout.stickUsage.ly, press: layout.stickPress.l))
                .position(x: 142, y: 150)
            StickWell(state: state.rightStick, helpText: stickHelp(lx: layout.stickUsage.rx, ly: layout.stickUsage.ry, press: layout.stickPress.r))
                .position(x: 218, y: 162)

            // 背键（冰原狼 M1/M2；其余款无表不画）
            if let m1 = layout.extras[.backL] {
                ExtraChip(label: "M1", pressed: state.extras[.backL] ?? false, helpText: buttonHelp(m1))
                    .position(x: 66, y: 200)
            }
            if let m2 = layout.extras[.backR] {
                ExtraChip(label: "M2", pressed: state.extras[.backR] ?? false, helpText: buttonHelp(m2))
                    .position(x: 294, y: 200)
            }
        }
    }

    /// DualSense 对称布置：触控板居中、左右摇杆下置。
    private var dualsenseLayout: some View {
        ZStack {
            ShoulderKey(label: "L1", pressed: state.shoulderL, helpText: buttonHelp(layout.shoulder.l))
                .position(x: 92, y: 30)
            ShoulderKey(label: "R1", pressed: state.shoulderR, helpText: buttonHelp(layout.shoulder.r))
                .position(x: 268, y: 30)
            TriggerGauge(label: "L2", state: state.triggerL, helpText: triggerHelp(triggerUsage: layout.triggerUsage.lt, button: layout.triggerButton.l))
                .position(x: 92, y: 12)
            TriggerGauge(label: "R2", state: state.triggerR, helpText: triggerHelp(triggerUsage: layout.triggerUsage.rt, button: layout.triggerButton.r))
                .position(x: 268, y: 12)

            // 触控板（DualShock 3 无此实体；最新 PS 皮肤默认显示）
            if skin != .dualshock3 {
                extraTouchpad.position(x: 180, y: 48)
            }

            DpadCross(directions: state.dpad, helpText: dpadHelp)
                .position(x: 102, y: 98)
            faceCluster.position(x: 256, y: 100)

            CenterPill(label: tr("创建"), pressed: state.back, helpText: buttonHelp(layout.back))
                .position(x: 142, y: 76)
            CenterPill(label: tr("选项"), pressed: state.start, helpText: buttonHelp(layout.start))
                .position(x: 218, y: 76)
            GuideKey(label: "PS", pressed: state.guide, helpText: buttonHelp(layout.guide))
                .position(x: 180, y: 106)

            StickWell(state: state.leftStick, helpText: stickHelp(lx: layout.stickUsage.lx, ly: layout.stickUsage.ly, press: layout.stickPress.l))
                .position(x: 146, y: 160)
            StickWell(state: state.rightStick, helpText: stickHelp(lx: layout.stickUsage.rx, ly: layout.stickUsage.ry, press: layout.stickPress.r))
                .position(x: 214, y: 160)
        }
    }

    private var extraTouchpad: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill((state.extras[.touchpad] ?? false) ? Color.accentColor : DSTheme.surface)
            RoundedRectangle(cornerRadius: 9).strokeBorder(DSTheme.line.opacity((state.extras[.touchpad] ?? false) ? 0 : 0.7))
        }
        .frame(width: 86, height: 32)
        .modifier(HelpAttachment(text: layout.extras[.touchpad].map { buttonHelp($0) }))
    }

    /// 通用造型：编号即符号，一切从惯例位。
    private var genericLayout: some View {
        ZStack {
            ShoulderKey(label: "5", pressed: state.shoulderL, helpText: buttonHelp(layout.shoulder.l))
                .position(x: 92, y: 30)
            ShoulderKey(label: "6", pressed: state.shoulderR, helpText: buttonHelp(layout.shoulder.r))
                .position(x: 268, y: 30)
            TriggerGauge(label: "7", state: state.triggerL, helpText: triggerHelp(triggerUsage: layout.triggerUsage.lt, button: layout.triggerButton.l))
                .position(x: 92, y: 12)
            TriggerGauge(label: "8", state: state.triggerR, helpText: triggerHelp(triggerUsage: layout.triggerUsage.rt, button: layout.triggerButton.r))
                .position(x: 268, y: 12)

            DpadCross(directions: state.dpad, helpText: dpadHelp)
                .position(x: 106, y: 92)
            faceCluster.position(x: 254, y: 92)

            CenterPill(label: "9", pressed: state.back, helpText: buttonHelp(layout.back))
                .position(x: 152, y: 74)
            CenterPill(label: "10", pressed: state.start, helpText: buttonHelp(layout.start))
                .position(x: 203, y: 74)

            StickWell(state: state.leftStick, helpText: stickHelp(lx: layout.stickUsage.lx, ly: layout.stickUsage.ly, press: layout.stickPress.l))
                .position(x: 142, y: 150)
            StickWell(state: state.rightStick, helpText: stickHelp(lx: layout.stickUsage.rx, ly: layout.stickUsage.ry, press: layout.stickPress.r))
                .position(x: 218, y: 162)
        }
    }

    // MARK: 面键簇（方位 → 符号按皮肤）

    private var faceCluster: some View {
        let glyphs = faceGlyphs
        let radius: CGFloat = 19
        return ZStack {
            FaceKey(label: glyphs[.north] ?? "", pressed: state.face[.north] ?? false, diameter: 25,
                    helpText: buttonHelp(layout.face[.north]))
                .offset(y: -radius)
            FaceKey(label: glyphs[.east] ?? "", pressed: state.face[.east] ?? false, diameter: 25,
                    helpText: buttonHelp(layout.face[.east]))
                .offset(x: radius)
            FaceKey(label: glyphs[.south] ?? "", pressed: state.face[.south] ?? false, diameter: 25,
                    helpText: buttonHelp(layout.face[.south]))
                .offset(y: radius)
            FaceKey(label: glyphs[.west] ?? "", pressed: state.face[.west] ?? false, diameter: 25,
                    helpText: buttonHelp(layout.face[.west]))
                .offset(x: -radius)
        }
    }

    private var faceGlyphs: [GamepadFace: String] {
        switch skin {
        case .extreme3DPro:
            return [.north: "2", .east: "3", .south: "4", .west: "5"]
        case .f310, .direwolf4, .xbox360, .xboxOne, .xboxSeries:
            return [.north: "Y", .east: "B", .south: "A", .west: "X"]
        case .dualsense, .dualshock4, .dualshock3:
            return [.north: "△", .east: "○", .south: "✕", .west: "□"]
        case .generic:
            // 通用款编号即标签（与映射表的方位编号一致）
            return [.north: "1", .east: "2", .south: "3", .west: "4"]
        }
    }

    private var shoulderGlyphL: String { skin == .dualsense || skin == .dualshock4 || skin == .dualshock3 ? "L1" : "LB" }
    private var shoulderGlyphR: String { skin == .dualsense || skin == .dualshock4 || skin == .dualshock3 ? "R1" : "RB" }
    private var triggerGlyphL: String { skin == .dualsense || skin == .dualshock4 || skin == .dualshock3 ? "L2" : "LT" }
    private var triggerGlyphR: String { skin == .dualsense || skin == .dualshock4 || skin == .dualshock3 ? "R2" : "RT" }
    private var backGlyph: String {
        switch skin {
        case .dualsense: return tr("创建")
        case .dualshock4, .dualshock3: return tr("分享")
        case .f310: return tr("后退")
        default: return tr("视图")
        }
    }
    private var startGlyph: String {
        switch skin {
        case .dualsense, .dualshock4, .dualshock3: return tr("选项")
        case .f310: return tr("开始")
        default: return tr("菜单")
        }
    }
    private var guideGlyph: String {
        skin == .dualsense || skin == .dualshock4 || skin == .dualshock3 ? "PS" : "◎"
    }

    // MARK: 悬停提示（台架核对原始按键号/轴用）

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
        if let pov = layout.dpadPOV {
            return tr("方向键 · POV %d", pov)
        }
        return tr("方向键")
    }

    /// usage → 人读名（与 HID GenericDesktop 轴页一致）。
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

/// 通用款按 360×220 缩放；实机款按各自图片原始宽高比显示，最大 520×300。
struct GamepadSkinScaled: View {
    let skin: GamepadSkin
    var layoutSkin: GamepadSkin? = nil
    var mode: GamepadInputMode = .directInput
    let state: GamepadElementState

    var body: some View {
        if skin == .generic {
            GeometryReader { geo in
                let scale = min(1, min(geo.size.width / 360, geo.size.height / 220))
                GamepadSkinView(skin: skin, layoutSkin: layoutSkin, mode: mode, state: state)
                    .scaleEffect(scale)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .aspectRatio(360.0 / 220.0, contentMode: .fit)
            .frame(height: 220)
        } else {
            GamepadSkinView(skin: skin, layoutSkin: layoutSkin, mode: mode, state: state)
                .frame(maxWidth: 520, maxHeight: 300)
        }
    }
}
