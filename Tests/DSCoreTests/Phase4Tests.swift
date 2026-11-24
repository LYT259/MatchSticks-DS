// MARK: Phase 4：更新安全门全状态矩阵 + WebUI 行为测试（后续阶段并入本文件）

import Foundation
import DSCore

func updateSafetyGateMatrix() {
    // 全 8 组合：仅 (失能, 未连接, 无锁存) 放行
    let cases: [(Bool, Bool, Bool, UpdateSafetyGate.Decision, String)] = [
        (false, false, false, .allow, "唯一放行：失能+未连接+无锁存"),
        (true,  false, false, .blocked(reason: ""), "使能即阻断"),
        (false, true,  false, .blocked(reason: ""), "连接即阻断"),
        (false, false, true,  .blocked(reason: ""), "急停锁存即阻断"),
        (true,  true,  false, .blocked(reason: ""), "使能+连接"),
        (true,  false, true,  .blocked(reason: ""), "使能+锁存"),
        (false, true,  true,  .blocked(reason: ""), "连接+锁存"),
        (true,  true,  true,  .blocked(reason: ""), "三态全真"),
    ]
    for (enabled, connected, estop, expected, label) in cases {
        let decision = UpdateSafetyGate.evaluate(.init(
            enabled: enabled, commConnected: connected, estopEngaged: estop))
        switch (decision, expected) {
        case (.allow, .allow):
            check(true, label)
        case (.blocked(let r), .blocked):
            check(!r.isEmpty, "\(label)：阻断原因非空")
        default:
            check(false, "\(label)：期望 \(expected)，得到 \(decision)")
        }
    }
}

func updateSafetyGateReasonPrecedence() {
    // 阻断原因优先级：使能 > 连接 > 急停锁存（多条同时满足时报最显著的一条）
    guard case .blocked(let r1) = UpdateSafetyGate.evaluate(.init(enabled: true, commConnected: true, estopEngaged: true)) else {
        check(false, "三态全真应阻断"); return
    }
    check(r1.contains("使能") || r1.contains("enabled"), "优先报使能中（得到：\(r1)）")
    guard case .blocked(let r2) = UpdateSafetyGate.evaluate(.init(enabled: false, commConnected: true, estopEngaged: true)) else {
        check(false, "连接+锁存应阻断"); return
    }
    check(r2.contains("通信") || r2.contains("Comms"), "其次报通信活跃（得到：\(r2)）")
    guard case .blocked(let r3) = UpdateSafetyGate.evaluate(.init(enabled: false, commConnected: false, estopEngaged: true)) else {
        check(false, "仅锁存应阻断"); return
    }
    check(r3.contains("急停") || r3.contains("E-Stop"), "最后报急停锁存（得到：\(r3)）")
}

func updateSafetyGateBlockingDrivesUiState() {
    // 放行/阻断的可判定性：Decision 可判等（UI 干测试据此断言角标可点态）
    check(UpdateSafetyGate.evaluate(.init(enabled: false, commConnected: false, estopEngaged: false)) == .allow,
          "失能+未连接+无锁存 == .allow")
    check(UpdateSafetyGate.evaluate(.init(enabled: true, commConnected: false, estopEngaged: false)) != .allow,
          "任一为真 != .allow")
}


// MARK: Phase 4 — WebUI 服务器行为测试（路由纯函数 + 回环 socket 往返）

import DSCore

func makeWebUITempEnv() -> (WebUIServer.Environment, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("matchsticks-ds-webui-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var store: [String: String] = ["teamNumber": "2590", "soundsEnabled": "true"]
    let env = WebUIServer.Environment(
        logsDirectory: { dir },
        listSettings: { store },
        applySetting: { key, value in
            guard key == "teamNumber" || key == "soundsEnabled" else { return "未知设置项" }
            if key == "teamNumber", Int(value) == nil { return "队伍号须为整数" }
            store[key] = value
            return nil
        },
        status: { ["commState": "idle", "updateGateAllowed": "true"] }
    )
    return (env, dir)
}


/// 连接 127.0.0.1:port 的 TCP 客户端（WebUI 回环测试用）
func socketConnect(host: String, port: UInt16) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr(host))
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard ok == 0 else { close(fd); return nil }
    return fd
}

