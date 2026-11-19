import Foundation
import Darwin
import CryptoKit

// MARK: - NT4 Server（DS 侧，端口 6767；MrcComm/SystemCore 以 WebSocket 客户端反连）
//
// 传输：BSD 套接字 + 手写 WebSocket（HTTP Upgrade 握手 + RFC6455 帧编解码）。
// 不用 NWListener——macOS 27.0 beta 上 NWListener（含纯 TCP/UDP）start 即 EINVAL
//（系统 beta 缺陷，2026-09-16 独立探针复现）；BSD 路径已被本项目 UDP/TCP 测试充分验证。
//
// 线协议（2027 FirstDriverStation alpha 3 语义，经 robot_sim.py 交叉核对）：
//   - 子协议 "v4.1.networktables.first.wpi.edu"
//   - 文本帧：JSON **数组**，元素 {method, params}：
//       publish {name, pubuid, type, properties} / subscribe {topics:[前缀], subuid, options}
//       announce（server→client）params: {name, id, type, pubuid?, properties}
//   - 二进制帧：msgpack 数组 [pubuid或topic_id, timestamp_us, type_id, value]（可拼接）
//   - type_id：0 bool / 1 double / 2 int / 3 float / 4 string / 5 raw(protobuf)

public final class NT4Server: @unchecked Sendable {
    public enum NT4Value {
        case boolean(Bool)
        case double(Double)
        case int(Int64)
        case string(String)
        case raw(Data)
    }

    public static let defaultSubprotocol = "v4.1.networktables.first.wpi.edu"
    private static let wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private let port: UInt16
    private let lock = NSLock()
    private var listenSock: Int32 = -1
    private var runningFlag = false

    private var topics: [String: (id: UInt32, type: String)] = [:]
    private var nextTopicID: UInt32 = 1
    private var clients: [(sock: Int32, subscriptions: [String], publishers: [Int64: (name: String, type: String, topicID: UInt32)])] = []

    /// 机器人侧写入的值（DS 关心的状态位等）；任意线程回调
    public var onValue: ((String, NT4Value) -> Void)?
    public var onLog: ((String) -> Void)?

    public init(port: UInt16 = 6767) {
        self.port = port
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return runningFlag
    }

