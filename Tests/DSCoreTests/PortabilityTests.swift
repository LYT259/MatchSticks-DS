// MARK: 三平台移植的行为测试（Darwin / Linux / Windows 同一套断言）
//
// 覆盖：① WebSocket 握手 accept key（纯 Swift SHA-1，向量由 Python hashlib 独立算出，
// 含 55/56/64/119/120 字节的分组边界与多字节 UTF-8）；② SocketCompat 的 IPv4 纯解析/
// 格式化（文法对齐 inet_pton：允许前导零、拒绝 >255）；③ OpenStep 文本 .strings 解析
// （注释、转义、坏条目容错）；④ SettingsStore 的持久化类型判定不依赖 CoreFoundation；
// ⑤ 仅经 SocketCompat 的回环 UDP/TCP 往返（Linux 用 poll、Windows 用 Winsock select）；
// ⑥ 同地址同端口独占绑定（Windows SO_EXCLUSIVEADDRUSE / Linux UDP 不设 SO_REUSEADDR）与 UDP 对
//    「对端端口不可达」的表现（Windows 关闭 SIO_UDP_CONNRESET 后与 POSIX 一致）。

import Foundation
import DSCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif

func websocketAcceptKeyVectorTests() {
    let vectors: [(key: String, accept: String)] = [
        ("", "Kfh9QIsMVZcl6xEPYxPHzW8SZ8w="),
        ("dGhlIHNhbXBsZSBub25jZQ==", "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="), // RFC 6455 §1.3
        (String(repeating: "k", count: 19), "tWclcP21hrR+xgjYVswtQRW71GQ="), // 55 字节：末块恰能容纳填充
        (String(repeating: "k", count: 20), "tSsjsIAvEVIQ+IC5K8+T/OkG8nU="), // 56 字节：填充溢出到第二块
        (String(repeating: "k", count: 28), "x9bmfLYIxLMaaT5h0sFuRlAhhb8="), // 64 字节：整块无余量
        (String(repeating: "k", count: 83), "c8WQ7edrEIKQKdUK6YpbGv6/vjc="), // 119 字节
        (String(repeating: "k", count: 84), "oSGTDoRzn25LiA1UjW2lEH1Pvlc="), // 120 字节
        ("倍倍倍xxxxxxx", "FNRTtagSu10WMtinxTNGZL81x54="), // 多字节 UTF-8（字节数 ≠ 字符数）
    ]
    for (key, expected) in vectors {
        check(NT4Server.websocketAcceptKey(for: key) == expected,
              "websocket accept key（\(key.prefix(12))…）得到 \(NT4Server.websocketAcceptKey(for: key))")
    }
}

func socketCompatIPv4Tests() {
    func be(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
        a << 24 | b << 16 | c << 8 | d
    }
    check(SocketCompat.parseIPv4("1.2.3.4") == be(1, 2, 3, 4), "基本四段")
    check(SocketCompat.parseIPv4("127.0.0.1") == be(127, 0, 0, 1), "回环")
    check(SocketCompat.parseIPv4("0.0.0.0") == 0, "0.0.0.0 解析为 0（非 nil）")
    check(SocketCompat.parseIPv4("255.255.255.255") == UInt32.max, "广播地址")
    check(SocketCompat.parseIPv4("01.2.3.4") == be(1, 2, 3, 4), "前导零按十进制（与 inet_pton 一致）")
    check(SocketCompat.parseIPv4("1.2.3.0004") == be(1, 2, 3, 4), "四位数带前导零仍按十进制")
    for bad in ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "999.1.1.1", "1.2.3.-1", " 1.2.3.4", "1.2.3.4 ",
                "1.2.3.4.", ".1.2.3.4", "1..2.3", "1.2.3.4a", "a.b.c.d", "0x7f.0.0.1", "+1.2.3.4",
                "roboRIO-2590-FRC.local", "1.2.3.4:1110", "1.2.3.4\n"] {
        check(SocketCompat.parseIPv4(bad) == nil, "非数字 IPv4 字面量拒绝：\(bad.debugDescription)")
    }
    for (text, value) in [("1.2.3.4", be(1, 2, 3, 4)), ("0.0.0.0", 0), ("255.255.255.255", .max)] {
        check(SocketCompat.ipv4AddressString(value) == text, "点分十进制回写 \(text)")
    }
    check(SocketCompat.parseIPv4("10.25.9.2") == be(10, 25, 9, 2), "队号地址")
}

