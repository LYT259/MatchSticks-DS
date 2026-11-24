import AppKit
import DSCore

func thumbstickMotionTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    let well = CGRect(x: 100, y: 80, width: 160, height: 150)
    let cap = CGRect(x: 120, y: 95, width: 120, height: 110)
    func state(_ x: Float, _ y: Float) -> GamepadStickState {
        GamepadStickState(x: x, yUp: y, pressed: false)
    }
    guard let geometry = ThumbstickGeometry.resolve(cap: cap) else {
        check(false, "三维摇杆几何可由帽顶轮廓解出")
        return
    }
    let radius = cap.width / 2
    check(geometry.cameraPitch == ThumbstickGeometry.viewPitch,
          "参考图视角固定为产品图的默认俯角，同一手柄的左右摇杆一致")
    check(abs(2 * geometry.capDepth * cos(geometry.cameraPitch) + geometry.capThickness * sin(geometry.cameraPitch) - cap.height) < 0.01,
          "中立帽顶轮廓（顶面加可见侧面）与原图帽顶高度一致")
    check(geometry.capThickness > 0 && geometry.capThickness < radius, "帽顶有真实厚度且不超过帽顶半径")
    let square = ThumbstickGeometry.resolve(cap: CGRect(x: 0, y: 0, width: 100, height: 100))
    let flat = ThumbstickGeometry.resolve(cap: CGRect(x: 0, y: 0, width: 100, height: 80))
    let tall = ThumbstickGeometry.resolve(cap: CGRect(x: 0, y: 0, width: 100, height: 103))
    check(square?.cameraPitch == ThumbstickGeometry.viewPitch && flat?.cameraPitch == ThumbstickGeometry.viewPitch &&
              abs((square?.capDepth ?? 0) - 50) < 0.05 && (flat?.capDepth ?? 50) < 50 && (tall?.capDepth ?? 0) > 50 &&
              abs((flat?.capDepth ?? 0) * 2 * cos(ThumbstickGeometry.viewPitch) +
                  (flat?.capThickness ?? 0) * sin(ThumbstickGeometry.viewPitch) - 80) < 0.000001,
          "俯角固定不变，偏扁或偏高的帽顶用椭圆截面贴合原图轮廓，且仍有真实厚度")

    let neutral = ThumbstickMotion.pose(cap: cap, state: state(0, 0))
    check(neutral.tiltX == 0 && neutral.tiltY == 0 && neutral.travel == .zero,
          "三维摇杆中立时不倾斜、无位移")
    check(neutral.capSize == cap.size && neutral.pivot == geometry.pivot, "中立帽顶尺寸来自标定")
    check(neutral.pivot.x == cap.midX && neutral.pivot.y > cap.midY && well.contains(neutral.pivot),
          "转动轴心在帽顶前下方（靠使用者一侧）的井口内，而不是帽顶后方或井口中心")

    let right = ThumbstickMotion.pose(cap: cap, state: state(1, 0))
    check(right.pivot == neutral.pivot && right.tiltY > 0 && right.tiltX == 0,
          "右拨绕自身轴心侧倾而非平移贴图")
    check(right.travel.width > 0 && abs(right.travel.height) < cap.width * 0.05,
          "右拨帽顶向右移动，只略微降低")

    let left = ThumbstickMotion.pose(cap: cap, state: state(-1, 0))
    check(left.tiltY < 0 && left.travel.width == -right.travel.width, "左拨方向与右拨相反")
    let up = ThumbstickMotion.pose(cap: cap, state: state(0, 1))
    check(up.tiltX < 0 && up.travel.height < 0 && up.travel.width == 0, "上拨帽顶向屏幕上方倾斜")
    let down = ThumbstickMotion.pose(cap: cap, state: state(0, -1))
    check(down.tiltX > 0 && down.travel.height > 0 && down.travel.width == 0, "下拨帽顶向屏幕下方倾斜")
    check(abs(down.tiltX) <= ThumbstickGeometry.maxDeflection && abs(up.tiltX) <= ThumbstickGeometry.maxDeflection &&
              abs(right.tiltY) <= ThumbstickGeometry.maxDeflection,
          "满量程偏转不超过真实摇杆模块的机械极限（20°），不会把摇杆放倒")
    check(abs(down.travel.height) > abs(up.travel.height) &&
              abs(down.travel.height) < radius && abs(up.travel.height) < radius &&
              abs(right.travel.width) < radius,
          "帽顶行程小于一个帽顶半径，朝使用者一侧略大于远离一侧")

    let diagonal = ThumbstickMotion.pose(cap: cap, state: state(1, 1))
    check(abs(diagonal.tiltX - up.tiltX / sqrt(2)) < 0.000001 && abs(diagonal.tiltY - right.tiltY / sqrt(2)) < 0.000001,
          "斜向输入按圆形量程归一化而不会越界")
    let oversized = ThumbstickMotion.pose(cap: cap, state: state(100, -100))
    check(oversized == ThumbstickMotion.pose(cap: cap, state: state(1, -1)),
          "超量程输入仍钳制在圆形量程内")
    let invalid = ThumbstickMotion.pose(cap: cap, state: state(.nan, .infinity))
    check(invalid == neutral, "非有限输入安全回中")
    let empty = ThumbstickMotion.pose(cap: .zero, state: state(1, 1))
    check(empty.tiltX.isFinite && empty.tiltY.isFinite && empty.travel == .zero && empty.pivot == .zero,
          "非法几何不产生 NaN 或无限姿态")

    guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                  bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        check(false, "透明遮罩测试图可创建")
        return
    }
    let sourcePixels = context.data!.bindMemory(to: UInt8.self, capacity: 64 * 64 * 4)
    for y in 0..<64 {
        for x in 0..<64 {
            let offset = (y * 64 + x) * 4
            let red = x >= 16 && x < 32 && y >= 16 && y < 32
            sourcePixels[offset] = 255
            sourcePixels[offset + 1] = red ? 0 : 255
            sourcePixels[offset + 2] = red ? 0 : 255
            sourcePixels[offset + 3] = 255
        }
    }
    guard let source = context.makeImage(),
          let masked = GamepadArtworkImageSource.imageMaskingStickCaps(
            source, capRegions: [CGRect(x: 16, y: 16, width: 16, height: 16)]) else {
        check(false, "原摇杆区域可透明遮罩")
        return
    }
    guard let data = masked.dataProvider?.data else {
        check(false, "遮罩像素可读取")
        return
    }
    let bytes = [UInt8](data as Data)
    func pixel(_ x: Int, _ y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let offset = (y * 64 + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }
    check(pixel(24, 24).alpha == 0,
          "原摇杆孔位透明，由真实井口填充而非复制邻近像素")
    check(pixel(18, 20).alpha == 0,
          "摇杆帽边缘也移除，不留下静态残影")
    check(pixel(0, 0) == (255, 255, 255, 255), "遮罩不改变手柄其他区域")
    check(pixel(17, 17) == (255, 0, 0, 255), "遮罩之外的原始纹理保持不变")

    let sampledSide = ThumbstickTexture.sideColor(image: source, cap: CGRect(x: 16, y: 16, width: 16, height: 16))
    check(sampledSide != nil, "摇杆侧面可以从原图边缘采样")
    if let color = sampledSide?.usingColorSpace(.deviceRGB) {
        check(abs(color.redComponent - 1) < 0.001 && abs(color.greenComponent) < 0.001 &&
              abs(color.blueComponent) < 0.001,
              "摇杆侧面保留原图边缘颜色而非任意配色，实际 RGB \(color.redComponent)/\(color.greenComponent)/\(color.blueComponent)")
    }
    let strip = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    strip.setFillColor(NSColor.red.cgColor)
    strip.fill(CGRect(x: 16, y: 16, width: 32, height: 32))
    strip.setFillColor(NSColor.blue.cgColor)
    strip.fill(CGRect(x: 16, y: 16, width: 32, height: 4))
    if let stripImage = strip.makeImage(),
       let capSide = ThumbstickTexture.capSideColor(image: stripImage, cap: CGRect(x: 16, y: 16, width: 32, height: 32))?
           .usingColorSpace(.deviceRGB) {
        check(capSide.blueComponent > 0.8 && capSide.redComponent < 0.3,
              "帽顶侧面取下缘最暗条带的颜色，而不是帽顶顶面纹理，实际 RGB \(capSide.redComponent)/\(capSide.greenComponent)/\(capSide.blueComponent)")
    } else {
        check(false, "帽顶侧面颜色可采样")
    }
    let wellRegion = CGRect(x: 8, y: 8, width: 32, height: 32)
    let sampledWell = ThumbstickTexture.wellColor(image: source, well: wellRegion,
                                                  cap: CGRect(x: 16, y: 16, width: 16, height: 16))
    check(sampledWell != nil, "井口内壁颜色可从原生环纹采样")
}
