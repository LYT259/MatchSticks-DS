import Foundation

// MARK: Sparkle feed / enclosure 请求路径行为测试
//
// URLSession 是真实的；仅在线路边界注入脚本化 transport，证明 feed 与 enclosure 都经过探测选出的
// 同一 route。重定向 / chunked / 流式 / 断线由回环 HTTP 服务覆盖。真实 Sparkle 升级仍由
// scripts/test-update.sh 五腿 E2E 验证，本文件不启动 App 或模拟器。

@MainActor
func updateRequestRoutingTests(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void) {
    let routing = UpdateRequestRouting.shared
    defer {
        routing.deactivate()
        routing.transport = nil
    }

    // ===== A. 默认探测成功：feed 与 enclosure 都只走 default，不产生第二次 Ethernet 请求 =====
    do {
        let transport = ScriptedRequestTransport()
        routing.transport = transport
        let token = routing.activate(route: .defaultRoute)
        check(!token.isEmpty && routing.route == .defaultRoute, "activation exposes the default route and a private request token")
        let parameters = routing.feedParameters()
        check(parameters == [["key": UpdateRequestRouting.feedParameter, "value": token,
                              "displayKey": "", "displayValue": ""]],
              "Sparkle's public feedParameters hook carries the same private token")

        var feed = URLRequest(url: URL(string: "https://example.com/appcast.xml")!)
        feed.url = markedURL(feed.url!, token: token)
        var enclosure = URLRequest(url: URL(string: "https://example.com/update.dmg")!)
        routing.markDownload(&enclosure)
        check(routing.shouldIntercept(feed) && routing.shouldIntercept(enclosure),
              "marked Sparkle feed and enclosure requests are update requests")

        let session = URLSession(configuration: updateProtocolConfiguration())
        defer { session.finishTasksAndInvalidate() }
        let feedResult = perform(feed, session: session)
        let enclosureResult = perform(enclosure, session: session)
        check(feedResult.error.value == nil && enclosureResult.error.value == nil,
              "default-route feed and enclosure both complete through the URLProtocol")
        check(transport.calls.value.map(\.route) == [.defaultRoute, .defaultRoute],
              "feed and enclosure use the successful default route exactly once each")
        check(transport.calls.value.map(\.request.url) == [feed.url, enclosure.url].map { stripMarker(from: $0!) },
              "the private query token is removed before reaching the origin")
        check(transport.calls.value.allSatisfy { $0.request.value(forHTTPHeaderField: UpdateRequestRouting.downloadHeader) == nil },
              "the private enclosure header is removed before reaching the origin")
    }

    // ===== B. 默认失败、Ethernet 探测成功：真实 feed + download 请求都使用 wiredEthernet =====
    do {
        let transport = ScriptedRequestTransport()
        routing.transport = transport
        let feedURL = URL(string: "https://example.com/appcast.xml")!
        let probe = ScriptedProbeTransport()
        let reachability = UpdateReachability(probeURL: feedURL, transport: probe, monitorsPath: false)
        probe.responder = { route, _ in
            route == .defaultRoute
                ? UpdateProbeResult(reachable: false, route: route, detail: "gateway has no Internet")
                : UpdateProbeResult(reachable: true, route: route, detail: "HTTP 200")
        }
        let scheduler = UpdateCheckScheduler()
        _ = scheduler.requestCheck()
        reachability.onResult = { result in
            _ = result.reachable ? scheduler.probeSucceeded(route: result.route) : scheduler.probeFailed()
            if result.reachable { routing.activate(route: result.route) }
        }
        reachability.probe()
        waitUntil("probe selects Ethernet") { scheduler.state == .checking(triggerPending: true) }
        check(scheduler.updateRoute == .wiredEthernet && routing.route == .wiredEthernet,
              "the scheduler and request adapter retain Ethernet as the successful probe route")
        check(probe.calls.map(\.route) == [.defaultRoute, .wiredEthernet],
              "the routing composition still probes default once before Ethernet")

        let token = routing.token!
        let feed = URLRequest(url: markedURL(feedURL, token: token))
        var enclosure = URLRequest(url: URL(string: "https://example.com/update.dmg")!)
        routing.markDownload(&enclosure)
        let session = URLSession(configuration: updateProtocolConfiguration())
        defer { session.finishTasksAndInvalidate() }
        _ = perform(feed, session: session)
        _ = perform(enclosure, session: session)
        check(transport.calls.value.map(\.route) == [.wiredEthernet, .wiredEthernet],
              "after default failure both real URLSession feed and download requests use Ethernet")
    }

    // ===== C. 非更新流量不拦截：无 token 的同源、机器人、WebUI、Star 请求交给后续 protocol =====
    do {
        let transport = ScriptedRequestTransport()
        routing.transport = transport
        let token = routing.activate(route: .wiredEthernet)
        SentinelURLProtocol.count.value = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateURLProtocol.self, SentinelURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let urls = [
            "http://192.0.2.2/ds-udp-endpoint",
            "http://127.0.0.1:6768/webui",
            "http://127.0.0.1/star",
            "https://example.com/appcast.xml",
            "https://example.com/update.dmg",
        ]
        for string in urls {
            let result = perform(URLRequest(url: URL(string: string)!), session: session)
            check(result.error.value == nil && result.data.value == Data("sentinel".utf8),
                  "non-update request \(string) bypasses the update transport")
        }
        check(transport.calls.value.isEmpty, "unmarked requests never create an update transport request")
        check(SentinelURLProtocol.count.value == urls.count, "all unmarked requests reach the next URLProtocol")
        var credentials = URLRequest(url: markedURL(URL(string: "https://user:secret@example.com/appcast.xml")!, token: token))
        routing.markDownload(&credentials)
        check(routing.shouldIntercept(credentials), "marked requests with URL-embedded credentials are contained instead of escaping to another protocol")
        credentials.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        credentials.setValue("session=secret", forHTTPHeaderField: "Cookie")
        let sentinelBeforeInvalid = SentinelURLProtocol.count.value
        let invalidCredentialResult = perform(credentials, session: session)
        check(invalidCredentialResult.error.value != nil && SentinelURLProtocol.count.value == sentinelBeforeInvalid,
              "URL-embedded credentials fail closed without reaching a fallback protocol or the origin")
        let sanitized = routing.sanitizedRequest(credentials)
        check(sanitized == nil,
              "URL-embedded credentials cannot produce a forwardable sanitized request")

        var nonHTTP = URLRequest(url: URL(string: "ftp://user:secret@example.com/appcast.xml?matchsticksds_update_request=\(token)")!)
        nonHTTP.setValue(token, forHTTPHeaderField: UpdateRequestRouting.downloadHeader)
        check(routing.shouldIntercept(nonHTTP), "marked non-HTTP requests are contained instead of escaping to another protocol")
        let invalidSchemeResult = perform(nonHTTP, session: session)
        check(invalidSchemeResult.error.value != nil && SentinelURLProtocol.count.value == sentinelBeforeInvalid,
              "non-HTTP update requests fail closed without reaching a fallback protocol or the origin")

        let escaped = URL(string: "https://example.com/escaped/a%2Fb?keep=%2F%3F%26%3D%23%25%20%2B&flag&empty=&matchsticksds_update_request=\(token)")!
        let escapedResult = routing.sanitizedRequest(URLRequest(url: escaped))
        let escapedComponents = escapedResult?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        check(escapedComponents?.percentEncodedPath == "/escaped/a%2Fb" &&
              escapedComponents?.percentEncodedQuery == "keep=%2F%3F%26%3D%23%25%20%2B&flag&empty=",
              "request sanitization preserves percent-encoded path and query bytes (actual: \(escapedComponents?.percentEncodedQuery ?? "nil"))")

        check(SystemUpdateRequestTransport.makeConfiguration().urlCredentialStorage == nil,
              "the production default-route configuration disables implicit URL credentials")

        let secureOrigin = URL(string: "https://example.com/appcast.xml")!
        check(UpdateRequestRouting.redirectTarget(URL(string: "http://example.com/appcast.xml")!, from: secureOrigin) == nil &&
              UpdateRequestRouting.redirectTarget(URL(string: "https://example.com/appcast.xml")!, from: secureOrigin) != nil &&
              UpdateRequestRouting.redirectTarget(URL(string: "ftp://example.com/appcast.xml")!, from: URL(string: "http://example.com/appcast.xml")!) == nil &&
              UpdateRequestRouting.redirectTarget(URL(string: "https://user:secret@example.com/appcast.xml")!, from: secureOrigin) == nil,
              "redirect policy rejects HTTPS downgrade, non-HTTP schemes and URL credentials")
        let redirectURL = UpdateRequestRouting.redirectTarget(
            URL(string: "https://example.com/appcast.xml?keep=%2F&matchsticksds_update_request=secret")!, from: secureOrigin)
        check(redirectURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.percentEncodedQuery == "keep=%2F",
              "redirect sanitization removes private markers without decoding the remaining query")
        var urlLess = URLRequest(url: secureOrigin)
        urlLess.url = nil
        check(UpdateRequestRouting.sanitizedRequest(URLRequest(url: URL(fileURLWithPath: "/tmp/appcast.xml"))) == nil &&
              UpdateRequestRouting.sanitizedRequest(urlLess) == nil &&
              UpdateRequestRouting.sanitizedRequest(URLRequest(url: secureOrigin)) != nil,
              "non-HTTP and URL-less requests fail closed while valid HTTP(S) requests are sanitized")

        let conflictingResponse = HTTPURLResponse(url: secureOrigin, statusCode: 200, httpVersion: "HTTP/1.1",
                                                  headerFields: ["Content-Length": "1, 2"])!
        let identicalResponse = HTTPURLResponse(url: secureOrigin, statusCode: 200, httpVersion: "HTTP/1.1",
                                                headerFields: ["Content-Length": "1, 1"])!
        let hugeResponse = HTTPURLResponse(url: secureOrigin, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": String(UInt64.max)])!
        check(SystemUpdateRequestTransport.responseError(conflictingResponse)?.localizedDescription.contains("conflicting Content-Length") == true &&
              SystemUpdateRequestTransport.responseError(identicalResponse) == nil &&
              SystemUpdateRequestTransport.responseError(hugeResponse) != nil,
              "default responses reject conflicting or unrepresentable Content-Length but allow identical duplicates (conflict: \(String(describing: SystemUpdateRequestTransport.responseError(conflictingResponse))), identical: \(String(describing: SystemUpdateRequestTransport.responseError(identicalResponse))), huge: \(String(describing: SystemUpdateRequestTransport.responseError(hugeResponse))), headers: \(conflictingResponse.allHeaderFields))")
        _ = routing.activate(route: .defaultRoute)
    }

    // ===== C2. 全局 registerClass：未显式配置 protocolClasses 的 session 也命中生产 URLProtocol =====
    do {
        let transport = ScriptedRequestTransport()
        routing.transport = transport
        let token = routing.activate(route: .defaultRoute)
        UpdateRequestRouting.installSparkleSessionRouting()
        URLProtocol.registerClass(UpdateURLProtocol.self)
        let interceptions = Locked(0)
        routing.interceptionObserver = { interceptions.value += 1 }
        defer {
            routing.interceptionObserver = nil
            URLProtocol.unregisterClass(UpdateURLProtocol.self)
        }
        let session = URLSession(configuration: .default)
        defer { session.finishTasksAndInvalidate() }
        check(session.configuration.protocolClasses?.contains { $0 === UpdateURLProtocol.self } == true,
              "Sparkle-style default-configuration sessions receive the production adapter")
        let result = perform(URLRequest(url: markedURL(URL(string: "https://example.com/appcast.xml")!, token: token)), session: session)
        check(result.error.value == nil && transport.calls.value.count == 1 && interceptions.value == 1,
              "global registration plus Sparkle-style configuration injection intercepts a default-configuration session (error: \(String(describing: result.error.value)))")
        check(transport.calls.value.first?.request.url.map(stripMarker(from:)) == URL(string: "https://example.com/appcast.xml"),
              "the globally registered production adapter strips the query token before transport")
    }

    // ===== D. 失败 / 取消 / 重复回调：URLProtocol 有界收尾，路径失败交给上层退避 =====
    do {
        let transport = ScriptedRequestTransport()
        routing.transport = transport
        _ = routing.activate(route: .wiredEthernet)
        let failure = NSError(domain: "test.update.offline", code: 42, userInfo: [NSLocalizedDescriptionKey: "path lost"])
        transport.handler = { [weak transport] _, _, callbacks, _ in
            DispatchQueue.global().async {
                transport?.completions.value += 1
                callbacks.completion(failure)
                transport?.completions.value += 1
                callbacks.completion(failure)
            }
        }
        let session = URLSession(configuration: updateProtocolConfiguration())
        defer { session.finishTasksAndInvalidate() }
        let failed = perform(URLRequest(url: markedURL(URL(string: "https://example.com/appcast.xml")!, token: routing.token!)),
                             session: session)
        check((failed.error.value as NSError?)?.domain == "test.update.offline" &&
              (failed.error.value as NSError?)?.code == 42,
              "a transport path failure reaches Sparkle's URLSession error path")
        check(transport.completions.value == 2, "the scripted transport is allowed to misbehave for duplicate guarding")

        transport.handler = { _, _, callbacks, handle in
            _ = callbacks
            _ = handle
        }
        let pending = URLSession(configuration: updateProtocolConfiguration())
        defer { pending.finishTasksAndInvalidate() }
        let started = Locked(false)
        let task = pending.dataTask(with: URLRequest(url: markedURL(URL(string: "https://example.com/appcast.xml")!, token: routing.token!))) { _, _, _ in }
        task.resume()
        waitUntil("update request starts") { transport.calls.value.count == 2 }
        started.value = true
        task.cancel()
        waitUntil("update request cancellation propagates") { transport.cancelled.value > 0 }
        check(started.value && transport.cancelled.value == 1, "cancelling the real URLSession task cancels exactly one transport handle")
        _ = schedulerPathLossCheck()
    }

    // ===== E. 真实回环 HTTP：两种 route 都支持重定向、流式 body、chunked 与断线 =====
    let payload = Data((0..<262_144).map { UInt8(truncatingIfNeeded: $0) })
    let originRequests = Locked<[HTTPRequest]>([])
    guard let server = try? LoopbackHTTPServer(expectedConnections: 80, handler: { request, fd in
        originRequests.value.append(request)
        switch request.target {
        case "/redirect":
            LoopbackHTTPServer.respond(status: "302 Found", headers: ["Location": "/final", "Content-Length": "0"], body: Data(), fd: fd)
        case "/final":
            LoopbackHTTPServer.stream(status: "200 OK", headers: ["Content-Type": "application/octet-stream",
                                                                  "Content-Length": String(payload.count)], body: payload, fd: fd)
        case "/chunked":
            LoopbackHTTPServer.respondChunked(body: payload, fd: fd)
        case "/close":
            close(fd)
        case "/slow":
            LoopbackHTTPServer.respond(status: "200 OK", headers: ["Content-Length": String(payload.count)],
                                       body: payload.prefix(4096), fd: fd)
            Thread.sleep(forTimeInterval: 1.0)
            close(fd)
        case "/length-2e63":
            LoopbackHTTPServer.respond(status: "200 OK", headers: ["Content-Length": "9223372036854775808"], body: Data("x".utf8), fd: fd)
        case "/length-uint64max":
            LoopbackHTTPServer.respond(status: "200 OK", headers: ["Content-Length": "18446744073709551615"], body: Data("x".utf8), fd: fd)
        case "/chunk-2e63":
            LoopbackHTTPServer.respond(status: "200 OK", headers: ["Transfer-Encoding": "chunked"], body: Data("8000000000000000\r\nx".utf8), fd: fd)
        case "/chunk-overflow":
            LoopbackHTTPServer.respond(status: "200 OK", headers: ["Transfer-Encoding": "chunked"],
                                          body: Data(String(repeating: "A", count: 65_537).utf8), fd: fd)
        case "/trailer-overflow":
            LoopbackHTTPServer.respond(status: "200 OK", headers: ["Transfer-Encoding": "chunked"],
                                          body: Data(("0\r\n" + String(repeating: "T", count: 65_537)).utf8), fd: fd)
        case "/length-conflict":
            LoopbackHTTPServer.respondRawText("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\nConnection: close\r\n\r\nx", fd: fd)
        case "/length-empty":
            LoopbackHTTPServer.respondRawText("HTTP/1.1 200 OK\r\nContent-Length:\r\nConnection: close\r\n\r\n", fd: fd)
        case "/status-999":
            LoopbackHTTPServer.respond(status: "999 Out Of Range", headers: ["Content-Length": "0"], body: Data(), fd: fd)
        case let target where target.hasPrefix("/redirect-non-http"):
            LoopbackHTTPServer.respond(status: "302 Found", headers: ["Location": "ftp://\(request.headers["host"] ?? "127.0.0.1")/final",
                                                                        "Content-Length": "0"], body: Data(), fd: fd)
        case let target where target.hasPrefix("/redirect-marker"):
            LoopbackHTTPServer.respond(status: "302 Found", headers: ["Location": "/echo?keep=%2F&matchsticksds_update_request=redirect-secret",
                                                                        "Content-Length": "0"], body: Data(), fd: fd)
        case let target where target.hasPrefix("/redirect-sensitive"):
            LoopbackHTTPServer.respond(status: "302 Found", headers: ["Location": "/echo", "Content-Length": "0"], body: Data(), fd: fd)
        case "/echo", "/final-echo":
            LoopbackHTTPServer.respond(status: "200 OK", headers: ["Content-Length": "2"], body: Data("ok".utf8), fd: fd)
        case let target where target.hasPrefix("/escaped/"):
            LoopbackHTTPServer.respond(status: "200 OK", headers: ["Content-Length": "2"], body: Data("ok".utf8), fd: fd)
        default:
            LoopbackHTTPServer.respond(status: "404 Not Found", headers: ["Content-Length": "0"], body: Data(), fd: fd)
        }
    }) else {
        check(false, "loopback HTTP server starts")
        return
    }
    server.start()
    defer { server.stop() }
    let base = "http://127.0.0.1:\(server.port)"

    for route: UpdateProbeRoute in [.defaultRoute, .wiredEthernet] {
        let recorder = RecordingRequestTransport(base: SystemUpdateRequestTransport(wiredTimeout: 3))
        routing.transport = recorder
        _ = routing.activate(route: route)
        let session = URLSession(configuration: updateProtocolConfiguration())
        defer { session.finishTasksAndInvalidate() }
        let redirected = perform(URLRequest(url: markedURL(URL(string: "\(base)/redirect")!, token: routing.token!)), session: session)
        check(redirected.error.value == nil && (redirected.response.value as? HTTPURLResponse)?.statusCode == 200 &&
              redirected.data.value == payload,
              "\(route) follows redirect and preserves the complete streamed body")
        check((redirected.response.value as? HTTPURLResponse)?.url?.path == "/final",
              "\(route) reports the final response URL for relative appcast links")
        check(recorder.dataCounts.value.last.map { $0 > 1 } == true,
              "\(route) streams large payloads in chunks instead of buffering one body block (counts: \(recorder.dataCounts.value))")
        let chunked = perform(URLRequest(url: markedURL(URL(string: "\(base)/chunked")!, token: routing.token!)), session: session)
        check(chunked.error.value == nil && chunked.data.value == payload,
              "\(route) decodes chunked transfer encoding (error: \(String(describing: chunked.error.value)), bytes: \(chunked.data.value?.count ?? 0))")
        let disconnected = perform(URLRequest(url: markedURL(URL(string: "\(base)/close")!, token: routing.token!)), session: session)
        check(disconnected.error.value != nil, "\(route) reports a connection closed before headers")
    }

    // ===== E2. 重定向安全与源站隐私：两种 route 都不得把标记、凭据或非 HTTP 目标放行 =====
    for route: UpdateProbeRoute in [.defaultRoute, .wiredEthernet] {
        routing.transport = SystemUpdateRequestTransport(wiredTimeout: 1)
        _ = routing.activate(route: route)
        let session = URLSession(configuration: updateProtocolConfiguration())
        defer { session.finishTasksAndInvalidate() }

        let beforeNonHTTP = originRequests.value.count
        let nonHTTP = perform(URLRequest(url: markedURL(URL(string: "\(base)/redirect-non-http")!, token: routing.token!)), session: session)
        let nonHTTPRequests = originRequests.value.dropFirst(beforeNonHTTP)
        check(nonHTTP.error.value != nil && nonHTTPRequests.count == 1 && nonHTTPRequests.first?.target.hasPrefix("/redirect-non-http") == true,
              "\(route) rejects a non-HTTP redirect without contacting its target")

        let beforeSensitive = originRequests.value.count
        var sensitive = URLRequest(url: markedURL(URL(string: "\(base)/redirect-sensitive")!, token: routing.token!))
        sensitive.setValue("Bearer origin-secret", forHTTPHeaderField: "Authorization")
        sensitive.setValue("Basic proxy-secret", forHTTPHeaderField: "Proxy-Authorization")
        sensitive.setValue("session=origin-secret", forHTTPHeaderField: "Cookie")
        let sensitiveResult = perform(sensitive, session: session)
        let sensitiveRequests = originRequests.value.dropFirst(beforeSensitive)
        check(sensitiveResult.error.value == nil && sensitiveRequests.count == 2 &&
              sensitiveRequests.dropFirst().first?.target == "/echo",
              "\(route) follows a safe redirect while preserving the origin path")
        check(sensitiveRequests.allSatisfy { request in
            request.headers["authorization"] == nil && request.headers["proxy-authorization"] == nil && request.headers["cookie"] == nil
        }, "\(route) never sends Authorization, Proxy-Authorization or Cookie headers to the origin")

        let beforeMarker = originRequests.value.count
        let markedRedirect = perform(URLRequest(url: markedURL(URL(string: "\(base)/redirect-marker")!, token: routing.token!)), session: session)
        let markerRequests = originRequests.value.dropFirst(beforeMarker)
        check(markedRedirect.error.value == nil && markerRequests.count == 2 && markerRequests.first?.target == "/redirect-marker",
              "\(route) removes the private query marker before the first origin request")
        check(markerRequests.dropFirst().first?.target == "/echo?keep=%2F",
              "\(route) strips private markers from the redirect target while preserving other escaping (actual: \(markerRequests.dropFirst().first?.target ?? "none"))")

        let escapedTarget = "/escaped/a%2Fb?keep=%2F%3F%26%3D%23%25%20%2B&flag&empty=&matchsticksds_update_request=\(routing.token!)"
        let escapedResult = perform(URLRequest(url: URL(string: "\(base)\(escapedTarget)")!), session: session)
        check(escapedResult.error.value == nil && originRequests.value.last?.target == "/escaped/a%2Fb?keep=%2F%3F%26%3D%23%25%20%2B&flag&empty=",
              "\(route) preserves the exact percent-encoded request target (actual: \(originRequests.value.last?.target ?? "none"))")
    }

    // ===== E3. 恶意 HTTP framing：大整数不得崩溃，累计行缓冲有界，冲突长度/状态码 fail closed =====
    for path in ["/length-2e63", "/length-uint64max"] {
        let result = performWired("\(base)\(path)", timeout: 1)
        check(result.error.value?.localizedDescription.contains("Content-Length") == true,
              "\(path) rejects a Content-Length beyond Int.max without trapping (error: \(String(describing: result.error.value)))")
    }
    let hugeChunk = performWired("\(base)/chunk-2e63", timeout: 1)
    check(hugeChunk.error.value?.localizedDescription.contains("chunk size") == true,
          "a chunk size of 2^63 is rejected without trapping (error: \(String(describing: hugeChunk.error.value)))")
    for path in ["/chunk-overflow", "/trailer-overflow"] {
        let before = originRequests.value.count
        let result = performWired("\(base)\(path)", timeout: 0.5)
        let expected = path == "/chunk-overflow" ? "chunk size line" : "chunk trailers"
        check(result.error.value?.localizedDescription.contains(expected) == true && originRequests.value.count == before + 1,
              "\(path) caps an unterminated line at 64 KiB instead of waiting for the full timeout (error: \(String(describing: result.error.value)))")
    }
    let conflict = performWired("\(base)/length-conflict", timeout: 1)
    check(conflict.error.value?.localizedDescription.contains("conflicting Content-Length") == true,
          "different repeated Content-Length values are rejected (error: \(String(describing: conflict.error.value)))")
    let emptyLength = performWired("\(base)/length-empty", timeout: 1)
    check(emptyLength.error.value?.localizedDescription.contains("Content-Length") == true,
          "an empty Content-Length is rejected instead of becoming a close-delimited success")
    let badStatus = performWired("\(base)/status-999", timeout: 1)
    check(badStatus.error.value?.localizedDescription.contains("HTTP status") == true,
          "a status code above 599 is rejected (error: \(String(describing: badStatus.error.value)))")
    routing.transport = SystemUpdateRequestTransport(wiredTimeout: 1)
    _ = routing.activate(route: .defaultRoute)
    let defaultSession = URLSession(configuration: updateProtocolConfiguration())
    defer { defaultSession.finishTasksAndInvalidate() }
    let defaultConflict = perform(URLRequest(url: markedURL(URL(string: "\(base)/length-conflict")!, token: routing.token!)), session: defaultSession)
    let defaultBadStatus = perform(URLRequest(url: markedURL(URL(string: "\(base)/status-999")!, token: routing.token!)), session: defaultSession)
    check(defaultConflict.error.value != nil && defaultBadStatus.error.value != nil,
          "default responses reject conflicting Content-Length and out-of-range status codes (conflict: \(String(describing: defaultConflict.error.value)); status: \(String(describing: defaultBadStatus.error.value)); response: \(String(describing: defaultConflict.response.value))")

    let beforeCredentials = originRequests.value.count
    let credentialBase = base.replacingOccurrences(of: "http://", with: "http://user:secret@")
    let urlCredentials = performWired("\(credentialBase)/echo", timeout: 1)
    check(urlCredentials.error.value != nil && originRequests.value.count == beforeCredentials,
          "wired requests with URL-embedded credentials fail before opening an origin connection")

    // ===== E4. 探测边界：默认探测不跟随跳转，有线状态码也限定在 HTTP 范围内 =====
    let beforeProbeRedirect = originRequests.value.count
    let probeRedirect = Locked<UpdateProbeResult?>(nil)
    SystemRouteProbeTransport().probe(.defaultRoute, url: URL(string: "\(base)/redirect")!) { probeRedirect.value = $0 }
    waitUntil("default redirect probe completes") { probeRedirect.value != nil }
    check(probeRedirect.value?.reachable == true && probeRedirect.value?.detail.contains("302") == true &&
          originRequests.value.count == beforeProbeRedirect + 1,
          "the default probe reports a redirect without following it (detail: \(probeRedirect.value?.detail ?? "pending"), requests: \(originRequests.value.dropFirst(beforeProbeRedirect).map(\.target)))")
    let probeBadStatus = Locked<UpdateProbeResult?>(nil)
    SystemRouteProbeTransport().probe(.wiredEthernet, url: URL(string: "\(base)/status-999")!) { probeBadStatus.value = $0 }
    waitUntil("wired bad-status probe completes") { probeBadStatus.value != nil }
    check(probeBadStatus.value?.reachable == false, "the wired probe rejects a status line above 599")
    let probeSource = (try? String(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/MatchSticksDriverStaion/UpdateProbeTransport.swift"), encoding: .utf8)) ?? ""
    check(probeSource.contains("configuration.urlCredentialStorage = nil") &&
              SystemRouteProbeTransport.makeConfiguration().urlCredentialStorage == nil,
          "the production default probe configuration disables implicit URL credentials")

    // ===== F. 数据已开始后取消：底层连接确实取消，不仅隐藏 UI =====
    do {
        let recorder = RecordingRequestTransport(base: SystemUpdateRequestTransport(wiredTimeout: 3))
        routing.transport = recorder
        _ = routing.activate(route: .wiredEthernet)
        let session = URLSession(configuration: updateProtocolConfiguration())
        defer { session.finishTasksAndInvalidate() }
        let result = NetworkResult()
        let task = session.dataTask(with: URLRequest(url: markedURL(URL(string: "\(base)/slow")!, token: routing.token!))) { data, response, error in
            result.data.value = data
            result.response.value = response
            result.error.value = error
            result.done.value = true
        }
        task.resume()
        waitUntil("slow update sends its first chunk") { recorder.lastDataCount.value > 0 }
        task.cancel()
        waitUntil("cancelled slow update completes") { result.done.value }
        check(result.error.value != nil && recorder.cancelled.value == 1,
              "cancel after streaming starts cancels the underlying wired connection (error: \(String(describing: result.error.value)), cancelled: \(recorder.cancelled.value), done: \(result.done.value))")
    }

    // ===== G. 生产接线守卫：Sparkle 公开钩子标 feed / enclosure，探测 route 交给 adapter =====
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let center = (try? String(contentsOf: repositoryRoot.appendingPathComponent("Sources/MatchSticksDriverStaion/UpdateCenter.swift"), encoding: .utf8)) ?? ""
    check(center.contains("routing.activate(route: result.route)") &&
          center.contains("routing.deactivate()"),
          "UpdateCenter activates and clears the selected route at probe/cycle boundaries")
    check(center.contains("feedParameters(for updater: SPUUpdater") &&
          center.contains("willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest"),
          "Sparkle's public feed parameter and enclosure request hooks are implemented")
    check(center.contains("routing.markDownload(request)"), "the Sparkle enclosure request receives the private marker")
    check(center.contains("shouldDownloadReleaseNotesForUpdate"),
          "the silent driver disables unused release-notes downloads that would otherwise bypass the selected route")
    let unknownSparkleGuard = "guard nsError.domain == SUSparkleErrorDomain,\n              let code = SUError(rawValue: Int32(nsError.code)) else { return }"
    check(!center.contains(unknownSparkleGuard),
          "unknown Sparkle errors cannot return without finishing the cycle and scheduling backoff")
    check(!center.contains("Int(delay), error.localizedDescription)"),
          "Sparkle error descriptions are not copied into app logs where request URLs could contain markers")
}

@MainActor
private func performWired(_ string: String, timeout: TimeInterval) -> NetworkResult {
    let result = NetworkResult()
    let transport = SystemUpdateRequestTransport(wiredTimeout: timeout)
    let handle = transport.send(URLRequest(url: URL(string: string)!), route: .wiredEthernet, callbacks: UpdateRequestCallbacks(
        response: { result.response.value = $0 },
        data: { result.data.value = $0 },
        completion: { error in
            result.error.value = error
            result.done.value = true
        }))
    waitUntil("wired request completes", timeout: 5) { result.done.value }
    if !result.done.value { handle.cancel() }
    return result
}

@MainActor
private func schedulerPathLossCheck() -> Bool {
    let scheduler = UpdateCheckScheduler()
    _ = scheduler.requestCheck()
    _ = scheduler.probeSucceeded(route: .wiredEthernet)
    let failed = scheduler.checkFinished(.failed)
    return scheduler.updateRoute == nil && failed == .wait(delay: 3)
}

private func updateProtocolConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UpdateURLProtocol.self]
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 15
    return configuration
}

private func markedURL(_ url: URL, token: String) -> URL {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: UpdateRequestRouting.feedParameter, value: token)]
    return components.url!
}

