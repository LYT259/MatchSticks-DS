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
}
