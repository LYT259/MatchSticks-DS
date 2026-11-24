import AppKit
import DSCore
import UniformTypeIdentifiers

// MARK: 手柄槽位拖放排序（任意 source→destination）+ 槽位标题型号显示名
//
// 删除上移/下移按钮后，顶部槽位摘要卡拖放是唯一排序路径：模型必须支持任意
// source→destination；越界/原地/落点未知不得改动座次；可见槽位、控制快照与
// 热插拔恢复三者顺序保持一致。

/// 三只可区分手柄：名称/VID/PID/首轴值互不相同；控制快照按首轴值辨认顺序。
private final class ThreeStickFeed {
    var third: Float? = 3
    var devices: [HIDDeviceSnapshot] {
        var list = [
            HIDDeviceSnapshot(uniqueID: "a:1:s", name: "Wireless Controller", vendorID: 0x054C, productID: 0x05C4,
                              axes: [1], axisUsages: [0x30], buttons: 0, buttonCount: 14, povs: [-1],
                              isXbox: false, mode: .directInput,
                              polarity: GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: false),
                              usbLocationID: nil),
            HIDDeviceSnapshot(uniqueID: "b:2:s", name: "Xbox Wireless Controller", vendorID: 0x045E, productID: 0x0B12,
                              axes: [2], axisUsages: [0x30], buttons: 0, buttonCount: 10, povs: [-1],
                              isXbox: true, mode: .directInput,
                              polarity: GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: false),
                              usbLocationID: nil),
        ]
        if let third {
            list.append(HIDDeviceSnapshot(uniqueID: "c:3:s", name: "Cool Pad", vendorID: 0x1234, productID: 0x5678,
                                          axes: [third], axisUsages: [0x30], buttons: 0, buttonCount: 12, povs: [-1],
                                          isXbox: false, mode: .directInput,
                                          polarity: GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: false),
                                          usbLocationID: nil))
        }
        return list
    }
}

@MainActor
func joystickSlotOrderingTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    func settle(_ model: DSModel) {
        Thread.sleep(forTimeInterval: 0.55)
        model.pollAndPublishSnapshot()
    }

    let model = DSModel()
    let feed = ThreeStickFeed()
    model.hidPoller = { feed.devices }
    model.pollAndPublishSnapshot()
    check(model.joystickSlots.map(\.uniqueID) == ["a:1:s", "b:2:s", "c:3:s"], "三只手柄按首扫顺序落座")

    // 任意位置排序：slot 0 直接拖到 slot 2（被拖者占目标槽位，其余顺延）
    model.moveSlot(from: 0, to: 2)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"],
          "slot 0 → slot 2 非相邻拖放立即生效")
    check(model.joystickSlots.map(\.index) == [0, 1, 2], "拖放后槽位编号连续重排")
    // 控制快照按 50Hz tick 重建：下一次轮询即按新座次发送，与可见槽位一致
    model.pollAndPublishSnapshot()
    check(model.latestPublishedJoysticks.map { $0.axes.first } == [2, 3, 1],
          "控制快照按新座次发送（与可见槽位一致）")

    // 反向：末位拖到首位
    model.moveSlot(from: 2, to: 0)
    check(model.joystickSlots.map(\.uniqueID) == ["a:1:s", "b:2:s", "c:3:s"], "slot 2 → slot 0 拖回原位")

    // 拖到末尾（落点 == 当前数量，即第一张空闲摘要卡）
    model.moveSlot(from: 0, to: 3)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"], "拖到末尾落点 == 数量时移到末位")
    model.pollAndPublishSnapshot()
    check(model.latestPublishedJoysticks.map { $0.axes.first } == [2, 3, 1], "控制快照随末尾落点同步")

    // 越界 / 原地 / 源不存在：座次不得改变（无效拖放只回弹，不写座次记忆）
    model.moveSlot(from: 0, to: 99)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"], "落点越界（99）被忽略")
    model.moveSlot(from: 3, to: 0)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"], "源槽位 == 数量（越界）被忽略")
    model.moveSlot(from: -1, to: 0)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"], "源槽位为负被忽略")
    model.moveSlot(from: 1, to: 1)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"], "原地落点被忽略")
    model.moveSlot(from: 7, to: 1)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"], "源槽位越界被忽略")
    settle(model)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"],
          "无效拖放不写座次：重扫防抖窗口后仍保持拖放后的顺序")

    // 热插拔：拖放后的座次在拔出/插回后保持（离线设备回原座次，在场设备顺延）
    feed.third = nil
    settle(model)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "a:1:s"], "拔出 c 后在场设备保持先后")
    feed.third = 3
    settle(model)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"], "插回 c 回到拖放后的座次")
    check(model.latestPublishedJoysticks.map { $0.axes.first } == [2, 3, 1], "插回后控制快照与可见槽位一致")

    // 拖放后再次重扫（过了 0.5s 防抖）不回弹
    model.moveSlot(from: 1, to: 0)
    check(model.joystickSlots.map(\.uniqueID) == ["c:3:s", "b:2:s", "a:1:s"], "slot 1 → slot 0 立即生效")
    settle(model)
    check(model.joystickSlots.map(\.uniqueID) == ["c:3:s", "b:2:s", "a:1:s"], "拖放顺序在重扫防抖窗口后不回弹")
    check(model.latestPublishedJoysticks.map { $0.axes.first } == [3, 2, 1], "重扫后控制快照仍按拖放顺序")

    // 相邻步进旧入口仍可用（与拖放到相邻槽位等价）
    model.moveSlot(0, up: false)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"], "旧 moveSlot(up: false) 与拖到下一槽位等价")

    // 槽位标题型号显示名：经 DSModel 读取按 uniqueID 持久化的手动覆盖
    let suiteName = "org.ghfrc.driverstation.test.uitests.slot-name.\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    defer { suite.removePersistentDomain(forName: suiteName) }
    let nameModel = DSModel(settingsDefaults: suite, persistenceEnabled: true)
    let ds4 = model.joystickSlots[2]
    check(nameModel.gamepadDisplayName(for: ds4) == GamepadSkin.dualshock4.displayName,
          "自动检测：Wireless Controller 显示 PS4 DualShock 4")
    nameModel.setGamepadSkinOverride(.xboxSeries, for: ds4)
    check(nameModel.gamepadDisplayName(for: ds4) == GamepadSkin.xboxSeries.displayName,
          "手动选择：显示所选型号而非检测型号")
    check(DSModel(settingsDefaults: suite, persistenceEnabled: true).gamepadDisplayName(for: ds4)
            == GamepadSkin.xboxSeries.displayName, "手动型号覆盖按 uniqueID 持久化后重建模型仍生效")
    nameModel.setGamepadSkinOverride(nil, for: ds4)
    check(nameModel.gamepadDisplayName(for: ds4) == GamepadSkin.dualshock4.displayName, "清除覆盖回到自动检测型号")
    let xbox = model.joystickSlots[0]
    check(xbox.uniqueID == "b:2:s" && nameModel.gamepadDisplayName(for: xbox) == GamepadSkin.xboxSeries.displayName,
          "Xbox Series 自报名显示具体型号")
    let unknown = model.joystickSlots[1]
    check(unknown.uniqueID == "c:3:s" && nameModel.gamepadDisplayName(for: unknown) == "Cool Pad",
          "未识别型号保留真实设备名")
}

