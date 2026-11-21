// MARK: 直连绑定失败安全（绑定失败不得绕过看门狗/失联，且 latch 阻断陈旧 enabled）

import Darwin
import Foundation
import DSCore

private let bindFailureControlPortA: UInt16 = 32410
private let bindFailureControlPortB: UInt16 = 32412
private let bindFailureControlPortC: UInt16 = 32414
private let bindFailureTCPPortA: UInt16 = 32411
private let bindFailureTCPPortB: UInt16 = 32413
private let bindFailureTCPPortC: UInt16 = 32415

func bindFailureWait(_ timeout: Double, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    return condition()
}

final class BindFailureSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var enabledValue: Bool

    init(_ enabled: Bool) { enabledValue = enabled }

    var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabledValue }
        set { lock.lock(); enabledValue = newValue; lock.unlock() }
    }
}

final class BindFailureBindScript: @unchecked Sendable {
    private let lock = NSLock()
    private var result: DirectInterface.BindResult
    private var failureTimesValue: [Double] = []

    init(_ initial: DirectInterface.BindResult) { result = initial }

    func set(_ next: DirectInterface.BindResult) {
        lock.lock(); result = next; lock.unlock()
    }

    func provider(_ fd: Int32, _ target: String) -> DirectInterface.BindResult {
        lock.lock()
        let current = result
        if case .failed = current {
            failureTimesValue.append(Date().timeIntervalSinceReferenceDate)
        }
        lock.unlock()
        return current
    }

    var failureTimes: [Double] {
        lock.lock(); defer { lock.unlock() }
        return failureTimesValue
    }
}

final class BindFailureHeartbeatBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ageValue: Double = 0

    var age: Double {
        get { lock.lock(); defer { lock.unlock() }; return ageValue }
        set { lock.lock(); ageValue = newValue; lock.unlock() }
    }
}

final class BindFailureEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var autoDisabledValue: [String] = []
    private var statesValue: [DSClient.CommState] = []
    private var logsValue: [String] = []
    private var tickCountValue = 0
    private var watchdogTripsValue = 0
    private var watchdogRecoveriesValue = 0

    func handle(_ event: DSClient.Event) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .autoDisabled(let reason): autoDisabledValue.append(reason)
        case .commState(let state): statesValue.append(state)
        case .log(let line): logsValue.append(line)
        case .watchdogTripped: watchdogTripsValue += 1
        case .watchdogRecovered: watchdogRecoveriesValue += 1
        default: break
        }
    }

    func tick() {
        lock.lock(); tickCountValue += 1; lock.unlock()
    }

    var autoDisabledReasons: [String] {
        lock.lock(); defer { lock.unlock() }
        return autoDisabledValue
    }

    var states: [DSClient.CommState] {
        lock.lock(); defer { lock.unlock() }
        return statesValue
    }

    var searchingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return statesValue.filter { $0 == .searching }.count
    }

    var logs: [String] {
        lock.lock(); defer { lock.unlock() }
        return logsValue
    }

    var tickCount: Int {
        lock.lock(); defer { lock.unlock() }
        return tickCountValue
    }

    var watchdogTrips: Int {
        lock.lock(); defer { lock.unlock() }
        return watchdogTripsValue
    }

    var watchdogRecoveries: Int {
        lock.lock(); defer { lock.unlock() }
        return watchdogRecoveriesValue
    }
}

final class BindFailureResponder: @unchecked Sendable {
    let port: UInt16
    private let lock = NSLock()
    private var rxSock: Int32 = -1
    private var txSock: Int32 = -1
    private var stopped = false
    private var repliesEnabled = true
    private var packetsValue = 0
    private var enabledValue = 0
    private var disabledValue = 0
    private var seq: UInt16 = 0

    init(port: UInt16) { self.port = port }

