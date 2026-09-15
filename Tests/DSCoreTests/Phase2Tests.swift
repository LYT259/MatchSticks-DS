
// MARK: DSLog 编码/读取 单测

func dslogTests() {
    // 头部：版本 + 时间戳（1904 纪元）
    let date = Date(timeIntervalSinceReferenceDate: 800_000_000.5)
    let header = DSLogFormat.encodeHeader(version: 2, timestamp: date)
    check(header.count == 20, "dslog 头 20B（" + String(header.count) + "）")
    var hr = ByteReader(header)
    check(hr.u32be() == 2, "dslog 版本字段")
    _ = hr.u32be()
    let secs = hr.u32be() ?? 0
    check(abs(TimeInterval(secs) - (800_000_000.5 + DSLogFormat.mac1904Offset)) < 1.0, "dslog 1904 纪元时间戳")

    // 条目：已知值金样本
    var e = DSLogEntry()
    e.tripTimeMs = 3            // x/15 → 45
    e.packetLossPercent = 20    // x*4 → 5
    e.batteryVolts = 12.25      // 0x0C40
    e.cpuPercent = 25           // x/2 → 50
    e.brownout = true
    e.dsTeleop = true
    e.robotAuton = true
    e.dsDisabled = false
    e.canPercent = 30           // x/2 → 60
    let encoded = DSLogFormat.encodeEntry(e)
    check(encoded.count == 34, "dslog 条目 34B（" + String(encoded.count) + "）")
    check(Array(encoded[0..<2]) == [45, 5], "trip/loss 金样本")
    check(Array(encoded[2..<4]) == [0x0C, 0x40], "电池 12.25 金样本")
    check(encoded[4] == 50, "cpu 25% → 50")
    check(encoded[5] == 0xA3, "trace 位表：brownout 0x80 + dsTeleop 0x20 + robotAuton 0x02 + robotDisabled 0x01（默认真）= 0xA3，实际 0x" + String(encoded[5], radix: 16))
    check(encoded[6] == 60, "can 30% → 60")

    // PDP 打包回读：0-15 端口已知电流
    var currents = [Double](repeating: 0, count: 16)
    for i in 0..<16 { currents[i] = Double(i) * 1.25 + 0.125 }
    let packed = DSLogFormat.pdpPacked(currents)
    check(packed.count == 21, "PDP 21B")
    let decoded = DSLogFile.decodePDP(packed)
    for i in 0..<16 {
        check(abs(decoded[i] - currents[i]) < 0.1251, "PDP 端口 " + String(i) + " 回读（" + String(decoded[i]) + " vs " + String(currents[i]) + "）")
    }

    // 全文件往返
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ghds-\(Int.random(in: 0...999_999)).dslog")
    let writer = try! DSLogWriter(fileURL: url, version: 2, timestamp: date)
    writer.append(e)
    var e2 = DSLogEntry()
    e2.batteryVolts = 11.5
    e2.packetLossPercent = 4
    writer.append(e2)
    writer.close()

    let raw = try! Data(contentsOf: url)
    let file = try! DSLogFile(fileURL: url)
    let direct = try! DSLogFile(data: raw)
    check(direct.entries.count == file.entries.count, "data/file 两路读取一致")
    check(file.version == 2, "读取器版本")
    check(file.entries.count == 2, "读取器条目数")
    check(abs(file.entries[0].batteryVolts - 12.25) < 0.005, "读取器电池（" + String(file.entries[0].batteryVolts) + "）")
    check(file.entries[0].brownout && file.entries[0].dsTeleop && file.entries[0].robotAuton, "读取器 trace 位（b=" + String(file.entries[0].brownout) + " t=" + String(file.entries[0].dsTeleop) + " a=" + String(file.entries[0].robotAuton) + " d=" + String(file.entries[0].dsDisabled) + "）")
    check(abs(file.entries[1].batteryVolts - 11.5) < 0.005, "读取器第二条目（" + String(file.entries[1].batteryVolts) + "）")
    try? FileManager.default.removeItem(at: url)
}


