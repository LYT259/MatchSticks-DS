import AppKit
import SwiftUI
import DSCore

@MainActor
func gamepadRenderingTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    let texture = NSImage(size: NSSize(width: 60, height: 60))
    texture.lockFocus()
    NSColor.darkGray.setFill()
    NSBezierPath(ovalIn: CGRect(x: 4, y: 4, width: 52, height: 52)).fill()
    texture.unlockFocus()

    let view = ZStack(alignment: .topLeading) {
        NativeStickCap(image: texture, rect: CGRect(x: 60, y: 70, width: 60, height: 60),
                       offset: .zero, pressed: true)
    }
    .frame(width: 200, height: 200)
    .background(Color.white)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    guard let image = renderer.nsImage,
          let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!) else {
        check(false, "摇杆按下描边渲染可读取")
        return
    }
    var outsideBlue = false
    for y in 0..<200 {
        for x in 0..<200 {
            guard x < 54 || x > 126 || y < 64 || y > 136,
                  let color = bitmap.colorAt(x: x, y: y) else { continue }
            if color.blueComponent > 0.8 && color.greenComponent > 0.3 && color.redComponent < 0.3 {
                outsideBlue = true
            }
        }
    }
    check(!outsideBlue, "摇杆按下描边只围绕原生摇杆帽，不扩张到整只手柄")

    guard let sourceContext = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                       bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        check(false, "重影回归源图可创建")
        return
    }
    sourceContext.setFillColor(NSColor.white.cgColor)
    sourceContext.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    sourceContext.setFillColor(NSColor.red.cgColor)
    sourceContext.fill(CGRect(x: 16, y: 16, width: 16, height: 16))
    guard let sourceImage = sourceContext.makeImage(),
          let baseImage = GamepadArtworkImageSource.imageWithoutStickCaps(
            sourceImage, capRegions: [CGRect(x: 16, y: 16, width: 16, height: 16)]) else {
        check(false, "底图应能去除原摇杆以消除重影")
        return
    }
    let baseBitmap = NSBitmapImageRep(cgImage: baseImage)
    let center = baseBitmap.colorAt(x: 24, y: 24)
    let outside = baseBitmap.colorAt(x: 0, y: 0)
    check(center?.redComponent != 1 || center?.greenComponent != 0 || center?.blueComponent != 0,
          "底图不再保留原摇杆，移动时只显示一层摇杆")
    check(outside?.redComponent == 1 && outside?.greenComponent == 1 && outside?.blueComponent == 1,
          "去除原摇杆不改变手柄其他区域的像素")
}