func webuiRoutingTests() {
    let (env, dir) = makeWebUITempEnv()
    defer { try? FileManager.default.removeItem(at: dir) }

    // 首页
    let index = WebUIServer.route(method: "GET", target: "/", body: Data(), env: env)
    check(index.status == 200 && String(data: index.body, encoding: .utf8)?.contains("MatchSticks Driver Station") == true,
          "index page serves")

    // 状态
    let status = WebUIServer.route(method: "GET", target: "/api/status", body: Data(), env: env)
    check(status.status == 200 && String(data: status.body, encoding: .utf8)?.contains("updateGateAllowed") == true,
          "status JSON exposes update gate")

    // 设置查看
    let get = WebUIServer.route(method: "GET", target: "/api/settings", body: Data(), env: env)
    check(get.status == 200 && String(data: get.body, encoding: .utf8)?.contains("\"teamNumber\":\"2590\"") == true,
          "settings JSON lists store values")

    // 设置覆盖：合法键应用 + 非法值拒绝 + 未知键拒绝
    let good = Data("{\"teamNumber\":\"2591\",\"soundsEnabled\":\"maybe\",\"evil\":\"1\"}".utf8)
    // 注：mock 校验器只拒 teamNumber 非整数与未知键；soundsEnabled 任意值按 mock 通过
    let apply = WebUIServer.route(method: "POST", target: "/api/settings", body: good, env: env)
    let applyText = String(data: apply.body, encoding: .utf8) ?? ""
    check(apply.status == 200 && applyText.contains("\"teamNumber\"") && applyText.contains("evil"),
          "apply reports applied + rejected keys, got \(applyText)")

    // 坏 JSON / 非平面对象 → 400
    let bad = WebUIServer.route(method: "POST", target: "/api/settings", body: Data("not json".utf8), env: env)
    check(bad.status == 400, "malformed settings body rejected 400")

    // 日志列表 + 下载 + 白名单
    let name = "2099_12_31 23_59_59.dslog"
    FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data([0xAB, 0xCD]))
    FileManager.default.createFile(atPath: dir.appendingPathComponent("hidden.sh").path, contents: Data([0x01]))
    let logs = WebUIServer.route(method: "GET", target: "/api/logs", body: Data(), env: env)
    let logsText = String(data: logs.body, encoding: .utf8) ?? ""
    check(logs.status == 200 && logsText.contains(name) && !logsText.contains("hidden.sh"),
          "logs list shows .dslog only, hides non-whitelisted")

    let dl = WebUIServer.route(method: "GET", target: "/logs/\(name.replacingOccurrences(of: " ", with: "%20"))", body: Data(), env: env)
    check(dl.status == 200 && dl.body == Data([0xAB, 0xCD]), "log download returns exact bytes")

    // 目录逃逸与非法名 → 404（编码后的 ../ 与绝对路径与控制字符）
    for evil in ["/logs/..%2F..%2Fetc%2Fpasswd", "/logs/%2e%2e%2fsecret.dslog", "/logs//etc/passwd.dslog", "/logs/%00.dslog", "/logs/a.dslog%00.txt"] {
        let r = WebUIServer.route(method: "GET", target: evil, body: Data(), env: env)
        check(r.status == 404, "traversal attempt rejected: \(evil)")
    }

    // 未知路由 → 404
    check(WebUIServer.route(method: "GET", target: "/nope", body: Data(), env: env).status == 404, "unknown route 404")
}

