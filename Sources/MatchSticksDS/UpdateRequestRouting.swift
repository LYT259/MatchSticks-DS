import Foundation

struct UpdateRequestCallbacks {
    let response: (HTTPURLResponse) -> Void
    let data: (Data) -> Void
    let completion: (Error?) -> Void
}

protocol UpdateRequestTransport: AnyObject {
    func send(_ request: URLRequest, route: UpdateProbeRoute, callbacks: UpdateRequestCallbacks) -> UpdateRequestHandle
}

final class UpdateRequestHandle {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?
    private(set) var isCancelled = false

    init(_ cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let action = cancellation
        cancellation = nil
        lock.unlock()
        action?()
    }
}

/// Sparkle 2.10 没有公开 URLSession 注入点。进程内 URLProtocol 只识别本次探测签发的随机 token：
/// feed 经公开 feedParameters 获得 query token，enclosure 经 willDownloadUpdate 获得 header token。
/// 机器人、WebUI、Star 以及未标记的同源请求都不会命中；token 与凭证不会发往源站，也不写日志。
final class UpdateRequestRouting {
    static let shared = UpdateRequestRouting()
    static let feedParameter = "matchsticksds_update_request"
    static let downloadHeader = "MatchSticksDS-Update-Request"

    private let lock = NSLock()
    private var storedRoute: UpdateProbeRoute?
    private var storedToken: String?
    private var storedTransport: (any UpdateRequestTransport)?

    var route: UpdateProbeRoute? {
        lock.lock()
        defer { lock.unlock() }
        return storedRoute
    }

    var token: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedToken
    }

    var transport: (any UpdateRequestTransport)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedTransport
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedTransport = newValue
        }
    }

    @discardableResult
    func activate(route: UpdateProbeRoute) -> String {
        let token = UUID().uuidString
        lock.lock()
        defer { lock.unlock() }
        storedRoute = route
        storedToken = token
        return token
    }

    func deactivate() {
        lock.lock()
        defer { lock.unlock() }
        storedRoute = nil
        storedToken = nil
    }

    func feedParameters() -> [[String: String]] {
        guard let token else { return [] }
        return [["key": Self.feedParameter, "value": token, "displayKey": "", "displayValue": ""]]
    }

    func markDownload(_ request: inout URLRequest) {
        guard let token else { return }
        request.setValue(token, forHTTPHeaderField: Self.downloadHeader)
    }

    func markDownload(_ request: NSMutableURLRequest) {
        guard let token else { return }
        request.setValue(token, forHTTPHeaderField: Self.downloadHeader)
    }

    func shouldIntercept(_ request: URLRequest) -> Bool {
        guard route != nil, let token, let url = request.url,
              url.user == nil, url.password == nil,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        if request.value(forHTTPHeaderField: Self.downloadHeader) == token { return true }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { $0.name == Self.feedParameter && $0.value == token }
    }

    func sanitizedRequest(_ request: URLRequest) -> URLRequest {
        var sanitized = request
        sanitized.setValue(nil, forHTTPHeaderField: Self.downloadHeader)
        for header in ["Authorization", "Proxy-Authorization", "Cookie"] {
            sanitized.setValue(nil, forHTTPHeaderField: header)
        }
        if let url = sanitized.url,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = components.queryItems?.filter { $0.name != Self.feedParameter }
            if components.queryItems?.isEmpty == true { components.queryItems = nil }
            sanitized.url = components.url
        }
        return sanitized
    }
}

@objc(UpdateURLProtocol)
final class UpdateURLProtocol: URLProtocol {
    private let stateLock = NSRecursiveLock()
    private var finished = false
    private var handle: UpdateRequestHandle?

    override class func canInit(with request: URLRequest) -> Bool {
        UpdateRequestRouting.shared.shouldIntercept(request)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard UpdateRequestRouting.shared.shouldIntercept(request),
              let route = UpdateRequestRouting.shared.route,
              let transport = UpdateRequestRouting.shared.transport else {
            finish(NSError(domain: "org.ghfrc.driverstation.update.routing", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "Update request is no longer active"]))
            return
        }
        let sanitized = UpdateRequestRouting.shared.sanitizedRequest(request)
        let newHandle = transport.send(sanitized, route: route, callbacks: UpdateRequestCallbacks(
            response: { [weak self] response in self?.receive(response) },
            data: { [weak self] data in self?.receive(data) },
            completion: { [weak self] error in self?.finish(error) }))
        stateLock.lock()
        if finished {
            stateLock.unlock()
            newHandle.cancel()
        } else {
            handle = newHandle
            stateLock.unlock()
        }
    }

    override func stopLoading() {
        stateLock.lock()
        finished = true
        let pending = handle
        handle = nil
        stateLock.unlock()
        pending?.cancel()
    }

    private func receive(_ response: HTTPURLResponse) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !finished else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    private func receive(_ data: Data) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !finished else { return }
        client?.urlProtocol(self, didLoad: data)
    }

    private func finish(_ error: Error?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !finished else { return }
        finished = true
        handle = nil
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

}
