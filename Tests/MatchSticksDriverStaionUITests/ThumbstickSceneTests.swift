import AppKit
import SceneKit
import DSCore

@MainActor
func thumbstickSceneTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    let resourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/MatchSticksDriverStaion/Resources/Gamepads")
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
        let enlarged = CGSize(width: container.width * 2.5, height: container.height * 2.5)
        let enlargedView = ThumbstickSceneView(frame: CGRect(origin: .zero, size: enlarged))
        if enlargedView.update(spec: spec, region: .leftStick, state: .init(x: 0, yUp: 0, pressed: false),
                                container: enlarged, sourceImage: source),
           let enlargedTop = enlargedView.scene?.rootNode.childNode(withName: "capTop", recursively: true)?
               .geometry?.firstMaterial?.diffuse.contents as! CGImage? {
            check(enlargedTop.width == topTexture.width && enlargedTop.height == topTexture.height,
                  "\(skin.rawValue) 帽顶纹理始终按原图像素裁剪，不随显示尺寸变化（\(enlargedTop.width)x\(enlargedTop.height) 对比 \(topTexture.width)x\(topTexture.height)）")
        } else {
            check(false, "\(skin.rawValue) 放大显示时三维摇杆场景与帽顶纹理可检查")
        }
        let capFrame = spec.region(.leftStickCap, in: container)
        let wellFrame = spec.region(.leftStick, in: container)
        let capRadius = capFrame.width / 2
        let neutralPose = ThumbstickMotion.pose(cap: capFrame, state: .init(x: 0, yUp: 0, pressed: false))
        check(view.cameraPitch > 0 && abs(pivot.eulerAngles.x + view.cameraPitch) < 0.0001 &&
                  pivot.eulerAngles.y == 0 && pivot.eulerAngles.z == 0,
              "\(skin.rawValue) 中立摇杆按参考图视角后仰（顶面朝向使用者），不叠加输入倾斜")
        check(cap.boundingBox.max.z - cap.boundingBox.min.z > 0,
              "\(skin.rawValue) 帽顶具有真实厚度")
        let sideGeometry = scene.rootNode.childNode(withName: "capSide", recursively: true)?
            .childNodes.compactMap { $0.geometry as? SCNCylinder }.first
        check((sideGeometry?.height ?? 0) > 0 && (sideGeometry?.height ?? .infinity) < capRadius * 0.6,
              "\(skin.rawValue) 帽顶侧壁是真实帽顶厚度，而不是整个井口间隙")
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
        if let sourceCap = spec.regions[.leftStickCap],
           let sourceImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let top = luminance(sourceImage, at: CGPoint(x: sourceCap.midX, y: sourceCap.midY)),
           let side = sideColor?.usingColorSpace(.deviceRGB) {
            check(0.299 * side.redComponent + 0.587 * side.greenComponent + 0.114 * side.blueComponent <= top + 0.08,
                  "\(skin.rawValue) 侧面与杆身颜色不亮于帽顶顶面（侧面 \(side.redComponent)/\(side.greenComponent)/\(side.blueComponent)，顶面亮度 \(top)）")
        } else {
            check(false, "\(skin.rawValue) 侧面颜色与帽顶顶面可比较")
        }
        check(abs(pivot.position.x - (neutralPose.pivot.x - container.width / 2)) < 0.0001 &&
                  abs(pivot.position.y - (container.height / 2 - neutralPose.pivot.y)) < 0.0001,
              "\(skin.rawValue) 三维轴心位于帽顶前下方（靠使用者一侧），不在帽顶后方")
        check(wellFrame.contains(neutralPose.pivot) && neutralPose.pivot.y > capFrame.midY,
              "\(skin.rawValue) 轴心落在井口内、帽顶中心之前")
        let shaftGeometry = scene.rootNode.childNode(withName: "shaft", recursively: true)?
            .childNodes.compactMap { $0.geometry as? SCNCylinder }.first
        check((shaftGeometry?.radius ?? 0) > 0 && (shaftGeometry?.radius ?? .infinity) < capRadius * 0.35 &&
                  (shaftGeometry?.height ?? 0) > capRadius * 0.5,
              "\(skin.rawValue) 杆身是细于帽顶的真实立柱")
        for (x, y) in [(Float(1), Float(0)), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)] {
            let pose = ThumbstickMotion.pose(cap: capFrame, state: .init(x: x, yUp: y, pressed: false))
            check(abs(pose.travel.width) <= capRadius && abs(pose.travel.height) <= capRadius,
                  "\(skin.rawValue) 满量程 (\(x), \(y)) 帽顶位移不超过一个帽顶半径")
        }
        let originalPosition = pivot.worldPosition
        let neutralImage = view.snapshot()
        let neutral = renderedBytes(neutralImage)
        check(!neutral.isEmpty && neutral.contains { $0 != 0 }, "\(skin.rawValue) 实际渲染不是空白图")
        if let sourceImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let expected = alphaBounds(sourceImage), let rendered = neutralImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let actual = alphaBounds(rendered) {
            check(abs(expected.minX - actual.minX) <= 1 && abs(expected.minY - actual.minY) <= 1 &&
                      abs(expected.maxX - actual.maxX) <= 1 && abs(expected.maxY - actual.maxY) <= 1,
                  "\(skin.rawValue) 中立渲染轮廓与原图对齐，得到 \(actual)，预期 \(expected)")
        } else {
            check(false, "\(skin.rawValue) 中立渲染轮廓可测量")
        }
        saveReview(neutralImage, skin: skin, state: "neutral")
        check(view.update(spec: spec, region: .leftStick,
                          state: .init(x: 1, yUp: 0, pressed: true),
                          container: container, sourceImage: source),
              "\(skin.rawValue) 右拨场景更新成功")
        check(pivot.worldPosition.x == originalPosition.x &&
                  pivot.worldPosition.y == originalPosition.y && pivot.worldPosition.z == originalPosition.z,
              "\(skin.rawValue) 输入后轴心世界坐标不变")
        check(pivot.eulerAngles.y > 0 && abs(pivot.eulerAngles.x + view.cameraPitch) < 0.0001,
              "\(skin.rawValue) 右拨旋转三维轴心而不是平移贴图")
        let movedImage = view.snapshot()
        let moved = renderedBytes(movedImage)
        check(neutral != moved, "\(skin.rawValue) 三维运动产生真实像素变化")
        saveReview(movedImage, skin: skin, state: "right-pressed")
        check(view.update(spec: spec, region: .leftStick,
                          state: .init(x: 0, yUp: 1, pressed: false),
                          container: container, sourceImage: source),
              "\(skin.rawValue) 上拨场景更新成功")
        check(pivot.eulerAngles.x < -view.cameraPitch && pivot.eulerAngles.y == 0,
              "\(skin.rawValue) 上拨：摇杆进一步背离使用者倾斜，顶面变扁、露出更多前侧壁")
        let upImage = view.snapshot()
        check(neutral != renderedBytes(upImage), "\(skin.rawValue) 上拨产生真实像素变化")
        saveReview(upImage, skin: skin, state: "up")
        check(view.update(spec: spec, region: .leftStick,
                          state: .init(x: 0, yUp: -1, pressed: false),
                          container: container, sourceImage: source),
              "\(skin.rawValue) 下拨场景更新成功")
        check(pivot.eulerAngles.x > -view.cameraPitch && pivot.eulerAngles.y == 0,
              "\(skin.rawValue) 下拨：摇杆向使用者回正，顶面变圆而不是被压成扁盘")
        let downImage = view.snapshot()
        check(neutral != renderedBytes(downImage), "\(skin.rawValue) 下拨产生真实像素变化")
        saveReview(downImage, skin: skin, state: "down")
        for (name, image) in [("右拨", movedImage), ("上拨", upImage), ("下拨", downImage)] {
            if let before = neutralImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let after = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let changed = changedBounds(before, after) {
                let ratio = CGFloat(before.width) / container.width
                let box = CGRect(x: changed.minX / ratio, y: changed.minY / ratio,
                                 width: changed.width / ratio, height: changed.height / ratio)
                check(wellFrame.insetBy(dx: -3, dy: -3).contains(box),
                      "\(skin.rawValue) \(name)只改变井口内的像素，得到 \(box)")
            } else {
                check(false, "\(skin.rawValue) \(name)像素差可测量")
            }
        }
        check(view.update(spec: spec, region: .leftStick,
                          state: .init(x: .nan, yUp: .infinity, pressed: false),
                          container: container, sourceImage: source),
              "\(skin.rawValue) 异常输入场景更新成功")
        check(abs(pivot.eulerAngles.x + view.cameraPitch) < 0.0001 && pivot.eulerAngles.y == 0,
              "\(skin.rawValue) 异常输入回到中立姿态")
        check(view.update(spec: spec, region: .rightStick,
                          state: .init(x: -1, yUp: 0, pressed: false),
                          container: container, sourceImage: source),
              "\(skin.rawValue) 右摇杆也能独立创建三维装配")
        check(view.scene?.rootNode.childNode(withName: "pivot", recursively: true)?.worldPosition.x != originalPosition.x,
              "\(skin.rawValue) 左右摇杆使用各自标定轴心")
        saveReview(view.snapshot(), skin: skin, state: "right-stick-left")
    }
    stripedCapTests(check)
}

