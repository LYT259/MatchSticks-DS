import Foundation
import Darwin

// MARK: - Application Support 数据目录（新品牌 + 旧目录保留式迁移）
//
// 新目录：Application Support/MatchSticksDS
// 旧目录：Application Support/GHDriverStation（旧版本数据）
//
// 迁移规则：
// - 初始化只解析目录并创建新目录根；递归补齐在后台串行队列执行，
//   `waitForMigration(timeout:)` 供测试等待（生产路径不被迁移阻塞）
// - 只复制旧目录中缺失的普通文件；已存在的目标文件/符号链接绝不覆盖，
//   已存在的目标目录只补齐缺失子项
// - 逐文件复制到同目录临时文件，内容校验通过后以硬链接原子发布：
//   目标要么不存在，要么是完整文件；并发迁移只有一个发布成功
// - 任何失败都清理临时文件并保留旧目录；下一次启动可重试
// - 源与目标符号链接一律跳过（不跟随，避免复制到目录树之外）
// - 新目录无法创建/使用时回退旧目录，保证日志、录制与 WebUI 继续可用
//
// 测试隔离：`MATCHSTICKS_DS_APPLICATION_SUPPORT` 覆盖 Application Support 根
// （只认新前缀，不兼容 GHDS_ alias；生产默认路径不变）。

public struct AppSupportDirectory {
    public static let name = "MatchSticksDS"
    public static let legacyName = "GHDriverStation"
    /// 仅用于测试/并行会话隔离：覆盖 Application Support 根目录
    /// （其下仍是 MatchSticksDS / GHDriverStation）。
    public static let overrideEnvironmentKey = DSEnvironment.prefix + "APPLICATION_SUPPORT"

    public let url: URL
    private let fileManager: FileManager
    private let migrationGroup: DispatchGroup

    /// 进程内串行：多个 AppSupportDirectory 实例（或多窗口）同时启动时，
    /// 迁移不会互相叠加；跨进程并发仍由目标文件的原子发布兜底。
    private static let migrationQueue = DispatchQueue(
        label: "matchsticks.ds.application-support-migration",
        qos: .utility
    )

    public init(
        baseURL: URL? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let base = baseURL ?? Self.applicationSupportBaseURL(
            fileManager: fileManager,
            environment: environment
        )
        let candidate = base.appendingPathComponent(Self.name, isDirectory: true)
        let legacy = base.appendingPathComponent(Self.legacyName, isDirectory: true)
        let group = DispatchGroup()

        self.fileManager = fileManager
        self.migrationGroup = group

        var chosen = legacy
        var shouldMigrate = false

        if Self.isSymbolicLink(candidate) {
            // 新目录本身是符号链接：不跟随，回退旧目录。
            chosen = legacy
        } else if Self.isWritableDirectory(candidate, fileManager: fileManager) {
            chosen = candidate
            shouldMigrate = true
        } else if !fileManager.fileExists(atPath: candidate.path) {
            do {
                try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
                if Self.isWritableDirectory(candidate, fileManager: fileManager) {
                    chosen = candidate
                    shouldMigrate = true
                }
            } catch {
                // 并发创建时另一个实例可能已把目录建好：能写就继续用。
                if Self.isWritableDirectory(candidate, fileManager: fileManager) {
                    chosen = candidate
                    shouldMigrate = true
                } else {
                    chosen = legacy
                }
            }
        } else {
            // 同名普通文件占位或目录不可写：回退旧目录（调用方按需创建子目录）。
            chosen = legacy
        }

        self.url = chosen
        if shouldMigrate {
            Self.beginMigration(
                from: legacy,
                to: candidate,
                fileManager: fileManager,
                group: group
            )
        }
    }

