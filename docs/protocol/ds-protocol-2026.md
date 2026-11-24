# DS 协议档案 — NI（roboRIO 1.0/2.0）与 MRC（SystemCore）

> 依据 CLAUDE.md/AGENTS.md 红线 2：本文件建立后为本项目 DS 协议条目的权威记录。
> 只收「已核查」与「待实测」两类，修改必须附依据。
> 建档：2026-09-16（通宵研发会话 4，Phase 1 实现时核查）。

## 来源

| 来源 | 状态 | 说明 |
|---|---|---|
| [frcnetworking.readthedocs.io](https://frcnetworking.readthedocs.io/)（ds_to_rio / rio_to_ds） | 已核查（2026-09-15 抓取） | 本档案主依据；实现 `Sources/DSCore/NIPackets.swift` |
| MatchSticksDriverStationSim ↔ MatchSticksDriverStation 本机回环 + 回归测试 | 已实测（本机） | 协议两端均我方实现，互通验证通过（78 checks + 50Hz E2E） |
| 真机 roboRIO 抓包 | **待实测** | 硬件到位后逐字段核对；差异回写本文件并同步代码 |

## 已核查条目（含实现验证）

### 端口

- DS → robot 控制通道：**UDP 1110**（FMS 下 1115），每 20ms
- robot → DS 遥测：**UDP 1150**（2026-11-14 roboRIO 2.0 真机验证：应答固定发往 DS 1150；DS 本地 socket 必须 bind 1150，不能依赖内核临时端口）
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
- **Request 字节（0x08 重启 roboRIO / 0x04 重启代码）**：2026-09-18 二次核对 frcnetworking 原文（`....x...` = Reboot RoboRIO、`.....x..` = Restart Code），与本档案一致；可行性研究报告 v1.1 §3.1 曾误写「bit4 重启代码」，已在 v1.2 更正（代码实现自始按 0x04 落地，无行为变更）
- **手柄按钮元素取值约定**：只接受 usage page = Button(0x09) 或 GenericDesktop(0x01) 且编号 1…64 的输入按钮；Consumer 页（0x0C，音量/媒体键）的 usage 是千位级功能码，若当按钮号使用会使 0x0C tag 声明的按键数（按 64 位截断）与实际字节数（按原值 ⌈n/8⌉ 计算）不一致——真机核对该约定对 Logitech Attack3 / Extreme 3D Pro 的实际影响（见下「待实测（手柄）」）
- **XInput 布局手柄轴序归一**（2026-11-18 真机联调定案）：Xbox 系手柄（名称含 xbox 或厂商 045E）命中「六轴签名」（usage 升序恰为 X,Y,Z,Rx,Ry,Rz；Z/Rz 为 0…255 类非对称扳机量程；其余四轴对称量程）时，按官方 FRC DS 的 XInput 手柄轴序下发——usage 序 `[左X, 左Y, 左扳机, 右X, 右Y, 右扳机]` → XInput 序 `[左X, 左Y, 左扳机, 右扳机, 右X, 右Y]`，且 Y 族翻转符号（实测样本飞智冰原狼 4 USB 模式自报 Xbox 360 签名 045E:028E，Y 族「上=+1」与 FRC 约定「上=-1」相反）。实测教训：按 usage 序原样透传时，机器人侧 WPILib `XboxController` 读 axis4（RightX）得到的是右摇杆 Y——旋转绑到「上下拨」、右摇杆 X 误入右扳机槽位（推过半即触发绑在 RightTrigger 上的动作）。非六轴签名或非 Xbox 自报的设备维持 usage 序透传（官方 DS 对 HID Joystick 类亦如此）。实现 Sources/DSCore/XInputAxisOrder.swift（单测 DSCoreTests xinputAxisOrder*）；蓝牙模式布局未实测，命中不了签名时自动退回透传

## MRC（SystemCore / MrcCommDaemon，Comm Version 2）— 已核查（编码器已实现）

依据：Compatibility Proxy 逆向文档 DS_MRCCOMM_UDP_PROTOCOL.md（2026-09-16 核查；双端反汇编交叉验证）。实现 Sources/DSCore/MRCPackets.swift + CRC32C.swift。

- 控制包（UDP 1110，6B 头 + tags）：seq u16 BE / **ver 0x02** / ctrl（bit0 Test、bit1 Auto、bit2 Enabled、bit3 FMS、bit7 E-Stop）/ request（**bit0 RequestNormal，清零停机**）/ alliance 0-5；tags：0x0C 手柄（同 NI 框架；轴负数÷128 非负÷127）、0x07 match time f32 BE
- 应答（回送源端口，24B 头）：seq u16 BE 回显 / ver / ctrl（bit0-1 mode 0 Unknown/1 Auto/2 Teleop/3 Test、bit2 Enabled、bit5 HasCode、bit7 E-Stop）/ status（**bit0 WatchdogFed 每包必须**，连续 >4 缺失 → DS「Watchdog Not Fed」；bit5 HasUserCodeReady + bit6 HasUserCode 同置才清「无代码」）/ batt（整数+分数/256）/ flags / 保留 8B / payload CRC32C LE / **header CRC32C（只算 [0..20)）LE**；CRC32C Castagnoli 0x82F63B78，向量 "123456789"→0xE3069283
- 0xFF 错误包（8B）：版本不符时 [seq][0xFF][errorCode][0×4]，观察值 101
- 手柄输出 tag **0x2E**（UDP 或 TCP）：6 槽 × 11B = RGB LED + 左/右/左扳机/右扳机 rumble u16 BE
- TCP 1740 同帧格式；robot→DS **0x13 OpMode 列表**（自定义大端二进制非 protobuf：count + 每项 u8 前缀 name/group/desc（≤64B，任一为空整表拒绝）+ u64 BE hash（bit56-57 模式、bit58 enabled）+ u32 BE 文字色/背景色）；DS 忽略 /Dscomm/* 的远程 NT4 写入——OpMode 列表必须走 TCP
- **金样本**：文档 §8 实测包（seq 0x0123/有码/失能/12.0V/0x2E 全零 tag，92B）——本仓编码器已逐字节复现（DSCoreTests mrcGoldenPacketTests）
- **NT4 平面（6767，DS 侧 server，MrcComm 反连）**：OpMode 选择/告警/显示走此通道——**已实现**（`Sources/DSCore/NT4Server.swift`：BSD 套接字 + 手写 WebSocket，JSON 文本帧 publish/subscribe/announce + msgpack 二进制值帧 + ProtobufLite ControlData；20ms tick 下发控制字/手柄/OpMode hash/GameData，NT4 为 2027 权威控制面，优先级高于 UDP）。异构联测已通过：Compatibility Proxy `robot_sim.py` 侧实测 UDP V2 控制流、TCP 0x13 OpMode 下发、NT4 握手 + 26 主题 announce + 541 条 ControlData（≈45Hz）protobuf 解析全通（2026-09-16）

### 待实测（MRC/SystemCore）
- [ ] 真机 SystemCore 抓包比对（现行依据为逆向文档 + robot_sim 语义）
- [ ] **SystemCore 摄像头流**：真实流协议未核查（无实机，禁止猜字段）。现状 = MatchSticksDriverStationSim 自定义 **MOCK 通道**（127.0.0.1:6769，HTTP GET `/frame.jpg` 单帧 JPEG，按需生成）+ DS 侧显示槽位（诊断页，点按刷新 + ≥1s 限流，RateLimiter 可注入时钟有单测）；真机抓包后按实物替换数据源，槽位与限流交互保留（2026-10-01，Phase 4）
- [x] NT4 6767 握手与 /Dscomm/Control/ControlData 写入路径——已实现并以 robot_sim.py 联测通过（2026-09-16）；**/Dscomm/OpModeSelection 等机器人侧回写主题的键位仍以真机为准**
- [ ] console/error 的 TCP tag id（0x0B–0x19 范围内，具体值待核）
- [ ] 0x2E rumble 值到物理手柄的映射（Phase 4 震动测试——**协议侧已核查**（2026-10-01）：`MRCPackets.slotOutputsTag` 编码金样本 + 应答器/DS 端到端同值断言 + DS 手柄页呈现；仅物理手柄驱动效果待真机）


## 待实测（真机核对清单 — NI）

- [ ] 控制包/应答包逐字节抓包比对（协议年份 2025/2026 变体是否存在字段漂移）
- [ ] 0x0C 手柄 tag：多手柄时确为「每手柄一 tag」还是单 tag 多条目（两实现兼容性以真机为准）
- [ ] 0x0F/0x10 首连触发条件：requestDate=1 的确切时机与 DS 重发策略
- [ ] TCP keepalive 频率与描述符重发时序
- [ ] CPU tag 核数 float 的实际值；PDP 0x08 布局（当前跳过）
- [ ] FMS 1115 路径（季外赛 Cheesy Arena 扩展时核对）
- [ ] roboRIO 1.0 与 2.0 在同一实现下行为一致性（报告 §3.1：协议层同构）

## 待实测（手柄 HID → DS 报文）

建档依据：2026-09-18 通读自查（`JoystickData.povAngle` 与按钮过滤的实现说明见上方「语义决策」）。

- [ ] **hatswitch 角度次序**：本项目按「有效位从 1 起、顺时针 0° 起（1 = 正北，+45°/位）」直序映射；HID Usage Tables 的 8 位帽用法表次序为 NE,NW,SW,SE,N,W,S,E（1=NE），两者不同。中立态判定（0…8 与 1…8 描述器的 0 = 未按）已按声明逻辑范围实现并有单测（DSCoreTests povHatTests），**角度次序需实物设备矩阵核对后才改判**，不凭文档记忆
- [ ] 每款手柄的 POV 上报值与 NI DS / First DS 显示一致性（Attack3 的 hat、Extreme 3D Pro 的 POV）
- [ ] 按钮过滤约定（只取 Button/GenericDesktop 页 ≤64）在带媒体键的手柄上的实际按键编号连续性
- [x] ~~0x0C tag 的轴 usage 顺序（本项目按 usage 升序 X,Y,Z,Rx,Ry,Rz,Slider,Dial,Wheel）与 roboRIO 侧 `setAxis` 索引语义对应~~ **2026-11-18 已核查**：真机（roboRIO + WPILib XboxController）期待 XInput 轴序，与 usage 序不一致；对 XInput 六轴签名设备已按官方 DS 归一（见上「语义决策·XInput 布局手柄轴序归一」），其余布局维持 usage 序待实物矩阵核对
