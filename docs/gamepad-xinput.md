# F310 XInput 原始 USB 支持

## 模式与边界

- D 档（`046D:C216`）继续使用 `IOHIDManager`：4 轴、12 按钮、1 POV。面键实测为 X=1、A=2、B=3、Y=4；LT/RT 只有数字按钮 7/8，不显示伪造行程。
- X 档（`046D:C21D`）由应用内 `IOUSBHost` reader 直接读取，不创建虚拟 HID，不需要 sudo、第三方驱动、libusb 或 SDL。输出进入与其他手柄相同的槽位和 50Hz 控制快照。
- Mode 是手柄本地 flight/sports 切换，不作为独立按钮事件展示；切换后另行核对左摇杆与 D-pad 的硬件交换关系。
- [Logitech 官方说明书](https://www.logitech.com/assets/35017/gamepad-f310-gsw.pdf)与 [SDL #15790](https://github.com/libsdl-org/SDL/issues/15790)是上述能力边界的依据。

## 报文与初始化

候选格式来自 SDL 的 zlib 源码及 [MIT 许可的 XInput USB 工具](https://github.com/meghrathod/xinput-controller)，最终需由本机 F310 金样本复核。解析器只接受 20 字节、`byte[0]=0`、`byte[1]=0x14` 的输入：

- `byte[2]`：POV、Start、Back、L3、R3。
- `byte[3]`：LB、RB、Guide、A、B、X、Y。
- `byte[4]` / `byte[5]`：LT / RT 的 0…255 真实深度；输出轴映射到静止 -1、按满 +1。
- `byte[6…13]`：LX、LY、RX、RY 的小端 Int16。X 右为正，Y 从 XInput 上正转换为 FRC 上负。

按钮映射为 A/B/X/Y=1…4、LB/RB=5/6、Back/Start=7/8、L3/R3=9/10、Guide=11。相反 POV 同时置位、短包、未知类型与错误长度均拒绝。

激活写包仅含电源/LED/初始化序列，不包含参考工具中的 rumble begin/end。不得借初始化测试电机或手柄震动。

## 生命周期与安全

- 按 USB 描述符选择 interface 0 的 interrupt IN/OUT pipe，不硬编码端点地址。
- 读写在每设备独立串行队列异步执行；主线程只读取加锁快照，不执行同步 `ReadPipe`。
- 超过 100ms 没有有效包，六轴立即回中（双扳机 -1）、按钮清零、POV=-1；原有 0.5s 设备移除防抖继续处理列表移除。
- 读错、拔线、终止和退出先清零，再销毁 interface user client；inactive 后不再调度新读包。
- 同 USB location 同时出现时优先完整 XInput reader，避免 HID 与原始 USB 形成重复槽位。

## 验证状态

- 已完成：20 字节候选报文单测、全部按钮/POV/模拟轴/异常包、100ms 超时清零、恢复、打开失败重试、同 location 去重、完整应用构建和离屏资源/视图验证。
- 待 F310 X 档实物验收：实际激活、全部按钮含 Guide、双摇杆、真实多级 LT/RT、拔线重连、X↔D 切换、与其他手柄共存、安装版重复验证。
- 未完成上述实物验收前，不把 X 档标为“真机已通过”。
