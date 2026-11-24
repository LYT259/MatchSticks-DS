# ADR-0005：DSCore 三平台可移植架构（SocketCompat / SHA1 / StringsTable）与同一 commit 的三端验证

- 状态：已接受（Accepted）
- 日期：2026-11-24
- 决策：产品所有者（LYT259）——2026-11-23/24 指令：核心代码可在 macOS / Linux / Windows 三平台跑同一套验证，Windows 端用 GitHub Actions
- 编号核查：新建前检查本地全部分支、`origin/*` 与磁盘上各 worktree 的 `docs/decisions/`。已占用：`0001`（更名映射，已在 beta）、`0002`（natural-controller-motion，`fix/natural-controller-motion` 等 3 个分支）、`0003`（两份互不相同：`docs/three-platform-validation` 与 `feat/matchsticks-driver-station-rename` 两个 worktree 各有一份，属并行会话撞号，不在本 ADR 处理范围）、`0004`（update-channels，`feat/auto-update-channels` worktree）。`0005` 无人占用，按仓库约定「全分支最大号 +1」取 `0005`。

## 背景

MatchSticks DS 是 macOS 专用桌面软件（可行性研究报告 v1.2 §1.1/§1.3），这一点没有变。但 `DSCore`（NI 协议编解码、20 ms 控制环、看门狗、NT4、WebUI、日志与录制、手柄映射、设置迁移、双语表）是平台无关的纯逻辑，它的回归证据此前只能来自一台 Mac。

让同一套 `DSCoreTests` 在 Linux 与 Windows 上运行，被四处平台耦合挡住（2026-11-23 首轮 RED 证据：Linux 交叉编译报 `no such module 'Darwin'`）：

1. 源码与测试直接写 BSD/Darwin 调用（`import Darwin`、`socket/bind/recvfrom/fcntl/poll/select`、`__darwin_fd_set`）。
2. NT4 WebSocket 握手摘要用 CryptoKit，只在 Apple 平台可用。
3. 英文表经 `Bundle.localizedString` 读取 OpenStep 文本 `.strings`，corelibs Foundation 对该格式的支持不可依赖。
4. `SettingsStore` 的类型判定依赖 CoreFoundation 的 `CFBoolean`/`CFNumber` 类型 ID。

Windows 另有一组独立差异：Winsock 的句柄、错误码（`WSAE*`）、非阻塞方式与 `SO_REUSEADDR` 语义都和 POSIX 不同；`FIONBIO`、`SO_EXCLUSIVEADDRUSE`、`SD_BOTH`、`SIO_UDP_CONNRESET` 以函数式或带转换的宏定义，Swift 的 ClangImporter 不保证能导入。

## 决策

### 1. 范围：只移植核心，产品范围不变

`DSCore` 与 `DSCoreTests` 在 macOS / Linux / Windows 上是同一份源码、同一套断言。`MatchSticksDS`（SwiftUI + Sparkle）、`MatchSticksDSSim`、UI 测试与打包版 E2E 仍然只在 macOS 上构建和运行。本 ADR 不新增对 Linux/Windows 的产品承诺，不分发，不改变可行性研究报告关于非目标平台的结论。DSCore 继续保持零外部依赖。

### 2. SocketCompat：唯一的套接字平台边界

`Sources/DSCore/SocketCompat.swift` 是一个 `public enum SocketCompat`（:35），业务代码与测试只调用这一层，不再直接写系统调用。方法名刻意避开 C 全局函数名（`bindSocket`/`sendData`/`receiveFrom`/`closeSocket`…），因为 enum 内的同名静态方法会遮蔽 C 函数。

