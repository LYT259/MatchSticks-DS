
// MARK: Phase 3/4：msgpack + protobuf-lite + NT4 server 往返

import Network

func msgPackTests() {
    // 正负整数 / bool / double / string / bin / 数组 的 pack→unpack 往返
    let packed = MsgPack.pack([Int64(1), Int64(300), Int64(-5), true, 12.5, "hello", Data([0xAB, 0xCD])] as [Any])
    print("  [dbg] packed=" + [UInt8](packed).map { String(format: "%02X", $0) }.joined(separator: " ") + " count=" + String(packed.count))
    let unpacked: [Any]
    do { unpacked = try MsgPack.unpackAll(packed) }
    catch { print("  [dbg] UNPACK THROWN: \(error)"); unpacked = [] }
    check(unpacked.count == 1, "顶层单数组（\(unpacked.count)）")
    guard let arr = unpacked.first as? [Any] else { check(false, "顶层数组"); return }
    check(arr.count == 7, "msgpack 元素数（\(arr.count)）")
    check((arr[0] as? Int64) == 1, "小整数（fixint）")
    check((arr[1] as? Int64) == 300, "uint16 整数")
    check((arr[2] as? Int64) == -5, "负整数")
    check((arr[3] as? Bool) == true, "布尔")
    check((arr[4] as? Double) == 12.5, "float64")
    check((arr[5] as? String) == "hello", "字符串")
    check((arr[6] as? Data) == Data([0xAB, 0xCD]), "bin")

    // NT4 值帧形态：[id, ts_us, type_id, value]（大整数时间戳）
    let frame = MsgPack.pack([Int64(3), Int64(1_700_000_000_123_456), Int(5), Data([1, 2, 3])] as [Any])
    let frames = (try? MsgPack.unpackAll(frame)) as? [[Any]]
    check(frames?.count == 1, "值帧单条")
    check((frames?.first?.count) == 4, "值帧四元组")
}

func protobufLiteTests() {
    // 手工推演金样本：MatchTime=0 / 无手柄 / CurrentOpMode=1 / ControlWord=5 / GameData=""
    let data = ProtobufLite.mrcControlData(controlWord: 5, matchTimeSec: 0,
                                           joysticks: [], currentOpMode: 1, gameData: "")
    check([UInt8](data) == [
        0x10, 0x00,                                              // field2 varint 0
        0x21, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,    // field4 fixed64 1
        0x28, 0x05,                                              // field5 varint 5
        0x32, 0x00,                                              // field6 空串
    ], "ControlData 金样本（" + [UInt8](data).map { String(format: "%02X", $0) }.joined() + "）")

    // JoystickData 子消息非空
    let js = ProtobufLite.JoystickWire(buttons: 0b101, buttonCount: 3,
                                       axes: [0.0], povsPacked: 0xFFFF)
    let jd = ProtobufLite.mrcJoystickData(js)
    check(jd.contains(0x10), "JoystickData AvailableButtons varint 字段（field2 uint64 走 varint，key 0x10）")
}

