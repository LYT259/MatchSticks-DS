import Foundation

// MARK: - 防火墙入站验证探针（BSD socket 临时监听）

/// 监听地址候选：由 getifaddrs 映射出的 IPv4 地址；`prefixLength` 为 0 表示没有有效掩码。
struct FirewallInterface: Equatable {
    let name: String
    let address: String
    let prefixLength: Int
    let isUp: Bool
    let isLoopback: Bool
}

/// 一次入站连接的地址对（点分十进制字面值；不做反向 DNS，不信任请求头里的地址字段）。
struct FirewallProbePeer {
    let source: String
    let destination: String
}

/// 探针抽象：生产为真实 BSD 监听，测试注入假实现——不建套接字。
@MainActor
protocol FirewallProbeControlling: AnyObject {
    var onState: (@MainActor (FirewallProbeState) -> Void)? { get set }
    func start()
    func stop()
}

// MARK: - 请求解析

/// 验证请求的有界解析。只承认精确的 `GET /verify` HTTP/1.0 或 HTTP/1.1 且不带正文；
/// 其他方法、路径、查询串、畸形、超长或尚未结束的数据一律不能通过。
enum FirewallHTTPRequest {
    enum Result: Equatable { case valid, invalid, incomplete }

    /// 含请求行与全部头部的总上限
    static let maximumLength = 4096

    private static let requestLines: Set<[UInt8]> = [
        Array("GET /verify HTTP/1.0".utf8),
        Array("GET /verify HTTP/1.1".utf8),
    ]

    static func parse(_ data: Data) -> Result {
        guard data.count <= maximumLength else { return .invalid }
        let bytes = [UInt8](data)

        // HTTP 要求 CRLF 行结束：NUL 与裸 LF 直接判畸形；裸 CR 若在末尾可能是尚未到齐的 CRLF。
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0D {
                guard index + 1 < bytes.count else { return .incomplete }
                guard bytes[index + 1] == 0x0A else { return .invalid }
                index += 2
                continue
            }
            if byte == 0x0A || byte == 0x00 { return .invalid }
            index += 1
        }

        var lines: [[UInt8]] = []
        var start = 0
        index = 0
        while index + 1 < bytes.count {
            if bytes[index] == 0x0D {
                lines.append(Array(bytes[start..<index]))
                index += 2
                start = index
            } else {
                index += 1
            }
        }
        let trailing = Array(bytes[start...])

        guard let requestLine = lines.first else {
            // 请求行尚未结束：只有仍可能成为合法请求行前缀时才继续等待
            return Self.requestLines.contains { $0.starts(with: trailing) } ? .incomplete : .invalid
        }
        guard Self.requestLines.contains(requestLine) else { return .invalid }

        var cursor = 1
        while cursor < lines.count {
            let line = lines[cursor]
            if line.isEmpty {
                // 头部结束：空行之后不得再有任何数据（额外 CRLF 或正文都算正文）
                return cursor == lines.count - 1 && trailing.isEmpty ? .valid : .invalid
            }
            guard Self.isHeaderLine(line) else { return .invalid }
            cursor += 1
        }
        // 尚未收到结束空行；未终止的尾行若不是头部形态（例如正文）即判畸形
        return trailing.isEmpty || Self.isHeaderLine(trailing) ? .incomplete : .invalid
    }

    /// `field-name ":" OWS value`：field-name 为 RFC 7230 token，冒号前不得有空白；
    /// 值只允许 HTAB、可见 ASCII 与 obs-text，不得含控制字符。
    private static func isHeaderLine(_ line: [UInt8]) -> Bool {
        guard let colon = line.firstIndex(of: 0x3A), colon > 0 else { return false }
        guard line[0..<colon].allSatisfy(isTokenByte) else { return false }
        return line[(colon + 1)...].allSatisfy { byte in
            byte == 0x09 || (0x20...0x7E).contains(byte) || byte >= 0x80
        }
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x30...0x39, 0x41...0x5A, 0x5E...0x7A, 0x7C, 0x7E:
            return true
        default:
            return false
        }
    }
}

