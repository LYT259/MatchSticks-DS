import Foundation
import CoreFoundation

// MARK: - SettingsStore：偏好持久化（UserDefaults 封装，可注入 suite 供测试隔离）
//
// 品牌改名后新键前缀为 `matchsticks.`；旧 `ghds.` 键兼容规则：
// - 新键存在即唯一真值；只有新键完全缺失时才读旧键并补写新键（迁移）
// - 新键类型不符时不回退旧键：避免旧值经读取/回写链路覆盖新键
// - 正常 set 同步写新旧键：降级回旧版本仍能读到最新值（回滚支持）
// - set nil 是用户主动清除：同时删除新旧键，防止旧值复活（见 removeBoth）
// - 自定义测试前缀默认不启用旧前缀，防止意外读写生产设置

public final class SettingsStore {
    public static let defaultPrefix = "matchsticks."
    public static let legacyPrefix = "ghds."

    private let defaults: UserDefaults
    private let prefix: String
    private let legacyPrefix: String?

    public init(
        defaults: UserDefaults = .standard,
        prefix: String = SettingsStore.defaultPrefix,
        legacyPrefix: String? = nil
    ) {
        self.defaults = defaults
        self.prefix = prefix
        if let legacyPrefix {
            self.legacyPrefix = legacyPrefix
        } else if prefix == Self.defaultPrefix {
            self.legacyPrefix = Self.legacyPrefix
        } else {
            self.legacyPrefix = nil
        }
    }

    private func full(_ key: String) -> String { prefix + key }
    private func legacyFull(_ key: String) -> String? { legacyPrefix.map { $0 + key } }

    /// 新键存在即权威：类型不符按损坏处理（返回 nil），绝不回退旧键——
    /// 否则旧值会被调用方 didSet 回写，反过来覆盖新键。
    /// 只有新键完全缺失时才读取旧键，并补写新键完成迁移。
    private func migrated<T>(_ key: String, decode: (Any) -> T?) -> T? {
        if let raw = defaults.object(forKey: full(key)) {
            return decode(raw)
        }
        guard let legacyKey = legacyFull(key),
              let raw = defaults.object(forKey: legacyKey),
              let value = decode(raw) else { return nil }
        defaults.set(value, forKey: full(key))
        return value
    }

    /// 普通写入：新键是权威值；同时写旧键，旧版本降级后仍读到最新值（回滚支持）。
    private func write(_ key: String, _ value: Any) {
        defaults.set(value, forKey: full(key))
        if let legacyKey = legacyFull(key) {
            defaults.set(value, forKey: legacyKey)
        }
    }

    /// 显式清除（用户主动 set nil）：新旧键一起删除。只删新键会让迁移回退
    /// 把旧值重新读回来（“复活”）；因此这里是用户意图，不是普通覆盖。
    private func removeBoth(_ key: String) {
        defaults.removeObject(forKey: full(key))
        if let legacyKey = legacyFull(key) {
            defaults.removeObject(forKey: legacyKey)
        }
    }

    // MARK: 类型解码

    private static func decodeString(_ raw: Any) -> String? {
        raw as? String
    }

    private static func decodeInt(_ raw: Any) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number as CFTypeRef) == CFNumberGetTypeID() else { return nil }
        switch CFNumberGetType(number) {
        case .sInt8Type, .sInt16Type, .sInt32Type, .sInt64Type,
             .charType, .shortType, .intType, .longType, .longLongType,
             .nsIntegerType, .cfIndexType:
            return number.intValue
        default:
            return nil
        }
    }

    private static func decodeDouble(_ raw: Any) -> Double? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number as CFTypeRef) == CFNumberGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func decodeBool(_ raw: Any) -> Bool? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    // MARK: 读写

    public func string(_ key: String) -> String? {
        migrated(key, decode: Self.decodeString)
    }
    public func set(_ key: String, _ value: String?) {
        guard let value else { removeBoth(key); return }
        write(key, value)
    }

    public func integer(_ key: String) -> Int? {
        migrated(key, decode: Self.decodeInt)
    }
    public func set(_ key: String, _ value: Int) {
        write(key, value)
    }

    public func double(_ key: String) -> Double? {
        migrated(key, decode: Self.decodeDouble)
    }
    public func set(_ key: String, _ value: Double) {
        write(key, value)
    }

    public func bool(_ key: String) -> Bool? {
        migrated(key, decode: Self.decodeBool)
    }
    public func set(_ key: String, _ value: Bool) {
        write(key, value)
    }
}

