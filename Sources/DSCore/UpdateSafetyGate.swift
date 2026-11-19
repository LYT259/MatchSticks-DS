import Foundation

// MARK: - 更新安全门（安全链级；报告 §5.5 / CLAUDE.md 分发章）
//
// DS 运行中重启 = 控制包中断 → robot 侧看门狗自动 disable，绝不允许因更新误触发。
// 仅「失能 + 未连接 + 无急停锁存」放行重启安装；其余状态角标可见但点击无效，
// 阻断原因展示给操作员（tooltip）。求值必须在点击时刻现场执行，不缓存判定结果
// （下载完成到点击之间状态可能已变化）。

public enum UpdateSafetyGate {

    public struct State: Sendable, Equatable {
        public var enabled: Bool
        public var commConnected: Bool
        public var estopEngaged: Bool

        public init(enabled: Bool, commConnected: Bool, estopEngaged: Bool) {
            self.enabled = enabled
            self.commConnected = commConnected
            self.estopEngaged = estopEngaged
        }
    }

    public enum Decision: Sendable, Equatable {
        case allow
        case blocked(reason: String)
    }

    /// 阻断原因按安全显著性排序：使能中 > 通信活跃 > 急停锁存。
    public static func evaluate(_ state: State) -> Decision {
        if state.enabled {
            return .blocked(reason: tr("机器人使能中——重启会中断控制包，先失能"))
        }
        if state.commConnected {
            return .blocked(reason: tr("通信活跃（已连接机器人）——重启会中断控制包，先断开连接"))
        }
        if state.estopEngaged {
            return .blocked(reason: tr("急停锁存中——复位急停后才可重启更新"))
        }
        return .allow
    }
}