func socketCompatAddressTests() {
    guard var addr = SocketCompat.address("192.168.1.50", port: 61592) else {
        check(false, "数字 IPv4 + 端口必须可构造")
        return
    }
    check(SocketCompat.ipString(of: &addr) == "192.168.1.50", "ipString 回写")
    check(SocketCompat.port(of: addr) == 61592, "端口主机序回读（>1024 含高低字节）")
    check(SocketCompat.hostOrderAddress(of: &addr) == 0xC0A8_0132, "主机序地址")
    check(Int(addr.sin_family) == Int(SocketCompat.afINET), "族为 AF_INET")
    check(SocketCompat.address("localhost", port: 1) == nil, "非数字字面量返回 nil（不做解析）")

    var any = SocketCompat.anyAddress(port: 1150)
    check(SocketCompat.ipString(of: &any) == "0.0.0.0" && SocketCompat.port(of: any) == 1150, "anyAddress")
    var loopback = SocketCompat.loopbackAddress(port: 1740)
    check(SocketCompat.ipString(of: &loopback) == "127.0.0.1" && SocketCompat.port(of: loopback) == 1740,
          "loopbackAddress 为 127.0.0.1（不是 1.0.0.127）")
}

/// 主机名解析为 IPv4 点分字面量列表，三平台同一调用面（DSClient 的 mDNS 解析只经这里）：
/// 数字字面量原样返回；localhost 解析到回环；空名字解析失败返回空（不触网，离线也稳定）。
/// Darwin / Linux 用 getaddrinfo，Windows 用宽字符版 GetAddrInfoW / FreeAddrInfoW。
/// 修复前 RED：解析分支直接写在 DSClient 里，Windows 分支调用的 getaddrinfoA 根本不在 WinSDK 模块里
///（首次真实 Windows 运行 45349581329：`cannot find 'getaddrinfoA' in scope`）。
func socketCompatResolveHostTests() {
    check(SocketCompat.resolveIPv4Hosts("127.0.0.1") == ["127.0.0.1"], "数字字面量原样返回")
    let loopback = SocketCompat.resolveIPv4Hosts("localhost")
    check(loopback.contains("127.0.0.1"), "localhost 解析到回环（得到 \(loopback)）")
    check(loopback.allSatisfy { SocketCompat.parseIPv4($0) != nil }, "结果只含 IPv4 点分字面量")
    check(SocketCompat.resolveIPv4Hosts("").isEmpty, "空名字解析失败返回空")
}

func openStepStringsTableTests() {
    let table = OpenStepStringsTable.parse("""
    /* 块注释 "key" = "not an entry"; */
    // 行注释
    "使能" = "Enable";
    "换行\\n引号\\"反斜杠\\\\制表\\t" = "Line1\\nLine2 \\"quoted\\" \\\\ \\u4e2d";
    "空值" = "";
    "unquoted_key" = bare_value;
    "坏条目缺分号" = "x"
    "缺等号" ;
    "未闭合 = "value";
    "重复" = "first";
    "重复" = "last";
    "a = b" = "c = d";
    """)
    check(table["使能"] == "Enable", "基本条目")
    check(table["换行\n引号\"反斜杠\\制表\t"] == "Line1\nLine2 \"quoted\" \\ 中", "键与值的转义序列（含 \\uXXXX）")
    check(table["空值"] == "", "空字符串值")
    check(table["unquoted_key"] == "bare_value", "未加引号的键值")
    check(table["a = b"] == "c = d", "引号内的 = 不当作分隔符")
    check(table["重复"] == "last", "重复键取后者")
    check(table["坏条目缺分号"] == "x", "缺分号的条目容忍入表（解析器不做严格校验）")
    check(table["缺等号"] == nil && table["未闭合 = "] == nil,
          "缺等号/无值的条目不入表：\(table.keys.sorted())")
    check(table.count == 7, "恰好 7 个合法条目（得到 \(table.count)）")
}