| 差异点 | macOS | Linux | Windows | 实现位置（SocketCompat.swift） |
|---|---|---|---|---|
| 句柄 | `Int32` fd | 同 macOS | `Int32`；`INVALID_SOCKET` 与 -1 互转，超出 Int32 的句柄按创建失败处理，绝不截断 | :596–608 |
| 错误码 | `errno` | `errno` | `WSAGetLastError()`，`WSAE*` 常量经本层取用 | :56–92、:108–115 |
| 初始化 | 无 | 无 | `WSAStartup(2.2)`，进程内幂等（`ensureInitialized()`） | :136–149 |
| UDP 套接字 | — | — | 关闭 `SIO_UDP_CONNRESET`：对端端口不可达不再表现为连接重置 | :119–133 |
| 非阻塞 | `fcntl(O_NONBLOCK)` | 同 macOS | `ioctlsocket(FIONBIO)`，常量按 SDK 头文件写字面量 | :151–201 |
| 「可重绑但不共享」 | `SO_REUSEADDR` | UDP 不设（否则两个套接字可重复绑定同端口）；TCP 监听口设 | `SO_EXCLUSIVEADDRUSE`（Winsock 的 `SO_REUSEADDR` 允许无特权进程强绑已占用端口） | :203–235 |
| 接收超时 | `timeval` | `timeval` | 毫秒 `DWORD` | :237–248 |
| 非阻塞 connect 的等待 | `select` 写/异常集合（`poll` 对实网 RST 可能不醒） | `poll` | `select`（Winsock `fd_set`） | :498–568 |
| 对端关闭写入 | 默认 | `MSG_NOSIGNAL`（不得以 SIGPIPE 杀死控制环进程） | 默认 | :666–681 |
| 地址解析与格式化 | 纯 Swift，文法同 `inet_pton` | 同 macOS | 同 macOS | :263–324 |
| 主机名解析（mDNS） | `getaddrinfo` | 同 macOS | `GetAddrInfoW` / `FreeAddrInfoW`（`ADDRINFOW`；`getaddrinfoA` 是宏别名，WinSDK 模块不导入） | :326–370 |
| 接口枚举与钉绑 | `getifaddrs` + `IP_BOUND_IF` | `getifaddrs` + `SO_BINDTOIFINDEX`（62） | 不实现（`supportsInterfaceBinding = false`，按系统路由） | :570–628 |

「可重绑但不共享」一行是安全相关的：DS 固定绑定 UDP 1150，「被占即失败」是不变量。Winsock 默认语义会把它变成静默串包，所以 Windows 改用独占选项；Linux 内核允许两个都设 `SO_REUSEADDR` 的 UDP 套接字重复绑定同地址同端口（单播只投给其一），所以 Linux 的 UDP 不设该选项。对应测试见下文第 6 节。

一处有意保留的直接系统调用：

- `getifaddrs`（枚举本机接口）：`DirectInterface.enumerateCandidates`（`Sources/DSCore/DirectInterface.swift`），位于 `#if os(Windows)` 之外；Windows 分支不枚举，直连钉绑按「无匹配」处理。

主机名解析（解析 `roboRIO-<队号>-FRC.local`）已收口到 `SocketCompat.resolveIPv4Hosts`（`Sources/DSCore/SocketCompat.swift`），由 `DSClient.scheduleMDNSResolveLocked` 调用：Darwin / Linux 用 `getaddrinfo`，Windows 用宽字符版 `GetAddrInfoW` / `FreeAddrInfoW`。`getaddrinfoA` 在 `ws2tcpip.h` 里是宏别名，WinSDK 模块并不导入——2026-11-24 首次真实 Windows 运行实测 `cannot find 'getaddrinfoA' in scope`，此后才把解析分支从业务文件移进本层。该函数先调用 `SocketCompat.ensureInitialized()`——它可能先于任何套接字创建被执行。

### 3. SHA1：握手摘要用纯 Swift

`Sources/DSCore/SHA1.swift`（FIPS 180-1 / RFC 3174，74 行）。`NT4Server.websocketAcceptKey(for:)`（`Sources/DSCore/NT4Server.swift:312–313`）用它计算 `Sec-WebSocket-Accept`。只用于握手校验，不是安全用途；不引入 CryptoKit（仅 Apple）或三方库。

### 4. StringsTable：OpenStep 文本 `.strings` 的纯 Swift 解析

`Sources/DSCore/StringsTable.swift` 的 `OpenStepStringsTable.parse`（:10–13）：支持 `/* */` 与 `//` 注释、`\" \\ \n \r \t \uXXXX` 转义与未加引号的键值；坏条目（缺等号、无值、引号未闭合）跳过不入表，不影响其余条目；重复键取后者。

`Sources/DSCore/Localization.swift` 的 `EnglishStrings.load()`（:96–107）先按文件头判断：`bplist` 或 `<?xml` 开头交给 `PropertyListSerialization` 兜底，否则交给本解析器——三个平台走同一条路径，不再依赖 `Bundle.localizedString`。`LanguageManager` 的 `ObservableObject` 只在 `canImport(Combine)` 时声明（:2–4、:39–43、:87–89）；Linux/Windows 上 `effective` 是普通属性。

### 5. SettingsStore：类型判定不依赖 CoreFoundation

`Sources/DSCore/RadioProbe.swift:73` 起，按 plist 的持久化形态判定类型（整数 `<integer>`、浮点 `<real>`、布尔、字符串），不再查 `CFBoolean`/`CFNumber` 的类型 ID。语义不变：类型不符按损坏处理并返回空，不跨类型读。

### 6. 三端验证的是同一个 commit

`scripts/validate-all.sh` 是三端的唯一入口（Mac 本机、实体 Linux SSH 主机、GitHub Actions Windows）。三端必须验证同一个提交，否则「全绿」没有意义：

