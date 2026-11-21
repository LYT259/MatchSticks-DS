import SwiftUI
import DSCore

// Opaque PathBlender-style surfaces with explicit light and dark palettes.
enum DSTheme {
    static let canvas = adaptive(0xF4F4F6, 0x19191B)
    static let surface = adaptive(0xFFFFFF, 0x232326)
    static let sidebar = adaptive(0xF1F1F3, 0x212124)
    static let card = adaptive(0xF5F5F7, 0x2B2B2F)
    static let button = adaptive(0xFFFFFF, 0x323237)
    static let buttonHover = adaptive(0xF3F3F6, 0x3C3C42)
    static let hover = adaptive(0xE6E6EB, 0x303035)
    static let line = adaptive(0xDEDEE3, 0x37373B)
    static let textPrimary = adaptive(0x232327, 0xEDEDF0)
    static let textSecondary = adaptive(0x68686F, 0xA1A1AA)
    static let accent = adaptive(0x007AFF, 0x0A84FF)
    static let accentText = accent
    static let accentDim = adaptive(0x007AFF, 0x0A84FF, lightAlpha: 0.10, darkAlpha: 0.18)
    static let segmentTrack = adaptive(0xE8E8ED, 0x19191C)
    static let segmentSelected = adaptive(0xFFFFFF, 0x45454B)
    static let focusRing = adaptive(0x006CDB, 0x64ACFF)
    static let success = adaptive(0x34C759, 0x30D158)
    static let warning = adaptive(0xFF9500, 0xFF9F0A)
    static let danger = adaptive(0xFF3B30, 0xFF453A)

    private static func adaptive(_ light: UInt32, _ dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    private static func rgb(_ hex: UInt32, alpha: Double) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
}

struct DSPanel<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !title.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(DSTheme.textSecondary) }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DSTheme.line))
    }
}

struct DSBadge: View {
    let text: String
    var color: Color = DSTheme.textSecondary
    var symbol: String = "circle.fill"
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct DSActionStyle: ButtonStyle {
    var color: Color = DSTheme.textPrimary
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let fill = prominent ? color : (hovering ? DSTheme.buttonHover : DSTheme.button)
        return configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11).padding(.vertical, 5)
            .frame(minHeight: 30)
            .foregroundStyle(prominent ? Color.white : color)
            .background(fill, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(prominent ? Color.clear : DSTheme.line))
            .overlay(RoundedRectangle(cornerRadius: 7).fill(configuration.isPressed ? Color.primary.opacity(0.12) : .clear))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { hovering = $0 }
    }
}

struct DSMetric: View {
    let title: String
    let value: String
    var symbol: String = ""
    var color: Color = DSTheme.textPrimary
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.system(size: 12)).foregroundStyle(DSTheme.textSecondary)
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().foregroundStyle(color)
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
        case .idle: return tr("尚未连接")
        case .searching: return tr("正在寻找机器人")
        case .connected(let host): return host
        }
    }

    var uiStatus: String {
        if estopEngaged || robotStatus.estop { return tr("急停已锁定") }
        if !watchdogHealthy { return tr("控制已冻结") }
        if !commConnected { return tr("未连接机器人") }
        if robotStatus.brownout { return tr("电池欠压") }
        if robotStatus.codeStarting { return tr("机器人程序启动中") }
        if enabled && !robotStatus.enabled { return tr("等待机器人使能") }
        if !enabled && robotStatus.enabled { return tr("等待机器人失能") }
        if robotStatus.enabled { return tr("已使能 · %@", mode.displayName) }
        return tr("已失能")
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
        if estopEngaged { return tr("急停已锁定；复位将请求重启机器人程序。") }
        if remoteEstopReported { return tr("机器人仍报告急停；请在诊断页检查或重启机器人程序。") }
        if !watchdogHealthy { return tr("界面心跳异常，使能输出已冻结。") }
        if !commConnected { return tr("先在「连接」页配置机器人。") }
        if enabled { return tr("运行中。按 Return 失能，按空格急停。") }
        return tr("使能后机器人可能运动，请先确认周围安全。")
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
