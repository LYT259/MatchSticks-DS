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
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return configuration
    }

    static func responseError(_ response: HTTPURLResponse) -> Error? {
        guard (100...599).contains(response.statusCode) else {
            return transportError("unsupported HTTP status")
        }
        var lengths: [UInt64] = []
        for (key, value) in response.allHeaderFields {
            guard String(describing: key).lowercased() == "content-length" else { continue }
            let texts = String(describing: value).split(separator: ",")
            guard !texts.isEmpty else { return transportError("invalid or conflicting Content-Length") }
            for text in texts {
                guard let length = UInt64(text.trimmingCharacters(in: .whitespaces)) else {
                    return transportError("invalid or conflicting Content-Length")
                }
                lengths.append(length)
            }
        }
        guard Set(lengths).count <= 1, lengths.allSatisfy({ Int(exactly: $0) != nil }) else {
            return transportError("invalid or conflicting Content-Length")
        }
        return nil
    }

    static func transportError(_ detail: String) -> NSError {
        NSError(domain: "org.ghfrc.driverstation.update.transport", code: 1,
                userInfo: [NSLocalizedDescriptionKey: detail])
    }

    func send(_ request: URLRequest, route: UpdateProbeRoute, callbacks: UpdateRequestCallbacks) -> UpdateRequestHandle {
        guard let sanitized = UpdateRequestRouting.sanitizedRequest(request) else {
            callbacks.completion(Self.transportError("invalid update request"))
            return UpdateRequestHandle {}
        }
        switch route {
        case .defaultRoute:
            return DefaultRouteRequest(request: sanitized, configuration: defaultConfiguration, callbacks: callbacks).start()
        case .wiredEthernet:
            return UpdateHTTPConnection(request: sanitized, timeout: wiredTimeout, prohibitedWiFi: true, callbacks: callbacks).start()
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

    private func reject(_ error: Error, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        finish(error)
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !isCancelled else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            reject(SystemUpdateRequestTransport.transportError("invalid update response"), completionHandler: completionHandler)
            return
        }
        if let error = SystemUpdateRequestTransport.responseError(http) {
            reject(error, completionHandler: completionHandler)
            return
        }
        callbacks.response(http)
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
        guard let currentURL = response.url, let proposedURL = request.url,
              let target = UpdateRequestRouting.redirectTarget(proposedURL, from: currentURL),
              var sanitized = UpdateRequestRouting.sanitizedRequest(request) else {
            finish(SystemUpdateRequestTransport.transportError("unsafe update redirect"))
            completionHandler(nil)
            return
        }
        sanitized.url = target
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
        case fixed(Int)
        case chunked
        case untilClose
    }

    private enum ChunkState {
        case size
        case data
        case crlf
        case trailers
    }

    private static let maximumLineLength = 64 * 1024
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
    private var chunkRemaining = 0

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
        guard let validatedURL = UpdateRequestRouting.validatedRequestURL(currentURL),
              let components = URLComponents(url: validatedURL, resolvingAgainstBaseURL: false),
              let host = components.host?.trimmingCharacters(in: .whitespaces), !host.isEmpty,
              let port = port(for: validatedURL), method == "GET" || method == "HEAD" else {
            fail("invalid update request")
            return
        }
        currentURL = validatedURL
        let parameters: NWParameters
        if components.scheme?.lowercased() == "https" {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        if prohibitedWiFi { parameters.prohibitedInterfaceTypes = [.wifi] }

        let hostHeader = (host.contains(":") ? "[\(host)]" : host) + (components.port.map { ":\($0)" } ?? "")
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { target += "?\(query)" }
        var lines = ["\(method) \(target) HTTP/1.1", "Host: \(hostHeader)", "Accept: */*", "Connection: close"]
        for (field, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = field.lowercased()
            if ["host", "connection", "accept-encoding", "content-length", "authorization", "proxy-authorization", "cookie",
                UpdateRequestRouting.downloadHeader.lowercased()].contains(lower) { continue }
            lines.append("\(field): \(value)")
        }
        if request.value(forHTTPHeaderField: "Accept") != nil {
            lines.removeAll { $0.hasPrefix("Accept: */*") }
        }
        lines.append("Accept-Encoding: identity")
        let requestData = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            self?.stateChanged(state, requestData: requestData, connection: connection)
        }
        armTimeout()
        connection.start(queue: queue)
    }

    private func port(for url: URL) -> NWEndpoint.Port? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let number: Int
        if let explicit = components.port {
            guard (1...65_535).contains(explicit) else { return nil }
            number = explicit
        } else if components.scheme?.lowercased() == "https" {
            number = 443
        } else if components.scheme?.lowercased() == "http" {
            number = 80
        } else {
            return nil
        }
        return NWEndpoint.Port(rawValue: UInt16(number))
    }

    private func stateChanged(_ state: NWConnection.State, requestData: Data, connection: NWConnection) {
        guard !finished, self.connection === connection else { return }
        switch state {
        case .ready:
            connection.send(content: requestData, completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection, !self.finished, self.connection === connection else { return }
                if let error {
                    self.fail(error.localizedDescription)
                } else {
                    self.receive(on: connection)
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

    private func receive(on connection: NWConnection) {
        guard !finished, self.connection === connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, !self.finished, self.connection === connection else { return }
            self.timeoutItem?.cancel()
            if let error {
                self.fail(error.localizedDescription)
                return
            }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.process()
            }
            guard !self.finished, self.connection === connection else { return }
            if isComplete {
                self.endOfStream()
            } else {
                self.armTimeout()
                self.receive(on: connection)
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
            if buffer.count > Self.maximumLineLength { throw HTTPError("oversized update response headers") }
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
        var contentLengths: [UInt64] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let field = String(line[..<colon])
            if field.isEmpty { throw HTTPError("invalid HTTP header") }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if field.lowercased() == "set-cookie" { continue }
            if field.lowercased() == "content-length" {
                let texts = value.split(separator: ",")
                guard !texts.isEmpty else { throw HTTPError("invalid Content-Length") }
                for text in texts {
                    guard let length = UInt64(text.trimmingCharacters(in: .whitespaces)) else {
                        throw HTTPError("invalid Content-Length")
                    }
                    contentLengths.append(length)
                }
            }
            headers[field] = value
        }
        guard Set(contentLengths).count <= 1 else { throw HTTPError("conflicting Content-Length") }
        if (100...199).contains(statusCode), statusCode != 101 {
            informationalResponses += 1
            guard informationalResponses <= 8 else { throw HTTPError("too many informational responses") }
            return
        }
        if [301, 302, 303, 307, 308].contains(statusCode) {
            guard let location = headers.first(where: { $0.key.lowercased() == "location" })?.value,
                  let url = URL(string: location, relativeTo: currentURL)?.absoluteURL,
                  let target = UpdateRequestRouting.redirectTarget(url, from: currentURL) else {
                throw HTTPError("unsafe or missing update redirect")
            }
            redirects += 1
            guard redirects <= 5 else { throw HTTPError("too many update redirects") }
            currentURL = target
            if statusCode == 303 { method = "GET" }
            buffer.removeAll()
            bodyMode = .none
            chunkState = .size
            chunkRemaining = 0
            responseSent = false
            timeoutItem?.cancel()
            if let connection {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
            connection = nil
            startConnection()
            return
        }
        guard (200...599).contains(statusCode) else { throw HTTPError("unsupported HTTP status") }
        guard let response = HTTPURLResponse(url: currentURL, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers) else {
            throw HTTPError("invalid HTTP response")
        }
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
        } else if let length = contentLengths.first {
            guard let exactLength = Int(exactly: length) else { throw HTTPError("invalid Content-Length") }
            bodyMode = .fixed(exactLength)
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
                let count = min(remaining, buffer.count)
                emit(buffer.prefix(count))
                buffer.removeFirst(count)
                remaining -= count
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
                guard let line = try removeLine(oversizedDetail: "oversized chunk size line") else { return }
                let hex = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
                guard let length = UInt64(hex.trimmingCharacters(in: .whitespaces), radix: 16),
                      let exactLength = Int(exactly: length) else {
                    throw HTTPError("invalid chunk size")
                }
                if exactLength == 0 {
                    chunkState = .trailers
                } else {
                    chunkRemaining = exactLength
                    chunkState = .data
                }
            case .data:
                guard !buffer.isEmpty else { return }
                let count = min(chunkRemaining, buffer.count)
                emit(buffer.prefix(count))
                buffer.removeFirst(count)
                chunkRemaining -= count
                if chunkRemaining == 0 { chunkState = .crlf }
            case .crlf:
                guard buffer.count >= 2 else { return }
                guard buffer.starts(with: [13, 10]) else { throw HTTPError("invalid chunk terminator") }
                buffer.removeFirst(2)
                chunkState = .size
            case .trailers:
                guard let line = try removeLine(oversizedDetail: "oversized chunk trailers") else { return }
                if line.isEmpty {
                    finish(nil)
                    return
                }
            }
        }
    }

    private func removeLine(oversizedDetail: String) throws -> String? {
        guard let range = buffer.range(of: Data("\r\n".utf8)) else {
            if buffer.count >= Self.maximumLineLength { throw HTTPError("\(oversizedDetail) at \(chunkState) with \(buffer.count) bytes") }
            return nil
        }
        if buffer.distance(from: buffer.startIndex, to: range.lowerBound) > Self.maximumLineLength {
            throw HTTPError(oversizedDetail)
        }
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
        finish(SystemUpdateRequestTransport.transportError(detail))
    }

    private struct HTTPError: LocalizedError {
        let description: String
        init(_ description: String) { self.description = description }
        var errorDescription: String? { description }
    }
}