// MARK: - RadioProbe：Robot Radio 可达性探测（真实机器人 = 10.T.E.AM.1:80）
//
// NI DS Diagnostics 的 Robot Radio 灯来自对 radio 网关的 ping；ICMP 需要特权，
// 这里用短超时 TCP 连接作为可达性代理（radio 自带 web 服务，端口 80 常开）。
// 2026-10-31 真机实测修正：OM5P 的 :80 可以回 RST（Connection refused）而 radio 在线——
// TCP 结局里 connected 与 refused 都证明主机活着，只有超时/不可达/其他错误才判离线。

public final class RadioProbe {
    public struct Configuration {
        public var interval: TimeInterval
        public var timeout: TimeInterval
        public var port: UInt16

        public init(interval: TimeInterval = 2.0, timeout: TimeInterval = 2.0, port: UInt16 = 80) {
            self.interval = interval
            self.timeout = timeout
            self.port = port
        }
    }

    /// 自动模式 radio 探测目标（纯函数，可测）：
    /// - AUTO_SIM：本机模拟器 host + 非特权端口（默认 127.0.0.1:8080），与队号无关；
    /// - 普通自动：队号派生 10.T.E.1:80（radio 网关）。manualIP 是 roboRIO 地址，
    ///   不参与 radio 选址（2026-10-31：填手动 roboRIO IP 曾让 radio 灯误亮）；
    /// - 队号未设置：nil（本轮不探测）。
    public static func autoTarget(autoSim: Bool,
                                  teamNumber: Int,
                                  teamPort: UInt16 = 80,
                                  simHost: String = "127.0.0.1",
                                  simPort: UInt16 = 8080) -> (host: String, port: UInt16)? {
        if autoSim { return (simHost, simPort) }
        guard teamNumber > 0 else { return nil }
        return (String(format: "10.%d.%d.1", teamNumber / 100, teamNumber % 100), teamPort)
    }

    /// 返回 nil = 本轮不探测（队伍号未设置等）
    public var hostProvider: () -> (host: String, port: UInt16)? = { nil }
    /// 在 probe queue 上回调
    public var onResult: ((Bool) -> Void)?

    public let configuration: Configuration
    private let queue = DispatchQueue(label: "matchsticks.driverstation.radio-probe", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var reachableValue = false
    private var attemptsValue = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public var isReachable: Bool {
        lock.lock(); defer { lock.unlock() }
        return reachableValue
    }

    /// 探测次数（测试用；stop() 后读取）
    public var probeAttempts: Int {
        lock.lock(); defer { lock.unlock() }
        return attemptsValue
    }

    public func start() {
        queue.async { [weak self] in self?.scheduleLocked(immediate: true) }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func scheduleLocked(immediate: Bool) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: immediate ? .now() : .now() + configuration.interval,
                   repeating: configuration.interval, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.probeOnce() }
        t.resume()
        timer = t
    }

    private func probeOnce() {
        guard let target = hostProvider() else { setResult(false); return }
        lock.lock(); attemptsValue += 1; lock.unlock()
        // connected / refused（RST）= radio 主机在线；timedOut / unreachable / error = 离线。
        // connect 由 boundedTCPConnect 用 poll 截止时间限时，黑洞链路不再卡探测队列
        // （2026-10-31 断线漏报 ~75s 的直接原因）。
        switch DSClient.boundedTCPConnect(to: target.host, port: target.port, timeout: configuration.timeout) {
        case .connected(let fd):
            close(fd)
            setResult(true)
        case .refused:
            setResult(true)
        case .timedOut, .unreachable, .error:
            setResult(false)
        }
    }

    private func setResult(_ ok: Bool) {
        lock.lock()
        let changed = reachableValue != ok
        reachableValue = ok
        lock.unlock()
        if changed { onResult?(ok) }
    }
}
