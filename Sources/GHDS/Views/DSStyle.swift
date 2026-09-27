import SwiftUI
import DSCore

// Opaque, adaptive surfaces. No Material, blur, or continuously animated decoration.
enum DSTheme {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let sidebar = Color(nsColor: .windowBackgroundColor)
    static let line = Color(nsColor: .separatorColor)
}

struct DSPanel<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !title.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DSTheme.line.opacity(0.4)))
    }
}

struct DSBadge: View {
    let text: String
    var color: Color = .secondary
    var symbol: String = "circle.fill"
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct DSActionStyle: ButtonStyle {
    var color: Color = .accentColor
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 13).padding(.vertical, 9)
            .foregroundStyle(prominent ? Color.white : color)
            .background(prominent ? color : DSTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(prominent ? Color.clear : DSTheme.line.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 8).fill(configuration.isPressed ? Color.primary.opacity(0.12) : .clear))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct DSMetric: View {
    let title: String
    let value: String
    var symbol: String = ""
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 25, weight: .semibold)).monospacedDigit().foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
@Observable
final class ConnectionDraft {
    private var loading = false
    var teamNumber = "" { didSet { if !loading { userEdited = true } } }
    var manualIP = "" { didSet { if !loading { userEdited = true } } }
    var protocolKind: DSClient.ProtocolKind = .ni { didSet { if !loading { userEdited = true } } }
    var userEdited = false

    func load(from model: DSModel) {
        loading = true
        teamNumber = String(model.teamNumber)
        manualIP = model.manualIP
        protocolKind = model.protocolKind
        userEdited = false
        loading = false
    }
}

// Presentation only: all control decisions remain in DSModel / SafetyGate.
extension DSModel {
    var connectionDetail: String {
        switch commState {
        case .idle: return "尚未连接"
        case .searching: return "正在寻找机器人"
        case .connected(let host): return host
        }
    }

    var uiStatus: String {
        if estopEngaged || robotStatus.estop { return "急停已锁定" }
        if !watchdogHealthy { return "控制已冻结" }
        if !commConnected { return "未连接机器人" }
        if robotStatus.brownout { return "电池欠压" }
        if robotStatus.codeStarting { return "机器人程序启动中" }
        if enabled && !robotStatus.enabled { return "等待机器人使能" }
        if !enabled && robotStatus.enabled { return "等待机器人失能" }
        if robotStatus.enabled { return "已使能 · \(mode.displayName)" }
        return "已失能"
    }

    var uiStatusColor: Color {
        if estopEngaged || robotStatus.estop { return .red }
        if !watchdogHealthy { return .orange }
        guard commConnected else { return .secondary }
        if robotStatus.brownout { return .red }
        if enabled != robotStatus.enabled { return .orange }
        if robotStatus.enabled { return .green }
        return .secondary
    }

    var enableExplanation: String {
        if estopEngaged { return "急停已锁定；复位将请求重启机器人程序。" }
        if remoteEstopReported { return "机器人仍报告急停；请在诊断页检查或重启机器人程序。" }
        if !watchdogHealthy { return "界面心跳异常，使能输出已冻结。" }
        if !commConnected { return "先在「连接与设置」中配置机器人。" }
        if enabled { return "运行中。按 Return 失能，按空格急停。" }
        return "使能后机器人可能运动，请先确认周围安全。"
    }

    /// 机器人侧回传的急停（区别于本地锁存 estopEngaged）。
    /// 呈现层用它压住使能按钮：机器人处于急停时使能指令不会产生运动，
    /// 「急停状态 + 可点击的使能」组合只会误导操作员（2026-09-27 复位竞态 E2E 发现）。
    /// 仅影响按钮可用性呈现，不改 SafetyGate / 控制包内容。
    var remoteEstopReported: Bool { commConnected && robotStatus.estop }

    var uiConnectionEditingLocked: Bool {
        enabled || (commConnected && robotStatus.enabled) || practiceActive
    }

    var practiceActive: Bool { practicePhase != .idle && practicePhase != .finished }
}
