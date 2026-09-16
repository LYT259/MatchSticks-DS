# DS 协议档案 — NI（roboRIO 1.0/2.0）与 MRC（SystemCore）

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

## MRC（SystemCore / MrcCommDaemon，Comm Version 2）— 已核查（编码器已实现）

依据：Compatibility Proxy 逆向文档 DS_MRCCOMM_UDP_PROTOCOL.md（2026-09-16 核查；双端反汇编交叉验证）。实现 Sources/DSCore/MRCPackets.swift + CRC32C.swift。

- 控制包（UDP 1110，6B 头 + tags）：seq u16 BE / **ver 0x02** / ctrl（bit0 Test、bit1 Auto、bit2 Enabled、bit3 FMS、bit7 E-Stop）/ request（**bit0 RequestNormal，清零停机**）/ alliance 0-5；tags：0x0C 手柄（同 NI 框架；轴负数÷128 非负÷127）、0x07 match time f32 BE
- 应答（回送源端口，24B 头）：seq u16 BE 回显 / ver / ctrl（bit0-1 mode 0 Unknown/1 Auto/2 Teleop/3 Test、bit2 Enabled、bit5 HasCode、bit7 E-Stop）/ status（**bit0 WatchdogFed 每包必须**，连续 >4 缺失 → DS「Watchdog Not Fed」；bit5 HasUserCodeReady + bit6 HasUserCode 同置才清「无代码」）/ batt（整数+分数/256）/ flags / 保留 8B / payload CRC32C LE / **header CRC32C（只算 [0..20)）LE**；CRC32C Castagnoli 0x82F63B78，向量 "123456789"→0xE3069283
- 0xFF 错误包（8B）：版本不符时 [seq][0xFF][errorCode][0×4]，观察值 101
- 手柄输出 tag **0x2E**（UDP 或 TCP）：6 槽 × 11B = RGB LED + 左/右/左扳机/右扳机 rumble u16 BE
- TCP 1740 同帧格式；robot→DS **0x13 OpMode 列表**（自定义大端二进制非 protobuf：count + 每项 u8 前缀 name/group/desc（≤64B，任一为空整表拒绝）+ u64 BE hash（bit56-57 模式、bit58 enabled）+ u32 BE 文字色/背景色）；DS 忽略 /Dscomm/* 的远程 NT4 写入——OpMode 列表必须走 TCP
- **金样本**：文档 §8 实测包（seq 0x0123/有码/失能/12.0V/0x2E 全零 tag，92B）——本仓编码器已逐字节复现（DSCoreTests mrcGoldenPacketTests）
- **NT4 平面（6767，DS 侧 server，MrcComm 反连）**：OpMode 选择/告警/显示走此通道——**下一批实现**

### 待实测（MRC/SystemCore）
- [ ] 真机 SystemCore 抓包比对（现行依据为逆向文档 + robot_sim 语义）
- [ ] NT4 6767 握手与 /Dscomm/OpModeSelection 写入路径（下一批实现后以 robot_sim.py 联测）
- [ ] console/error 的 TCP tag id（0x0B–0x19 范围内，具体值待核）
- [ ] 0x2E rumble 值到物理手柄的映射（Phase 4 震动测试）

## 待实测（真机核对清单 — NI）

- [ ] 控制包/应答包逐字节抓包比对（协议年份 2025/2026 变体是否存在字段漂移）
- [ ] 0x0C 手柄 tag：多手柄时确为「每手柄一 tag」还是单 tag 多条目（两实现兼容性以真机为准）
- [ ] 0x0F/0x10 首连触发条件：requestDate=1 的确切时机与 DS 重发策略
- [ ] TCP keepalive 频率与描述符重发时序
- [ ] CPU tag 核数 float 的实际值；PDP 0x08 布局（当前跳过）
- [ ] FMS 1115 路径（季外赛 Cheesy Arena 扩展时核对）
- [ ] roboRIO 1.0 与 2.0 在同一实现下行为一致性（报告 §3.1：协议层同构）
