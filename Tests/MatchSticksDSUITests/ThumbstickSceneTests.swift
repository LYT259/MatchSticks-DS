import AppKit
import SceneKit
import DSCore

@MainActor
func thumbstickSceneTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    let resourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/MatchSticksDS/Resources/Gamepads")
    for skin in [GamepadSkin.f310, .generic, .direwolf4, .dualshock4, .dualsense, .xboxSeries] {
        let spec = GamepadArtworkCatalog.spec(for: skin)
        guard let source = NSImage(contentsOf: resourceRoot.appendingPathComponent("\(spec.imageName).png")) else {
            check(false, "\(skin.rawValue) 三维摇杆测试图可读取")
            continue
        }
        let container = spec.referenceSize
        let view = ThumbstickSceneView(frame: CGRect(origin: .zero, size: container))
        check(view.update(spec: spec, region: .leftStick,
                          state: .init(x: 0, yUp: 0, pressed: false),
                          container: container, sourceImage: source),
              "\(skin.rawValue) 三维摇杆场景创建成功")
        guard let scene = view.scene else {
            check(false, "\(skin.rawValue) 场景存在")
            continue
        }
        for name in ["pivot", "well", "shaft", "cap", "capTop", "capSide", "pressedRing"] {
            check(scene.rootNode.childNode(withName: name, recursively: true) != nil,
                  "\(skin.rawValue) 具有真实 \(name) 节点")
        }
        guard let pivot = scene.rootNode.childNode(withName: "pivot", recursively: true),
              let cap = scene.rootNode.childNode(withName: "cap", recursively: true),
              let capTop = scene.rootNode.childNode(withName: "capTop", recursively: true),
              let body = scene.rootNode.childNode(withName: "body", recursively: true),
              let wellSurface = scene.rootNode.childNode(withName: "wellSurface", recursively: true) else {
            check(false, "\(skin.rawValue) 必要三维节点完整")
            continue
        }
        check(view.pointOfView?.camera?.usesOrthographicProjection == true,
              "\(skin.rawValue) 使用标定尺寸的正交投影")
        let bodyTexture = body.geometry?.firstMaterial?.diffuse.contents as! CGImage
        let wellTexture = wellSurface.geometry?.firstMaterial?.diffuse.contents as! CGImage
        if skin == .f310 {
            saveReview(NSImage(cgImage: wellTexture, size: NSSize(width: wellTexture.width, height: wellTexture.height)), skin: skin, state: "well-texture")
        }
        if let well = spec.regions[.leftStick], let cap = spec.regions[.leftStickCap] {
            check(alpha(bodyTexture, at: CGPoint(x: well.midX, y: well.midY)) == 0,
                  "\(skin.rawValue) 主体不再保留静态摇杆或井口")
            check(alpha(bodyTexture, at: .zero) == 0, "\(skin.rawValue) 主体外边缘保持透明")
            check(alpha(wellTexture, at: CGPoint(x: cap.midX - well.minX, y: cap.midY - well.minY)) == 0,
                  "\(skin.rawValue) 井口只保留原生环纹，没有第二帽顶")
        } else {
            check(false, "\(skin.rawValue) 主体与井口纹理可检查")
        }
        check(capTop.geometry?.sources.contains { $0.semantic == .texcoord } == true,
              "\(skin.rawValue) 帽顶使用原图 UV 纹理而非纯色贴片")
        let topTexture = capTop.geometry?.firstMaterial?.diffuse.contents as! CGImage
        if skin == .f310 {
            saveReview(NSImage(cgImage: topTexture, size: NSSize(width: topTexture.width, height: topTexture.height)), skin: skin, state: "cap-top-texture")
        }
        check(CGFloat(topTexture.height) < spec.regions[.leftStickCap]!.height,
              "\(skin.rawValue) 三维帽顶纹理不包含原图的侧面")
        check(view.basePitch > 0 && abs(pivot.eulerAngles.x - view.basePitch) < 0.0001 && pivot.eulerAngles.y == 0,
              "\(skin.rawValue) 中立帽顶保留参考图倾角而非额外输入倾斜")
        check(cap.boundingBox.max.z - cap.boundingBox.min.z > 0,
              "\(skin.rawValue) 帽顶具有真实厚度")
        let travel = (spec.region(.leftStick, in: container).width -
                      spec.region(.leftStickCap, in: container).width) / 2
        let sideGeometry = scene.rootNode.childNode(withName: "capSide", recursively: true)?
            .childNodes.compactMap { $0.geometry as? SCNCylinder }.first
        check((sideGeometry?.height ?? .infinity) < travel,
              "\(skin.rawValue) 帽顶侧壁厚度来自标定比例而不是整个井口间隙")
        let sideMaterials = scene.rootNode.childNode(withName: "capSide", recursively: true)?
            .childNodes.first?.geometry?.materials
        check(sideMaterials?.count == 3 && sideMaterials?[1].writesToDepthBuffer == false &&
              sideMaterials?[2].writesToDepthBuffer == false,
              "\(skin.rawValue) 圆柱顶盖不与纹理顶面争夺深度")
        let sideColor = scene.rootNode.childNode(withName: "capSide", recursively: true)?
            .childNodes.first?.geometry?.firstMaterial?.diffuse.contents as? NSColor
        let shaftColor = scene.rootNode.childNode(withName: "shaft", recursively: true)?
            .childNodes.first?.geometry?.firstMaterial?.diffuse.contents as? NSColor
        check(sideColor != nil && shaftColor != nil,
              "\(skin.rawValue) 侧面与杆身使用边缘采样材质，不包裹放射状图片")
        check(abs(pivot.eulerAngles.x - view.basePitch) < 0.0001 && pivot.eulerAngles.y == 0 && pivot.eulerAngles.z == 0,
              "\(skin.rawValue) 中立姿态无倾斜")
        let originalPosition = pivot.worldPosition
        let neutral = renderedBytes(view.snapshot())
        check(!neutral.isEmpty && neutral.contains { $0 != 0 }, "\(skin.rawValue) 实际渲染不是空白图")
        if let sourceImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let expected = alphaBounds(sourceImage), let rendered = view.snapshot().cgImage(forProposedRect: nil, context: nil, hints: nil),
           let actual = alphaBounds(rendered) {
            check(abs(expected.minX - actual.minX) <= 1 && abs(expected.minY - actual.minY) <= 1 &&
                  abs(expected.maxX - actual.maxX) <= 1 && abs(expected.maxY - actual.maxY) <= 1,
                  "\(skin.rawValue) 中立渲染轮廓与原图对齐，得到 \(actual)，预期 \(expected)")
        } else {
            check(false, "\(skin.rawValue) 中立渲染轮廓可测量")
        }
        saveReview(view.snapshot(), skin: skin, state: "neutral")
        check(view.update(spec: spec, region: .leftStick,
                          state: .init(x: 1, yUp: 0, pressed: true),
                          container: container, sourceImage: source),
              "\(skin.rawValue) 右拨场景更新成功")
        check(pivot.worldPosition.x == originalPosition.x &&
              pivot.worldPosition.y == originalPosition.y && pivot.worldPosition.z == originalPosition.z,
              "\(skin.rawValue) 输入后轴心世界坐标不变")
        check(pivot.eulerAngles.y > 0 && abs(pivot.eulerAngles.x - view.basePitch) < 0.0001,
              "\(skin.rawValue) 右拨旋转三维轴心而不是平移贴图")
        let moved = renderedBytes(view.snapshot())
        check(neutral != moved, "\(skin.rawValue) 三维运动产生真实像素变化")
        saveReview(view.snapshot(), skin: skin, state: "right-pressed")
        check(view.update(spec: spec, region: .leftStick,
                          state: .init(x: 0, yUp: 1, pressed: false),
                          container: container, sourceImage: source),
              "\(skin.rawValue) 上拨场景更新成功")
        check(pivot.eulerAngles.x < view.basePitch && pivot.eulerAngles.y == 0,
              "\(skin.rawValue) 上拨方向与物理方向一致")
        check(view.update(spec: spec, region: .leftStick,
                          state: .init(x: .nan, yUp: .infinity, pressed: false),
                          container: container, sourceImage: source),
              "\(skin.rawValue) 异常输入场景更新成功")
        check(abs(pivot.eulerAngles.x - view.basePitch) < 0.0001 && pivot.eulerAngles.y == 0,
              "\(skin.rawValue) 异常输入回到中立姿态")
        check(view.update(spec: spec, region: .rightStick,
                          state: .init(x: -1, yUp: 0, pressed: false),
                          container: container, sourceImage: source),
              "\(skin.rawValue) 右摇杆也能独立创建三维装配")
        check(view.scene?.rootNode.childNode(withName: "pivot", recursively: true)?.worldPosition.x != originalPosition.x,
              "\(skin.rawValue) 左右摇杆使用各自标定轴心")
        saveReview(view.snapshot(), skin: skin, state: "right-stick-left")
    }
}

