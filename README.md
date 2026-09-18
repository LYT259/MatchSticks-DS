# GH Driver Station

**macOS 原生 FRC Driver Station** —— 同时支持 roboRIO 1.0 / roboRIO 2.0（NI 协议）与 SystemCore（MRCCOMM V2 协议，实验性）的驾驶台，严格遵循 Apple 设计语言（SwiftUI 原生）。

> ⚠️ **Practice Only**：所有第三方 DS 均不得用于正式比赛（规则 R710/R901）。本项目定位为练习、调试与台架测试工具。
>
> 📦 当前状态：**Phase 1 + Phase 2 完成，Phase 3 协议层完成**（NI 全功能 + MRC V2 + NT4 server，模拟器与 `robot_sim.py` 异构联调通过；发布线 v0.1.0-alpha.4）。真机（roboRIO / SystemCore）联调待实体硬件。完整论证见 [可行性研究报告](可行性研究报告.md)。

## 功能（当前版本）

- **连接**：roboRIO 1.0/2.0 NI 协议——UDP 1110 控制环（20ms / 50Hz）+ UDP 1150 遥测回传 + TCP 1740 慢速通道；目标自动轮换（mDNS `roboRIO-<队号>-FRC.local` → 静态 `10.T.E.2` → USB `172.22.11.2`），支持手动 IP
- **操作**：Teleop / Autonomous / Test 模式、Enable / Disable / **E-Stop**（协议位直发）、E-Stop 复位（First DS 语义）、Alliance 站位（R1–B3）、使能计时、Practice 分段时序（Auto/TeleOp 延迟 + 提示音 + A-Stop）、远程 Reboot roboRIO / Restart Robot Code
- **状态栏常驻**：队伍号、电池电压（brownout 红底警示 + 迷你曲线）、三大指示灯（Comms / Robot Code / Joysticks）、状态字符串
- **手柄**：IOHIDManager 枚举所有 HID 设备（含 Attack3 / Extreme 3D Pro 等非游戏标准手柄）、槽位排序 + **槽位锁定**、轴 / 按键 / POV 实时显示
- **诊断**：每核 CPU、内存、磁盘、CAN 总线指标（利用率 / BusOff / TxFull / 错误计数）、电源故障计数、TCP 版本信息、网络指示灯、丢包率
- **图表**：电池电压曲线、每核 CPU、UDP 链路质量（Swift Charts 原生）
- **消息**：robot stdout 控制台、错误消息（TCP 0x0B）、DS 事件流
- **抓包录制/回放**：Setup 页一键录制收发包为 `.dsrec`（金样本回归基线）；模拟器 `--replay` 按录制的真机字节应答
- **SystemCore（MRC V2 · 实验性）**：Setup 页切换机器人类型；UDP V2 控制环（CRC32C 应答校验）+ NT4 server（6767，OpMode 选择经 ControlData.CurrentOpMode 下发）+ TCP 0x13 OpMode 列表
- **会话日志**：连接期间 1Hz 自动记录 `.dslog`（NI DS 格式）与 `.wpilog`（WPILib DataLog 2027 VarInt 格式）双文件，AdvantageScope 可直接打开复盘
- **本机状态**：DS 电脑电池/交流供电、系统 CPU、进程内存、本机网络指示（WiFi/有线）
- **安全机制**：UI 主线程心跳看门狗（冻结 >200ms 自动冻结使能输出，robot 侧失包自动 disable）；通信失联 >1.25s 自动失能；使能门禁（无连接 / E-Stop 锁存 / 看门狗异常时拒绝使能，`SafetyGate` 纯逻辑单测覆盖）
- **快捷键**：`Space` = E-Stop · `Enter` = Disable · `[ + ] + \` = Enable · `Esc + I` = E-Stop 复位 · `F1` = 重扫手柄（应用前台；全局后台键属 Phase 4 + Input Monitoring 权限）

## 内置 roboRIO 模拟器

`GHDSSim` 在本机扮演 roboRIO（1110/1150/1740 全端口，模拟电池 / CPU / CAN / stdout / 错误流与 reboot / E-Stop / 重启代码时序），**无需实体机器人即可全流程联调**：

```bash
# 终端 A
.build/debug/GHDSSim
# 终端 B（GHDS_AUTO_SIM=1 自动连接 127.0.0.1）
GHDS_AUTO_SIM=1 .build/debug/GHDS
# SystemCore（MRC V2）模式
.build/debug/GHDSSim --mrc
GHDS_AUTO_SIM=1 GHDS_AUTO_MRC=1 .build/debug/GHDS
```

第三方异构联测：Compatibility Proxy 的 `robot_sim.py`（独立 Python 实现）可直接对接本 DS——实测 UDP V2 控制流、TCP 0x13 OpMode、NT4 26 主题发布/订阅与 45Hz ControlData 下发全部互通。

或在应用内：Setup → 「启动 roboRIO 模拟器」（自动切换手动 IP 并连接）。

**回放模式**（Phase 0「录制即测试」）：

```bash
# DS 侧开启抓包录制（Setup 页开关，存至 ~/Library/Application Support/GHDriverStation/captures/）
# 然后用录制文件驱动模拟器应答——DS 端解析与真机逐字节一致：
.build/debug/GHDSSim --replay capture-20260916-020000.dsrec
```

## 从源码构建

要求：macOS 14+、**完整 Xcode**（SwiftUI 宏需要；Command Line Tools 缺 `SwiftUIMacros` 插件）。

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer  # 按本机 Xcode 路径调整
swift build
swift run DSCoreTests   # 回归测试：38 组 / 257 项检查（协议金样本/容错 + 安全门禁/时序机/录制回放/POV 归一化单测 + E-Stop 锁存/重启断联/看门狗冻结/brownout/30s 长跑/录制回放全链路/MRC 正反向/NT4 握手 场景级集成测试）
swift run GHDS          # 运行驾驶台
```

