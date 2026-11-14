import Foundation

#if canImport(Darwin)
import Darwin
#endif

// MARK: - DS 客户端：UDP 控制环 + TCP 慢速通道 + 连接管理 + 看门狗
//
// 安全设计（报告 §6 决策 2）：
// - 控制包固定 20ms 周期；UI/主线程心跳停滞 >200ms 时冻结使能（robot 因失包自动 disable）；
// - 通信中断 >1.25s 判定失联（发 .autoDisabled 事件，由上层落 enabled=false）；
// - E-Stop 位随每个控制包发送，本类不做任何使能侧「优化」；请求位（重启/重启代码）脉冲 6 周期。

public final class DSClient {
    public struct Snapshot: Sendable {
        public var control = ControlWord()
        public var alliance = AllianceStation.red1
        public var joysticks: [JoystickData] = []
        public var matchTime: Float?
        public var joystickDescriptors: [NICodec.JoystickDescriptor] = []
        public var gameData: String?
        public var matchInfo: MatchInfo?

        public init() {}
    }

    public struct MatchInfo: Sendable, Equatable {
        public var competition: String
        public var type: UInt8
        public init(competition: String, type: UInt8) {
            self.competition = competition
            self.type = type
        }
    }

    public enum CommState: Sendable, Equatable {
        case idle
        case searching
        case connected(host: String)
    }

    public enum Event: Sendable {
        case commState(CommState)
        case response(NICodec.ResponsePacket)
        case tcpEvent(NICodec.TCPEvent)
        case opModes([MRCOpModeInfo])
        case stats(lossPercent: Double, rttMillis: Double?, txCount: UInt64, rxCount: UInt64)
        case watchdogTripped(frozenSeconds: Double)
        case watchdogRecovered
        case autoDisabled(reason: String)
        case log(String)
    }

    public enum ProtocolKind: String, Sendable, CaseIterable {
        case ni      // roboRIO 1.0/2.0（comm version 0x01）
        case mrc     // SystemCore / MrcComm（comm version 0x02，CRC32C 应答）
    }

    public struct Configuration: Sendable {
        public var teamNumber = 0
        public var manualIP: String?
        public var protocolKind: ProtocolKind = .ni
        /// 控制周期，秒（协议 20ms）
        public var controlPeriod = 0.02
        /// 心跳停滞判定阈值（报告 §6：200ms）
        public var heartbeatLimit = 0.2
        /// 通信失联判定阈值
        public var silenceLimit = 1.25
        /// 控制通道端口：协议默认 1110（FMS 下 1115，档案「待实测」项）；
        /// 做成配置项是为了场景测试可与实机/模拟器隔离（见 DSCoreTests 端口污染事故 2026-09-16）
        public var controlPort: UInt16 = NICodec.udpControlPort
        /// 慢速通道端口（协议 1740）
        public var tcpPort: UInt16 = NICodec.tcpPort

        public init() {}
    }

    // 注入（须在 start() 前设置；start 后仅供 loop queue 读取）
    public var snapshotProvider: () -> Snapshot = { Snapshot() }
    public var eventHandler: (Event) -> Void = { _ in }
    /// 返回主线程心跳停滞秒数（UI 冻结检测）
    public var heartbeatAge: () -> Double = { 0 }
    /// 抓包录制 sink（报告 §6 决策 3「录制即测试」；loop queue 上调用，须自行保证线程安全）
    public var recordSink: ((RecordedDirection, Data) -> Void)?
    /// 每 20ms tick 回调（MRC 模式下发 NT4 ControlData 用；loop queue）
    public var tickHook: (() -> Void)?
    /// 首连日期 tag 的来源
    public var dateProvider: () -> Date = { Date() }
    public var timeZoneProvider: () -> String = { TimeZone.current.identifier }

    public private(set) var config = Configuration()

    // MARK: 内部状态（全部归 loop queue 所有）

