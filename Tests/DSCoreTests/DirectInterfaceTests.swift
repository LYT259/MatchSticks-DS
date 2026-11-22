// MARK: 直连出口选择（Clash Verge TUN 全模式）：纯函数选路 + 真实 lo0 绑定/清除

import Darwin
import Foundation
import DSCore

private func directIPv4(_ string: String) -> UInt32 {
    var value: UInt32 = 0
    for part in string.split(separator: ".") {
        value = (value << 8) | (UInt32(part) ?? 0)
    }
    return value
}

private func directCandidate(_ name: String, _ index: UInt32, _ address: String, _ netmask: String,
                             up: Bool = true, loopback: Bool = false) -> DirectInterface.Candidate {
    DirectInterface.Candidate(name: name, index: index,
                              address: directIPv4(address), netmask: directIPv4(netmask),
                              isUp: up, isLoopback: loopback)
}

func directInterfaceSelectionTests() {
    let lo0 = directCandidate("lo0", 1, "127.0.0.1", "255.0.0.0", loopback: true)
    let lo1 = directCandidate("lo1", 2, "127.0.0.1", "255.0.0.0", loopback: true)
    let wired = directCandidate("en0", 4, "10.1.2.100", "255.255.255.0")
    let wiredDown = directCandidate("en2", 5, "10.1.2.60", "255.255.255.0", up: false)
    let wifi = directCandidate("en1", 6, "192.168.1.50", "255.255.255.0")
    let usb = directCandidate("en7", 15, "192.168.7.2", "255.255.255.0")
    let wide = directCandidate("en8", 16, "172.16.5.10", "255.255.240.0")
    let clashTun = directCandidate("utun6", 20, "198.18.0.1", "255.255.0.0")
    let robotTun = directCandidate("utun3", 21, "10.1.2.50", "255.255.255.0")
    let pool = [lo0, wired, wifi, usb, wide, wiredDown, clashTun, robotTun]

    check(DirectInterface.select(target: "10.1.2.2", candidates: pool) == wired,
          "有线同子网命中 en0")
    check(DirectInterface.select(target: "192.168.1.77", candidates: pool) == wifi,
          "Wi-Fi 同子网命中 en1")
    check(DirectInterface.select(target: "192.168.7.44", candidates: pool) == usb,
          "USB 网卡同子网命中 en7")
    check(DirectInterface.select(target: "198.18.0.5", candidates: [clashTun]) == nil,
          "utun（Clash TUN）即便同子网也排除")
    check(DirectInterface.select(target: "10.1.2.2", candidates: [robotTun, wiredDown]) == nil,
          "同子网只有 utun/未启用接口时返回 nil")
    check(DirectInterface.select(target: "10.1.2.2", candidates: [wiredDown, wired]) == wired,
          "已启用接口优先于 down 接口")
    check(DirectInterface.select(target: "10.1.2.2", candidates: [wiredDown]) == nil,
          "只有 down 接口时返回 nil")

    for name in ["utun0", "ipsec0", "ppp0", "gif0", "stf0", "awdl0", "llw0", "nan0"] {
        let virtual = directCandidate(name, 30, "10.9.8.10", "255.255.255.0")
        check(DirectInterface.select(target: "10.9.8.42", candidates: [virtual]) == nil,
              "虚拟接口 \(name) 排除")
    }

    check(DirectInterface.select(target: "172.16.10.20", candidates: [wide]) == wide,
          "/20 掩码跨第三段命中")
    check(DirectInterface.select(target: "172.16.32.1", candidates: [wide]) == nil,
          "/20 掩码外不命中")
    check(DirectInterface.select(target: "10.1.3.2", candidates: [wired]) == nil,
          "/24 掩码外不命中")

    let pointToPoint = directCandidate("en9", 17, "169.254.1.2", "255.255.255.255")
    check(DirectInterface.select(target: "169.254.1.2", candidates: [pointToPoint]) == pointToPoint,
          "/32 掩码仅命中自身")
    check(DirectInterface.select(target: "169.254.1.3", candidates: [pointToPoint]) == nil,
          "/32 掩码不命中邻居地址")

    let zeroMask = directCandidate("en3", 7, "10.1.2.70", "0.0.0.0")
    let zeroAddress = directCandidate("en4", 8, "0.0.0.0", "255.255.255.0")
    check(DirectInterface.select(target: "10.1.2.2", candidates: [zeroMask, zeroAddress]) == nil,
          "零掩码/零地址候选不参与匹配")
    check(DirectInterface.select(target: "0.0.0.0", candidates: [zeroMask, zeroAddress, wired]) == nil,
          "0.0.0.0 不作为目标")

    let dupLower = directCandidate("en0", 4, "10.1.2.100", "255.255.255.0")
    let dupHigher = directCandidate("en3", 12, "10.1.2.101", "255.255.255.0")
    check(DirectInterface.select(target: "10.1.2.2", candidates: [dupHigher, dupLower]) == dupLower,
          "同前缀多接口按索引取小（候选顺序无关）")
    check(DirectInterface.select(target: "10.1.2.2", candidates: [dupLower, dupHigher]) == dupLower,
          "同前缀多接口结果与候选顺序无关")
    for _ in 0..<8 {
        check(DirectInterface.select(target: "10.1.2.2", candidates: [dupHigher, dupLower]) == dupLower,
              "重复调用选择稳定")
    }

    let broad = directCandidate("en0", 4, "10.1.0.10", "255.255.0.0")
    let narrow = directCandidate("en1", 6, "10.1.2.50", "255.255.255.0")
    check(DirectInterface.select(target: "10.1.2.9", candidates: [broad, narrow]) == narrow,
          "多前缀命中时选最长前缀（不受索引影响）")
    check(DirectInterface.select(target: "10.1.2.9", candidates: [narrow, broad]) == narrow,
          "最长前缀选择与候选顺序无关")

    check(DirectInterface.select(target: "127.0.0.1", candidates: [wired, lo1, lo0]) == lo0,
          "回环目标选 lo0（优先于其他回环候选）")
    check(DirectInterface.select(target: "127.8.9.10", candidates: [lo1, lo0]) == lo0,
          "整个 127/8 都走 lo0")
    check(DirectInterface.select(target: "127.0.0.1", candidates: [wired]) == nil,
          "无回环候选时回环目标返回 nil")
    let fakePhysical = directCandidate("en9", 18, "127.0.0.5", "255.0.0.0")
    check(DirectInterface.select(target: "127.0.0.9", candidates: [fakePhysical]) == nil,
          "回环目标不落到非回环接口")

    let localWired = directCandidate("en0", 4, "192.168.1.10", "255.255.255.0")
    let localWifi = directCandidate("en1", 6, "192.168.1.20", "255.255.255.0")
    let localPool = [localWifi, localWired]
    check(DirectInterface.select(localAddress: directIPv4("192.168.1.20"), candidates: localPool) == localWifi,
          "本地地址精确命中 en1，不因同子网低索引误选 en0")
    check(DirectInterface.select(localAddress: directIPv4("192.168.1.10"), candidates: localPool) == localWired,
          "本地地址精确命中 en0")
    check(DirectInterface.select(target: "192.168.1.99", candidates: localPool) == localWired,
          "对照：目标子网选择仍按低索引 en0")
    check(DirectInterface.select(localAddress: directIPv4("192.168.1.30"), candidates: localPool) == nil,
          "本机地址未配置时不按子网猜测")
    check(DirectInterface.select(localAddress: directIPv4("127.0.0.1"), candidates: [wired, lo0]) == lo0,
          "本地地址精确匹配支持回环")
    check(DirectInterface.select(localAddress: 0, candidates: localPool) == nil,
          "0.0.0.0 本地地址不匹配任何接口")
    let aliasA = directCandidate("en0", 4, "192.168.1.10", "255.255.255.0")
    let aliasB = directCandidate("en4", 10, "192.168.1.10", "255.255.255.0")
    check(DirectInterface.select(localAddress: directIPv4("192.168.1.10"),
                                 candidates: [aliasB, aliasA]) == aliasA,
          "同地址多候选按索引确定性选择")

    for bad in ["", "10.1.2", "10.1.2.2.5", "10.1.2.256", "10.1.2.-1",
                "10.1.2.a", " 10.1.2.2", "10.1.2.2:1110", "roborio-10-frc.local", "10.1.2.2."] {
        check(DirectInterface.select(target: bad, candidates: pool) == nil,
              "非数字 IPv4 字面量拒绝：\(bad)")
    }
}