private func stripMarker(from url: URL) -> URL {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.queryItems = components.queryItems?.filter { $0.name != UpdateRequestRouting.feedParameter }
    if components.queryItems?.isEmpty == true { components.queryItems = nil }
    return components.url!
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

private final class NetworkResult: @unchecked Sendable {
    let data = Locked<Data?>(nil)
    let response = Locked<URLResponse?>(nil)
    let error = Locked<Error?>(nil)
    let done = Locked(false)
}

@MainActor
private func perform(_ request: URLRequest, session: URLSession) -> NetworkResult {
    let result = NetworkResult()
    let task = session.dataTask(with: request) { data, response, error in
        result.data.value = data
        result.response.value = response
        result.error.value = error
        result.done.value = true
    }
    task.resume()
    waitUntil("URLSession request completes") { result.done.value }
    if !result.done.value { task.cancel() }
    return result
}

@MainActor
private func waitUntil(_ message: String, timeout: TimeInterval = 6, condition: @escaping @MainActor () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

private final class ScriptedRequestTransport: UpdateRequestTransport, @unchecked Sendable {
    struct Call {
        let request: URLRequest
        let route: UpdateProbeRoute
    }
    let calls = Locked<[Call]>([])
    let completions = Locked(0)
    let cancelled = Locked(0)
    var handler: ((URLRequest, UpdateProbeRoute, UpdateRequestCallbacks, UpdateRequestHandle) -> Void)?
    func send(_ request: URLRequest, route: UpdateProbeRoute, callbacks: UpdateRequestCallbacks) -> UpdateRequestHandle {
        calls.value.append(Call(request: request, route: route))
        let handle = UpdateRequestHandle { [weak self] in self?.cancelled.value += 1 }
        if let handler {
            handler(request, route, callbacks, handle)
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "2"])!
            callbacks.response(response)
            callbacks.data(Data("ok".utf8))
            callbacks.completion(nil)
        }
        return handle
    }
}

