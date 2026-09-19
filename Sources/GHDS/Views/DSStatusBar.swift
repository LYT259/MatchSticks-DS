import SwiftUI
import DSCore

// MARK: - 常驻状态栏（NI DS 语义：队伍号 / 电池 / 三大指示灯 / 状态字符串）

struct DSStatusBar: View {
    let model: DSModel

    var body: some View {
        HStack(spacing: 14) {
            // 队伍号 + 连接
            VStack(alignment: .leading, spacing: 1) {
                Text("TEAM")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(model.teamNumber > 0 ? "\(model.teamNumber)" : "—")
                    .font(.system(.title3, design: .rounded).monospacedDigit().bold())
            }

            Divider().frame(height: 30)

            // 电池
            batteryBlock

            Divider().frame(height: 30)

            // 三大指示灯
            HStack(spacing: 12) {
                LED(label: "Comms", on: model.commConnected, onColor: .green, symbol: "antenna.radiowaves.left.and.right")
                LED(label: "Robot Code", on: model.robotTrace.hasRobotCode, onColor: .green, symbol: "curlybraces")
                LED(label: "Joysticks", on: !model.joystickSlots.isEmpty, onColor: .green, symbol: "gamecontroller")
            }

            Spacer()

            // 状态字符串
            statusPill

            // 看门狗健康
            if !model.watchdogHealthy {
                Label("看门狗冻结", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("UI 主线程冻结，使能输出已被安全冻结")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var batteryBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("BATTERY")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.commConnected ? String(format: "%.2f V", model.batteryVolts) : "--.-- V")
                    .font(.system(.title3, design: .rounded).monospacedDigit().bold())
                    .foregroundStyle(batteryColor)
                if !model.batteryHistory.isEmpty {
                    Sparkline(values: model.batteryHistory.suffix(120))
                        .frame(width: 70, height: 18)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(brownout ? AnyShapeStyle(.red.opacity(0.25)) : AnyShapeStyle(.clear))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var brownout: Bool { model.robotStatus.brownout }
    private var batteryColor: Color {
        if brownout { return .red }
        switch model.batteryVolts {
        case ..<7.0 where model.commConnected: return .red
        case 7.0..<11.0 where model.commConnected: return .orange
        default: return .primary
        }
    }

    private var statusText: String {
        if model.robotStatus.estop { return "E-Stop" }
        if !model.commConnected { return "No Robot Communication" }
        if model.robotStatus.brownout { return "Voltage Brownout" }
        if model.robotStatus.codeStarting { return "Robot Code Starting…" }
        if model.robotStatus.enabled {
            return "\(model.mode.displayName) Enabled"
        }
        return "Disabled"
    }

    private var statusPill: some View {
        Text(statusText)
            .font(.callout.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(statusColor.opacity(0.16), in: Capsule())
            .foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        if model.robotStatus.estop { return .red }
        if !model.commConnected { return .gray }
        if model.robotStatus.brownout { return .red }
        if model.robotStatus.enabled { return .green }
        return .secondary
    }
}

// MARK: 指示灯

struct LED: View {
    let label: String
    let on: Bool
    let onColor: Color
    let symbol: String
    /// 熄灭时替代标签的说明文字：用于「本版本不具备该能力」这类诚实状态，
    /// 避免一盏永远不亮的灯被读成「坏了/没连上」
    var offText: String? = nil

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(on ? onColor : Color.gray.opacity(0.35))
                .shadow(color: on ? onColor.opacity(0.6) : .clear, radius: 4)
            Text(on ? label : (offText ?? label))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
                .layoutPriority(1)
        }
    }
}

// MARK: 迷你曲线

struct Sparkline: View {
    let values: [Float]

    var body: some View {
        GeometryReader { geo in
            let pts = normalizedPoints(size: geo.size)
            Path { p in
                guard pts.count > 1 else { return }
                p.move(to: pts[0])
                for pt in pts.dropFirst() { p.addLine(to: pt) }
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
    }

    private func normalizedPoints(size: CGSize) -> [CGPoint] {
        guard let minV = values.min(), let maxV = values.max(), maxV > minV else { return [] }
        let span = maxV - minV
        return values.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) / CGFloat(values.count - 1) * size.width,
                    y: size.height - CGFloat((v - minV) / span) * size.height)
        }
    }
}