// MARK: - 探针

/// 队列侧事件；`FirewallProbeState` 是主线程隔离类型，只能在主线程构造。
private enum FirewallProbeEvent {
    case waiting(URL), verified(peer: String), unavailable, failed, timedOut

    @MainActor var state: FirewallProbeState {
        switch self {
        case .waiting(let url): return .waiting(url)
        case .verified(let peer): return .verified(peer: peer)
        case .unavailable: return .unavailable
        case .failed: return .failed
        case .timedOut: return .timedOut
        }
    }
}

/// 防火墙入站验证探针：在本机某个活跃非回环 IPv4 地址上临时监听端口 0，等待另一台设备访问
/// `http://<地址>:<端口>/verify`。只有完整收到有效非回环请求并完整发送响应后才发布 `.verified`；
/// 绑定 / 监听失败、无地址、超时与取消都只是“未验证”，从不推断为防火墙拒绝。
/// 不依赖 NWListener、DSClient、WebUI 或 NT4；不记录对端地址、请求头或请求内容。
@MainActor
final class FirewallVerificationProbe: FirewallProbeControlling {
    var onState: (@MainActor (FirewallProbeState) -> Void)?

    /// 监听器内所有描述符操作只在这条串行队列上执行；主线程只持有监听器句柄和代际号。
    private let queue = DispatchQueue(label: "org.ghfrc.driverstation.firewall-verification", qos: .utility)
    private var listener: FirewallListener?
    /// 每次 start / stop 递增；旧代际已排队到主线程的回调不得再发布状态。
    private var generation = 0
    private var isRunning = false