    public func start() {
        lock.lock()
        guard !runningFlag else { lock.unlock(); return }
        runningFlag = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.listenLoop()
        }
    }

    public func stop() {
        lock.lock()
        runningFlag = false
        let sock = listenSock
        let clientSocks = clients.map(\.sock)
        clients.removeAll()
        lock.unlock()
        if sock >= 0 { close(sock) }
        for s in clientSocks { shutdown(s, SHUT_RDWR); close(s) }
    }

    // MARK: 监听与握手

    private func listenLoop() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { onLog?(tr("NT4 socket 创建失败")); return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            onLog?(tr("NT4 监听失败 :%d（errno %d）", port, errno))
            close(fd)
            return
        }
        lock.lock()
        listenSock = fd
        lock.unlock()
        onLog?(tr("NT4 server 监听 :%d", port))

        while true {
            lock.lock()
            let active = runningFlag
            lock.unlock()
            if !active { close(fd); return }
            var clientAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
            }
            guard client >= 0 else { break }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handleConnection(client)
            }
        }
        close(fd)
    }

    private func handleConnection(_ fd: Int32) {
        guard let request = Self.readHTTPHeader(fd),
              let key = Self.headerValue(request, "Sec-WebSocket-Key"),
              request.lowercased().contains("upgrade: websocket") else {
            close(fd)
            return
        }
        let accept = Self.wsAccept(key: key)
        let response = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n"
            + "Sec-WebSocket-Protocol: \(Self.defaultSubprotocol)\r\n\r\n"
        let responseData = Data(response.utf8)
        guard responseData.withUnsafeBytes({ raw in send(fd, raw.baseAddress, raw.count, 0) }) == responseData.count else {
            close(fd)
            return
        }
        onLog?(tr("NT4 客户端已连接"))

        lock.lock()
        clients.append((fd, [], [:]))
        lock.unlock()
        frameLoop(fd)
    }

    private func frameLoop(_ fd: Int32) {
        var pending: [UInt8] = []
        while true {
            lock.lock()
            let active = runningFlag
            let connected = clients.contains { $0.sock == fd }
            lock.unlock()
            if !active || !connected { return }
            guard let (opcode, payload) = NT4Server.readFrame(fd, buffer: &pending) else { removeClient(fd); return }
            switch opcode {
            case 0x1: handleText(payload, from: fd)
            case 0x2: handleBinary(payload, from: fd)
            case 0x8:
                _ = Self.writeFrame(fd, opcode: 0x8, payload: Data())
                removeClient(fd)
                return
            case 0x9:
                _ = Self.writeFrame(fd, opcode: 0xA, payload: payload)
            default:
                break
            }
        }
    }

    private func removeClient(_ fd: Int32) {
        lock.lock()
        clients.removeAll { $0.sock == fd }
        lock.unlock()
        close(fd)
    }

    // MARK: 文本（publish / subscribe）

    private func handleText(_ payload: Data, from fd: Int32) {
        guard let array = (try? JSONSerialization.jsonObject(with: payload)) as? [[String: Any]] else { return }
        for event in array {
            guard let method = event["method"] as? String else { continue }
            let params = event["params"] as? [String: Any] ?? [:]
            switch method {
            case "publish":
                guard let name = params["name"] as? String else { continue }
                let pubuid = NT4Server.asInt64(params["pubuid"] as Any)   // 缺省 nil → 0（显式 Any，免隐式提升警告）
                let type = params["type"] as? String ?? "raw"
                let id = assignTopic(name: name, type: type)
                registerPublisher(fd: fd, pubuid: pubuid, name: name, type: type, topicID: id)
                sendAnnounce(name: name, id: id, type: type, pubuid: pubuid, to: [fd])
            case "subscribe":
                let prefixes = params["topics"] as? [String] ?? []
                setSubscriptions(fd: fd, prefixes: prefixes)
                lock.lock()
                let existing = topics
                lock.unlock()
                for (name, info) in existing where prefixes.contains(where: { name.hasPrefix($0) }) {
                    sendAnnounce(name: name, id: info.id, type: info.type, pubuid: nil, to: [fd])
                }
            default:
                break
            }
        }
    }

    // MARK: 二进制（值集）

    private func handleBinary(_ payload: Data, from fd: Int32) {
        guard let array = (try? MsgPack.unpackAll(payload)) as? [[Any]] else { return }
        for record in array where record.count == 4 {
            let pubuid = NT4Server.asInt64(record[0])
            let ts = NT4Server.asInt64(record[1])
            let typeID = Int(NT4Server.asInt64(record[2]))
            let value = record[3]
            lock.lock()
            let topic = clients.first { $0.sock == fd }?.publishers[pubuid]
            lock.unlock()
            guard let (name, _, topicID) = topic else { continue }     // 发布方声明的类型串此处不使用
            let ntValue = Self.ntValue(typeID: Int(typeID), raw: value)
            onValue?(name, ntValue)
            forward(name: name, topicID: topicID, ts: ts, value: value, excluding: fd)
        }
    }

    // MARK: DS 侧发布/写值（线程安全）

    @discardableResult
    public func publish(name: String, type: String) -> UInt32 {
        lock.lock()
        let id = assignTopicLocked(name: name, type: type)
        let clientSocks = clients.map(\.sock)
        lock.unlock()
        sendAnnounce(name: name, id: id, type: type, pubuid: nil, to: clientSocks)
        return id
    }

    public func set(name: String, _ value: NT4Value, timestampMs: Int64? = nil) {
        lock.lock()
        guard let (id, _) = topics[name] else { lock.unlock(); return }
        let typeID = Self.typeID(for: value)
        let tsUs = Int64(timestampMs ?? Int64(Date().timeIntervalSince1970 * 1000)) * 1000
        let frame = Self.encodeFrame(opcode: 0x2, payload: MsgPack.pack([Int(id), Int(tsUs), typeID, NT4Server.ntPackable(value)] as [Any]))
        let targets = clients.compactMap { client -> Int32? in
            client.subscriptions.contains(where: { name.hasPrefix($0) }) ? client.sock : nil
        }
        lock.unlock()
        for sock in targets {
            frame.withUnsafeBytes { raw in
                _ = send(sock, raw.baseAddress, raw.count, 0)
            }
        }
    }

    // MARK: 注册表

    private func assignTopic(name: String, type: String) -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        return assignTopicLocked(name: name, type: type)
    }

    private func assignTopicLocked(name: String, type: String) -> UInt32 {
        if let existing = topics[name] { return existing.id }
        let id = nextTopicID
        nextTopicID += 1
        topics[name] = (id, type)
        return id
    }

    private func registerPublisher(fd: Int32, pubuid: Int64, name: String, type: String, topicID: UInt32) {
        lock.lock(); defer { lock.unlock() }
        if let index = clients.firstIndex(where: { $0.sock == fd }) {
            clients[index].publishers[pubuid] = (name, type, topicID)
        }
    }

    private func setSubscriptions(fd: Int32, prefixes: [String]) {
        lock.lock(); defer { lock.unlock() }
        if let index = clients.firstIndex(where: { $0.sock == fd }) {
            clients[index].subscriptions = prefixes
        }
    }

    private func sendAnnounce(name: String, id: UInt32, type: String, pubuid: Int64?, to targets: [Int32]) {
        var params: [String: Any] = ["name": name, "id": Int(id), "type": type, "properties": [String: Any]()]
        if let pubuid { params["pubuid"] = pubuid }
        let msg: [[String: Any]] = [["method": "announce", "params": params]]
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        let frame = Self.encodeFrame(opcode: 0x1, payload: data)
        for sock in targets {
            frame.withUnsafeBytes { raw in
                _ = send(sock, raw.baseAddress, raw.count, 0)
            }
        }
    }

    private func forward(name: String, topicID: UInt32, ts: Int64, value: Any, excluding fd: Int32) {
        lock.lock()
        let targets = clients.compactMap { client -> Int32? in
            (client.sock != fd && client.subscriptions.contains(where: { name.hasPrefix($0) })) ? client.sock : nil
        }
        lock.unlock()
        guard !targets.isEmpty else { return }
        let frame = Self.encodeFrame(opcode: 0x2, payload: MsgPack.pack([Int(topicID), Int(ts), value] as [Any]))
        for sock in targets {
            frame.withUnsafeBytes { raw in
                _ = send(sock, raw.baseAddress, raw.count, 0)
            }
        }
    }

    // MARK: HTTP 握手 / WS 帧（静态纯函数）

    static func headerValue(_ request: String, _ name: String) -> String? {
        for line in request.split(separator: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func wsAccept(key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + Self.wsGUID).utf8))
        return Data(digest).base64EncodedString()
    }

    static func readHTTPHeader(_ fd: Int32) -> String? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 16384 {
            let n = recv(fd, &byte, 1, 0)
            guard n == 1 else { return nil }
            data.append(byte)
            if data.count >= 4, [UInt8](data.suffix(4)) == [0x0D, 0x0A, 0x0D, 0x0A] {
                return String(decoding: data, as: UTF8.self)
            }
        }
        return nil
    }

    static func writeFrame(_ fd: Int32, opcode: UInt8, payload: Data) -> Bool {
        let frame = encodeFrame(opcode: opcode, payload: payload)
        return frame.withUnsafeBytes({ raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return send(fd, base, raw.count, 0) == raw.count
        })
    }

    /// 读一帧（客户端帧带掩码；服务器→客户端帧不掩码）
    static func readFrame(_ fd: Int32, buffer: inout [UInt8]) -> (opcode: UInt8, payload: Data)? {
        func recvExact(_ n: Int) -> [UInt8]? {
            var out: [UInt8] = []
            while out.count < n {
                var chunk = [UInt8](repeating: 0, count: n - out.count)
                let got = recv(fd, &chunk, chunk.count, 0)
                guard got > 0 else { return nil }
                out.append(contentsOf: chunk[0..<got])
            }
            return out
        }
        while buffer.count < 2 {
            guard let c = recvExact(2 - buffer.count) else { return nil }
            buffer.append(contentsOf: c)
        }
        let b0 = buffer[0], b1 = buffer[1]
        let opcode = b0 & 0x0F
        let masked = b1 & 0x80 != 0
        var length = Int(b1 & 0x7F)
        var headerSize = 2
        if length == 126 {
            while buffer.count < 4 {
                guard let c = recvExact(4 - buffer.count) else { return nil }
                buffer.append(contentsOf: c)
            }
            length = Int(buffer[2]) << 8 | Int(buffer[3])
            headerSize = 4
        } else if length == 127 {
            while buffer.count < 10 {
                guard let c = recvExact(10 - buffer.count) else { return nil }
                buffer.append(contentsOf: c)
            }
            length = 0
            for i in 0..<8 { length = length << 8 | Int(buffer[2 + i]) }
            headerSize = 10
        }
        if masked {
            while buffer.count < headerSize + 4 {
                guard let c = recvExact(headerSize + 4 - buffer.count) else { return nil }
                buffer.append(contentsOf: c)
            }
            headerSize += 4
        }
        while buffer.count < headerSize + length {
            guard let c = recvExact(headerSize + length - buffer.count) else { return nil }
            buffer.append(contentsOf: c)
        }
        var payload = Array(buffer[headerSize ..< headerSize + length])
        if masked {
            let mask = Array(buffer[(headerSize - 4)..<headerSize])
            for i in 0..<payload.count { payload[i] ^= mask[i % 4] }
        }
        buffer.removeFirst(headerSize + length)
        return (opcode, Data(payload))
    }

    static func encodeFrame(opcode: UInt8, payload: Data) -> Data {
        var out = Data([0x80 | opcode]) // FIN + opcode；服务器帧不掩码
        let length = payload.count
        if length < 126 {
            out.append(UInt8(length))
        } else if length <= 0xFFFF {
            out.append(126)
            out.append(UInt8(length >> 8)); out.append(UInt8(length & 0xFF))
        } else {
            out.append(127)
            let v = UInt64(length)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((v >> UInt64(shift)) & 0xFF))
            }
        }
        out.append(payload)
        return out
    }

    /// 测试辅助：从套接字读一帧服务器消息（服务器帧不掩码；调用方自行设 SO_RCVTIMEO）
    public static func readTestFrame(_ fd: Int32) -> (opcode: UInt8, payload: Data)? {
        func recvExact(_ n: Int) -> [UInt8]? {
            var out: [UInt8] = []
            while out.count < n {
                var chunk = [UInt8](repeating: 0, count: n - out.count)
                let got = recv(fd, &chunk, chunk.count, 0)
                guard got > 0 else { return nil }
                out.append(contentsOf: chunk[0..<got])
            }
            return out
        }
        guard let h = recvExact(2) else { return nil }
        var buffer = h
        let opcode = buffer[0] & 0x0F
        var length = Int(buffer[1] & 0x7F)
        if length == 126 {
            guard let more = recvExact(2) else { return nil }
            buffer += more
            length = Int(buffer[2]) << 8 | Int(buffer[3])
        } else if length == 127 {
            guard let more = recvExact(8) else { return nil }
            buffer += more
            length = 0
            for i in 0..<8 { length = length << 8 | Int(buffer[2 + i]) }
        }
        guard let payload = recvExact(length) else { return nil }
        return (opcode, Data(payload))
    }

    // MARK: 工具

    static func typeID(for value: NT4Value) -> Int {
        switch value {
        case .boolean: return 0
        case .double: return 1
        case .int: return 2
        case .string: return 4
        case .raw: return 5
        }
    }

    static func ntValue(typeID: Int, raw: Any) -> NT4Value {
        switch typeID {
        case 0: return .boolean(raw as? Bool ?? false)
        case 1: return .double(raw as? Double ?? 0)
        case 2: return .int(NT4Server.asInt64(raw))
        case 4: return .string(raw as? String ?? "")
        case 5: return .raw(raw as? Data ?? Data())
        default: return .raw(Data())
        }
    }

    static func ntPackable(_ value: NT4Value) -> Any {
        switch value {
        case .boolean(let b): return b
        case .double(let d): return d
        case .int(let i): return i
        case .string(let s): return s
        case .raw(let d): return d
        }
    }

    static func asInt64(_ value: Any) -> Int64 {
        switch value {
        case let v as Int: return Int64(v)
        case let v as Int64: return v
        case let v as UInt64: return Int64(bitPattern: v)
        case let v as UInt32: return Int64(v)
        case let v as Double: return Int64(v)
        default: return 0
        }
    }
}
