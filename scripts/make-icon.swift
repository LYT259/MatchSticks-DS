// MatchSticks Driver Station 应用图标生成器：从用户原稿派生全尺寸 iconset（不再程序绘制）
// 用法：swift scripts/make-icon.swift <输出目录> [母版 PNG]
//       母版默认 Sources/MatchSticksDriverStaion/Resources/AppIcons/app-icon-day.png（按脚本位置解析）
// 行为契约（scripts/test-icon.sh 固化）：
//   - 母版必须是 1024×1024 可解码图片；缺失/损坏/尺寸不符 → 报错点名路径并以非零码退出
//   - 每次运行整体重建 <输出目录>/AppIcon.iconset（先删旧目录，不留任何陈旧产物）
//   - icon_512x512@2x.png 为母版逐字节副本；其余 9 个尺寸由母版高质量缩放
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "."
// 脚本路径先 absoluteURL 再解析符号链接：args[0] 是调用方给的原始形式（可能是
// 相对路径），标准化为绝对路径后按脚本位置反推仓库根——任意 cwd / 相对路径调用
// 都解析到同一份仓库母版（scripts/test-icon.sh T8 锁定该行为）
let scriptDir = URL(fileURLWithPath: args[0]).absoluteURL.resolvingSymlinksInPath().deletingLastPathComponent()
let defaultMaster = scriptDir.deletingLastPathComponent()
    .appendingPathComponent("Sources/MatchSticksDriverStaion/Resources/AppIcons/app-icon-day.png")
let masterURL = URL(fileURLWithPath: args.count > 2 ? args[2] : defaultMaster.path)

let entries: [(name: String, side: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("✗ make-icon: \(message)\n").utf8))
    exit(1)
}

guard let source = CGImageSourceCreateWithURL(masterURL as CFURL, nil) else {
    fail("无法读取母版：\(masterURL.path)（文件不存在或不是可识别的图片）")
}
guard let master = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("母版解码失败：\(masterURL.path)")
}
guard master.width == 1024, master.height == 1024 else {
    fail("母版必须是 1024×1024（当前 \(master.width)×\(master.height)）：\(masterURL.path)")
}

let fm = FileManager.default
let outDirURL = URL(fileURLWithPath: outDir, isDirectory: true)
let iconset = outDirURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
do {
    try fm.createDirectory(at: outDirURL, withIntermediateDirectories: true)
    if fm.fileExists(atPath: iconset.path) {
        try fm.removeItem(at: iconset)
    }
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    try fm.copyItem(at: masterURL, to: iconset.appendingPathComponent("icon_512x512@2x.png"))
} catch {
    fail("重建 iconset 失败：\(error)")
}

let colorSpace = master.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
for entry in entries where entry.side != 1024 {
    let side = entry.side
    guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("创建 \(side)×\(side) 位图上下文失败")
    }
    ctx.interpolationQuality = .high
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let scaled = ctx.makeImage() else {
        fail("缩放到 \(side)×\(side) 失败")
    }
    let url = iconset.appendingPathComponent(entry.name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("创建 PNG 写出目标失败：\(url.path)")
    }
    CGImageDestinationAddImage(dest, scaled, nil)
    guard CGImageDestinationFinalize(dest) else {
        fail("写出 PNG 失败：\(url.path)")
    }
}
print("iconset written to \(iconset.path)（母版：\(masterURL.lastPathComponent)）")
