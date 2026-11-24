# MatchSticks Driver Station

**macOS 原生 FRC Driver Station** —— 同时支持 roboRIO 1.0 / roboRIO 2.0（NI 协议）与 SystemCore（MRCCOMM V2 协议，实验性）的驾驶台，严格遵循 Apple 设计语言（SwiftUI 原生）。

> ⚠️ **Practice Only**：所有第三方 DS 均不得用于正式比赛（规则 R710/R901）。本项目定位为练习、调试与台架测试工具。
>
> 📦 当前状态：**Phase 1–4（无硬件部分）完成**（2026-10-01：Apple 全量 UI 重做、Sparkle 应用内自动更新、内置 WebUI、摄像头 MOCK 通道、0x2E 手柄输出协议侧、打包版 E2E、分发配套；发布线当前 v0.1.0-alpha.6）。剩余为真机联调项——照单执行见 [docs/bench-checklist.md](docs/bench-checklist.md)。完整论证见 [可行性研究报告](可行性研究报告.md)。

## 功能（当前版本）

- **连接**：roboRIO 1.0/2.0 NI 协议——UDP 1110 控制环（20ms / 50Hz）+ UDP 1150 遥测回传 + TCP 1740 慢速通道；目标自动轮换（mDNS `roboRIO-<队号>-FRC.local` → 静态 `10.T.E.2` → USB `172.22.11.2`），支持手动 IP；机器人 socket 自动绑定同子网物理网卡，Clash Verge 系统代理 / TUN（规则、全局、直连）下均保持直连，无需添加分流规则
- **操作**：Teleop / Autonomous / Test 模式、Enable / Disable / **E-Stop**（协议位直发 + FMS 全场 Foghorn 音效）、E-Stop 复位（First DS 语义）、Alliance 站位（R1–B3）、使能计时、Practice 比赛时间线（2022–2026 官方预设与阶段音效 + 2026 Transition/Alliance Shifts/Endgame + 2022 八分钟 Timeout 提示 + 可拖动分段时长 + A-Stop）、远程 Reboot roboRIO / Restart Robot Code
- **界面**：Apple 原生风格（实色自适应表面、无模糊/材质装饰）——侧栏导航（操作/监测两组，底部设置/权限）+ 每页常驻安全控制条（使能/失能/急停 + 状态解释）；状态条：机器人状态、通信/程序/手柄指示、电池电压（brownout 红字警示）；队伍号常驻侧栏；迷你驾驶台独立小窗（状态 + 三键 + 电池）
- **手柄**：IOHIDManager 枚举所有 HID 设备（含 Attack3 / Extreme 3D Pro 等非游戏标准手柄）、槽位排序 + **槽位锁定**、轴 / 按键 / POV 实时显示
- **诊断**：每核 CPU、内存、磁盘、CAN 总线指标（利用率 / BusOff / TxFull / 错误计数）、电源故障计数、TCP 版本信息、网络指示灯、丢包率
- **图表**：电池电压曲线、每核 CPU、UDP 链路质量（Swift Charts 原生）
- **消息**：robot stdout 控制台、错误消息（TCP 0x0B）、DS 事件流
- **抓包录制/回放**：Settings 页一键录制收发包为 `.dsrec`（金样本回归基线）；模拟器 `--replay` 按录制的真机字节应答
- **SystemCore（MRC V2 · 实验性）**：Connection 页切换机器人类型；UDP V2 控制环（CRC32C 应答校验）+ NT4 server（6767，OpMode 选择经 ControlData.CurrentOpMode 下发）+ TCP 0x13 OpMode 列表
- **会话日志**：连接期间 1Hz 自动记录 `.dslog`（NI DS 格式）与 `.wpilog`（WPILib DataLog 2027 VarInt 格式）双文件，AdvantageScope 可直接打开复盘
- **本机状态**：DS 电脑电池/交流供电、系统 CPU、进程内存、本机网络指示（WiFi/有线）
- **控制环稳定性**：统计窗口的收/发计数在浮点域求差并夹取（rx > tx 在真机可达——sendto 失败而先前应答在途、或机器人重复应答），避免旧实现的 UInt64 下溢把进程在控制环线程上打崩（2026-09-19 崩溃报告修复，回归测试 statsUnderflowScenario）；应用另声明 latency-critical 活动以抑制 App Nap 节流
- **安全机制**：UI 主线程心跳看门狗（冻结 >200ms 自动冻结使能输出，robot 侧失包自动 disable）；通信失联 >1.25s 自动失能；使能门禁（无连接 / E-Stop 锁存 / 看门狗异常时拒绝使能，`SafetyGate` 纯逻辑单测覆盖）
- **应用内更新（Sparkle）**：启动静默查（GitHub Releases appcast）→ 静默后台下载 → 固定角落进度角标（可忽略、无弹窗）→ 点击一键重启安装；**安全门**：机器人使能中 / 通信活跃 / 急停锁存期间点击无效（tooltip 说明）——仅「失能 + 未连接 + 无锁存」放行；下载失败静默跳过下次再试
- **内置 WebUI**：`http://127.0.0.1:6768`（仅本机）——日志文件列表与下载、设置查看/覆盖（逐键校验）、连接/使能/急停/更新门状态页
- **摄像头（MOCK）**：诊断页显示槽位（点按刷新 + ≥1s 限流）；真实 SystemCore 流协议未核查（协议档案待实测），现由 MatchSticksDriverStationSim 提供自定义 MOCK 图像源（:6769）
- **手柄输出（0x2E）**：MRC 应答中的 rumble/LED 输出实时呈现于手柄页（协议侧已核查——编码金样本 + 模拟器端到端同值；物理手柄震动映射待真机）
- **快捷键**：`Space` = E-Stop · `Enter` = Disable · `[ + ] + \` = Enable · `Esc + I` = E-Stop 复位 · `F1` = 重扫手柄（应用前台；全局后台键属 Phase 4 + Input Monitoring 权限）

## 内置 roboRIO 模拟器

`MatchSticksDriverStationSim` 在本机扮演 roboRIO（1110/1150/1740 全端口，模拟电池 / CPU / CAN / stdout / 错误流与 reboot / E-Stop / 重启代码时序），**无需实体机器人即可全流程联调**：

```bash
# 终端 A
.build/debug/MatchSticksDriverStationSim
# 终端 B（MATCHSTICKS_DRIVER_STATION_AUTO_SIM=1 自动连接 127.0.0.1）
MATCHSTICKS_DRIVER_STATION_AUTO_SIM=1 .build/debug/MatchSticksDriverStation
# SystemCore（MRC V2）模式
.build/debug/MatchSticksDriverStationSim --mrc
MATCHSTICKS_DRIVER_STATION_AUTO_SIM=1 MATCHSTICKS_DRIVER_STATION_AUTO_MRC=1 .build/debug/MatchSticksDriverStation
```

兼容：旧 `MATCHSTICKS_DS_AUTO_SIM` / `MATCHSTICKS_DS_AUTO_MRC`（及更早 `GHDS_AUTO_SIM` / `GHDS_AUTO_MRC`）环境变量仍会被读取；新脚本与文档统一使用 `MATCHSTICKS_DRIVER_STATION_*`。

第三方异构联测：Compatibility Proxy 的 `robot_sim.py`（独立 Python 实现）可直接对接本 DS——实测 UDP V2 控制流、TCP 0x13 OpMode、NT4 26 主题发布/订阅与 45Hz ControlData 下发全部互通。

或在应用内：Connection → 「启动 roboRIO 模拟器」（自动切换手动 IP 并连接）。

**回放模式**（Phase 0「录制即测试」）：

```bash
# DS 侧开启抓包录制（Settings 页开关，存至 ~/Library/Application Support/MatchSticksDriverStation/captures/）
# 然后用录制文件驱动模拟器应答——DS 端解析与真机逐字节一致：
.build/debug/MatchSticksDriverStationSim --replay capture-20260916-020000.dsrec
```

## 从源码构建

要求：macOS 14+、**完整 Xcode**（SwiftUI 宏需要；Command Line Tools 缺 `SwiftUIMacros` 插件）。

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer  # 按本机 Xcode 路径调整
swift build
swift run DSCoreTests   # 协议回归（协议金样本/容错 + 安全门禁/更新安全门/时序机/录制回放/POV 归一化单测 + TCP 1740 正向端到端 + E-Stop 锁存/重启断联/看门狗冻结/brownout/30s 长跑/录制回放全链路/MRC 正反向/0x2E 端到端/NT4 握手/WebUI 路由与回环/MOCK 摄像头 场景级集成测试；门禁以 0 failures 为准，不绑定固定检查数）
scripts/test-ui.sh      # UI 状态干测试（状态文案/安全门禁/急停锁存与复位快照/连接草稿/设置隔离与地址警告/状态日志/更新流状态机与安全门联动语义；不起 socket 与 HID；门禁以 0 failures 为准，不绑定固定检查数）
swift run MatchSticksDriverStation   # 运行驾驶台
scripts/test-update.sh  # Sparkle 本地升级链路 E2E：9.9.8→9.9.9 全流程 + 安全门双阻断
scripts/test-e2e.sh     # 打包版 E2E：进程存活 + 控制环吞吐 ≥40Hz + connected + Radio 事件 + 日志落盘 + 正式设置未变
```

