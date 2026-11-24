import Foundation

/// 更新渠道（持久化值）：stable = 只看 Sparkle 默认渠道；beta = 默认渠道 + `beta` 渠道。
///
/// 映射到 Sparkle 原生渠道过滤：appcast 里带 `<sparkle:channel>beta</sparkle:channel>` 的
/// 条目只有允许 `beta` 渠道的客户端才看得到；不带 channel 的条目属于默认渠道，所有客户端都看得到
/// （默认渠道永远包含在允许集合内）。rawValue 是设置键 `updateChannel` 的持久化契约。
enum UpdateChannel: String, CaseIterable, Sendable {
    case stable = "stable"
    case beta = "beta"

    /// `SPUUpdaterDelegate.allowedChannels` 语义：空集 = 仅默认渠道。
    var allowedSparkleChannels: Set<String> {
        switch self {
        case .stable: return []
        case .beta: return ["beta"]
        }
    }

    /// 日志 / 诊断用的展示名（与 appcast 渠道名一致，便于对照 feed）。
    var displayName: String { rawValue }
}
