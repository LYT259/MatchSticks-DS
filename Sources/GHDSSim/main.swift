import Foundation
import Darwin
import DSCore

// MARK: - GHDSSim：roboRIO 1.0/2.0 模拟器
//
// 用途：无实体机器人时对 DS 做端到端验证（协议回归 + UI 链路）。
// 行为：UDP 1110 收控制包 → 以 1150 端口应答（与真实 roboRIO 相同的「回送源端口」语义）；
//       TCP 1740 提供版本信息 / 周期 stdout / 错误消息 / 故障计数。
// 安全说明：这是模拟器，只在本机/局域网内回应答包，不存在任何执行机构。

let version = "0.1.0"

struct Args {
    var udpPort: UInt16 = 1110
    var tcpPort: UInt16 = 1740
    var brownoutAfter: Double = 0     // 0 = 关闭
    var stdoutInterval: Double = 1.0  // 0 = 关闭
    var quiet = false
}

let args: Args = {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let flag = it.next() {
        let value = { () -> String? in let v = it.next(); return v }
        switch flag {
        case "--udp-port": if let v = value(), let p = UInt16(v) { a.udpPort = p }
        case "--tcp-port": if let v = value(), let p = UInt16(v) { a.tcpPort = p }
        case "--brownout-after": if let v = value(), let d = Double(v) { a.brownoutAfter = d }
        case "--stdout-interval": if let v = value(), let d = Double(v) { a.stdoutInterval = d }
        case "--quiet": a.quiet = true
        default: break
        }
    }
    return a
}()

func simLog(_ s: String) {
    guard !args.quiet else { return }
    print(s)
    fflush(stdout)
}

// MARK: 模拟机器人状态

final class SimRobot: @unchecked Sendable {
    private let lock = NSLock()

    // DS 侧输入
    private var dsControl = ControlWord()
    private var dsAlliance = AllianceStation.red1
    private var joystickCount = 0
    private var lastRequestAt: Double = 0

    // 内部状态
    private var estopLatched = false
    private var rebootStart: Double = 0       // >0 = 重启中
    private var codeRestartStart: Double = 0  // >0 = 代码重启中
    private var seq: UInt16 = 0
    private var startTime = Date()
    private var canRxTotal: UInt32 = 0
    private var canTxTotal: UInt32 = 0
    private var brownoutPhaseStart: Double = 0
    private var cpuLoads: [Float] = [0.12, 0.08]
    private var lastSeqReceived: UInt16 = 0
    private var packetsReceived: UInt64 = 0

    var isRebooting: Bool { lock.lock(); defer { lock.unlock() }; return rebootStart > 0 }
    var packetCount: UInt64 { lock.lock(); defer { lock.unlock() }; return packetsReceived }

    func now() -> Double { Date().timeIntervalSince(startTime) }

    /// 收到控制包：更新状态；返回是否应答（重启窗口内静默）
    func handleControl(_ p: NICodec.ControlPacket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        packetsReceived += 1
        lastSeqReceived = p.seq
        dsControl = p.control
        dsAlliance = p.alliance
        joystickCount = p.joysticks.count

        let t = now()
        if p.request.rebootRoboRIO {
            if rebootStart == 0 {
                rebootStart = t
                simLog("⚡  roboRIO reboot requested (outage 3s, then code restart)")
            }
        }
        if p.request.restartCode {
            if codeRestartStart == 0 {
                codeRestartStart = t
                estopLatched = false   // FDS 语义：重启代码即解除 E-Stop 锁存
                simLog("⟳  robot code restart requested (estop cleared, code starting)")
            }
        }
        if p.control.estop, !estopLatched {
            estopLatched = true
            simLog("🛑 E-STOP latched (cleared by code restart, per First DS semantics)")
        }
        return rebootStart == 0
    }

