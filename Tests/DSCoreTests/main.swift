
// MARK: 回环集成测试：真 DSClient ↔ 极简 roboRIO 应答器（UDP 1110 → 1150）

import Darwin

final class LoopbackResponder {
    var rxSock: Int32 = -1
    var txSock: Int32 = -1
    var sawEnabled = false
    var sawEstop = false
    var packetsSeen = 0
    var requestDateSent = false
    private var stopFlag = false

    func start() {
        rxSock = socket(AF_INET, SOCK_DGRAM, 0)
        txSock = socket(AF_INET, SOCK_DGRAM, 0)
        _ = fcntl(rxSock, F_SETFL, fcntl(rxSock, F_GETFL, 0) | O_NONBLOCK)
        guard bindChecked(rxSock, port: NICodec.udpControlPort, what: "回环应答器 控制口") else { return }
        _ = bindChecked(txSock, port: NICodec.udpResponsePort, soft: true,
                        what: "回环应答器 应答口（soft 恒不绑 1150，避免占用 DS 监听端口）")
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
            if n <= 0 { Thread.sleep(forTimeInterval: 0.02); continue }
            guard let packet = NICodec.decodeControl(Data(buf[0..<n])) else { continue }
            packetsSeen += 1
            if packet.control.enabled { sawEnabled = true }
            if packet.control.estop { sawEstop = true }

            seq &+= 1
            var w = ByteWriter()
            w.u16be(seq); w.u8(NICodec.commVersion)
            var status = RobotStatus()
            status.enabled = packet.control.enabled && !packet.control.estop
            status.mode = packet.control.mode
            w.u8(status.raw)
            var trace = RobotTrace(); trace.isRoboRIO = true; trace.disabled = !status.enabled
            w.u8(trace.raw)
            w.u16be(0x0C40) // 12.25V
            w.u8(requestDateSent ? 0x00 : 0x01)
            requestDateSent = true
            var ram = ByteWriter(); ram.u32be(1); ram.u32be(2)
            NICodec.appendTag(0x06, ram.data, to: &w)
            var disk = ByteWriter(); disk.u32be(3)
            NICodec.appendTag(0x04, disk.data, to: &w)

            let sent = withUnsafePointer(to: &src) { dst in
                dst.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    w.data.withUnsafeBytes { raw in
                        sendto(txSock, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            _ = sent
        }
    }

    func stop() {
        stopFlag = true
        if rxSock >= 0 { shutdown(rxSock, SHUT_RDWR); close(rxSock) }
        if txSock >= 0 { close(txSock) }
    }
}

func loopbackIntegrationTest() {
    let responder = LoopbackResponder()
    responder.start()
    Thread.sleep(forTimeInterval: 0.05)

    final class Sink: @unchecked Sendable {
        var responses = 0
        var connected = false
        var battery: Float = 0
        var statsLoss: Double = -1
        var lock = NSLock()
    }
    let sink = Sink()
    let boot = Date()

    let client = DSClient()
    client.eventHandler = { event in
        sink.lock.lock(); defer { sink.lock.unlock() }
        switch event {
        case .commState(.connected): sink.connected = true
        case .response(let p):
            sink.responses += 1
            sink.battery = p.batteryVoltage
        case .stats(let loss, _, _, _): sink.statsLoss = loss
        default: break
        }
    }
    client.updateConfig { cfg in
        cfg.manualIP = "127.0.0.1"
    }
    client.snapshotProvider = {
        var snap = DSClient.Snapshot()
        // 0.5s 后使能（测试时间基点：client 启动后由 responder 状态间接驱动）
        if Date().timeIntervalSince(boot) > 0.5 { snap.control.enabled = true }
        return snap
    }
    client.start()
    Thread.sleep(forTimeInterval: 2.6)
    client.stop()
    responder.stop()

    sink.lock.lock(); defer { sink.lock.unlock() }
    check(sink.connected, "commState reached connected")
    check(sink.responses >= 30, "got ≥30 responses @50Hz over ~1.5s (got \(sink.responses))")
    check(abs(sink.battery - 12.25) < 0.01, "battery decoded end-to-end (\(sink.battery))")
    check(responder.packetsSeen >= 30, "responder got ≥30 control packets (got \(responder.packetsSeen))")
    check(responder.sawEnabled, "responder observed enable command")
    check(sink.statsLoss >= 0 && sink.statsLoss < 5, "packet loss low (\(sink.statsLoss)%)")
}

import Foundation
import DSCore

// MARK: - NI 协议回归测试（金样本 + 往返 + 容错）
// CLT 工具链无 XCTest / TestingMacros，自带 runner：swift run DSCoreTests

nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var checks = 0

func check(_ cond: Bool, _ label: String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !cond { failures.append("\(file):\(line) — \(label)") }
}

func runTest(_ name: String, _ body: () -> Void) {
    let before = failures.count
    body()
    print(failures.count == before ? "  PASS  \(name)" : "  FAIL  \(name)")
}

// MARK: 控制包（DS → robot）

func controlPacketGoldenMin() {
    var control = ControlWord()
    control.enabled = true
    control.mode = .teleoperated
    let d = NICodec.controlPacket(seq: 1, control: control, request: RequestWord(),
                                  alliance: .red1, joysticks: [])
    check(Array(d) == [0x00, 0x01, 0x01, 0x04, 0x00, 0x00], "golden min control packet, got \(Array(d).map { String(format: "0x%02X", $0) })")
}

func controlPacketGoldenJoystick() {
    var control = ControlWord()
    control.enabled = true
    var js = JoystickData(axes: [1.0, -0.5], buttonCount: 12, buttons: 0, povs: [90, -1])
    js.buttons = (1 << 0) | (1 << 11)
    let d = NICodec.controlPacket(seq: 1, control: control, request: RequestWord(),
                                  alliance: .red1, joysticks: [js])
    check(Array(d) == [
        0x00, 0x01, 0x01, 0x04, 0x00, 0x00,
        0x0C, 0x0C,
        0x02, 0x7F, 0xC0,
        0x0C, 0x01, 0x08,
        0x02, 0x00, 0x5A, 0xFF, 0xFF,
    ], "golden joystick control packet, got \(Array(d).map { String(format: "0x%02X", $0) })")
}

func controlPacketDateAndTimezoneTags() {
    let d = NICodec.controlPacket(seq: 0, control: ControlWord(), request: RequestWord(),
                                  alliance: .blue3, joysticks: [],
                                  date: Date(timeIntervalSince1970: 0), timeZone: "UTC")
    var r = ByteReader(d)
    check(r.u16be() == 0, "seq")
    check(r.u8() == NICodec.commVersion, "comm version")
    _ = r.u8(); _ = r.u8()
    check(r.u8() == 5, "blue3 alliance")
    check(r.u8() == 11, "date tag size")
    check(r.u8() == 0x0F, "date tag id")
    check(r.u32be() == 0, "micros")
    check(r.u8() == 0 && r.u8() == 0 && r.u8() == 0, "sec/min/hour UTC")
    check(r.u8() == 1, "day")
    check(r.u8() == 0, "month-1")
    check(r.u8() == 70, "year-1900")
    check(r.u8() == 4, "tz tag size")
    check(r.u8() == 0x10, "tz tag id")
    check(r.bytes(3).map { String(decoding: $0, as: UTF8.self) } == "UTC", "tz string")
    check(r.isExhausted, "no trailing bytes")
}

func controlDecodeRoundTrip() {
    var control = ControlWord()
    control.estop = true
    control.fmsAttached = true
    control.enabled = true
    control.mode = .autonomous
    var js = JoystickData(axes: [0.5, -1.0, 0.0], buttonCount: 10, buttons: 0b111, povs: [180])
    js.buttonCount = 10
    let packet = NICodec.controlPacket(seq: 4242, control: control, request: RequestWord(),
                                       alliance: .blue2, joysticks: [js], matchTime: 31.5)
    let decoded = NICodec.decodeControl(packet)
    check(decoded != nil, "decodes")
    check(decoded?.seq == 4242, "seq round trip")
    check(decoded?.control == control, "control word round trip")
    check(decoded?.alliance == .blue2, "alliance round trip")
    check(decoded?.joysticks.count == 1, "joystick count")
    check(decoded?.joysticks.first?.buttons == 0b111, "buttons round trip")
    check(decoded?.joysticks.first?.povs == [180], "povs round trip")
    check((decoded?.matchTime.map { abs($0 - 31.5) < 0.01 }) == true, "match time round trip")
}

// MARK: 应答包（robot → DS）

func responseGoldenHeader() {
    let d = Data([0x00, 0xFF, 0x01, 0x06, 0x22, 0x0C, 0x40, 0x01])
    let p = NICodec.decodeResponse(d)
    check(p != nil, "header decodes")
    check(p?.seq == 255, "seq")
    check(p?.status.enabled == true, "status.enabled")
    check(p?.status.mode == .autonomous, "status.mode")
    check(p?.trace.hasRobotCode == true, "trace.hasRobotCode")
    check(p?.trace.teleopMode == true, "trace.teleopMode")
    check(abs((p?.batteryVoltage ?? 0) - 12.25) < 0.001, "battery 12.25, got \(p?.batteryVoltage ?? -1)")
    check(p?.requestDate == true, "requestDate")
}

func responseDecodeTags() {
    var w = ByteWriter()
    w.u16be(7); w.u8(0x01)
    var status = RobotStatus(); status.estop = true; status.brownout = true; status.enabled = true
    w.u8(status.raw)
    var trace = RobotTrace(); trace.isRoboRIO = true; trace.disabled = true
    w.u8(trace.raw)
    w.u16be(0x0C80)
    w.u8(0x00) // requestDate
    var ram = ByteWriter(); ram.u32be(100); ram.u32be(200)
    NICodec.appendTag(0x06, ram.data, to: &w)
    var disk = ByteWriter(); disk.u32be(300)
    NICodec.appendTag(0x04, disk.data, to: &w)
    var can = ByteWriter(); can.f32be(0.25); can.u32be(1); can.u32be(2); can.u8(3); can.u8(4)
    NICodec.appendTag(0x0E, can.data, to: &w)
    var joy = ByteWriter(); joy.u32be(0b101); joy.u16be(11); joy.u16be(22)
    NICodec.appendTag(0x01, joy.data, to: &w)

    let p = NICodec.decodeResponse(w.data)
    check(p != nil, "tags decode")
    check(p?.status.estop == true, "estop bit")
    check(p?.status.brownout == true, "brownout bit")
    check(p?.trace.isRoboRIO == true, "isRoboRIO bit")
    check(p?.ramUsedBytes == 100, "ram used")
    check(p?.ramTotalBytes == 200, "ram total")
    check(p?.diskFreeBytes == 300, "disk free")
    check(abs((p?.can.utilizationPercent ?? 0) - 0.25) < 0.001, "can util")
    check(p?.can.busOffCount == 1, "can busOff")
    check(p?.can.txFullCount == 2, "can txFull")
    check(p?.can.rxErrorCount == 3, "can rxErr")
    check(p?.can.txErrorCount == 4, "can txErr")
    check(p?.joystickOutputs.count == 1, "joy output count")
    check(p?.joystickOutputs.first?.leftRumble == 11, "left rumble")
    check(p?.joystickOutputs.first?.rightRumble == 22, "right rumble")
}

func responseRejectsWrongVersionAndShortData() {
    check(NICodec.decodeResponse(Data([0x00])) == nil, "short packet rejected")
    let bad = Data([0x00, 0x01, 0x02, 0x00, 0x00, 0x0C, 0x40, 0x00])
    check(NICodec.decodeResponse(bad) == nil, "wrong comm version rejected")
}

func malformedTagBounds() {
    var w = ByteWriter()
    w.u16be(1); w.u8(0x01); w.u8(0); w.u8(0); w.u16be(0x0C40); w.u8(0)
    w.u8(0xFF); w.u8(0x06)
    check(NICodec.decodeResponse(w.data) == nil, "oversized tag rejected")
}

// MARK: TCP 1740

func tcpFrameSplitAcrossChunks() {
    let data = Data([0x00, 0x02, 0x0C, 0xAB,
                     0x00, 0x00,
                     0x00, 0x05, 0x0E])
    let (frames, remainder) = NICodec.extractTCPFrames(from: data)
    check(frames.count == 2, "two complete frames, got \(frames.count)")
    check(frames[0].id == 0x0C && Array(frames[0].payload) == [0xAB], "frame1 content")
    check(frames[1].id == 0, "keepalive frame")
    check(Array(remainder) == [0x00, 0x05, 0x0E], "incomplete frame held back")
}

func tcpVersionTagParse() {
    var payload = ByteWriter()
    payload.u8(2); payload.u16be(0); payload.u8(0)
    payload.string8("CAN Talon FX"); payload.string8("26.1.0")
    payload.bytes([0, 0, 0, 0, 0, 0])
    let frame = NICodec.tcpFrame(id: 0x0A, payload: payload.data)
    let (frames, _) = NICodec.extractTCPFrames(from: frame)
    check(frames.count == 1, "one frame")
    guard case .versions(let entries)? = NICodec.decodeTCPEvent(id: 0x0A, payload: frames[0].payload) else {
        check(false, "expected versions event")
        return
    }
    check(entries.count == 1, "one entry")
    check(entries[0].deviceType == 2, "device type")
    check(entries[0].name == "CAN Talon FX", "name")
    check(entries[0].version == "26.1.0", "version")
}

func tcpErrorAndStdoutParse() {
    var errPayload = ByteWriter()
    errPayload.f32be(1.5); errPayload.u16be(9); errPayload.u16be(1)
    errPayload.u32be(0xFFFFFBEC) // -1044
    errPayload.u8(0x03) // flags
    errPayload.string16("details"); errPayload.string16("loc"); errPayload.string16("stack")
    guard case .error(let e)? = NICodec.decodeTCPEvent(id: 0x0B, payload: errPayload.data) else {
        check(false, "expected error event")
        return
    }
    check(e.seq == 9, "error seq")
    check(e.errorCode == -1044, "error code, got \(e.errorCode)")
    check(e.details == "details", "details")
    check(e.callStack == "stack", "call stack")

    var outPayload = ByteWriter()
    outPayload.f32be(2.0); outPayload.u16be(1)
    outPayload.bytes(Array("hello robot\n".utf8))
    guard case .stdout(let m)? = NICodec.decodeTCPEvent(id: 0x0C, payload: outPayload.data) else {
        check(false, "expected stdout event")
        return
    }
    check(m.message == "hello robot\n", "stdout message")

    var f4 = ByteWriter(); f4.u16be(3); f4.u16be(4)
    guard case .disableFaults(let comms, let twelve)? = NICodec.decodeTCPEvent(id: 0x04, payload: f4.data) else {
        check(false, "expected faults")
        return
    }
    check(comms == 3 && twelve == 4, "fault counts")
}

// MARK: 语义辅助

func allianceStationSemantics() {
    check(AllianceStation.red1.isRed == true && AllianceStation.red1.number == 1, "red1")
    check(AllianceStation.blue3.isRed == false && AllianceStation.blue3.number == 3, "blue3")
    check(AllianceStation(rawValue: 2) == .red3, "raw 2 = red3")
}

func axisEncodingSaturation() {
    check(JoystickData.encodeAxis(1.5) == 127, "saturate high")
    check(JoystickData.encodeAxis(-1.5) == -127, "saturate low")
    check(JoystickData.encodeAxis(0) == 0, "zero")
    check(JoystickData.encodeAxis(-0.5) == -64, "half negative")
}

// MARK: runner

setvbuf(stdout, nil, _IOLBF, 0) // 行缓冲：崩溃前也能看到进度
print("DSCore 协议回归测试")
runTest("controlPacketGoldenMin", controlPacketGoldenMin)
runTest("controlPacketGoldenJoystick", controlPacketGoldenJoystick)
runTest("controlPacketDateAndTimezoneTags", controlPacketDateAndTimezoneTags)
runTest("controlDecodeRoundTrip", controlDecodeRoundTrip)
runTest("responseGoldenHeader", responseGoldenHeader)
runTest("responseDecodeTags", responseDecodeTags)
runTest("responseRejectsWrongVersionAndShortData", responseRejectsWrongVersionAndShortData)
runTest("malformedTagBounds", malformedTagBounds)
runTest("tcpFrameSplitAcrossChunks", tcpFrameSplitAcrossChunks)
runTest("tcpVersionTagParse", tcpVersionTagParse)
runTest("tcpErrorAndStdoutParse", tcpErrorAndStdoutParse)
runTest("allianceStationSemantics", allianceStationSemantics)
runTest("axisEncodingSaturation", axisEncodingSaturation)
runTest("xinputAxisOrderDirewolfLayout", xinputAxisOrderDirewolfLayout)
runTest("xinputAxisOrderNonXboxPassthrough", xinputAxisOrderNonXboxPassthrough)
runTest("xinputAxisOrderRejectsNonSignatures", xinputAxisOrderRejectsNonSignatures)
runTest("xinputAxisOrderApplyBoundsSafety", xinputAxisOrderApplyBoundsSafety)
runTest("loopbackIntegration", loopbackIntegrationTest)
runAllPhase2Tests()
runAllPhase4Tests()
runAllOM5PReadinessTests()
// 手柄造型（GamepadProfile：识别/映射/容错；轴序样本锚定 2026-11-18 真机实测）
runTest("gamepadProfileDetection", gamepadProfileDetectionTests)
runTest("gamepadProfileDirewolfState", gamepadProfileDirewolfStateTests)
runTest("gamepadProfileF310State", gamepadProfileF310StateTests)
runTest("gamepadProfileF310XInputState", gamepadProfileF310XInputStateTests)
runTest("gamepadProfileDualsenseState", gamepadProfileDualsenseStateTests)
runTest("gamepadDirectionAndPolarity", gamepadDirectionAndPolarityTests)
runTest("gamepadProfileGenericState", gamepadProfileGenericStateTests)
runTest("gamepadProfileRobustness", gamepadProfileRobustnessTests)
// 双语（放最后：enTableTests 会临时切 shared 语言并在 defer 恢复 system）
runTest("languageResolve", languageResolveTests)
runTest("languageManager", languageManagerTests)
runTest("enTable", enTableTests)
runTest("localizationSourceCoverage", localizationSourceCoverageTests)
runTest("webuiLanguage", webuiLanguageTests)

print("\n\(checks) checks, \(failures.count) failures")
for f in failures { print("  ✗ \(f)") }
exit(failures.isEmpty ? 0 : 1)