## 安装（GitHub Releases）

1. 从 [Releases](../../releases) 下载 `GHDS-<版本>.dmg`，打开并拖入 Applications；
2. 首次启动：macOS 15+ 需到 **设置 → 隐私与安全性 → 「仍要打开」**（未公证分发的免费方案，每台机器一次性；详见报告 §5.5）；
3. 连接机器人时允许「本地网络」权限（**机器人连不上第一嫌疑**）；终端 / SSH 启动豁免此权限。

安装 / 校验：

```bash
# 终端安装（无 Gatekeeper 隔离属性，免「仍要打开」）
curl -L <release-dmg-url> -o GHDS.dmg && hdiutil attach GHDS.dmg
# 校验
shasum -a 256 -c SHA256SUMS
```

## 打包发布

```bash
scripts/build-app.sh 0.1.0-alpha.1   # universal .app + ad-hoc 签名 + DMG + SHA256SUMS
```

## 仓库结构

```
Sources/DSCore/      协议核心：NI 编解码、20ms 控制环、看门狗、连接管理（平台无关）
Sources/GHDS/        SwiftUI 应用：DSModel 状态源、六页 UI、HID、快捷键
Sources/GHDSSim/     roboRIO 模拟器（本机端到端验证）
Tests/DSCoreTests/   协议回归测试（自带 runner）+ 回环集成测试
scripts/             图标生成 + 打包脚本
```

## 分支模型

`feat/*` → PR → **beta**（开发主线，PR 合入）→ 用户全面验证后 → **stable**（发布基线）。Releases 基于 beta 产出的构建。

## 路线图（报告 §9）

| 阶段 | 内容 | 状态 |
|---|---|---|
| Phase 1 | NI 协议栈 + Apple 风格核心 UI（roboRIO 1/2 可用 MVP） | ✅ 完成 |
| Phase 2 | NI 全功能：Practice ✅、dslog + WPILog ✅、Charts ✅、Dashboard 启动 ✅、DS 自身监控 ✅（XInput 震动待硬件：GCDeviceHaptics 引擎链路 + 实物手柄） | ✅ 基本完成 |
| Phase 3 | MRCCOMM V2 协议栈 ✅（金样本验证）+ NT4 server（6767，异构联测通过）+ OpMode 选择 ✅（Alerts/Display 待真机核对） | ✅ 协议层完成 |
| Phase 4 | 迷你视图 ✅、权限引导页 ✅；全局快捷键（CGEventTap + Input Monitoring）、应用内更新（Sparkle）、内置 Web UI、摄像头流 待做 | ⏳ 部分完成 |

## 许可与合规

- 许可证：**Apache-2.0**（2026-09-15 定稿，见 [LICENSE](LICENSE)）；
- Practice Only：不得用于正式比赛（第三方 DS 一律不合法）；
- 协议事实来源：[docs/protocol/ds-protocol-2026.md](docs/protocol/ds-protocol-2026.md)（本项目权威协议档案，已核查/待实测两级）与 [frcnetworking.readthedocs.io](https://frcnetworking.readthedocs.io/)（2026-09-15 核查、2026-09-18 二次核对 Request 字节）。