    private let queue = DispatchQueue(label: "gh.driverstation.control-loop", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var running = false

    private var udpSock: Int32 = -1
    private var tcpSock: Int32 = -1
    private var tcpBuffer = Data()
    private var tcpConnected = false
    private var tcpConnectInFlight = false
    private var tcpRetryAfter: Double = 0
    /// TCP 连接尝试次数（测试用：stop() 后读取）
    public private(set) var tcpConnectAttempts = 0

    private var candidates: [String] = []
    private var candidateIndex = 0
    private var currentTarget: String?
    private var candidateSwitchAt: Double = 0

    private var commState: CommState = .idle
    private var lastResponseAt: Double = 0
    private var txSeq: UInt16 = 0
    private var txCount: UInt64 = 0
    private var rxCount: UInt64 = 0
    private var rxCountAtStats: UInt64 = 0
    private var txCountAtStats: UInt64 = 0
    private var lastStatsAt: Double = 0

    private var pendingRequest = RequestWord()
    private var requestPulseTicks = 0

    private var sentDateTag = false
    private var lastDescriptorHash = 0
    private var lastGameData: String?
    private var lastMatchInfo: MatchInfo?
    private var lastKeepAliveAt: Double = 0

    private var watchdogTripped = false
    private var watchdogTripStart: Double = 0
    private var statsWindowConnected = false

    /// 坏应答限流状态（loop queue 所有；按来源 IP 一份）
    private var malformedLogState: [String: (at: Double, suppressed: Int)] = [:]
    private static let malformedLogWindow = 10.0
    private static let malformedLogMaxSources = 32

    private let resolverQueue = DispatchQueue(label: "gh.driverstation.resolver", qos: .utility)
    private var resolvedMDNS: [String] = []
    private var lastResolveAt: Double = 0

    public init() {}

    // MARK: 对外控制（线程安全）

    public func updateConfig(_ mutate: (inout Configuration) -> Void) {
        queue.sync {
            mutate(&config)
            rebuildCandidatesLocked()
        }
    }

    /// 请求位脉冲（重启 roboRIO / 重启代码）：连续发送约 120ms。
    public func sendRequestPulse(_ request: RequestWord) {
        queue.async {
            self.pendingRequest = request
            self.requestPulseTicks = 6
        }
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.running else { return }
            self.running = true
            self.rebuildCandidatesLocked()
            self.openUDPLocked()
            // 启动即宣告搜索态：否则无应答时 UI 停在 idle，看不出正在找机器人（root cause ④）
            if !self.isConnectedLocked {
                self.commState = .searching
                self.emit(.commState(.searching))
            }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: self.config.controlPeriod, leeway: .microseconds(200))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
            self.emit(.log("control loop started, period \(Int(self.config.controlPeriod * 1000))ms"))
        }
    }

    public func stop() {
        queue.sync {
            guard running else { return }
            running = false
            timer?.cancel(); timer = nil
            closeTCPLocked()
            closeUDPLocked()
            commState = .idle
        }
    }

    // MARK: Loop queue 内部

    private func emit(_ event: Event) { eventHandler(event) }

    private var isConnectedLocked: Bool {
        if case .connected = commState { return true }
        return false
    }

    private func isConnectedLocked(to host: String) -> Bool {
        if case .connected(let h) = commState, h == host { return true }
        return false
    }

    private func monotonicNow() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private func rebuildCandidatesLocked() {
        candidates = Self.sendCandidates(manualIP: config.manualIP, teamNumber: config.teamNumber)
        resolvedMDNS = []
        currentTarget = nil
        candidateIndex = 0
        if tcpConnected { closeTCPLocked() }
    }

    /// 发送候选构造（纯函数，可测）：手动模式只发 manualIP；自动模式 = 队号 .2 + USB。
    /// mDNS 主机名（roboRIO-<team>-FRC.local）只作解析输入（scheduleMDNSResolveLocked），
    /// 不进发送轮换——sockaddrFor 只收数字 IP，.local 槽位等于整窗空发（root cause ③，
    /// 每 3 槽一窗 500ms 全废，发包速率天花板 ~33Hz）。
    public static func sendCandidates(manualIP: String?, teamNumber: Int) -> [String] {
        var list: [String] = []
        if let manual = manualIP, !manual.isEmpty {
            list.append(manual)
        } else {
            let team = max(teamNumber, 0)
            if team > 0 {
                list.append(String(format: "10.%d.%d.2", team / 100, team % 100))
            }
            list.append("172.22.11.2") // USB
        }
        return list
    }

    /// 发送轮换 = 静态候选 + mDNS 解析结果（可测纯函数；保持顺序、去重）。
    public static func sendRotation(staticCandidates: [String], resolvedMDNS: [String]) -> [String] {
        var seen = Set<String>()
        var rotation: [String] = []
        for candidate in staticCandidates + resolvedMDNS where seen.insert(candidate).inserted {
            rotation.append(candidate)
        }
        return rotation
    }

    // MARK: UDP

    private func openUDPLocked() {
        closeUDPLocked()
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { emit(.log("UDP socket create failed")); return }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        // 2026-11-14 roboRIO 2.0 真机验证：应答固定发往 DS UDP 1150。
        // 旧实现不 bind，内核分配临时端口，真机应答因此全部收不到。
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = NICodec.udpResponsePort.bigEndian
        local.sin_addr.s_addr = 0
        let bound = withUnsafePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            emit(.log("UDP bind 1150 failed: errno \(errno)"))
            close(fd)
            return
        }
        udpSock = fd
        flushStaleUDPPacketsLocked()
    }

    private func flushStaleUDPPacketsLocked() {
        guard udpSock >= 0 else { return }
        while true {
            var src = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = withUnsafeMutablePointer(to: &src) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(udpSock, &buffer, buffer.count, 0, sa, &len)
                }
            }
            if n <= 0 { break }
        }
    }

    public var localUDPPortForTest: UInt16? {
        queue.sync {
            guard udpSock >= 0 else { return nil }
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            guard getsockname(udpSock, withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in sa }
            }, &len) == 0 else { return nil }
            return UInt16(bigEndian: addr.sin_port)
        }
    }

    private func closeUDPLocked() {
        guard udpSock >= 0 else { return }
        close(udpSock)
        udpSock = -1
    }

    private func sockaddrFor(_ ip: String, port: UInt16) -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
        return addr
    }

    private func drainUDPLocked(now: Double) {
        guard udpSock >= 0 else { return }
        var count = 0
        while count < 12 {
            var src = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = withUnsafeMutablePointer(to: &src) { srcPtr in
                srcPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(udpSock, &buffer, buffer.count, 0, sa, &len)
                }
            }
            guard n > 0 else { break }
            count += 1

            let srcIP = Self.ipString(from: src)
            let connectedHost: String? = { if case .connected(let h) = commState { return h }; return nil }()
            guard Self.shouldAcceptResponse(srcIP: srcIP, connectedHost: connectedHost, manualIP: config.manualIP) else { continue }
            let decoded: NICodec.ResponsePacket?
            switch config.protocolKind {
            case .ni:
                decoded = NICodec.decodeResponse(Data(buffer[0 ..< n]))
            case .mrc:
                if let errorCode = MRCPackets.decodeErrorPacket(Data(buffer[0..<n])) {
                    emit(.log("MRC 错误包：code \(errorCode)（版本不匹配？）"))
                    continue
                }
                decoded = MRCPackets.decodeReply(Data(buffer[0..<n])).map { reply in
                    var np = NICodec.ResponsePacket()
                    np.seq = reply.seq
                    np.status.estop = reply.estop
                    np.status.enabled = reply.enabled
                    switch reply.mode {
                    case .autonomous: np.status.mode = .autonomous
                    case .test: np.status.mode = .test
                    case .teleoperated, .unknown: np.status.mode = .teleoperated
                    }
                    np.status.codeStarting = !(reply.hasCode || reply.hasUserCode)
                    np.trace.hasRobotCode = reply.hasCode || reply.hasUserCode
                    np.trace.isRoboRIO = true // SystemCore 等价指示
                    np.trace.teleopMode = reply.mode == .teleoperated
                    np.trace.autonomousMode = reply.mode == .autonomous
                    np.trace.testMode = reply.mode == .test
                    np.trace.disabled = !reply.enabled
                    np.batteryVoltage = reply.batteryVoltage
                    np.watchdogFed = reply.watchdogFed
                    np.joystickOutputs = reply.slotOutputs.map { slot in
                        var j = JoystickOutput()
                        j.leftRumble = slot.leftRumble
                        j.rightRumble = slot.rightRumble
                        j.ledRGB = UInt32(slot.ledR) << 16 | UInt32(slot.ledG) << 8 | UInt32(slot.ledB)
                        j.leftTriggerRumble = slot.leftTriggerRumble
                        j.rightTriggerRumble = slot.rightTriggerRumble
                        return j
                    }
                    return np
                }
            }
            guard let packet = decoded else {
                // 坏包留痕但按源限流（root cause ⑤）：真实「零应答」台架排查要能区分
                // 「链路静默」与「协议版本漂移」；证据含来源 IP、字节数与前缀 hex。
                // 坏包不建链、不进录制流（.dsrec 方向/schema 不变）。
                if malformedLogState.count > Self.malformedLogMaxSources { malformedLogState.removeAll() }
                var entry = malformedLogState[srcIP] ?? (at: -Self.malformedLogWindow, suppressed: 0)
                if now - entry.at >= Self.malformedLogWindow {
                    let prefix = Data(buffer[0 ..< min(n, 8)]).map { String(format: "%02x", $0) }.joined()
                    var line = "无法解码应答（来自 \(srcIP)，\(n) 字节，前缀 \(prefix)）——已丢弃，不建立连接"
                    if entry.suppressed > 0 { line += "（本窗口另抑制 \(entry.suppressed) 条同类包）" }
                    emit(.log(line))
                    malformedLogState[srcIP] = (at: now, suppressed: 0)
                } else {
                    entry.suppressed += 1
                    malformedLogState[srcIP] = entry
                }
                continue
            }

            rxCount += 1
            let previousHost: String? = { if case .connected(let h) = commState { return h }; return nil }()
            if previousHost != srcIP {
                commState = .connected(host: srcIP)
                currentTarget = srcIP
                emit(.commState(commState))
                if previousHost == nil { emit(.log("link established with \(srcIP)")) }
            }
            lastResponseAt = now

            recordSink?(.responseIn, Data(buffer[0 ..< n]))

            if packet.requestDate, !sentDateTag {
                sentDateTag = true // 下一个 tick 构造 date/timezone tag
            }
            emit(.response(packet))
        }
    }

    /// 已连接时只收当前主机；手动 IP 模式只收指定主机；自动发现才接受其他合法来源。
    public static func shouldAcceptResponse(srcIP: String, connectedHost: String?, manualIP: String?) -> Bool {
        if let connectedHost { return srcIP == connectedHost }
        if let manualIP { return srcIP == manualIP }
        return true
    }

    static func ipString(from addr: sockaddr_in) -> String {
        var a = addr.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    private func sendControlPacketLocked(now: Double) {
        guard udpSock >= 0, !candidates.isEmpty else { return }

        // 目标轮换：搜索态每 500ms 换下一个候选
        if !isConnectedLocked {
            if now >= candidateSwitchAt {
                candidateSwitchAt = now + 0.5
                scheduleMDNSResolveLocked(now: now)
                currentTarget = nextCandidateLocked()
            }
        }
        guard let target = currentTarget,
              let addr = sockaddrFor(target, port: config.controlPort) else { return }

        let snapshot = snapshotProvider()
        var control = snapshot.control

        // 看门狗：主线程冻结 → 冻结使能（estop 状态保持透传）
        let beatAge = heartbeatAge()
        if beatAge > config.heartbeatLimit {
            control.enabled = false
            if !watchdogTripped {
                watchdogTripped = true
                watchdogTripStart = now
                emit(.watchdogTripped(frozenSeconds: beatAge))
            }
        } else if watchdogTripped {
            watchdogTripped = false
            emit(.watchdogRecovered)
        }

        // 失联自动 disable（只发事件，状态由上层落盘，避免双写）
        if isConnectedLocked, now - lastResponseAt > config.silenceLimit {
            commState = .searching
            closeTCPLocked()
            emit(.commState(.searching))
            emit(.autoDisabled(reason: "communication lost (> \(Int(config.silenceLimit * 1000))ms silence)"))
            sentDateTag = false
        }

        var request = RequestWord()
        if requestPulseTicks > 0 {
            request = pendingRequest
            requestPulseTicks -= 1
        }

        var date: Date?
        var timeZone: String?
        if !sentDateTag, isConnectedLocked {
            // 首连后发送一次日期/时区（robot 置 requestDate=1 时会再触发一轮，此处幂等）
            date = dateProvider()
            timeZone = timeZoneProvider()
            sentDateTag = true
        }

        let packet: Data
        switch config.protocolKind {
        case .ni:
            packet = NICodec.controlPacket(
                seq: txSeq, control: control, request: request, alliance: snapshot.alliance,
                joysticks: snapshot.joysticks, matchTime: snapshot.matchTime,
                date: date, timeZone: timeZone
            )
        case .mrc:
            // NI 抽象控制字 → MRC 独立位（request 仅 RequestNormal；重启/重启代码走 NT4，Phase 3 后续）
            var mrcControl = MRCControlWord()
            mrcControl.test = control.mode == .test
            mrcControl.autonomous = control.mode == .autonomous
            mrcControl.enabled = control.enabled
            mrcControl.fmsAttached = control.fmsAttached
            mrcControl.estop = control.estop
            packet = MRCPackets.controlPacket(
                seq: txSeq, control: mrcControl, alliance: snapshot.alliance,
                joysticks: snapshot.joysticks, matchTime: snapshot.matchTime
            )
        }

        let sent = withUnsafePointer(to: addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                packet.withUnsafeBytes { raw in
                    sendto(udpSock, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent >= 0 {
            txSeq &+= 1; txCount += 1
            recordSink?(.controlOut, packet)
        }
    }

    private func nextCandidateLocked() -> String {
        let rotation = Self.sendRotation(staticCandidates: candidates, resolvedMDNS: resolvedMDNS)
        guard !rotation.isEmpty else { return "" }
        let target = rotation[candidateIndex % rotation.count]
        candidateIndex += 1
        return target
    }

    private func scheduleMDNSResolveLocked(now: Double) {
        guard now - lastResolveAt > 2.0 else { return }
        lastResolveAt = now
        let team = config.teamNumber
        guard team > 0, config.manualIP == nil else { return }
        resolverQueue.async { [weak self] in
            let name = "roboRIO-\(team)-FRC.local"
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_DGRAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(name, nil, &hints, &result) == 0, let first = result else { return }
            defer { freeaddrinfo(result) }
            var ips: [String] = []
            var info: UnsafeMutablePointer<addrinfo>? = first
            while let i = info {
                if i.pointee.ai_family == AF_INET {
                    let ip = i.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        Self.ipString(from: $0.pointee)
                    }
                    ips.append(ip)
                }
                info = i.pointee.ai_next
            }
            guard !ips.isEmpty else { return }
            self?.queue.async { self?.resolvedMDNS = ips }
        }
    }

    // MARK: TCP 1740

    private func ensureTCPLocked(now: Double) {
        guard isConnectedLocked, let host = currentTarget else { return }
        if tcpConnected { drainTCPLocked(); serviceTCPTagsLocked(now: now); return }
        // 后台有界连接（2s 截止，与 RadioProbe 同一 boundedTCPConnect）；in-flight 守卫 +
        // 失败 1s 退避，防止未建立期间每 tick 排队新连接（连接风暴）
        guard tcpSock < 0, !tcpConnectInFlight, now >= tcpRetryAfter else { return }
        tcpConnectInFlight = true
        tcpConnectAttempts += 1
        let target = host
        let port = config.tcpPort
        resolverQueue.async { [weak self] in
            guard let self else { return }
            let outcome = Self.boundedTCPConnect(to: target, port: port, timeout: 2.0)
            self.queue.async {
                self.tcpConnectInFlight = false
                guard self.running, self.isConnectedLocked(to: target), self.currentTarget == target else {
                    if case .connected(let fd) = outcome { close(fd) }
                    self.tcpRetryAfter = self.monotonicNow() + 1.0
                    return
                }
                guard case .connected(let fd) = outcome else {
                    self.tcpRetryAfter = self.monotonicNow() + 1.0
                    return
                }
                self.tcpSock = fd // boundedTCPConnect 返回的 fd 已是非阻塞
                self.tcpConnected = true
                self.tcpBuffer = Data()
                self.lastDescriptorHash = 0 // 触发描述符重发
                self.emit(.log("tcp channel open (\(target):\(port))"))
            }
        }
    }

    /// 有界 TCP 连接的结局分类：
    /// - connected：已建立（fd 已是非阻塞，归调用者所有，用毕须 close）
    /// - refused：ECONNREFUSED——主机在线但端口关（2026-10-31 实测 OM5P:80 形态）
    /// - timedOut：poll 截止时间到（黑洞链路/物理断线；阻塞式 connect 会挂到内核超时，
    ///   回环实测 ~7.8s、真机 en4 实测 ~75s）
    /// - unreachable：ENETUNREACH / EHOSTUNREACH
    /// - error：其余错误（含非数字 IP，errno=EINVAL）
    /// 非 connected 路径均已关闭 fd。
    public enum TCPConnectOutcome: Equatable, Sendable {
        case connected(fd: Int32)
        case refused
        case timedOut
        case unreachable
        case error(errno: Int32)
    }

    /// 非阻塞 connect + select 截止时间 + SO_ERROR 分类。
    /// 旧实现（blockingTCPConnect，已移除）设 SO_SNDTIMEO/RCVTIMEO 后直接阻塞 connect——
    /// 这两个选项不约束 connect 本身，黑洞链路会挂到内核 TCP 超时（~75s），且把
    /// ECONNREFUSED 与其他失败一并吞成 -1，OM5P 在线时的 RST 被误判离线
    /// （engineering-log/2026.10.31.md root cause ①）。
    public static func boundedTCPConnect(to ip: String, port: UInt16, timeout: Double) -> TCPConnectOutcome {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return .error(errno: EINVAL) }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .error(errno: errno) }
        let flags = fcntl(fd, F_GETFL, 0)
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let e = errno; close(fd); return .error(errno: e)
        }

        let rc = withUnsafePointer(to: addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return .connected(fd: fd) } // 回环可立即完成
        guard errno == EINPROGRESS else {
            let e = errno
            close(fd)
            switch e {
            case ECONNREFUSED: return .refused
            case ENETUNREACH, EHOSTUNREACH: return .unreachable
            default: return .error(errno: e)
            }
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let deadlineMs = max(1, Int(timeout * 1000))
        while true {
            let spentMs = Int(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            let remainingMs = deadlineMs - spentMs
            if remainingMs <= 0 { close(fd); return .timedOut }
            // macOS 的 OM5P 实网 RST 下 poll(POLLOUT 可能不醒；select 的写/异常集合能可靠返回。
            var writeSet = fd_set()
            var errorSet = fd_set()
            bzero(&writeSet, MemoryLayout<fd_set>.size)
            bzero(&errorSet, MemoryLayout<fd_set>.size)
            __darwin_fd_set(fd, &writeSet)
            __darwin_fd_set(fd, &errorSet)
            var wait = timeval(tv_sec: remainingMs / 1000, tv_usec: Int32((remainingMs % 1000) * 1000))
            let prc = select(fd + 1, nil, &writeSet, &errorSet, &wait)
            if prc > 0 { break }
            if prc < 0, errno == EINTR { continue }
            if prc < 0 { let e = errno; close(fd); return .error(errno: e) }
            close(fd)
            return .timedOut
        }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        switch soError {
        case 0:
            return .connected(fd: fd)
        case ECONNREFUSED:
            close(fd); return .refused
        case ETIMEDOUT:
            close(fd); return .timedOut
        case ENETUNREACH, EHOSTUNREACH:
            close(fd); return .unreachable
        default:
            close(fd); return .error(errno: soError)
        }
    }

    private func closeTCPLocked() {
        if tcpSock >= 0 { close(tcpSock) }
        tcpSock = -1
        tcpConnected = false
        tcpBuffer = Data()
    }

    private func drainTCPLocked() {
        guard tcpSock >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = recv(tcpSock, &buffer, buffer.count, 0)
            if n > 0 {
                tcpBuffer.append(Data(buffer[0 ..< n]))
                if n < buffer.count { break }
            } else if n == 0 {
                emit(.log("tcp channel closed by robot"))
                closeTCPLocked()
                return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                closeTCPLocked()
                return
            }
        }
        let (frames, remainder) = NICodec.extractTCPFrames(from: tcpBuffer)
        tcpBuffer = remainder
        for frame in frames where frame.id != 0 {
            recordSink?(.tcpIn, NICodec.tcpFrame(id: frame.id, payload: frame.payload))
            // MRC：0x13 = OpMode 列表（自定义大端二进制）
            if config.protocolKind == .mrc, frame.id == 0x13 {
                emit(.opModes(MRCPackets.decodeOpModes(frame.payload)))
                continue
            }
            if let event = NICodec.decodeTCPEvent(id: frame.id, payload: frame.payload) {
                emit(.tcpEvent(event))
            }
        }
    }

    private func serviceTCPTagsLocked(now: Double) {
        let snapshot = snapshotProvider()

        // keepalive
        if now - lastKeepAliveAt > 0.25 {
            _ = tcpSend(NICodec.tcpKeepAlive)
            lastKeepAliveAt = now
        }
        // 手柄描述符（变化时）
        let hash = snapshot.joystickDescriptors.map { "\($0)" }.joined().hashValue
        if hash != lastDescriptorHash {
            lastDescriptorHash = hash
            if !snapshot.joystickDescriptors.isEmpty || lastDescriptorHash != 0 {
                _ = tcpSend(NICodec.joystickDescriptorTag(snapshot.joystickDescriptors))
            }
        }
        // Game Data（变化时）
        if snapshot.gameData != lastGameData {
            lastGameData = snapshot.gameData
            if let gd = snapshot.gameData { _ = tcpSend(NICodec.gameDataTag(gd)) }
        }
        // 比赛信息（变化时）
        if snapshot.matchInfo != lastMatchInfo {
            lastMatchInfo = snapshot.matchInfo
            if let mi = snapshot.matchInfo {
                _ = tcpSend(NICodec.matchInfoTag(competition: mi.competition, matchType: mi.type))
            }
        }
    }

    private func tcpSend(_ data: Data) -> Bool {
        guard tcpSock >= 0, tcpConnected else { return false }
        recordSink?(.tcpOut, data)
        let ok = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return send(tcpSock, base, raw.count, 0) == raw.count
        }
        if !ok {
            emit(.log("tcp send failed, channel closed"))
            closeTCPLocked()
        }
        return ok
    }

    // MARK: 主循环

    private func tick() {
        guard running else { return }
        let now = monotonicNow()
        drainUDPLocked(now: now)
        sendControlPacketLocked(now: now)
        ensureTCPLocked(now: now)
        tickHook?()

        // 每秒发一次统计；窗口起点未连接（含连接瞬间的半窗）不计，
        // 否则连接初期会出现 100% 丢包伪影
        if now - lastStatsAt > 1.0 {
            let wasConnected = statsWindowConnected
            statsWindowConnected = isConnectedLocked
            lastStatsAt = now
            if wasConnected {
                let txWindow = txCount - txCountAtStats
                let rxWindow = rxCount - rxCountAtStats
                // 必须先在带符号/浮点域里相减：窗口内 rx > tx 是**真实可达**的
                // （sendto 因漫游或缓冲满失败则本包不计数，而更早发出的应答仍在途；
                //  机器人/中继对同一请求重复应答同样会超发）。UInt64 直接相减会
                // 下溢并触发 `Swift runtime failure: arithmetic overflow`——
                // 崩溃点在控制环线程上 = 立刻停发控制包 = 机器人看门狗自动失能。
                // 2026-09-19 崩溃报告（DSClient.tick）实锤，回归测试见 statsUnderflowScenario。
                let loss = txWindow == 0
                    ? 0.0
                    : (Double(txWindow) - Double(rxWindow)) / Double(txWindow) * 100
                emit(.stats(lossPercent: min(100, max(0, loss)), rttMillis: nil,
                            txCount: txCount, rxCount: rxCount))
            }
            txCountAtStats = txCount
            rxCountAtStats = rxCount
        }
    }
}