    func start() -> Bool {
        let rx = socket(AF_INET, SOCK_DGRAM, 0)
        let tx = socket(AF_INET, SOCK_DGRAM, 0)
        guard rx >= 0, tx >= 0 else {
            if rx >= 0 { close(rx) }
            if tx >= 0 { close(tx) }
            return false
        }
        _ = fcntl(rx, F_SETFL, fcntl(rx, F_GETFL, 0) | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(rx, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            close(rx); close(tx)
            return false
        }
        rxSock = rx
        txSock = tx
        Thread.detachNewThread { [weak self] in self?.loop() }
        return true
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        if rxSock >= 0 { shutdown(rxSock, SHUT_RDWR); close(rxSock); rxSock = -1 }
        if txSock >= 0 { close(txSock); txSock = -1 }
    }

    func setRepliesEnabled(_ enabled: Bool) {
        lock.lock(); repliesEnabled = enabled; lock.unlock()
    }

    var packetCount: Int {
        lock.lock(); defer { lock.unlock() }
        return packetsValue
    }

    var enabledCount: Int {
        lock.lock(); defer { lock.unlock() }
        return enabledValue
    }

    var disabledCount: Int {
        lock.lock(); defer { lock.unlock() }
        return disabledValue
    }

    private func loop() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            lock.lock()
            let stopNow = stopped
            let replyNow = repliesEnabled
            lock.unlock()
            if stopNow { break }

            var src = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &src) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(rxSock, &buffer, buffer.count, 0, sa, &len)
                }
            }
            if n <= 0 {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            guard let packet = NICodec.decodeControl(Data(buffer[0 ..< n])) else { continue }

            lock.lock()
            packetsValue += 1
            if packet.control.enabled { enabledValue += 1 } else { disabledValue += 1 }
            lock.unlock()

            if replyNow { sendResponse(to: src, control: packet.control) }
        }
    }

    private func sendResponse(to src: sockaddr_in, control: ControlWord) {
        seq &+= 1
        var w = ByteWriter()
        w.u16be(seq)
        w.u8(NICodec.commVersion)
        var status = RobotStatus()
        status.enabled = control.enabled && !control.estop
        status.mode = control.mode
        w.u8(status.raw)
        var trace = RobotTrace()
        trace.isRoboRIO = true
        trace.disabled = !status.enabled
        w.u8(trace.raw)
        w.u16be(0x0C40)
        w.u8(0)

        var dst = src
        _ = withUnsafePointer(to: &dst) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                w.data.withUnsafeBytes { raw in
                    sendto(txSock, raw.baseAddress, raw.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}

private func bindFailureMakeClient(controlPort: UInt16, tcpPort: UInt16,
                                   snapshot: BindFailureSnapshotBox,
                                   script: BindFailureBindScript,
                                   events: BindFailureEventBox) -> DSClient {
    let client = DSClient()
    client.snapshotProvider = {
        var snap = DSClient.Snapshot()
        snap.control.enabled = snapshot.enabled
        return snap
    }
    client.eventHandler = { events.handle($0) }
    client.tickHook = { events.tick() }
    client.udpBindProviderForTest = { fd, target in script.provider(fd, target) }
    client.updateConfig {
        $0.manualIP = "127.0.0.1"
        $0.controlPort = controlPort
        $0.tcpPort = tcpPort
    }
    return client
}

func directInterfaceBindFailureSafetyTests() {
    let responder = BindFailureResponder(port: bindFailureControlPortA)
    guard responder.start() else {
        check(false, "绑定失败安全：控制口 \(bindFailureControlPortA) 启动（端口被占用？）")
        return
    }
    defer { responder.stop() }

    let loIndex = if_nametoindex("lo0")
    check(loIndex != 0, "绑定失败安全：lo0 存在")
    let snapshot = BindFailureSnapshotBox(true)
    let script = BindFailureBindScript(.bound(name: "lo0", index: loIndex))
    let events = BindFailureEventBox()
    let client = bindFailureMakeClient(controlPort: bindFailureControlPortA,
                                       tcpPort: bindFailureTCPPortA,
                                       snapshot: snapshot, script: script, events: events)
    client.start()
    defer { client.stop() }

    check(bindFailureWait(1.0) { client.localUDPPortForTest == NICodec.udpResponsePort },
          "绑定失败安全：DS UDP \(NICodec.udpResponsePort) 就绪（端口被占用？）")
    check(bindFailureWait(4.0) {
        events.states.contains(.connected(host: "127.0.0.1"))
            && responder.enabledCount > 0
            && events.tickCount > 0
    }, "绑定失败安全：先建立连接并发送 enabled")

    let searchingBeforeFailure = events.searchingCount
    script.set(.failed(errno: EIO))
    check(bindFailureWait(5.0) {
        events.autoDisabledReasons.contains { $0.contains("bind failed") }
    }, "绑定失败触发 autoDisabled（等待 2s 绑定刷新窗口）")
    check(events.searchingCount > searchingBeforeFailure,
          "绑定失败后 commState 进入 searching（\(searchingBeforeFailure) → \(events.searchingCount)）")
    check(events.autoDisabledReasons.contains { $0.contains("bind failed") },
          "autoDisabled 原因标注绑定失败（\(events.autoDisabledReasons.last ?? "nil")）")

    Thread.sleep(forTimeInterval: 0.15) // 收干净失败前在途的 enabled 包
    let ticksAtFailure = events.tickCount
    let enabledAtFailure = responder.enabledCount
    let disabledAtFailure = responder.disabledCount

    Thread.sleep(forTimeInterval: 0.4)
    check(events.tickCount == ticksAtFailure,
          "latch 期间 tickHook 暂停（\(ticksAtFailure) → \(events.tickCount)）")
    check(responder.enabledCount == enabledAtFailure, "绑定失败后不再发送 enabled")
    check(responder.disabledCount > disabledAtFailure, "latch 期间仍发送 disabled UDP")

    let times = script.failureTimes
    check(times.count >= 3, "失败后约 100ms 重试（0.4s 内 \(times.count) 次）")
    let deltas = zip(times.dropFirst(), times).map { $0 - $1 }
    check(deltas.allSatisfy { $0 > 0.02 && $0 < 1.0 },
          "失败重试间隔远小于 2s（\(deltas.map { String(format: "%.3f", $0) })）")

    let ticksBeforeRecovery = events.tickCount
    script.set(.bound(name: "lo0", index: loIndex))
    Thread.sleep(forTimeInterval: 0.3)
    check(events.tickCount == ticksBeforeRecovery,
          "绑定恢复但 snapshot 仍 enabled 时 latch 保持、tickHook 不恢复")
    check(responder.enabledCount == enabledAtFailure, "恢复瞬间陈旧 enabled 未发出")

    snapshot.enabled = false
    check(bindFailureWait(1.0) { events.tickCount > ticksBeforeRecovery },
          "上层实际落 enabled=false 后 latch 解除")
    check(responder.enabledCount == enabledAtFailure, "latch 解除时仍不补发 enabled")

    snapshot.enabled = true
    check(bindFailureWait(1.0) { responder.enabledCount > enabledAtFailure },
          "之后正常人工使能可恢复发送")
    check(events.autoDisabledReasons.count == 1,
          "同一次绑定失败只上报一次 autoDisabled（\(events.autoDisabledReasons.count)）")
}

func directInterfaceBindFailureRetryTests() {
    let snapshot = BindFailureSnapshotBox(true)
    let script = BindFailureBindScript(.failed(errno: EIO))
    let events = BindFailureEventBox()
    let heartbeat = BindFailureHeartbeatBox()
    let client = bindFailureMakeClient(controlPort: bindFailureControlPortB,
                                       tcpPort: bindFailureTCPPortB,
                                       snapshot: snapshot, script: script, events: events)
    client.heartbeatAge = { heartbeat.age }
    client.start()
    defer { client.stop() }

    check(bindFailureWait(1.0) { client.localUDPPortForTest == NICodec.udpResponsePort },
          "绑定失败重试：DS UDP \(NICodec.udpResponsePort) 就绪（端口被占用？）")
    check(bindFailureWait(3.0) { script.failureTimes.count >= 4 },
          "持续失败时 100ms 周期重试（\(script.failureTimes.count) 次）")
    let times = script.failureTimes
    let deltas = zip(times.dropFirst(), times).map { $0 - $1 }
    check(deltas.allSatisfy { $0 > 0.02 && $0 < 1.0 },
          "失败重试间隔约 100ms（\(deltas.map { String(format: "%.3f", $0) })）")
    check(events.tickCount == 0, "持续绑定失败 + enabled 快照时 tickHook 全程暂停")

    heartbeat.age = 1.0
    check(bindFailureWait(0.5) { events.watchdogTrips == 1 },
          "绑定失败 tick 仍执行看门狗冻结检测（不得绕过看门狗）")
    heartbeat.age = 0
    check(bindFailureWait(0.5) { events.watchdogRecoveries == 1 },
          "绑定失败时看门狗恢复事件仍上报")

    snapshot.enabled = false
    Thread.sleep(forTimeInterval: 0.2)
    check(events.tickCount == 0, "绑定仍失败时 tickHook 不因上层 false 提前恢复")

    let loIndex = if_nametoindex("lo0")
    script.set(.bound(name: "lo0", index: loIndex))
    check(bindFailureWait(1.0) { events.tickCount > 0 },
          "绑定恢复且上层 false 后 tickHook 恢复")
}

func directInterfaceSilenceDisableLatchTests() {
    let responder = BindFailureResponder(port: bindFailureControlPortC)
    guard responder.start() else {
        check(false, "silence latch：控制口 \(bindFailureControlPortC) 启动（端口被占用？）")
        return
    }
    defer { responder.stop() }

    let loIndex = if_nametoindex("lo0")
    let snapshot = BindFailureSnapshotBox(true)
    let script = BindFailureBindScript(.bound(name: "lo0", index: loIndex))
    let events = BindFailureEventBox()
    let client = bindFailureMakeClient(controlPort: bindFailureControlPortC,
                                       tcpPort: bindFailureTCPPortC,
                                       snapshot: snapshot, script: script, events: events)
    client.start()
    defer { client.stop() }

    check(bindFailureWait(1.0) { client.localUDPPortForTest == NICodec.udpResponsePort },
          "silence latch：DS UDP \(NICodec.udpResponsePort) 就绪（端口被占用？）")
    check(bindFailureWait(4.0) {
        events.states.contains(.connected(host: "127.0.0.1")) && responder.enabledCount > 0
    }, "silence latch：先建立连接并发送 enabled")

    let searchingBeforeSilence = events.searchingCount
    responder.setRepliesEnabled(false)
    check(bindFailureWait(4.0) {
        events.autoDisabledReasons.contains { $0.contains("silence") }
    }, "失联触发 autoDisabled")
    check(events.searchingCount > searchingBeforeSilence,
          "失联后 commState 进入 searching（\(searchingBeforeSilence) → \(events.searchingCount)）")

    Thread.sleep(forTimeInterval: 0.15)
    let ticksAtDisable = events.tickCount
    let enabledAtDisable = responder.enabledCount
    let disabledAtDisable = responder.disabledCount
    Thread.sleep(forTimeInterval: 0.3)
    check(events.tickCount == ticksAtDisable, "失联 latch 期间 tickHook 暂停")
    check(responder.enabledCount == enabledAtDisable, "失联 latch 期间不补发 enabled")
    check(responder.disabledCount > disabledAtDisable, "失联 latch 期间继续发送 disabled UDP")

    snapshot.enabled = false
    check(bindFailureWait(1.0) { events.tickCount > ticksAtDisable },
          "上层实际落 enabled=false 后失联 latch 解除")
    check(responder.enabledCount == enabledAtDisable, "失联 latch 解除时仍不补发 enabled")

    responder.setRepliesEnabled(true)
    snapshot.enabled = true
    check(bindFailureWait(2.0) { responder.enabledCount > enabledAtDisable },
          "之后正常人工使能可恢复发送")
}