private func directReceiverOnLoopback() -> (fd: Int32, port: UInt16)? {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return nil }
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    let bound = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { close(fd); return nil }

    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            getsockname(fd, sa, &length)
        }
    }
    guard named == 0 else { close(fd); return nil }
    return (fd, UInt16(bigEndian: addr.sin_port))
}

private func directWildcardListener() -> (fd: Int32, port: UInt16)? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = 0
    let bound = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, listen(fd, 1) == 0 else { close(fd); return nil }

    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            getsockname(fd, sa, &length)
        }
    }
    guard named == 0 else { close(fd); return nil }
    return (fd, UInt16(bigEndian: addr.sin_port))
}

func directInterfaceLoopbackBindingTests() {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    check(fd >= 0, "创建 UDP 套接字")
    guard fd >= 0 else { return }
    defer { close(fd) }

    let loIndex = if_nametoindex("lo0")
    check(loIndex != 0, "系统存在 lo0")
    check(DirectInterface.boundInterfaceIndex(fd: fd) == nil, "新套接字未绑定接口")

    let bound = DirectInterface.bind(fd: fd, target: "127.0.0.1")
    check(bound == .bound(name: "lo0", index: loIndex), "绑定 127.0.0.1 选中 lo0（得到 \(bound)）")
    check(DirectInterface.boundInterfaceIndex(fd: fd) == loIndex, "IP_BOUND_IF 回读 lo0 索引")

    if let receiver = directReceiverOnLoopback() {
        let payload: [UInt8] = [0x47, 0x48, 0x44, 0x53]
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = receiver.port.bigEndian
        dest.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let sent = withUnsafePointer(to: &dest) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                payload.withUnsafeBytes { raw in
                    sendto(fd, raw.baseAddress, raw.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        check(sent == payload.count, "绑定 lo0 后可向 127.0.0.1 发送（sent \(sent)）")

        var buffer = [UInt8](repeating: 0, count: 32)
        var source = sockaddr_in()
        var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let received = withUnsafeMutablePointer(to: &source) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(receiver.fd, &buffer, buffer.count, 0, sa, &sourceLength)
            }
        }
        if received == payload.count {
            check(Array(buffer[0..<received]) == payload, "回环接收内容一致")
        } else {
            check(false, "回环接收字节数（got \(received)）")
        }
        close(receiver.fd)
    } else {
        check(false, "创建 127.0.0.1 接收套接字")
    }

    let noMatch = DirectInterface.bind(fd: fd, target: "0.0.0.0")
    check(noMatch == .noMatch, "无匹配返回 .noMatch（得到 \(noMatch)）")
    check(DirectInterface.boundInterfaceIndex(fd: fd) == nil, "无匹配时清除旧绑定")

    let rebound = DirectInterface.bind(fd: fd, target: "127.8.9.10")
    check(rebound == .bound(name: "lo0", index: loIndex), "127/8 重新绑定 lo0")
    check(DirectInterface.boundInterfaceIndex(fd: fd) == loIndex, "重新绑定回读 lo0")
    let invalid = DirectInterface.bind(fd: fd, target: "not-an-ip")
    check(invalid == .noMatch, "非法目标返回 .noMatch（得到 \(invalid)）")
    check(DirectInterface.boundInterfaceIndex(fd: fd) == nil, "非法目标也清除旧绑定")

    check(DirectInterface.bind(fd: -1, target: "127.0.0.1") == .failed(errno: EBADF),
          "无效 fd 返回 EBADF")
    check(DirectInterface.boundInterfaceIndex(fd: -1) == nil, "无效 fd 回读返回 nil")

    if let listener = directWildcardListener() {
        let client = socket(AF_INET, SOCK_STREAM, 0)
        check(client >= 0, "创建回环 TCP 客户端")
        if client >= 0 {
            var dest = sockaddr_in()
            dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            dest.sin_family = sa_family_t(AF_INET)
            dest.sin_port = listener.port.bigEndian
            dest.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
            let connected = withUnsafePointer(to: &dest) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(client, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            check(connected == 0, "回环 TCP 连接建立")
            if connected == 0 {
                let accepted = accept(listener.fd, nil, nil)
                check(accepted >= 0, "accept 回环 TCP 连接")
                if accepted >= 0 {
                    check(DirectInterface.boundInterfaceIndex(fd: accepted) == nil,
                          "accepted 套接字初始未绑定接口")
                    let result = DirectInterface.bindAccepted(fd: accepted)
                    check(result == .bound(name: "lo0", index: loIndex),
                          "accepted 本机 127.0.0.1 精确绑定 lo0（得到 \(result)）")
                    check(DirectInterface.boundInterfaceIndex(fd: accepted) == loIndex,
                          "accepted 套接字 IP_BOUND_IF 回读 lo0")
                    close(accepted)
                }
            }
            close(client)
        }
        close(listener.fd)
    } else {
        check(false, "创建回环 TCP 监听套接字")
    }

    let wildcard = socket(AF_INET, SOCK_DGRAM, 0)
    check(wildcard >= 0, "创建未绑定 UDP 套接字")
    if wildcard >= 0 {
        let prebound = DirectInterface.bind(fd: wildcard, target: "127.0.0.1")
        check(prebound == .bound(name: "lo0", index: loIndex),
              "未绑定 UDP 先人为绑定 lo0（得到 \(prebound)）")
        check(DirectInterface.boundInterfaceIndex(fd: wildcard) == loIndex,
              "人为绑定后回读 lo0")
        let result = DirectInterface.bindAccepted(fd: wildcard)
        check(result == .noMatch, "未绑定套接字本地 0.0.0.0 返回 .noMatch（得到 \(result)）")
        check(DirectInterface.boundInterfaceIndex(fd: wildcard) == nil,
              "bindAccepted 无匹配时清除旧绑定")
        close(wildcard)
    }

    let notSocket = open("/dev/null", O_RDONLY)
    check(notSocket >= 0, "打开 /dev/null 获取非套接字 fd")
    if notSocket >= 0 {
        let result = DirectInterface.bindAccepted(fd: notSocket)
        check(result == .failed(errno: ENOTSOCK),
              "非套接字 getsockname 失败返回 ENOTSOCK（得到 \(result)）")
        close(notSocket)
    }

    check(DirectInterface.bindAccepted(fd: -1) == .failed(errno: EBADF),
          "bindAccepted 无效 fd 返回 EBADF")
}
