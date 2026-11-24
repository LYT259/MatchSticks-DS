import AppKit
import DSCore

// MARK: GitHub 可达探测：默认路由 → 有线 Ethernet 行为测试（2026-11-23）
//
// UpdateReachability 把「单条路径怎么发请求」交给可注入的 UpdateProbeTransport，自身只负责顺序：
// 先系统默认路由；默认路由失败才明确试一次非 Wi‑Fi 路径（Mac 上即可用的有线 Ethernet，见 UpdateProbeTransport）；
// 默认成功不重复探测；回环地址（本地测试源）跳过 Ethernet；同一时刻最多一个探测序列；
// 传输层的重复 / 过期回调不重复回报。生产传输（URLSession + NWConnection + TLS）在 UpdateProbeTransport.swift，
// 本文件只测顺序与回报；真实走线由 swift build 编译、scripts/test-update.sh E2E 覆盖。
// 最后与 UpdateCheckScheduler 组合：默认 + Ethernet 都不可用时仍无限退避。

@MainActor
func updateReachabilityTests(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void) {
    let feed = URL(string: "https://github.com/LYT259/MatchSticks-DS/releases/latest/download/appcast.xml")!
    let defaultDown = UpdateProbeResult(reachable: false, route: .defaultRoute,
                                        detail: "The Internet connection appears to be offline.")
    let ethernetUp = UpdateProbeResult(reachable: true, route: .wiredEthernet, detail: "HTTP 200")
    let ethernetDown = UpdateProbeResult(reachable: false, route: .wiredEthernet, detail: "no wired path (ENETDOWN)")

    // ===== A. 默认路由成功：只探一次，不碰 Ethernet =====
    let ok = ScriptedProbeTransport()
    ok.responder = { route, _ in .init(reachable: true, route: route, detail: "HTTP 302") }
    let r = UpdateReachability(probeURL: feed, transport: ok, monitorsPath: false)
    var results: [UpdateProbeResult] = []
    r.onResult = { results.append($0) }
    check(!r.isProbing, "reachability starts idle")
    r.probe()
    check(r.isProbing && ok.calls.map(\.route) == [.defaultRoute], "a probe starts on the system default route")
    drain()
    check(!r.isProbing && results.count == 1, "a default-route reply finishes the probe")
    check(results.first == .init(reachable: true, route: .defaultRoute, detail: "HTTP 302"),
          "a default-route success is reported as-is")
    check(ok.calls.map(\.route) == [.defaultRoute] && ok.calls.map(\.url) == [feed],
          "a successful default route never triggers an Ethernet probe")

    // ===== B. 默认路由失败 → 有线 Ethernet 成功 =====
    let fallback = ScriptedProbeTransport()
    fallback.responder = { route, _ in route == .defaultRoute ? defaultDown : ethernetUp }
    let f = UpdateReachability(probeURL: feed, transport: fallback, monitorsPath: false)
    var fallbackResults: [UpdateProbeResult] = []
    f.onResult = { fallbackResults.append($0) }
    f.probe()
    drain()
    check(fallback.calls.map(\.route) == [.defaultRoute, .wiredEthernet],
          "a default-route failure is followed by exactly one Ethernet probe")
    check(fallback.calls.map(\.url) == [feed, feed], "both routes probe the same feed URL")
    let viaEthernet = fallbackResults.first
    check(viaEthernet?.reachable == true && viaEthernet?.route == .wiredEthernet,
          "Ethernet success is reported as reachable via the wired route")
    check(viaEthernet?.detail.contains("HTTP 200") == true && viaEthernet?.detail.contains("Internet connection") == true,
          "the Ethernet success detail keeps the default-route failure for diagnostics")

    // ===== C. 默认失败 + Ethernet 失败 → 不可达 =====
    let both = ScriptedProbeTransport()
    both.responder = { route, _ in route == .defaultRoute ? defaultDown : ethernetDown }
    let d = UpdateReachability(probeURL: feed, transport: both, monitorsPath: false)
    var downResults: [UpdateProbeResult] = []
    d.onResult = { downResults.append($0) }
    d.probe()
    drain()
    check(both.calls.map(\.route) == [.defaultRoute, .wiredEthernet], "both routes are tried exactly once")
    check(downResults.count == 1 && downResults[0].reachable == false && downResults[0].route == .wiredEthernet,
          "Ethernet failure reports unreachable, attributed to the last route tried")
    check(downResults[0].detail.contains("Internet connection") == true && downResults[0].detail.contains("ENETDOWN") == true,
          "the unreachable detail carries both routes' failures")

    // ===== D. 顺序与防重入：Ethernet 只在默认路由回报之后发起；期间重复 probe() 不重复 =====
    let held = ScriptedProbeTransport()   // 无 responder：挂起，直到测试显式回复
    let h = UpdateReachability(probeURL: feed, transport: held, monitorsPath: false)
    var heldResults: [UpdateProbeResult] = []
    h.onResult = { heldResults.append($0) }
    h.probe()
    h.probe()
    h.probe()
    check(h.isProbing && held.calls.map(\.route) == [.defaultRoute],
          "repeated probe() calls during an in-flight probe never start a second sequence")
    drain()
    check(held.calls.map(\.route) == [.defaultRoute] && heldResults.isEmpty,
          "Ethernet is not requested while the default route is still pending")
    check(held.reply(call: 0, with: defaultDown), "the pending default-route call can be answered")
    drain()
    check(held.calls.map(\.route) == [.defaultRoute, .wiredEthernet],
          "Ethernet is requested only after the default route reports failure")
    check(heldResults.isEmpty && h.isProbing, "the sequence stays open while Ethernet is pending")
    h.probe()
    check(held.calls.map(\.route) == [.defaultRoute, .wiredEthernet], "a probe() during the Ethernet stage adds nothing")
    check(held.reply(call: 1, with: ethernetUp), "the pending Ethernet call can be answered")
    drain()
    check(heldResults.count == 1 && heldResults[0].route == .wiredEthernet && !h.isProbing,
          "the Ethernet reply completes the sequence")
    h.probe()
    drain()
    check(held.calls.map(\.route) == [.defaultRoute, .wiredEthernet, .defaultRoute],
          "a new probe after completion starts over on the default route")

    // ===== E. 回环地址（本地测试源）跳过 Ethernet =====
    let local = URL(string: "http://127.0.0.1:8123/appcast.xml")!
    let loop = ScriptedProbeTransport()
    loop.responder = { route, _ in .init(reachable: false, route: route, detail: "connection refused") }
    let l = UpdateReachability(probeURL: local, transport: loop, monitorsPath: false)
    var loopResults: [UpdateProbeResult] = []
    l.onResult = { loopResults.append($0) }
    l.probe()
    drain()
    check(loop.calls.map(\.route) == [.defaultRoute],
          "loopback feed URLs never try Ethernet (there is no wired path to 127.0.0.1)")
    check(loopResults.count == 1 && loopResults[0].reachable == false && loopResults[0].route == .defaultRoute,
          "a loopback default failure is reported as unreachable via the default route")
    check(UpdateReachability.isLoopback(URL(string: "http://127.0.0.1:8123/x")!)
            && UpdateReachability.isLoopback(URL(string: "http://localhost/x")!)
            && UpdateReachability.isLoopback(URL(string: "http://[::1]:8123/x")!),
          "loopback detection covers 127.0.0.1, localhost and ::1")
    check(!UpdateReachability.isLoopback(feed) && !UpdateReachability.isLoopback(URL(string: "http://192.0.2.2/x")!),
          "github.com and the RFC 5737 TEST-NET-1 documentation address are not loopback")

    // ===== F. 未配置 URL：立即不可达，不发请求 =====
    let none = ScriptedProbeTransport()
    let n = UpdateReachability(probeURL: nil, transport: none, monitorsPath: false)
    var noneResults: [UpdateProbeResult] = []
    n.onResult = { noneResults.append($0) }
    n.probe()
    check(!n.isProbing && none.calls.isEmpty && noneResults.count == 1 && noneResults[0].reachable == false,
          "a missing feed URL reports unreachable without any request")

    // ===== G. 传输层重复 / 过期回调：只回报一次 =====
    let dup = ScriptedProbeTransport()
    let g = UpdateReachability(probeURL: feed, transport: dup, monitorsPath: false)
    var dupResults: [UpdateProbeResult] = []
    g.onResult = { dupResults.append($0) }
    g.probe()
    check(dup.reply(call: 0, with: defaultDown), "first default reply accepted")
    dup.replyStale(call: 0, with: ethernetUp)   // 默认阶段的第二次回报：必须被忽略
    drain()
    check(dup.calls.map(\.route) == [.defaultRoute, .wiredEthernet], "a duplicate default-stage reply does not start a third probe")
    check(dup.reply(call: 1, with: ethernetUp), "ethernet reply accepted")
    dup.replyStale(call: 1, with: ethernetDown)
    drain()
    check(dupResults.count == 1 && dupResults[0].reachable == true,
          "duplicate Ethernet replies produce exactly one result")

    // ===== H. start() 不监控路径时为空操作（测试注入），不会自己探测 =====
    let s = ScriptedProbeTransport()
    let quiet = UpdateReachability(probeURL: feed, transport: s, monitorsPath: false)
    quiet.start()
    drain()
    check(!quiet.isProbing && s.calls.isEmpty, "start() without path monitoring neither probes nor crashes")

    // ===== I. 与调度器组合：默认 + Ethernet 都不可用 → 无限退避；Ethernet 一旦可达 → 检查 =====
    // 镜像 UpdateCenter 的接线：apply(.probe) → reachability.probe()；onResult → probeSucceeded / probeFailed；
    // apply(.wait) 的计时在测试里直接 timerFired()。
    let offline = ScriptedProbeTransport()
    offline.responder = { route, _ in route == .defaultRoute ? defaultDown : ethernetDown }
    let reach = UpdateReachability(probeURL: feed, transport: offline, monitorsPath: false)
    let scheduler = UpdateCheckScheduler()
    reach.onResult = { result in
        _ = result.reachable ? scheduler.probeSucceeded() : scheduler.probeFailed()
    }
    check(scheduler.requestCheck() == .probe, "startup asks for a probe")
    var delays: [TimeInterval] = []
    for round in 0..<12 {
        reach.probe()
        drain()
        guard case .waiting(_, let delay) = scheduler.state else {
            check(false, "offline round \(round) must end in a timed wait")
            break
        }
        delays.append(delay)
        check(!scheduler.reachabilityConfirmed, "offline round \(round) leaves Sparkle's gate closed")
        check(scheduler.timerFired() == .probe, "the backoff timer re-arms the probe in round \(round)")
    }
    check(offline.calls.map(\.route) == Array(repeating: [.defaultRoute, .wiredEthernet], count: 12).flatMap { $0 },
          "every offline retry tries the default route and then Ethernet again, never giving up")
    check(delays == [3, 6, 12, 24, 48, 96, 192, 384, 768, 900, 900, 900],
          "the composed ladder climbs to the 15-minute cap and keeps retrying")
    offline.responder = { route, _ in route == .defaultRoute ? defaultDown : ethernetUp }
    reach.probe()
    drain()
    check(scheduler.state == .checking(triggerPending: true) && scheduler.reachabilityConfirmed,
          "Ethernet coming back at any point opens the gate and authorizes the check")

    // ===== J. 生产传输的 URL 边界：凭据、非 HTTP scheme、越界端口在发连接前 fail closed =====
    let invalidCases: [(String, URL, UpdateProbeRoute)] = [
        ("URL credentials on default", URL(string: "http://user:secret@127.0.0.1:9/appcast.xml")!, .defaultRoute),
        ("URL credentials on wired", URL(string: "http://user:secret@127.0.0.1:9/appcast.xml")!, .wiredEthernet),
        ("non-HTTP scheme", URL(string: "ftp://127.0.0.1:9/appcast.xml")!, .defaultRoute),
        ("out-of-range port", URL(string: "http://127.0.0.1:65536/appcast.xml")!, .wiredEthernet),
    ]
    for (name, url, route) in invalidCases {
        let result = ReachabilityProbeResultBox()
        SystemRouteProbeTransport(wiredTimeout: 0.5).probe(route, url: url) { result.value = $0 }
        let deadline = Date().addingTimeInterval(2)
        while result.value == nil && Date() < deadline { drain() }
        check(result.value?.reachable == false && result.value?.detail.contains("invalid feed URL") == true,
              "\(name) is rejected before a probe connection (detail: \(result.value?.detail ?? "pending"))")
    }
}