- **预检先行**：环境变量、所需工具、仓库根、Mac 必需脚本齐全、工作树干净、HEAD 已推送且与 `origin` 一致（一次只读 `git ls-remote`）、`gh auth status`、workflow 文件已提交。任何一项不过，就不运行任何测试、SSH 或 Actions 调用。
- **Mac** 跑当前 HEAD（工作树干净，所以磁盘内容等于 HEAD）；Mac 开始前固定 `HEAD_SHA`，Linux 与 Windows 均消费该 SHA，Linux 结束与三端汇总前再次复核 HEAD，任何变化都失败。清单 = 8 个必需基础脚本（缺任一即 fail-closed）+ 自动发现的全部 `scripts/test-*.sh`，去重后每个脚本只跑一次：必需脚本按声明顺序（快到慢），其余按路径名排序。
- **Linux**：`git archive <HEAD_SHA>` 经 stdin 送入远端 `tar -xf -`，解包到远端每次 `mktemp -d` 新建的独立目录。只传已提交的跟踪文件——不含 `.git`、未跟踪文件与任何本地文件；不做删除式同步；退出（含失败与 Ctrl-C）只删除本次创建的那一个目录。归档前用 `df -Pk /tmp /` 确认两个挂载点各有至少 1 GiB 可用空间，不足即明确失败，不运行 `DSCoreTests`。远端 PATH 使用实际探测成功的 `MATCHSTICKS_DS_LINUX_SWIFT_BIN`；`SWIFTPM_CACHE_PATH` 与 `CLANG_MODULE_CACHE_PATH` 指向本次临时目录，`SWIFTPM_MANIFEST_CACHE=local` 将 manifest cache 留在该包的远端 build 目录，避免写入根分区默认缓存位置。
- **Windows**：消费 GitHub Actions 上 `headSha` 等于同一 SHA 的运行。`pull_request`（目标 beta/stable）、beta/stable 的 `push` 与此前对本分支的 `workflow_dispatch` 运行一并消费，全部成功才算通过。一条都没有时才 `dispatch`，且至多一次；workflow 尚未进入默认分支、`dispatch` 不可用时立即失败并给出处置办法，不空等、不重发。
- **GitHub 调用纪律**：任何 `gh` 调用失败即停并报告，不自动重试；`dispatch` 只在「没有同 SHA 的运行且 workflow 处于启用状态」时发生一次。
- **汇总**：三行各记同一个 `commit=<SHA>`，三端全部通过时才输出一致性结论。

`scripts/test-core.sh` 是三平台共用的核心回归入口：只构建并运行 `DSCoreTests`（自带 runner，不依赖 XCTest），Sparkle 与 SwiftUI 主程序不参与。

`.github/workflows/full-validation.yml` 是 Windows 一端：`windows-2025` 原生 Swift（swift.org 6.4.2 固定安装 URL，安装后校验版本）、`actions/checkout` 钉完整提交 SHA，并以 `github.event.pull_request.head.sha || github.sha` 显式选择 checkout ref——PR 验证精确 head，不验证 `refs/pull/N/merge`；push 与 dispatch 回退到 `github.sha`。随后经 vcvarsall 与显式的 Git Bash 路径运行 `scripts/test-core.sh`。触发器为 `pull_request`（目标 beta/stable）、`push`（beta/stable）与 `workflow_dispatch`。项目自 2026-10-04 起停用 GitHub Actions；本次由产品所有者点名，仅为 Windows 验证恢复，且全仓库只有这一个 job。

## 影响

- DSCore 的每个平台差异都收口在 `SocketCompat.swift` 一处，新增平台相关行为时只有这里需要条件编译；业务文件里的 `#if` 只剩三个文件：`DSClient`（libc 导入）、`DirectInterface`（libc 导入、Linux 的 `tun/tap` 虚拟网卡前缀、旧内核不支持 `SO_BINDTOIFINDEX` 时按无匹配处理、Windows 不枚举接口）与 `Localization`（Combine）。
- 协议、控制环、看门狗、安全闩锁的回归证据从「一台 Mac」扩展为三个平台的同一套断言。
- 代价：`SocketCompat` 是一层薄封装，调用点比直接写系统调用略长；Windows 分支在本机无法编译，只能靠真实 CI 验证（见下）。
- 产品范围、分发方式、打包与签名链路均不变。

## 备选方案

