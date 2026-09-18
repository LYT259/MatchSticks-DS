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
        var list: [String] = []
        if let manual = config.manualIP, !manual.isEmpty {
            list.append(manual)
        } else {
            let team = max(config.teamNumber, 0)
            if team > 0 {
                list.append("roboRIO-\(team)-FRC.local")
                list.append(String(format: "10.%d.%d.2", team / 100, team % 100))
            }
            list.append("172.22.11.2") // USB
        }
        candidates = list
        resolvedMDNS = []
        currentTarget = nil
        candidateIndex = 0
        if tcpConnected { closeTCPLocked() }
    }

    // MARK: UDP

    private func openUDPLocked() {
        closeUDPLocked()
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { emit(.log("UDP socket create failed")); return }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        udpSock = fd
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
            // 已连接：严格只收当前目标；搜索中：接受任何能解出合法应答的来源（LAN 上即机器人）
            if case .connected(let host) = commState, srcIP != host { continue }
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
                        return j
                    }
                    return np
                }
            }
            guard let packet = decoded else {
                // 搜索期静默丢弃异协议应答（避免 NI/MRC 混布误建链）；已连接时的坏包才记日志
                if isConnectedLocked {
                    emit(.log("malformed response packet from \(srcIP), dropped"))
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
              let addr = sockaddrFor(target, port: NICodec.udpControlPort) else { return }

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
        guard !candidates.isEmpty else { return "" }
        let merged = candidates + resolvedMDNS.filter { !candidates.contains($0) }
        let target = merged[candidateIndex % merged.count]
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
        // 后台阻塞式连接（2s 超时）；in-flight 守卫 + 失败 1s 退避，
        // 防止未建立期间每 tick 排队新连接（连接风暴）
        guard tcpSock < 0, !tcpConnectInFlight, now >= tcpRetryAfter else { return }
        tcpConnectInFlight = true
        tcpConnectAttempts += 1
        let target = host
        resolverQueue.async { [weak self] in
            guard let self else { return }
            let fd = Self.blockingTCPConnect(to: target, port: NICodec.tcpPort, timeout: 2.0)
            self.queue.async {
                self.tcpConnectInFlight = false
                guard self.running, self.isConnectedLocked(to: target), self.currentTarget == target else {
                    if fd >= 0 { close(fd) }
                    self.tcpRetryAfter = self.monotonicNow() + 1.0
                    return
                }
                guard fd >= 0 else {
                    self.tcpRetryAfter = self.monotonicNow() + 1.0
                    return
                }
                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                self.tcpSock = fd
                self.tcpConnected = true
                self.tcpBuffer = Data()
                self.lastDescriptorHash = 0 // 触发描述符重发
                self.emit(.log("tcp channel open (\(target):\(NICodec.tcpPort))"))
            }
        }
    }

    static func blockingTCPConnect(to ip: String, port: UInt16, timeout: Double) -> Int32 {
        guard let addr = { () -> sockaddr_in? in
            var a = sockaddr_in()
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            guard inet_pton(AF_INET, ip, &a.sin_addr) == 1 else { return nil }
            return a
        }() else { return -1 }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout * 1_000_000).truncatingRemainder(dividingBy: 1_000_000)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let rc = withUnsafePointer(to: addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 { close(fd); return -1 }
        return fd
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
                let loss = txWindow == 0 ? 0.0 : Double(txWindow - rxWindow) / Double(txWindow) * 100
                emit(.stats(lossPercent: max(0, loss), rttMillis: nil, txCount: txCount, rxCount: rxCount))
            }
            txCountAtStats = txCount
            rxCountAtStats = rxCount
        }
    }
}
