# DS 协议档案 — NI（roboRIO 1.0/2.0）

> 依据 CLAUDE.md/AGENTS.md 红线 2：本文件建立后为本项目 DS 协议条目的权威记录。
> 只收「已核查」与「待实测」两类，修改必须附依据。
> 建档：2026-09-16（通宵研发会话 4，Phase 1 实现时核查）。

## 来源

| 来源 | 状态 | 说明 |
|---|---|---|
| [frcnetworking.readthedocs.io](https://frcnetworking.readthedocs.io/)（ds_to_rio / rio_to_ds） | 已核查（2026-09-15 抓取） | 本档案主依据；实现 `Sources/DSCore/NIPackets.swift` |
| GHDSSim ↔ GHDS 本机回环 + 回归测试 | 已实测（本机） | 协议两端均我方实现，互通验证通过（78 checks + 50Hz E2E） |
| 真机 roboRIO 抓包 | **待实测** | 硬件到位后逐字段核对；差异回写本文件并同步代码 |

## 已核查条目（含实现验证）

### 端口

- DS → robot 控制通道：**UDP 1110**（FMS 下 1115），每 20ms
- robot → DS 遥测：**UDP 1150**（回送到控制包源地址:源端口，非固定对端端口 → DS 必须用未连接 UDP socket 收包）
- 慢速通道：**TCP 1740** 双向
- 官方白皮书旧端口 1130/1140 **过时**（沿 GHPaths 纪律记录在案）

### DS → robot 控制包（UDP）

| 偏移 | 字段 | 值/位 |
|---|---|---|
| 0–1 | Sequence Num | u16 BE 递增 |
| 2 | Comm Version | `0x01` |
| 3 | Control | bit7 E-Stop · bit3 FMS · bit2 Enabled · bit0-1 模式（0 Teleop / 1 Test / 2 Auto） |
| 4 | Request | bit3(0x08) 重启 roboRIO · bit2(0x04) 重启代码 |
| 5 | Alliance | 0–5 = R1,R2,R3,B1,B2,B3（<3 红，%3+1 站位） |
| 6+ | Tags | 见下 |

**UDP tag 框架**：`Size(u8，含 ID 字节) + ID(u8) + Data`（size = 数据长度 + 1）。

- `0x07` Countdown：float32 BE，秒
- `0x0C` Joystick（每手柄一个 tag）：轴数 u8 + 轴 i8×n（÷127 归一，饱和 ±127）+ 按键数 u8 + 位包 ⌈n/8⌉B（LSB0）+ POV 数 u8 + POV i16×n（0–360，未按 -1）
- `0x0F` Date（首连一次）：微秒 u32 + 秒/分/时(UTC)/日/月(0=Jan)/年(1900 起) 各 u8
- `0x10` Timezone（首连一次）：IANA 标识字符串

### robot → DS 应答包（UDP 1150）

| 偏移 | 字段 | 值/位 |
|---|---|---|
| 0–1 | Sequence Num | u16 BE |
| 2 | Comm Version | `0x01` |
| 3 | Status | bit7 E-Stop · bit4 Brownout · bit3 代码启动中 · bit2 Enabled · bit0-1 模式 |
| 4 | Trace | bit5 RobotCode · bit4 isRoboRIO · bit3 Test · bit2 Auto · bit1 Teleop · bit0 Disabled |
| 5–6 | Battery | u16：电压 = 高字节 + 低字节/256 |
| 7 | Request Date | 首连 `0x01` → DS 回 0x0F/0x10 |
| 8+ | Tags | 同上框架 |

- `0x01` Joystick Output（可多条 7B 记录）：outputs u32 + 左/右 rumble u16
- `0x04` Disk：剩余字节 u32
- `0x05` CPU：**核数为 float32**（roboRIO 上 2.0）+ 每核 4×float32（time-critical/above/normal/low）
- `0x06` RAM：used u32 + total u32
- `0x08` PDP Log / `0x09` 未知：跳过（未解析）
- `0x0E` CAN：利用率 f32 + BusOff u32 + TxFull u32 + RxErr u8 + TxErr u8

### TCP 1740

**帧**：`Size(u16 BE，含 ID 字节) + ID(u8) + Data`；`Size=0` 为 keepalive。

DS → robot：

- `0x02` 手柄描述符（插拔/排序变化时）：每手柄 = index u8 + isXbox u8 + type i8 + 名称(u8 前缀串) + 轴数 u8 + 轴类型 u8×n（0 X/1 Y/2 Z/3 Twist/4 Throttle）+ 按键数 u8 + POV 数 u8；type 枚举 -1 未知/0-1 XInput/20 HID Joystick/21 HID Gamepad 等
- `0x07` 比赛信息：赛事名(u8 前缀串) + 类型 u8（0 None/1 Practice/2 Qual/3 Elim）
- `0x0E` Game Data：u8 前缀串

robot → DS：

- `0x0A` 版本信息：条目 = type u8（0 Software/2 CAN Talon/8 PDP/9 PCM）+ 未知 u16 + id u8 + 名称(u8 串) + 版本(u8 串)；**6 字节全零终止**
- `0x0B` 错误：时间戳 f32 + seq u16 + 未知 u16 + 错误码 i32 + flags u8（bit0 错误/bit1 LV 码）+ 详情/位置/调用栈（u16 前缀串×3）
- `0x0C` stdout：时间戳 f32 + seq u16 + 文本
- `0x04` Disable Faults：通信 u16 + 12V u16；`0x05` Rail Faults：6V/5V/3.3V u16×3

### 语义决策（本项目实现约定）

- **E-Stop 锁存**：沿 First DS 语义——E-Stop 后由「重启 robot code」解锁（Request bit2），不要求 roboRIO 断电（NI DS 旧体验的升级）；模拟器按此实现
- 失联判定 >1.25s；UI 心跳看门狗 >200ms 冻结使能（OpenDS 模式，报告 §6 决策 2）

## 待实测（真机核对清单）

- [ ] 控制包/应答包逐字节抓包比对（协议年份 2025/2026 变体是否存在字段漂移）
- [ ] 0x0C 手柄 tag：多手柄时确为「每手柄一 tag」还是单 tag 多条目（两实现兼容性以真机为准）
- [ ] 0x0F/0x10 首连触发条件：requestDate=1 的确切时机与 DS 重发策略
- [ ] TCP keepalive 频率与描述符重发时序
- [ ] CPU tag 核数 float 的实际值；PDP 0x08 布局（当前跳过）
- [ ] FMS 1115 路径（季外赛 Cheesy Arena 扩展时核对）
- [ ] roboRIO 1.0 与 2.0 在同一实现下行为一致性（报告 §3.1：协议层同构）
