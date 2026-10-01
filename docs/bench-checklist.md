# 真机台架手册（照单跑）

> 2026-10-01 整理自 `docs/protocol/ds-protocol-2026.md` 三节待实测清单。
> 真机到手后逐项执行：每项先跑「操作」，再回写协议档案（已核查/差异）与本手册勾选。
> 台架纪律：**不能让电机动**——首次联调以失能态抓包/对灯为主；使能验证前确认
> 机器人架空、急停在手。

## 0. 台架准备

- [ ] DS 装「仍要打开」流程走通（首次）；本地网络授权「允许」已点
- [ ] `bash scripts/test-e2e.sh` 本机全绿（打包版基线）
- [ ] 抓包开启：Setup 页抓包录制（.dsrec）全程留存；镜像 lsusb/系统报告
- [ ] GHDSSim 回归先跑一遍作对照（`swift run DSCoreTests` 全绿基线）

## 1. MRC / SystemCore（真机抓包比对）

- [ ] **协议总比对**：真机 SystemCore 抓包 vs 逆向文档语义（现行依据 = 逆向文档 + robot_sim）；
      差异逐字段回写协议档案
- [ ] **/Dscomm/* 机器人侧回写键位**：OpModeSelection 等（NT4 6767 通道已联测，
      键位以真机为准）
- [ ] **console/error TCP tag id**（0x0B–0x19 范围内确定具体值）
- [ ] **摄像头流协议**：现仅 MOCK 通道（GHDSSim :6769 HTTP JPEG）；抓真机流，
      定协议（容器/端口/限流语义），按实物替换 DS 侧数据源（UI 槽位与限流保留）
- [ ] **0x2E → 物理手柄震动**：协议侧已核查（编码金样本 + 端到端同值）；真机发
      不同 rumble 值观察手柄震动强度/通道对应（L/R/双扳机），必要时调整映射
- [ ] NT4 权威性确认：NT4 ControlData 与 UDP V2 的优先级/并存行为（断其一观察）

## 2. NI（roboRIO 1.0 / 2.0 真机核对）

- [ ] 控制包/应答包逐字节抓包比对（2025/2026 协议年份变体是否存在字段漂移）
- [ ] 0x0C 手柄 tag：多手柄时「每手柄一 tag」还是单 tag 多条目
- [ ] 0x0F/0x10 首连触发：requestDate=1 的确切时机与 DS 重发策略
- [ ] TCP keepalive 频率与描述符重发时序
- [ ] CPU tag 核数 float 实际值；PDP 0x08 布局（当前跳过）
- [ ] roboRIO 1.0 与 2.0 同实现行为一致性（同一 DS 分别连两代核对）
- [ ] （后续）FMS 1115 路径——季外赛 Cheesy Arena 扩展时核对

## 3. 手柄 HID → DS 报文

- [ ] **hatswitch 角度次序**：本项目按「有效位从 1 起、顺时针 0° 起」直序映射，
      与 HID Usage Tables 帽用法表次序（1=NE）不同——实物矩阵核对后才改判，
      不凭文档记忆（Attack3 的 hat / Extreme 3D Pro 的 POV）
- [ ] 各手柄 POV 上报值与 NI DS / First DS 显示一致性
- [ ] 按钮过滤约定（Button/GenericDesktop 页 ≤64）在带媒体键手柄上的按键编号连续性
- [ ] 0x0C tag 轴 usage 顺序（X,Y,Z,Rx,Ry,Rz,Slider,Dial,Wheel）与 roboRIO
      `setAxis` 索引语义对应

## 4. 台架专项（安全链）

- [ ] 使能→拔网线：robot 侧看门狗自动 disable 时延实测（预期 ~200ms 量级）
- [ ] DS 强杀（kill -9）同上对照
- [ ] E-Stop 空格键全局触发（前台/非文本输入）+ Esc+I 复位全流程
- [ ] 应用内更新在真机连接态点击角标：安全门阻断 tooltip 呈现

## 5. 回写要求

每项完成：协议档案对应条目改「已核查」附依据（抓包文件名/日期）；本手册勾选；
涉及代码的改动照常走 feat/fix 分支 + PR；`engineering-log` 记录台架当日条目。
