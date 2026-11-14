
// MARK: OM5P 真机就绪回归（2026-10-31 真机日志确立的六个 root cause；engineering-log/2026.10.31.md）
// ① 阻塞 connect 无界且吞 ECONNREFUSED（黑洞链路挂 ~75s；OM5P:80 活着的 RST 被判离线）
// ② radio 选址误用 manualIP + 跨线程读 MainActor 状态
// ③ .local 主机名进发送轮换 → sockaddrFor 只收数字 IP → 每 3 槽一窗整窗空发
// ④ start() 不发初始 .searching → 搜索期 UI 停在 idle
// ⑤ 搜索期坏包静默丢弃 → 真实「零应答」无法区分静默与协议版本漂移
// ⑥ 0x0C 按钮声明数截到 64 但字节数用未截断 n → n>64 时包结构错位

import Foundation
import DSCore
import Darwin

// MARK: 回环测试辅具

/// 在 127.0.0.1 绑定临时端口并 listen，返回 (fd, port)
@discardableResult
func loopbackListen(backlog: Int32) -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    precondition(bound == 0, "loopbackListen bind 失败 errno \(errno)")
    precondition(listen(fd, backlog) == 0, "loopbackListen listen 失败")
    var got = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &got) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    return (fd, UInt16(bigEndian: got.sin_port))
}

/// 回环黑洞：listen(backlog 1) + 一条永不 accept 的连接填满积压 → 后续 SYN 被内核丢弃，
/// connect 永远等不到结果（等价真机「物理拔线/黑洞链路」；阻塞式 connect 会挂到内核
/// 超时——本机回环实测 ~7.8s，真机 en4 实测 ~75s，见 2026-10-31 日志）。
final class LoopbackBlackhole {
    private(set) var listener: Int32 = -1
    private var filler: Int32 = -1
    private(set) var port: UInt16 = 0

    func start() -> Bool {
        let (lfd, p) = loopbackListen(backlog: 1)
        listener = lfd
        port = p
        // 首条连接立即完成并滞留在 accept 队列（回环实测：填满后后续 connect 全部悬挂）
        let c = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = p.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(c, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { close(c); close(lfd); return false }
        filler = c
        return true
    }

    func stop() {
        if filler >= 0 { close(filler) }
        if listener >= 0 { close(listener) }
        filler = -1
        listener = -1
    }
}

/// 对每个控制包回一条「错误 comm 版本」的 NI 应答（0x02，NI 侧解码必败）——
/// 2026-10-31 真机「43180 条 controlOut / 0 条 responseIn」的反面样本：
/// 若真机出现协议版本漂移，DS 必须留下可读证据而不是静默。
final class GarbageResponder {
    static let garbage = Data([0x00, 0x01, 0x02, 0x00, 0x00, 0x0C, 0x40, 0x00])
    private var rxSock: Int32 = -1
    private var txSock: Int32 = -1
    private var stopFlag = false
    private(set) var replies = 0

    func start() -> Bool {
        rxSock = socket(AF_INET, SOCK_DGRAM, 0)
        txSock = socket(AF_INET, SOCK_DGRAM, 0)
        guard bindChecked(rxSock, port: NICodec.udpControlPort, what: "畸形应答器 控制口") else { return false }
        Thread.detachNewThread { [weak self] in self?.loop() }
        return true
    }

