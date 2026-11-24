import Foundation
import Network
import DSCore

// MARK: 首次启动本地网络授权触发：NI 服务发现（2026-11-23）行为测试
//
// 全部走假浏览器——不建真实套接字，也不触发系统本地网络弹窗；真实弹窗留给控制器验收。
// 覆盖：包装器一次启动 / 重复 start 不重启 / cancel 到达假浏览器且可重复；
// 策略拒绝（kDNSServiceErr_PolicyDenied）与普通失败、瞬态等待区分，无结果≠拒绝；
// 终态即取消浏览器（isRunning 变 false），同一终态只报一次，取消后重启仍可用；
// DSModel 默认队号 0、空手动地址也启动且重复启动只开一次，AUTO_SIM 不启动；
// 浏览结果只进日志，永不改连接配置 / 发送候选；start() 调用顺序与 Info.plist 声明守卫。

/// 假浏览器：记录 start / cancel，测试直接触发回调。
private final class FakeLocalNetworkBrowser: LocalNetworkBrowsing {
    var onState: ((NWBrowser.State) -> Void)?
    var onServices: (([String]) -> Void)?
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    func start(queue: DispatchQueue) { startCount += 1 }
    func cancel() { cancelCount += 1 }
}

private func failedReason(_ event: LocalNetworkDiscoveryEvent?) -> String? {
    guard case .failed(let reason)? = event else { return nil }
    return reason
}

private func isWaiting(_ event: LocalNetworkDiscoveryEvent?) -> Bool {
    guard case .waiting? = event else { return false }
    return true
}

