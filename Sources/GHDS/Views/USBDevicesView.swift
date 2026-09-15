import SwiftUI
import DSCore

// MARK: - USB Devices 页（槽位 / 实时轴值 / 按键高亮 / POV / 锁定排序）

struct USBDevicesView: View {
    let model: DSModel

    var body: some View {
        VStack(spacing: 0) {
            if model.joystickSlots.isEmpty {
                ContentUnavailableView(
                    "未检测到手柄",
                    systemImage: "gamecontroller",
                    description: Text("插入 HID 手柄 / 游戏控制器后自动出现。F1 或工具栏按钮可手动重扫。")
                )
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(Array(model.joystickSlots.enumerated()), id: \.element.id) { index, slot in
                            JoystickCard(model: model, index: index, slot: slot)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .toolbar {
            Button {
                model.rescanJoysticks()
            } label: {
                Label("重扫（F1）", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }
}

struct JoystickCard: View {
    let model: DSModel
    let index: Int
    let slot: JoystickSlot

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                // 头部：槽位号 + 名称 + VID/PID + 操作
                HStack(spacing: 10) {
                    Text("\(index)")
                        .font(.system(.title2, design: .rounded).bold().monospacedDigit())
                        .frame(width: 34, height: 34)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(slot.name).font(.headline)
                            if slot.isXbox {
                                Text("Xbox")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.green.opacity(0.18), in: Capsule())
                            }
                            if slot.lockedDeviceID != nil {
                                Label("已锁定", systemImage: "lock.fill")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        Text(String(format: "VID %04X · PID %04X", slot.vendorID, slot.productID))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Button {
                            model.moveSlot(index, up: true)
                        } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0)
                        Button {
                            model.moveSlot(index, up: false)
                        } label: { Image(systemName: "chevron.down") }
                        .disabled(index == model.joystickSlots.count - 1)
                        Button {
                            model.toggleLock(index)
                        } label: {
                            Image(systemName: slot.lockedDeviceID == nil ? "lock.open" : "lock.fill")
                        }
                        .tint(slot.lockedDeviceID == nil ? .secondary : .orange)
                    }
                    .buttonStyle(.borderless)
                }

                // 轴
                if !slot.axes.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(slot.axes.indices, id: \.self) { axisIndex in
                            HStack(spacing: 8) {
                                Text("A\(axisIndex)")
                                    .font(.caption.monospaced())
                                    .frame(width: 26, alignment: .leading)
                                    .foregroundStyle(.secondary)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(.quaternary)
                                        let v = CGFloat(slot.axes[axisIndex]) // -1…1
                                        Capsule()
                                            .fill(v >= 0 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.orange))
                                            .frame(width: abs(v) * geo.size.width / 2)
                                            .offset(x: v >= 0 ? geo.size.width / 2 : geo.size.width / 2 + v * geo.size.width / 2)
                                    }
                                }
                                .frame(height: 8)
                                Text(String(format: "%+.2f", slot.axes[axisIndex]))
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 48, alignment: .trailing)
                            }
                        }
                    }
                }

                // 按键
                if slot.buttonCount > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("按键（\(slot.buttonCount)）").font(.caption).foregroundStyle(.secondary)
                        FlowButtons(count: min(slot.buttonCount, 40), pressed: slot.buttons)
                    }
                }

                // POV
                if !slot.povs.isEmpty {
                    HStack(spacing: 10) {
                        Text("POV").font(.caption).foregroundStyle(.secondary)
                        ForEach(slot.povs.indices, id: \.self) { povIndex in
                            let angle = slot.povs[povIndex]
                            Text(angle >= 0 ? "\(angle)°" : "—")
                                .font(.callout.monospacedDigit())
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(angle >= 0 ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(.quaternary),
                                            in: Capsule())
                        }
                    }
                }
            }
            .padding(4)
        }
    }
}

struct FlowButtons: View {
    let count: Int
    let pressed: UInt64

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 13), spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                let on = pressed & (1 << UInt64(i)) != 0
                Text("\(i + 1)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .frame(width: 28, height: 20)
                    .background(on ? AnyShapeStyle(Color.green) : AnyShapeStyle(.quaternary),
                                in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(on ? Color.white : Color.secondary)
            }
        }
        .padding(2)
    }
}