/// N 只可区分手柄（名称/VID/PID/首轴值 = 序号 + 1）。
private final class ManyStickFeed {
    var ids: [String]
    init(_ ids: [String]) { self.ids = ids }
    var devices: [HIDDeviceSnapshot] {
        ids.enumerated().map { i, id in
            HIDDeviceSnapshot(uniqueID: id, name: "Stick \(id)", vendorID: 0x1234, productID: 0x1000 + i,
                              axes: [Float(i + 1)], axisUsages: [0x30], buttons: 0, buttonCount: 4, povs: [-1],
                              isXbox: false, mode: .directInput,
                              polarity: GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: false),
                              usbLocationID: nil)
        }
    }
}

@MainActor
func joystickSlotDragBoundaryTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    func settle(_ model: DSModel) {
        Thread.sleep(forTimeInterval: 0.55)
        model.pollAndPublishSnapshot()
    }

    // 末位拖到末尾（落点 == 数量）是真正的 no-op：不重写座次记忆，离线设备的记忆优先级不变
    let noop = DSModel()
    let noopFeed = ManyStickFeed(["a:1:s", "b:2:s", "c:3:s"])
    noop.hidPoller = { noopFeed.devices }
    noop.pollAndPublishSnapshot()
    noop.moveSlot(from: 1, to: 0)                       // [b, a, c]
    noopFeed.ids = ["a:1:s", "c:3:s"]                   // b 离线，但仍排在记忆首位
    settle(noop)
    check(noop.joystickSlots.map(\.uniqueID) == ["a:1:s", "c:3:s"], "b 拔出后在场 a、c 顺延")
    noop.moveSlot(from: 1, to: 2)                       // c 已在末位 → 拖到末尾
    check(noop.joystickSlots.map(\.uniqueID) == ["a:1:s", "c:3:s"], "末位拖到末尾顺序不变")
    noopFeed.ids = ["a:1:s", "b:2:s", "c:3:s"]
    settle(noop)
    check(noop.joystickSlots.map(\.uniqueID) == ["b:2:s", "a:1:s", "c:3:s"],
          "末位 no-op 不重写座次记忆：b 插回仍回记忆首位")
    // 对照：真正改动座次（a 拖到末尾）会重写记忆，离线的 b 退到末尾
    noopFeed.ids = ["a:1:s", "c:3:s"]
    settle(noop)
    noop.moveSlot(from: 0, to: 2)                       // [c, a]
    noopFeed.ids = ["a:1:s", "b:2:s", "c:3:s"]
    settle(noop)
    check(noop.joystickSlots.map(\.uniqueID) == ["c:3:s", "a:1:s", "b:2:s"],
          "真实拖放重写座次记忆：离线设备回插后排到末尾")

    // 单槽：落点 == 数量（唯一一张卡拖到末尾）同样是 no-op
    let single = DSModel()
    let singleFeed = ManyStickFeed(["s1"])
    single.hidPoller = { singleFeed.devices }
    single.pollAndPublishSnapshot()
    single.moveSlot(from: 0, to: 1)
    check(single.joystickSlots.map(\.uniqueID) == ["s1"] && single.joystickSlots[0].index == 0, "单槽拖到末尾无变化")

    // >6 槽位：第 7 张详情卡把手拖到顶部摘要卡 → 进入发送区间，前 6 个控制槽位随之重排
    let seven = DSModel()
    let sevenFeed = ManyStickFeed(["s1", "s2", "s3", "s4", "s5", "s6", "s7"])
    seven.hidPoller = { sevenFeed.devices }
    seven.pollAndPublishSnapshot()
    check(seven.joystickSlots.count == 7, "七只手柄全部可见")
    check(seven.latestPublishedJoysticks.map { $0.axes.first } == [1, 2, 3, 4, 5, 6], "只有槽位 0–5 进入控制快照")
    seven.moveSlot(from: 6, to: 2)
    check(seven.joystickSlots.map(\.uniqueID) == ["s1", "s2", "s7", "s3", "s4", "s5", "s6"],
          "第 7 槽拖到第 3 张摘要卡后被拖者占目标槽位")
    check(seven.joystickSlots.map(\.index) == Array(0..<7), "七槽编号连续")
    seven.pollAndPublishSnapshot()
    check(seven.latestPublishedJoysticks.map { $0.axes.first } == [1, 2, 7, 3, 4, 5], "控制快照按新座次发送前 6 个")
    settle(seven)
    check(seven.joystickSlots.map(\.uniqueID) == ["s1", "s2", "s7", "s3", "s4", "s5", "s6"], "七槽重扫后不回弹")
    seven.moveSlot(from: 0, to: 6)
    check(seven.joystickSlots.map(\.uniqueID) == ["s2", "s7", "s3", "s4", "s5", "s6", "s1"],
          "首槽拖到末尾（第 7 张详情卡）移到最后")

    // 拖放载荷：私有 UTI 往返；纯文本 provider 不含该类型，onDrop(of: 私有 UTI) 不会接受
    let provider = JoystickSlotDrag.provider(uniqueID: "a:1:s")
    check(provider.registeredTypeIdentifiers.contains(JoystickSlotDrag.typeIdentifier), "拖放载荷携带私有 UTI")
    check(provider.registeredTypeIdentifiers.contains(UTType.data.identifier),
          "拖放载荷同时注册 public.data：UTI 未声明时只带私有 UTI 的拖拽不会命中任何落点")
    let text = NSItemProvider(object: NSString(string: "a:1:s"))
    check(!text.registeredTypeIdentifiers.contains(JoystickSlotDrag.typeIdentifier), "外部文本 provider 不含私有 UTI")
    var decoded: String?
    let semaphore = DispatchSemaphore(value: 0)
    let dragBoard = NSPasteboard(name: .drag)
    defer { dragBoard.clearContents() }
    dragBoard.clearContents()
    JoystickSlotDrag.uniqueID(from: provider) { decoded = $0; semaphore.signal() }
    check(semaphore.wait(timeout: .now() + 2) == .success && decoded == "a:1:s", "载荷按私有 UTI 解码回 uniqueID")
    JoystickSlotDrag.uniqueID(from: text) { decoded = $0; semaphore.signal() }
    check(semaphore.wait(timeout: .now() + 2) == .success && decoded == nil, "纯文本 provider 解不出槽位载荷")

    // 生产 app 未在 Info.plist 声明该 UTI（UTType(exportedAs:) 为动态类型）。真实 HID 指针拖放验证（2026-11-23）
    // 发现：onDrop(of:) 仍会命中并调用落点闭包，但交给闭包的 provider 不暴露该类型（registeredTypeIdentifiers
    // 为空、loadDataRepresentation 拿不到数据），私有 UTI 数据只在拖拽粘贴板上——仅经 provider 解码会静默失败，
    // 落点接受了拖放却不排序。兜底：provider 没有该表示时直接读拖拽粘贴板。
    let bare = NSItemProvider()
    check(!bare.registeredTypeIdentifiers.contains(JoystickSlotDrag.typeIdentifier), "未声明 UTI 时 onDrop 拿到的 provider 不含私有 UTI 表示")
    dragBoard.setString("c:3:s", forType: NSPasteboard.PasteboardType(JoystickSlotDrag.typeIdentifier))
    JoystickSlotDrag.uniqueID(from: bare) { decoded = $0; semaphore.signal() }
    check(semaphore.wait(timeout: .now() + 2) == .success && decoded == "c:3:s",
          "provider 不暴露私有 UTI 时从拖拽粘贴板兜底解码 uniqueID")
    dragBoard.clearContents()
    JoystickSlotDrag.uniqueID(from: bare) { decoded = $0; semaphore.signal() }
    check(semaphore.wait(timeout: .now() + 2) == .success && decoded == nil, "provider 与拖拽粘贴板都无载荷时解不出 uniqueID")
}
