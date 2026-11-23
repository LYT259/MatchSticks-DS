import Foundation
import Network
import Security

// MARK: - 生产探测传输：默认路由（URLSession）与非 Wi‑Fi 路径（NWConnection + TLS + HTTP/1.1 HEAD）
//
// 第二条路径是对「系统自然 fallback」假设的实证替代：默认路由（radio Wi‑Fi 优先时通常就是 Wi‑Fi）
// 失败后，用 NWConnection 对同一 feed URL 再发一次真实的 TLS + HTTP/1.1 HEAD，并**禁止走 Wi‑Fi**
// （prohibitedInterfaceTypes = [.wifi]）——连接只能从非 Wi‑Fi 接口离开，在 Mac 上即可用的有线 Ethernet /
// Thunderbolt 网桥；没有任何这样的路径时内核立即报 .waiting(ENETDOWN)，快速判不可达。回环目标由
// UpdateReachability 在顺序层直接跳过（不存在「不经 Wi‑Fi 到 127.0.0.1」的路径）。
//
// 为什么不用 requiredInterfaceType = .wiredEthernet：2026-11-23 在 macOS 27.3 上实测，无论
// requiredInterfaceType（.wiredEthernet / .wifi）还是 requiredInterface（取自有线 NWPathMonitor 的真实
// NWInterface），连接都停在 .waiting(ENETDOWN) 永不恢复，而同机 NWPathMonitor 明确报告 en9:wiredEthernet
// satisfied、prohibitedInterfaceTypes = [.wifi] 7 ms 内 ready（TLS 握手 ~0.5 s）。同一实测还发现
// 把 .loopback 一并禁用也会 ENETDOWN，所以只禁 Wi‑Fi。与 AGENTS.md 记录的 macOS 27 Network.framework
// 回归（NWListener EINVAL）同类。禁止 Wi‑Fi 不依赖按类型选路，语义上同样回答「不经 radio Wi‑Fi 能否连上 GitHub」。
//
// 任何 HTTP 状态行 = 可达；无路径（.waiting）、连接失败（.failed）、超时 = 不可达。不设 ALPN（服务端按
// HTTP/1.1 应答，状态行可直接解析），不跟随重定向（任一状态码即可达），不发送 cookie / 凭证。只约束这一条
// 探测连接：不改网络服务顺序、不关 Wi‑Fi、不碰机器人 socket。
//
// Sparkle 的 appcast / 下载请求由 UpdateURLProtocol 使用同一 UpdateProbeRoute：默认成功只走默认，
// 默认失败且有线路径成功时，feed 与 enclosure 都经 WiredEthernet HTTP transport。更新请求失败回到
// 调度器退避并清除 route。探测传输的顺序由 UpdateReachabilityTests 覆盖，更新请求的流式 / 重定向 /
// 取消由 UpdateRequestRoutingTests 的真实回环 HTTP 服务覆盖；真实 Sparkle 五腿 E2E 留给主代理。

final class SystemRouteProbeTransport: UpdateProbeTransport {
    private let session: URLSession
    private let wiredTimeout: TimeInterval

    init(session: URLSession = UpdateReachability.makeSession(), wiredTimeout: TimeInterval = 8) {
        self.session = session
        self.wiredTimeout = wiredTimeout
    }

    func probe(_ route: UpdateProbeRoute, url: URL, completion: @escaping (UpdateProbeResult) -> Void) {
        switch route {
        case .defaultRoute:
            probeDefault(url, completion: completion)
        case .wiredEthernet:
            WiredEthernetProbe(url: url, timeout: wiredTimeout, completion: completion).start()
        }
    }

    private func probeDefault(_ url: URL, completion: @escaping (UpdateProbeResult) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        session.dataTask(with: request) { _, response, error in
            if let http = response as? HTTPURLResponse {
                completion(UpdateProbeResult(reachable: true, route: .defaultRoute, detail: "HTTP \(http.statusCode)"))
            } else {
                completion(UpdateProbeResult(reachable: false, route: .defaultRoute,
                                             detail: error?.localizedDescription ?? "no HTTP response"))
            }
        }.resume()
    }
}

