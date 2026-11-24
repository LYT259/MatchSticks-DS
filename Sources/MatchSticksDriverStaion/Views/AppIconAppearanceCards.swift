import SwiftUI
import AppKit
import DSCore

// MARK: - 应用图标卡片选择器（几何对齐 PathBlender IconAppearancePicker / PreferencesPanel.css:100-114）
//
// 图标样式两列等宽卡、图标外观三列等宽卡，均直接绑定 DSModel 的独立偏好键即时生效：
// 预览区 80 高、中性底（hover，让浅/深两种瓷片轮廓都可见）、圆角 7、1pt 边线；
// 选中 = 2pt 强调色外描边（外扩 3），键盘焦点 = 3pt 焦点环（外扩 3）；标签在预览下方
// （选中加粗提亮）。跟随系统 / 样式卡恒为 78×60 容器内两张 48pt 图、第二张偏移 (30,12)；
// 固定浅色/深色 = 56pt 单图。图稿一律经白名单加载 Bundle.module 的 1024pt PNG，
// 高插值下采样（绝不读 icns 小尺寸或运行时图标）。

/// 卡片几何常量（与 PathBlender preferences-icon-preview 逐项对应）。
private enum AppIconCardGeometry {
    static let previewHeight: CGFloat = 80
    static let cornerRadius: CGFloat = 7
    static let singleTileSize: CGFloat = 56
    static let pairWidth: CGFloat = 78
    static let pairHeight: CGFloat = 60
    static let pairTileSize: CGFloat = 48
    static let pairOffsetX: CGFloat = 30
    static let pairOffsetY: CGFloat = 12
    static let selectionRingWidth: CGFloat = 2
    static let focusRingWidth: CGFloat = 3
    static let ringGap: CGFloat = 3
    static let cardSpacing: CGFloat = 12
    static let labelSpacing: CGFloat = 9
}

/// 图标样式选择：两列等宽卡，每张恒为该样式的浅/深双图对比（直观看到两种深浅效果）。
struct AppIconStyleCardPicker: View {
    let title: String
    @Binding var selection: IconStyle
    var artwork: (IconStyle, Bool) -> NSImage? = { AppIconArtwork.image(style: $0, dark: $1) }

    @FocusState private var focused: IconStyle?

    var body: some View {
        HStack(alignment: .top, spacing: AppIconCardGeometry.cardSpacing) {
            ForEach(IconStyle.allCases, id: \.self) { style in
                AppIconOptionCard(
                    label: label(for: style),
                    isSelected: selection == style,
                    isFocused: focused == style,
                    action: { selection = style },
                    preview: { AppIconPairArtwork(light: artwork(style, false), dark: artwork(style, true)) }
                )
                .focused($focused, equals: style)
                .accessibilityLabel("\(title)，\(label(for: style))")
                .accessibilityAddTraits(selection == style ? .isSelected : [])
            }
        }
    }

    private func label(for style: IconStyle) -> String {
        switch style {
        case .color: return tr("彩色")
        case .monochrome: return tr("单色")
        }
    }
}

/// 图标外观选择：三列等宽卡，图稿跟随当前样式——跟随系统 = 双图，固定浅色/深色 = 对应单图。
struct AppIconAppearanceCardPicker: View {
    let title: String
    let style: IconStyle
    @Binding var selection: AppearanceMode
    var artwork: (IconStyle, Bool) -> NSImage? = { AppIconArtwork.image(style: $0, dark: $1) }

    @FocusState private var focused: AppearanceMode?

    var body: some View {
        HStack(alignment: .top, spacing: AppIconCardGeometry.cardSpacing) {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                AppIconOptionCard(
                    label: label(for: mode),
                    isSelected: selection == mode,
                    isFocused: focused == mode,
                    action: { selection = mode },
                    preview: {
                        switch mode {
                        case .system:
                            AppIconPairArtwork(light: artwork(style, false), dark: artwork(style, true))
                        case .light:
                            AppIconSingleArtwork(image: artwork(style, false))
                        case .dark:
                            AppIconSingleArtwork(image: artwork(style, true))
                        }
                    }
                )
                .focused($focused, equals: mode)
                .accessibilityLabel("\(title)，\(label(for: mode))")
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }
    }

