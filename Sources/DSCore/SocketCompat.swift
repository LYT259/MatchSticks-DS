import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif

// MARK: - 跨平台套接字薄层（Darwin / Linux / Windows 共用一套调用面）
//
// DSCore 的 UDP/TCP 服务器与 DSCoreTests 原先直接写 BSD 调用；三平台差异全部收口到这里：
// - 句柄统一 Int32：Windows 的 SOCKET 句柄按 Winsock 惯例可在 32 位内无损往返，
//   INVALID_SOCKET 映射为 -1，与 POSIX 的 `fd < 0` 约定一致；
// - 错误码：POSIX 读 errno，Windows 读 WSAGetLastError（WSAE* 码值不同，常量经本层取用）；
// - 非阻塞：POSIX fcntl(O_NONBLOCK)，Windows ioctlsocket(FIONBIO)；
// - connect 等待：Darwin 用 select 写/异常集合（poll 在 macOS 上对 RST 不可靠，见 DSClient 注释），
//   Linux 用 poll，Windows 用 WSAPoll（Winsock 的 select 在 windows-2025-vs2026 上对 connect 完成从不置位）；
// - SIGPIPE：Linux 的 send 带 MSG_NOSIGNAL；Darwin/Windows 无此语义，行为保持不变；
// - 数字地址解析/格式化用纯 Swift，IPv4 文法与 inet_pton 一致（允许前导零、拒绝 >255）；
//   主机名解析（DSClient 的 mDNS）经 resolveIPv4Hosts：Darwin / Linux 用 getaddrinfo，
//   Windows 用宽字符版 GetAddrInfoW / FreeAddrInfoW（getaddrinfoA 是宏别名，WinSDK 模块不导入）；
// - 接口绑定（IP_BOUND_IF）只在 Darwin 实现，Linux 用 SO_BINDTOIFINDEX；Windows 不实现
//   （该特性用于排除 macOS 的 Clash TUN 虚拟网卡，Windows 按系统路由）——三平台各有编译分支，
//   Windows 分支不落入 Darwin 分支；
// - 可变参数的 C 函数（_open 等）Swift 不导入：打开空设备改用定参的 _sopen_s；
// - 「可重绑但不共享」的绑定语义三平台对齐（见 setReuseAddress）：DS 固定绑定 UDP 1150、被占即失败的不变量
//   在 Windows 上不能靠 SO_REUSEADDR（它允许任意无特权进程强绑已占用端口），改用 SO_EXCLUSIVEADDRUSE。
//
// Windows 常量导入说明：Swift 的 ClangImporter 只保证导入「纯整数字面量/简单表达式」的 C 宏；
// WinSDK 里 FIONBIO（_IOW(...) 含 sizeof）、SO_EXCLUSIVEADDRUSE（(int)(~SO_REUSEADDR)）、SD_BOTH、
// SIO_UDP_CONNRESET 等以函数式或带转换的宏定义，不保证能导入，本层按 SDK 头文件的值写字面量。
//
// 方法名刻意避开 C 全局函数名（bind/send/recv/close…）：同名静态方法会在 enum 内遮蔽 C 函数。

public enum SocketCompat {

    public typealias Handle = Int32
    public static let invalidHandle: Int32 = -1
    /// AF_INET（套接字族常量，供调用方比较 sin_family）
    public static let afINET: Int32 = AF_INET

    #if os(Windows)
    public typealias SocketLength = Int32
    public typealias Family = ADDRESS_FAMILY
    #else
    public typealias SocketLength = socklen_t
    public typealias Family = sa_family_t
    #endif

    // MARK: 常量

