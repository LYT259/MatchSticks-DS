// MARK: 手动机器人刷新（2026-11-23）：真重搜动作与连接安全
//
// Mini Driver Station 刷新按钮背后的核心行为：
// - 决策纯函数：已连接/未启动一律不动链路（rebuild 会触发 autoDisabled = 误失能）；
// - 端到端安全：已连接时刷新不打断控制链路、不触发自动失能、应答持续；
// - 搜索中刷新不 wedge：多次刷新后应答器上线仍能正常建链。

import Foundation
import DSCore

func refreshConnectionDecisionTests() {
    check(DSClient.shouldRefreshConnection(running: false, connected: false) == false,
          "未启动控制环：刷新是空操作")
    check(DSClient.shouldRefreshConnection(running: true, connected: false) == true,
          "已启动且未连接：刷新执行真重搜")
    check(DSClient.shouldRefreshConnection(running: true, connected: true) == false,
          "已连接：刷新不打断活跃控制链路")
    check(DSClient.shouldRefreshConnection(running: false, connected: true) == false,
          "未启动 + 已连接（理论态）：刷新仍是空操作")
}

func refreshConnectionSafetyScenario() {
    // 已连接 + 已使能时连点两次刷新：链路保持、无 autoDisabled、应答持续抵达
    let server = ScenarioServer(controlPort: 12330, responsePort: 12350)
    guard server.start() else {
        // 安全场景不得在端口被占用时静默跳过——显式失败让运行结果可信
        check(false, "安全场景应答器启动失败（隔离端口 12330/12350 被占用？）——不得静默跳过")
        return
    }
    defer { server.stop() }
    Thread.sleep(forTimeInterval: 0.05)
    let sink = runScenarioClient(
        heartbeatStale: { _ in false },
        intent: { _ in (enabled: false, estop: false) },
        actions: [
            (1.0, { $0.refreshConnection() }),
            (1.2, { $0.refreshConnection() }),
        ],
        duration: 2.2,
        onClient: { c in c.updateConfig { $0.controlPort = 12330 } }
    )
    sink.lock.lock(); defer { sink.lock.unlock() }
    check(sink.connectedCount == 1, "已连接时刷新不拆链（connected 事件 \(sink.connectedCount) 次）")
    // start() 启动即宣告一次搜索态（既有行为）；刷新不得新增任何 searching 事件
    check(sink.disconnectedCount == 1, "已连接时刷新不进入搜索态（searching 事件 \(sink.disconnectedCount) 次，仅含启动宣告）")
    check(sink.autoDisabled == 0, "已连接时刷新不触发自动失能（autoDisabled \(sink.autoDisabled) 次）")
    check(sink.responses >= 40, "刷新前后应答持续抵达（\(sink.responses) 条）")
}

func refreshConnectionRescueScenario() {
    // 搜索中连续刷新不 wedge：应答器后上线仍能建链
    var server: ScenarioServer?
    let sink = runScenarioClient(
        heartbeatStale: { _ in false },
        intent: { _ in (enabled: false, estop: false) },
        actions: [
            (0.5, { $0.refreshConnection() }),
            (0.9, { $0.refreshConnection() }),
            (1.3, { _ in
                let s = ScenarioServer(controlPort: 12370, responsePort: 12390)
                let started = s.start()
                // 应答器起不来必须显式失败，不能静默降低场景覆盖
                check(started, "rescue 场景应答器启动失败（隔离端口 12370/12390 被占用？）——不得静默跳过")
                if started { server = s }
            }),
        ],
        duration: 3.2,
        onClient: { c in c.updateConfig { $0.controlPort = 12370 } }
    )
    server?.stop()
    sink.lock.lock(); defer { sink.lock.unlock() }
    check(sink.connectedCount >= 1, "搜索中多次刷新后仍能正常建链（connected \(sink.connectedCount) 次）")
    check(sink.responses >= 20, "建链后应答持续（\(sink.responses) 条）")
}