@MainActor
private func stripedCapTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    guard let context = CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 96 * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        check(false, "条纹帽顶测试图可创建")
        return
    }
    context.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
    // Image rows 24-31 white, 32-39 black, 40-47 white, 48-55 black; CoreGraphics rows run bottom-up.
    for (row, white) in [(24, true), (32, false), (40, true), (48, false)] {
        context.setFillColor(NSColor(white: white ? 1 : 0, alpha: 1).cgColor)
        context.fill(CGRect(x: 24, y: 96 - row - 8, width: 48, height: 8))
    }
    guard let cgImage = context.makeImage() else {
        check(false, "条纹帽顶测试图可导出")
        return
    }
    let spec = GamepadArtworkSpec(
        imageName: "striped", referenceSize: CGSize(width: 96, height: 96),
        regions: [.leftStick: CGRect(x: 12, y: 12, width: 72, height: 72),
                  .leftStickCap: CGRect(x: 24, y: 24, width: 48, height: 48)])
    let source = NSImage(cgImage: cgImage, size: CGSize(width: 96, height: 96))
    for scale in [1, 3] {
        let container = CGSize(width: 96 * scale, height: 96 * scale)
        let view = ThumbstickSceneView(frame: CGRect(origin: .zero, size: container))
        guard view.update(spec: spec, region: .leftStick, state: .init(x: 0, yUp: 0, pressed: false),
                          container: container, sourceImage: source),
              let rendered = view.snapshot().cgImage(forProposedRect: nil, context: nil, hints: nil),
              let bytes = rgbaBytes(rendered), rendered.width == 96 * scale else {
            check(false, "\(scale)x 显示时条纹帽顶可按原始像素渲染")
            continue
        }
        func brightness(_ imageX: Int, _ imageY: Int) -> CGFloat? {
            let x = imageX * scale, y = imageY * scale
            guard x >= 0, x < rendered.width, y >= 0, y < rendered.height else { return nil }
            let offset = (y * rendered.width + x) * 4
            return (CGFloat(bytes[offset]) + CGFloat(bytes[offset + 1]) + CGFloat(bytes[offset + 2])) / 765
        }
        let rows = [27, 36, 44, 52].map { brightness(48, $0) }
        check(rows.count == 4 && rows[0].map({ $0 > 0.8 }) == true && rows[1].map({ $0 < 0.2 }) == true &&
                  rows[2].map({ $0 > 0.8 }) == true && rows[3].map({ $0 < 0.2 }) == true,
              "\(scale)x 显示时帽顶顶面正立贴图（上缘白、其下黑、再下白、近前缘黑），实际 \(rows.map { $0.map { Int(($0 * 100).rounded()) } ?? -1 })")
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

/// Bounding box (in pixel coordinates, origin top-left) of every pixel that differs
/// between two same-sized images.
private func changedBounds(_ before: CGImage, _ after: CGImage) -> CGRect? {
    guard before.width == after.width, before.height == after.height,
          let first = rgbaBytes(before), let second = rgbaBytes(after) else { return nil }
    var minX = before.width, minY = before.height, maxX = -1, maxY = -1
    for y in 0..<before.height {
        for x in 0..<before.width {
            let offset = (y * before.width + x) * 4
            guard first[offset] != second[offset] || first[offset + 1] != second[offset + 1] ||
                  first[offset + 2] != second[offset + 2] || first[offset + 3] != second[offset + 3] else { continue }
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

private func luminance(_ image: CGImage, at point: CGPoint) -> CGFloat? {
    guard let bytes = rgbaBytes(image), image.width > 0, image.height > 0 else { return nil }
    let x = min(image.width - 1, max(0, Int(point.x))), y = min(image.height - 1, max(0, Int(point.y)))
    let offset = (y * image.width + x) * 4
    return (0.299 * CGFloat(bytes[offset]) + 0.587 * CGFloat(bytes[offset + 1]) + 0.114 * CGFloat(bytes[offset + 2])) / 255
}

private func rgbaBytes(_ image: CGImage) -> [UInt8]? {
    guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return [UInt8](Data(bytes: context.data!, count: image.width * image.height * 4))
}

@MainActor
private func saveReview(_ image: NSImage, skin: GamepadSkin, state: String) {
    guard skin != .generic, let directory = ProcessInfo.processInfo.environment["MATCHSTICKS_DRIVER_STAION_RENDER_REVIEW"],
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