func settingsStoreTypeKindTests() {
    let name = "matchsticks-ds-kind-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = SettingsStore(defaults: defaults, prefix: "kind.")

    store.set("n", 1)
    check(store.integer("n") == 1, "整数按整数读")
    check(store.bool("n") == nil, "整数 1 不按布尔读")
    check(store.double("n") == 1, "整数可按浮点读")
    check(store.string("n") == nil, "整数不按字符串读")

    store.set("b", true)
    check(store.bool("b") == true, "布尔按布尔读")
    check(store.integer("b") == nil, "布尔不按整数读")
    check(store.double("b") == nil, "布尔不按浮点读")

    store.set("d", 2.5)
    check(store.double("d") == 2.5, "浮点按浮点读")
    check(store.integer("d") == nil, "浮点不按整数读（避免截断）")
    check(store.bool("d") == nil, "浮点不按布尔读")

    store.set("s", "7")
    check(store.string("s") == "7", "字符串按字符串读")
    check(store.integer("s") == nil && store.double("s") == nil && store.bool("s") == nil,
          "字符串不按数字/布尔读")

    store.set("big", 1234)
    check(store.integer("big") == 1234 && store.double("big") == 1234, "往返整数")
}

/// 只经 SocketCompat 的回环往返：UDP 收发 + 非阻塞 TCP connect 等待 + SO_ERROR 分类
func socketCompatLoopbackRoundTripTests() {
    let udp = SocketCompat.udpSocket()
    check(udp >= 0, "UDP 套接字创建")
    guard udp >= 0 else { return }
    defer { SocketCompat.closeSocket(udp) }
    check(SocketCompat.setReceiveTimeout(udp, seconds: 1), "UDP 接收超时设置")
    var local = SocketCompat.anyAddress(port: 0)
    check(SocketCompat.bindSocket(udp, &local) == 0, "UDP 绑定临时端口（errno \(SocketCompat.lastError)）")
    guard var bound = SocketCompat.localAddress(udp) else {
        check(false, "UDP getsockname")
        return
    }
    check(SocketCompat.port(of: bound) != 0, "内核分配了端口")
    check(SocketCompat.ipString(of: &bound) == "0.0.0.0", "任意地址回读")

    var dest = SocketCompat.loopbackAddress(port: SocketCompat.port(of: bound))
    let payload = Data([0x4D, 0x53, 0x44, 0x53])
    check(SocketCompat.sendDatagram(udp, payload, &dest) == payload.count, "UDP 回环发送")
    var source = sockaddr_in()
    var buffer = [UInt8](repeating: 0, count: 16)
    let n = SocketCompat.receiveFrom(udp, &buffer, buffer.count, &source)
    check(n == payload.count && Array(buffer[0..<n]) == Array(payload), "UDP 回环接收内容")
    check(SocketCompat.ipString(of: &source) == "127.0.0.1", "来源地址回环")
    check(SocketCompat.port(of: source) != 0, "来源端口非零")

    // 非阻塞 connect：回环监听
    let listener = SocketCompat.tcpSocket()
    guard listener >= 0 else { check(false, "TCP 监听创建"); return }
    defer { SocketCompat.closeSocket(listener) }
    check(SocketCompat.setReuseAddress(listener), "TCP SO_REUSEADDR")
    var listenAddr = SocketCompat.loopbackAddress(port: 0)
    check(SocketCompat.bindSocket(listener, &listenAddr) == 0, "TCP 监听绑定")
    check(SocketCompat.listenSocket(listener, backlog: 4) == 0, "TCP listen")
    guard let listenLocal = SocketCompat.localAddress(listener) else {
        check(false, "TCP getsockname")
        return
    }
    let client = SocketCompat.tcpSocket()
    guard client >= 0 else { check(false, "TCP 客户端创建"); return }
    defer { SocketCompat.closeSocket(client) }
    check(SocketCompat.setNonBlocking(client), "TCP 非阻塞")
    var server = SocketCompat.loopbackAddress(port: SocketCompat.port(of: listenLocal))
    let rc = SocketCompat.connectSocket(client, &server)
    if rc != 0 {
        check(SocketCompat.connectPending(SocketCompat.lastError),
              "非阻塞 connect 返回 in-progress（得到 \(SocketCompat.lastError)）")
    }
    check(SocketCompat.waitForConnect(client, timeoutMs: 1000) == .ready, "connect 等待就绪")
    check(SocketCompat.getSocketError(client) == 0, "SO_ERROR 为 0")
    let accepted = SocketCompat.acceptSocket(listener)
    check(accepted >= 0, "accept 回环连接")
    if accepted >= 0 {
        check(SocketCompat.getSocketError(client) == 0, "accept 后 SO_ERROR 仍为 0")
        SocketCompat.closeSocket(accepted)
    }

    // 无效句柄分类
    check(SocketCompat.bindSocket(SocketCompat.invalidHandle, &local) != 0, "无效句柄 bind 失败")
    check(SocketCompat.localAddress(SocketCompat.invalidHandle) == nil, "无效句柄 getsockname 返回 nil")
    check(SocketCompat.acceptSocket(SocketCompat.invalidHandle) < 0, "无效句柄 accept 失败")
}