/// 一次非 Wi‑Fi 路径上的 HEAD 探测。全部状态只在私有串行队列上变更；completion 恰好回调一次。
/// 调用方不持有实例：start() 期间自持有（回调全是 [weak self]，不持有会在 start 返回后立即释放、永不回报）。
private final class WiredEthernetProbe {
    private let queue = DispatchQueue(label: "matchsticks.ds.updateprobe.wired", qos: .utility)
    private let url: URL
    private let timeout: TimeInterval
    private let completion: (UpdateProbeResult) -> Void
    private var connection: NWConnection?
    private var timeoutItem: DispatchWorkItem?
    private var selfRetainer: WiredEthernetProbe?
    private var finished = false

    init(url: URL, timeout: TimeInterval, completion: @escaping (UpdateProbeResult) -> Void) {
        self.url = url
        self.timeout = timeout
        self.completion = completion
    }

    func start() {
        selfRetainer = self
        guard let host = url.host?.trimmingCharacters(in: .whitespaces), !host.isEmpty,
              let port = Self.port(of: url) else {
            fail("invalid feed URL")
            return
        }
        let useTLS = url.scheme?.lowercased() == "https"
        let parameters: NWParameters
        if useTLS {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        parameters.prohibitedInterfaceTypes = [.wifi]

        // IPv6 字面量主机名需加方括号；显式端口才写进 Host
        let hostHeader = (host.contains(":") ? "[\(host)]" : host) + (url.port.map { ":\($0)" } ?? "")
        var target = url.path.isEmpty ? "/" : url.path
        if let query = url.query { target += "?\(query)" }
        var lines: [String] = []
        lines.append("HEAD \(target) HTTP/1.1")
        lines.append("Host: \(hostHeader)")
        lines.append("User-Agent: MatchSticksDS-update-probe")
        lines.append("Accept: */*")
        lines.append("Connection: close")
        let request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)

        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.stateChanged(state, request: request)
        }
        let timeoutText = "timeout after \(Int(timeout)) s"
        let item = DispatchWorkItem { [weak self] in self?.fail(timeoutText) }
        timeoutItem = item
        queue.asyncAfter(deadline: .now() + timeout, execute: item)
        connection.start(queue: queue)
    }

    private static func port(of url: URL) -> NWEndpoint.Port? {
        if let explicit = url.port { return NWEndpoint.Port(rawValue: UInt16(clamping: explicit)) }
        return url.scheme?.lowercased() == "https" ? 443 : 80
    }

    private func stateChanged(_ state: NWConnection.State, request: Data) {
        switch state {
        case .ready:
            connection?.send(content: request, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.fail("send failed: \(error.localizedDescription)")
                } else {
                    self.receive()
                }
            })
        case .waiting(let error):
            // 没有非 Wi‑Fi 的可用路径：不等待插线，快速判不可达，交给调度器退避 / 路径事件唤醒
            fail("no non-Wi-Fi path (\(error.localizedDescription))")
        case .failed(let error):
            fail(error.localizedDescription)
        case .setup, .preparing, .cancelled:
            break
        @unknown default:
            break
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.fail(error.localizedDescription)
                return
            }
            if let data, !data.isEmpty {
                let head = String(decoding: data.prefix(256), as: UTF8.self)
                if let lineEnd = head.range(of: "\r\n") ?? head.range(of: "\n") {
                    let line = String(head[..<lineEnd.lowerBound])
                    if line.hasPrefix("HTTP/") {
                        self.finish(UpdateProbeResult(reachable: true, route: .wiredEthernet, detail: line))
                    } else {
                        self.fail("unexpected response: \(line)")
                    }
                    return
                }
                if head.count >= 5, !head.hasPrefix("HTTP/") {
                    self.fail("unexpected response")
                    return
                }
            }
            if isComplete {
                self.fail("connection closed without an HTTP status line")
                return
            }
            self.receive()
        }
    }

    private func fail(_ detail: String) {
        finish(UpdateProbeResult(reachable: false, route: .wiredEthernet, detail: detail))
    }

    private func finish(_ result: UpdateProbeResult) {
        guard !finished else { return }
        finished = true
        timeoutItem?.cancel()
        timeoutItem = nil
        let connection = self.connection
        self.connection = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        selfRetainer = nil
        completion(result)
    }
}
