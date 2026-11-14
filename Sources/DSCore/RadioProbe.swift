import Foundation

// MARK: - SettingsStore：偏好持久化（UserDefaults 封装，可注入 suite 供测试隔离）

public final class SettingsStore {
    private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "ghds.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    private func full(_ key: String) -> String { prefix + key }

    public func string(_ key: String) -> String? {
        defaults.string(forKey: full(key))
    }
    public func set(_ key: String, _ value: String?) {
        guard let value else { defaults.removeObject(forKey: full(key)); return }
        defaults.set(value, forKey: full(key))
    }

    public func integer(_ key: String) -> Int? {
        guard defaults.object(forKey: full(key)) != nil else { return nil }
        return defaults.integer(forKey: full(key))
    }
    public func set(_ key: String, _ value: Int) {
        defaults.set(value, forKey: full(key))
    }

    public func double(_ key: String) -> Double? {
        guard defaults.object(forKey: full(key)) != nil else { return nil }
        return defaults.double(forKey: full(key))
    }
    public func set(_ key: String, _ value: Double) {
        defaults.set(value, forKey: full(key))
    }

    public func bool(_ key: String) -> Bool? {
        guard defaults.object(forKey: full(key)) != nil else { return nil }
        return defaults.bool(forKey: full(key))
    }
    public func set(_ key: String, _ value: Bool) {
        defaults.set(value, forKey: full(key))
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

        public init(interval: TimeInterval = 2.0, timeout: TimeInterval = 0.6, port: UInt16 = 80) {
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
    private let queue = DispatchQueue(label: "gh.driverstation.radio-probe", qos: .utility)
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