/// 同地址同端口必须独占：两个都经 setReuseAddress 配置的套接字，第二个绑定同一回环端口必须失败
///（macOS：BSD 无 SO_REUSEPORT 不共享；Windows：SO_EXCLUSIVEADDRUSE 取代会「强绑成功、行为不确定」的 SO_REUSEADDR；
/// Linux UDP：不设 SO_REUSEADDR，否则内核允许两者重复绑定）。DS 固定绑定 UDP 1150「被占即失败」的不变量依赖这一点。
/// 修复前在 Windows（UDP+TCP）与 Linux（UDP）为 RED——两边第二个 bind 都返回 0。
func socketCompatExclusiveBindTests() {
    let first = SocketCompat.udpSocket()
    guard first >= 0 else { check(false, "UDP 首个套接字创建"); return }
    defer { SocketCompat.closeSocket(first) }
    check(SocketCompat.setReuseAddress(first), "UDP setReuseAddress")
    var addr = SocketCompat.loopbackAddress(port: 0)
    check(SocketCompat.bindSocket(first, &addr) == 0, "UDP 首个绑定")
    guard let local = SocketCompat.localAddress(first) else { check(false, "UDP getsockname"); return }
    let udpPort = SocketCompat.port(of: local)

    let second = SocketCompat.udpSocket()
    guard second >= 0 else { check(false, "UDP 第二个套接字创建"); return }
    defer { SocketCompat.closeSocket(second) }
    check(SocketCompat.setReuseAddress(second), "UDP 第二个 setReuseAddress")
    var sameUDP = SocketCompat.loopbackAddress(port: udpPort)
    check(SocketCompat.bindSocket(second, &sameUDP) != 0,
          "第二个 UDP 套接字绑定同一回环端口必须失败（得到 0，errno \(SocketCompat.lastError)）")

    let listener = SocketCompat.tcpSocket()
    guard listener >= 0 else { check(false, "TCP 监听创建"); return }
    defer { SocketCompat.closeSocket(listener) }
    check(SocketCompat.setReuseAddress(listener), "TCP setReuseAddress")
    var listenAddr = SocketCompat.loopbackAddress(port: 0)
    check(SocketCompat.bindSocket(listener, &listenAddr) == 0, "TCP 监听绑定")
    check(SocketCompat.listenSocket(listener, backlog: 1) == 0, "TCP listen")
    guard let listenLocal = SocketCompat.localAddress(listener) else { check(false, "TCP getsockname"); return }
    let secondListener = SocketCompat.tcpSocket()
    guard secondListener >= 0 else { check(false, "TCP 第二个监听创建"); return }
    defer { SocketCompat.closeSocket(secondListener) }
    check(SocketCompat.setReuseAddress(secondListener), "TCP 第二个 setReuseAddress")
    var sameListen = SocketCompat.loopbackAddress(port: SocketCompat.port(of: listenLocal))
    check(SocketCompat.bindSocket(secondListener, &sameListen) != 0,
          "第二个 TCP 监听绑定同一回环端口必须失败（得到 0，errno \(SocketCompat.lastError)）")
}

