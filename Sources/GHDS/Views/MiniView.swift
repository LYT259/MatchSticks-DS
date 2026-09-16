import SwiftUI
import DSCore

// MARK: - 迷你视图（Phase 4：FDS Mini view / NI DS Docked 模式对应）
// 常驻角落的紧凑控制面：状态 / 电池 / 三大按键。与主窗口共享同一 DSModel。

struct MiniView: View {
    let model: DSModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("TEAM").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(model.teamNumber > 0 ? "\(model.teamNumber)" : "—")
                        .font(.system(.headline, design: .rounded).monospacedDigit())
                }
                LED(label: "Comm", on: model.commConnected, onColor: .green, symbol: "antenna.radiowaves.left.and.right")
                LED(label: "Code", on: model.robotTrace.hasRobotCode, onColor: .green, symbol: "curlybraces")
                LED(label: "Joy", on: !model.joystickSlots.isEmpty, onColor: .green, symbol: "gamecontroller")
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(model.commConnected ? String(format: "%.2f V", model.batteryVolts) : "--.- V")
                        .font(.system(.headline, design: .rounded).monospacedDigit())
                        .foregroundStyle(model.robotStatus.brownout ? Color.red : Color.primary)
                    Text(model.mode.displayName)
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }

            statusPill

            HStack(spacing: 8) {
                Button {
                    model.setEnabled(true)
                } label: {
                    Text("ENABLE").font(.caption.bold())
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!model.canEnable)

                Button {
                    model.setEnabled(false)
                } label: {
                    Text("DISABLE").font(.caption.bold())
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.return, modifiers: [])

                Button {
                    model.triggerEstop()
                } label: {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .frame(minWidth: 44, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }

    private var statusPill: some View {
        HStack {
            Circle()
                .fill(model.enabled ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(model.robotStatus.estop ? "E-STOP" : (model.enabled ? "\(model.mode.displayName) ENABLED" : "Disabled"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(model.enabled ? Color.green : Color.secondary)
            Spacer()
            if !model.watchdogHealthy {
                Text("看门狗冻结").font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}
