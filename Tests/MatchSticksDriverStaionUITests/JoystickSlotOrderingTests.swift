import AppKit
import DSCore
import UniformTypeIdentifiers

// MARK: 手柄槽位拖放排序（任意 source→destination）+ 槽位标题型号显示名
//
// 删除上移/下移按钮后，顶部槽位摘要卡拖放是唯一排序路径：模型必须支持任意
// source→destination；越界/原地/落点未知不得改动座次；可见槽位、控制快照与
// 热插拔恢复三者顺序保持一致。
//
// 2026-11-24 稀疏槽位：source/destination 都是物理槽号（slot.index）。joystickSlots 仍是紧凑数组、
// 按 slot.index 排序（空槽不在数组里）；空洞只在线上输出层用中性占位表达——NI 0x0C / MRC 手柄 tag
// 与描述符 tag 都按数组顺序对号入座，不占位会把后面的手柄错位到前面的槽号。拖到空闲卡真正留洞，
// 重扫/插拔按绝对槽号回座，新设备追加在末尾、不填旧洞。

private extension Array {
    /// 越界返回 nil：断言线上第 n 槽时，不占位的实现只会发更少的项，应记为失败而不是让测试崩在索引上。
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

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
    check(model.joystickSlots.map(\.index) == [0, 1, 2], "首扫落座 0–2")

    // 任意位置排序：slot 0 直接拖到 slot 2（被拖者占目标槽位，其余顺延）
    model.moveSlot(from: 0, to: 2)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"],
          "slot 0 → slot 2 非相邻拖放立即生效")
    check(model.joystickSlots.map(\.index) == [0, 1, 2], "目标被占用时顺延：槽位编号连续重排")
    // 控制快照按 50Hz tick 重建：下一次轮询即按新座次发送，与可见槽位一致
    model.pollAndPublishSnapshot()
    check(model.latestPublishedJoysticks.map { $0.axes.first } == [2, 3, 1],
          "控制快照按新座次发送（与可见槽位一致）")
    check(model.latestPublishedJoystickDescriptors.map(\.index) == [0, 1, 2]
          && model.latestPublishedJoystickDescriptors.map(\.name) == ["Xbox Wireless Controller", "Cool Pad", "Wireless Controller"],
          "描述符按新座次发送")

    // 反向：末位拖到首位
    model.moveSlot(from: 2, to: 0)
    check(model.joystickSlots.map(\.uniqueID) == ["a:1:s", "b:2:s", "c:3:s"], "slot 2 → slot 0 拖回原位")

    // 拖到空闲摘要卡 3：被拖者真正落座 3，原槽 0 留洞，其余卡片不动（不再钳到末尾压缩）
    model.moveSlot(from: 0, to: 3)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"] && model.joystickSlots.map(\.index) == [1, 2, 3],
          "拖到空闲卡 3：a 落座 3，原槽 0 留洞，b/c 不动")
    check(model.joystickSlots.first { $0.index == 0 } == nil, "槽 0 是空洞（紧凑数组里没有它）")
    model.pollAndPublishSnapshot()
    check(model.latestPublishedJoysticks.map { $0.axes.first } == [nil, 2, 3, 1], "控制快照随空洞落点同步：槽 0 为中性占位")
    check(model.latestPublishedJoysticks[safe: 0] == JoystickData(), "空洞占位是中性 JoystickData")
    check(model.latestPublishedJoystickDescriptors.map(\.index) == [0, 1, 2, 3]
          && model.latestPublishedJoystickDescriptors[safe: 0] == JoystickSlot.emptyDescriptor(index: 0)
          && model.latestPublishedJoystickDescriptors[safe: 3]?.name == "Wireless Controller",
          "描述符同样占位：洞 0 为空描述符、真实项 index 3")

    // 越界 / 原地 / 源不存在：座次不得改变（无效拖放只回弹，不写座次记忆）
    model.moveSlot(from: 0, to: 99)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"], "落点越界（99）被忽略")
    model.moveSlot(from: 0, to: 6)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"], "落点超出摘要卡范围（6）被忽略")
    model.moveSlot(from: 0, to: 2)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"], "源槽位是空洞被忽略")
    model.moveSlot(from: -1, to: 0)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"], "源槽位为负被忽略")
    model.moveSlot(from: 1, to: 1)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"], "原地落点被忽略")
    model.moveSlot(from: 7, to: 1)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"], "源槽位越界被忽略")
    settle(model)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"] && model.joystickSlots.map(\.index) == [1, 2, 3],
          "无效拖放不写座次：重扫防抖窗口后仍保持拖放后的座次与空洞")

    // 热插拔：拖放后的座次在拔出/插回后保持（离线设备回原槽，在场设备不压缩）
    feed.third = nil
    settle(model)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "a:1:s"] && model.joystickSlots.map(\.index) == [1, 3],
          "拔出 c 后在场设备保持原槽（槽 2 留给 c）")
    check(model.latestPublishedJoysticks.map { $0.axes.first } == [nil, 2, nil, 1], "拔出后控制快照按剩余槽位占位")
    feed.third = 3
    settle(model)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"] && model.joystickSlots.map(\.index) == [1, 2, 3],
          "插回 c 回到原槽 2")
    check(model.latestPublishedJoysticks.map { $0.axes.first } == [nil, 2, 3, 1], "插回后控制快照与可见槽位一致")

    // 拖放后再次重扫（过了 0.5s 防抖）不回弹
    model.moveSlot(from: 1, to: 0)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"] && model.joystickSlots.map(\.index) == [0, 2, 3],
          "slot 1 → 空洞 0 立即生效：b 挪进空洞，c/a 不动")
    settle(model)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"] && model.joystickSlots.map(\.index) == [0, 2, 3],
          "拖放顺序在重扫防抖窗口后不回弹")
    check(model.latestPublishedJoysticks.map { $0.axes.first } == [2, nil, 3, 1], "重扫后控制快照仍按拖放顺序")

    // 相邻步进旧入口仍可用（与拖到相邻槽位等价）
    model.moveSlot(0, up: false)
    check(model.joystickSlots.map(\.uniqueID) == ["b:2:s", "c:3:s", "a:1:s"] && model.joystickSlots.map(\.index) == [1, 2, 3],
          "旧 moveSlot(up: false) 与拖到下一槽位等价：b 挪进空洞 1")

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