    private func label(for mode: AppearanceMode) -> String {
        switch mode {
        case .system: return tr("跟随系统")
        case .light: return tr("浅色")
        case .dark: return tr("深色")
        }
    }
}

/// 单张卡片：预览舞台在上、标签在下；整卡可点、键盘可聚焦、读屏报「组名，选项名」+ 选中态。
private struct AppIconOptionCard<Preview: View>: View {
    let label: String
    let isSelected: Bool
    var isFocused = false
    let action: () -> Void
    @ViewBuilder let preview: Preview

    var body: some View {
        Button(action: action) {
            VStack(spacing: AppIconCardGeometry.labelSpacing) {
                AppIconCardStage(isSelected: isSelected, isFocused: isFocused) { preview }
                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? DSTheme.textPrimary : DSTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(AppIconCardButtonStyle())
    }
}

/// 预览舞台：中性底 + 1pt 边线 + 圆角 7；选中/焦点描边画在舞台外侧（不侵占预览内容）。
struct AppIconCardStage<Content: View>: View {
    let isSelected: Bool
    var isFocused = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: AppIconCardGeometry.previewHeight)
            .background(DSTheme.hover, in: RoundedRectangle(cornerRadius: AppIconCardGeometry.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: AppIconCardGeometry.cornerRadius).strokeBorder(DSTheme.line))
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: AppIconCardGeometry.cornerRadius + AppIconCardGeometry.ringGap + AppIconCardGeometry.focusRingWidth)
                        .strokeBorder(DSTheme.focusRing, lineWidth: AppIconCardGeometry.focusRingWidth)
                        .padding(-(AppIconCardGeometry.ringGap + AppIconCardGeometry.focusRingWidth))
                } else if isSelected {
                    RoundedRectangle(cornerRadius: AppIconCardGeometry.cornerRadius + AppIconCardGeometry.ringGap + AppIconCardGeometry.selectionRingWidth)
                        .strokeBorder(DSTheme.accentText, lineWidth: AppIconCardGeometry.selectionRingWidth)
                        .padding(-(AppIconCardGeometry.ringGap + AppIconCardGeometry.selectionRingWidth))
                }
            }
    }
}

/// 跟随系统 / 样式卡的双图：78×60 容器内两张 48pt 图，第二张（深色）偏移 (30,12) 叠在上层。
struct AppIconPairArtwork: View {
    let light: NSImage?
    let dark: NSImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            AppIconArtworkTile(image: light)
                .frame(width: AppIconCardGeometry.pairTileSize, height: AppIconCardGeometry.pairTileSize)
            AppIconArtworkTile(image: dark)
                .frame(width: AppIconCardGeometry.pairTileSize, height: AppIconCardGeometry.pairTileSize)
                .offset(x: AppIconCardGeometry.pairOffsetX, y: AppIconCardGeometry.pairOffsetY)
        }
        .frame(width: AppIconCardGeometry.pairWidth, height: AppIconCardGeometry.pairHeight, alignment: .topLeading)
    }
}

/// 固定浅色/深色卡的单图：56pt 居中。
struct AppIconSingleArtwork: View {
    let image: NSImage?

    var body: some View {
        AppIconArtworkTile(image: image)
            .frame(width: AppIconCardGeometry.singleTileSize, height: AppIconCardGeometry.singleTileSize)
    }
}

/// 单张图稿：1024pt 原图高插值下采样；缺失时用卡片底色占位保持几何（图稿自带圆角瓷片，无需裁剪）。
private struct AppIconArtworkTile: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Rectangle().fill(DSTheme.card)
            }
        }
    }
}

/// 卡片按钮：无自带边框，仅按压轻微降不透明度（选中态由舞台外描边表达）。
private struct AppIconCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}