@MainActor
func localNetworkDiscoveryTests(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void) {
    let policyDenied = NWError.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))
    let ordinaryFailure = NWError.posix(.ECONNREFUSED)

    // ===== A. 错误分类：不强转；只有 dns(-65570) 才是权限拒绝 =====
    check(LocalNetworkDiscovery.isPolicyDenied(policyDenied),
          "kDNSServiceErr_PolicyDenied inside NWError.dns is the policy-denied error")
    check(!LocalNetworkDiscovery.isPolicyDenied(NWError.dns(DNSServiceErrorType(kDNSServiceErr_Unknown))) &&
          !LocalNetworkDiscovery.isPolicyDenied(ordinaryFailure) &&
          !LocalNetworkDiscovery.isPolicyDenied(.tls(-9800)),
          "other DNS, POSIX and TLS errors are ordinary failures, not permission denial")

    // ===== B. 包装器：一次启动、幂等、取消 =====
    let fake = FakeLocalNetworkBrowser()
    var browserFactoryCalls = 0
    let discovery = LocalNetworkDiscovery(makeBrowser: {
        browserFactoryCalls += 1
        return fake
    })
    var events: [LocalNetworkDiscoveryEvent] = []
    discovery.onEvent = { events.append($0) }
    check(!discovery.isRunning, "a fresh discovery is not running")
    discovery.start()
    discovery.start()
    discovery.start()
    check(browserFactoryCalls == 1 && fake.startCount == 1 && discovery.isRunning,
          "repeated start creates and starts the browser exactly once")
    discovery.cancel()
    check(fake.cancelCount == 1 && !discovery.isRunning, "cancel reaches the browser and stops discovery")
    discovery.cancel()
    check(fake.cancelCount == 1, "repeated cancel is safe and does not cancel twice")
    fake.onState?(.ready)
    fake.onServices?(["roboRIO-2590-FRC"])
    check(events.isEmpty, "a cancelled browser no longer delivers events")

    let revived = FakeLocalNetworkBrowser()
    let revival = LocalNetworkDiscovery(makeBrowser: { revived })
    revival.start()
    revival.cancel()
    revival.start()
    check(revived.startCount == 2 && revived.cancelCount == 1,
          "start after cancel starts a browser again exactly once")

    // ===== C. 状态回调：就绪 / 瞬态等待；终态即取消浏览器 =====
    let stateFake = FakeLocalNetworkBrowser()
    let stateDiscovery = LocalNetworkDiscovery(makeBrowser: { stateFake })
    var stateEvents: [LocalNetworkDiscoveryEvent] = []
    stateDiscovery.onEvent = { stateEvents.append($0) }
    stateDiscovery.start()
    stateFake.onState?(.setup)
    check(stateEvents.isEmpty, "setup is silent")
    stateFake.onState?(.ready)
    check(stateEvents == [.ready], "ready is reported without inventing results")
    check(!stateEvents.contains(.policyDenied), "no results at all is not permission denial")
    stateFake.onState?(.waiting(NWError.posix(.ENETDOWN)))
    check(isWaiting(stateEvents.last) && stateEvents.last != .policyDenied &&
          stateDiscovery.isRunning && stateFake.cancelCount == 0,
          "waiting on a network error is a transient wait that keeps browsing")
    let eventCount = stateEvents.count
    stateFake.onState?(.cancelled)
    check(stateEvents.count == eventCount, "cancelled is silent")

    // ===== C2. 终态（权限被拒 / 失败）：报一次并取消浏览器；同一终态不重复报 =====
    let deniedFake = FakeLocalNetworkBrowser()
    let denied = LocalNetworkDiscovery(makeBrowser: { deniedFake })
    var deniedEvents: [LocalNetworkDiscoveryEvent] = []
    denied.onEvent = { deniedEvents.append($0) }
    denied.start()
    deniedFake.onState?(.failed(policyDenied))
    check(deniedEvents == [.policyDenied] && !denied.isRunning && deniedFake.cancelCount == 1,
          "policy denial is reported once and stops the browser")
    deniedFake.onState?(.failed(policyDenied))
    deniedFake.onServices?(["roboRIO-2590-FRC"])
    check(deniedEvents == [.policyDenied] && deniedFake.cancelCount == 1,
          "a terminated browser delivers nothing more")
    // 重启后再次命中同一终态：不再报第二次（网络变化不刷重复拒绝日志），浏览器同样被取消
    denied.start()
    deniedFake.onState?(.failed(policyDenied))
    check(deniedEvents == [.policyDenied] && !denied.isRunning && deniedFake.cancelCount == 2,
          "an identical terminal event after a restart is suppressed and still stops the browser")
    // 不同终态仍要报：去重只针对同一事件
    denied.start()
    deniedFake.onState?(.failed(ordinaryFailure))
    check(deniedEvents.count == 2 && failedReason(deniedEvents.last) != nil && !denied.isRunning,
          "a different terminal failure after a restart is still reported and stops the browser")

    let failedFake = FakeLocalNetworkBrowser()
    let failed = LocalNetworkDiscovery(makeBrowser: { failedFake })
    var failedEvents: [LocalNetworkDiscoveryEvent] = []
    failed.onEvent = { failedEvents.append($0) }
    failed.start()
    failedFake.onState?(.failed(ordinaryFailure))
    check(failedEvents.count == 1 && failedReason(failedEvents.last) != nil &&
          !failedReason(failedEvents.last)!.isEmpty && failedEvents.last != .policyDenied &&
          !failed.isRunning && failedFake.cancelCount == 1,
          "an ordinary terminal failure is reported once with its reason, not as policy denial, and stops the browser")

    let waitingDeniedFake = FakeLocalNetworkBrowser()
    let waitingDenied = LocalNetworkDiscovery(makeBrowser: { waitingDeniedFake })
    var waitingDeniedEvents: [LocalNetworkDiscoveryEvent] = []
    waitingDenied.onEvent = { waitingDeniedEvents.append($0) }
    waitingDenied.start()
    waitingDeniedFake.onState?(.waiting(policyDenied))
    check(waitingDeniedEvents == [.policyDenied] && !waitingDenied.isRunning && waitingDeniedFake.cancelCount == 1,
          "policy denial reported through waiting is still policy denial and stops the browser")
    // 安全取消 / 重启不受终态影响：取消后再 start 仍可正常浏览并交付结果
    waitingDeniedFake.onServices?(["roboRIO-2590-FRC"])
    check(waitingDeniedEvents == [.policyDenied], "a terminated browser drops late results")
    waitingDenied.start()
    waitingDeniedFake.onServices?(["roboRIO-2590-FRC"])
    check(waitingDenied.isRunning && waitingDeniedEvents.last == .services(["roboRIO-2590-FRC"]),
          "a browser started after a terminal state browses again")

    // ===== D. 结果：只在集合变化时交付 =====
    let resultFake = FakeLocalNetworkBrowser()
    let resultDiscovery = LocalNetworkDiscovery(makeBrowser: { resultFake })
    var resultEvents: [LocalNetworkDiscoveryEvent] = []
    resultDiscovery.onEvent = { resultEvents.append($0) }
    resultDiscovery.start()
    resultFake.onServices?(["roboRIO-2590-FRC"])
    resultFake.onServices?(["roboRIO-2590-FRC"])
    check(resultEvents == [.services(["roboRIO-2590-FRC"])], "unchanged results are delivered once")
    resultFake.onServices?(["roboRIO-2590-FRC", "roboRIO-9999-FRC"])
    check(resultEvents.last == .services(["roboRIO-2590-FRC", "roboRIO-9999-FRC"]),
          "a changed result set is delivered")
    resultFake.onServices?([])
    check(resultEvents.last == .services([]), "an emptied result set is delivered")
    resultDiscovery.cancel()
    resultDiscovery.start()
    resultFake.onServices?(["roboRIO-2590-FRC"])
    check(resultEvents.last == .services(["roboRIO-2590-FRC"]) && resultEvents.count == 4,
          "a restarted browser reports the services it sees again")

    check(NIBonjourBrowser.name(of: .service(name: "roboRIO-2590-FRC", type: "_ni._tcp", domain: "local.", interface: nil)) == "roboRIO-2590-FRC" &&
          NIBonjourBrowser.name(of: .hostPort(host: "10.25.90.2", port: 1110)) == nil,
          "only Bonjour service endpoints carry a service name")
    check(NIBonjourBrowser.serviceType == "_ni._tcp",
          "the browser browses the NI service type declared in Info.plist")

    // ===== E. DSModel：默认队号 0 / 空手动地址也启动；重复 start 只开一次；AUTO_SIM 不启动 =====
    let model = DSModel()
    check(model.teamNumber == 0 && model.manualIP.isEmpty, "default model has team 0 and no manual IP")
    let modelFake = FakeLocalNetworkBrowser()
    var modelWrappers = 0
    model.makeLocalNetworkDiscovery = {
        modelWrappers += 1
        return LocalNetworkDiscovery(makeBrowser: { modelFake })
    }
    // start() 本身幂等（guard startInvoked）；这里模拟多窗口 / 状态恢复反复进入 start() 的效果
    model.startLocalNetworkDiscovery()
    model.startLocalNetworkDiscovery()
    model.startLocalNetworkDiscovery()
    check(modelWrappers == 1 && modelFake.startCount == 1,
          "team 0 with an empty manual IP still starts discovery exactly once across repeated starts")

    let simFake = FakeLocalNetworkBrowser()
    var simWrappers = 0
    let simModel = DSModel()
    simModel.makeLocalNetworkDiscovery = {
        simWrappers += 1
        return LocalNetworkDiscovery(makeBrowser: { simFake })
    }
    simModel.startLocalNetworkDiscovery(autoSim: true)
    simModel.startLocalNetworkDiscovery(autoSim: true)
    check(simWrappers == 0 && simFake.startCount == 0, "AUTO_SIM sessions never start discovery")

    // ===== F. 浏览结果永不进发送轮转：连接配置不变，只写日志 =====
    modelFake.onState?(.ready)
    modelFake.onServices?(["roboRIO-2590-FRC"])
    modelFake.onState?(.failed(policyDenied))
    check(model.teamNumber == 0 && model.manualIP.isEmpty && model.protocolKind == .ni && model.commState == .idle,
          "discovered services and browser states leave the connection configuration untouched")
    check(DSClient.sendCandidates(manualIP: model.manualIP, teamNumber: model.teamNumber) == ["172.22.11.2"],
          "send candidates stay the team-0 default (USB only) after discovery events")
    check(model.dsEvents.contains {
        $0.text.contains(tr("本地网络授权被拒绝：请在「系统设置 → 隐私与安全性 → 本地网络」中允许 MatchSticks Driver Station，然后重新打开应用。"))
    }, "policy denial is logged with the localized guidance")
    check(model.dsEvents.contains { $0.text.contains(tr("NI 服务发现：%@", "roboRIO-2590-FRC")) },
          "discovered services are logged for diagnosis")
    model.teamNumber = 2590
    modelFake.onServices?(["roboRIO-2590-FRC", "roboRIO-9999-FRC"])
    check(DSClient.sendCandidates(manualIP: model.manualIP, teamNumber: model.teamNumber) == ["10.25.90.2", "172.22.11.2"],
          "send candidates stay the team-derived rotation after discovery events")
    model.manualIP = "10.0.0.5"
    modelFake.onServices?([])
    check(DSClient.sendCandidates(manualIP: model.manualIP, teamNumber: model.teamNumber) == ["10.0.0.5"],
          "a manual IP stays the only send candidate after discovery events")
    check(model.commState == .idle && !model.commConnected, "discovery alone never connects to anything")

    // ===== G. 源码守卫：start() 在控制环前调用且只调一次；权限 / 端口 / 英文表 =====
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    func source(_ path: String) -> String {
        (try? String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }
    let modelSource = source("Sources/MatchSticksDriverStaion/DSModel.swift")
    let discoverySource = source("Sources/MatchSticksDriverStaion/LocalNetworkDiscovery.swift")
    let buildAppSource = source("scripts/build-app.sh")
    let englishTable = source("Sources/DSCore/Resources/en.lproj/Localizable.strings")
    check(!modelSource.isEmpty && !discoverySource.isEmpty && !buildAppSource.isEmpty && !englishTable.isEmpty,
          "source fixtures load")

    if let guardRange = modelSource.range(of: "guard !startInvoked else { return }"),
       let discoverRange = modelSource.range(of: "startLocalNetworkDiscovery()", range: guardRange.upperBound..<modelSource.endIndex),
       let clientRange = modelSource.range(of: "startWebUI()\n        client.start()", range: guardRange.upperBound..<modelSource.endIndex) {
        check(guardRange.lowerBound < discoverRange.lowerBound && discoverRange.lowerBound < clientRange.lowerBound,
              "start() starts discovery after its idempotence guard and before the control client")
    } else {
        check(false, "start() guard, discovery call and control client start can be located in order")
    }
    check(modelSource.components(separatedBy: "startLocalNetworkDiscovery()").count - 1 == 1,
          "start() starts discovery exactly once")
    check(modelSource.contains("func startLocalNetworkDiscovery(autoSim: Bool? = nil)") &&
          modelSource.contains("autoSim ?? DSModel.isAutoSim"),
          "the production gate defaults to the real AUTO_SIM session flag")

    check(discoverySource.contains(".bonjour(type: Self.serviceType, domain: nil)"),
          "the production browser browses the NI Bonjour service on the default domain")
    check(!discoverySource.contains("sendCandidates") && !discoverySource.contains("resolvedMDNS") &&
          !discoverySource.contains("client."),
          "discovery never touches send candidates or the control client")
    check(!discoverySource.contains("CGRequestListenEventAccess") && !discoverySource.contains("CGRequestPostEventAccess") &&
          !discoverySource.contains("NWListener"),
          "discovery requests no Input Monitoring and opens no listening ports")
    check(buildAppSource.contains("<key>NSBonjourServices</key>") && buildAppSource.contains("<string>_ni._tcp</string>") &&
          buildAppSource.contains("<key>NSLocalNetworkUsageDescription</key>"),
          "Info.plist keeps declaring _ni._tcp and the local network usage description")
    for key in ["本地网络授权被拒绝：请在「系统设置 → 隐私与安全性 → 本地网络」中允许 MatchSticks Driver Station，然后重新打开应用。",
                "NI 服务发现：%@", "NI 服务发现：当前没有 NI 设备", "NI 服务发现失败：%@",
                "NI 服务发现等待：%@", "NI 服务发现已就绪"] {
        check(englishTable.contains("\"\(key)\" = \""), "English translation exists for: \(key)")
    }
}