    /// 构造应答包
    func response(for toAddr: sockaddr_in) -> Data {
        lock.lock(); defer { lock.unlock() }
        let t = now()

        // 重启时序：3s 断联静默 → 代码重启 2s → 恢复
        if rebootStart > 0 {
            if t - rebootStart < 3.0 { return Data() }
            if t - rebootStart < 5.0 {
                codeRestartStart = t - 0.5
                rebootStart = 0
                simLog("🔋 roboRIO back online, code starting")
            } else {
                rebootStart = 0
                codeRestartStart = t
            }
        }
        var codeStarting = false
        if codeRestartStart > 0 {
            if t - codeRestartStart < 1.5 {
                codeStarting = true
            } else {
                codeRestartStart = 0
                simLog("✅ robot code running")
            }
        }
        let codeRunning = !codeStarting
        let enabled = dsControl.enabled && !estopLatched && codeRunning

        // 电池：基线 12.42V，使能压降，brownout 演示窗口
        var battery = 12.42 + 0.04 * sin(t * 0.7)
        if enabled { battery -= 0.5 + 0.05 * sin(t * 2.3) }
        var brownout = false
        if args.brownoutAfter > 0 {
            if brownoutPhaseStart == 0 && t >= args.brownoutAfter { brownoutPhaseStart = t }
            if brownoutPhaseStart > 0, t - brownoutPhaseStart < 5.0 {
                brownout = true
                battery = 6.9
            }
        }
        let bInt = UInt8(clamping: Int(battery))
        let bFrac = UInt8(clamping: Int((battery - Double(bInt)) * 256))
        let batteryRaw = UInt16(bInt) << 8 | UInt16(bFrac)

        var status = RobotStatus()
        status.estop = estopLatched
        status.brownout = brownout
        status.codeStarting = codeStarting
        status.enabled = enabled
        status.mode = dsControl.mode

        var trace = RobotTrace()
        trace.hasRobotCode = codeRunning
        trace.isRoboRIO = true
        trace.testMode = dsControl.mode == .test
        trace.autonomousMode = dsControl.mode == .autonomous
        trace.teleopMode = dsControl.mode == .teleoperated
        trace.disabled = !enabled

        seq &+= 1
        var w = ByteWriter()
        w.u16be(seq)
        w.u8(NICodec.commVersion)
        w.u8(status.raw)
        w.u8(trace.raw)
        w.u16be(batteryRaw)
        w.u8(0x00) // requestDate：首包由 UDP 层改写

        // CPU tag：首 4 字节 float = 核数，随后每核 4 档 float（time-critical/above/normal/low）
        for i in 0 ..< cpuLoads.count {
            let target: Float = (enabled ? 0.55 : 0.12) + Float(sin(t * Double(1.3 + Float(i)))) * 0.1
            cpuLoads[i] = cpuLoads[i] * 0.95 + target * 0.05
        }
        var cpuTag = ByteWriter()
        cpuTag.f32be(Float(cpuLoads.count))
        for load in cpuLoads {
            let clamped = max(0, min(1, load))
            cpuTag.f32be(clamped * 0.6)
            cpuTag.f32be(clamped * 0.3)
            cpuTag.f32be(0.05)
            cpuTag.f32be(0.05)
        }
        NICodec.appendTag(0x05, cpuTag.data, to: &w)

        // RAM / Disk
        var ramTag = ByteWriter()
        ramTag.u32be(190_000_000 + UInt32(abs(Int(sin(t) * 8_000_000))))
        ramTag.u32be(2_048 * 1_000_000)
        NICodec.appendTag(0x06, ramTag.data, to: &w)

        var diskTag = ByteWriter()
        diskTag.u32be(1_240_000_000)
        NICodec.appendTag(0x04, diskTag.data, to: &w)

        // CAN 指标
        if enabled { canRxTotal &+= UInt32.random(in: 5 ... 40); canTxTotal &+= UInt32.random(in: 5 ... 40) }
        var canTag = ByteWriter()
        canTag.f32be(enabled ? Float.random(in: 0.18 ... 0.45) : Float.random(in: 0.0 ... 0.04))
        canTag.u32be(0); canTag.u32be(0)
        canTag.u8(0); canTag.u8(0)
        NICodec.appendTag(0x0E, canTag.data, to: &w)

        // Joystick Output（全零：真实 robot 由代码请求 rumble 时才非零）
        var joyOut = ByteWriter()
        joyOut.u32be(0); joyOut.u16be(0); joyOut.u16be(0)
        NICodec.appendTag(0x01, joyOut.data, to: &w)

        var data = w.data
        // 首包 requestDate=1：由 UDP 层判断新 DS 地址后覆写字节 7
        if isNewPeer(toAddr) { data[7] = 0x01 }
        return data
    }

