import AppKit
import DSCore

func thumbstickMotionTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    let well = CGRect(x: 100, y: 80, width: 160, height: 150)
    let cap = CGRect(x: 120, y: 95, width: 120, height: 110)
    func state(_ x: Float, _ y: Float) -> GamepadStickState {
        GamepadStickState(x: x, yUp: y, pressed: false)
    }
    let neutral = ThumbstickMotion.pose(well: well, cap: cap, state: state(0, 0))
    check(neutral.pivot == CGPoint(x: 180, y: 155) && neutral.tiltX == 0 && neutral.tiltY == 0,
          "三维摇杆中立时轴心固定在井口且不倾斜")
    check(neutral.capSize == cap.size && neutral.travel == .zero, "中立帽顶尺寸来自标定且无位移")

    let right = ThumbstickMotion.pose(well: well, cap: cap, state: state(1, 0))
    check(right.pivot == neutral.pivot && right.tiltY > 0 && right.tiltX == 0,
          "右拨绕井口 Y 轴倾斜而非平移贴图")
    check(abs(right.travel.width - 20) < 0.0001 && right.travel.height == 0,
          "右拨投影位移受井帽差值约束")

    let left = ThumbstickMotion.pose(well: well, cap: cap, state: state(-1, 0))
    check(left.tiltY < 0 && left.travel.width == -20, "左拨方向与右拨相反")
    let up = ThumbstickMotion.pose(well: well, cap: cap, state: state(0, 1))
    check(up.tiltX < 0 && up.travel.height == -20, "上拨朝屏幕上方倾斜")
    let down = ThumbstickMotion.pose(well: well, cap: cap, state: state(0, -1))
    check(down.tiltX > 0 && down.travel.height == 20, "下拨朝屏幕下方倾斜")

    let diagonal = ThumbstickMotion.pose(well: well, cap: cap, state: state(1, 1))
    check(abs(diagonal.travel.width - 20 / sqrt(2)) < 0.0001 &&
          abs(diagonal.travel.height + 20 / sqrt(2)) < 0.0001,
          "斜向输入受圆形井口约束而不会越界")
    let oversized = ThumbstickMotion.pose(well: well, cap: cap, state: state(100, -100))
    check(abs(oversized.travel.width - 20 / sqrt(2)) < 0.0001 &&
          abs(oversized.travel.height - 20 / sqrt(2)) < 0.0001,
          "超量程输入仍钳制在井口内")
    let invalid = ThumbstickMotion.pose(well: well, cap: cap, state: state(.nan, .infinity))
    check(invalid == neutral, "非有限输入安全回中")
    let empty = ThumbstickMotion.pose(well: .zero, cap: .zero, state: state(1, 1))
    check(empty.tiltX.isFinite && empty.tiltY.isFinite && empty.travel == .zero,
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
    let wellRegion = CGRect(x: 8, y: 8, width: 32, height: 32)
    let sampledWell = ThumbstickTexture.wellColor(image: source, well: wellRegion,
                                                  cap: CGRect(x: 16, y: 16, width: 16, height: 16))
    check(sampledWell != nil, "井口内壁颜色可从原生环纹采样")
}
