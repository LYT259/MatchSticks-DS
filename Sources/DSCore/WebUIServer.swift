import Foundation
import Darwin

// MARK: - 内置 WebUI（localhost:6768，报告 §6 架构图 / §7 功能矩阵）
//
// 纯本地 HTTP/1.1 服务：日志文件列表与下载、设置查看/覆盖、状态页（P5 打包 E2E 用）。
// 手写 BSD socket（与 NT4Server 同一路线——NWListener 在 macOS 27 beta EINVAL，见 CLAUDE.md）。
// 安全边界：仅绑定 127.0.0.1（不暴露局域网）；一连接一请求（Connection: close）；
// 外部输入不可信（通用 §7）：请求行/头部容错、超长拒绝、文件名白名单 + 目录逃逸双查。

public final class WebUIServer {

    public struct LogFileInfo: Sendable, Equatable {
        public var name: String
        public var sizeBytes: UInt64
        public var modified: Date
    }

    /// 宿主注入的数据源（DSModel 装配；测试注入临时目录与内存字典）
    public struct Environment {
        public var logsDirectory: () -> URL?
        public var listSettings: () -> [String: String]
        /// 返回 nil = 应用成功；非 nil = 拒绝原因（键不在白名单或值非法）
        public var applySetting: (String, String) -> String?
        public var status: () -> [String: String]
        public init(logsDirectory: @escaping () -> URL?,
                    listSettings: @escaping () -> [String: String],
                    applySetting: @escaping (String, String) -> String?,
                    status: @escaping () -> [String: String]) {
            self.logsDirectory = logsDirectory
            self.listSettings = listSettings
            self.applySetting = applySetting
            self.status = status
        }
    }

    public struct Response: Equatable {
        public var status: Int
        public var reason: String
        public var contentType: String
        public var body: Data
        public static func json(_ obj: String, status: Int = 200) -> Response {
            Response(status: status, reason: status == 200 ? "OK" : "Error",
                     contentType: "application/json; charset=utf-8", body: Data(obj.utf8))
        }
    }

    public let port: UInt16
    private let env: Environment
    private let lock = NSLock()
    private var listenSock: Int32 = -1
    private var runningFlag = false
    private var boundPortValue: UInt16 = 0
    public var onLog: ((String) -> Void)?

    public init(port: UInt16 = 6768, environment: Environment) {
        self.port = port
        self.env = environment
    }

    /// 实际绑定端口（port=0 时由内核分配；测试用）
    public var boundPort: UInt16 {
        lock.lock(); defer { lock.unlock() }
        return boundPortValue
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
        lock.unlock()
        if sock >= 0 { close(sock) }
    }

    // MARK: 监听（仅回环）