    #if os(Windows)
    public static let ebadf = WSAEBADF
    public static let enotsock = WSAENOTSOCK
    public static let einval = WSAEINVAL
    /// 通用 I/O 错误：Winsock 无 WSAEIO，测试脚本注入的 EIO 码值原样透传
    public static let eio = EIO
    public static let eintr = WSAEINTR
    public static let einprogress = WSAEINPROGRESS
    public static let ewouldblock = WSAEWOULDBLOCK
    public static let econnrefused = WSAECONNREFUSED
    public static let enetunreach = WSAENETUNREACH
    public static let ehostunreach = WSAEHOSTUNREACH
    public static let etimedout = WSAETIMEDOUT
    public static let enoprotoopt = WSAENOPROTOOPT
    public static let eopnotsupp = WSAEOPNOTSUPP
    public static let eaddrinuse = WSAEADDRINUSE
    public static let eacces = WSAEACCES
    public static let eafnosupport = WSAEAFNOSUPPORT
    #else
    public static let ebadf = EBADF
    public static let enotsock = ENOTSOCK
    public static let einval = EINVAL
    public static let eio = EIO
    public static let eintr = EINTR
    public static let einprogress = EINPROGRESS
    public static let ewouldblock = EWOULDBLOCK
    public static let econnrefused = ECONNREFUSED
    public static let enetunreach = ENETUNREACH
    public static let ehostunreach = EHOSTUNREACH
    public static let etimedout = ETIMEDOUT
    public static let enoprotoopt = ENOPROTOOPT
    public static let eopnotsupp = EOPNOTSUPP
    public static let eaddrinuse = EADDRINUSE
    public static let eacces = EACCES
    public static let eafnosupport = EAFNOSUPPORT
    public static let eagain = EAGAIN
    #endif

    /// 非阻塞 connect 已被内核接受（POSIX EINPROGRESS；Windows 返回 WSAEWOULDBLOCK）
    public static func connectPending(_ code: Int32) -> Bool {
        code == einprogress || code == ewouldblock
    }

    /// 非阻塞 recv/send 的「暂无数据/缓冲暂满」。
    /// Windows 上另含带 SO_RCVTIMEO 的阻塞接收到期：Winsock 报 WSAETIMEDOUT，而 POSIX 同一场合是 EAGAIN
    ///（不对齐的话「对端无应答」在 Windows 会被当成连接重置一类的硬错误）。
    public static func wouldBlock(_ code: Int32) -> Bool {
        #if os(Windows)
        return code == ewouldblock || code == etimedout
        #else
        return code == eagain || code == ewouldblock
        #endif
    }

    /// 最近一次套接字调用的错误码（POSIX errno / Windows WSAGetLastError）
    public static var lastError: Int32 {
        #if os(Windows)
        return WSAGetLastError()
        #else
        return errno
        #endif
    }

    // MARK: 生命周期

    public static func udpSocket() -> Int32 {
        #if os(Windows)
        let fd = makeSocket(type: datagramSocketType)
        guard fd >= 0 else { return fd }
        // 关闭 Winsock 默认行为「对端端口不可达（ICMP port unreachable）→ 下一次 recvfrom 报 WSAECONNRESET」，
        // 使 UDP 接收失败分类与 POSIX 一致（暂无数据/超时），DS 控制环与测试桩不会把它当成硬错误。
        var disable: Int32 = 0
        var returned: UInt32 = 0
        _ = WSAIoctl(socketHandle(fd), windowsSIO_UDP_CONNRESET, &disable,
                     UInt32(MemoryLayout<Int32>.size), nil, 0, &returned, nil, nil)
        return fd
        #else
        return makeSocket(type: datagramSocketType)
        #endif
    }
    public static func tcpSocket() -> Int32 { makeSocket(type: streamSocketType) }

    /// Winsock 初始化（Windows：WSAStartup 2.2，进程内幂等、线程安全；其余平台空操作）。
    /// 任何不经本层创建套接字而直接调用 Winsock API（如 getaddrinfo）的代码，必须先调用本方法——
    /// 否则 Windows 上会得到 WSANOTINITIALISED。
    public static func ensureInitialized() {
        #if os(Windows)
        windowsStartup
        #endif
    }

    #if os(Windows)
    private static let windowsStartup: Void = {
        var data = WSADATA()
        _ = WSAStartup(WORD(0x0202), &data)
    }()