/// 按 id 稳定的手柄流：名称/VID/PID/首轴值由该 id 在初始序列中的序号决定，插拔不改变身份值。
private final class StableStickFeed {
    private let table: [String: HIDDeviceSnapshot]
    var ids: [String]

    init(_ ids: [String], make: (String, Int) -> HIDDeviceSnapshot = StableStickFeed.generic) {
        var table: [String: HIDDeviceSnapshot] = [:]
        for (ordinal, id) in ids.enumerated() { table[id] = make(id, ordinal) }
        self.table = table
        self.ids = ids
    }

    var devices: [HIDDeviceSnapshot] { ids.compactMap { table[$0] } }

    static func generic(_ id: String, _ ordinal: Int) -> HIDDeviceSnapshot {
        HIDDeviceSnapshot(uniqueID: id, name: "Stick \(id)", vendorID: 0x1234, productID: 0x1000 + ordinal,
                          axes: [Float(ordinal + 1)], axisUsages: [0x30], buttons: 0, buttonCount: 4, povs: [-1],
                          isXbox: false, mode: .directInput,
                          polarity: GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: false),
                          usbLocationID: nil)
    }
}

/// 单只 PS4 DualShock 4 自报名快照（054C:05C4）；首轴取 1.0，线上 Int8 量化后仍精确可辨。
private func ps4Snapshot() -> HIDDeviceSnapshot {
    HIDDeviceSnapshot(uniqueID: "ps4", name: "Wireless Controller", vendorID: 0x054C, productID: 0x05C4,
                      axes: [1], axisUsages: [0x30], buttons: 0, buttonCount: 14, povs: [-1],
                      isXbox: false, mode: .directInput,
                      polarity: GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: false),
                      usbLocationID: nil)
}