// MARK: 场景 6：录制 → 回放 → 解析 全链路（真实抓包回归的预演）

func recordReplayScenario() {
    let server = ScenarioServer()
    server.start()
    Thread.sleep(forTimeInterval: 0.05)

    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let recURL = dir.appendingPathComponent("ghds-e2e-\(Int.random(in: 0...999_999)).dsrec")
    let recorder = try! PacketRecorder(fileURL: recURL)
    let boot = Date()

    let sink = ClientSink()
    let client = DSClient()
    client.eventHandler = { sink.observe($0) }
    client.recordSink = { dir, data in recorder.record(dir, data) }
    client.snapshotProvider = {
        var snap = DSClient.Snapshot()
        snap.control.enabled = Date().timeIntervalSince(boot) > 0.5
        return snap
    }
    client.updateConfig { $0.manualIP = "127.0.0.1" }
    client.start()
    Thread.sleep(forTimeInterval: 3.0)
    client.stop()
    recorder.close()
    server.stop()

    // 回放录制的应答：逐组解码必须与实时会话解析一致
    let source = try! ReplaySource(fileURL: recURL)
    let controlCount = source.records.filter { $0.direction == .controlOut }.count
    let responseCount = source.records.filter { $0.direction == .responseIn }.count
    check(controlCount > 100, "录制：控制包 ≥100（" + String(controlCount) + "）")
    check(responseCount > 100, "录制：应答包 ≥100（" + String(responseCount) + "）")

    var batches = 0
    var decoded = 0
    var lastSeq = -1
    var seqMonotonic = true
    var cursor = 0
    while cursor < source.records.count {
        let (batch, next) = source.responseBatch(from: cursor)
        cursor = next
        guard !batch.isEmpty else { break }
        batches += 1
        for payload in batch {
            if let p = NICodec.decodeResponse(payload) {
                decoded += 1
                if Int(p.seq) <= lastSeq { seqMonotonic = false }
                lastSeq = Int(p.seq)
            }
        }
    }
    check(decoded == responseCount, "回放解码 100% 成功（" + String(decoded) + "/" + String(responseCount) + "）")
    check(seqMonotonic, "回放序列号单调递增")
    check(batches >= 2, "回放按控制包边界正确分组（" + String(batches) + " 组）")
    try? FileManager.default.removeItem(at: recURL)
}

import Foundation
import Darwin
import DSCore

// MARK: - Phase 2 验证套件：安全逻辑单测 + 场景级集成测试
// 场景覆盖（红线 3 的验证证据链）：E-Stop 锁存与复位 / roboRIO 重启断联与恢复 /
// UI 冻结看门狗冻结使能 / brownout 解码 / 30s 长跑稳定性。

// MARK: ScenarioServer：可编程 roboRIO 应答器（每个场景独立实例，端口 1110/1150）

final class ScenarioServer {
    let lock = NSLock()
    private(set) var packets = 0
    private(set) var sawEnabled = false
    private(set) var sawEstopRequested = false
    private(set) var sawRestartCode = false
    private(set) var sawReboot = false
    private(set) var lastStatusRaw: UInt8 = 0
    private(set) var enabledEchoCount = 0
    private(set) var disabledEchoCount = 0

    var brownoutForPackets = 0
    private var estopLatched = false
    private var outageStart: Date?
    private var codeRestartAt: Date?
    private var rxSock: Int32 = -1
    private var txSock: Int32 = -1
    private var stopFlag = false