    /// 异步且幂等：已启动则不重复创建监听。
    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        let generation = generation
        let emit: (FirewallProbeEvent) -> Void = { [weak self] event in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.onState?(event.state)
            }
        }
        let listener = FirewallListener(queue: queue, emit: emit)
        self.listener = listener
        queue.async { listener.start() }
    }

    /// 幂等：取消读源并关闭全部描述符；之后可再次 start（新代际、新端口）。
    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        let listener = self.listener
        self.listener = nil
        queue.async { listener?.stop() }
    }

    // MARK: 地址选择与对端校验（纯函数，无套接字）

    /// 确定性地选择一个监听地址：只取已启用、非回环、有有效掩码的 IPv4 单播地址，
    /// 排除 0.0.0.0 / 零掩码、回环、组播（首字节 ≥ 224）、广播；按接口名再按数值地址排序。
    /// 没有合格地址时返回 nil——绝不回退到 0.0.0.0 或 127.0.0.1。
    nonisolated static func selectListenAddress(_ interfaces: [FirewallInterface]) -> String? {
        let candidates: [(name: String, number: UInt32, address: String)] = interfaces.compactMap { item in
            guard let number = ipv4Number(item.address), isEligibleListenAddress(item, number: number) else { return nil }
            return (item.name, number, item.address)
        }
        return candidates.min { lhs, rhs in
            lhs.name != rhs.name ? lhs.name < rhs.name : lhs.number < rhs.number
        }?.address
    }

    /// 来源属于本机：回环、未指定、localhost，或本机任一接口的地址（含本机连接自己的局域网地址）。
    nonisolated static func isLocalPeer(_ source: String, localAddresses: Set<String>) -> Bool {
        if localAddresses.contains(source) || source == "localhost" || source == "::" || source == "::1" {
            return true
        }
        guard let number = ipv4Number(source) else { return false }
        return number == 0 || number >> 24 == 127
    }

    /// 有效对端：目的地址必须等于对外公布的地址，且来源不是本机。
    nonisolated static func isValidPeer(_ peer: FirewallProbePeer, advertisedAddress: String,
                                        localAddresses: Set<String>) -> Bool {
        peer.destination == advertisedAddress && !isLocalPeer(peer.source, localAddresses: localAddresses)
    }

    /// 当前全部 IPv4 接口地址（含回环与未启用接口），用于识别本机来源。
    nonisolated static func enumerateInterfaces() -> [FirewallInterface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let head = list else { return [] }
        defer { freeifaddrs(list) }
        var interfaces: [FirewallInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let item = cursor {
            cursor = item.pointee.ifa_next
            guard let rawAddress = item.pointee.ifa_addr,
                  Int32(rawAddress.pointee.sa_family) == AF_INET else { continue }
            let address = rawAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            guard let text = text(of: address.sin_addr) else { continue }
            var prefixLength = 0
            if let rawMask = item.pointee.ifa_netmask, Int32(rawMask.pointee.sa_family) == AF_INET {
                let mask = rawMask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                prefixLength = UInt32(bigEndian: mask.sin_addr.s_addr).nonzeroBitCount
            }
            let flags = item.pointee.ifa_flags
            interfaces.append(FirewallInterface(
                name: String(cString: item.pointee.ifa_name), address: text, prefixLength: prefixLength,
                isUp: flags & UInt32(IFF_UP) != 0, isLoopback: flags & UInt32(IFF_LOOPBACK) != 0))
        }
        return interfaces
    }

    /// inet_ntop 的点分十进制字面值。
    fileprivate nonisolated static func text(of address: in_addr) -> String? {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }

    private nonisolated static func isEligibleListenAddress(_ item: FirewallInterface, number: UInt32) -> Bool {
        guard item.isUp, !item.isLoopback, (1...32).contains(item.prefixLength) else { return false }
        let firstOctet = number >> 24
        // 0.x（含 0.0.0.0）、127/8、≥ 224（组播 / 保留 / 广播）都不能作为验证监听地址
        guard firstOctet != 0, firstOctet != 127, firstOctet < 224 else { return false }
        let hostBits = 32 - item.prefixLength
        let hostMask = hostBits >= 32 ? UInt32.max : UInt32(1 << hostBits) - 1
        return number & hostMask != hostMask   // 子网广播地址（主机位全 1）
    }

    /// 严格的点分十进制 IPv4 解析（四段、每段 0–255、仅 ASCII 数字）。
    private nonisolated static func ipv4Number(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var number: UInt32 = 0
        for part in parts {
            guard (1...3).contains(part.utf8.count), part.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                  let octet = UInt32(part), octet <= 255 else { return nil }
            number = number << 8 | octet
        }
        return number
    }
}

// MARK: - 监听器（串行队列独占）

/// 描述符的单一关闭点：取消处理器只捕获它，不反向引用连接或监听器，避免引用循环。
private final class DescriptorCloser {
    private let fd: Int32
    private var isClosed = false

    init(fd: Int32) { self.fd = fd }

    func closeDescriptor() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fd)
    }
}

/// 静态响应：只含固定文案，不回显请求内容；HTTP/1.0 + Connection: close 让客户端读完即结束。
private enum FirewallResponse {
    case success, forbidden, notFound

    var data: Data {
        let status: String, body: String
        switch self {
        case .success:
            status = "200 OK"
            body = "Verification received: an inbound request from another device reached this Mac. Return to MatchSticks Driver Station. Only this port was checked, at this moment.\n"
        case .forbidden:
            status = "403 Forbidden"
            body = "Local interface rejected: open this address from another device on the same network.\n"
        case .notFound:
            status = "404 Not Found"
            body = "Verification not accepted: use a plain GET /verify request.\n"
        }
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.0 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(bodyData.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        return Data(head.utf8) + bodyData
    }
}

/// 单个已接受的连接；只在监听队列上访问。
private final class FirewallConnection {
    enum Phase { case readingRequest, writingResponse, draining }