    private func loop() {
        var buf = [UInt8](repeating: 0, count: 2048)
        while !stopFlag {
            var src = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &src) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(rxSock, &buf, buf.count, 0, sa, &len)
                }
            }
            guard n > 0 else { continue }
            replies += 1
            withUnsafePointer(to: &src) { dst in
                dst.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Self.garbage.withUnsafeBytes { raw in
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

/// 从控制包里取出（第一个）0x0C 手柄 tag 的载荷
func joystickTagPayload(_ packet: Data) -> Data? {
    var r = ByteReader(packet)
    guard r.remaining >= 6 else { return nil }
    for _ in 0 ..< 6 { _ = r.u8() } // 头部 6 字节（seq/version/control/request/alliance + tag size 前缀）
    guard let size = r.u8(), let id = r.u8(), id == 0x0C, size >= 1,
          let payload = r.bytes(Int(size) - 1) else { return nil }
    return Data(payload)
}

// MARK: ① 有界 connect 分类（真实回环 socket：connected / refused / timedOut / error）

func outcomeTag(_ o: DSClient.TCPConnectOutcome) -> String {
    switch o {
    case .connected: return "connected"
    case .refused: return "refused"
    case .timedOut: return "timedOut"
    case .unreachable: return "unreachable"
    case .error: return "error"
    }
}

func boundedConnectClassificationTests() {
    // connected：监听中
    let live = loopbackListen(backlog: 4)
    defer { close(live.fd) }
    var t0 = Date()
    var outcome = DSClient.boundedTCPConnect(to: "127.0.0.1", port: live.port, timeout: 1.0)
    check(outcomeTag(outcome) == "connected", "监听中 → connected（got \(outcomeTag(outcome))）")
    if case .connected(let fd) = outcome {
        check(fd >= 0, "connected 返回可用 fd")
        close(fd)
    }
    check(-t0.timeIntervalSinceNow < 1.0, "connected 快速返回")

    // refused：端口关但主机活（真机 OM5P:80 形态 → RST）
    let dead = loopbackListen(backlog: 4)
    close(dead.fd)
    t0 = Date()
    outcome = DSClient.boundedTCPConnect(to: "127.0.0.1", port: dead.port, timeout: 1.0)
    check(outcomeTag(outcome) == "refused", "端口关闭 → refused（ECONNREFUSED 独立分类，got \(outcomeTag(outcome))）")
    check(-t0.timeIntervalSinceNow < 2.0, "refused 即时返回（不等待）")

    // timedOut：黑洞链路（accept 积压填满 → SYN 被丢）
    let hole = LoopbackBlackhole()
    check(hole.start(), "黑洞监听就绪")
    defer { hole.stop() }
    t0 = Date()
    outcome = DSClient.boundedTCPConnect(to: "127.0.0.1", port: hole.port, timeout: 0.6)
    check(outcomeTag(outcome) == "timedOut", "黑洞链路 → timedOut（got \(outcomeTag(outcome))）")
    let elapsed = -t0.timeIntervalSinceNow
    check(elapsed >= 0.5 && elapsed <= 2.5,
          "截止时间有界（\(String(format: "%.2f", elapsed))s；阻塞式回环实测 ~7.8s、真机 ~75s）")

    // error：非数字 IP（分类而非崩溃/悬挂）
    outcome = DSClient.boundedTCPConnect(to: "roboRIO-2590-FRC.local", port: 1740, timeout: 1.0)
    check(outcomeTag(outcome) == "error", "非数字 IP → error（got \(outcomeTag(outcome))）")
}

/// 有界等待条件成立（RadioProbe 计时器带 1s leeway + utility QoS，
/// 负载下触发会滞后，固定 sleep 会产生时序伪失败）
func waitUntil(_ timeout: Double, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return condition()
}

// MARK: ① RadioProbe 语义：connected 或 refused = radio 在线；其余 = 离线

func radioProbeClassificationTests() {
    let probe = RadioProbe(configuration: RadioProbe.Configuration(interval: 0.4, timeout: 0.5))

    // 1. 黑洞（物理断线等价物）→ 不可达
    let hole = LoopbackBlackhole()
    check(hole.start(), "黑洞就绪")
    probe.hostProvider = { (host: "127.0.0.1", port: hole.port) }
    probe.start()
    check(waitUntil(8.0) { probe.probeAttempts >= 2 }, "黑洞阶段探测已运行 ≥2 次")
    check(!probe.isReachable, "黑洞链路（超时）→ 不可达")

    // 2. 关闭端口 → RST（真机 OM5P:80 形态）→ 必须仍判可达（假阴性修复）
    hole.stop()
    check(waitUntil(8.0) { probe.isReachable }, "RST 拒绝 = 主机在线 → 仍可达（OM5P:80 假阴性修复）")

    // 3. 再次黑洞 → 重新判离线（证明上一状态的 true 来自 refused 而非残留）
    let hole2 = LoopbackBlackhole()
    check(hole2.start(), "黑洞 2 就绪")
    probe.hostProvider = { (host: "127.0.0.1", port: hole2.port) }
    check(waitUntil(8.0) { !probe.isReachable }, "黑洞 2（超时）→ 重新不可达")

    // 4. 活监听 → connected → 可达
    let live = loopbackListen(backlog: 4)
    defer { close(live.fd) }
    probe.hostProvider = { (host: "127.0.0.1", port: live.port) }
    check(waitUntil(8.0) { probe.isReachable }, "监听中 → 可达")

    probe.stop()
    check(probe.probeAttempts >= 4, "探测持续推进（\(probe.probeAttempts) 次）")
}

// MARK: ② radio 自动选址（纯函数）：队号 .1，与 roboRIO manualIP 无关

func radioAutoTargetTests() {
    let sim = RadioProbe.autoTarget(autoSim: true, teamNumber: 11019)
    check(sim?.host == "127.0.0.1", "AUTO_SIM 固定本机模拟器 host（got \(sim?.host ?? "nil")）")
    check(sim?.port == 8080, "AUTO_SIM 用非特权模拟 radio 端口 8080（got \(sim?.port ?? 0)）")

    let normal = RadioProbe.autoTarget(autoSim: false, teamNumber: 11019)
    check(normal?.host == "10.110.19.1", "普通自动 = 队号派生 10.T.E.1（radio 网关，got \(normal?.host ?? "nil")）")
    check(normal?.port == 80, "普通自动端口 80")

    check(RadioProbe.autoTarget(autoSim: false, teamNumber: 2590)?.host == "10.25.90.1", "队号 2590 → 10.25.90.1")
    check(RadioProbe.autoTarget(autoSim: false, teamNumber: 0) == nil, "队号未设置 → 不探测")
}

// MARK: ③ 发送候选：只收数字 IP；.local 仅作 mDNS 解析输入

func sendCandidatesTests() {
    let auto = DSClient.sendCandidates(manualIP: nil, teamNumber: 2590)
    check(auto.contains("10.25.90.2"), "队号派生 .2 在列")
    check(auto.contains("172.22.11.2"), "USB 候选在列")
    check(!auto.contains { $0.hasSuffix(".local") },
          "自动模式发送候选不含 .local（sockaddrFor 只收数字 IP，.local 槽位 = 整窗空发，got \(auto)）")

    let manual = DSClient.sendCandidates(manualIP: "10.110.19.2", teamNumber: 11019)
    check(manual == ["10.110.19.2"], "手动模式只发 manualIP（got \(manual)）")

    let noTeam = DSClient.sendCandidates(manualIP: nil, teamNumber: 0)
    check(noTeam == ["172.22.11.2"], "无队号只保留 USB 候选（got \(noTeam)）")
    check(!noTeam.contains { $0.hasSuffix(".local") }, "无队号也不含 .local")
}

func sendRotationTests() {
    let rotation = DSClient.sendRotation(
        staticCandidates: ["10.25.90.2", "172.22.11.2"],
        resolvedMDNS: ["10.25.90.2", "10.25.90.201", "10.25.90.201"])
    check(rotation == ["10.25.90.2", "172.22.11.2", "10.25.90.201"],
          "轮换合并去重：静态优先 + mDNS 解析结果唯一（got \(rotation)）")
    check(!rotation.contains { $0.hasSuffix(".local") }, "轮换内无 .local")
}

// MARK: ④ start() 即刻宣告搜索态

func startEmitsSearchingTest() {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var states: [DSClient.CommState] = []
        func add(_ s: DSClient.CommState) { lock.lock(); states.append(s); lock.unlock() }
    }
    let box = Box()
    let client = DSClient()
    client.eventHandler = { event in
        if case .commState(let s) = event { box.add(s) }
    }
    client.updateConfig { $0.manualIP = "127.0.0.1" }
    client.start()
    Thread.sleep(forTimeInterval: 0.4)
    client.stop()

    box.lock.lock(); defer { box.lock.unlock() }
    check(!box.states.isEmpty, "无应答场景 start() 后也应收到 commState 事件（got \(box.states.count) 条）")
    check(box.states.first == .searching, "首条 commState = .searching（UI 搜索期不闲置）")
}

// MARK: ⑤ 搜索期坏包：留痕（按源限流）、不建链、不录制

func malformedResponseLoggingTests() {
    let responder = GarbageResponder()
    check(responder.start(), "畸形应答器启动")
    defer { responder.stop() }

    final class Sink: @unchecked Sendable {
        let lock = NSLock()
        var logs: [String] = []
        var connected = 0
        var recordedResponseIn = 0
    }
    let sink = Sink()
    let client = DSClient()
    client.eventHandler = { event in
        sink.lock.lock(); defer { sink.lock.unlock() }
        switch event {
        case .commState(.connected): sink.connected += 1
        case .log(let line): sink.logs.append(line)
        default: break
        }
    }
    client.recordSink = { dir, _ in
        sink.lock.lock(); defer { sink.lock.unlock() }
        if case .responseIn = dir { sink.recordedResponseIn += 1 }
    }
    client.updateConfig { $0.manualIP = "127.0.0.1" }
    client.start()
    Thread.sleep(forTimeInterval: 1.5)
    client.stop()

    sink.lock.lock(); defer { sink.lock.unlock() }
    let malformed = sink.logs.filter { $0.contains("无法解码") }
    check(sink.connected == 0, "错误版本应答绝不建链（connected \(sink.connected) 次）")
    check(sink.recordedResponseIn == 0, "坏包不写入录制流（.dsrec 方向/schema 不变）")
    check(responder.replies >= 12, "收到足量控制包并回以坏应答（\(responder.replies) 条，慢速环境按 8Hz 下限）")
    check(!malformed.isEmpty, "坏应答留下可读证据（可甄别协议版本漂移）")
    check(malformed.count <= 2,
          "按源限流：整窗突发只落 ≤2 条日志（实际 \(malformed.count)，逐包刷屏会 ≈\(responder.replies) 条）")
    if let line = malformed.first {
        check(line.contains("127.0.0.1"), "证据含来源 IP")
        check(line.contains("8 字节"), "证据含字节数")
        check(line.contains("00010200000c4000"), "证据含前缀 hex（00010200000c4000）")
    }
}

// MARK: ⑥ 0x0C 按钮：字节数按声明数（截断后）计算

func joystickButtonClampTests() {
    // n=100：声明 64，字节必须 8（旧实现按未截断 n 写 13 字节 → 对端按 64 读 8 字节后
    // 把第 9 个按钮字节误当 POV 计数）
    let js100 = JoystickData(axes: [0.5], buttonCount: 100, buttons: UInt64.max, povs: [90])
    let packet100 = NICodec.controlPacket(seq: 1, control: ControlWord(), request: RequestWord(),
                                          alliance: .red1, joysticks: [js100])
    guard let payload = joystickTagPayload(packet100) else {
        check(false, "0x0C tag 存在")
        return
    }
    check(payload.count == 1 + 1 + 1 + 8 + 1 + 2,
          "n=100 tag 载荷长度 = 轴1 + 轴值 + 声明64 + 按钮8字节 + POV数1 + POV2（got \(payload.count)）")
    var tr = ByteReader(payload)
    _ = tr.u8(); _ = tr.i8()
    check(tr.u8() == 64, "声明按钮数截断到 64")

    let decoded100 = NICodec.decodeControl(packet100)
    check(decoded100 != nil, "n=100 包可完整解码")
    check(decoded100?.joysticks.first?.buttons == .max, "64 位按钮位图全保留")
    check(decoded100?.joysticks.first?.povs == [90], "POV 不被按钮多余字节挤占（n>64 回归）")

    // n=65 边界：声明 64 → 字节 8（旧实现 9）
    let js65 = JoystickData(axes: [], buttonCount: 65, buttons: 0, povs: [])
    let packet65 = NICodec.controlPacket(seq: 1, control: ControlWord(), request: RequestWord(),
                                         alliance: .red1, joysticks: [js65])
    if let p65 = joystickTagPayload(packet65) {
        check(p65.count == 1 + 1 + 8 + 1, "n=65 字节数按截断后声明数计（got \(p65.count)，旧实现 12）")
    } else {
        check(false, "n=65 的 0x0C tag 存在")
    }

    // n=64 / n=0 边界不变
    let js64 = JoystickData(axes: [], buttonCount: 64, buttons: 0, povs: [])
    let packet64 = NICodec.controlPacket(seq: 1, control: ControlWord(), request: RequestWord(),
                                         alliance: .red1, joysticks: [js64])
    if let p64 = joystickTagPayload(packet64) {
        check(p64.count == 1 + 1 + 8 + 1, "n=64 边界 8 字节（got \(p64.count)）")
    } else {
        check(false, "n=64 的 0x0C tag 存在")
    }
    let js0 = JoystickData(axes: [], buttonCount: 0, buttons: 0, povs: [])
    let packet0 = NICodec.controlPacket(seq: 1, control: ControlWord(), request: RequestWord(),
                                        alliance: .red1, joysticks: [js0])
    if let p0 = joystickTagPayload(packet0) {
        check(p0.count == 1 + 1 + 0 + 1, "n=0 边界 0 字节（got \(p0.count)）")
    } else {
        check(false, "n=0 的 0x0C tag 存在")
    }
}

// MARK: 注册

func runAllOM5PReadinessTests() {
    runTest("boundedConnectClassification", boundedConnectClassificationTests)
    runTest("radioProbeClassification", radioProbeClassificationTests)
    runTest("radioAutoTarget", radioAutoTargetTests)
    runTest("sendCandidatesNoHostname", sendCandidatesTests)
    runTest("sendRotationUnique", sendRotationTests)
    runTest("startEmitsSearching", startEmitsSearchingTest)
    runTest("malformedResponseLogging", malformedResponseLoggingTests)
    runTest("joystickButtonClamp", joystickButtonClampTests)
}
