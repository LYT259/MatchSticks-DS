import Foundation
import Network
import Security

final class SystemUpdateRequestTransport: UpdateRequestTransport {
    private let defaultConfiguration: URLSessionConfiguration
    private let wiredTimeout: TimeInterval

    init(wiredTimeout: TimeInterval = 60,
         configuration: URLSessionConfiguration = SystemUpdateRequestTransport.makeConfiguration()) {
        self.wiredTimeout = wiredTimeout
        self.defaultConfiguration = configuration
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = []
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return configuration
    }

    func send(_ request: URLRequest, route: UpdateProbeRoute, callbacks: UpdateRequestCallbacks) -> UpdateRequestHandle {
        switch route {
        case .defaultRoute:
            return DefaultRouteRequest(request: request, configuration: defaultConfiguration, callbacks: callbacks).start()
        case .wiredEthernet:
            return UpdateHTTPConnection(request: request, timeout: wiredTimeout, prohibitedWiFi: true, callbacks: callbacks).start()
        }
    }
}

private final class DefaultRouteRequest: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var finished = false
    private let callbacks: UpdateRequestCallbacks

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    init(request: URLRequest, configuration: URLSessionConfiguration, callbacks: UpdateRequestCallbacks) {
        self.callbacks = callbacks
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session?.dataTask(with: request)
    }

    func start() -> UpdateRequestHandle {
        task?.resume()
        return UpdateRequestHandle { [self] in cancel() }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let active = !finished
        finished = true
        let pendingTask = task
        let pendingSession = session
        task = nil
        session = nil
        lock.unlock()
        if active {
            pendingTask?.cancel()
            pendingSession?.finishTasksAndInvalidate()
        }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let pendingSession = session
        session = nil
        task = nil
        lock.unlock()
        callbacks.completion(error)
        pendingSession?.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !isCancelled else {
            completionHandler(.cancel)
            return
        }
        if let http = response as? HTTPURLResponse { callbacks.response(http) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isCancelled else { return }
        callbacks.data(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isCancelled else { return }
        finish(error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard !isCancelled else {
            completionHandler(nil)
            return
        }
        var sanitized = request
        for header in ["Authorization", "Proxy-Authorization", "Cookie", UpdateRequestRouting.downloadHeader] {
            sanitized.setValue(nil, forHTTPHeaderField: header)
        }
        completionHandler(sanitized)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }
}

/// 非 Wi‑Fi 路径上的 HTTP/1.1 客户端。重定向在连接内部完成，确保后续请求仍走同一 NWConnection
/// 路由；固定长度、chunked 与 close-delimited body 均按块回调，不把 enclosure 全量放进内存。
private final class UpdateHTTPConnection {
    private enum BodyMode {
        case none
        case fixed(UInt64)
        case chunked
        case untilClose
    }

    private enum ChunkState {
        case size
        case data
        case crlf
        case trailers
    }

    private let queue = DispatchQueue(label: "matchsticks.ds.updatehttp", qos: .utility)
    private let request: URLRequest
    private let timeout: TimeInterval
    private let prohibitedWiFi: Bool
    private let callbacks: UpdateRequestCallbacks
    private var connection: NWConnection?
    private var timeoutItem: DispatchWorkItem?
    private var selfRetainer: UpdateHTTPConnection?
    private var finished = false
    private var buffer = Data()
    private var currentURL: URL
    private var method: String
    private var redirects = 0
    private var informationalResponses = 0
    private var responseSent = false
    private var bodyMode: BodyMode = .none
    private var chunkState = ChunkState.size
    private var chunkRemaining: UInt64 = 0

    init(request: URLRequest, timeout: TimeInterval, prohibitedWiFi: Bool, callbacks: UpdateRequestCallbacks) {
        self.request = request
        self.timeout = timeout
        self.prohibitedWiFi = prohibitedWiFi
        self.callbacks = callbacks
        currentURL = request.url ?? URL(fileURLWithPath: "/")
        method = request.httpMethod ?? "GET"
    }

    func start() -> UpdateRequestHandle {
        selfRetainer = self
        queue.async { [self] in self.startConnection() }
        return UpdateRequestHandle { [weak self] in
            guard let self else { return }
            self.queue.async { self.cancel() }
        }
    }

    private func startConnection() {
        guard !finished else { return }
        guard let host = currentURL.host?.trimmingCharacters(in: .whitespaces), !host.isEmpty,
              let port = port(for: currentURL), method == "GET" || method == "HEAD" else {
            fail("invalid update request")
            return
        }
        let parameters: NWParameters
        if currentURL.scheme?.lowercased() == "https" {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        if prohibitedWiFi { parameters.prohibitedInterfaceTypes = [.wifi] }

        let hostHeader = (host.contains(":") ? "[\(host)]" : host) + (currentURL.port.map { ":\($0)" } ?? "")
        var target = currentURL.path.isEmpty ? "/" : currentURL.path
        if let query = currentURL.query { target += "?\(query)" }
        var lines = ["\(method) \(target) HTTP/1.1", "Host: \(hostHeader)", "Accept: */*", "Connection: close"]
        for (field, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = field.lowercased()
            if ["host", "connection", "accept-encoding", "content-length", "authorization", "proxy-authorization", "cookie"].contains(lower) { continue }
            lines.append("\(field): \(value)")
        }
        if request.value(forHTTPHeaderField: "Accept") != nil {
            lines.removeAll { $0.hasPrefix("Accept: */*") }
        }
        lines.append("Accept-Encoding: identity")
        let requestData = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state, requestData: requestData) }
        armTimeout()
        connection.start(queue: queue)
    }

    private func port(for url: URL) -> NWEndpoint.Port? {
        if let explicit = url.port { return NWEndpoint.Port(rawValue: UInt16(clamping: explicit)) }
        return url.scheme?.lowercased() == "https" ? 443 : 80
    }

    private func stateChanged(_ state: NWConnection.State, requestData: Data) {
        switch state {
        case .ready:
            connection?.send(content: requestData, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.fail(error.localizedDescription)
                } else {
                    self.receive()
                }
            })
        case .waiting(let error):
            fail("no non-Wi-Fi path (\(error.localizedDescription))")
        case .failed(let error):
            fail(error.localizedDescription)
        case .setup, .preparing, .cancelled:
            break
        @unknown default:
            break
        }
    }

    private func armTimeout() {
        timeoutItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fail("update request timed out") }
        timeoutItem = item
        queue.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    private func receive() {
        guard !finished else { return }
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.timeoutItem?.cancel()
            if let error {
                self.fail(error.localizedDescription)
                return
            }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.process()
            }
            guard !self.finished else { return }
            if isComplete {
                self.endOfStream()
            } else {
                self.armTimeout()
                self.receive()
            }
        }
    }

    private func process() {
        do {
            if !responseSent {
                try processHeaders()
                guard !finished else { return }
            }
            try processBody()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func processHeaders() throws {
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 65_536 { throw HTTPError("oversized update response headers") }
            return
        }
        let headerData = buffer[..<range.lowerBound]
        buffer.removeSubrange(..<range.upperBound)
        let lines = String(decoding: headerData, as: UTF8.self).components(separatedBy: "\r\n")
        let statusLine = lines[0].components(separatedBy: " ")
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/"), let statusCode = Int(statusLine[1]) else {
            throw HTTPError("invalid HTTP status line")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let field = String(line[..<colon])
            if field.lowercased() == "set-cookie" { continue }
            headers[field] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if (100..<200).contains(statusCode), statusCode != 101 {
            informationalResponses += 1
            guard informationalResponses <= 8 else { throw HTTPError("too many informational responses") }
            return
        }
        if [301, 302, 303, 307, 308].contains(statusCode) {
            guard let location = headers.first(where: { $0.key.lowercased() == "location" })?.value,
                  let url = URL(string: location, relativeTo: currentURL)?.absoluteURL else {
                throw HTTPError("redirect without a valid Location")
            }
            redirects += 1
            guard redirects <= 5 else { throw HTTPError("too many update redirects") }
            currentURL = url
            if statusCode == 303 { method = "GET" }
            buffer.removeAll()
            timeoutItem?.cancel()
            if let connection {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
            startConnection()
            return
        }
        guard statusCode >= 200 else { throw HTTPError("unsupported HTTP status") }
        let response = HTTPURLResponse(url: currentURL, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
        responseSent = true
        callbacks.response(response)
        if method == "HEAD" || statusCode == 204 || statusCode == 304 {
            bodyMode = .none
            finish(nil)
            return
        }
        let transferEncoding = headers.first { $0.key.lowercased() == "transfer-encoding" }?.value.lowercased() ?? ""
        if transferEncoding.contains("chunked") {
            bodyMode = .chunked
        } else if let lengthText = headers.first(where: { $0.key.lowercased() == "content-length" })?.value {
            guard let length = UInt64(lengthText.trimmingCharacters(in: .whitespaces)) else {
                throw HTTPError("invalid Content-Length")
            }
            bodyMode = .fixed(length)
        } else {
            bodyMode = .untilClose
        }
    }

    private func processBody() throws {
        switch bodyMode {
        case .none:
            return
        case .fixed(let length):
            var remaining = length
            while !buffer.isEmpty && remaining > 0 && !finished {
                let count = min(Int(remaining), buffer.count)
                emit(buffer.prefix(count))
                buffer.removeFirst(count)
                remaining -= UInt64(count)
            }
            bodyMode = .fixed(remaining)
            if remaining == 0 { finish(nil) }
        case .untilClose:
            if !buffer.isEmpty {
                emit(buffer)
                buffer.removeAll()
            }
        case .chunked:
            try processChunked()
        }
    }

    private func processChunked() throws {
        while !finished {
            switch chunkState {
            case .size:
                guard let line = removeLine() else { return }
                let hex = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
                guard let length = UInt64(hex.trimmingCharacters(in: .whitespaces), radix: 16) else {
                    throw HTTPError("invalid chunk size")
                }
                if length == 0 {
                    chunkState = .trailers
                } else {
                    chunkRemaining = length
                    chunkState = .data
                }
            case .data:
                guard !buffer.isEmpty else { return }
                let count = min(Int(chunkRemaining), buffer.count)
                emit(buffer.prefix(count))
                buffer.removeFirst(count)
                chunkRemaining -= UInt64(count)
                if chunkRemaining == 0 { chunkState = .crlf }
            case .crlf:
                guard buffer.count >= 2 else { return }
                guard buffer.starts(with: [13, 10]) else { throw HTTPError("invalid chunk terminator") }
                buffer.removeFirst(2)
                chunkState = .size
            case .trailers:
                guard let line = removeLine() else { return }
                if line.isEmpty {
                    finish(nil)
                    return
                }
            }
        }
    }

    private func removeLine() -> String? {
        guard let range = buffer.range(of: Data("\r\n".utf8)) else { return nil }
        let line = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
        buffer.removeSubrange(..<range.upperBound)
        return line
    }

    private func endOfStream() {
        if responseSent, case .untilClose = bodyMode {
            finish(nil)
        } else {
            fail("connection closed before the update response completed")
        }
    }

    private func emit(_ data: Data) {
        callbacks.data(Data(data))
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        timeoutItem?.cancel()
        timeoutItem = nil
        if let connection {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connection = nil
        selfRetainer = nil
        callbacks.completion(error)
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        timeoutItem?.cancel()
        timeoutItem = nil
        if let connection {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connection = nil
        selfRetainer = nil
    }

    private func fail(_ detail: String) {
        finish(NSError(domain: "org.ghfrc.driverstation.update.transport", code: 1,
                       userInfo: [NSLocalizedDescriptionKey: detail]))
    }

    private struct HTTPError: Error {
        let description: String
        init(_ description: String) { self.description = description }
        var localizedDescription: String { description }
    }
}
