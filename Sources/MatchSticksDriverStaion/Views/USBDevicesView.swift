import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DSCore

/// 槽位卡拖放载荷：私有 UTI 承载槽位 uniqueID。落点用 onDrop(of: [type]) 只认该类型——
/// 外部文本 / 文本选择拖动都不包含它，根本不会成为落点，更不会被接受。
/// 注意：该 UTI 不在 Info.plist 声明（UTType(exportedAs:) 为动态类型）。真实指针验证（2026-11-23）：
/// ① 只带私有 UTI 的拖拽能起手，但落点永远不会被 target（AppKit 不把仅含动态 UTI 的粘贴板项当有效载荷），
///    所以同一份数据再注册一份 public.data（标准类型，不泄露纯文本）；
/// ② 落点闭包拿到的 NSItemProvider 不暴露该私有类型，数据只在拖拽粘贴板上，解码必须带粘贴板兜底。
enum JoystickSlotDrag {
    static let typeIdentifier = "org.ghfrc.driverstation.joystick-slot"
    static let type = UTType(exportedAs: typeIdentifier)

    static func provider(uniqueID: String) -> JoystickSlotDragItemProvider {
        let provider = JoystickSlotDragItemProvider(uniqueID: uniqueID)
        let payload = Data(uniqueID.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .all) { completion in
            completion(payload, nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.data.identifier, visibility: .all) { completion in
            completion(payload, nil)
            return nil
        }
        return provider
    }

    static func uniqueID(from provider: NSItemProvider, completion: @escaping (String?) -> Void) {
        guard provider.registeredTypeIdentifiers.contains(typeIdentifier) else {
            completion(draggedUniqueID())
            return
        }
        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
            completion(data.flatMap { String(data: $0, encoding: .utf8) } ?? draggedUniqueID())
        }
    }

    /// drop 闭包内同步读取拖拽粘贴板上的私有 UTI。
    static func draggedUniqueID(pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> String? {
        pasteboard.data(forType: NSPasteboard.PasteboardType(typeIdentifier))
            .flatMap { String(data: $0, encoding: .utf8) }
    }
}

final class JoystickSlotDragItemProvider: NSItemProvider, NSPasteboardWriting {
    private let uniqueID: String

    init(uniqueID: String) {
        self.uniqueID = uniqueID
        super.init()
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [NSPasteboard.PasteboardType(JoystickSlotDrag.typeIdentifier),
         NSPasteboard.PasteboardType(UTType.data.identifier)]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        Data(uniqueID.utf8)
    }
}

/// 分离轻点与拖动：只有超过阈值且成功进入拖动会话后才消费随后的 mouseUp。
/// 新 mouseDown 开启新手势，因此取消或完成拖动后不会遗留点击状态。
@MainActor
final class JoystickCardInteractionCoordinator: NSObject, NSDraggingSource {
    static let dragThreshold: CGFloat = 6

    private var mouseDownLocation: NSPoint?
    private var hasDragged = false
    var onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
    }

    func mouseDown(at point: NSPoint) {
        mouseDownLocation = point
        hasDragged = false
    }

    func mouseDragged(at point: NSPoint, startingDrag: () -> Bool) -> Bool {
        guard let mouseDownLocation, !hasDragged else { return false }
        let dx = point.x - mouseDownLocation.x
        let dy = point.y - mouseDownLocation.y
        guard (dx * dx + dy * dy).squareRoot() >= Self.dragThreshold else { return false }
        hasDragged = true
        return startingDrag()
    }

    func mouseUp(at point: NSPoint) {
        guard mouseDownLocation != nil else { return }
        mouseDownLocation = nil
        guard !hasDragged else { return }
        onClick()
    }

    func dragEnded() {
        mouseDownLocation = nil
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        dragEnded()
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }
}

private extension View {
    /// 条件应用修饰符：VoiceOver 自定义操作只在有效时提供（首槽不展示「上移」、末槽不展示「下移」）。
    @ViewBuilder func `when`<Transform: View>(_ condition: Bool, _ transform: (Self) -> Transform) -> some View {
        if condition { transform(self) } else { self }
    }
}