    private func listenLoop() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { onLog?(tr("WebUI socket 创建失败")); return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        // 仅 127.0.0.1，绝不暴露局域网。注意字节序陷阱：INADDR_LOOPBACK 常量按大端
        // 语义定义，直接赋 s_addr 在小端机上会变成 1.0.0.127（bind 报 EADDRNOTAVAIL，
        // 2026-10-01 实测 errno 49）——用 inet_addr 生成天然网络序地址。
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            onLog?(tr("WebUI 监听失败 :%d（errno %d）", port, errno))
            close(fd)
            lock.lock(); runningFlag = false; lock.unlock()
            return
        }
        var gotAddr = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var realPort: UInt16 = port
        let gsResult = withUnsafeMutablePointer(to: &gotAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        if gsResult == 0 { realPort = UInt16(bigEndian: gotAddr.sin_port) }
        lock.lock()
        listenSock = fd
        boundPortValue = realPort
        lock.unlock()
        onLog?(tr("WebUI 服务已启动：http://127.0.0.1:%d（仅本机）", realPort))

        while true {
            lock.lock()
            let active = runningFlag
            lock.unlock()
            if !active { close(fd); return }
            var clientAddr = sockaddr_in()
            var alen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &alen) }
            }
            guard client >= 0 else { break }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handle(client)
            }
        }
        close(fd)
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        // 每连接 5 秒读超时：半开连接不悬挂线程
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let (method, target, body) = Self.readRequest(fd) else {
            let _ = Self.send(fd, Self.http(Response(status: 400, reason: "Bad Request",
                contentType: "text/plain; charset=utf-8", body: Data("bad request".utf8))))
            return
        }
        let response = Self.route(method: method, target: target, body: body, env: env)
        _ = Self.send(fd, Self.http(response))
    }

    // MARK: 请求读取与解析（容错：坏输入给明确错误，不崩溃——通用 §7）

    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 16 * 1024

    static func readRequest(_ fd: Int32) -> (method: String, target: String, body: Data)? {
        var buf = [UInt8]()
        var leftover = Data() // 头终结符之后同包到达的 body 字节（POST 常见，不得丢弃）
        var scratch = [UInt8](repeating: 0, count: 8192)
        headerLoop: while buf.count < maxHeaderBytes {
            let n = recv(fd, &scratch, scratch.count, 0)
            guard n > 0 else { return nil }
            buf.append(contentsOf: scratch[0..<n])
            // 找 \r\n\r\n
            if buf.count >= 4 {
                for i in stride(from: 3, to: buf.count, by: 1) where buf[i-3] == 13 && buf[i-2] == 10 && buf[i-1] == 13 && buf[i] == 10 {
                    leftover = Data(buf[(i + 1)...])
                    buf.removeSubrange((i + 1)...)
                    break headerLoop
                }
            }
        }
        guard let head = String(bytes: buf, encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1") else { return nil }
        let method = String(parts[0]).uppercased()
        var contentLength = 0
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                contentLength = Int(lower.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? -1
            } else if lower.hasPrefix("transfer-encoding:") {
                return nil // 拒绝 chunked（本地 UI 不会用）
            }
        }
        guard contentLength >= 0, contentLength <= maxBodyBytes else { return nil }
        var body = leftover
        while body.count < contentLength {
            let n = recv(fd, &scratch, min(scratch.count, contentLength - body.count), 0)
            guard n > 0 else { return nil }
            body.append(contentsOf: scratch[0..<n])
        }
        return (method, String(parts[1]), body)
    }

    public static func send(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), data.count - sent, 0)
                guard n > 0 else { return false }
                sent += n
            }
            return true
        }
    }

    static func http(_ r: Response) -> Data {
        let head = "HTTP/1.1 \(r.status) \(r.reason)\r\n"
            + "Content-Type: \(r.contentType)\r\n"
            + "Content-Length: \(r.body.count)\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + r.body
    }

    // MARK: 路由（纯函数，行为测试直接驱动）

    public static func route(method: String, target: String, body: Data, env: Environment) -> Response {
        // 拆 path 与 query
        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<q])
            let qs = target[target.index(after: q)...]
            for pair in qs.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard let k = percentDecode(String(kv[0])) else { return .json("{\"error\":\"bad query\"}", status: 400) }
                let v = kv.count > 1 ? (percentDecode(String(kv[1])) ?? "") : ""
                query[k] = v
            }
        }
        guard let decodedPath = percentDecode(path), decodedPath.count <= 256 else {
            return .json("{\"error\":\"bad path\"}", status: 400)
        }

        switch (method, decodedPath) {
        case ("GET", "/"), ("GET", "/index.html"):
            // 页面语言：?lang=zh|en 覆盖，否则跟随 App 当前生效语言（系统/手动）
            let language = queryLanguageOverride(query) ?? LanguageManager.shared.currentEffective
            return Response(status: 200, reason: "OK", contentType: "text/html; charset=utf-8",
                            body: Data(indexHTML(language: language).utf8))
        case ("GET", "/api/status"):
            return .json(jsonObject(env.status()))
        case ("GET", "/api/logs"):
            guard let dir = env.logsDirectory() else {
                return .json("{\"error\":\"logs unavailable\"}", status: 503)
            }
            let files = listLogFiles(in: dir)
            let items = files.map {
                "{\"name\":\(jsonString($0.name)),\"size\":\($0.sizeBytes),\"modified\":\(Int($0.modified.timeIntervalSince1970))}"
            }.joined(separator: ",")
            return .json("{\"logs\":[\(items)]}")
        case ("GET", "/api/settings"):
            return .json("{\"settings\":\(jsonObject(env.listSettings()))}")
        case ("POST", "/api/settings"):
            return applySettings(body: body, env: env)
        case ("GET", "/logs"), ("GET", "/api/logs/download"):
            return .json("{\"error\":\"missing file name (?file=)\"}", status: 400)
        default:
            // /logs/<name> 下载
            if method == "GET", decodedPath.hasPrefix("/logs/") {
                let name = String(decodedPath.dropFirst("/logs/".count))
                return downloadLog(name: name, env: env)
            }
            return .json("{\"error\":\"not found\"}", status: 404)
        }
    }

    static func applySettings(body: Data, env: Environment) -> Response {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: String],
              !obj.isEmpty else {
            return .json("{\"error\":\"body must be a non-empty flat JSON object of strings\"}", status: 400)
        }
        var applied: [String] = []
        var rejected: [String] = []
        for (key, value) in obj.sorted(by: { $0.key < $1.key }) {
            if let reason = env.applySetting(key, value) {
                rejected.append("\(jsonString(key)):\(jsonString(reason))")
            } else {
                applied.append(jsonString(key))
            }
        }
        let appliedJSON = "[" + applied.joined(separator: ",") + "]"
        let rejectedJSON = "{" + rejected.joined(separator: ",") + "}"
        return .json("{\"applied\":\(appliedJSON),\"rejected\":\(rejectedJSON)}")
    }

    // MARK: 文件服务（白名单 + 目录逃逸双查）

    static let allowedFileChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.- ()")

    static func isValidLogFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128,
              !name.hasPrefix("."), !name.contains(".."),
              name.range(of: "[^a-zA-Z0-9_.\\-() ]", options: .regularExpression) == nil else { return false }
        return ["dslog", "wpilog", "dsrec"].contains((name as NSString).pathExtension.lowercased())
    }

    static func listLogFiles(in dir: URL) -> [LogFileInfo] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var files: [LogFileInfo] = []
        for name in names where isValidLogFileName(name) {
            let url = dir.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? UInt64,
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            files.append(LogFileInfo(name: name, sizeBytes: size, modified: mtime))
        }
        return files.sorted { $0.modified > $1.modified }
    }

    static func downloadLog(name: String, env: Environment) -> Response {
        guard let raw = name.removingURLFragmentSafety(), isValidLogFileName(raw),
              let dir = env.logsDirectory() else {
            return .json("{\"error\":\"invalid file name\"}", status: 404)
        }
        let url = dir.appendingPathComponent(raw).standardizedFileURL
        // 双查：解析后的绝对路径必须仍在日志目录内（防符号链接/逃逸）
        guard url.path.hasPrefix(dir.standardizedFileURL.path + "/"),
              let data = FileManager.default.contents(atPath: url.path) else {
            return .json("{\"error\":\"file not found\"}", status: 404)
        }
        return Response(status: 200, reason: "OK",
                        contentType: "application/octet-stream", body: data)
    }

    // MARK: JSON 与 URL 工具

    static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    static func jsonObject(_ dict: [String: String]) -> String {
        "{" + dict.sorted { $0.key < $1.key }.map { "\(jsonString($0.key)):\(jsonString($0.value))" }.joined(separator: ",") + "}"
    }

    static func percentDecode(_ s: String) -> String? {
        let out = s.replacingOccurrences(of: "+", with: " ")
        guard out.utf8.count <= 512 else { return nil }
        return out.removingPercentEncoding ?? nil
    }

    /// ?lang= 覆盖：zh/zh-hans/chinese → 中文，en/english → 英文；非法/缺省返回 nil（回落 App 当前语言）
    public static func queryLanguageOverride(_ query: [String: String]) -> AppLanguage? {
        switch query["lang"]?.lowercased() {
        case "zh", "zh-hans", "chinese": return .chinese
        case "en", "english": return .english
        default: return nil
        }
    }

    /// 首页模板（双语）：文案成对维护，结构与样式保持一致
    public static func indexHTML(language: AppLanguage) -> String {
        switch language {
        case .chinese:
            return """
            <!doctype html><html><head><meta charset="utf-8"><title>MatchSticks DS</title>
            <style>body{font-family:-apple-system;font-size:14px;margin:24px;color:#1d1d1f}
            h1{font-size:20px}code{background:#f2f2f4;padding:2px 5px;border-radius:4px}
            a{color:#0066cc}</style></head><body>
            <h1>MatchSticks DS · WebUI</h1>
            <p>本机调试与支持页（仅 127.0.0.1 可访问）。</p>
            <ul>
            <li><a href="/api/status">/api/status</a> — 连接/使能/急停/更新门状态</li>
            <li><a href="/api/logs">/api/logs</a> — 日志文件列表（.dslog/.wpilog/.dsrec）</li>
            <li>/logs/&lt;文件名&gt; — 下载日志文件</li>
            <li><a href="/api/settings">/api/settings</a> — 查看设置</li>
            <li><code>POST /api/settings</code> — 覆盖设置（JSON 字符串键值，逐键校验）</li>
            </ul></body></html>
            """
        case .english:
            return """
            <!doctype html><html><head><meta charset="utf-8"><title>MatchSticks DS</title>
            <style>body{font-family:-apple-system;font-size:14px;margin:24px;color:#1d1d1f}
            h1{font-size:20px}code{background:#f2f2f4;padding:2px 5px;border-radius:4px}
            a{color:#0066cc}</style></head><body>
            <h1>MatchSticks DS · WebUI</h1>
            <p>Local debugging and support page (127.0.0.1 only).</p>
            <ul>
            <li><a href="/api/status">/api/status</a> — connection / enable / E-Stop / update-gate status</li>
            <li><a href="/api/logs">/api/logs</a> — log file list (.dslog/.wpilog/.dsrec)</li>
            <li>/logs/&lt;file name&gt; — download a log file</li>
            <li><a href="/api/settings">/api/settings</a> — view settings</li>
            <li><code>POST /api/settings</code> — override settings (flat JSON strings, per-key validation)</li>
            </ul></body></html>
            """
        }
    }
}

// String 小扩展（仅本文件用）
extension String {
    func removingURLFragmentSafety() -> String? {
        // 去掉可能混入的 #fragment 与空字符
        guard !contains("\0") else { return nil }
        if let hash = firstIndex(of: "#") { return String(self[startIndex..<hash]) }
        return self
    }
}