    let fd: Int32
    let closer: DescriptorCloser
    /// 对端地址字面值；只有验证成功时才进入证据
    let peer: String
    /// 回环或本机接口地址：无论请求内容如何都返回 403，且永不验证
    let isLocalPeer: Bool
    var phase = Phase.readingRequest
    var buffer = Data()
    var responseKind: FirewallResponse?
    var response: Data?
    var responseOffset = 0
    var readSource: DispatchSourceRead?
    var writeSource: DispatchSourceWrite?
    var deadline: DispatchWorkItem?
    var isClosing = false

    init(fd: Int32, peer: String, isLocalPeer: Bool) {
        self.fd = fd
        self.closer = DescriptorCloser(fd: fd)
        self.peer = peer
        self.isLocalPeer = isLocalPeer
    }
}

/// 临时监听器：接口枚举、绑定、监听、accept、读写、超时与取消全部只在 `queue` 上执行；
/// 状态只经 `emit` 交给主线程，主线程按代际号丢弃过期回调。
/// 对象只在创建后经 `queue.async` 交给该队列（串行，先 start 后 stop），故按队列独占标记 Sendable。
private final class FirewallListener: @unchecked Sendable {
    /// 整体等待上限：超时即关闭监听，保持未验证
    static let overallTimeout: TimeInterval = 120
    /// 单个连接从 accept 到关闭的上限
    static let connectionTimeout: TimeInterval = 5

    private static let onQueueKey = DispatchSpecificKey<UInt8>()

    private let queue: DispatchQueue
    private let emit: (FirewallProbeEvent) -> Void

    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var connections: [FirewallConnection] = []
    private var advertisedAddress = ""
    private var isStopped = false

    init(queue: DispatchQueue, emit: @escaping (FirewallProbeEvent) -> Void) {
        self.queue = queue
        self.emit = emit
        queue.setSpecific(key: Self.onQueueKey, value: 1)
    }

    deinit {
        // 持有者未显式 stop 就释放时仍要关闭全部描述符；已在队列上则直接收尾，避免 sync 自锁
        if DispatchQueue.getSpecific(key: Self.onQueueKey) != nil {
            stop()
        } else {
            queue.sync { stop() }
        }
    }

    // MARK: 生命周期

    func start() {
        guard !isStopped else { return }
        guard let address = FirewallVerificationProbe.selectListenAddress(
            FirewallVerificationProbe.enumerateInterfaces()) else {
            // 没有可用的非回环地址：验证不可用，而不是防火墙拒绝；不回退到 0.0.0.0 或 127.0.0.1
            isStopped = true
            emit(.unavailable)
            return
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        // 只绑定这个具体地址的端口 0；任何一步失败都只是“未完成”，不做通配重试
        guard fd >= 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0,
              Self.setNonBlocking(fd),
              Self.bindSocket(fd, to: address) == 0,
              listen(fd, 8) == 0,
              let port = Self.socketPort(fd),
              let url = URL(string: "http://\(address):\(port)/verify") else {
            if fd >= 0 { Darwin.close(fd) }
            isStopped = true
            emit(.failed)
            return
        }
        advertisedAddress = address
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        // 只有 GCD 取消读源之后才关闭监听描述符，避免描述符号被复用
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        listenSource = source
        source.resume()
        emit(.waiting(url))
        queue.asyncAfter(deadline: .now() + Self.overallTimeout) { [weak self] in
            guard let self, !self.isStopped, self.listenSource != nil else { return }
            self.emit(.timedOut)
            self.stop()
        }
    }

    /// 幂等：取消监听读源与每个连接的读 / 写源，由各自的取消处理器关闭描述符。
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        listenFD = -1
        listenSource?.cancel()
        listenSource = nil
        connections.forEach { close($0) }
    }

    // MARK: 接受连接

