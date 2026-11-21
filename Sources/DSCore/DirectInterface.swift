import Darwin

// MARK: 直连出口选择（Clash Verge TUN 全模式下的机器人直连）
//
// TUN 模式会把机器人网段吸进 utun 虚拟接口；DS 的 UDP 套接字若不绑定物理接口，
// 出站包会按系统路由进入 TUN，再被代理规则劫持。这里按目标 IPv4 选出同子网的
// 物理接口，并用 IP_BOUND_IF 把套接字钉在该接口上。

public enum DirectInterface {

    public struct Candidate: Equatable {
        public var name: String
        public var index: UInt32
        public var address: UInt32   // IPv4 主机字节序
        public var netmask: UInt32   // IPv4 主机字节序
        public var isUp: Bool
        public var isLoopback: Bool

        public init(name: String, index: UInt32, address: UInt32, netmask: UInt32,
                    isUp: Bool, isLoopback: Bool) {
            self.name = name
            self.index = index
            self.address = address
            self.netmask = netmask
            self.isUp = isUp
            self.isLoopback = isLoopback
        }
    }

    public enum BindResult: Equatable {
        case bound(name: String, index: UInt32)
        case noMatch
        case failed(errno: Int32)
    }

    private struct EnumerationFailure: Error {
        let code: Int32
    }

    private static let virtualPrefixes = ["utun", "ipsec", "ppp", "gif", "stf", "awdl", "llw", "nan"]

    /// 纯函数选择：target 必须是数字 IPv4 字面量（不做域名解析）。
    ///
    /// - 回环目标（127.0.0.0/8）优先选 lo0，其次其他回环候选；无回环候选时返回 nil。
    /// - 普通目标只在已启用、非回环、非虚拟接口、地址与掩码均非零且同子网的候选中选。
    /// - 多候选命中时依次按掩码前缀长度、掩码值、启用状态、接口索引、名称/地址排序，
    ///   与候选数组顺序无关。
    public static func select(target: String, candidates: [Candidate]) -> Candidate? {
        guard let ip = parseIPv4(target) else { return nil }
        if ip & 0xFF00_0000 == 0x7F00_0000 {
            return chooseLoopback(candidates)
        }
        guard ip != 0 else { return nil }
        let matching = candidates.filter { candidate in
            candidate.isUp
                && !candidate.isLoopback
                && !isVirtual(candidate.name)
                && candidate.address != 0
                && candidate.netmask != 0
                && (candidate.address & candidate.netmask) == (ip & candidate.netmask)
        }
        return matching.min(by: rank)
    }

    /// 纯函数：按本机 IPv4 地址（主机字节序）精确匹配接口，不做子网推断。
    ///
    /// `0.0.0.0` 或无候选地址相等时返回 nil；同一地址出现在多个候选时按 rank
    /// 确定性选择，回环接口同样参与匹配。
    public static func select(localAddress: UInt32, candidates: [Candidate]) -> Candidate? {
        guard localAddress != 0 else { return nil }
        return candidates.filter { $0.address == localAddress }.min(by: rank)
    }

    /// 按目标 IPv4 选接口并设置 IP_BOUND_IF。
    ///
    /// 接口枚举失败、套接字操作失败（含清除失败）返回 `.failed(errno:)`，且不改动
    /// 既有绑定。枚举成功但无候选命中（含非 IPv4 字面量、0.0.0.0）时向
    /// IP_BOUND_IF 写 0 清除旧绑定并返回 `.noMatch`，供 UDP 改目标时避免残留。
    public static func bind(fd: Int32, target: String) -> BindResult {
        guard fd >= 0 else { return .failed(errno: EBADF) }
        switch enumerateCandidates() {
        case .failure(let failure):
            return .failed(errno: failure.code)
        case .success(let candidates):
            return applyBinding(fd: fd, chosen: select(target: target, candidates: candidates))
        }
    }

