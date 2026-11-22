import Foundation

// MARK: - 环境变量兼容读取
//
// 品牌改名后统一使用 `MATCHSTICKS_DS_` 前缀；旧 `GHDS_` 前缀保留回退，
// 旧脚本 / 旧 E2E 命令无需立即改写。新键存在时优先（即使值为空），旧键只做兜底。

public enum DSEnvironment {
    public static let prefix = "MATCHSTICKS_DS_"
    public static let legacyPrefix = "GHDS_"

    public static func string(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let value = environment[prefix + name] { return value }
        return environment[legacyPrefix + name]
    }

    /// 只读新前缀，不查旧 `GHDS_` alias。
    /// 用于只有新品牌语义、回退旧键会误读生产/旧测试环境的开关
    /// （例如 `MATCHSTICKS_DS_APPLICATION_SUPPORT`）。
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