/// 全卡透明事件层。原 Button 仍保留键盘/VoiceOver 语义；此层只处理指针轻点与 NSDraggingSession。
private struct JoystickCardInteraction: NSViewRepresentable {
    let index: Int
    let uniqueID: String
    let onClick: () -> Void

    func makeCoordinator() -> JoystickCardInteractionCoordinator {
        JoystickCardInteractionCoordinator(onClick: onClick)
    }

    func makeNSView(context: Context) -> SlotCardEventView {
        let view = SlotCardEventView()
        view.identifier = NSUserInterfaceItemIdentifier("joystick-card-interaction-\(index)")
        view.coordinator = context.coordinator
        view.uniqueID = uniqueID
        return view
    }

    func updateNSView(_ view: SlotCardEventView, context: Context) {
        view.uniqueID = uniqueID
        context.coordinator.onClick = onClick
    }
}

private final class SlotCardEventView: NSView {
    var coordinator: JoystickCardInteractionCoordinator?
    var uniqueID = ""

    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        coordinator?.mouseDown(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let coordinator else { return }
        let point = convert(event.locationInWindow, from: nil)
        _ = coordinator.mouseDragged(at: point) { [weak self] in
            guard let self else { return false }
            let item = NSDraggingItem(pasteboardWriter: JoystickSlotDrag.provider(uniqueID: self.uniqueID))
            let image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil) ?? NSImage()
            item.setDraggingFrame(NSRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24), contents: image)
            beginDraggingSession(with: [item], event: event, source: coordinator)
            return true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let coordinator else { return }
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            coordinator.mouseUp(at: point)
        } else {
            coordinator.dragEnded()
        }
    }
}

// Input presentation only. Slot order, locking and polling stay in DSModel.
struct USBDevicesView: View {
    let model: DSModel
    /// 拖动悬停中的落点（摘要卡或详情卡），用于高亮。
    @State private var dropTarget: DropArea?