private func alpha(_ image: CGImage, at point: CGPoint) -> UInt8? {
    guard point.x >= 0, point.y >= 0, Int(point.x) < image.width, Int(point.y) < image.height,
          let data = image.dataProvider?.data else { return nil }
    let bytes = [UInt8](data as Data)
    return bytes[Int(point.y) * image.bytesPerRow + Int(point.x) * 4 + 3]
}

private func alphaBounds(_ image: CGImage) -> CGRect? {
    guard let data = image.dataProvider?.data else { return nil }
    let bytes = [UInt8](data as Data)
    var minX = image.width, minY = image.height, maxX = -1, maxY = -1
    for y in 0..<image.height {
        for x in 0..<image.width where bytes[y * image.bytesPerRow + x * 4 + 3] != 0 {
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

@MainActor
private func saveReview(_ image: NSImage, skin: GamepadSkin, state: String) {
    guard skin != .generic, let directory = ProcessInfo.processInfo.environment["MATCHSTICKS_DS_RENDER_REVIEW"],
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return }
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try? data.write(to: root.appendingPathComponent("\(skin.rawValue)-\(state).png"))
}

@MainActor
private func renderedBytes(_ image: NSImage) -> [UInt8] {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let data = cgImage.dataProvider?.data else { return [] }
    return [UInt8](data as Data)
}