    /// 按 accepted socket 的本机 IPv4（getsockname）精确匹配实际本地接口并设置
    /// IP_BOUND_IF；不按对端子网推断。
    ///
    /// getsockname、接口枚举或套接字操作失败返回 `.failed(errno:)`，且不改动既有
    /// 绑定；本机地址非 IPv4 返回 `.failed(EAFNOSUPPORT)`。枚举成功但无地址匹配
    /// （含未绑定套接字的 0.0.0.0）时清除旧绑定并返回 `.noMatch`。
    public static func bindAccepted(fd: Int32) -> BindResult {
        guard fd >= 0 else { return .failed(errno: EBADF) }
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &length)
            }
        }
        guard named == 0 else {
            let err = errno
            return .failed(errno: err)
        }
        guard storage.ss_family == sa_family_t(AF_INET) else {
            return .failed(errno: EAFNOSUPPORT)
        }
        let localAddress = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                UInt32(bigEndian: sin.pointee.sin_addr.s_addr)
            }
        }
        switch enumerateCandidates() {
        case .failure(let failure):
            return .failed(errno: failure.code)
        case .success(let candidates):
            return applyBinding(fd: fd, chosen: select(localAddress: localAddress, candidates: candidates))
        }
    }

    /// 回读套接字当前绑定的接口索引；未绑定或读取失败返回 nil。
    public static func boundInterfaceIndex(fd: Int32) -> UInt32? {
        guard fd >= 0 else { return nil }
        var index: UInt32 = 0
        var length = socklen_t(MemoryLayout<UInt32>.size)
        guard getsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, &length) == 0 else { return nil }
        return index == 0 ? nil : index
    }

    private static func parseIPv4(_ string: String) -> UInt32? {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let octet = UInt32(part), octet <= 255
            else { return nil }
            value = (value << 8) | octet
        }
        return value
    }

    private static func isVirtual(_ name: String) -> Bool {
        let lower = name.lowercased()
        return virtualPrefixes.contains { lower.hasPrefix($0) }
    }

    private static func rank(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let lhsBits = lhs.netmask.nonzeroBitCount
        let rhsBits = rhs.netmask.nonzeroBitCount
        if lhsBits != rhsBits { return lhsBits > rhsBits }
        if lhs.netmask != rhs.netmask { return lhs.netmask > rhs.netmask }
        if lhs.isUp != rhs.isUp { return lhs.isUp }
        if lhs.isLoopback != rhs.isLoopback { return lhs.isLoopback }
        if lhs.index != rhs.index { return lhs.index < rhs.index }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        if lhs.address != rhs.address { return lhs.address < rhs.address }
        return false
    }

    private static func chooseLoopback(_ candidates: [Candidate]) -> Candidate? {
        candidates.filter { $0.isLoopback }.sorted { lhs, rhs in
            let lhsIsLo0 = lhs.name == "lo0"
            let rhsIsLo0 = rhs.name == "lo0"
            if lhsIsLo0 != rhsIsLo0 { return lhsIsLo0 }
            return rank(lhs, rhs)
        }.first
    }

    private static func applyBinding(fd: Int32, chosen: Candidate?) -> BindResult {
        var index = chosen?.index ?? 0
        guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index,
                         socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
            let err = errno
            return .failed(errno: err)
        }
        guard let chosen else { return .noMatch }
        return .bound(name: chosen.name, index: chosen.index)
    }

    private static func enumerateCandidates() -> Result<[Candidate], EnumerationFailure> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else {
            let code = errno
            return .failure(EnumerationFailure(code: code))
        }
        guard let first = head else { return .success([]) }
        defer { freeifaddrs(head) }

        var result: [Candidate] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let index = if_nametoindex(name)
            guard index != 0 else { continue }
            let address = ipv4Address(addr)
            let netmask = entry.pointee.ifa_netmask.map(ipv4Address) ?? 0
            let flags = entry.pointee.ifa_flags
            result.append(Candidate(name: name, index: index, address: address, netmask: netmask,
                                    isUp: flags & UInt32(IFF_UP) != 0,
                                    isLoopback: flags & UInt32(IFF_LOOPBACK) != 0))
        }
        return .success(result)
    }

    private static func ipv4Address(_ pointer: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            UInt32(bigEndian: sin.pointee.sin_addr.s_addr)
        }
    }
}