    private enum DropArea: Hashable {
        case summary(Int), detail(Int)
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("%d 个手柄", model.joystickSlots.count))
                                .font(.headline)
                        }
                        Spacer()
                        Button {
                            model.rescanJoysticks()
                        } label: {
                            Label(tr("重新扫描"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(DSActionStyle())
                        .help(tr("重新扫描已连接的手柄。应用在前台且未编辑文本时，也可按 F1。"))
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                        ForEach(0..<6, id: \.self) { index in
                            let slot = model.joystickSlots.first { $0.index == index }
                            let title = slot.map { model.gamepadDisplayName(for: $0) } ?? tr("空闲")
                            let hint = slot == nil ? tr("拖到空闲卡即占据该槽位") : tr("轻点查看详情；拖动卡面调整顺序")
                            slotCard(index: index, slot: slot, title: title, hint: hint, reader: reader)
                        }
                    }
                    if !model.joystickSlots.isEmpty {
                        Label(tr("拖到空闲卡即占据该槽位；拖到占用卡会让其他手柄顺延，顺序在重新扫描和插拔后保持不变。"),
                              systemImage: "arrow.left.arrow.right")
                            .font(.caption).foregroundStyle(DSTheme.textSecondary)
                    }

                    if model.joystickSlots.isEmpty {
                        emptyState
                    } else {
                        if model.joystickSlots.count > 6 {
                            Label(tr("只有槽位 0–5 会发送到机器人。将要使用的手柄移到这些槽位。"), systemImage: "info.circle")
                                .font(.callout).foregroundStyle(DSTheme.textSecondary)
                        }
                        ForEach(model.joystickSlots, id: \.id) { slot in
                            JoystickCard(model: model, index: slot.index, slot: slot)
                                .onDrop(of: [JoystickSlotDrag.type], isTargeted: dropTargeted(.detail(slot.index))) { providers in
                                    drop(providers, at: slot.index)
                                }
                                .overlay {
                                    if dropTarget == .detail(slot.index) {
                                        RoundedRectangle(cornerRadius: 10)
                                            .strokeBorder(DSTheme.accent, lineWidth: 2)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .id(slot.id)
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    /// 顶部槽位摘要卡：卡面 Button 保留键盘/VoiceOver 语义，透明 AppKit 层负责指针轻点与整卡拖动。
    /// 右上角把手只是视觉提示；空闲卡仅作落点。
    private func slotCard(index: Int, slot: JoystickSlot?, title: String, hint: String,
                          reader: ScrollViewProxy) -> some View {
        let targeted = dropTarget == .summary(index)
        return ZStack(alignment: .topTrailing) {
            Button {
                if let slot { reader.scrollTo(slot.id, anchor: .top) }
            } label: {
                slotSummary(index: index, title: title, occupied: slot != nil, targeted: targeted)
            }
            .buttonStyle(.plain)
            .disabled(slot == nil)
            .accessibilityLabel(tr("槽位 %d，%@", index, title))
            .accessibilityHint(hint)
            .when(index > 0) {
                $0.accessibilityAction(named: tr("上移一个槽位")) { model.moveSlot(index, up: true) }
            }
            .when(model.joystickSlots.contains { $0.index > index }) {
                $0.accessibilityAction(named: tr("下移一个槽位")) { model.moveSlot(index, up: false) }
            }
            .help(hint)
            if let slot {
                SlotDragHandle(slot: slot).padding(4)
            }
        }
        .overlay {
            if let slot {
                JoystickCardInteraction(index: index, uniqueID: slot.uniqueID) {
                    reader.scrollTo(slot.id, anchor: .top)
                }
            }
        }
        .onDrop(of: [JoystickSlotDrag.type], isTargeted: dropTargeted(.summary(index))) { providers in
            drop(providers, at: index)
        }
    }

    /// 落点：载荷只可能是私有 UTI（onDrop(of:) 已过滤外部文本），解码 uniqueID 找源槽位交给模型排序。
    private func drop(_ providers: [NSItemProvider], at destination: Int) -> Bool {
        guard let provider = providers.first else { return false }
        JoystickSlotDrag.uniqueID(from: provider) { uniqueID in
            guard let uniqueID else { return }
            DispatchQueue.main.async {
                let source = model.joystickSlots.first { $0.uniqueID == uniqueID }?.index
                guard let source else { return }
                model.moveSlot(from: source, to: destination)
            }
        }
        return true
    }

    private func dropTargeted(_ area: DropArea) -> Binding<Bool> {
        Binding(
            get: { dropTarget == area },
            // 退出竞态：从 A 移到 B 时 A 的 false 可能晚于 B 的 true 到达，只清除仍指向自己的高亮
            set: { targeted in
                if targeted { dropTarget = area } else if dropTarget == area { dropTarget = nil }
            }
        )
    }

    /// 摘要卡卡面：槽号 + 当前生效型号（空闲显示「空闲」）；拖动把手由 SlotDragHandle 单独叠加在右上角。
    private func slotSummary(index: Int, title: String, occupied: Bool, targeted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(tr("槽位 %d", index))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                Spacer(minLength: 20)
            }
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(occupied ? DSTheme.textPrimary : DSTheme.textSecondary)
                .lineLimit(2)
                .frame(height: 32, alignment: .topLeading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(targeted ? DSTheme.accent : DSTheme.line, lineWidth: targeted ? 2 : 1))
    }

    private var emptyState: some View {
        DSPanel(title: "") {
            DSEmptyState(
                symbol: "gamecontroller",
                title: tr("连接你的手柄"),
                detail: tr("通过 USB 连接 HID 手柄或游戏控制器，设备会自动出现。\n如果没有出现，请检查连接线，然后重新扫描。"),
                minHeight: 180
            )
        }
    }
}

/// 摘要卡右上角的视觉把手：不接收指针，拖动由整张占用卡的透明事件层统一处理。
private struct SlotDragHandle: View {
    let slot: JoystickSlot

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DSTheme.textSecondary)
            .frame(width: 24, height: 24)
            .background(.clear, in: RoundedRectangle(cornerRadius: 6))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct JoystickCard: View {
    let model: DSModel
    let index: Int
    let slot: JoystickSlot

    var body: some View {
        DSPanel(title: "") {
            header
            Divider()

            skinSection

            if !slot.axes.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(tr("摇杆轴 · %d", slot.axes.count))
                        .font(.subheadline.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)], spacing: 12) {
                        ForEach(slot.axes.indices, id: \.self) { axisIndex in
                            axisRow(axisIndex)
                        }
                    }
                }
            }

            if slot.buttonCount > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(tr("按键 · %d", slot.buttonCount))
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                    FlowButtons(count: min(slot.buttonCount, 64), pressed: slot.buttons)
                }
            }

            rumbleOutputRow

            if !slot.povs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("方向帽 · POV"))
                        .font(.subheadline.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(slot.povs.indices, id: \.self) { povIndex in
                            let angle = slot.povs[povIndex]
                            HStack {
                                Text("POV \(povIndex)").foregroundStyle(DSTheme.textSecondary)
                                Spacer()
                                Text(angle >= 0 ? "\(angle)°" : tr("未按下"))
                                    .foregroundStyle(angle >= 0 ? DSTheme.accent : DSTheme.textSecondary)
                            }
                            .font(.system(size: 12)).monospacedDigit()
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(DSTheme.card, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
    }

    // MARK: 手柄造型（按下即点亮；映射真值在 DSCore/GamepadProfile）

    private var effectiveSkin: GamepadSkin { model.gamepadSkin(for: slot) }

    private var skinState: GamepadElementState {
        GamepadLayout.layout(for: effectiveSkin).state(for: GamepadSample(slot: slot))
    }

    @ViewBuilder private var skinSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(tr("手柄造型"))
                    .font(.subheadline.weight(.semibold))
                if let override = model.gamepadSkinOverride(for: slot) {
                    DSBadge(text: tr("手动 · %@", override.displayName), color: .orange, symbol: "paintbrush")
                }
                Spacer()
                skinPicker
            }
            GamepadSkinScaled(skin: effectiveSkin, state: skinState)
                .frame(maxWidth: .infinity)
            if !skinState.unmapped.isEmpty {
                HStack(spacing: 6) {
                    Text(tr("未映射按键"))
                        .font(.caption).foregroundStyle(DSTheme.textSecondary)
                    ForEach(skinState.unmapped, id: \.self) { number in
                        Text("\(number)")
                            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(DSTheme.accent, in: RoundedRectangle(cornerRadius: 6))
                            .help(tr("按键 %d 已按下，但当前造型映射表未引用", number))
                    }
                }
            }
        }
    }

    /// 造型选择：自动识别（VID/PID/名称）或手动指定（按设备持久化）。
    private var skinPicker: some View {
        DSSelectControl<GamepadSkin?>(title: tr("手柄造型"), selection: Binding(
            get: { model.gamepadSkinOverride(for: slot) },
            set: { model.setGamepadSkinOverride($0, for: slot) }
        ), options: [DSSelectOption(value: Optional<GamepadSkin>.none,
                                    label: tr("自动识别（当前：%@）", GamepadProfile.detect(
                                        vendorID: slot.vendorID, productID: slot.productID, name: slot.name).displayName))]
            + GamepadSkin.selectableSkins.map { DSSelectOption(value: Optional($0), label: $0.displayName) },
            searchText: { $0?.searchableText ?? tr("自动识别 自动检测 自动 Auto Detect") })
            .frame(width: 240)
        .help(tr("选择手柄造型。自动按 VID/PID 与名称识别，识别不对可手动指定。"))
    }

    /// 机器人回传的 0x2E 手柄输出（rumble/LED）：协议侧验证呈现。
    /// 物理手柄震动映射待真机核查（协议档案「待实测（手柄）」）——显示值不代表已驱动硬件。
    @ViewBuilder private var rumbleOutputRow: some View {
        let outputs = model.joystickOutputs
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("机器人输出 · 0x2E")).font(.subheadline.weight(.semibold))
                Spacer()
                Text(outputs.isEmpty ? tr("尚未收到") : tr("实时"))
                    .font(.caption).foregroundStyle(DSTheme.textSecondary)
            }
            if outputs.isEmpty {
                Text(tr("连接 SystemCore（MRC V2）后，机器人程序可通过 0x2E 下发震动/LED。"))
                    .font(.caption).foregroundStyle(DSTheme.textSecondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 6) {
                    ForEach(outputs.indices, id: \.self) { i in
                        let o = outputs[i]
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("槽 %d", i)).font(.caption.weight(.semibold)).foregroundStyle(DSTheme.textSecondary)
                            Text("L \(o.leftRumble) · R \(o.rightRumble)")
                                .font(.caption.monospacedDigit())
                            Text(tr("扳机 L %d · R %d · LED #%@", Int(o.leftTriggerRumble), Int(o.rightTriggerRumble), String(o.ledRGB, radix: 16)))
                                .font(.caption.monospacedDigit()).foregroundStyle(DSTheme.textSecondary)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(DSTheme.card))
                    }
                }
                Text(tr("值为协议解码结果；到物理手柄的震动映射待真机核查（待实测清单）。"))
                    .font(.caption2).foregroundStyle(DSTheme.textSecondary)
            }
        }
        .padding(.top, 2)
    }

    private var header: some View {
        // 标题 = 当前生效型号（手动所选 / 自动识别的具体型号 / 未知则真实设备名）；
        // 真实设备名与 VID/PID 保留在副标题，识别出手柄时不丢失原始自报名。
        let title = model.gamepadDisplayName(for: slot)
        let vidPID = String(format: "VID %04X · PID %04X", slot.vendorID, slot.productID)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("\(index)")
                    .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(index < 6 ? DSTheme.accent : DSTheme.textSecondary)
                    .frame(width: 44, height: 44)
                    .background(DSTheme.card, in: RoundedRectangle(cornerRadius: 10))
                    .onDrag { JoystickSlotDrag.provider(uniqueID: slot.uniqueID) }
                    .accessibilityLabel(tr("槽位 %d", index))
                    .accessibilityHint(tr("拖到其他槽位以调整顺序"))
                    .help(tr("拖到其他槽位以调整顺序"))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline).textSelection(.enabled)
                    Text(title == slot.name ? vidPID : "\(slot.name) · \(vidPID)")
                        .font(.caption.monospaced()).foregroundStyle(DSTheme.textSecondary)
                }
                Spacer()
                if slot.isXbox { DSBadge(text: "Xbox", symbol: "gamecontroller") }
                if index >= 6 { DSBadge(text: tr("未发送"), color: .orange, symbol: "info.circle") }
            }
        }
    }

    private func axisRow(_ axisIndex: Int) -> some View {
        HStack(spacing: 10) {
            Text(tr("轴 %d", axisIndex))
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(DSTheme.textSecondary)
                .frame(width: 34, alignment: .leading)
            GeometryReader { geometry in
                // Clamp only the drawing; the displayed reading remains the actual input value.
                let raw = slot.axes[axisIndex]
                let value = raw.isFinite ? CGFloat(max(-1, min(1, raw))) : 0
                let center = geometry.size.width / 2
                ZStack(alignment: .leading) {
                    Capsule().fill(DSTheme.card)
                    Capsule()
                        .fill(DSTheme.accent)
                        .frame(width: abs(value) * center)
                        .offset(x: value >= 0 ? center : center + value * center)
                    Rectangle().fill(DSTheme.line)
                        .frame(width: 1, height: 12)
                        .offset(x: center)
                }
                .frame(height: 8)
            }
            .frame(height: 8)
            Text(String(format: "%+.2f", slot.axes[axisIndex]))
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 46, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("轴 %d", axisIndex))
        .accessibilityValue(String(format: "%+.2f", slot.axes[axisIndex]))
    }
}

struct FlowButtons: View {
    let count: Int
    let pressed: UInt64

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 30, maximum: 36), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(0..<min(count, 64), id: \.self) { index in
                let isPressed = pressed & (1 << UInt64(index)) != 0
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .foregroundStyle(isPressed ? Color.white : DSTheme.textSecondary)
                    .background(isPressed ? DSTheme.accent : DSTheme.card, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(tr("按键 %d", index + 1))
                    .accessibilityValue(isPressed ? tr("已按下") : tr("已松开"))
            }
        }
    }
}