func webuiSocketRoundTripTests() {
    let (env, dir) = makeWebUITempEnv()
    defer { try? FileManager.default.removeItem(at: dir) }
    FileManager.default.createFile(atPath: dir.appendingPathComponent("x.dsrec").path, contents: Data(repeating: 7, count: 32))

    let server = WebUIServer(port: 0, environment: env) // 内核分配端口，避免与真实实例冲突
    var serverLogs: [String] = []
    let logLock = NSLock()
    server.onLog = { line in
        logLock.lock(); serverLogs.append(line); logLock.unlock()
    }
    server.start()
    var port: UInt16 = 0
    for _ in 0..<100 where port == 0 { // 轮询 boundPort（最多 ~5s）
        usleep(50_000)
        port = server.boundPort
    }
    logLock.lock(); let logs = serverLogs.joined(separator: " | "); logLock.unlock()
    check(port > 0, "server binds ephemeral port (got \(port); logs: \(logs))")
    guard port > 0 else { return }

    func httpGet(_ raw: String) -> String? {
        guard let fd = socketConnect(host: "127.0.0.1", port: port) else { return nil }
        defer { close(fd) }
        guard WebUIServer.send(fd, Data(raw.utf8)) else { return nil }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.range(of: Data("}\r\n".utf8)) != nil || data.count > 1_000_000 { break }
        }
        return String(data: data, encoding: .utf8)
    }

    let resp1 = httpGet("GET /api/status HTTP/1.1\r\nHost: localhost\r\n\r\n")
    check(resp1?.hasPrefix("HTTP/1.1 200") == true && resp1?.contains("updateGateAllowed") == true,
          "socket GET /api/status round trip")

    let body = "{\"teamNumber\":\"1234\"}"
    let post = "POST /api/settings HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    let resp2 = httpGet(post)
    check(resp2?.hasPrefix("HTTP/1.1 200") == true && resp2?.contains("teamNumber") == true,
          "socket POST /api/settings round trip")

    let resp3 = httpGet("GET /logs/x.dsrec HTTP/1.1\r\nHost: localhost\r\n\r\n")
    check(resp3?.hasPrefix("HTTP/1.1 200") == true && resp3?.contains("Content-Type: application/octet-stream") == true,
          "socket log download round trip")

    server.stop()
}


// MARK: Phase 4 — MOCK 摄像头通道 + 限流器

func mockCameraServerTests() {
    let server = MockCameraServer(port: 0, frameProvider: {
        Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x01, 0xFF, 0xD9]) // JPEG 魔数首尾的最小帧
    })
    server.start()
    var port: UInt16 = 0
    for _ in 0..<100 where port == 0 {
        usleep(50_000)
        port = server.boundPort
    }
    check(port > 0, "mock camera binds ephemeral port (got \(port))")
    guard port > 0 else { return }

    func httpGetRaw(_ path: String) -> Data? {
        guard let fd = socketConnect(host: "127.0.0.1", port: port) else { return nil }
        defer { close(fd) }
        guard WebUIServer.send(fd, Data("GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)) else { return nil }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        return data
    }
    func headerText(_ raw: Data?) -> String {
        // 只解码头部终止符之前的字节——prefix(512) 会把二进制帧体带进来，UTF-8 解码必 nil
        guard let raw else { return "" }
        let headData = raw.range(of: Data("\r\n\r\n".utf8)).map { raw.subdata(in: raw.startIndex..<$0.lowerBound) } ?? raw
        return String(data: headData, encoding: .utf8) ?? ""
    }
    func bodyAfterHeader(_ raw: Data?) -> Data {
        guard let raw, let range = raw.range(of: Data("\r\n\r\n".utf8)) else { return Data() }
        return raw.subdata(in: range.upperBound..<raw.endIndex)
    }

    let frame = httpGetRaw("/frame.jpg")
    check(headerText(frame).hasPrefix("HTTP/1.1 200") && headerText(frame).contains("Content-Type: image/jpeg"),
          "frame request returns JPEG content type")
    // 帧字节完整送达：头之后恰好是 8 字节 mock JPEG（FF D8 开头 FF D9 结尾）
    let body = bodyAfterHeader(frame)
    check(body == Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x01, 0xFF, 0xD9]), "frame body carries mock JPEG bytes, got \(body.map { String(format: "%02X", $0) })")

    let miss = httpGetRaw("/nope")
    check(headerText(miss).hasPrefix("HTTP/1.1 404"), "unknown path 404")

    // 第二次请求仍然成功（无状态、可持续刷新）
    check(headerText(httpGetRaw("/frame.jpg")).hasPrefix("HTTP/1.1 200"), "second frame fetch works")

    server.stop()
}

func rateLimiterTests() {
    // 时钟注入：确定性验证限流窗口（给定条件可复现）
    final class ClockBox { var t = Date(timeIntervalSince1970: 1000) }
    let clock = ClockBox()
    let limiter = RateLimiter(minInterval: 1.0, now: { clock.t })
    check(limiter.allow() == true, "first request allowed")
    clock.t = clock.t.addingTimeInterval(0.4)
    check(limiter.allow() == false, "request inside window rejected")
    check(abs(limiter.retryAfterSeconds() - 0.6) < 0.01, "retry-after reports remaining window")
    clock.t = clock.t.addingTimeInterval(0.61)
    check(limiter.allow() == true, "request after window allowed")
    // 连续两次成功放行之间的实际间隔 ≥ 窗口
    clock.t = clock.t.addingTimeInterval(0.99)
    check(limiter.allow() == false, "boundary (0.99 < 1.0) still rejected")
}


