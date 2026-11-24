import Foundation

// MARK: - MOCK 摄像头通道（MatchSticksDriverStaionSim 侧；Phase 4 摄像头流的无硬件占位）
//
// ⚠️ 这不是 SystemCore 的真实摄像头流协议——真实协议无实机未核查（协议档案待实测清单），
// 本通道仅为 DS 侧显示管线与本机联调提供自定义 MOCK 图源，禁止当作协议事实使用。
// 形态：127.0.0.1 HTTP，GET /frame.jpg 返回一帧 JPEG（帧内容由宿主注入，按需生成）。

public final class MockCameraServer {
    public let port: UInt16
    private let frameProvider: () -> Data
    private let lock = NSLock()
    private var listenSock: Int32 = -1
    private var runningFlag = false
    private var boundPortValue: UInt16 = 0
    public var onLog: ((String) -> Void)?

    public init(port: UInt16 = 6769, frameProvider: @escaping () -> Data) {
        self.port = port
        self.frameProvider = frameProvider
    }

    public var boundPort: UInt16 {
        lock.lock(); defer { lock.unlock() }
        return boundPortValue
    }

    public func start() {
        lock.lock()
        guard !runningFlag else { lock.unlock(); return }
        runningFlag = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.listenLoop() }
    }

    public func stop() {
        lock.lock()
        runningFlag = false
        let sock = listenSock
        lock.unlock()
        if sock >= 0 { SocketCompat.closeSocket(sock) }
    }

    private func listenLoop() {
        let fd = SocketCompat.tcpSocket()
        guard fd >= 0 else { onLog?(tr("MOCK 摄像头 socket 创建失败")); return }
        _ = SocketCompat.setReuseAddress(fd)
        var addr = SocketCompat.loopbackAddress(port: port) // 仅回环
        let bound = SocketCompat.bindSocket(fd, &addr)
        guard bound == 0, SocketCompat.listenSocket(fd, backlog: 4) == 0 else {
            onLog?(tr("MOCK 摄像头监听失败 :%d（errno %d）", port, Int(SocketCompat.lastError)))
            SocketCompat.closeSocket(fd)
            lock.lock(); runningFlag = false; lock.unlock()
            return
        }
        var realPort: UInt16 = port
        if let local = SocketCompat.localAddress(fd) { realPort = SocketCompat.port(of: local) }
        lock.lock(); listenSock = fd; boundPortValue = realPort; lock.unlock()
        onLog?(tr("MOCK 摄像头通道：http://127.0.0.1:%d/frame.jpg", realPort))

        while true {
            lock.lock(); let active = runningFlag; lock.unlock()
            if !active { SocketCompat.closeSocket(fd); return }
            let client = SocketCompat.acceptSocket(fd)
            guard client >= 0 else { break }
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.handle(client) }
        }
        SocketCompat.closeSocket(fd)
    }

    private func handle(_ fd: Int32) {
        defer { SocketCompat.closeSocket(fd) }
        _ = SocketCompat.setReceiveTimeout(fd, seconds: 5)
        // 只读请求行即可路由（本通道无 body 语义）
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = SocketCompat.receive(fd, &buf, buf.count)
        guard n > 0, let head = String(bytes: buf[0..<n], encoding: .utf8),
              let line = head.components(separatedBy: "\r\n").first else {
            _ = WebUIServer.send(fd, Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else {
            _ = WebUIServer.send(fd, Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        switch (parts[0].uppercased(), parts[1].hasSuffix("?t=") ? String(parts[1].dropLast(3)) : String(parts[1])) {
        case ("GET", "/frame.jpg"), ("GET", "/"), ("GET", "/index.html"):
            let jpeg = frameProvider()
            let ok = "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\nConnection: close\r\n\r\n"
            _ = WebUIServer.send(fd, Data(ok.utf8) + jpeg)
        default:
            let notFound = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\nConnection: close\r\n\r\nnot found"
            _ = WebUIServer.send(fd, Data(notFound.utf8))
        }
    }
}

// MARK: - 限流器（点按刷新防抖；时钟可注入——「给定条件可复现」底线）

public final class RateLimiter: @unchecked Sendable {
    private let minInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var lastAllowed: Date?

    public init(minInterval: TimeInterval, now: @escaping @Sendable () -> Date = { Date() }) {
        self.minInterval = minInterval
        self.now = now
    }

    /// 本次请求是否放行；放行即记录时刻
    public func allow() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        if let last = lastAllowed, t.timeIntervalSince(last) < minInterval { return false }
        lastAllowed = t
        return true
    }

    /// 距下次可用的秒数（UI 倒计时提示用）
    public func retryAfterSeconds() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let last = lastAllowed else { return 0 }
        return max(0, minInterval - now().timeIntervalSince(last))
    }
}
