import Foundation

// MARK: - 环境变量兼容读取
//
// 品牌改名后统一使用 `MATCHSTICKS_DRIVER_STATION_` 前缀；过渡期 `MATCHSTICKS_DS_`
// 与旧 `GHDS_` 前缀保留逐级回退，旧脚本 / 旧 E2E 命令无需立即改写。
// 新键存在时优先（即使值为空），旧键只做兜底。

public enum DSEnvironment {
    public static let prefix = "MATCHSTICKS_DRIVER_STATION_"
    /// 过渡期前缀（上一代品牌 MatchSticks DS）：比 `legacyPrefix` 新一级的回退
    public static let interimPrefix = "MATCHSTICKS_DS_"
    public static let legacyPrefix = "GHDS_"

    /// 三级优先链：新 → 过渡 → 旧。任一级键存在（含空值）即为权威，不再查更旧前缀。
    public static func string(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let value = environment[prefix + name] { return value }
        if let value = environment[interimPrefix + name] { return value }
        return environment[legacyPrefix + name]
    }

    /// 只读最新前缀，不查 `MATCHSTICKS_DS_` / `GHDS_` alias。
    /// 用于只有新品牌语义、回退旧键会误读生产/旧测试环境的开关
    /// （例如 `MATCHSTICKS_DRIVER_STATION_APPLICATION_SUPPORT`）。
    public static func currentString(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        environment[prefix + name]
    }

    public static func isEnabled(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        string(name, environment: environment) == "1"
    }
}