    private func acceptPending() {
        let listenFD = self.listenFD
        guard listenFD >= 0 else { return }
        while !isStopped {
            let fd = accept(listenFD, nil, nil)
            if fd >= 0 {
                handleAccepted(fd)
                continue
            }
            let error = errno
            if error == EINTR { continue }
            if error != EAGAIN {
                // 资源耗尽等无法恢复的错误：结束监听并报告未完成，而不是空转
                emit(.failed)
                stop()
            }
            return
        }
    }

    private func handleAccepted(_ fd: Int32) {
        let closer = DescriptorCloser(fd: fd)
        var one: Int32 = 1
        guard !isStopped,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0,
              Self.setNonBlocking(fd),
              // 目的地址必须等于对外公布的地址；来源必须是 AF_INET 非回环、非未指定且不属于本机任一接口地址
              let destination = Self.socketText(fd, using: getsockname),
              let source = Self.socketText(fd, using: getpeername) else {
            closer.closeDescriptor()
            return
        }
        let isValidPeer = FirewallVerificationProbe.isValidPeer(
            FirewallProbePeer(source: source, destination: destination),
            advertisedAddress: advertisedAddress,
            localAddresses: Set(FirewallVerificationProbe.enumerateInterfaces().map(\.address)))
        let connection = FirewallConnection(fd: fd, peer: source, isLocalPeer: !isValidPeer)
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.readAvailable(connection)
        }
        readSource.setCancelHandler { [closer] in closer.closeDescriptor() }
        connection.readSource = readSource
        connections.append(connection)
        readSource.resume()
        let deadline = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.deadlineReached(connection)
        }
        connection.deadline = deadline
        queue.asyncAfter(deadline: .now() + Self.connectionTimeout, execute: deadline)
    }

    // MARK: 读取与判定

    private func readAvailable(_ connection: FirewallConnection) {
        guard !connection.isClosing else { return }
        var scratch = [UInt8](repeating: 0, count: FirewallHTTPRequest.maximumLength)
        while !connection.isClosing {
            let count = recv(connection.fd, &scratch, scratch.count, 0)
            if count > 0 {
                guard consume(connection, scratch[0..<count]) else { return }
                if count < scratch.count { return }
                continue
            }
            if count == 0 {
                // 对端已关闭
                close(connection)
                return
            }
            let error = errno
            if error == EINTR { continue }
            if error != EAGAIN {
                // ECONNRESET 等：对端消失，不产生证据
                close(connection)
            }
            return
        }
    }

    /// 返回 false 表示本轮读取应停止（已进入响应阶段或已关闭）。
    private func consume(_ connection: FirewallConnection, _ slice: ArraySlice<UInt8>) -> Bool {
        switch connection.phase {
        case .readingRequest:
            connection.buffer.append(contentsOf: slice)
            if connection.isLocalPeer {
                // 回环或本机接口地址：无论请求内容如何都不能证明外部入站路径，固定返回 403
                respond(connection, with: .forbidden)
                return false
            }
            switch FirewallHTTPRequest.parse(connection.buffer) {
            case .valid:
                respond(connection, with: .success)
                return false
            case .invalid:
                respond(connection, with: .notFound)
                return false
            case .incomplete:
                return true
            }
        case .writingResponse, .draining:
            return true
        }
    }

    /// 5 秒内没有完整有效的请求：不产生任何证据；仍在读请求时返回静态拒绝后关闭。
    private func deadlineReached(_ connection: FirewallConnection) {
        guard !connection.isClosing else { return }
        switch connection.phase {
        case .readingRequest:
            respond(connection, with: connection.isLocalPeer ? .forbidden : .notFound)
            close(connection)
        case .writingResponse, .draining:
            close(connection)
        }
    }

    // MARK: 发送与关闭

    private func respond(_ connection: FirewallConnection, with kind: FirewallResponse) {
        guard connection.phase == .readingRequest else { return }
        connection.phase = .writingResponse
        connection.responseKind = kind
        connection.response = kind.data
        connection.responseOffset = 0
        sendPending(connection)
    }

    private func sendPending(_ connection: FirewallConnection) {
        guard !connection.isClosing, connection.phase == .writingResponse,
              let response = connection.response else { return }
        while connection.responseOffset < response.count {
            let offset = connection.responseOffset
            let sent = response.withUnsafeBytes { bytes in
                send(connection.fd, bytes.baseAddress!.advanced(by: offset), response.count - offset, MSG_NOSIGNAL)
            }
            if sent > 0 {
                connection.responseOffset += sent
                continue
            }
            guard sent < 0 else {
                close(connection)
                return
            }
            let error = errno
            if error == EINTR { continue }
            if error == EAGAIN {
                if connection.writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: connection.fd, queue: queue)
                    source.setEventHandler { [weak self, weak connection] in
                        guard let self, let connection else { return }
                        self.sendPending(connection)
                    }
                    // 写源不拥有描述符：读源的取消处理器统一关闭
                    source.resume()
                    connection.writeSource = source
                }
                return
            }
            // EPIPE / ECONNRESET：对端已消失，部分发送绝不成为证据
            close(connection)
            return
        }
        responseSent(connection)
    }

    private func responseSent(_ connection: FirewallConnection) {
        connection.writeSource?.cancel()
        connection.writeSource = nil
        let kind = connection.responseKind
        connection.response = nil
        // 已完整发送：先发 FIN，再读完对端后续数据直到 EOF（仍受 5 秒上限约束），
        // 避免带未读数据关闭触发 RST 让对端收不到响应。
        shutdown(connection.fd, SHUT_WR)
        connection.phase = .draining
        if kind == .success {
            emit(.verified(peer: connection.peer))
            finishAfterVerification(keeping: connection)
        }
    }

    /// 已取得证据：立即停止监听，其余连接全部关闭；验证连接只负责读到 EOF 后关闭。
    private func finishAfterVerification(keeping verified: FirewallConnection) {
        listenFD = -1
        listenSource?.cancel()
        listenSource = nil
        connections.filter { $0 !== verified }.forEach { close($0) }
    }

    /// 关闭连接：取消读 / 写源与超时，描述符由读源的取消处理器关闭（幂等）。
    private func close(_ connection: FirewallConnection) {
        guard !connection.isClosing else { return }
        connection.isClosing = true
        connection.deadline?.cancel()
        connections.removeAll { $0 === connection }
        connection.writeSource?.cancel()
        connection.writeSource = nil
        guard let readSource = connection.readSource else {
            connection.closer.closeDescriptor()
            return
        }
        readSource.cancel()
    }

    // MARK: 套接字辅助

    private static func setNonBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    /// 只绑定到给定地址（端口 0）；不设置 SO_REUSEADDR，不回退到 INADDR_ANY。
    private static func bindSocket(_ fd: Int32, to address: String) -> Int32 {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else { return -1 }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private static func socketPort(_ fd: Int32) -> UInt16? {
        guard let addr = socketAddress(fd, using: getsockname) else { return nil }
        return UInt16(bigEndian: addr.sin_port)
    }

    private static func socketText(_ fd: Int32,
                                   using query: (Int32, UnsafeMutablePointer<sockaddr>,
                                                 UnsafeMutablePointer<socklen_t>) -> Int32) -> String? {
        guard let addr = socketAddress(fd, using: query) else { return nil }
        return FirewallVerificationProbe.text(of: addr.sin_addr)
    }

    /// getsockname / getpeername 的 AF_INET 结果；其他地址族一律视为无效。
    private static func socketAddress(_ fd: Int32,
                                      using query: (Int32, UnsafeMutablePointer<sockaddr>,
                                                    UnsafeMutablePointer<socklen_t>) -> Int32) -> sockaddr_in? {
        var addr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { query(fd, $0, &length) }
        }
        guard result == 0, Int32(addr.sin_family) == AF_INET,
              length >= socklen_t(MemoryLayout<sockaddr_in>.size) else { return nil }
        return addr
    }
}