/// UDP 套接字向「无监听的回环端口」发过一个包之后，receiveFrom 必须表现为「暂无数据」（wouldBlock）而非硬错误，
/// 且套接字仍可自发自收。Windows 默认把 ICMP port unreachable 以 WSAECONNRESET 报在 recvfrom 上（修复前 RED）；
/// udpSocket() 关闭该行为后三平台一致。
func socketCompatUDPPortUnreachableTests() {
    let sock = SocketCompat.udpSocket()
    guard sock >= 0 else { check(false, "UDP 套接字创建"); return }
    defer { SocketCompat.closeSocket(sock) }
    check(SocketCompat.setReceiveTimeout(sock, seconds: 0, microseconds: 300_000), "接收超时 0.3s")
    var local = SocketCompat.loopbackAddress(port: 0)
    check(SocketCompat.bindSocket(sock, &local) == 0, "绑定回环临时端口")
    guard let own = SocketCompat.localAddress(sock) else { check(false, "getsockname"); return }
    let ownPort = SocketCompat.port(of: own)

    // 无监听端口：绑定一个临时套接字拿到内核分配的空闲端口，随即关闭
    let probe = SocketCompat.udpSocket()
    var probeAddr = SocketCompat.loopbackAddress(port: 0)
    _ = SocketCompat.bindSocket(probe, &probeAddr)
    guard let probeLocal = SocketCompat.localAddress(probe) else {
        SocketCompat.closeSocket(probe); check(false, "探测端口"); return
    }
    let closedPort = SocketCompat.port(of: probeLocal)
    SocketCompat.closeSocket(probe)

    var dead = SocketCompat.loopbackAddress(port: closedPort)
    check(SocketCompat.sendDatagram(sock, Data([0x01]), &dead) == 1, "向无监听端口发送")
    Thread.sleep(forTimeInterval: 0.05)
    var source = SocketCompat.emptyAddress()
    var buffer = [UInt8](repeating: 0, count: 8)
    let n = SocketCompat.receiveFrom(sock, &buffer, buffer.count, &source)
    let code = SocketCompat.lastError
    check(n < 0 && SocketCompat.wouldBlock(code),
          "无应答时 receiveFrom 应为「暂无数据」（n=\(n) errno \(code)），不得是连接重置等硬错误")

    var selfAddr = SocketCompat.loopbackAddress(port: ownPort)
    check(SocketCompat.sendDatagram(sock, Data([0x02, 0x03]), &selfAddr) == 2, "之后仍可自发")
    let got = SocketCompat.receiveFrom(sock, &buffer, buffer.count, &source)
    check(got == 2 && buffer[0] == 0x02 && buffer[1] == 0x03, "之后仍可自收（n=\(got)）")
}

// MARK: 平台边界守卫（静态）：DSCore 里除 SocketCompat.swift 外不得直接调用套接字 C API
//
// 三平台差异全部收口在 SocketCompat。绕过它的直接调用在 macOS 上照样编译、照样通过，却会在 Windows 上
// 编译失败或行为错误——例如对 boundedTCPConnect 返回的已连接套接字调 C close()，Windows 必须用
// closesocket。本机编译不了 Windows 分支，这条守卫在 Mac / Linux / Windows 上都能执行。
// 有意保留的直接调用只剩 getifaddrs（DirectInterface，接口枚举），见 docs/decisions/0005-portable-dscore-validation.md。
// 主机名解析（getaddrinfo / GetAddrInfoW）同样收口在 SocketCompat.resolveIPv4Hosts：Windows 上 WinSDK 模块
// 不导入 getaddrinfoA（2026-11-24 首次真实 Windows 运行实测），业务文件里的解析分支既编不过也不该存在。
// 修复前 RED：DSClient.swift 对已连接 TCP 套接字调 close(fd)；其后 DSClient.swift 直接调 getaddrinfo。

