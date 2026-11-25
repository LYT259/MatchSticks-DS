import AppKit
import DSCore

@MainActor
private final class FakeFirewallProbe: FirewallProbeControlling {
    var onState: (@MainActor (FirewallProbeState) -> Void)?
    var startCount = 0
    var stopCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}

/// 只连接、不发送的 TCP 连接：在监听端占住一个空闲名额（回环来源在收到数据或超时前保持打开）。
private func idleConnection(to url: URL) -> Int32? {
    guard let host = url.host, let port = url.port else { return nil }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else {
        Darwin.close(fd)
        return nil
    }
    return fd
}

@MainActor
func firewallVerificationProbeTests(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void) {
    let loopback = FirewallInterface(name: "lo0", address: "127.0.0.1", prefixLength: 8,
                                     isUp: true, isLoopback: true)
    let down = FirewallInterface(name: "en5", address: "192.0.2.5", prefixLength: 24,
                                 isUp: false, isLoopback: false)
    let unspecified = FirewallInterface(name: "en6", address: "0.0.0.0", prefixLength: 0,
                                        isUp: true, isLoopback: false)
    let wifi = FirewallInterface(name: "en1", address: "192.0.2.20", prefixLength: 24,
                                 isUp: true, isLoopback: false)
    let ethernet = FirewallInterface(name: "en0", address: "192.0.2.10", prefixLength: 24,
                                     isUp: true, isLoopback: false)
    let multicast = FirewallInterface(name: "en7", address: "224.0.0.1", prefixLength: 24,
                                      isUp: true, isLoopback: false)
    let broadcast = FirewallInterface(name: "en8", address: "255.255.255.255", prefixLength: 24,
                                      isUp: true, isLoopback: false)
    let selected = FirewallVerificationProbe.selectListenAddress(
        [loopback, down, unspecified, multicast, broadcast, wifi, ethernet])
    check(selected == "192.0.2.10",
          "the listener selects a deterministic active non-loopback IPv4 address")
    check(FirewallVerificationProbe.selectListenAddress([loopback, down, unspecified, multicast, broadcast]) == nil,
          "invalid or unavailable interfaces never fall back to wildcard or loopback")
    check(FirewallVerificationProbe.selectListenAddress([wifi, ethernet]) == "192.0.2.10" &&
          FirewallVerificationProbe.selectListenAddress([ethernet, wifi]) == "192.0.2.10",
          "interface order does not make listener selection nondeterministic")
    let virtualBridge = FirewallInterface(name: "bridge100", address: "192.168.64.2", prefixLength: 24,
                                          isUp: true, isLoopback: false)
    check(FirewallVerificationProbe.selectListenAddress([virtualBridge, wifi]) == "192.0.2.20" &&
              FirewallVerificationProbe.selectListenAddress([virtualBridge]) == "192.168.64.2",
          "a virtual-machine or bridge adapter never outranks a Wi-Fi or Ethernet address, and is still usable alone")

    let localAddresses: Set<String> = ["192.0.2.10", "192.0.2.20", "127.0.0.1"]
    check(FirewallVerificationProbe.isLocalPeer("127.0.0.1", localAddresses: localAddresses) &&
          FirewallVerificationProbe.isLocalPeer("localhost", localAddresses: localAddresses) &&
          FirewallVerificationProbe.isLocalPeer("0.0.0.0", localAddresses: localAddresses) &&
          FirewallVerificationProbe.isLocalPeer("192.0.2.10", localAddresses: localAddresses) &&
          FirewallVerificationProbe.isLocalPeer("192.0.2.20", localAddresses: localAddresses),
          "loopback, unspecified and every local interface address are rejected as self-probes")
    check(!FirewallVerificationProbe.isLocalPeer("192.0.2.20", localAddresses: ["192.0.2.10"]),
          "a non-loopback address not owned by this Mac is eligible as external evidence")

    let peer = FirewallProbePeer(source: "192.0.2.20", destination: "192.0.2.10")
    check(FirewallVerificationProbe.isValidPeer(peer, advertisedAddress: "192.0.2.10",
                                                localAddresses: ["192.0.2.10"]),
          "a non-local peer reaching the advertised destination is valid")
    check(!FirewallVerificationProbe.isValidPeer(peer, advertisedAddress: "192.0.2.20",
                                                localAddresses: ["192.0.2.10"]),
          "a different destination is not valid for the advertised listener")
    check(!FirewallVerificationProbe.isValidPeer(
        FirewallProbePeer(source: "192.0.2.10", destination: "192.0.2.10"),
        advertisedAddress: "192.0.2.10", localAddresses: ["192.0.2.10"]),
          "a same-Mac non-loopback self-connection is rejected")
    check(!FirewallVerificationProbe.isValidPeer(
        FirewallProbePeer(source: "127.0.0.1", destination: "192.0.2.10"),
        advertisedAddress: "192.0.2.10", localAddresses: ["192.0.2.10"]),
          "a loopback peer is rejected even when the destination is non-loopback")
    check(!FirewallVerificationProbe.isValidPeer(
        FirewallProbePeer(source: "0.0.0.0", destination: "192.0.2.10"),
        advertisedAddress: "192.0.2.10", localAddresses: ["192.0.2.10"]),
          "an unspecified peer is rejected")

    func request(_ text: String) -> Data {
        Data((text + "\r\nHost: irrelevant.example\r\n\r\n").utf8)
    }
    check(FirewallHTTPRequest.parse(request("GET /verify HTTP/1.1")) == .valid &&
          FirewallHTTPRequest.parse(request("GET /verify HTTP/1.0")) == .valid,
          "only exact bounded GET /verify HTTP requests are valid")
    check(FirewallHTTPRequest.parse(request("POST /verify HTTP/1.1")) == .invalid &&
          FirewallHTTPRequest.parse(request("GET /other HTTP/1.1")) == .invalid &&
          FirewallHTTPRequest.parse(request("GET /verify?q=1 HTTP/1.1")) == .invalid &&
          FirewallHTTPRequest.parse(request("GET /verify HTTP/2")) == .invalid,
          "wrong methods, paths, queries and HTTP versions are invalid")
    check(FirewallHTTPRequest.parse(Data("GET /verify HTTP/1.1\r\n".utf8)) == .incomplete &&
          FirewallHTTPRequest.parse(Data("GET /verify HTTP/1.1\r\nHost: x\r\nBODY".utf8)) == .invalid &&
          FirewallHTTPRequest.parse(Data(repeating: 0x41, count: 5000)) == .invalid,
          "incomplete, malformed and oversized requests never verify")

    let fake = FakeFirewallProbe()
    let monitor = PermissionRuntimeMonitor(makeFirewallProbe: { fake })
    monitor.beginNewLaunch()
    monitor.startFirewallVerification()
    monitor.startFirewallVerification()
    check(fake.startCount == 2 && fake.stopCount == 1,
          "a fresh firewall check stops the previous probe before starting a new one")
    fake.onState?(.starting)
    check(monitor.firewallEvidence == .starting && monitor.firewallEvidence.tone == .warning,
          "starting a probe does not create success")
    let url = URL(string: "http://192.0.2.10:6789/verify")!
    fake.onState?(.waiting(url))
    check(monitor.firewallURL == url && monitor.firewallEvidence == .waiting(url),
          "the ephemeral verification URL is published only in waiting state")
    fake.onState?(.verified(peer: "192.0.2.20"))
    check(monitor.firewallEvidence == .verified && monitor.firewallURL == nil,
          "verified evidence closes the URL and becomes green")
    fake.onState?(.waiting(url))
    check(monitor.firewallEvidence == .verified,
          "late waiting callbacks cannot overwrite valid success")
    monitor.beginNewLaunch()
    check(monitor.firewallEvidence == .notStarted && monitor.firewallURL == nil && fake.stopCount == 2,
          "a new launch cancels the old probe and clears its evidence")

    let autoFake = FakeFirewallProbe()
    let autoMonitor = PermissionRuntimeMonitor(makeFirewallProbe: { autoFake })
    autoMonitor.beginNewLaunch(autoSim: true)
    autoMonitor.startFirewallVerification(autoSim: true)
    check(autoFake.startCount == 0 && autoMonitor.firewallEvidence == .skipped,
          "AUTO_SIM does not open the LAN verification listener")

    let probe = FirewallVerificationProbe()
    var states: [FirewallProbeState] = []
    probe.onState = { states.append($0) }
    probe.start()
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline, !states.contains(where: {
        if case .waiting = $0 { return true }
        return false
    }) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    guard case .waiting(let verificationURL)? = states.last else {
        check(false, "the real temporary listener starts on an ephemeral port")
        probe.stop()
        return
    }
    let semaphore = DispatchSemaphore(value: 0)
    var statusCode: Int?
    var responseBodyData: Data?
    var responseError: Error?
    let task = URLSession.shared.dataTask(with: verificationURL) { data, response, error in
        statusCode = (response as? HTTPURLResponse)?.statusCode
        responseBodyData = data
        responseError = error
        semaphore.signal()
    }
    task.resume()
    check(semaphore.wait(timeout: .now() + 5) == .success, "the local negative request completes")
    check(statusCode == 403, "same-Mac non-loopback requests receive 403 rather than success")
    check(!states.contains { state in
        if case .verified = state { return true }
        return false
    }, "a same-Mac non-loopback request never creates firewall evidence")
    check(responseError == nil, "the local negative request uses the real listener rather than a fake response")
    let body = String(data: responseBodyData ?? Data(), encoding: .utf8) ?? ""
    check(body.contains("Local interface rejected") && !body.contains("firewall allowed"),
          "the negative response is static and does not claim firewall success")

    var held: [Int32] = []
    defer { held.forEach { Darwin.close($0) } }
    for _ in 0..<FirewallVerificationProbe.maximumConcurrentConnections {
        if let fd = idleConnection(to: verificationURL) { held.append(fd) }
    }
    let overflow = idleConnection(to: verificationURL)
    check(held.count == FirewallVerificationProbe.maximumConcurrentConnections && overflow != nil,
          "idle local connections can fill the listener's connection slots")
    if let first = held.first, let overflow {
        var byte: UInt8 = 0
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(first, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(overflow, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        check(recv(overflow, &byte, 1, 0) == 0,
              "a connection beyond the cap is closed at once instead of being held")
        Darwin.close(overflow)
        check(recv(first, &byte, 1, 0) < 0,
              "connections within the cap are still held instead of being refused")
    }
    probe.stop()
    check(states.allSatisfy { state in
        if case .verified = state { return false }
        return true
    }, "stopping the probe does not fabricate success")
}
