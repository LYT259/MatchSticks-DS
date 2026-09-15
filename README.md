# GH Driver Station

**macOS 原生 FRC Driver Station** —— 同时支持 roboRIO 1.0 / roboRIO 2.0（NI 协议）与 SystemCore（MRCCOMM 协议，规划中）的驾驶台，严格遵循 Apple 设计语言（SwiftUI 原生）。

> ⚠️ **Practice Only**：所有第三方 DS 均不得用于正式比赛（规则 R710/R901）。本项目定位为练习、调试与台架测试工具。
>
> 📦 当前状态：**Phase 1 MVP**（NI 协议栈 + Apple 风格核心 UI，本机可用模拟器端到端联调）。真机（roboRIO）联调待实体硬件验证。完整论证见 [可行性研究报告](可行性研究报告.md)。

## 功能（当前版本）

- **连接**：roboRIO 1.0/2.0 NI 协议——UDP 1110 控制环（20ms / 50Hz）+ UDP 1150 遥测回传 + TCP 1740 慢速通道；目标自动轮换（mDNS `roboRIO-<队号>-FRC.local` → 静态 `10.T.E.2` → USB `172.22.11.2`），支持手动 IP
- **操作**：Teleop / Autonomous / Test 模式、Enable / Disable / **E-Stop**（协议位直发）、E-Stop 复位（First DS 语义）、Alliance 站位（R1–B3）、使能计时、Practice 分段时序（Auto/TeleOp 延迟 + 提示音 + A-Stop）、远程 Reboot roboRIO / Restart Robot Code
- **状态栏常驻**：队伍号、电池电压（brownout 红底警示 + 迷你曲线）、三大指示灯（Comms / Robot Code / Joysticks）、状态字符串
- **手柄**：IOHIDManager 枚举所有 HID 设备（含 Attack3 / Extreme 3D Pro 等非游戏标准手柄）、槽位排序 + **槽位锁定**、轴 / 按键 / POV 实时显示
- **诊断**：每核 CPU、内存、磁盘、CAN 总线指标（利用率 / BusOff / TxFull / 错误计数）、电源故障计数、TCP 版本信息、网络指示灯、丢包率
- **图表**：电池电压曲线、每核 CPU、UDP 链路质量（Swift Charts 原生）
- **消息**：robot stdout 控制台、错误消息（TCP 0x0B）、DS 事件流
- **安全机制**：UI 主线程心跳看门狗（冻结 >200ms 自动冻结使能输出，robot 侧失包自动 disable）；通信失联 >1.25s 自动失能；使能门禁（无连接 / E-Stop 锁存 / 看门狗异常时拒绝使能）
- **快捷键**：`Space` = E-Stop · `Enter` = Disable · `[ + ] + \` = Enable · `Esc + I` = E-Stop 复位 · `F1` = 重扫手柄（应用前台；全局后台键属 Phase 4 + Input Monitoring 权限）

## 内置 roboRIO 模拟器

`GHDSSim` 在本机扮演 roboRIO（1110/1150/1740 全端口，模拟电池 / CPU / CAN / stdout / 错误流与 reboot / E-Stop / 重启代码时序），**无需实体机器人即可全流程联调**：

```bash
# 终端 A
.build/debug/GHDSSim
# 终端 B（GHDS_AUTO_SIM=1 自动连接 127.0.0.1）
GHDS_AUTO_SIM=1 .build/debug/GHDS
```

或在应用内：Setup → 「启动 roboRIO 模拟器」（自动切换手动 IP 并连接）。

## 从源码构建

要求：macOS 14+、**完整 Xcode**（SwiftUI 宏需要；Command Line Tools 缺 `SwiftUIMacros` 插件）。

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer  # 按本机 Xcode 路径调整
swift build
swift run DSCoreTests   # 协议回归测试（78 项检查，含回环集成测试）
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
| Phase 1 | NI 协议栈 + Apple 风格核心 UI（roboRIO 1/2 可用 MVP） | ✅ 本版本 |
| Phase 2 | NI 全功能：Practice 完善、dslog/WPILog、Dashboard 启动完善、Charts 补全 | ⏳ |
| Phase 3 | MRCCOMM 协议 + NT4 server + OpMode/Alerts（SystemCore） | ⏳ |
| Phase 4 | 全局快捷键（CGEventTap）、应用内更新（Sparkle）、迷你视图 | ⏳ |

## 许可与合规

- 许可证**尚未定稿**——当前仓库私有，禁止再分发；
- Practice Only：不得用于正式 FRC 比赛；
- 协议事实来源：[frcnetworking.readthedocs.io](https://frcnetworking.readthedocs.io/)（2026-09-15 核查）与 `docs/protocol/` 纪律（建立后以其为准）。