func socketCompatBoundaryTests() {
    let sourcesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/DSCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // 包根
        .appendingPathComponent("Sources/DSCore")
    let files = ((try? FileManager.default.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "SocketCompat.swift" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    check(!files.isEmpty, "定位到 Sources/DSCore 源文件（\(files.count) 个，不含 SocketCompat.swift）")
    guard !files.isEmpty else { return }

    // C 函数调用 = 名字前面不是 `.` 或标识符字符（排除 Swift 方法调用，如 WebUIServer.send(…)）
    let socketAPIs = ["socket", "bind", "listen", "accept", "connect", "recv", "recvfrom", "send", "sendto",
                      "shutdown", "setsockopt", "getsockopt", "getsockname", "getpeername", "fcntl", "poll",
                      "inet_pton", "inet_ntop", "if_nametoindex", "WSAStartup", "closesocket", "ioctlsocket",
                      "__darwin_fd_set", "getaddrinfo", "getaddrinfoA", "freeaddrinfo", "freeaddrinfoA",
                      "GetAddrInfoW", "FreeAddrInfoW"]
    let patterns = [
        "(^|[^.A-Za-z0-9_])(\(socketAPIs.joined(separator: "|")))\\s*\\(",
        // C close(fd)：带一个标识符参数；本模块的 Swift close() 方法都不带参数（第 2 组 = 函数名，与上一条一致）
        "(^|[^.A-Za-z0-9_])(close)\\s*\\(\\s*[A-Za-z_][A-Za-z0-9_]*\\s*\\)",
    ]
    let regexes = patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    check(regexes.count == patterns.count, "守卫正则可编译")
    guard regexes.count == patterns.count else { return }

    var violations: [String] = []
    for file in files {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            violations.append("\(file.lastPathComponent): 无法读取")
            continue
        }
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let code: Substring
            if let comment = line.range(of: "//") { code = line[..<comment.lowerBound] } else { code = line[...] }
            let base = String(code)
            for regex in regexes {
                for match in regex.matches(in: base, range: NSRange(base.startIndex..., in: base)) {
                    guard let whole = Range(match.range(at: 1), in: base),
                          let name = Range(match.range(at: 2), in: base) else { continue }
                    let before = base[..<whole.lowerBound].trimmingCharacters(in: .whitespaces)
                    if before.hasSuffix("func") { continue }   // Swift 方法声明，不是 C 调用
                    violations.append("\(file.lastPathComponent):\(index + 1): \(base[name.lowerBound...].prefix(60))")
                }
            }
        }
    }
    check(violations.isEmpty,
          violations.isEmpty ? "DSCore 除 SocketCompat.swift 外没有直接的套接字 C 调用"
                             : "以下位置绕过了 SocketCompat（Windows 上会编译失败或行为错误）：\(violations)")
}

#if os(Windows)
// 临时诊断（2026-11-24，定位后移除）：首次真实 Windows 运行里，连接「已关闭的回环端口」被判成 timedOut 而不是
// refused（OM5PReadinessTests / Phase2Tests.radioProbeTests / tcpPositiveScenario 共 5 项失败）。这里把非阻塞 connect
// 之后每一步的真实返回值打进日志：select 的结果与集合计数、SO_ERROR、WSAPoll、再次 connect 的错误码。
func windowsConnectRefusedProbeTests() {
    let dead = SocketCompat.tcpSocket()
    var anyAddr = SocketCompat.anyAddress(port: 0)
    _ = SocketCompat.bindSocket(dead, &anyAddr)
    _ = SocketCompat.listenSocket(dead, backlog: 4)
    guard let local = SocketCompat.localAddress(dead) else {
        print("probe: getsockname failed \(SocketCompat.lastError)")
        SocketCompat.closeSocket(dead)
        return
    }
    let port = SocketCompat.port(of: local)
    SocketCompat.closeSocket(dead)

    let fd = SocketCompat.tcpSocket()
    _ = SocketCompat.setNonBlocking(fd)
    var target = SocketCompat.loopbackAddress(port: port)
    let rc = SocketCompat.connectSocket(fd, &target)
    print("probe: connect rc=\(rc) lastError=\(SocketCompat.lastError)")
    let raw = SOCKET(UInt(UInt32(bitPattern: fd)))
    for index in 0..<6 {
        var writeSet = fd_set()
        var errorSet = fd_set()
        writeSet.fd_count = 1
        writeSet.fd_array.0 = raw
        errorSet.fd_count = 1
        errorSet.fd_array.0 = raw
        var wait = timeval(tv_sec: 0, tv_usec: 300_000)
        let selected = select(0, nil, &writeSet, &errorSet, &wait)
        print("probe[\(index)]: select rc=\(selected) write=\(writeSet.fd_count) except=\(errorSet.fd_count) " +
              "lastError=\(SocketCompat.lastError) soError=\(String(describing: SocketCompat.getSocketError(fd)))")
        if selected > 0 { break }
    }
    var pollDescriptor = WSAPOLLFD(fd: raw, events: Int16(POLLOUT), revents: 0)
    let polled = WSAPoll(&pollDescriptor, 1, 300)
    print("probe: WSAPoll rc=\(polled) revents=\(pollDescriptor.revents) " +
          "POLLOUT=\(POLLOUT) POLLERR=\(POLLERR) POLLHUP=\(POLLHUP)")
    let again = SocketCompat.connectSocket(fd, &target)
    print("probe: connect again rc=\(again) lastError=\(SocketCompat.lastError)")
    SocketCompat.closeSocket(fd)
}
#endif
