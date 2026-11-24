# MatchSticks DS

**macOS 原生 FRC Driver Station** —— 同时支持 roboRIO 1.0 / roboRIO 2.0（NI 协议）与 SystemCore（MRCCOMM V2 协议，实验性）的驾驶台，严格遵循 Apple 设计语言（SwiftUI 原生）。应用本体只在 macOS 构建与分发；2026-11-23 起验证矩阵覆盖 macOS / Windows / Linux 三平台，但跨平台验证的对象仅是 `DSCore` 协议核心与回归测试（App / UI / E2E 只在 Mac 跑）——**不提供 Windows / Linux 版 App**（见[分支模型](#分支模型)）。协议核心可移植性 ADR：[ADR-0005](docs/decisions/0005-portable-dscore-validation.md)。

> ⚠️ **Practice Only**：所有第三方 DS 均不得用于正式比赛（规则 R710/R901）。本项目定位为练习、调试与台架测试工具。
>
> 📦 当前状态：**Phase 1–4（无硬件部分）完成**（2026-10-01：Apple 全量 UI 重做、Sparkle 应用内自动更新、内置 WebUI、摄像头 MOCK 通道、0x2E 手柄输出协议侧、打包版 E2E、分发配套；发布线当前 v0.1.0-alpha.7）。剩余为真机联调项——照单执行见 [docs/bench-checklist.md](docs/bench-checklist.md)。完整论证见 [可行性研究报告](可行性研究报告.md)。

## 功能（当前版本）

- **连接**：roboRIO 1.0/2.0 NI 协议——UDP 1110 控制环（20ms / 50Hz）+ UDP 1150 遥测回传 + TCP 1740 慢速通道；目标自动轮换（mDNS `roboRIO-<队号>-FRC.local` → 静态 `10.T.E.2` → USB `172.22.11.2`），支持手动 IP；机器人 socket 自动绑定同子网物理网卡，Clash Verge 系统代理 / TUN（规则、全局、直连）下均保持直连，无需添加分流规则
- **操作**：Teleop / Autonomous / Test 模式、Enable / Disable / **E-Stop**（协议位直发 + FMS 全场 Foghorn 音效）、E-Stop 复位（First DS 语义）、Alliance 站位（R1–B3）、使能计时、Practice 比赛时间线（2022–2026 官方预设与阶段音效 + 2026 Transition/Alliance Shifts/Endgame + 2022 八分钟 Timeout 提示 + 可拖动分段时长 + A-Stop）、远程 Reboot roboRIO / Restart Robot Code
- **界面**：Apple 原生风格（实色自适应表面、无模糊/材质装饰）——侧栏导航（操作/监测两组，底部设置/权限）+ 每页常驻安全控制条（使能/失能/急停 + 状态解释）；状态条：机器人状态、通信/程序/手柄指示、电池电压（brownout 红字警示）；队伍号常驻侧栏；迷你驾驶台独立小窗（状态 + 三键 + 电池）
- **手柄**：IOHIDManager 枚举所有 HID 设备（含 Attack3 / Extreme 3D Pro 等非游戏标准手柄）、槽位排序 + **槽位锁定**、轴 / 按键 / POV 实时显示
- **机器人**：独立页——链路检查（通信 / 无线电指示灯、丢包率）、每核 CPU、内存、磁盘、CAN 总线指标（利用率 / BusOff / TxFull / 错误计数）、电源故障计数、TCP 版本信息；历史曲线（电池电压、每核 CPU、UDP 链路质量，Swift Charts 原生）——原诊断与图表两页的机器人内容合并于此
- **消息**：robot stdout 控制台、错误消息（TCP 0x0B）、DS 事件流
- **抓包录制/回放**：Settings 页一键录制收发包为 `.dsrec`（金样本回归基线）；模拟器 `--replay` 按录制的真机字节应答
- **SystemCore（MRC V2 · 实验性）**：Connection 页切换机器人类型；UDP V2 控制环（CRC32C 应答校验）+ NT4 server（6767，OpMode 选择经 ControlData.CurrentOpMode 下发）+ TCP 0x13 OpMode 列表
- **会话日志**：连接期间 1Hz 自动记录 `.dslog`（NI DS 格式）与 `.wpilog`（WPILib DataLog 2027 VarInt 格式）双文件，AdvantageScope 可直接打开复盘
- **Mac 状态**：独立页——DS 电脑电池/交流供电、系统 CPU、进程内存、本机网络指示（WiFi/有线）
- **控制环稳定性**：统计窗口的收/发计数在浮点域求差并夹取（rx > tx 在真机可达——sendto 失败而先前应答在途、或机器人重复应答），避免旧实现的 UInt64 下溢把进程在控制环线程上打崩（2026-09-19 崩溃报告修复，回归测试 statsUnderflowScenario）；应用另声明 latency-critical 活动以抑制 App Nap 节流
- **安全机制**：UI 主线程心跳看门狗（冻结 >200ms 自动冻结使能输出，robot 侧失包自动 disable）；通信失联 >1.25s 自动失能；使能门禁（无连接 / E-Stop 锁存 / 看门狗异常时拒绝使能，`SafetyGate` 纯逻辑单测覆盖）
- **应用内更新（Sparkle）**：**stable / beta 两条更新通道**；GitHub 不可达时按退避持续重试（不阻塞使用）→ 发现新版即后台下载 → 界面固定一隅的**圆形更新按钮**，点击展开为胶囊显示下载百分比 → 100% 后转为可点态，点击**经安全门放行**一键重启安装；**安全门**：机器人使能中 / 通信活跃 / 急停锁存期间点击无效（tooltip 说明）——仅「失能 + 未连接 + 无锁存」放行；无强制升级、无全屏弹窗
- **内置 WebUI**：`http://127.0.0.1:6768`（仅本机）——日志文件列表与下载、设置查看/覆盖（逐键校验）、连接/使能/急停/更新门状态页
- **摄像头（MOCK）**：独立页显示槽位（点按刷新 + ≥1s 限流）；真实 SystemCore 流协议未核查（协议档案待实测），现由 MatchSticksDSSim 提供自定义 MOCK 图像源（:6769）
- **手柄输出（0x2E）**：MRC 应答中的 rumble/LED 输出实时呈现于手柄页（协议侧已核查——编码金样本 + 模拟器端到端同值；物理手柄震动映射待真机）
- **快捷键**：`Space` = E-Stop · `Enter` = Disable · `[ + ] + \` = Enable · `Esc + I` = E-Stop 复位 · `F1` = 重扫手柄（应用前台；全局后台键属 Phase 4 + Input Monitoring 权限）

## 内置 roboRIO 模拟器

`MatchSticksDSSim` 在本机扮演 roboRIO（1110/1150/1740 全端口，模拟电池 / CPU / CAN / stdout / 错误流与 reboot / E-Stop / 重启代码时序），**无需实体机器人即可全流程联调**：

```bash
# 终端 A
.build/debug/MatchSticksDSSim
# 终端 B（MATCHSTICKS_DS_AUTO_SIM=1 自动连接 127.0.0.1）
MATCHSTICKS_DS_AUTO_SIM=1 .build/debug/MatchSticksDS
# SystemCore（MRC V2）模式
.build/debug/MatchSticksDSSim --mrc
MATCHSTICKS_DS_AUTO_SIM=1 MATCHSTICKS_DS_AUTO_MRC=1 .build/debug/MatchSticksDS
```

兼容：旧 `GHDS_AUTO_SIM` / `GHDS_AUTO_MRC` 环境变量仍会被读取；新脚本与文档统一使用 `MATCHSTICKS_DS_*`。

第三方异构联测：Compatibility Proxy 的 `robot_sim.py`（独立 Python 实现）可直接对接本 DS——实测 UDP V2 控制流、TCP 0x13 OpMode、NT4 26 主题发布/订阅与 45Hz ControlData 下发全部互通。

或在应用内：Connection → 「启动 roboRIO 模拟器」（自动切换手动 IP 并连接）。

**回放模式**（Phase 0「录制即测试」）：

```bash
# DS 侧开启抓包录制（Settings 页开关，存至 ~/Library/Application Support/MatchSticksDS/captures/）
# 然后用录制文件驱动模拟器应答——DS 端解析与真机逐字节一致：
.build/debug/MatchSticksDSSim --replay capture-20260916-020000.dsrec
```

## 从源码构建

要求：macOS 14+、**完整 Xcode**（SwiftUI 宏需要；Command Line Tools 缺 `SwiftUIMacros` 插件）。

`scripts/validate-all.sh` 在 Mac **自动发现并逐个执行全部 `scripts/test-*.sh`**（新增脚本自动纳入，不维护手工清单）；下列命令只是本地子集，不能替代三平台全量验证。

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer  # 完整 Xcode（本机已无 Xcode-beta；装了多版本时按实际路径调整）
swift build
scripts/test-core.sh    # 完整 DSCoreTests（协议金样本/容错 + 安全门禁/时序机/录制回放/迁移/双语/WebUI/SocketCompat；0 failures）
scripts/test-ui.sh      # UI 状态干测试（不起 socket 与 HID；0 failures）
swift run MatchSticksDS   # 运行驾驶台
scripts/test-update.sh  # Sparkle 本地升级链路 E2E + 安全门双阻断（会启动 App，由主代理串行运行）
scripts/test-e2e.sh     # 打包版 E2E（会启动 App 与模拟器，由主代理串行运行）
scripts/validate-all.sh # 三平台全量验证统一入口：Mac 全量 + Linux/Windows 完整 DSCoreTests（见「分支模型」）
```

## 安装（GitHub Releases）

1. 从 [Releases](https://github.com/LYT259/MatchSticks-DS/releases) 下载 `MatchSticks-DS-<版本>.dmg`，打开并拖入 Applications；
2. 首次启动：macOS 15+ 需到 **设置 → 隐私与安全性 → 「仍要打开」**（未公证分发的免费方案，每台机器一次性；详见报告 §5.5）；
3. 连接机器人时允许「本地网络」权限（**机器人连不上第一嫌疑**）；终端 / SSH 启动豁免此权限；
4. 应用内更新分 **stable** / **beta** 两条通道，读的是**同一个 appcast**（`releases/latest/download/appcast.xml`，即当前 Latest Release 的 `appcast.xml` 附件）：不带 `<sparkle:channel>` 的 stable 默认条目所有客户端可见，带 `<sparkle:channel>beta</sparkle:channel>` 的条目仅 beta 通道客户端可见；两条通道都经同一安全门安装。功能合入 `beta` 且三端全量通过后创建对应 beta Pre-release，并在**同一次 beta 发布操作**里把 beta 条目并入当前 Latest 的 appcast（stable 默认条目原样不动），未全绿不得发布；stable Latest 仍需用户批准 stable 链（合并与发版均须用户明确授权）。发布规则见 [发版工具包](docs/release-kit.md)。

> **生产自动更新可用性前提（2026-11-24 回读，部分满足）**：仓库现为 Public，匿名 Latest appcast 返回 200；Cloudflare 镜像尚未部署。镜像部署并回读、真实客户端升级实测通过之前，**不得宣称现网应用内更新可用**，本地升级 E2E 也不构成生产可用证据。
>
> **Release 标题与 Pre-release 规则（2026-11-24 起）**：GitHub Release 标题只写版本号（= tag，如 `v0.1.0-alpha.8`），不得在标题写改动内容、功能名、Phase、摘要或破折号；改动内容只放 Release 正文。GitHub 仓库首页与 Releases 页顶部只突出 Latest，完整列表才会展示所有带 Pre-release 标记的版本——所以每个合入 `beta` 且三端全量通过的功能都有一个对应的 beta Pre-release（不标记为 Latest）。历史 Release 本轮不改写，批量改历史须另行点名。

安装 / 校验：

```bash
# 终端下载（仓库现为 Public：直链可匿名 curl）
curl -L <release-dmg-url> -o MatchSticks-DS.dmg && hdiutil attach MatchSticks-DS.dmg
# 校验
shasum -a 256 -c SHA256SUMS
```

> 终端一行安装（SHA256 校验后装 /Applications）：`curl -fsSL https://raw.githubusercontent.com/LYT259/MatchSticks-DS/<ref>/scripts/install.sh | bash`（发版后生效）。Homebrew tap（`LYT259/homebrew-matchsticks-ds`，cask `matchsticks-ds`）与国内镜像：**待建**（物料已备，见 packaging/ 与 mirror/）。

## 打包发布

```bash
scripts/build-app.sh 0.1.0-alpha.1   # universal .app + ad-hoc 签名 + DMG + SHA256SUMS
```

## 仓库结构

```
Sources/DSCore/               协议核心：NI 编解码、20ms 控制环、看门狗、连接管理（平台无关）
Sources/MatchSticksDS/        SwiftUI 应用：DSModel 状态源、九页 UI + 迷你驾驶台、DSStyle 设计系统、HID、快捷键
Sources/MatchSticksDSSim/     roboRIO 模拟器（本机端到端验证）
Tests/DSCoreTests/            协议回归测试（自带 runner）+ 回环集成测试
Tests/MatchSticksDSUITests/   UI 状态干测试（无 socket/HID/定时器；scripts/test-ui.sh 运行）
scripts/             图标生成 + 打包/签名工具 + 安装脚本 + 自动发现的 test-*.sh（核心 / UI / 图标 / 文档 / 升级与打包 E2E）+ 三平台全量验证统一入口（validate-all.sh）
.github/workflows/   仅 Windows 全量验证（GitHub Actions 在本项目的唯一用途）
packaging/           Homebrew cask 模板（自维护 tap 用）
mirror/              Cloudflare Pages 镜像（下载页 + appcast 镜像；部署待定）
docs/                协议档案 / 发版操作单（release-kit）/ 真机台架手册（bench-checklist）/ 架构决策记录（decisions/）
```

## 分支模型

`feat/*`、`fix/*`、`docs/*` → PR → **beta**（集成分支）→ 累计用户可感知改动达标后提醒用户 → **用户明确同意** → 重新跑三平台全量验证 → **stable**（稳定分支名 = `stable`；**主干与发布基线**，仓库默认分支；Latest Release 从 stable 打 tag）。GitHub Releases 的标题只写版本号（= tag）：合入 `beta` 且三端全量通过的功能先有对应的 beta Pre-release（不标记为 Latest），`stable` 发布后才标记为 Latest Release——规则见 [发版工具包](docs/release-kit.md) 第六节。

### 三平台全量验证（发版门禁）

- **平台**：macOS（本机）、Linux（配置的实体 SSH 主机）、Windows（GitHub Actions——本项目唯一允许的 Actions 用途）；
- **时机**：**所有合入 `beta` 的改动**之后——不论 `feat/`、`fix/`、`docs/` 等分支前缀，也不论代码 / 文档 / 测试 / CI 改动，没有豁免；stable 合并前（用户同意后在待合并的 beta 树上重新跑，不沿用旧结果）；
- **通过标准**：三端实际运行并全部通过才算通过；失败 / 未运行 / 跳过一律不算通过，任一端未通过不得继续（不得合 stable、不得发版）；
- **执行范围**：Mac 自动发现并逐个执行全部 `scripts/test-*.sh`，覆盖完整 `DSCoreTests` 与 macOS App / UI / E2E；Linux / Windows 各自运行完整 `DSCoreTests`（`scripts/test-core.sh` / `.github/workflows/full-validation.yml`，不做抽样或过滤），不构建、不运行 Windows / Linux App。三端全过 ≠ Windows / Linux 上有可用 App；
- **同一 SHA 预检**：任何平台测试开始前，要求工作树干净、当前分支已推送、本地 `HEAD` 与 `origin/<branch>` 一致；Mac 只在该树运行，Linux 只同步该树，Windows 只接受相同 `headSha` 的 run。不一致即失败，不复用其他 SHA 的结果；
- **运行前提**：`MATCHSTICKS_DS_LINUX_SSH_HOST` 指向已配置的实体 Linux 主机、`gh` 已登录；脚本只做验证——不合并 beta/stable、不发 Release、不替换 `/Applications`；
- **beta → stable 的触发**：按自上个 stable 以来累计的用户可感知改动评估——一个值得写进 Release notes 的新功能 / 显著改进，或一批明显修复；纯内部 CI / docs / 重构不算。完成 beta 交付时只提醒「可能可以合并」，合并与发版等用户明确同意；
- **统一入口**：`scripts/validate-all.sh`（与三平台核心任务一同交付）；**脚本存在或能跑 ≠ 验证通过**，证据以实际运行输出（记入工程日志）为准。

决策记录见 [ADR-0003](docs/decisions/0003-three-platform-validation.md)；更新通道与连通性决策见 [ADR-0004](docs/decisions/0004-update-channels-and-connectivity.md)；协议核心可移植性 ADR：[ADR-0005](docs/decisions/0005-portable-dscore-validation.md)。

## 路线图（报告 §9）

| 阶段 | 内容 | 状态 |
|---|---|---|
| Phase 1 | NI 协议栈 + Apple 风格核心 UI（roboRIO 1/2 可用 MVP） | ✅ 完成 |
| Phase 2 | NI 全功能：Practice ✅、dslog + WPILog ✅、Charts ✅、Dashboard 启动 ✅、DS 自身监控 ✅（XInput 震动待硬件：GCDeviceHaptics 引擎链路 + 实物手柄） | ✅ 基本完成 |
| Phase 3 | MRCCOMM V2 协议栈 ✅（金样本验证）+ NT4 server（6767，异构联测通过）+ OpMode 选择 ✅（Alerts/Display 待真机核对） | ✅ 协议层完成 |
| Phase 4 | 迷你视图 ✅、权限引导页 ✅、应用内更新（Sparkle，含安全门与本地升级链路 E2E）✅、内置 WebUI ✅、摄像头 MOCK 通道 + DS 槽位 ✅（真实协议待真机）、0x2E 手柄输出协议侧 ✅（物理震动待真机）、打包版 E2E ✅、分发配套 ✅；余全局后台快捷键与真机联调项（[台架手册](docs/bench-checklist.md)） | ✅ 无硬件部分完成 |

## 改名与兼容（2026-11-22）

本仓库自 2026-11-22 起由 **GH Driver Station** 更名为 **MatchSticks DS**（仓库 `LYT259/MatchSticks-DS`）。兼容约定：

- 应用 bundle ID 保持 `org.ghfrc.driverstation`，设置域与 Sparkle 更新链延续；旧版可直接用新版应用替换，旧数据按下方规则迁移；
- 设置键使用新前缀 `matchsticks.`，新键缺失时回退读取旧 `ghds.*`；环境变量使用新前缀 `MATCHSTICKS_DS_`，旧 `GHDS_*` 继续兼容读取；
- 数据目录改为 `~/Library/Application Support/MatchSticksDS`，启动时从旧 `GHDriverStation` 保留式迁移——旧目录与旧数据不删除、不覆盖；
- `.dsrec` 魔数保持 `GHDSREC1`，旧录制文件可直接回放；Sparkle Ed25519 密钥路径不变。

完整映射与兼容理由见 [ADR-0001](docs/decisions/0001-matchsticks-ds-rename.md)。

## 许可与合规

- 许可证：**Apache-2.0**（2026-09-15 定稿，见 [LICENSE](LICENSE)）；
- Practice Only：不得用于正式比赛（第三方 DS 一律不合法）；
- 协议事实来源：[docs/protocol/ds-protocol-2026.md](docs/protocol/ds-protocol-2026.md)（本项目权威协议档案，已核查/待实测两级）与 [frcnetworking.readthedocs.io](https://frcnetworking.readthedocs.io/)（2026-09-15 核查、2026-09-18 二次核对 Request 字节）。
