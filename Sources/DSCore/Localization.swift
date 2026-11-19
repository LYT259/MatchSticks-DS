import Foundation
import Combine

// MARK: - 语言管理：默认跟随系统，设置页可手动覆盖（中文 / English），立即生效
//
// 设计要点（本地化方案见 docs 与 README「双语」条目）：
// - 中文文案即查找键：chinese 模式零查找直接返回键本身，无需 zh 表；
//   english 模式查 en.lproj/Localizable.strings（SPM resources → Bundle.module），
//   未命中回退中文键并在 DEBUG 打缺失告警——只维护一张 en 表，无两表漂移问题。
// - 回退策略：system 模式按系统首选语言解析，zh*（含繁体）→ 中文，其余（en/ja/fr/…）→ 英文。
// - 持久化不走本类：与其他设置一致，由 DSModel 的 languageMode 属性 didSet 写 SettingsStore
//   （键 ghds.language），启动时读回并 setMode；WebUI 的 language 键也走同一条链。
// - 线程模型：setMode 仅主线程调用；tr() 任意线程可调（内部以锁读当前语言快照）。

/// 语言选择（持久化的值）：跟随系统 / 手动中文 / 手动英文。
public enum LanguageMode: String, CaseIterable, Sendable {
    case system = "system"
    case chinese = "chinese"
    case english = "english"
}

/// 实际生效语言（system 模式解析后的结果）。
public enum AppLanguage: String, Sendable {
    case chinese
    case english
}

public final class LanguageManager: ObservableObject, @unchecked Sendable {
    /// 全局共享实例：状态默认跟随系统；宿主 App 启动时按持久化值 setMode。
    /// 测试不要用 shared——用 init() 自建实例隔离。
    public static let shared = LanguageManager()

    /// UI 观察用（主线程写）：根部 .id(effective) 即可实现语言切换整树重建。
    @Published public private(set) var effective: AppLanguage
    /// 跨线程 tr() 读用快照（控制环线程、server 线程也会产出用户可见文案）。
    /// 命名避开 @Published 合成的 _effective 存储。
    private let lock = NSLock()
    private var effectiveSnapshot: AppLanguage
    private var modeSnapshot: LanguageMode

    public init() {
        let mode = LanguageMode.system
        let resolved = Self.resolve(mode: mode, preferred: Locale.preferredLanguages)
        self.modeSnapshot = mode
        self.effectiveSnapshot = resolved
        self.effective = resolved
    }

    public var mode: LanguageMode { lock.withLock { modeSnapshot } }
    /// tr() 与后台线程取当前语言统一走这里。
    public var currentEffective: AppLanguage { lock.withLock { effectiveSnapshot } }

    /// 仅主线程调用；幂等。变更即生效并广播（@Published + 锁内快照）。
    public func setMode(_ newMode: LanguageMode) {
        let (changed, newEffective): (Bool, AppLanguage) = lock.withLock {
            guard newMode != modeSnapshot else { return (false, effectiveSnapshot) }
            modeSnapshot = newMode
            effectiveSnapshot = Self.resolve(mode: newMode, preferred: Locale.preferredLanguages)
            return (true, effectiveSnapshot)
        }
        guard changed else { return }
        effective = newEffective
    }

    /// system 模式解析：zh 开头（zh-Hans / zh-Hant / zh-CN 等）→ 中文，其余一律英文。
    /// 静态纯函数，测试直接断言各分支。
    public static func resolve(mode: LanguageMode, preferred: [String]) -> AppLanguage {
        switch mode {
        case .chinese: return .chinese
        case .english: return .english
        case .system:
            guard let first = preferred.first else { return .english }
            return first.hasPrefix("zh") ? .chinese : .english
        }
    }
}

// MARK: - 查找入口

/// 便捷查找：key 即中文原文；插值文案改写为 %@/%d 等格式键后传入对应参数。
/// 例：tr("槽位 %d", index) / tr("限流中（%.0f 秒后可再刷）", seconds)。
public func tr(_ key: String, _ args: CVarArg...) -> String {
    LanguageManager.shared.translate(key, args: args)
}

extension LanguageManager {
    /// chinese：直接返回键（含格式参数时按格式键展开，保持调用点单一写法）；
    /// english：查 en 表命中则用译文格式串，未命中回退中文键（DEBUG 告警）。
    func translate(_ key: String, args: [CVarArg]) -> String {
        let language = currentEffective
        let format: String
        switch language {
        case .chinese:
            format = key
        case .english:
            let localized = Bundle.module.localizedString(forKey: key, value: nil, table: nil)
            if localized != key {
                format = localized
            } else {
                #if DEBUG
                print("[L10n] en 表缺失键：\(key)")
                #endif
                format = key
            }
        }
        return args.isEmpty ? format : String(format: format, arguments: args)
    }
}
