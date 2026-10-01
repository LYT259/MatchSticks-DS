import Foundation
import Darwin

// MARK: - MOCK 摄像头通道（GHDSSim 侧；Phase 4 摄像头流的无硬件占位）
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
        if sock >= 0 { close(sock) }
    }

    private func listenLoop() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { onLog?("MOCK 摄像头 socket 创建失败"); return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1")) // 仅回环（字节序见 WebUIServer 注释）
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            onLog?("MOCK 摄像头监听失败 :\(port)（errno \(errno)）")
            close(fd)
            lock.lock(); runningFlag = false; lock.unlock()
            return
        }
        var got = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var realPort: UInt16 = port
        let gs = withUnsafeMutablePointer(to: &got) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        if gs == 0 { realPort = UInt16(bigEndian: got.sin_port) }
        lock.lock(); listenSock = fd; boundPortValue = realPort; lock.unlock()
        onLog?("MOCK 摄像头通道：http://127.0.0.1:\(realPort)/frame.jpg")

        while true {
            lock.lock(); let active = runningFlag; lock.unlock()
            if !active { close(fd); return }
            var clientAddr = sockaddr_in()
            var alen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &alen) }
            }
            guard client >= 0 else { break }
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.handle(client) }
        }
        close(fd)
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // 只读请求行即可路由（本通道无 body 语义）
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buf, buf.count, 0)
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