    /// WinSDK 里以函数式/带转换宏定义、Swift 不保证能导入的常量（值按 SDK 头文件）：
    /// - FIONBIO = _IOW('f', 126, u_long) = IOC_IN | (sizeof(u_long) << 16) | ('f' << 8) | 126（winsock.h）
    /// - SO_EXCLUSIVEADDRUSE = ((int)(~SO_REUSEADDR))，SO_REUSEADDR = 0x0004（ws2def.h）
    /// - SD_BOTH = 0x02（winsock2.h）
    /// - SIO_UDP_CONNRESET = IOC_IN | IOC_VENDOR | 12 = 0x80000000 | 0x18000000 | 12（mstcpip.h）
    private static let windowsFIONBIO: Int32 = Int32(bitPattern: 0x8004_667E)
    private static let windowsSO_EXCLUSIVEADDRUSE: Int32 = -5
    private static let windowsSD_BOTH: Int32 = 0x02
    private static let windowsSIO_UDP_CONNRESET: UInt32 = 0x9800_000C
    #endif

    private static let datagramSocketType = Int32(SOCK_DGRAM)
    private static let streamSocketType = Int32(SOCK_STREAM)

    private static func makeSocket(type: Int32) -> Int32 {
        #if os(Windows)
        ensureInitialized()
        let created = socket(AF_INET, type, 0)
        return created == SOCKET.max ? invalidHandle : handle(created)
        #else
        return socket(AF_INET, type, 0)
        #endif
    }

    public static func closeSocket(_ fd: Int32) {
        guard fd >= 0 else { return }
        #if os(Windows)
        _ = closesocket(socketHandle(fd))
        #else
        _ = close(fd)
        #endif
    }

    public static func shutdownReadWrite(_ fd: Int32) {
        guard fd >= 0 else { return }
        #if os(Windows)
        _ = shutdown(socketHandle(fd), windowsSD_BOTH)
        #else
        _ = shutdown(fd, Int32(SHUT_RDWR))
        #endif
    }