    /// 解析 Application Support 根目录。`baseURL` 显式注入优先；
    /// 否则只认 `MATCHSTICKS_DS_APPLICATION_SUPPORT`（旧 GHDS_ 前缀不设 alias），
    /// 最后回退系统默认的 Application Support。
    public static func applicationSupportBaseURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let overridePath = DSEnvironment.currentString("APPLICATION_SUPPORT", environment: environment),
           !overridePath.isEmpty {
            let expanded = (overridePath as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    public func subdirectory(_ name: String, create: Bool = true) -> URL {
        let directory = url.appendingPathComponent(name, isDirectory: true)
        if create {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// 等待后台迁移结束（测试 / 需要确定性文件视图的调用方使用）。
    /// 未启动迁移时立即返回 true；超时返回 false（迁移仍在后台继续，旧目录不受影响）。
    @discardableResult
    public func waitForMigration(timeout: TimeInterval = 30) -> Bool {
        migrationGroup.wait(timeout: .now() + timeout) == .success
    }

    // MARK: 迁移

    private static func beginMigration(
        from source: URL,
        to destination: URL,
        fileManager: FileManager,
        group: DispatchGroup
    ) {
        // 根目录符号链接同样跳过：旧目录只读，绝不跟随链接到目录树之外。
        guard isDirectory(source, fileManager: fileManager),
              !isSymbolicLink(source),
              isDirectory(destination, fileManager: fileManager),
              !isSymbolicLink(destination) else { return }

        group.enter()
        migrationQueue.async {
            defer { group.leave() }
            mergeMissingContents(from: source, into: destination, fileManager: fileManager)
        }
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    private static func isWritableDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        !isSymbolicLink(url)
            && isDirectory(url, fileManager: fileManager)
            && fileManager.isWritableFile(atPath: url.path)
    }

    /// lstat 语义：只判断路径本身，不跟随链接（悬空链接也能识别）。
    /// 去掉目录 URL 可能带有的尾斜杠：lstat 对 "link/" 会按目录跟随链接。
    private static func isSymbolicLink(_ url: URL) -> Bool {
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
    }

    /// 只补齐缺失项：源目录只读不写；目标目录递归补齐，已存在的目标文件不覆盖。
    private static func mergeMissingContents(from source: URL, into destination: URL, fileManager: FileManager) {
        guard isDirectory(source, fileManager: fileManager),
              !isSymbolicLink(source),
              isDirectory(destination, fileManager: fileManager),
              !isSymbolicLink(destination),
              let entries = try? fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
                options: []
              ) else { return }

        for entry in entries {
            // 外部目录内容不可信：源符号链接（含悬空链接）一律跳过，不跟随。
            guard !isSymbolicLink(entry) else { continue }
            let values = try? entry.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
            )
            guard values?.isSymbolicLink != true else { continue }
            let target = destination.appendingPathComponent(entry.lastPathComponent)

            if values?.isDirectory == true {
                // 目标是符号链接：不跟随、不写入其指向，也不在其下递归。
                guard !isSymbolicLink(target) else { continue }
                if !fileManager.fileExists(atPath: target.path) {
                    do {
                        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                    } catch {
                        continue
                    }
                }
                guard isDirectory(target, fileManager: fileManager),
                      !isSymbolicLink(target) else { continue }
                mergeMissingContents(from: entry, into: target, fileManager: fileManager)
            } else if values?.isRegularFile == true {
                mergeRegularFile(from: entry, to: target, fileManager: fileManager)
            }
            // FIFO / 设备 / 套接字等不复制：读取可能阻塞或产生副作用。
        }
    }

    private static func mergeRegularFile(from source: URL, to target: URL, fileManager: FileManager) {
        // 目标已存在或本身是符号链接：绝不覆盖、绝不写穿。
        guard !isSymbolicLink(target), !fileManager.fileExists(atPath: target.path) else { return }

        let temp = target.deletingLastPathComponent().appendingPathComponent(
            ".matchsticks-migration-\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temp) }

        do {
            try fileManager.copyItem(at: source, to: temp)
            let matches = try contentsEqual(source, temp)
            guard matches else { return }
            // 硬链接发布：目标已出现则失败（EEXIST），不会被覆盖；
            // 目标只在临时文件完整且校验通过后出现，读侧不会看到半文件。
            try fileManager.linkItem(at: temp, to: target)
        } catch {
            // 失败保持旧目录不动；defer 清理临时文件，下次启动重试。
        }
    }

    /// 分块比较源文件与临时副本，避免把大日志整体读进内存。
    private static func contentsEqual(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let left = try FileHandle(forReadingFrom: lhs)
        defer { try? left.close() }
        let right = try FileHandle(forReadingFrom: rhs)
        defer { try? right.close() }

        while true {
            let a = try readChunk(from: left)
            let b = try readChunk(from: right)
            guard a == b else { return false }
            if a.isEmpty { return true }
        }
    }

    /// 读满一个块或读到 EOF：regular file 的 read 也可能短读，
    /// 固定块边界才能让两个文件逐块可比。
    private static func readChunk(from handle: FileHandle, size: Int = 64 * 1024) throws -> Data {
        var chunk = Data()
        while chunk.count < size {
            guard let piece = try handle.read(upToCount: size - chunk.count), !piece.isEmpty else {
                break
            }
            chunk.append(contentsOf: piece)
        }
        return chunk
    }
}