/// 按 DS → robot 描述符 tag 帧（0x02）的线上顺序还原每只手柄的描述符。
private func decodeDescriptorTag(_ frame: Data) -> [NICodec.JoystickDescriptor] {
    var r = ByteReader(frame)
    guard let length = r.u16be(), r.u8() == 0x02, r.remaining == Int(length) - 1 else { return [] }
    var result: [NICodec.JoystickDescriptor] = []
    while r.remaining > 0 {
        var d = NICodec.JoystickDescriptor()
        guard let index = r.u8(), let xbox = r.u8(), let type = r.i8(), let name = r.string8(),
              let axisCount = r.u8() else { return [] }
        d.index = Int(index)
        d.isXbox = xbox == 1
        d.type = type
        d.name = name
        for _ in 0..<Int(axisCount) {
            guard let axisType = r.u8() else { return [] }
            d.axisTypes.append(axisType)
        }
        guard let buttons = r.u8(), let povs = r.u8() else { return [] }
        d.buttonCount = Int(buttons)
        d.povCount = Int(povs)
        result.append(d)
    }
    return result
}

/// 稀疏槽位边界：无效/原地/末位 no-op、单只手柄拖到空槽、多空洞与新设备、>6 槽位、线上占位。
/// 由 joystickSlotDragBoundaryTests 调起；拖放载荷断言留在该函数里，不在此处。
@MainActor
func joystickSlotSparseSlotTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    func settle(_ model: DSModel) {
        Thread.sleep(forTimeInterval: 0.55)
        model.pollAndPublishSnapshot()
    }
    /// 控制快照与可见槽逐槽对齐：0…min(5, 最大槽号) 每槽要么是该槽手柄的数据+描述符，要么是中性占位
    func snapshotMatchesVisible(_ model: DSModel) -> Bool {
        let data = model.latestPublishedJoysticks
        let descriptors = model.latestPublishedJoystickDescriptors
        guard data.count == descriptors.count else { return false }
        guard let last = model.joystickSlots.map(\.index).max() else { return data.isEmpty }
        guard data.count == min(5, last) + 1 else { return false }
        for seat in 0..<data.count {
            if let slot = model.joystickSlots.first(where: { $0.index == seat }) {
                if data[seat] != slot.data || descriptors[seat] != slot.descriptor { return false }
            } else if data[seat] != JoystickData() || descriptors[seat] != JoystickSlot.emptyDescriptor(index: seat) {
                return false
            }
        }
        return true
    }

    // 无效 / 原地 no-op 不写座次记忆：离线设备记住的绝对槽位不受无效果操作影响
    let noop = DSModel()
    let noopFeed = StableStickFeed(["a:1:s", "b:2:s", "c:3:s"])
    noop.hidPoller = { noopFeed.devices }
    noop.pollAndPublishSnapshot()
    noop.moveSlot(from: 1, to: 0)                       // [b0, a1, c2]
    check(noop.joystickSlots.map(\.uniqueID) == ["b:2:s", "a:1:s", "c:3:s"], "slot 1 → slot 0：b 占 0，其余顺延")
    noopFeed.ids = ["a:1:s", "c:3:s"]                   // b 离线，槽 0 为它保留
    settle(noop)
    check(noop.joystickSlots.map(\.uniqueID) == ["a:1:s", "c:3:s"] && noop.joystickSlots.map(\.index) == [1, 2],
          "b 拔出后 a、c 保持原槽（槽 0 留给 b）")
    noop.moveSlot(from: 0, to: 2)                       // 源槽 0 是离线设备留下的空洞
    check(noop.joystickSlots.map(\.index) == [1, 2], "源槽位是空洞被忽略")
    noop.moveSlot(from: 2, to: 2)                       // 原地
    check(noop.joystickSlots.map(\.index) == [1, 2], "原地落点被忽略")
    noop.moveSlot(from: 1, to: 6)                       // 落点超出摘要卡范围
    check(noop.joystickSlots.map(\.index) == [1, 2], "落点越界被忽略")
    noopFeed.ids = ["a:1:s", "b:2:s", "c:3:s"]
    settle(noop)
    check(noop.joystickSlots.map(\.uniqueID) == ["b:2:s", "a:1:s", "c:3:s"] && noop.joystickSlots.map(\.index) == [0, 1, 2],
          "无效/原地 no-op 不写座次记忆：b 插回仍回槽 0")
    // 对照：真正占用离线设备的槽位——离线设备冲突时让到首个空位
    noopFeed.ids = ["a:1:s", "c:3:s"]
    settle(noop)
    noop.moveSlot(from: 1, to: 0)                       // a 占 b 的槽 0 → [a0, c2]，b 让到首个空位 1
    check(noop.joystickSlots.map(\.uniqueID) == ["a:1:s", "c:3:s"] && noop.joystickSlots.map(\.index) == [0, 2],
          "在场设备拖到离线设备保留的槽位：立即落座")
    noopFeed.ids = ["a:1:s", "b:2:s", "c:3:s"]
    settle(noop)
    check(noop.joystickSlots.map(\.uniqueID) == ["a:1:s", "b:2:s", "c:3:s"] && noop.joystickSlots.map(\.index) == [0, 1, 2],
          "离线设备槽位被占后让到首个空位：b 插回落到槽 1")

    // 单槽拖到空槽：唯一一只 PS4 从槽 0 拖到空闲的槽 1 必须真的落座 1——旧实现把落点钳回 0，
    // 单只手柄永远拖不动（2026-11-24 反转旧断言「单槽拖到末尾无变化」）
    let single = DSModel()
    let singleFeed = StableStickFeed(["ps4"]) { _, _ in ps4Snapshot() }
    single.hidPoller = { singleFeed.devices }
    single.pollAndPublishSnapshot()
    check(single.joystickSlots.map(\.index) == [0] && single.latestPublishedJoysticks.map { $0.axes.first } == [1],
          "单只 PS4 首扫落座 0，控制快照 1 项")
    single.moveSlot(from: 0, to: 1)
    check(single.joystickSlots.map(\.uniqueID) == ["ps4"] && single.joystickSlots.map(\.index) == [1],
          "单只 PS4 从槽 0 拖到空槽 1：PS4.index == 1")
    check(single.joystickSlots.first { $0.index == 0 } == nil, "槽 0 为空")
    single.pollAndPublishSnapshot()
    check(single.latestPublishedJoysticks.count == 2 && single.latestPublishedJoysticks[safe: 0] == JoystickData()
          && single.latestPublishedJoysticks[safe: 1]?.axes.first == 1,
          "只有设备在槽 1：数据 2 项、首项中性占位、真实项在 1")
    check(single.latestPublishedJoystickDescriptors.count == 2
          && single.latestPublishedJoystickDescriptors[safe: 0] == JoystickSlot.emptyDescriptor(index: 0),
          "描述符同样 2 项：槽 0 占位 index 0、type -1、isXbox false、名称/轴/按钮/POV 为空")
    let real = single.latestPublishedJoystickDescriptors[safe: 1] ?? NICodec.JoystickDescriptor()
    check(real.index == 1 && real.type == 20 && real.isXbox == false && real.name == "Wireless Controller"
          && real.buttonCount == 14 && real.povCount == 1 && real.axisTypes.isEmpty,
          "槽 1 保留 PS4 真实描述符")
    check(snapshotMatchesVisible(single), "控制快照与可见槽逐槽一致")
    // 线上顺序：NI 0x0C / MRC 手柄 tag 与 NI 描述符 tag 都按数组顺序对号入座，编解码后槽序不变
    let ni = NICodec.decodeControl(NICodec.controlPacket(seq: 7, control: ControlWord(), request: RequestWord(),
                                                         alliance: .red1, joysticks: single.latestPublishedJoysticks))
    check(ni?.joysticks.count == 2 && ni?.joysticks[0] == JoystickData() && ni?.joysticks[1].axes.first == 1,
          "NI 编解码后：2 项、首项空、真实项在 1")
    let mrc = MRCPackets.decodeControl(MRCPackets.controlPacket(seq: 7, control: MRCControlWord(), alliance: .red1,
                                                                joysticks: single.latestPublishedJoysticks))
    check(mrc?.joysticks.count == 2 && mrc?.joysticks[0] == JoystickData() && mrc?.joysticks[1].axes.first == 1,
          "MRC 编解码后：2 项、首项空、真实项在 1")
    let wireDescriptors = decodeDescriptorTag(NICodec.joystickDescriptorTag(single.latestPublishedJoystickDescriptors))
    check(wireDescriptors.count == 2 && wireDescriptors[safe: 0] == JoystickSlot.emptyDescriptor(index: 0)
          && wireDescriptors[safe: 1]?.index == 1 && wireDescriptors[safe: 1]?.name == "Wireless Controller"
          && wireDescriptors[safe: 1]?.type == 20,
          "NI 描述符 tag 编码后顺序与占位一致（首项 type -1、次项 PS4 index 1）")
    // 重扫 / 插拔后仍在 1
    settle(single)
    check(single.joystickSlots.map(\.index) == [1] && single.latestPublishedJoysticks.count == 2,
          "重扫防抖窗口后 PS4 仍在槽 1")
    singleFeed.ids = []
    settle(single)
    check(single.joystickSlots.isEmpty && single.latestPublishedJoysticks.isEmpty
          && single.latestPublishedJoystickDescriptors.isEmpty,
          "拔出后无槽位、不发送")
    singleFeed.ids = ["ps4"]
    settle(single)
    check(single.joystickSlots.map(\.index) == [1] && single.joystickSlots[0].uniqueID == "ps4", "插回后 PS4 回到槽 1")
    check(single.latestPublishedJoysticks.count == 2 && single.latestPublishedJoysticks[safe: 0] == JoystickData()
          && single.latestPublishedJoysticks[safe: 1]?.axes.first == 1,
          "插回后仍发 2 项（首项占位）")
    // 拖回槽 0：不保留尾部占位
    single.moveSlot(from: 1, to: 0)
    check(single.joystickSlots.map(\.index) == [0], "拖回槽 0 立即生效")
    single.pollAndPublishSnapshot()
    check(single.latestPublishedJoysticks.count == 1 && single.latestPublishedJoysticks[safe: 0]?.axes.first == 1
          && single.latestPublishedJoystickDescriptors.count == 1
          && single.latestPublishedJoystickDescriptors[safe: 0]?.index == 0,
          "拖回槽 0 后不保留尾部占位：数据/描述符各 1 项")
    settle(single)
    check(single.joystickSlots.map(\.index) == [0] && single.latestPublishedJoysticks.count == 1, "重扫后仍在槽 0")

    // 多个空洞 + 新设备不填旧洞：拖放留下的空洞只在用户显式拖入时才被占用
    let holes = DSModel()
    let holesFeed = StableStickFeed(["a", "b", "c", "d", "e"])
    holesFeed.ids = ["a", "b", "c"]                     // 首轴值：a=1 b=2 c=3 d=4 e=5
    holes.hidPoller = { holesFeed.devices }
    holes.pollAndPublishSnapshot()
    holes.moveSlot(from: 0, to: 4)                      // a → 4：[b1, c2, a4]，洞 0
    check(holes.joystickSlots.map(\.uniqueID) == ["b", "c", "a"] && holes.joystickSlots.map(\.index) == [1, 2, 4],
          "拖到空槽 4：a 落座 4、原槽 0 留洞，其余不动")
    holes.moveSlot(from: 1, to: 3)                      // b → 3：[c2, b3, a4]，洞 0、1
    check(holes.joystickSlots.map(\.uniqueID) == ["c", "b", "a"] && holes.joystickSlots.map(\.index) == [2, 3, 4],
          "拖到空槽 3：b 落座 3、原槽 1 留洞，其余不动")
    holes.pollAndPublishSnapshot()
    check(holes.latestPublishedJoysticks.map { $0.axes.first } == [nil, nil, 3, 2, 1], "多个空洞：槽 0、1 为中性占位")
    check(holes.latestPublishedJoystickDescriptors.map(\.index) == [0, 1, 2, 3, 4]
          && holes.latestPublishedJoystickDescriptors.map(\.type) == [-1, -1, 20, 20, 20],
          "描述符按槽号占位：洞 type -1")
    check(snapshotMatchesVisible(holes), "控制快照与可见槽逐槽一致（多空洞）")
    holesFeed.ids = ["a", "b", "c", "d"]                 // 新手柄 d：追加到末尾（5），不填洞 0、1
    settle(holes)
    check(holes.joystickSlots.map(\.uniqueID) == ["c", "b", "a", "d"] && holes.joystickSlots.map(\.index) == [2, 3, 4, 5],
          "新设备追加到末尾，不填旧洞")
    holesFeed.ids = ["a", "b", "c", "d", "e"]            // 再来一只：落到 6（>6 既有行为）
    settle(holes)
    check(holes.joystickSlots.map(\.index) == [2, 3, 4, 5, 6] && holes.joystickSlots.last?.uniqueID == "e", "第五只落到槽 6")
    check(holes.latestPublishedJoysticks.map { $0.axes.first } == [nil, nil, 3, 2, 1, 4]
          && holes.latestPublishedJoystickDescriptors.count == 6,
          ">6 仍只发 0–5（槽 6 的 e 不发）")
    check(snapshotMatchesVisible(holes), "控制快照与可见槽逐槽一致（>6）")
    // 显式拖入旧洞：e（槽 6）拖到槽 1 → 真正进洞并发送，其余卡片不动
    holes.moveSlot(from: 6, to: 1)
    check(holes.joystickSlots.map(\.uniqueID) == ["e", "c", "b", "a", "d"] && holes.joystickSlots.map(\.index) == [1, 2, 3, 4, 5],
          "槽 6 的 e 拖到空洞 1：只动被拖者")
    holes.pollAndPublishSnapshot()
    check(holes.latestPublishedJoysticks.map { $0.axes.first } == [nil, 5, 3, 2, 1, 4]
          && holes.latestPublishedJoystickDescriptors.map(\.type) == [-1, 20, 20, 20, 20, 20],
          "拖入旧洞后：槽 0 仍为占位，e 进入发送区间")
    check(snapshotMatchesVisible(holes), "控制快照与可见槽逐槽一致（拖入旧洞）")

    // >6 槽位：第 7 张详情卡把手拖到顶部摘要卡 → 进入发送区间，前 6 个控制槽位随之重排
    let seven = DSModel()
    let sevenFeed = StableStickFeed(["s1", "s2", "s3", "s4", "s5", "s6", "s7"])
    seven.hidPoller = { sevenFeed.devices }
    seven.pollAndPublishSnapshot()
    check(seven.joystickSlots.count == 7, "七只手柄全部可见")
    check(seven.latestPublishedJoysticks.map { $0.axes.first } == [1, 2, 3, 4, 5, 6], "只有槽位 0–5 进入控制快照")
    check(seven.latestPublishedJoysticks.count == 6 && seven.latestPublishedJoystickDescriptors.count == 6,
          ">6 时数据/描述符仍只发 0–5，无占位")
    check(seven.latestPublishedJoystickDescriptors.allSatisfy { $0.type == 20 }, "七槽全为真实描述符")
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
    // >6 时落点 == 数量仍表示移到末位；末位拖到末尾是真正的 no-op
    seven.moveSlot(from: 6, to: 7)
    check(seven.joystickSlots.map(\.uniqueID) == ["s2", "s7", "s3", "s4", "s5", "s6", "s1"], "末位拖到末尾顺序不变")
    seven.moveSlot(from: 0, to: 7)
    check(seven.joystickSlots.map(\.uniqueID) == ["s7", "s3", "s4", "s5", "s6", "s1", "s2"], "首槽拖到末尾（落点 == 数量）移到最后")
    check(seven.joystickSlots.map(\.index) == Array(0..<7), "七槽移到末尾后编号连续")
    seven.pollAndPublishSnapshot()
    check(seven.latestPublishedJoysticks.map { $0.axes.first } == [7, 3, 4, 5, 6, 1], "移到末尾后控制快照按新座次发送前 6 个")
    check(snapshotMatchesVisible(seven), "控制快照与可见槽逐槽一致（七槽）")
}

@MainActor
func joystickSlotDragBoundaryTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    joystickSlotSparseSlotTests(check)

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
