import AppKit
import SceneKit
import DSCore

@MainActor
func flightStickSceneTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    let spec = GamepadArtworkCatalog.spec(for: .extreme3DPro)
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let overlay = (try? String(contentsOf: root.appendingPathComponent(
        "Sources/MatchSticksDriverStaion/Views/GamepadArtwork/GamepadArtworkOverlay.swift"), encoding: .utf8)) ?? ""
    let artwork = (try? String(contentsOf: root.appendingPathComponent(
        "Sources/MatchSticksDriverStaion/Views/GamepadArtwork/GamepadArtwork.swift"), encoding: .utf8)) ?? ""
    check(overlay.contains("FlightStickScene("), "Extreme 正式布局使用三维装配")
    check(!overlay.contains("rotation3DEffect") && !overlay.contains("rotationEffect") &&
          !overlay.contains("offset(pose.offset)") && !artwork.contains("flightAnchor") &&
          !artwork.contains("let offset: CGSize"),
          "Extreme 不再使用整图旋转、图片平移或旧锚点")
    check(spec.flightPivot == CGPoint(x: 765.5, y: 710),
          "Extreme 球关节使用原图座圈等宽轮廓标定的固定中心")
    let view = FlightStickSceneView(frame: CGRect(origin: .zero, size: spec.referenceSize))
    check(view.update(spec: spec, state: .neutral, container: spec.referenceSize),
          "Extreme 三维装配可创建")
    guard let scene = view.scene else {
        check(false, "Extreme 场景存在")
        return
    }
    for name in ["base", "baseSurface", "socket", "pivot", "shaft", "twist", "handle"] {
        check(scene.rootNode.childNode(withName: name, recursively: true) != nil,
              "Extreme 具有独立 \(name) 部件")
    }
    guard let base = scene.rootNode.childNode(withName: "base", recursively: true),
          let socket = scene.rootNode.childNode(withName: "socket", recursively: true),
          let pivot = scene.rootNode.childNode(withName: "pivot", recursively: true),
          let handle = scene.rootNode.childNode(withName: "handle", recursively: true),
          let twist = scene.rootNode.childNode(withName: "twist", recursively: true) else { return }
    check(view.handleDepth == 105 && handle.geometry!.boundingBox.max.z - handle.geometry!.boundingBox.min.z > 0,
          "Extreme 手柄使用原图颈部直径作为真实几何厚度")
    check(handle.childNodes.contains { $0.geometry != nil },
          "Extreme 手柄具有真实侧壁和倒角而不是一张平面")
    check(handle.geometry?.sources.contains { $0.semantic == .texcoord } == true,
          "Extreme 立体表面保留原厂纹理 UV")
    let basePosition = base.worldPosition
    let socketPosition = socket.worldPosition
    let pivotPosition = pivot.worldPosition
    let neutral = view.snapshot()
    var state = GamepadElementState.neutral
    state.leftStick = GamepadStickState(x: 1, yUp: 0, pressed: false)
    state.face[.north] = true
    state.dpad.insert(.up)
    state.triggerR = GamepadTriggerState(pressed: true, depth: 0.65)
    check(view.update(spec: spec, state: state, container: spec.referenceSize),
          "Extreme 右倾与按钮状态可更新")
    check(abs(pivot.eulerAngles.y - 7 * CGFloat.pi / 180) < 0.0001,
          "Extreme 右倾是真实球关节旋转")
    check(base.worldPosition.x == basePosition.x && base.worldPosition.y == basePosition.y &&
          base.worldPosition.z == basePosition.z && socket.worldPosition.x == socketPosition.x &&
          socket.worldPosition.y == socketPosition.y && socket.worldPosition.z == socketPosition.z,
          "Extreme 底座和座圈不随手柄移动")
    check(pivot.worldPosition.x == pivotPosition.x && pivot.worldPosition.y == pivotPosition.y &&
          pivot.worldPosition.z == pivotPosition.z, "Extreme 球关节位置固定")
    check(scene.rootNode.childNode(withName: "highlight-facenorth", recursively: true)?.isHidden == false &&
          scene.rootNode.childNode(withName: "highlight-faceeast", recursively: true)?.isHidden == true,
          "Extreme 按钮高亮附着于真实手柄节点并只在按下时显示")
    check(scene.rootNode.childNode(withName: "highlight-dpadup", recursively: true)?.isHidden == false,
          "Extreme 方向键高亮附着在真实手柄上")
    if let throttle = scene.rootNode.childNode(withName: "highlight-depth-triggerR", recursively: true) {
        check(!throttle.isHidden && abs(throttle.scale.y - 0.65) < 0.0001,
              "Extreme 油门按真实行程显示深度")
    } else {
        check(false, "Extreme 油门深度节点存在")
    }
    check(scene.rootNode.childNode(withName: "highlight-shoulderL", recursively: true)?.isHidden == true,
          "Extreme 未按下的肩键不会错误高亮")
    let movingAccessibilityFrame = view.accessibilityControls[.faceNorth]?.frame
    let fixedAccessibilityFrame = view.accessibilityControls[.back]?.frame
    check(view.accessibilityControls[.faceNorth]?.toolTip?.isEmpty == false &&
          view.accessibilityControls[.back]?.toolTip?.isEmpty == false &&
          view.accessibilityControls[.faceNorth]?.isAccessibilityElement() == true,
          "Extreme 三维按钮保留可访问性标签和悬停提示")
    saveFlightReview(view.snapshot(), name: "right")
    state.leftStick = GamepadStickState(x: 0, yUp: 1, pressed: false)
    check(view.update(spec: spec, state: state, container: spec.referenceSize),
          "Extreme 前倾可更新")
    check(abs(pivot.eulerAngles.x - 7 * CGFloat.pi / 180) < 0.0001,
          "Extreme 前倾保持既有输入幅度")
    check(view.accessibilityControls[.faceNorth]?.frame != movingAccessibilityFrame &&
          view.accessibilityControls[.back]?.frame == fixedAccessibilityFrame,
          "Extreme 可访问性区域跟随真实手柄运动而固定底座不移动")
    saveFlightReview(view.snapshot(), name: "forward")
    state.leftStick = .init(x: -1, yUp: 0, pressed: false)
    check(view.update(spec: spec, state: state, container: spec.referenceSize) && pivot.eulerAngles.y < 0,
          "Extreme 左倾方向与右倾相反")
    saveFlightReview(view.snapshot(), name: "left")
    state.leftStick = .init(x: 0, yUp: -1, pressed: false)
    check(view.update(spec: spec, state: state, container: spec.referenceSize) && pivot.eulerAngles.x < 0,
          "Extreme 后倾方向与前倾相反")
    saveFlightReview(view.snapshot(), name: "back")
    state.leftStick = .init(x: 0, yUp: 0, pressed: false)
    state.rightStick = .init(x: 1, yUp: 0, pressed: false)
    check(view.update(spec: spec, state: state, container: spec.referenceSize),
          "Extreme 扭转可更新")
    check(abs(twist.eulerAngles.z + 16 * CGFloat.pi / 180) < 0.0001,
          "Extreme Z 轴仅扭转手柄并保留屏幕方向")
    check(neutral.cgImage(forProposedRect: nil, context: nil, hints: nil)?.dataProvider?.data !=
          view.snapshot().cgImage(forProposedRect: nil, context: nil, hints: nil)?.dataProvider?.data,
          "Extreme 三维扭转产生真实像素变化")
    saveFlightReview(view.snapshot(), name: "twist")
    check(view.update(spec: spec, state: .neutral, container: spec.referenceSize),
          "Extreme 回中可更新")
    check(pivot.eulerAngles.x == 0 && pivot.eulerAngles.y == 0 && twist.eulerAngles.z == 0,
          "Extreme 中立姿态真实回中")
    saveFlightReview(view.snapshot(), name: "neutral")
}

@MainActor
private func saveFlightReview(_ image: NSImage, name: String) {
    guard let directory = ProcessInfo.processInfo.environment["MATCHSTICKS_DRIVER_STAION_RENDER_REVIEW"],
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try? data.write(to: root.appendingPathComponent("flight-\(name).png"))
}
