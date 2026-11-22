import Foundation
import SwiftUI
import DSCore

func gamepadSkinPickerTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    let auto = DSSelectOption<GamepadSkin?>(value: nil, label: "Auto-Detect (current: PS5 DualSense)")
    let options = [auto] + GamepadSkin.selectableSkins.map {
        DSSelectOption(value: Optional($0), label: $0.displayName)
    }
    func search(_ query: String) -> [GamepadSkin?] {
        DSSelectControl<GamepadSkin?>.filter(options: options, query: query) {
            $0?.searchableText ?? "自动识别 自动检测 Auto Detect"
        }.map(\.value)
    }
    check(search("") == options.map(\.value), "空查询恢复自动、通用与所有具体型号")
    check(options[0].value == nil && options[1].value == .generic,
          "自动识别第一，通用第二，未连接时也显示真实生效型号")
    check(search("PS") == [.dualshock4, .dualsense].map(Optional.some),
          "PS 系列只显示 PS4 与 PS5")
    check(search("PS1").isEmpty && search("PS3").isEmpty, "已移除的 PS 旧型号不再出现在搜索结果")
    check(search(" pS 4 ") == [.dualshock4], "搜索忽略首尾空格、大小写与名称内空格")
    check(search("PlayStation").count == 2, "PlayStation 英文别名只覆盖保留的两代")
    check(search("DualSense") == [.dualsense], "DualSense 别名精确命中 PS5")
    check(search("冰原狼") == [.direwolf4], "冰原狼搜索只保留四代")
    check(search("Direwolf 4") == [.direwolf4], "英文型号与代数可组合搜索")
    check(search("Direwolf 2").isEmpty, "已移除的冰原狼旧型号不再出现")
    check(search("Logitech").contains(.f310) && search("Logitech").contains(.extreme3DPro),
          "罗技英文名可找到 F310 与飞行摇杆")
    check(search("不存在的型号").isEmpty, "无结果查询返回空列表")
    check(search("自动检测") == [nil], "自动项可通过其中文别名找到")
}