// MARK: Phase 4 — 0x2E 手柄输出 tag：金样本编码 + 解码往返（协议侧验证）

func rumbleTagGoldenTests() {
    // 编码器字节级金样本：槽 0 联调确定值 → [size=12][0x2E][20 40 80 12 34 23 45 34 56 45 67]
    let tag = MRCPackets.slotOutputsTag([.loopbackPattern])
    check(Array(tag) == [0x0C, 0x2E, 0x20, 0x40, 0x80, 0x12, 0x34, 0x23, 0x45, 0x34, 0x56, 0x45, 0x67],
          "0x2E 金样本字节，got " + tag.map { String(format: "%02X", $0) }.joined())
    // 双槽：size = 1 + 22
    let two = MRCPackets.slotOutputsTag([.loopbackPattern, .loopbackPattern])
    check(two.count == 1 + 1 + 22 && two[0] == 23, "双槽 size 字节 = 1+22（got \(two[0])）")
    // 超过 6 槽截断（协议上限 6）
    let seven = MRCPackets.slotOutputsTag(Array(repeating: MRCSlotOutput(), count: 7))
    check(seven[0] == UInt8(1 + 11 * 6), "7 槽截断为 6（size=\(seven[0])）")
}

func rumbleTagRoundTripTests() {
    // 编码 → 完整应答包 → 解码：非零值全字段往返（LED + 四路 rumble）
    let payload = MRCPackets.slotOutputsTag([.loopbackPattern, .loopbackPattern])
    let reply = MRCPackets.replyPacket(seq: 0x0102, mode: .teleoperated, enabled: false,
                                       batteryVolts: 12.0, payload: payload)
    guard let decoded = MRCPackets.decodeReply(reply) else {
        check(false, "带 0x2E 的应答包应可解码"); return
    }
    check(decoded.slotOutputs.count == 2, "解码出 2 槽（\(decoded.slotOutputs.count)）")
    guard decoded.slotOutputs.count == 2 else { return }
    let a0 = decoded.slotOutputs[0]
    check(a0 == .loopbackPattern, "槽 0 全字段往返一致（LED/四路 rumble）")
    check(decoded.batteryVoltage > 11.9 && decoded.batteryVoltage < 12.1, "其余字段不受 tag 影响")
    // 与既有 92B 金样本的兼容：全零 0x2E（mrcGoldenPacketTests 里的 92B 包）仍然可解
    var zeroPayload = ByteWriter()
    zeroPayload.u8(0x43); zeroPayload.u8(0x2E)
    for _ in 0..<6 {
        zeroPayload.u8(0); zeroPayload.u8(0); zeroPayload.u8(0)
        zeroPayload.u16be(0); zeroPayload.u16be(0); zeroPayload.u16be(0); zeroPayload.u16be(0)
    }
    let legacy = MRCPackets.replyPacket(seq: 0x0123, mode: .teleoperated, enabled: false,
                                        batteryVolts: 12.0, payload: Data(zeroPayload.data))
    check(MRCPackets.decodeReply(legacy)?.slotOutputs.count == 6, "全零 0x2E 六槽兼容可解")
}

func runAllPhase4Tests() {
    runTest("updateSafetyGateMatrix", updateSafetyGateMatrix)
    runTest("updateSafetyGateReasonPrecedence", updateSafetyGateReasonPrecedence)
    runTest("updateSafetyGateBlockingDrivesUiState", updateSafetyGateBlockingDrivesUiState)
    runTest("webuiRoutingTests", webuiRoutingTests)
    runTest("webuiSocketRoundTripTests", webuiSocketRoundTripTests)
    runTest("mockCameraServerTests", mockCameraServerTests)
    runTest("rateLimiterTests", rateLimiterTests)
    runTest("rumbleTagGoldenTests", rumbleTagGoldenTests)
    runTest("rumbleTagRoundTripTests", rumbleTagRoundTripTests)
}