@MainActor
private func drain() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
}

private final class ReachabilityProbeResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UpdateProbeResult?
    var value: UpdateProbeResult? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

/// 脚本化传输：记录每次调用（路由 + URL）。设置 responder 时同步回复；否则挂起直到 reply(call:)。
final class ScriptedProbeTransport: UpdateProbeTransport {
    struct Call: Equatable {
        let route: UpdateProbeRoute
        let url: URL
    }
    private(set) var calls: [Call] = []
    var responder: ((UpdateProbeRoute, URL) -> UpdateProbeResult)?
    private var pending: [Int: (UpdateProbeResult) -> Void] = [:]
    private var everyCompletion: [Int: (UpdateProbeResult) -> Void] = [:]

    func probe(_ route: UpdateProbeRoute, url: URL, completion: @escaping (UpdateProbeResult) -> Void) {
        calls.append(Call(route: route, url: url))
        if let responder {
            completion(responder(route, url))
            return
        }
        pending[calls.count - 1] = completion
        everyCompletion[calls.count - 1] = completion
    }

    /// 回复第 index 次调用（挂起模式）；该调用不存在或已回复时返回 false。
    func reply(call index: Int, with result: UpdateProbeResult) -> Bool {
        guard let completion = pending.removeValue(forKey: index) else { return false }
        completion(result)
        return true
    }

    /// 模拟传输层违约：对已回复的调用再次回调（无论是否已回复）。
    func replyStale(call index: Int, with result: UpdateProbeResult) {
        everyCompletion[index]?(result)
    }
}
