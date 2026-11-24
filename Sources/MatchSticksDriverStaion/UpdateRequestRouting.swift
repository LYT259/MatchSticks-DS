import Foundation
import ObjectiveC

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
/// 机器人、WebUI、Star 以及未标记的同源请求都不会命中；token 与凭证不会发往源站，应用自身不记录它们。
final class UpdateRequestRouting {
    static let shared = UpdateRequestRouting()
    static let feedParameter = "matchsticksds_update_request"
    static let downloadHeader = "MatchSticksDS-Update-Request"
    static let errorDomain = "org.ghfrc.driverstation.update.routing"
    private static let sensitiveHeaders = ["Authorization", "Proxy-Authorization", "Cookie", downloadHeader]
    private static let installLock = NSLock()
    private static var sparkSessionRoutingInstalled = false

    private let lock = NSLock()
    private var storedRoute: UpdateProbeRoute?
    private var storedToken: String?
    private var storedTransport: (any UpdateRequestTransport)?
    private var storedInterceptionObserver: (() -> Void)?

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

    var interceptionObserver: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedInterceptionObserver
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedInterceptionObserver = newValue
        }
    }

    /// URLProtocol.registerClass 只覆盖 shared session；Sparkle 通过 defaultSessionConfiguration
    /// 创建独立 session，因此还需在该公开工厂上幂等地补充同一 adapter。未标记请求仍由 canInit 放行。
    static func installSparkleSessionRouting() {
        installLock.lock()
        defer { installLock.unlock() }
        guard !sparkSessionRoutingInstalled else { return }
        let selector = NSSelectorFromString("defaultSessionConfiguration")
        guard let method = class_getClassMethod(URLSessionConfiguration.self, selector) else { return }
        let originalIMP = method_getImplementation(method)
        typealias ConfigurationFactory = @convention(c) (AnyObject, Selector) -> URLSessionConfiguration
        let factory: @convention(block) (AnyObject) -> URLSessionConfiguration = { object in
            let configuration = unsafeBitCast(originalIMP, to: ConfigurationFactory.self)(object, selector)
            let alreadyInstalled = configuration.protocolClasses?.contains { $0 === UpdateURLProtocol.self } == true
            if !alreadyInstalled {
                configuration.protocolClasses = [UpdateURLProtocol.self] + (configuration.protocolClasses ?? [])
            }
            return configuration
        }
        method_setImplementation(method, imp_implementationWithBlock(factory))
        sparkSessionRoutingInstalled = true
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
        guard route != nil, let token, let url = request.url else { return false }
        if request.value(forHTTPHeaderField: Self.downloadHeader) == token { return true }
        guard let rawQuery = url.query else { return false }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.percentEncodedQuery else {
            return rawQuery.contains("\(Self.feedParameter)=")
        }
        return Self.containsFeedToken(in: query, token: token)
    }

    static func sanitizedRequest(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url, let sanitizedURL = sanitizedURL(url) else { return nil }
        var sanitized = request
        sanitized.url = sanitizedURL
        for header in sensitiveHeaders {
            sanitized.setValue(nil, forHTTPHeaderField: header)
        }
        return sanitized
    }

    func sanitizedRequest(_ request: URLRequest) -> URLRequest? {
        Self.sanitizedRequest(request)
    }

    static func sanitizedURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.url != nil else { return nil }
        if let query = components.percentEncodedQuery {
            components.percentEncodedQuery = removingFeedToken(from: query)
        }
        guard let sanitized = components.url else { return nil }
        return validatedRequestURL(sanitized)
    }

    static func redirectTarget(_ url: URL, from currentURL: URL) -> URL? {
        guard let sanitized = sanitizedURL(url),
              let currentComponents = URLComponents(url: currentURL, resolvingAgainstBaseURL: false),
              let nextComponents = URLComponents(url: sanitized, resolvingAgainstBaseURL: false) else { return nil }
        if currentComponents.scheme?.lowercased() == "https" && nextComponents.scheme?.lowercased() != "https" {
            return nil
        }
        return sanitized
    }

    static func validatedRequestURL(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let normalized = components.url,
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host?.trimmingCharacters(in: .whitespaces), !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        if let port = components.port, !(1...65_535).contains(port) { return nil }
        return normalized
    }

    private static func feedTokenValue(in item: String) -> String? {
        let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, String(parts[0]).removingPercentEncoding == feedParameter else { return nil }
        return String(parts[1]).removingPercentEncoding
    }

    private static func containsFeedToken(in query: String, token: String) -> Bool {
        query.split(separator: "&", omittingEmptySubsequences: false)
            .contains { feedTokenValue(in: String($0)) == token }
    }

    private static func removingFeedToken(from query: String) -> String? {
        let items = query.split(separator: "&", omittingEmptySubsequences: false)
            .filter { feedTokenValue(in: String($0)) == nil }
        return items.isEmpty ? nil : items.joined(separator: "&")
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
            finish(routingError("Update request is no longer active"))
            return
        }
        guard let sanitized = UpdateRequestRouting.shared.sanitizedRequest(request) else {
            finish(routingError("Invalid update request URL"))
            return
        }
        UpdateRequestRouting.shared.interceptionObserver?()
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

    private func routingError(_ detail: String) -> NSError {
        NSError(domain: UpdateRequestRouting.errorDomain, code: 1,
                userInfo: [NSLocalizedDescriptionKey: detail])
    }
}
