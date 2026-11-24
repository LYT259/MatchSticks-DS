import Foundation

// MARK: - 环境变量兼容读取
//
// 当前统一使用 `MATCHSTICKS_DRIVER_STAION_` 前缀；上一轮
// `MATCHSTICKS_DRIVER_STATION_`、过渡期 `MATCHSTICKS_DS_` 与旧 `GHDS_`
// 前缀保留逐级回退，旧脚本 / 旧 E2E 命令无需立即改写。
// 新键存在时优先（即使值为空），旧键只做兜底。

public enum DSEnvironment {
    public static let prefix = "MATCHSTICKS_DRIVER_STAION_"
    /// 上一轮品牌前缀，也是第一级回退
    public static let interimPrefix = "MATCHSTICKS_DRIVER_STATION_"
    public static let dsPrefix = "MATCHSTICKS_DS_"
    public static let legacyPrefix = "GHDS_"

    /// 四级优先链：新 → 上一轮 → DS → 旧。任一级键存在（含空值）即为权威，不再查更旧前缀。
    public static func string(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let value = environment[prefix + name] { return value }
        if let value = environment[interimPrefix + name] { return value }
        if let value = environment[dsPrefix + name] { return value }
        return environment[legacyPrefix + name]
    }

    /// 只读最新前缀，不查任何旧 alias。
    /// 用于只有最新品牌语义、回退旧键会误读生产/旧测试环境的开关
    /// （例如 `MATCHSTICKS_DRIVER_STAION_APPLICATION_SUPPORT`）。
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