    func start() {
        rxSock = socket(AF_INET, SOCK_DGRAM, 0)
        txSock = socket(AF_INET, SOCK_DGRAM, 0)
        var reuse: Int32 = 1
        setsockopt(rxSock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var rxAddr = sockaddr_in()
        rxAddr.sin_family = sa_family_t(AF_INET)
        rxAddr.sin_port = NICodec.udpControlPort.bigEndian
        rxAddr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        _ = withUnsafePointer(to: &rxAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(rxSock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var txAddr = rxAddr
        txAddr.sin_port = NICodec.udpResponsePort.bigEndian
        _ = withUnsafePointer(to: &txAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(txSock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        Thread.detachNewThread { [weak self] in self?.loop() }
    }

    private func loop() {
        var buf = [UInt8](repeating: 0, count: 2048)
        var seq: UInt16 = 0
        while !stopFlag {
            var src = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &src) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(rxSock, &buf, buf.count, 0, sa, &len)
                }
            }
            guard n > 0, let packet = NICodec.decodeControl(Data(buf[0..<n])) else { continue }
            lock.lock()
            packets += 1
            if packet.control.enabled { sawEnabled = true }
            if packet.control.estop { sawEstopRequested = true; estopLatched = true }
            if packet.request.restartCode { sawRestartCode = true; estopLatched = false; codeRestartAt = Date() }
            if packet.request.rebootRoboRIO { sawReboot = true; outageStart = Date() }

            // 重启断联 3s → 代码重启 1.5s → 恢复
            if let outage = outageStart {
                if Date().timeIntervalSince(outage) < 3.0 { lock.unlock(); continue }
                outageStart = nil
                codeRestartAt = Date()
            }
            let codeStarting = codeRestartAt.map { Date().timeIntervalSince($0) < 1.5 } ?? false
            let enabled = packet.control.enabled && !estopLatched && !codeStarting

            seq &+= 1
            var w = ByteWriter()
            w.u16be(seq); w.u8(NICodec.commVersion)
            var status = RobotStatus()
            status.estop = estopLatched
            status.brownout = packets <= brownoutForPackets
            status.codeStarting = codeStarting
            status.enabled = enabled
            status.mode = packet.control.mode
            lastStatusRaw = status.raw
            if enabled { enabledEchoCount += 1 } else { disabledEchoCount += 1 }
            w.u8(status.raw)
            var trace = RobotTrace(); trace.isRoboRIO = true; trace.disabled = !enabled
            w.u8(trace.raw)
            w.u16be(status.brownout ? 0x06E0 : 0x0C40) // brownout 6.875V / 12.25V
            w.u8(0)
            var ram = ByteWriter(); ram.u32be(1); ram.u32be(2)
            NICodec.appendTag(0x06, ram.data, to: &w)
            lock.unlock()

            withUnsafePointer(to: &src) { dst in
                dst.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    w.data.withUnsafeBytes { raw in
                        _ = sendto(txSock, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    func stop() {
        stopFlag = true
        if rxSock >= 0 { close(rxSock) }
        if txSock >= 0 { close(txSock) }
    }
}

// MARK: 测试用 DS 客户端收集器

final class ClientSink: @unchecked Sendable {
    let lock = NSLock()
    var connectedCount = 0
    var disconnectedCount = 0
    var autoDisabled = 0
    var watchdogTripped = 0
    var watchdogRecovered = 0
    var responses = 0
    var sawBrownout = false
    var sawEstopStatus = false
    var estopClearedAfterLatch = false
    var estopStatusHistory: [Bool] = []

    func observe(_ event: DSClient.Event) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .commState(.connected): connectedCount += 1
        case .commState(.searching): disconnectedCount += 1
        case .autoDisabled: autoDisabled += 1
        case .watchdogTripped: watchdogTripped += 1
        case .watchdogRecovered: watchdogRecovered += 1
        case .response(let p):
            responses += 1
            if p.status.brownout { sawBrownout = true }
            estopStatusHistory.append(p.status.estop)
            if p.status.estop { sawEstopStatus = true }
            if sawEstopStatus, !p.status.estop { estopClearedAfterLatch = true }
        default: break
        }
    }
}

/// 场景化客户端跑法：手动 IP 127.0.0.1，收集事件，返回 sink
func runScenarioClient(heartbeatStale: @escaping (Double) -> Bool,
                       intent: @escaping (Double) -> (enabled: Bool, estop: Bool),
                       actions: [(at: Double, run: (DSClient) -> Void)] = [],
                       duration: Double) -> ClientSink {
    let sink = ClientSink()
    let boot = Date()
    let client = DSClient()
    client.eventHandler = { sink.observe($0) }
    client.heartbeatAge = { heartbeatStale(Date().timeIntervalSince(boot)) ? 1.0 : 0.0 }
    client.snapshotProvider = {
        var snap = DSClient.Snapshot()
        let i = intent(Date().timeIntervalSince(boot))
        snap.control.enabled = i.enabled
        snap.control.estop = i.estop
        return snap
    }
    client.updateConfig { $0.manualIP = "127.0.0.1" }
    client.start()
    for action in actions {
        let wait = action.at - Date().timeIntervalSince(boot)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        action.run(client)
    }
    let rest = duration - Date().timeIntervalSince(boot)
    if rest > 0 { Thread.sleep(forTimeInterval: rest) }
    client.stop()
    return sink
}

// MARK: 场景 1：E-Stop 锁存 → 重启代码复位（First DS 语义，端到端）

func estopLatchScenario() {
    let server = ScenarioServer()
    server.start()
    Thread.sleep(forTimeInterval: 0.05)
    let sink = runScenarioClient(
        heartbeatStale: { _ in false },
        intent: { t in
            (enabled: t > 0.5 && t < 4.0, estop: t > 1.0 && t < 2.0) // 1.0–2.0s 发 E-Stop 位
        },
        actions: [
            (2.2, { $0.sendRequestPulse(RequestWord(rebootRoboRIO: false, restartCode: true)) }) // 复位锁存
        ],
        duration: 4.5
    )
    server.stop()
    sink.lock.lock(); defer { sink.lock.unlock() }
    check(server.sawEnabled, "estop 场景：使能意图到达模拟器")
    check(server.sawEstopRequested, "estop 场景：E-Stop 位到达模拟器")
    check(server.sawRestartCode, "estop 场景：重启代码脉冲到达模拟器")
    check(sink.sawEstopStatus, "estop 场景：DS 收到 E-Stop 锁存状态")
    check(sink.estopClearedAfterLatch, "estop 场景：复位后 E-Stop 状态解除")
}

// MARK: 场景 2：重启 roboRIO → 断联 autoDisable → 恢复重连

func rebootOutageScenario() {
    let server = ScenarioServer()
    server.start()
    Thread.sleep(forTimeInterval: 0.05)
    let sink = runScenarioClient(
        heartbeatStale: { _ in false },
        intent: { t in (enabled: t > 0.5, estop: false) },
        actions: [
            (1.5, { $0.sendRequestPulse(RequestWord(rebootRoboRIO: true, restartCode: false)) })
        ],
        duration: 8.0
    )
    server.stop()
    sink.lock.lock(); defer { sink.lock.unlock() }
    check(server.sawReboot, "reboot 场景：重启请求到达模拟器")
    check(sink.autoDisabled >= 1, "reboot 场景：断联触发自动失能（\\(sink.autoDisabled) 次）")
    check(sink.disconnectedCount >= 1, "reboot 场景：通信状态转为搜索")
    check(sink.connectedCount >= 2, "reboot 场景：恢复后重连（连接 \\(sink.connectedCount) 次）")
}

// MARK: 场景 3：UI 冻结看门狗 → 冻结使能输出 → 恢复

func watchdogScenario() {
    let server = ScenarioServer()
    server.start()
    Thread.sleep(forTimeInterval: 0.05)
    let sink = runScenarioClient(
        heartbeatStale: { t in t > 1.0 && t < 2.5 }, // 1.0–2.5s 模拟主线程冻结
        intent: { t in (enabled: t > 0.5, estop: false) }, // 使能意图全程保持
        duration: 4.5
    )
    server.stop()
    sink.lock.lock(); defer { sink.lock.unlock() }
    check(sink.watchdogTripped >= 1, "watchdog 场景：触发冻结事件")
    check(sink.watchdogRecovered >= 1, "watchdog 场景：恢复事件")
    check(server.enabledEchoCount > 0, "watchdog 场景：冻结前/后使能正常发送（\(server.enabledEchoCount) 包）")
    check(server.disabledEchoCount > 0, "watchdog 场景：冻结窗口内使能被压制为失能（\(server.disabledEchoCount) 包）")
}

// MARK: 场景 4：brownout 解码

func brownoutScenario() {
    let server = ScenarioServer()
    server.brownoutForPackets = 60 // 前 ~1.2s 的应答全带 brownout
    server.start()
    Thread.sleep(forTimeInterval: 0.05)
    let sink = runScenarioClient(
        heartbeatStale: { _ in false },
        intent: { _ in (enabled: false, estop: false) },
        duration: 2.5
    )
    server.stop()
    sink.lock.lock(); defer { sink.lock.unlock() }
    check(sink.sawBrownout, "brownout 场景：DS 解码到 brownout 状态")
}

// MARK: 场景 5：30s 长跑（稳定性 + 丢包）

func longRunScenario() {
    let server = ScenarioServer()
    server.start()
    Thread.sleep(forTimeInterval: 0.05)
    let sink = runScenarioClient(
        heartbeatStale: { _ in false },
        intent: { t in (enabled: t > 1.0, estop: false) },
        duration: 30.0
    )
    server.stop()
    sink.lock.lock()
    let responses = sink.responses
    let autoDisabled = sink.autoDisabled
    sink.lock.unlock()
    check(responses > 1200, "长跑：30s 应答数 ≥1200（" + String(responses) + "）")
    check(server.packets > 1200, "长跑：控制包数 ≥1200（" + String(server.packets) + "）")
    check(server.enabledEchoCount > 500, "长跑：使能回显持续（" + String(server.enabledEchoCount) + " 包）")
    check(autoDisabled == 0, "长跑：全程无意外断联")
}

// MARK: SafetyGate 单测

func safetyGateTests() {
    var s = SafetyGate.State()
    s.commConnected = true
    check(SafetyGate.canEnable(s), "连通+健康+无锁存 → 允许")
    check(SafetyGate.canEnable(s), "重复评估幂等")

    s.estopEngaged = true
    if case .deny(let reason) = SafetyGate.evaluateEnable(s) {
        check(reason.contains("E-Stop"), "E-Stop 锁存拒绝并给原因")
    } else { check(false, "E-Stop 应拒绝") }

    s.estopEngaged = false
    s.commConnected = false
    if case .deny = SafetyGate.evaluateEnable(s) { } else { check(false, "断联应拒绝") }
    s.commConnected = true
    s.watchdogHealthy = false
    if case .deny(let reason) = SafetyGate.evaluateEnable(s) {
        check(reason.contains("心跳"), "看门狗异常拒绝并给原因")
    } else { check(false, "看门狗应拒绝") }

    s.watchdogHealthy = true
    s.currentlyEnabled = true
    s.estopEngaged = true // 即使 E-Stop，已使能状态评估为 allow（幂等路径；真实 E-Stop 由 triggerEstop 落地）
    check(SafetyGate.canEnable(s), "已使能时重复请求幂等放行")
}

// MARK: PracticeSequencer 单测

func practiceSequencerTests() {
    var seq = PracticeSequencer(config: .init(autoTime: 1.0, teleopTime: 1.0, delayTime: 0.5))
    var events: [PracticeSequencer.Event] = []
    events += seq.start()
    check(seq.phase == .delayBeforeAuto && abs(seq.remaining - 0.5) < 0.001, "起始：延迟阶段")

    // 0.5s 延迟 → auto
    for _ in 0..<5 { events += seq.tick(0.1) }
    check(seq.phase == .autonomous, "0.5s 后进入 Auto")
    check(events.contains(.enable), "Auto 进入时发出使能")
    check(events.contains(.entered(.autonomous)), "Auto 阶段切换事件")

    // 1.0s auto → 延迟 + 失能
    events = []
    for _ in 0..<10 { events += seq.tick(0.1) }
    check(seq.phase == .delayBeforeTeleop, "Auto 结束进入 TeleOp 延迟")
    check(events.contains(.disable), "Auto 结束发出失能")
    check(events.contains(.entered(.delayBeforeTeleop)), "延迟阶段事件")

    // 0.5s → teleop + 使能
    events = []
    for _ in 0..<5 { events += seq.tick(0.1) }
    check(seq.phase == .teleoperated, "进入 TeleOp")
    check(events.contains(.enable), "TeleOp 使能")

    // 1.0s → finish + 失能
    events = []
    for _ in 0..<10 { events += seq.tick(0.1) }
    check(seq.phase == .finished, "全程结束")
    check(events.contains(.disable) && events.contains(.finished), "结束失能")

    // idle 后 tick 无事件
    check(seq.tick(0.1).isEmpty, "结束后 tick 空转")

    // A-Stop 中途
    var seq2 = PracticeSequencer(config: .init(autoTime: 10, teleopTime: 10, delayTime: 1))
    _ = seq2.start()
    for _ in 0..<5 { _ = seq2.tick(0.1) } // 仍在延迟
    let abortEvents = seq2.abort()
    check(seq2.phase == .finished, "A-Stop 后 finished")
    check(abortEvents.contains(.disable) && abortEvents.contains(.aborted), "A-Stop 发失能")
    check(seq2.abort().isEmpty, "重复 A-Stop 幂等")
}

// MARK: PacketRecorder / ReplaySource 单测

func recorderTests() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let url = dir.appendingPathComponent("ghds-test-\\(Int.random(in: 0...999_999)).dsrec")

    let recorder = try! PacketRecorder(fileURL: url)
    recorder.record(.controlOut, Data([1, 2, 3]))
    recorder.record(.responseIn, Data([0x0A]))
    recorder.record(.responseIn, Data([0x0B, 0x0C]))
    recorder.record(.controlOut, Data([4]))
    recorder.record(.responseIn, Data([0x0D]))
    recorder.record(.tcpOut, Data([0xDE, 0xAD]))
    recorder.close()

    let source = try! ReplaySource(fileURL: url)
    check(source.records.count == 6, "记录数 6，\\(source.records.count)")
    check(source.tcpOutFrames.count == 1 && source.tcpOutFrames[0] == Data([0xDE, 0xAD]), "tcpOut 帧提取")

    let batch1 = source.responseBatch(from: 0)
    check(batch1.batch.count == 2 && batch1.batch[0] == Data([0x0A]), "第一组应答（1 条）到 controlOut 边界")
    let batch2 = source.responseBatch(from: batch1.next)
    check(batch2.batch == [Data([0x0D])], "第二组应答跨 controlOut 正确分组")

    // 容错：坏魔数拒绝；仅头部的空记录容许
    check((try? ReplaySource(data: Data("BADHEADER!!".utf8))) == nil, "坏魔数拒绝")
    check((try? ReplaySource(data: Data(PacketRecorder.magic.utf8))) != nil, "仅头部空记录容许")
    check((try? ReplaySource(data: Data(PacketRecorder.magic.utf8) + Data([1]))) == nil, "截断记录拒绝")
    try? FileManager.default.removeItem(at: url)
}

// MARK: 注册

func runAllPhase2Tests() {
    runTest("safetyGateTests", safetyGateTests)
    runTest("practiceSequencerTests", practiceSequencerTests)
    runTest("recorderTests", recorderTests)
    runTest("estopLatchScenario", estopLatchScenario)
    runTest("rebootOutageScenario", rebootOutageScenario)
    runTest("watchdogScenario", watchdogScenario)
    runTest("brownoutScenario", brownoutScenario)
    runTest("longRunScenario", longRunScenario)
    runTest("recordReplayScenario", recordReplayScenario)
    runTest("dslogTests", dslogTests)
}