func nt4ServerTests() {
    final class Box: @unchecked Sendable {
        var announced = false
        var gotValue: (name: String, value: NT4Server.NT4Value)? = nil
        var gotBinary: Data? = nil
        var lock = NSLock()
    }
    let box = Box()

    let server = NT4Server(port: 18_767)
    server.onValue = { name, value in
        box.lock.lock(); box.gotValue = (name, value); box.lock.unlock()
    }
    server.start()
    Thread.sleep(forTimeInterval: 0.3)

    // 裸 WebSocket 客户端（RFC6455；服务器要求 Upgrade 握手）
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(18_767).bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    check(connected == 0, "NT4：TCP 连接")
    var tv = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let handshake = "GET /nt/test HTTP/1.1\r\nHost: 127.0.0.1:18767\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    let handshakeData = Data(handshake.utf8)
    _ = handshakeData.withUnsafeBytes { raw in send(sock, raw.baseAddress, raw.count, 0) }
    // 读握手响应头（至 \r\n\r\n）
    var headerData = Data()
    var byte: UInt8 = 0
    while headerData.count < 4096 {
        let n = recv(sock, &byte, 1, 0)
        guard n == 1 else { break }
        headerData.append(byte)
        if [UInt8](headerData.suffix(4)) == [0x0D, 0x0A, 0x0D, 0x0A] { break }
    }
    let headerText = String(decoding: headerData, as: UTF8.self)
    check(headerText.contains("101"), "握手 101（" + headerText.prefix(40) + "）")
    check(headerText.contains("v4.1.networktables.first.wpi.edu"), "子协议回显")

    func sendClientFrame(opcode: UInt8, payload: Data) {
        var frame = Data([0x80 | opcode])
        // 客户端帧按 RFC 必须掩码；服务器实现兼容带/不带掩码
        let mask: [UInt8] = [0x11, 0x22, 0x33, 0x44]
        if payload.count < 126 {
            frame.append(UInt8(0x80 | payload.count))
        } else {
            frame.append(UInt8(0x80 | 126))
            frame.append(UInt8(payload.count >> 8)); frame.append(UInt8(payload.count & 0xFF))
        }
        frame.append(contentsOf: mask)
        var masked = [UInt8](payload)
        for i in 0..<masked.count { masked[i] ^= mask[i % 4] }
        frame.append(contentsOf: masked)
        frame.withUnsafeBytes { raw in _ = send(sock, raw.baseAddress, raw.count, 0) }
    }

    func recvServerFrame() -> (opcode: UInt8, payload: Data)? {
        // 用与服务器同款的读帧逻辑（无掩码）
        return NT4Server.readTestFrame(sock)
    }

    // ① publish → announce
    sendClientFrame(opcode: 0x1, payload: Data("[{\"method\":\"publish\",\"params\":{\"name\":\"/Netcomm/Status/HasUserCode\",\"pubuid\":1,\"type\":\"boolean\",\"properties\":{}}}]".utf8))
    if let (op, payload) = recvServerFrame() {
        check(op == 0x1, "announce 为文本帧")
        let text = String(decoding: payload, as: UTF8.self)
        check(text.contains("announce") && text.contains("HasUserCode"), "announce 内容（\(text.prefix(80))）")
    } else { check(false, "announce 帧未收到") }

    // ② 服务端发布 + 客户端订阅 + 服务端 set → 客户端收值帧
    server.publish(name: "/Dscomm/Control/ControlData", type: "proto:mrc.proto.ProtobufControlData")
    sendClientFrame(opcode: 0x1, payload: Data("[{\"method\":\"subscribe\",\"params\":{\"topics\":[\"/Dscomm/Control/\"],\"subuid\":7,\"options\":{\"prefix\":true,\"all\":true}}}]".utf8))
    Thread.sleep(forTimeInterval: 0.3) // 订阅处理
    server.set(name: "/Dscomm/Control/ControlData", .raw(Data([1, 2, 3])))
    var gotBinary: Data?
    for _ in 0..<3 {
        if let (op, payload) = recvServerFrame(), op == 0x2 {
            gotBinary = payload
            break
        }
    }
    check(gotBinary != nil, "server.set → 值帧下发")
    if let payload = gotBinary {
        let arr = (try? MsgPack.unpackAll(payload)) as? [[Any]]
        check(arr?.count == 1 && arr?[0].count == 4, "值帧四元组")
        check((arr?[0][2] as? Int64) == 5, "raw type_id=5")
        check((arr?[0][3] as? Data) == Data([1, 2, 3]), "raw payload 往返")
    }

    // ③ 客户端发值 → server.onValue
    let valueFrame = MsgPack.pack([Int64(1), Int64(123_456), Int(0), true] as [Any])
    sendClientFrame(opcode: 0x2, payload: valueFrame)
    for _ in 0..<20 {
        box.lock.lock()
        let got = box.gotValue
        box.lock.unlock()
        if let g = got {
            check(g.name == "/Netcomm/Status/HasUserCode", "客户端值 topic（\(g.name)）")
            if case .boolean(let b) = g.value { check(b == true, "布尔值") } else { check(false, "布尔值类型") }
            break
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    close(sock)
    server.stop()
}


func runAllPhase3Tests() {
    runTest("msgPackTests", msgPackTests)
    runTest("protobufLiteTests", protobufLiteTests)
    runTest("nt4ServerTests", nt4ServerTests)
}


// MARK: Phase 3：CRC32C + MRC V2 协议（金样本 = Compatibility Proxy 文档 §8 实测包）

func crc32cTests() {
    check(CRC32C.checksum(Array("123456789".utf8)) == 0xE3069283, "CRC32C 标准向量")
    check(CRC32C.checksum([]) == 0x00000000, "CRC32C 空输入")
}

func mrcGoldenPacketTests() {
    // 文档 §8：robot_sim.py 对 seq=0x0123、有代码、失能状态的真实应答包
    var payload = Data([0x43, 0x2E]) + Data(repeating: 0, count: 66)
    _ = payload
    let golden = Data([
        0x01, 0x23,                                     // seq
        0x02,                                           // comm version
        0x20,                                           // ctrl: HasCode, disabled, mode=Unknown
        0x61,                                           // status: WatchdogFed | HasUserCodeReady | HasUserCode
        0x0C, 0x00,                                     // battery 12.0V
        0x00,                                           // flags
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // reserved
        0xA7, 0x26, 0xDC, 0xC3,                         // payload CRC32C LE
        0x96, 0xCF, 0x7C, 0x5D,                         // header CRC32C LE
        0x43, 0x2E,                                     // tag: len 0x43, id 0x2E
    ] + Array(repeating: 0, count: 66))
    let decoded = MRCPackets.decodeReply(golden)
    check(decoded != nil, "金样本包 CRC 校验通过")
    check(decoded?.seq == 0x0123, "seq 回显")
    check(decoded?.mode == .unknown, "mode Unknown")
    check(decoded?.enabled == false, "失能")
    check(decoded?.hasCode == true, "HasCode")
    check(decoded?.watchdogFed == true, "WatchdogFed")
    check(decoded?.hasUserCode == true && decoded?.hasUserCodeReady == true, "用户代码就绪位")
    check(abs((decoded?.batteryVoltage ?? 0) - 12.0) < 0.001, "电池 12.0V")
    check(decoded?.slotOutputs.count == 6, "6 手柄槽位输出（" + String(decoded?.slotOutputs.count ?? 0) + "）")

    // 编码器应产出逐字节相同的包
    let slots = (0..<6).map { _ in MRCSlotOutput() }
    var payloadData = Data([0x43, 0x2E])
    for slot in slots {
        var w = ByteWriter()
        w.u8(slot.ledR); w.u8(slot.ledG); w.u8(slot.ledB)
        w.u16be(slot.leftRumble); w.u16be(slot.rightRumble)
        w.u16be(slot.leftTriggerRumble); w.u16be(slot.rightTriggerRumble)
        payloadData.append(Data(w.data))
    }
    let encoded = MRCPackets.replyPacket(seq: 0x0123, mode: .unknown, enabled: false,
                                         hasCode: true, batteryVolts: 12.0, payload: payloadData)
    check(encoded == golden, "编码器复现金样本（\(Array(encoded.prefix(24)).map { String(format: "%02X", $0) }.joined())）")

    // 单字节翻转 → CRC 拒绝
    var corrupted = golden
    corrupted[30] ^= 0xFF
    check(MRCPackets.decodeReply(corrupted) == nil, "坏 CRC 拒绝")

    // 错误包
    check(MRCPackets.decodeErrorPacket(Data([0x01, 0x23, 0xFF, 0x65, 0, 0, 0, 0])) == 101, "0xFF 错误包错误码 101")
}

func mrcControlRoundTrip() {
    var control = MRCControlWord()
    control.enabled = true
    control.autonomous = true
    var js = JoystickData(axes: [-1.0, 0.5], buttonCount: 9, buttons: 0b101, povs: [270])
    js.buttonCount = 9
    let packet = MRCPackets.controlPacket(seq: 77, control: control, alliance: .blue2,
                                          joysticks: [js], matchTime: 15.5)
    let decoded = MRCPackets.decodeControl(packet)
    check(decoded != nil, "MRC 控制包解码")
    check(decoded?.seq == 77, "seq")
    check(decoded?.control.enabled == true && decoded?.control.autonomous == true, "控制位")
    check(decoded?.control.test == false, "test 位未误置")
    check(decoded?.request.normal == true, "RequestNormal 默认置位")
    check(decoded?.alliance == .blue2, "alliance")
    check(decoded?.joysticks.count == 1, "手柄数")
    check(decoded?.joysticks.first?.buttons == 0b101, "按钮位")
    check(decoded?.joysticks.first?.povs == [270], "POV")
    check((decoded?.matchTime.map { abs($0 - 15.5) < 0.01 }) == true, "match time")
}

func mrcOpModesTests() {
    let ops = [
        MRCOpModeInfo(name: "TensorFlow Detect", group: "Auto", description: "vision auto",
                      hash: (1 << 56) | 0x1234),
        MRCOpModeInfo(name: "Teleop Main", group: "Teleop", description: "main teleop",
                      hash: (2 << 56) | (1 << 58) | 0x5678),
    ]
    let tag = MRCPackets.opModesTag(ops)
    let (frames, _) = NICodec.extractTCPFrames(from: tag)
    check(frames.count == 1 && frames[0].id == 0x13, "0x13 帧")
    let decoded = MRCPackets.decodeOpModes(frames[0].payload)
    check(decoded == ops, "OpMode 列表往返")
    // 空字符串元素应被拒（DS 语义：任一字符串为空即弃整个列表）
    let bad = MRCPackets.decodeOpModes(Data([1, 0, 5]) + Data("Group".utf8) + Data([5]) + Data("Descr".utf8) + Data(repeating: 0, count: 12))
    check(bad.isEmpty, "空 name 元素被拒")
}

func mrcLoopbackScenario() {

    let server = MRCResponder()
    server.start()
    Thread.sleep(forTimeInterval: 0.05)

    // 简化：直接用 client 层（protocolKind .mrc）——需 DSClient 支持，此处先用 codec 对打验证
    // 起一个 NI DSClient 会拿到 MRC 应答（版本字节 0x02）→ NI 解码失败 → 不会误判连接
    let sink = ClientSink()
    let boot = Date()
    let client = DSClient()
    client.eventHandler = { sink.observe($0) }
    client.updateConfig { $0.manualIP = "127.0.0.1" }
    client.snapshotProvider = {
        var snap = DSClient.Snapshot()
        snap.control.enabled = Date().timeIntervalSince(boot) > 0.5
        snap.control.mode = .autonomous
        return snap
    }
    client.start()
    Thread.sleep(forTimeInterval: 2.0)
    client.stop()
    server.stop()

    sink.lock.lock(); defer { sink.lock.unlock() }
    check(server.rawPackets >= 60, "MRC 场景：NI 模式 DS 持续发控制包（线缆 \(server.rawPackets)）")
    check(server.packets == 0, "MRC 场景：NI 格式包被 MRC 解码器全部拒绝（\(server.packets)）")
    // NI 解码器读 MRC 应答（0x02 版本）应拒绝 → 不误建链（避免误驱动 SystemCore）
    check(sink.connectedCount == 0, "MRC 场景：NI 解码器不认 MRC 应答（正确行为）")
}


// MARK: WPILog 编码/读取 单测（2027 VarInt 布局，依据 allwpilib datalog 模块核查）

func wpilogTests() {
    // 记录头 VarInt 金样本：entry=1, payloadSize=5, ts=123456789ms(=0x075BCD15, 4B LE)
    let header = WPILogFormat.recordHeader(entry: 1, timestampMs: 123_456_789, payloadSize: 5)
    check(header == [0x30, 0x01, 0x05, 0x15, 0xCD, 0x5B, 0x07],
          "记录头金样本（" + header.map { String(format: "%02X", $0) }.joined() + "）")
    // 大数值：entry=300 → 2 字节 LE (AC 01)
    let header2 = WPILogFormat.recordHeader(entry: 300, timestampMs: 1, payloadSize: 1)
    check(header2 == [0x01, 0x2C, 0x01, 0x01, 0x01], "多字节 entry 变长（" + header2.map { String(format: "%02X", $0) }.joined() + "）")

    // 全文件往返：START/double/boolean/string/FINISH
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ghds-\(Int.random(in: 0...999_999)).wpilog")
    var ts = Int64(1_700_000_000_000)
    let writer = try! WPILogWriter(fileURL: url, timestampProvider: { ts })
    let batteryID = writer.startEntry(name: "/DS/Battery", type: "double", metadata: "{\"unit\":\"V\"}")
    let enabledID = writer.startEntry(name: "/DS/Enabled", type: "boolean")
    writer.appendDouble(batteryID, 12.42)
    writer.appendBoolean(enabledID, true)
    ts += 20
    writer.appendDouble(batteryID, 12.39)
    writer.finishEntry(enabledID)
    writer.close()

    let file = try! WPILogFile(fileURL: url)
    check(file.entries.count == 2, "wpilog START 解码 2 条（" + String(file.entries.count) + "）")
    check(file.entries[0].name == "/DS/Battery" && file.entries[0].type == "double", "entry 名称/类型")
    check(file.entries[0].metadata == "{\"unit\":\"V\"}", "metadata 往返")
    check(file.records.count == 6, "记录总数 6（" + String(file.records.count) + "）")

    // 数据记录解码：double 与 boolean
    let dataRecords = file.records.filter { $0.entry != 0 }
    let doubles = dataRecords.filter { $0.entry == batteryID }
    check(doubles.count == 2, "battery 数据记录 2 条")
    let v0 = doubles[0].payload.reduce(0.0) { acc, b in
        var d = acc; d = d / 256.0 + Double(b) / 256.0; return d // 占位
    }
    _ = v0
    let battery0 = Double(bitPattern: doubles[0].payload.prefix(8).reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
    check(abs(battery0 - 12.42) < 0.0001, "double 往返（" + String(battery0) + "）")
    let enabledRecords = dataRecords.filter { $0.entry == enabledID }
    check(enabledRecords.first?.payload.first == 1, "boolean 真")

    // FINISH 记录（entry=0, payload[0]=0x01）
    let finishes = file.records.filter { $0.entry == 0 && $0.payload.first == 0x01 }
    check(finishes.count == 1, "FINISH 记录 1 条")

    // 坏魔数
    check((try? WPILogFile(data: Data("NOTWPILOG!!".utf8))) == nil, "坏魔数拒绝")
    try? FileManager.default.removeItem(at: url)
}


// MARK: SettingsStore 单测

func settingsStoreTests() {
    let name = "ghds-test-" + String(Int.random(in: 0...999_999))
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = SettingsStore(defaults: defaults, prefix: "p1.")

    check(store.integer("team") == nil, "缺省键读出 nil")
    store.set("team", 254)
    check(store.integer("team") == 254, "整型往返")
    store.set("ip", "10.0.0.2")
    check(store.string("ip") == "10.0.0.2", "字符串往返")
    store.set("auto", 1.5)
    check(abs((store.double("auto") ?? 0) - 1.5) < 0.0001, "浮点往返")
    store.set("flag", false)
    check(store.bool("flag") == false, "布尔往返（含 false）")
    store.set("ip", nil as String?)
    check(store.string("ip") == nil, "删除键")

    // 前缀隔离
    let other = SettingsStore(defaults: defaults, prefix: "p2.")
    check(other.integer("team") == nil, "不同前缀互不可见")
    check(store.integer("team") == 254, "原前缀不受影响")
}

// MARK: RadioProbe 单测（本机 TCP 监听模拟 radio）

func radioProbeTests() {
    // 监听 127.0.0.1:18123（可达）
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    var yes: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(18_123).bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(listener, 4) == 0 else {
        check(false, "radio 测试监听失败")
        return
    }

    let probe = RadioProbe(configuration: RadioProbe.Configuration(interval: 0.5, timeout: 0.5, port: 18_123))
    probe.hostProvider = { return (host: "127.0.0.1", port: 18_123) }
    probe.start()
    Thread.sleep(forTimeInterval: 1.6)
    check(probe.isReachable, "监听时可达（attempts " + String(probe.probeAttempts) + "）")

    // 关闭监听 → 不可达
    close(listener)
    Thread.sleep(forTimeInterval: 1.6)
    check(!probe.isReachable, "监听关闭后不可达")
    check(probe.probeAttempts >= 4, "探测按间隔进行（" + String(probe.probeAttempts) + " 次）")
    probe.stop()
}

// MARK: TCP 连接退避单测（无 TCP 监听的场景服务器 → 尝试数有界）

func tcpBackoffScenario() {
    let server = ScenarioServer() // 只有 UDP，1740 不监听
    server.start()
    Thread.sleep(forTimeInterval: 0.05)
    var captured: DSClient?
    let sink = runScenarioClient(
        heartbeatStale: { _ in false },
        intent: { t in (enabled: t > 0.5, estop: false) },
        duration: 4.0,
        onClient: { captured = $0 }
    )
    server.stop()
    sink.lock.lock(); defer { sink.lock.unlock() }
    check(sink.connectedCount >= 1, "退避场景：UDP 链路正常建立")
    if let client = captured {
        check(client.tcpConnectAttempts <= 6,
              "TCP 连接尝试有界（4s 内 " + String(client.tcpConnectAttempts) + " 次，无风暴则 ≤6）")
    } else {
        check(false, "退避场景：未捕获 client")
    }
}


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
    // 下限 8Hz × 3s（CI VM 定时器降频容差，见长跑注）
    check(controlCount >= 24, "录制：控制包 ≥24（" + String(controlCount) + "）")
    check(responseCount >= 24, "录制：应答包 ≥24（" + String(responseCount) + "）")

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

final class MRCResponder {
    var rxSock: Int32 = -1
    var txSock: Int32 = -1
    private(set) var packets = 0        // 通过 MRC 解码的包
    private(set) var rawPackets = 0     // 线缆上收到的包（含被拒的）
    private(set) var sawEnabled = false
    private(set) var sawAuto = false
    private var stopFlag = false
    private var seq: UInt16 = 0

    func start() {
        rxSock = socket(AF_INET, SOCK_DGRAM, 0)
        txSock = socket(AF_INET, SOCK_DGRAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = NICodec.udpControlPort.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(rxSock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var txAddr = addr
        txAddr.sin_port = NICodec.udpResponsePort.bigEndian
        _ = withUnsafePointer(to: &txAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(txSock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        Thread.detachNewThread { [weak self] in self?.loop() }
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
            rawPackets += 1
            guard let packet = MRCPackets.decodeControl(Data(buf[0..<n])) else { continue }
            packets += 1
            if packet.control.enabled { sawEnabled = true }
            if packet.control.autonomous { sawAuto = true }

            seq &+= 1
            var payload = ByteWriter()
            payload.u8(0x43); payload.u8(0x2E)
            for _ in 0..<6 {
                payload.u8(0); payload.u8(0); payload.u8(0)
                payload.u16be(0); payload.u16be(0); payload.u16be(0); payload.u16be(0)
            }
            let reply = MRCPackets.replyPacket(seq: packet.seq, mode: packet.control.autonomous ? .autonomous : .teleoperated,
                                               enabled: packet.control.enabled && !packet.control.estop,
                                               batteryVolts: 12.1,
                                               payload: Data(payload.data))
            withUnsafePointer(to: &src) { dst in
                dst.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    reply.withUnsafeBytes { raw in
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
    var batteryOK = false

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
            if p.batteryVoltage > 3.0 { batteryOK = true }
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
                       duration: Double,
                       onClient: ((DSClient) -> Void)? = nil,
                       protocolKind: DSClient.ProtocolKind = .ni) -> ClientSink {
    let sink = ClientSink()
    let boot = Date()
    let client = DSClient()
    onClient?(client)
    client.eventHandler = { sink.observe($0) }
    client.heartbeatAge = { heartbeatStale(Date().timeIntervalSince(boot)) ? 1.0 : 0.0 }
    client.snapshotProvider = {
        var snap = DSClient.Snapshot()
        let i = intent(Date().timeIntervalSince(boot))
        snap.control.enabled = i.enabled
        snap.control.estop = i.estop
        return snap
    }
    client.updateConfig {
        $0.manualIP = "127.0.0.1"
        $0.protocolKind = protocolKind
    }
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
    // 下限 8Hz：本地 50Hz / CI 共享 VM GCD 定时器 ~15Hz 均应通过，仍能抓住本地明显退化
    check(responses >= 240, "长跑：30s 应答数 ≥240@8Hz 下限（" + String(responses) + "）")
    check(server.packets >= 240, "长跑：控制包数 ≥240@8Hz 下限（" + String(server.packets) + "）")
    check(server.enabledEchoCount >= 120, "长跑：使能回显持续（" + String(server.enabledEchoCount) + " 包）")
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

// MARK: Phase 3 场景：MRC 模式 DS ↔ SystemCore 应答器（正向全链路）

func mrcClientScenario() {
    let server = MRCResponder()
    server.start()
    Thread.sleep(forTimeInterval: 0.05)
    let sink = runScenarioClient(
        heartbeatStale: { _ in false },
        intent: { t in (enabled: t > 0.5, estop: false) },
        duration: 2.5,
        protocolKind: .mrc
    )
    server.stop()
    sink.lock.lock(); defer { sink.lock.unlock() }
    check(sink.connectedCount >= 1, "MRC 正向：连接建立")
    check(sink.responses >= 30, "MRC 正向：应答 ≥30（\(sink.responses)）")
    check(sink.batteryOK, "MRC 正向：电池解码")
    check(server.sawEnabled, "MRC 正向：使能指令到达")
}

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
    runTest("settingsStoreTests", settingsStoreTests)
    runTest("radioProbeTests", radioProbeTests)
    runTest("tcpBackoffScenario", tcpBackoffScenario)
    runTest("wpilogTests", wpilogTests)
    runTest("crc32cTests", crc32cTests)
    runTest("mrcGoldenPacketTests", mrcGoldenPacketTests)
    runTest("mrcControlRoundTrip", mrcControlRoundTrip)
    runTest("mrcOpModesTests", mrcOpModesTests)
    runTest("mrcLoopbackScenario", mrcLoopbackScenario)
    runTest("mrcClientScenario", mrcClientScenario)
    runTest("msgPackTests", msgPackTests)
    runTest("protobufLiteTests", protobufLiteTests)
    runTest("nt4ServerTests", nt4ServerTests)
}