private final class RecordingRequestTransport: UpdateRequestTransport {
    let base: SystemUpdateRequestTransport
    let dataCounts = Locked<[Int]>([])
    let lastDataCount = Locked(0)
    let cancelled = Locked(0)
    init(base: SystemUpdateRequestTransport) { self.base = base }
    func send(_ request: URLRequest, route: UpdateProbeRoute, callbacks: UpdateRequestCallbacks) -> UpdateRequestHandle {
        dataCounts.value.append(0)
        let index = dataCounts.value.count - 1
        let handle = base.send(request, route: route, callbacks: UpdateRequestCallbacks(
            response: callbacks.response,
            data: { data in
                self.dataCounts.value[index] += 1
                self.lastDataCount.value = self.dataCounts.value[index]
                callbacks.data(data)
            },
            completion: callbacks.completion))
        return UpdateRequestHandle {
            self.cancelled.value += 1
            handle.cancel()
        }
    }
}

private final class SentinelURLProtocol: URLProtocol {
    static let count = Locked(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count.value += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("sentinel".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct HTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
}

private final class LoopbackHTTPServer {
    typealias Handler = (HTTPRequest, Int32) -> Void
    private let fd: Int32
    private let expectedConnections: Int
    private let handler: Handler
    private(set) var port: UInt16 = 0
    private var thread: Thread?

    init(expectedConnections: Int, handler: @escaping Handler) throws {
        self.expectedConnections = expectedConnections
        self.handler = handler
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "test.http.server", code: 1) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 && listen(fd, 4) == 0 else {
            close(fd)
            throw NSError(domain: "test.http.server", code: 2)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
    }

    func start() {
        let thread = Thread { [self] in acceptLoop() }
        self.thread = thread
        thread.start()
    }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    private func acceptLoop() {
        var count = 0
        while count < expectedConnections {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { break }
            count += 1
            handle(client)
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        var data = Data()
        while data.range(of: Data("\r\n\r\n".utf8)) == nil && data.count < 65_536 {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            data.append(buffer, count: count)
        }
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return }
        let text = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].components(separatedBy: " ")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard requestLine.count >= 2 else { return }
        handler(HTTPRequest(method: requestLine[0], target: requestLine[1], headers: headers), client)
    }

    static func respond(status: String, headers: [String: String], body: Data, fd: Int32) {
        var head = "HTTP/1.1 \(status)\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        sendAll(Data(head.utf8) + body, fd: fd)
    }

    static func respondRawText(_ response: String, fd: Int32) {
        sendAll(Data(response.utf8), fd: fd)
    }

    static func stream(status: String, headers: [String: String], body: Data, fd: Int32) {
        var head = "HTTP/1.1 \(status)\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        sendAll(Data(head.utf8), fd: fd)
        body.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let end = min(offset + 4096, raw.count)
                sendAll(Data(raw[offset..<end]), fd: fd)
                usleep(1000)
                offset = end
            }
        }
    }

    static func respondChunked(body: Data, fd: Int32) {
        let header = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        sendAll(Data(header.utf8), fd: fd)
        var offset = 0
        for size in [17, 8192, body.count - 17 - 8192] {
            sendAll(Data(String(format: "%x\r\n", size).utf8), fd: fd)
            sendAll(body[offset..<offset + size], fd: fd)
            sendAll(Data("\r\n".utf8), fd: fd)
            offset += size
        }
        sendAll(Data("0\r\nX-Trailer: done\r\n\r\n".utf8), fd: fd)
    }

    private static func sendAll(_ data: Data, fd: Int32) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                if sent <= 0 { return }
                offset += sent
            }
        }
    }
}