    private var knownPeer: UInt32 = 0
    private func isNewPeer(_ addr: sockaddr_in) -> Bool {
        let raw = addr.sin_addr.s_addr
        if raw != knownPeer { knownPeer = raw; return true }
        return false
    }

    var summary: String {
        lock.lock(); defer { lock.unlock() }
        let state = estopLatched ? "ESTOP" : (dsControl.enabled ? "ENABLED" : "disabled")
        return "mode=\(dsControl.mode.rawValue) \(state) joy=\(joystickCount) seq(rx)=\(lastSeqReceived)"
    }
}

// MARK: UDP

let robot = SimRobot()

func runUDP(_ a: Args) {
    let rxSock = socket(AF_INET, SOCK_DGRAM, 0)
    let txSock = socket(AF_INET, SOCK_DGRAM, 0)
    guard rxSock >= 0, txSock >= 0 else { simLog("udp socket create failed"); exit(1) }

    var yes: Int32 = 1
    setsockopt(rxSock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var rxAddr = sockaddr_in()
    rxAddr.sin_family = sa_family_t(AF_INET)
    rxAddr.sin_port = a.udpPort.bigEndian
    rxAddr.sin_addr = in_addr(s_addr: INADDR_ANY)

    var txAddr = sockaddr_in()
    txAddr.sin_family = sa_family_t(AF_INET)
    txAddr.sin_port = NICodec.udpResponsePort.bigEndian
    txAddr.sin_addr = in_addr(s_addr: INADDR_ANY)

    let rxBind = withUnsafePointer(to: &rxAddr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(rxSock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    let txBind = withUnsafePointer(to: &txAddr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(txSock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard rxBind == 0, txBind == 0 else { simLog("udp bind failed (port \(a.udpPort)/1150 in use?)"); exit(1) }

    DispatchQueue.global(qos: .userInitiated).async {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var src = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &src) { srcPtr in
                srcPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(rxSock, &buffer, buffer.count, 0, sa, &len)
                }
            }
            guard n > 0 else { continue }
            guard let packet = NICodec.decodeControl(Data(buffer[0 ..< n])) else {
                simLog("⚠️  malformed control packet (\(n)B), dropped")
                continue
            }
            let shouldReply = robot.handleControl(packet)
            guard shouldReply else { continue }
            let reply = robot.response(for: src)
            guard !reply.isEmpty else { continue }

            // 以 1150 端口回送到 DS 源地址:源端口（真实 roboRIO 语义）
            var dst = src
            let sent = withUnsafePointer(to: &dst) { dstPtr in
                dstPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    reply.withUnsafeBytes { raw in
                        sendto(txSock, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent < 0, !a.quiet { simLog("udp reply sendto failed: errno \(errno)") }
        }
    }
}

// MARK: TCP 1740

func runTCP(_ a: Args) {
    let listenSock = socket(AF_INET, SOCK_STREAM, 0)
    guard listenSock >= 0 else { simLog("tcp socket create failed"); exit(1) }
    var yes: Int32 = 1
    setsockopt(listenSock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = a.tcpPort.bigEndian
    addr.sin_addr = in_addr(s_addr: INADDR_ANY)
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenSock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(listenSock, 4) == 0 else { simLog("tcp bind/listen failed (port \(a.tcpPort) in use?)"); exit(1) }

    DispatchQueue.global(qos: .userInitiated).async {
        while true {
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            var clientAddr = sockaddr_in()
            let fd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenSock, $0, &len) }
            }
            guard fd >= 0 else { continue }
            handleTCPClient(fd)
        }
    }
}

func handleTCPClient(_ fd: Int32) {
    DispatchQueue.global(qos: .utility).async {
        simLog("🔌 tcp client connected")
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        func sendFrame(_ data: Data) {
            data.withUnsafeBytes { raw in
                _ = send(fd, raw.baseAddress, raw.count, 0)
            }
        }

        // 版本信息（0x0A）+ 终止符
        var verPayload = ByteWriter()
        for (type, name, ver) in [(UInt8(0), "RoboRIO", "sim-\(version)"),
                                  (UInt8(0), "FRC Python", "2026.1.0"),
                                  (UInt8(2), "CAN Talon FX", "26.1.0a1"),
                                  (UInt8(8), "PDP", "1.40")] {
            verPayload.u8(type); verPayload.u16be(0); verPayload.u8(0)
            verPayload.string8(name); verPayload.string8(ver)
        }
        verPayload.bytes([0, 0, 0, 0, 0, 0])
        sendFrame(NICodec.tcpFrame(id: 0x0A, payload: verPayload.data))

        let start = Date()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var lastStdout = 0.0
        var lastError = 0.0
        var lastFault = 0.0
        var stdoutCounter = 0

        while true {
            if robot.isRebooting { break }
            let t = Date().timeIntervalSince(start)

            // 读 DS 方向（keepalive / 描述符 / gamedata）
            let n = recv(fd, &buffer, buffer.count, 0)
            if n == 0 { break }
            if n > 0 {
                let (frames, _) = NICodec.extractTCPFrames(from: Data(buffer[0 ..< n]))
                for frame in frames {
                    switch frame.id {
                    case 0x02:
                        var r = ByteReader(frame.payload)
                        var names: [String] = []
                        while !r.isExhausted {
                            guard let idx = r.u8(), let _ = r.u8(), let _ = r.i8(),
                                  let name = r.string8(), let axisCount = r.u8(),
                                  let _ = r.bytes(Int(axisCount)),
                                  let buttonCount = r.u8(), let povCount = r.u8() else { break }
                            names.append("[\(idx)] \(name) axes=\(axisCount) btn=\(buttonCount) pov=\(povCount)")
                        }
                        simLog("🎚  descriptors: \(names.joined(separator: " | "))")
                    case 0x0E:
                        var r = ByteReader(frame.payload)
                        if let gd = r.string8() { simLog("🎮 game data received: \"\(gd)\"") }
                    case 0x07:
                        simLog("🏁 match info received")
                    default: break
                    }
                }
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                break
            }

            if args.stdoutInterval > 0, t - lastStdout >= args.stdoutInterval {
                lastStdout = t
                stdoutCounter += 1
                var m = ByteWriter()
                m.f32be(Float(t)); m.u16be(UInt16(stdoutCounter & 0xFFFF))
                m.bytes(Array("[SimRobot] periodic \(stdoutCounter) \(robot.summary)".utf8))
                sendFrame(NICodec.tcpFrame(id: 0x0C, payload: m.data))
            }
            if t - lastError >= 10.0 {
                lastError = t
                var m = ByteWriter()
                m.f32be(Float(t)); m.u16be(7); m.u16be(0x0001)
                m.u32be(UInt32(bitPattern: Int32(-1044)))   // 示例错误码
                m.u8(0x03)
                m.string16("CAN device 'CAN Talon FX' (ID: 2) is unreachable on bus")
                m.string16("SimRobotPeriodic")
                m.string16("main")
                sendFrame(NICodec.tcpFrame(id: 0x0B, payload: m.data))
            }
            if t - lastFault >= 5.0 {
                lastFault = t
                var f4 = ByteWriter(); f4.u16be(0); f4.u16be(0)
                sendFrame(NICodec.tcpFrame(id: 0x04, payload: f4.data))
                var f5 = ByteWriter(); f5.u16be(0); f5.u16be(0); f5.u16be(0)
                sendFrame(NICodec.tcpFrame(id: 0x05, payload: f5.data))
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        close(fd)
        simLog("🔌 tcp client disconnected")
    }
}

// MARK: main

print("""
┌─────────────────────────────────────────────────────┐
│  GHDSSim v\(version) — roboRIO 模拟器（GH Driver Station）  │
└─────────────────────────────────────────────────────┘
  UDP 控制通道 : 0.0.0.0:\(args.udpPort) → 应答源端口 1150
  TCP 慢速通道 : 0.0.0.0:\(args.tcpPort)
  等待 Driver Station 连接…（DS 侧 team 模式或手动 IP 127.0.0.1）
""")
fflush(stdout)

runUDP(args)
runTCP(args)

Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
    if robot.packetCount > 0 {
        simLog("… \(robot.summary)")
    }
}
RunLoop.main.run()