- **只在 macOS 上验证，Linux/Windows 靠代码审查**：零成本，但「平台无关的核心」没有任何执行证据，Windows 的 Winsock 差异（重绑语义、`SIO_UDP_CONNRESET`、句柄宽度）审查不出来；不采用。
- **引入 Network.framework（`NWListener`/`NWConnection`）统一三平台**：Apple 的网络栈在 macOS 27 beta 上 `NWListener` 对本项目的端口返回 `EINVAL`（见项目协作约定「待定项」），且 Linux/Windows 上没有；不采用。
- **引入跨平台网络库（SwiftNIO 等）**：会打破 DSCore 零外部依赖，并把协议时序交给第三方；DS 需要对原始套接字行为（绑定、接口钉绑、超时分类）有完全控制；不采用。
- **用 CryptoKit 之外的系统加密库算 SHA-1**：三平台 API 各不相同，且握手摘要不需要密码学强度；74 行纯 Swift 实现更小、更可测；不采用。
- **Linux 端用 `rsync` 同步整个工作树**：会把未提交改动和本地文件带到远端，三端验证的不再是同一个 commit；改用 `git archive <固定 SHA>`；不采用。

## 验证与后续

- **测试**：`Tests/DSCoreTests/PortabilityTests.swift` 的 10 项测试注册在 `Tests/DSCoreTests/main.swift`，三平台同一套断言——WebSocket 握手摘要向量（含 55/56/64/119/120 字节分组边界与多字节 UTF-8）、IPv4 解析与格式化（文法对齐 `inet_pton`）、地址构造、主机名解析为 IPv4 列表（`getaddrinfo` / `GetAddrInfoW`）、OpenStep `.strings` 解析、`SettingsStore` 类型判定、仅经 `SocketCompat` 的回环 UDP/TCP 往返、同地址同端口独占绑定、UDP 对「对端端口不可达」的表现，以及一条静态守卫 `socketCompatBoundary`：`Sources/DSCore` 里除 `SocketCompat.swift` 外不得直接调用套接字 C API（Swift 方法调用与声明、`getifaddrs` 一处有意例外不算；`getaddrinfo` / `GetAddrInfoW` 同样在禁止之列——2026-11-24 首次真实 Windows 运行后补入）。这条守卫补的是 Windows 可移植性的缺口：`DSClient` 曾对连接结果里要丢弃的已连接套接字直接调 C `close(fd)`，在 macOS 上完全正常，Windows 上则必须 `closesocket`——本机编译不了 Windows 分支，行为测试在 macOS 上也区分不了两种写法，所以用三端都能执行的静态守卫拦住（修复前该测试为 RED）。原有测试里的原始 BSD 调用全部切到 `SocketCompat`；Windows 不实现的接口钉绑处给出明确断言（`.noMatch`/`nil`），不假绿。
- **Mac**：`swift build`（全部 target）与 `scripts/test-core.sh` 通过（0 failures）。
- **Linux**：实体 Linux 主机的 Swift 工具链已准备，非交互 SSH 可通过 `MATCHSTICKS_DS_LINUX_SWIFT_BIN` 使用已验证的 swift；但 `DSCoreTests` 仍待在该主机真实运行。此前的交叉编译与本次离线脚本/夹具检查都不是运行验证。
- **Windows**：本机无法编译 Windows 分支。`SocketCompat` 的 Windows 路径按 SDK 头文件逐项核对过（`FIONBIO`、`SO_EXCLUSIVEADDRUSE`、`SD_BOTH`、`SIO_UDP_CONNRESET` 的取值，`SOCK_DGRAM`/`AF_INET`/`WSAE*` 可导入），但编译与运行都需要 `.github/workflows/full-validation.yml` 在 GitHub 托管的 Windows 上真跑。
- **脚本**：`scripts/test-validation-scripts.sh` 覆盖 workflow 精确 head checkout、`ss` UDP 本地地址样例、`git archive <固定 SHA>`、HEAD 变化失败、磁盘空间预检、缓存隔离、Swift PATH 与全部 `test-*.sh` 自动发现；`validate-all` 流程使用临时目录和 mock 的 git/swift/ssh/gh，夹具运行时文件位于被忽略的 `.build/`，测试脚本本身入库。真实的 SSH、Linux `DSCoreTests` 与 Actions 链路仍未在本次修复中运行。
- 后续：若 `DSCore` 开始依赖 Apple 专有框架，或产品范围扩展到 Linux/Windows，必须新增 ADR 并重新评估本 ADR 的第 1 节。

## 相关文档

- [ADR-0001：产品更名为 MatchSticks DS](0001-matchsticks-ds-rename.md)
- [可行性研究报告](../../可行性研究报告.md)
- [scripts/validate-all.sh](../../scripts/validate-all.sh)、[scripts/test-core.sh](../../scripts/test-core.sh)、[.github/workflows/full-validation.yml](../../.github/workflows/full-validation.yml)