## 安装（GitHub Releases）

1. 从 [Releases](https://github.com/LYT259/MatchSticks-Driver-Station/releases) 下载 `MatchSticks-Driver-Station-<版本>.dmg`，打开并拖入 Applications；
2. 首次启动：macOS 15+ 需到 **设置 → 隐私与安全性 → 「仍要打开」**（未公证分发的免费方案，每台机器一次性；详见报告 §5.5）；
3. 连接机器人时允许「本地网络」权限（**机器人连不上第一嫌疑**）；终端 / SSH 启动豁免此权限。

安装 / 校验：

```bash
# 终端下载（仓库现为 Private：直链 curl 需带 GitHub 凭证，浏览器下载不受影响）
curl -L -H "Authorization: Bearer <token>" <release-dmg-url> -o MatchSticks-Driver-Station.dmg && hdiutil attach MatchSticks-Driver-Station.dmg
# 校验
shasum -a 256 -c SHA256SUMS
```

> 终端一行安装（SHA256 校验后装 /Applications）：`curl -fsSL https://raw.githubusercontent.com/LYT259/MatchSticks-Driver-Station/<ref>/scripts/install.sh | bash`（发版后生效；远端仓库改名完成前新 URL 尚不可达，见 ADR-0003 先决条件）。Homebrew tap（`LYT259/homebrew-matchsticks-driver-station`，cask `matchsticks-driver-station`）与国内镜像（Cloudflare Pages 项目 `matchsticks-driver-station-mirror`）：**待建**（物料已备，见 packaging/ 与 mirror/）。

## 打包发布

```bash
scripts/build-app.sh 0.1.0-alpha.1   # 产出 dist/MatchSticks-Driver-Station-0.1.0-alpha.1.dmg（universal .app + ad-hoc 签名）+ SHA256SUMS
```

## 仓库结构

```
Sources/DSCore/                        协议核心：NI 编解码、20ms 控制环、看门狗、连接管理（平台无关）
Sources/MatchSticksDriverStation/      SwiftUI 应用：DSModel 状态源、八页 UI + 迷你驾驶台、DSStyle 设计系统、HID、快捷键
Sources/MatchSticksDriverStationSim/   roboRIO 模拟器（本机端到端验证）
Tests/DSCoreTests/                     协议回归测试（自带 runner）+ 回环集成测试
Tests/MatchSticksDriverStationUITests/ UI 状态干测试（无 socket/HID/定时器；scripts/test-ui.sh 运行）
scripts/                               图标生成 + 打包/签名工具 + 安装脚本 + 三套测试脚本（UI 干测试 / 升级链路 E2E / 打包版 E2E）
packaging/                             Homebrew cask 模板 `matchsticks-driver-station`（自维护 tap `LYT259/homebrew-matchsticks-driver-station` 用）
mirror/                                Cloudflare Pages 镜像 `matchsticks-driver-station-mirror`（下载页 + appcast 镜像；部署待定）
docs/                                  协议档案 / 发版操作单（release-kit）/ 真机台架手册（bench-checklist）/ 架构决策记录（decisions/）
```

## 分支模型

`feat/*`、`fix/*` → PR → **beta**（集成分支）→ 用户点名验证后 → **stable**（**主干与发布基线**，仓库默认分支；Releases 从 stable 打 tag）。

## 路线图（报告 §9）

| 阶段 | 内容 | 状态 |
|---|---|---|
| Phase 1 | NI 协议栈 + Apple 风格核心 UI（roboRIO 1/2 可用 MVP） | ✅ 完成 |
| Phase 2 | NI 全功能：Practice ✅、dslog + WPILog ✅、Charts ✅、Dashboard 启动 ✅、DS 自身监控 ✅（XInput 震动待硬件：GCDeviceHaptics 引擎链路 + 实物手柄） | ✅ 基本完成 |
| Phase 3 | MRCCOMM V2 协议栈 ✅（金样本验证）+ NT4 server（6767，异构联测通过）+ OpMode 选择 ✅（Alerts/Display 待真机核对） | ✅ 协议层完成 |
| Phase 4 | 迷你视图 ✅、权限引导页 ✅、应用内更新（Sparkle，含安全门与本地升级链路 E2E）✅、内置 WebUI ✅、摄像头 MOCK 通道 + DS 槽位 ✅（真实协议待真机）、0x2E 手柄输出协议侧 ✅（物理震动待真机）、打包版 E2E ✅、分发配套 ✅；余全局后台快捷键与真机联调项（[台架手册](docs/bench-checklist.md)） | ✅ 无硬件部分完成 |

## 改名与兼容（2026-11-22 / 2026-11-23）

本仓库自 2026-11-22 起由 **GH Driver Station** 更名为 **MatchSticks DS**，2026-11-23 二级更名为 **MatchSticks Driver Station**（仓库 `LYT259/MatchSticks-Driver-Station`）。兼容约定：

- 应用 bundle ID 保持 `org.ghfrc.driverstation`，设置域与 Sparkle 更新链延续；旧版可直接用新版应用替换，旧数据按下方规则迁移；
- 设置键前缀保持 `matchsticks.` 不变（新键缺失时回退读取旧 `ghds.*`；二级更名有意不引入新设置前缀）；环境变量使用 `MATCHSTICKS_DRIVER_STATION_*`，缺失时依次回退 `MATCHSTICKS_DS_*`、`GHDS_*`；
- 数据目录改为 `~/Library/Application Support/MatchSticksDriverStation`，启动时从 `MatchSticksDS` 与 `GHDriverStation` 链式保留式迁移——旧目录与旧数据不删除、不覆盖；
- `.dsrec` 魔数保持 `GHDSREC1`，旧录制文件可直接回放；Sparkle Ed25519 密钥路径不变。

完整映射与兼容理由见 [ADR-0001](docs/decisions/0001-matchsticks-ds-rename.md) 与 [ADR-0003](docs/decisions/0003-matchsticks-driver-station-rename.md)。

## 许可与合规

- 许可证：**Apache-2.0**（2026-09-15 定稿，见 [LICENSE](LICENSE)）；
- Practice Only：不得用于正式比赛（第三方 DS 一律不合法）；
- 协议事实来源：[docs/protocol/ds-protocol-2026.md](docs/protocol/ds-protocol-2026.md)（本项目权威协议档案，已核查/待实测两级）与 [frcnetworking.readthedocs.io](https://frcnetworking.readthedocs.io/)（2026-09-15 核查、2026-09-18 二次核对 Request 字节）。
