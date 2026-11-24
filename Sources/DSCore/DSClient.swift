import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
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
    /// UDP 直连绑定注入（测试用；start 前设置）
    public var udpBindProviderForTest: (Int32, String) -> DirectInterface.BindResult = DirectInterface.bind
    /// 首连日期 tag 的来源
    public var dateProvider: () -> Date = { Date() }
    public var timeZoneProvider: () -> String = { TimeZone.current.identifier }

    public private(set) var config = Configuration()

    // MARK: 内部状态（全部归 loop queue 所有）

    private let queue = DispatchQueue(label: "matchsticks.ds.control-loop", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var running = false

    private var udpSock: Int32 = -1
    /// UDP 直连绑定缓存（目标/结果/时刻），只在目标切换或约 2s 刷新时重绑
    private var udpBindTarget: String?
    private var udpBindResult: DirectInterface.BindResult?
    private var udpBindAt: Double = 0
    private var udpBindLogState: [String: (at: Double, line: String)] = [:]
    private static let udpBindRefreshInterval = 2.0
    private static let udpBindFailureRetryInterval = 0.1
    private static let udpBindLogWindow = 10.0
    private static let udpBindLogMaxTargets = 16
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
    /// 自动失能后等待上层实际落 enabled=false 的安全闩锁
    private var awaitingUpperDisabled = false
    /// 当前连续绑定失败 episode 是否已上报 autoDisabled
    private var bindFailureNotified = false

    /// 坏应答限流状态（loop queue 所有；按来源 IP 一份）
    private var malformedLogState: [String: (at: Double, suppressed: Int)] = [:]
    private static let malformedLogWindow = 10.0
    private static let malformedLogMaxSources = 32

    private let resolverQueue = DispatchQueue(label: "matchsticks.ds.resolver", qos: .utility)
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

    /// 手动刷新决策（纯函数，可测）：仅在控制环已启动且未连接时执行真重搜。
    /// 已连接时 rebuild 候选会强制 autoDisabled——刷新绝不能变成误失能。
    public static func shouldRefreshConnection(running: Bool, connected: Bool) -> Bool {
        running && !connected
    }

    /// 手动机器人刷新（Mini Driver Station 刷新按钮的真实动作）：
    /// 清 mDNS 解析缓存与 2s 节流、重建发送候选并宣告搜索态——等价一次全新搜索，
    /// 不只是视觉反馈。已连接/未启动时为空操作（见 shouldRefreshConnection）。
    public func refreshConnection() {
        queue.async {
            guard Self.shouldRefreshConnection(running: self.running, connected: self.isConnectedLocked) else { return }
            self.lastResolveAt = 0
            self.rebuildCandidatesLocked()
            guard self.commState != .searching else { return }
            self.commState = .searching
            self.emit(.commState(.searching))
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
        if isConnectedLocked {
            commState = .searching
            emit(.commState(.searching))
            emit(.autoDisabled(reason: "connection target changed"))
        }
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

    private func resetUDPBindCacheLocked() {
        udpBindTarget = nil
        udpBindResult = nil
        udpBindAt = 0
        udpBindLogState.removeAll()
        bindFailureNotified = false
    }

    private func refreshUDPBindLocked(target: String, now: Double) -> (result: DirectInterface.BindResult, attempted: Bool) {
        if target == udpBindTarget, let cached = udpBindResult {
            let interval: Double
            if case .failed = cached {
                interval = Self.udpBindFailureRetryInterval
            } else {
                interval = Self.udpBindRefreshInterval
            }
            if now - udpBindAt < interval { return (cached, false) }
        }
        let result = udpBindProviderForTest(udpSock, target)
        udpBindTarget = target
        udpBindResult = result
        udpBindAt = now
        logUDPBindLocked(target: target, result: result, now: now)
        return (result, true)
    }

    private func logUDPBindLocked(target: String, result: DirectInterface.BindResult, now: Double) {
        let line: String
        switch result {
        case .bound(let name, let index):
            line = tr("UDP 机器人直连：%@ → 网卡 %@（索引 %d）", target, name, Int(index))
        case .noMatch:
            line = tr("UDP 未匹配机器人网卡：%@，暂按系统路由发送", target)
        case .failed(let code):
            line = tr("UDP 机器人网卡绑定失败：%@（errno %d）", target, Int(code))
        }
        if let last = udpBindLogState[target], last.line == line {
            switch result {
            case .bound, .noMatch:
                return
            case .failed:
                if now - last.at < Self.udpBindLogWindow { return }
            }
        }
        if udpBindLogState.count >= Self.udpBindLogMaxTargets { udpBindLogState.removeAll() }
        udpBindLogState[target] = (at: now, line: line)
        emit(.log(line))
    }

    private func openUDPLocked() {
        closeUDPLocked()
        let fd = SocketCompat.udpSocket()
        guard fd >= 0 else { emit(.log("UDP socket create failed")); return }
        _ = SocketCompat.setNonBlocking(fd)
        _ = SocketCompat.setReuseAddress(fd)
        // 2026-11-14 roboRIO 2.0 真机验证：应答固定发往 DS UDP 1150。
        // 旧实现不 bind，内核分配临时端口，真机应答因此全部收不到。
        var local = SocketCompat.anyAddress(port: NICodec.udpResponsePort)
        guard SocketCompat.bindSocket(fd, &local) == 0 else {
            emit(.log("UDP bind 1150 failed: errno \(SocketCompat.lastError)"))
            SocketCompat.closeSocket(fd)
            return
        }
        udpSock = fd
        flushStaleUDPPacketsLocked()
    }

    private func flushStaleUDPPacketsLocked() {
        guard udpSock >= 0 else { return }
        while true {
            var src = SocketCompat.emptyAddress()
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = SocketCompat.receiveFrom(udpSock, &buffer, buffer.count, &src)
            if n <= 0 { break }
        }
    }

    public var localUDPPortForTest: UInt16? {
        queue.sync {
            guard udpSock >= 0, let addr = SocketCompat.localAddress(udpSock) else { return nil }
            return SocketCompat.port(of: addr)
        }
    }

    public var localUDPBoundInterfaceIndexForTest: UInt32? {
        queue.sync { DirectInterface.boundInterfaceIndex(fd: udpSock) }
    }

    private func closeUDPLocked() {
        resetUDPBindCacheLocked()
        guard udpSock >= 0 else { return }
        SocketCompat.closeSocket(udpSock)
        udpSock = -1
    }

    private func sockaddrFor(_ ip: String, port: UInt16) -> sockaddr_in? {
        SocketCompat.address(ip, port: port)
    }

    private func drainUDPLocked(now: Double) {
        guard udpSock >= 0 else { return }
        var count = 0
        while count < 12 {
            var src = SocketCompat.emptyAddress()
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = SocketCompat.receiveFrom(udpSock, &buffer, buffer.count, &src)
            guard n > 0 else { break }
            count += 1

            let srcIP = SocketCompat.ipString(of: &src)
            let connectedHost: String? = { if case .connected(let h) = commState { return h }; return nil }()
            let allowedHosts = Self.sendRotation(staticCandidates: candidates, resolvedMDNS: resolvedMDNS)
            guard Self.shouldAcceptResponse(srcIP: srcIP, connectedHost: connectedHost,
                                            manualIP: config.manualIP, allowedHosts: allowedHosts) else { continue }
            let decoded: NICodec.ResponsePacket?
            switch config.protocolKind {
            case .ni:
                decoded = NICodec.decodeResponse(Data(buffer[0 ..< n]))
            case .mrc:
                if let errorCode = MRCPackets.decodeErrorPacket(Data(buffer[0..<n])) {
                    emit(.log(tr("MRC 错误包：code %d（版本不匹配？）", Int(errorCode))))
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
                    var line = tr("无法解码应答（来自 %@，%d 字节，前缀 %@）——已丢弃，不建立连接", srcIP, Int(n), prefix)
                    if entry.suppressed > 0 { line += tr("（本窗口另抑制 %d 条同类包）", entry.suppressed) }
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
    public static func shouldAcceptResponse(srcIP: String, connectedHost: String?, manualIP: String?,
                                             allowedHosts: [String]? = nil) -> Bool {
        if let connectedHost { return srcIP == connectedHost }
        if let manualIP { return srcIP == manualIP }
        if let allowedHosts { return allowedHosts.contains(srcIP) }
        return true
    }

    private func sendControlPacketLocked(now: Double) -> Bool {
        guard udpSock >= 0, !candidates.isEmpty else { return !awaitingUpperDisabled }

        // 目标轮换：搜索态每 500ms 换下一个候选
        if !isConnectedLocked {
            if now >= candidateSwitchAt {
                candidateSwitchAt = now + 0.5
                scheduleMDNSResolveLocked(now: now)
                currentTarget = nextCandidateLocked()
            }
        }
        guard let target = currentTarget,
              var addr = sockaddrFor(target, port: config.controlPort) else {
            return !awaitingUpperDisabled
        }

        let bind = refreshUDPBindLocked(target: target, now: now)
        let bindFailure: Int32?
        if case .failed(let code) = bind.result {
            bindFailure = code
        } else {
            bindFailure = nil
            bindFailureNotified = false
        }

        let snapshot = snapshotProvider()
        var control = snapshot.control

        if awaitingUpperDisabled, !snapshot.control.enabled {
            awaitingUpperDisabled = false
        }

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
            awaitingUpperDisabled = true
        }

        if let code = bindFailure {
            if bind.attempted, isConnectedLocked {
                commState = .searching
                closeTCPLocked()
                emit(.commState(.searching))
                if !bindFailureNotified {
                    emit(.autoDisabled(reason: "direct interface bind failed for \(target) (errno \(code))"))
                    bindFailureNotified = true
                }
                sentDateTag = false
            }
            if bind.attempted {
                awaitingUpperDisabled = true
                control.enabled = false
                return false
            }
            control.enabled = false
        } else if awaitingUpperDisabled {
            control.enabled = false
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

        let sent = SocketCompat.sendDatagram(udpSock, packet, &addr)
        if sent >= 0 {
            txSeq &+= 1; txCount += 1
            recordSink?(.controlOut, packet)
        }
        return !awaitingUpperDisabled && bindFailure == nil
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
            // 名字解析是 Winsock API：可能先于任何套接字创建走到这里，Winsock 初始化由 resolveIPv4Hosts 负责
            let ips = SocketCompat.resolveIPv4Hosts(name)
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
                    // 丢弃连接结果：套接字必须经 SocketCompat 关闭（Windows 上 C close() 不能关套接字）
                    if case .connected(let fd) = outcome { SocketCompat.closeSocket(fd) }
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
    /// - connected：已建立（fd 已是非阻塞，归调用者所有，用毕须关闭）
    /// - refused：ECONNREFUSED——主机在线但端口关（2026-10-31 实测 OM5P:80 形态）
    /// - timedOut：等待截止时间到（黑洞链路/物理断线；阻塞式 connect 会挂到内核超时，
    ///   回环实测 ~7.8s、真机 en4 实测 ~75s）
    /// - unreachable：ENETUNREACH / EHOSTUNREACH
    /// - error：其余错误（含非数字 IP 的 EINVAL、直连绑定失败）
    /// 非 connected 路径均已关闭 fd。
    public enum TCPConnectOutcome: Equatable, Sendable {
        case connected(fd: Int32)
        case refused
        case timedOut
        case unreachable
        case error(errno: Int32)
    }

    /// 非阻塞 connect + 有界等待（SocketCompat：Darwin select / Linux poll / Windows select）
    /// + SO_ERROR 分类。旧实现（blockingTCPConnect，已移除）设 SO_SNDTIMEO/RCVTIMEO 后直接阻塞
    /// connect——这两个选项不约束 connect 本身，黑洞链路会挂到内核 TCP 超时（~75s），且把
    /// ECONNREFUSED 与其他失败一并吞成 -1，OM5P 在线时的 RST 被误判离线
    /// （engineering-log/2026.10.31.md root cause ①）。
    public static func boundedTCPConnect(to ip: String, port: UInt16, timeout: Double) -> TCPConnectOutcome {
        guard var addr = SocketCompat.address(ip, port: port) else {
            return .error(errno: SocketCompat.einval)
        }

        let fd = SocketCompat.tcpSocket()
        guard fd >= 0 else { return .error(errno: SocketCompat.lastError) }
        guard SocketCompat.setNonBlocking(fd) else {
            let e = SocketCompat.lastError
            SocketCompat.closeSocket(fd)
            return .error(errno: e)
        }
        switch DirectInterface.bind(fd: fd, target: ip) {
        case .bound, .noMatch:
            break
        case .failed(let code):
            SocketCompat.closeSocket(fd)
            return .error(errno: code)
        }

        let rc = SocketCompat.connectSocket(fd, &addr)
        if rc == 0 { return .connected(fd: fd) } // 回环可立即完成
        let pending = SocketCompat.lastError
        guard SocketCompat.connectPending(pending) else {
            SocketCompat.closeSocket(fd)
            switch pending {
            case SocketCompat.econnrefused: return .refused
            case SocketCompat.enetunreach, SocketCompat.ehostunreach: return .unreachable
            default: return .error(errno: pending)
            }
        }

        switch SocketCompat.waitForConnect(fd, timeoutMs: max(1, Int(timeout * 1000))) {
        case .ready:
            break
        case .timedOut:
            SocketCompat.closeSocket(fd)
            return .timedOut
        case .failed(let code):
            SocketCompat.closeSocket(fd)
            return .error(errno: code)
        }
        guard let soError = SocketCompat.getSocketError(fd) else {
            let e = SocketCompat.lastError
            SocketCompat.closeSocket(fd)
            return .error(errno: e)
        }
        switch soError {
        case 0:
            return .connected(fd: fd)
        case SocketCompat.econnrefused:
            SocketCompat.closeSocket(fd); return .refused
        case SocketCompat.etimedout:
            SocketCompat.closeSocket(fd); return .timedOut
        case SocketCompat.enetunreach, SocketCompat.ehostunreach:
            SocketCompat.closeSocket(fd); return .unreachable
        default:
            SocketCompat.closeSocket(fd); return .error(errno: soError)
        }
    }

    private func closeTCPLocked() {
        if tcpSock >= 0 { SocketCompat.closeSocket(tcpSock) }
        tcpSock = -1
        tcpConnected = false
        tcpBuffer = Data()
    }

    private func drainTCPLocked() {
        guard tcpSock >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = SocketCompat.receive(tcpSock, &buffer, buffer.count)
            if n > 0 {
                tcpBuffer.append(Data(buffer[0 ..< n]))
                if n < buffer.count { break }
            } else if n == 0 {
                emit(.log("tcp channel closed by robot"))
                closeTCPLocked()
                return
            } else {
                if SocketCompat.wouldBlock(SocketCompat.lastError) { break }
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
        let ok = SocketCompat.sendData(tcpSock, data) == data.count
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
        let allowTickHook = sendControlPacketLocked(now: now)
        ensureTCPLocked(now: now)
        if allowTickHook { tickHook?() }

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