    /// 返回是否成功（与旧实现一致：调用方多数忽略失败）
    @discardableResult
    public static func setNonBlocking(_ fd: Int32) -> Bool {
        #if os(Windows)
        var mode: UInt32 = 1
        return ioctlsocket(socketHandle(fd), windowsFIONBIO, &mode) == 0
        #else
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return false }
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
        #endif
    }

    /// 「可重绑但不共享」语义（三平台对齐；返回是否设置成功）：
    /// - Windows：SO_EXCLUSIVEADDRUSE。Winsock 的 SO_REUSEADDR 允许任意无特权进程强绑已被占用的端口，
    ///   之后该端口上所有套接字的行为不确定（微软文档《Using SO_REUSEADDR and SO_EXCLUSIVEADDRUSE》），
    ///   会把「DS 固定绑定 UDP 1150、被占即失败」变成静默串包；独占选项让冲突绑定返回 WSAEADDRINUSE/WSAEACCES，
    ///   且本套接字不会被他人用 SO_REUSEADDR 劫持。TIME_WAIT 不影响 Windows 重绑。
    /// - Linux：UDP 不设选项——UDP 没有 TIME_WAIT，而内核允许两个都设 SO_REUSEADDR 的 UDP 套接字重复绑定
    ///   同地址同端口（单播只投给其一），与 DS 的独占要求相反；TCP 监听口设 SO_REUSEADDR 以便跨 TIME_WAIT 重绑
    ///   （LISTEN 状态的套接字之间不会重复绑定）。
    /// - macOS：SO_REUSEADDR（BSD 语义：无 SO_REUSEPORT 不能重复绑定同地址同端口，独占要求天然满足）。
    @discardableResult
    public static func setReuseAddress(_ fd: Int32) -> Bool {
        #if os(Windows)
        var exclusive: Int32 = 1
        return setsockopt(socketHandle(fd), SOL_SOCKET, windowsSO_EXCLUSIVEADDRUSE, &exclusive,
                          Int32(MemoryLayout<Int32>.size)) == 0
        #elseif os(Linux)
        guard !isDatagramSocket(fd) else { return true }
        var reuse: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0
        #else
        var reuse: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0
        #endif
    }

    #if os(Linux)
    private static func isDatagramSocket(_ fd: Int32) -> Bool {
        var kind: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_TYPE, &kind, &length) == 0 else { return false }
        return kind == datagramSocketType
    }
    #endif

    /// 接收超时：POSIX 用 timeval，Windows 的 SO_RCVTIMEO 以毫秒 DWORD 计
    @discardableResult
    public static func setReceiveTimeout(_ fd: Int32, seconds: Int, microseconds: Int = 0) -> Bool {
        #if os(Windows)
        var milliseconds: UInt32 = UInt32(seconds * 1000 + microseconds / 1000)
        return setsockopt(socketHandle(fd), SOL_SOCKET, SO_RCVTIMEO, &milliseconds,
                          Int32(MemoryLayout<UInt32>.size)) == 0
        #else
        var tv = timeval(tv_sec: .init(seconds), tv_usec: .init(microseconds))
        return setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)) == 0
        #endif
    }

    /// SO_ERROR 读回并清除待处理错误；读取失败返回 nil
    public static func getSocketError(_ fd: Int32) -> Int32? {
        var value: Int32 = 0
        #if os(Windows)
        var length: Int32 = Int32(MemoryLayout<Int32>.size)
        guard getsockopt(socketHandle(fd), SOL_SOCKET, SO_ERROR, &value, &length) == 0 else { return nil }
        #else
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &value, &length) == 0 else { return nil }
        #endif
        return value
    }

    // MARK: 地址（纯 Swift，不经 inet_pton/inet_ntop/inet_addr）

    /// 数字 IPv4 字面量 → 主机字节序；文法同 inet_pton（允许前导零、拒绝 >255、必须 4 段）
    public static func parseIPv4(_ string: String) -> UInt32? {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let octet = UInt32(part), octet <= 255
            else { return nil }
            value = (value << 8) | octet
        }
        return value
    }

    /// 主机字节序 IPv4 → 点分十进制
    public static func ipv4AddressString(_ address: UInt32) -> String {
        "\((address >> 24) & 0xFF).\((address >> 16) & 0xFF).\((address >> 8) & 0xFF).\(address & 0xFF)"
    }

    /// 数字 IPv4 + 端口；非数字字面量返回 nil（不做域名解析）
    public static func address(_ host: String, port: UInt16) -> sockaddr_in? {
        guard let hostOrder = parseIPv4(host) else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = Family(AF_INET)
        addr.sin_port = port.bigEndian
        withUnsafeMutableBytes(of: &addr.sin_addr) { $0.storeBytes(of: hostOrder.bigEndian, as: UInt32.self) }
        return addr
    }

    /// 0.0.0.0（任意本地地址）
    public static func anyAddress(port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_family = Family(AF_INET)
        addr.sin_port = port.bigEndian
        withUnsafeMutableBytes(of: &addr.sin_addr) { $0.storeBytes(of: UInt32(0), as: UInt32.self) }
        return addr
    }

    /// 127.0.0.1（网络序，不经 INADDR_LOOPBACK 常量：那是大端语义，小端机直接赋会变成 1.0.0.127）
    public static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var addr = anyAddress(port: port)
        withUnsafeMutableBytes(of: &addr.sin_addr) { $0.storeBytes(of: UInt32(0x7F00_0001).bigEndian, as: UInt32.self) }
        return addr
    }

    /// 全零的 sockaddr_in（recvfrom 等需要预置出参的调用点使用）
    public static func emptyAddress() -> sockaddr_in { sockaddr_in() }

    public static func port(of addr: sockaddr_in) -> UInt16 {
        UInt16(bigEndian: addr.sin_port)
    }

    /// 本机字节序 IPv4（与 DirectInterface.Candidate.address 同一表示）
    public static func hostOrderAddress(of addr: inout sockaddr_in) -> UInt32 {
        withUnsafeBytes(of: &addr.sin_addr) { $0.load(as: UInt32.self) }.bigEndian
    }

    public static func ipString(of addr: inout sockaddr_in) -> String {
        ipv4AddressString(hostOrderAddress(of: &addr))
    }

    /// 主机名 → IPv4 点分字面量列表（AF_INET / SOCK_DGRAM；真的做名字解析，不限数字字面量）。
    /// 解析失败或没有 IPv4 结果返回空。可能先于任何套接字创建被调用，故先确保 Winsock 已初始化。
    /// Windows 用宽字符版 GetAddrInfoW / FreeAddrInfoW（ADDRINFOW）：ANSI 名字 getaddrinfoA 在 WinSDK 模块里
    /// 是宏别名、不导入（2026-11-24 实测 `cannot find 'getaddrinfoA' in scope`）；写法同 swift-corelibs-foundation 的 Host。
    public static func resolveIPv4Hosts(_ name: String) -> [String] {
        // Windows 的 GetAddrInfoW 把空名字当成「本机」（返回本机地址而不是失败）；mDNS 候选绝不能由空名字产生。
        guard !name.isEmpty else { return [] }
        ensureInitialized()
        var ips: [String] = []
        #if os(Windows)
        var hints = ADDRINFOW()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<ADDRINFOW>?
        let status = name.withCString(encodedAs: UTF16.self) { GetAddrInfoW($0, nil, &hints, &result) }
        guard status == 0, let first = result else { return [] }
        defer { FreeAddrInfoW(first) }
        var cursor: UnsafeMutablePointer<ADDRINFOW>? = first
        while let info = cursor {
            let entry = info.pointee
            if entry.ai_family == AF_INET, let raw = entry.ai_addr {
                ips.append(raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    ipString(of: &sin.pointee)
                })
            }
            cursor = entry.ai_next
        }
        #else
        var hints = addrinfo()
        hints.ai_family = .init(AF_INET)
        hints.ai_socktype = datagramSocketType
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            let entry = info.pointee
            if Int(entry.ai_family) == afINET, let raw = entry.ai_addr {
                ips.append(raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    ipString(of: &sin.pointee)
                })
            }
            cursor = entry.ai_next
        }
        #endif
        return ips
    }

    // MARK: 操作（返回值与 C 一致：结果码 / 字节数，负数表示失败）

    public static func bindSocket(_ fd: Int32, _ addr: inout sockaddr_in) -> Int32 {
        withConstSockAddr(&addr) { sa, len in
            #if os(Windows)
            return bind(socketHandle(fd), sa, len)
            #else
            return bind(fd, sa, len)
            #endif
        }
    }

    public static func listenSocket(_ fd: Int32, backlog: Int32) -> Int32 {
        #if os(Windows)
        return listen(socketHandle(fd), backlog)
        #else
        return listen(fd, backlog)
        #endif
    }

    /// 不关心对端地址的 accept；失败返回 -1
    public static func acceptSocket(_ fd: Int32) -> Int32 {
        #if os(Windows)
        let accepted = accept(socketHandle(fd), nil, nil)
        return accepted == SOCKET.max ? invalidHandle : handle(accepted)
        #else
        return accept(fd, nil, nil)
        #endif
    }

    public static func connectSocket(_ fd: Int32, _ addr: inout sockaddr_in) -> Int32 {
        withConstSockAddr(&addr) { sa, len in
            #if os(Windows)
            return connect(socketHandle(fd), sa, len)
            #else
            return connect(fd, sa, len)
            #endif
        }
    }

    /// getsockname 原始结果（族不过滤，调用方按需判断）；error 为 0 表示成功，否则为套接字错误码
    public static func localName(_ fd: Int32) -> (address: sockaddr_in, error: Int32) {
        var addr = sockaddr_in()
        var length = SocketLength(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa -> Int32 in
                #if os(Windows)
                return getsockname(socketHandle(fd), sa, &length)
                #else
                return getsockname(fd, sa, &length)
                #endif
            }
        }
        #if os(Windows)
        if rc != 0 {
            let code = lastError
            // Winsock 对「未绑定」套接字的 getsockname 报 WSAEINVAL；POSIX 返回通配地址 0.0.0.0:0。
            // 本层只创建 AF_INET 套接字，这里的 WSAEINVAL 只可能是未绑定：按 POSIX 语义回通配地址，
            // 调用方（DirectInterface.bindAccepted）据此判「无匹配」而不是失败。
            if code == einval { return (anyAddress(port: 0), 0) }
            return (addr, code)
        }
        return (addr, 0)
        #else
        return (addr, rc == 0 ? 0 : lastError)
        #endif
    }

    /// getsockname；非 IPv4 套接字或读取失败返回 nil
    public static func localAddress(_ fd: Int32) -> sockaddr_in? {
        let named = localName(fd)
        guard named.error == 0, Int(named.address.sin_family) == AF_INET else { return nil }
        return named.address
    }

    public static func receive(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if os(Windows)
        return Int(recv(socketHandle(fd), buffer.assumingMemoryBound(to: CChar.self), Int32(count), 0))
        #else
        return recv(fd, buffer, count, 0)
        #endif
    }

    public static func receiveFrom(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int,
                                   _ source: inout sockaddr_in) -> Int {
        var length = SocketLength(MemoryLayout<sockaddr_in>.size)
        return withUnsafeMutablePointer(to: &source) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                #if os(Windows)
                return Int(recvfrom(socketHandle(fd), buffer.assumingMemoryBound(to: CChar.self),
                                   Int32(count), 0, sa, &length))
                #else
                return recvfrom(fd, buffer, count, 0, sa, &length)
                #endif
            }
        }
    }

    /// 单次 send；Linux 带 MSG_NOSIGNAL（对端关闭不得以 SIGPIPE 杀死控制环进程）
    @discardableResult
    public static func sendData(_ fd: Int32, _ data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        return data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return sendBytes(fd, base, raw.count)
        }
    }

    /// 全部发完才返回 true（半包续写；失败即 false，与旧 WebUIServer.send 一致）
    public static func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var sent = 0
            while sent < raw.count {
                let n = sendBytes(fd, base.advanced(by: sent), raw.count - sent)
                guard n > 0 else { return false }
                sent += n
            }
            return true
        }
    }

    public static func sendDatagram(_ fd: Int32, _ data: Data, _ destination: inout sockaddr_in) -> Int {
        guard !data.isEmpty else { return 0 }
        return data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return withConstSockAddr(&destination) { sa, len -> Int in
                #if os(Windows)
                return Int(sendto(socketHandle(fd), base.assumingMemoryBound(to: CChar.self),
                                 Int32(raw.count), 0, sa, len))
                #else
                return sendto(fd, base, raw.count, sendFlags, sa, len)
                #endif
            }
        }
    }

    /// 非阻塞 connect 的有界等待（deadline 毫秒）。ready 之后由调用方读 SO_ERROR 分类。
    public enum ConnectWait: Equatable, Sendable {
        case ready
        case timedOut
        case failed(Int32)
    }

    public static func waitForConnect(_ fd: Int32, timeoutMs: Int) -> ConnectWait {
        let deadlineMs = max(1, timeoutMs)
        let start = DispatchTime.now().uptimeNanoseconds
        while true {
            let spentMs = Int(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            let remainingMs = deadlineMs - spentMs
            if remainingMs <= 0 { return .timedOut }
            switch waitForConnectOnce(fd, remainingMs: remainingMs) {
            case .ready: return .ready
            case .interrupted: continue
            case .timeout: return .timedOut
            case .failed(let code): return .failed(code)
            }
        }
    }

    private enum OnceOutcome {
        case ready, interrupted, timeout
        case failed(Int32)
    }

    private static func waitForConnectOnce(_ fd: Int32, remainingMs: Int) -> OnceOutcome {
        #if os(Windows)
        // Winsock 的 select 在 windows-2025-vs2026 镜像上对非阻塞 connect 的完成/失败从不置位
        //（2026-11-24 实测：6×300ms 均返回 0），WSAPoll 则立即报出 POLLERR|POLLHUP|POLLOUT（revents=0x13）。
        // 失败时 POLLOUT 也会置位，必须先看错误位；这种失败也不保证反映在 SO_ERROR（实测恒为 0）。
        // 常量按 winsock2.h 写字面量：POLLOUT = POLLWRNORM = 0x0010，POLLERR = 0x0001，POLLHUP = 0x0002。
        var descriptor = WSAPOLLFD(fd: socketHandle(fd), events: Int16(0x0010), revents: 0)
        let rc = WSAPoll(&descriptor, 1, Int32(remainingMs))
        if rc < 0 {
            let e = lastError
            return e == eintr ? .interrupted : .failed(e)
        }
        guard rc > 0 else { return .timeout }
        if (descriptor.revents & Int16(0x0003)) != 0 {
            if let code = getSocketError(fd), code != 0 { return .failed(code) }
            // 没有错误码的快速失败：连接尝试被对端明确拒绝（回环 / 局域网的 RST 形态）
            return .failed(econnrefused)
        }
        return .ready
        #elseif os(Linux)
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let rc = poll(&descriptor, 1, Int32(remainingMs))
        if rc > 0 { return .ready }
        if rc < 0 {
            let e = lastError
            return e == eintr ? .interrupted : .failed(e)
        }
        return .timeout
        #else
        // macOS 的 OM5P 实网 RST 下 poll(POLLOUT) 可能不醒；select 的写/异常集合能可靠返回。
        var writeSet = fd_set()
        var errorSet = fd_set()
        bzero(&writeSet, MemoryLayout<fd_set>.size)
        bzero(&errorSet, MemoryLayout<fd_set>.size)
        __darwin_fd_set(fd, &writeSet)
        __darwin_fd_set(fd, &errorSet)
        var wait = timeval(tv_sec: .init(remainingMs / 1000), tv_usec: .init((remainingMs % 1000) * 1000))
        let rc = select(fd + 1, nil, &writeSet, &errorSet, &wait)
        if rc > 0 { return .ready }
        if rc < 0 {
            let e = lastError
            return e == eintr ? .interrupted : .failed(e)
        }
        return .timeout
        #endif
    }

    // MARK: 接口

    #if os(Windows)
    /// Windows 无 getifaddrs/if_nametoindex 的可移植等价物（需 iphlpapi 的 GetAdaptersAddresses），
    /// 且直连绑定特性只针对 macOS 的 Clash TUN 场景；此处不实现，DS 按系统路由发送。
    public static let supportsInterfaceBinding = false
    public static let loopbackInterfaceName = "Loopback Pseudo-Interface 1"
    #elseif os(Linux)
    public static let supportsInterfaceBinding = true
    public static let loopbackInterfaceName = "lo"
    #else
    public static let supportsInterfaceBinding = true
    public static let loopbackInterfaceName = "lo0"
    #endif

    /// 接口名 → 内核接口索引；不存在返回 0
    public static func interfaceIndex(named name: String) -> UInt32 {
        #if os(Windows)
        return 0
        #else
        return name.withCString { if_nametoindex($0) }
        #endif
    }

    /// 把出站 IPv4 套接字钉到接口索引（0 = 清除绑定）。返回 0 为成功，否则为套接字错误码。
    /// Darwin 用 IP_BOUND_IF；Linux 用 SO_BINDTOIFINDEX（内核 ≥ 5.12，无需特权）；
    /// Windows 不支持（返回 EOPNOTSUPP，调用方应按系统路由处理）。
    public static func setBoundInterfaceIndex(_ fd: Int32, _ index: UInt32) -> Int32 {
        #if os(Windows)
        return eopnotsupp
        #elseif os(Linux)
        var value = Int32(bitPattern: index)
        return setsockopt(fd, SOL_SOCKET, linuxSO_BINDTOIFINDEX, &value,
                          socklen_t(MemoryLayout<Int32>.size)) == 0 ? 0 : errno
        #else
        var value = index
        return setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &value,
                          socklen_t(MemoryLayout<UInt32>.size)) == 0 ? 0 : errno
        #endif
    }

    /// 回读套接字当前钉住的接口索引；未绑定或读取失败返回 nil
    public static func boundInterfaceIndex(_ fd: Int32) -> UInt32? {
        guard fd >= 0, supportsInterfaceBinding else { return nil }
        // 三个平台各有一个编译分支：Windows 不能落进 Darwin 分支（IP_BOUND_IF 与 POSIX 句柄类型在那里都不存在）
        #if os(Windows)
        return nil
        #elseif os(Linux)
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, linuxSO_BINDTOIFINDEX, &value, &length) == 0 else { return nil }
        return value == 0 ? nil : UInt32(bitPattern: value)
        #else
        var value: UInt32 = 0
        var length = socklen_t(MemoryLayout<UInt32>.size)
        guard getsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &value, &length) == 0 else { return nil }
        return value == 0 ? nil : value
        #endif
    }

    /// 非套接字 fd（用于 getsockname 失败分类测试）
    public static func openNullDevice() -> Int32 {
        #if os(Windows)
        // _open 是可变参数的 C 函数，Swift 不导入；_sopen_s 是它的定参版（swift-tools-support-core 同此用法）。
        // 标志位按 UCRT 头文件的值写字面量：_O_RDONLY = 0x0000（fcntl.h）、_SH_DENYNO = 0x80（share.h）。
        var fd: Int32 = -1
        return _sopen_s(&fd, "NUL", 0x0000, 0x80, 0) == 0 ? fd : invalidHandle
        #else
        return open("/dev/null", O_RDONLY)
        #endif
    }

    public static func closeFileHandle(_ fd: Int32) {
        #if os(Windows)
        _ = _close(fd)
        #else
        _ = close(fd)
        #endif
    }

    // MARK: 内部

    #if os(Windows)
    /// Int32 句柄 → SOCKET。-1 必须映射成完整的 INVALID_SOCKET（UINT_PTR 全 1），否则 0xFFFFFFFF
    /// 只是个普通句柄值，Winsock 会报 WSAENOTSOCK 而不是 WSAEBADF。
    @inline(__always) private static func socketHandle(_ fd: Int32) -> SOCKET {
        fd == invalidHandle ? SOCKET.max : SOCKET(UInt(UInt32(bitPattern: fd)))
    }

    /// SOCKET → Int32 句柄。Winsock 句柄实践中都是小整数；超出 Int32 的值不得截断后与其他句柄混淆，
    /// 宁可按创建失败处理（否则截断值可能恰好等于另一个真实句柄，造成关错套接字）。
    @inline(__always) private static func handle(_ socket: SOCKET) -> Int32 {
        socket <= UInt(Int32.max) ? Int32(socket) : invalidHandle
    }
    #endif

    #if os(Linux)
    private static let sendFlags = Int32(MSG_NOSIGNAL)
    /// Linux UAPI `SO_BINDTOIFINDEX` 的固定值（asm-generic/socket.h，内核 ≥ 5.12）；
    /// 不经头文件常量，避免不同 libc 版本的宏缺失。
    private static let linuxSO_BINDTOIFINDEX: Int32 = 62
    #else
    private static let sendFlags: Int32 = 0
    #endif

    private static func sendBytes(_ fd: Int32, _ base: UnsafeRawPointer, _ count: Int) -> Int {
        #if os(Windows)
        return Int(send(socketHandle(fd), base.assumingMemoryBound(to: CChar.self), Int32(count), 0))
        #else
        return send(fd, base, count, sendFlags)
        #endif
    }

    @inline(__always)
    private static func withConstSockAddr<R>(_ addr: inout sockaddr_in,
                                             _ body: (UnsafePointer<sockaddr>, SocketLength) -> R) -> R {
        let length = SocketLength(MemoryLayout<sockaddr_in>.size)
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in body(sa, length) }
        }
    }
}
