import SwiftUI
import DSCore

// Input presentation only. Slot order, locking and polling stay in DSModel.
struct USBDevicesView: View {
    let model: DSModel

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("%d 个手柄", model.joystickSlots.count))
                                .font(.headline)
                            Text(tr("槽位从 0 开始，与机器人程序中的编号对应。手动调整的顺序在重新扫描和插拔后保持不变，新接入的手柄排到最后。"))
                                .font(.callout).foregroundStyle(DSTheme.textSecondary)
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
                            let slot = model.joystickSlots.indices.contains(index) ? model.joystickSlots[index] : nil
                            Button {
                                if let slot { reader.scrollTo(slot.id, anchor: .top) }
                            } label: {
                                slotSummary(index: index, slot: slot)
                            }
                            .buttonStyle(.plain)
                            .disabled(slot == nil)
                            .accessibilityLabel(tr("槽位 %d，%@", index, slot?.name ?? tr("空闲")))
                            .help(slot.map { tr("查看 %@ 的实时输入", $0.name) } ?? tr("连接手柄后自动分配槽位"))
                        }
                    }

                    if model.joystickSlots.isEmpty {
                        emptyState
                    } else {
                        if model.joystickSlots.count > 6 {
                            Label(tr("只有槽位 0–5 会发送到机器人。将要使用的手柄移到这些槽位。"), systemImage: "info.circle")
                                .font(.callout).foregroundStyle(DSTheme.textSecondary)
                        }
                        ForEach(Array(model.joystickSlots.enumerated()), id: \.element.id) { index, slot in
                            JoystickCard(model: model, index: index, slot: slot)
                                .id(slot.id)
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    private func slotSummary(index: Int, slot: JoystickSlot?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(tr("槽位 %d", index))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                Spacer(minLength: 4)
                Image(systemName: "gamecontroller")
                    .font(.system(size: 12))
                    .foregroundStyle(slot == nil ? DSTheme.textSecondary : DSTheme.accent)
            }
            Text(slot?.name ?? tr("空闲"))
                .font(.system(size: 12))
                .foregroundStyle(slot == nil ? DSTheme.textSecondary : DSTheme.textPrimary)
                .lineLimit(2)
                .frame(height: 32, alignment: .topLeading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DSTheme.line))
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
                        Text(tr("按下时高亮"))
                            .font(.caption).foregroundStyle(DSTheme.textSecondary)
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

    private var detectedSkin: GamepadSkin {
        GamepadProfile.detect(vendorID: slot.vendorID, productID: slot.productID, name: slot.name)
    }
    private var mappingSkin: GamepadSkin { model.gamepadSkinOverride(for: slot) ?? detectedSkin }
    private var effectiveSkin: GamepadSkin { model.gamepadSkin(for: slot) }

    private var skinState: GamepadElementState {
        GamepadLayout.layout(for: mappingSkin, mode: slot.mode).state(for: GamepadSample(slot: slot))
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
            GamepadSkinScaled(skin: effectiveSkin, layoutSkin: mappingSkin, mode: slot.mode, state: skinState)
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
                                    label: tr("自动识别（当前：%@）", effectiveSkin.displayName))]
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("\(index)")
                    .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(index < 6 ? DSTheme.accent : DSTheme.textSecondary)
                    .frame(width: 44, height: 44)
                    .background(DSTheme.card, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(tr("槽位 %d", index))
                VStack(alignment: .leading, spacing: 5) {
                    Text(slot.name).font(.headline).textSelection(.enabled)
                    Text(String(format: "VID %04X · PID %04X", slot.vendorID, slot.productID))
                        .font(.caption.monospaced()).foregroundStyle(DSTheme.textSecondary)
                }
                Spacer()
                if slot.isXbox { DSBadge(text: "Xbox", symbol: "gamecontroller") }
                if index >= 6 { DSBadge(text: tr("未发送"), color: .orange, symbol: "info.circle") }
            }

            HStack(spacing: 8) {
                Button {
                    model.moveSlot(index, up: true)
                } label: {
                    Label(tr("上移"), systemImage: "arrow.up")
                }
                .disabled(index == 0)
                .accessibilityLabel(tr("将 %@ 上移一个槽位", slot.name))
                .help(tr("将手柄移到前一个槽位"))

                Button {
                    model.moveSlot(index, up: false)
                } label: {
                    Label(tr("下移"), systemImage: "arrow.down")
                }
                .disabled(index == model.joystickSlots.count - 1)
                .accessibilityLabel(tr("将 %@ 下移一个槽位", slot.name))
                .help(tr("将手柄移到后一个槽位"))
            }
            .buttonStyle(DSActionStyle())
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
