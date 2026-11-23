import SwiftUI
import SceneKit
import DSCore

struct FlightStickScene: NSViewRepresentable {
    let spec: GamepadArtworkSpec
    let state: GamepadElementState
    let container: CGSize

    func makeNSView(context: Context) -> FlightStickSceneView {
        let view = FlightStickSceneView(frame: CGRect(origin: .zero, size: container))
        _ = view.update(spec: spec, state: state, container: container)
        return view
    }

    func updateNSView(_ view: FlightStickSceneView, context: Context) {
        _ = view.update(spec: spec, state: state, container: container)
    }
}

final class FlightStickSceneView: SCNView {
    private var configuration = ""
    private(set) var handleDepth: CGFloat = 0
    private(set) var errorDescription: String?

    override init(frame frameRect: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frameRect, options: options)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    private func configureView() {
        wantsLayer = true
        layer?.isOpaque = false
        backgroundColor = .clear
        allowsCameraControl = false
        autoenablesDefaultLighting = false
        rendersContinuously = false
        isPlaying = false
    }

    @discardableResult
    func update(spec: GamepadArtworkSpec, state: GamepadElementState, container: CGSize) -> Bool {
        guard container.width > 0, container.height > 0, spec.flightPivot != nil else {
            report("飞行摇杆缺少标定枢轴")
            return false
        }
        let key = "\(spec.imageName):\(container.width)x\(container.height)"
        if configuration != key {
            guard buildScene(spec: spec, container: container) else {
                report("无法创建飞行摇杆三维装配")
                return false
            }
            configuration = key
        }
        let pose = spec.flightPose(left: state.leftStick, twist: state.rightStick, in: container)
        node("pivot")?.eulerAngles = SCNVector3(pose.pitch * .pi / 180, pose.roll * .pi / 180, 0)
        node("twist")?.eulerAngles = SCNVector3(0, 0, -pose.twist * .pi / 180)
        updateHighlights(spec: spec, state: state)
        errorDescription = nil
        setNeedsDisplay(bounds)
        return true
    }

    private func buildScene(spec: GamepadArtworkSpec, container: CGSize) -> Bool {
        guard let pivot = spec.flightPivot,
              let base = image(spec.imageName), let handleName = spec.movingImageName,
              let handle = image(handleName),
              let cleaned = ArtworkContour.cleanedBase(image: base, handle: handle, pivot: pivot) else { return false }
        let gripBounds = ArtworkContour.paths(image: handle).reduce(CGRect.null) { $0.union($1.bounds) }
        guard !gripBounds.isNull, let gripColor = ThumbstickTexture.sideColor(image: handle, cap: gripBounds) else { return false }
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = container.height / 2
        camera.zNear = 0.01
        camera.zFar = max(container.width, container.height) * 10
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, max(container.width, container.height) * 2)
        scene.rootNode.addChildNode(cameraNode)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 700
        scene.rootNode.addChildNode(ambient)
        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .directional
        light.light?.intensity = 400
        light.light?.castsShadow = true
        light.position = SCNVector3(-container.width / 3, container.height / 3, max(container.width, container.height))
        light.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(light)
        let scale = min(container.width / spec.referenceSize.width, container.height / spec.referenceSize.height)
        let world = SCNNode()
        world.scale = SCNVector3(scale, scale, scale)
        scene.rootNode.addChildNode(world)
        let width = spec.referenceSize.width, height = spec.referenceSize.height
        let socketDiameter = 239.0, neckDiameter = 105.0
        let baseDepth = socketDiameter / 4

        let baseNode = SCNNode()
        baseNode.name = "base"
        world.addChildNode(baseNode)
        guard let baseShape = solid(image: cleaned, depth: baseDepth, chamfer: baseDepth / 4,
                                    offset: CGPoint(x: -width / 2, y: height / 2),
                                    uv: { CGPoint(x: $0.x / width + 0.5, y: 0.5 - $0.y / height) },
                                    sideColor: gripColor, frontZ: baseDepth) else { return false }
        baseShape.name = "baseSurface"
        baseNode.addChildNode(baseShape)

        let socketMaterial = SCNMaterial()
        socketMaterial.lightingModel = .lambert
        socketMaterial.diffuse.contents = gripColor
        let socket = SCNNode(geometry: SCNCylinder(radius: socketDiameter / 2, height: baseDepth))
        socket.name = "socket"
        socket.rotation = SCNVector4(1, 0, 0, CGFloat.pi / 2)
        socket.position = SCNVector3(pivot.x - width / 2, height / 2 - pivot.y, baseDepth)
        socket.geometry?.materials = [socketMaterial]
        world.addChildNode(socket)

        let pivotNode = SCNNode()
        pivotNode.name = "pivot"
        pivotNode.position = SCNVector3(pivot.x - width / 2, height / 2 - pivot.y,
                                        baseDepth * 1.5 + neckDiameter / 2)
        world.addChildNode(pivotNode)
        let ball = SCNNode(geometry: SCNSphere(radius: neckDiameter / 2))
        ball.name = "ball"
        ball.geometry?.materials = [socketMaterial]
        pivotNode.addChildNode(ball)
        let shaft = SCNNode(geometry: SCNCylinder(radius: neckDiameter / 4, height: neckDiameter))
        shaft.name = "shaft"
        shaft.rotation = SCNVector4(1, 0, 0, CGFloat.pi / 2)
        shaft.position.z = -neckDiameter / 2
        shaft.geometry?.materials = [socketMaterial]
        pivotNode.addChildNode(shaft)

        let twist = SCNNode()
        twist.name = "twist"
        pivotNode.addChildNode(twist)
        guard let handleNode = solid(image: handle, depth: neckDiameter, chamfer: neckDiameter / 8,
                                     offset: CGPoint(x: -pivot.x, y: pivot.y),
                                     uv: { CGPoint(x: ($0.x + pivot.x) / width, y: (pivot.y - $0.y) / height) },
                                     sideColor: gripColor, frontZ: 0) else { return false }
        handleNode.name = "handle"
        handleDepth = neckDiameter
        twist.addChildNode(handleNode)
        addHighlights(spec: spec, width: width, height: height, pivot: pivot,
                      base: baseNode, handle: twist, baseDepth: baseDepth)
        self.scene = scene
        self.pointOfView = cameraNode
        return true
    }

    private func image(_ name: String) -> CGImage? {
        GamepadArtworkImageSource.image(named: name)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func solid(image: CGImage, depth: CGFloat, chamfer: CGFloat, offset: CGPoint,
                       uv: @escaping (SCNVector3) -> CGPoint, sideColor: NSColor, frontZ: CGFloat) -> SCNNode? {
        RasterMesh.node(image: image, depth: depth, chamfer: min(chamfer, depth / 3),
                        offset: offset, uv: uv, sideColor: sideColor, frontZ: frontZ)
    }

    private func addHighlights(spec: GamepadArtworkSpec, width: CGFloat, height: CGFloat,
                               pivot: CGPoint, base: SCNNode, handle: SCNNode, baseDepth: CGFloat) {
        for face in GamepadFace.allCases {
            let region: GamepadArtworkRegion
            switch face {
            case .north: region = .faceNorth
            case .east: region = .faceEast
            case .south: region = .faceSouth
            case .west: region = .faceWest
            }
            if let rect = spec.regions[region] {
                addHighlight(name: "face\(face.rawValue)", rect: rect, parent: handle,
                             point: { CGPoint(x: $0.x - pivot.x, y: pivot.y - $0.y) }, z: 0.5, ellipse: true)
            }
        }
        for (region, name) in [(GamepadArtworkRegion.triggerL, "triggerL"), (.triggerR, "triggerR")] {
            if let rect = spec.regions[region] {
                let moving = region == .triggerL
                addHighlight(name: "depth-\(name)", rect: rect, parent: moving ? handle : base,
                             point: moving ? { CGPoint(x: $0.x - pivot.x, y: pivot.y - $0.y) } :
                                { CGPoint(x: $0.x - width / 2, y: height / 2 - $0.y) },
                             z: moving ? 0.5 : baseDepth + 0.5, ellipse: false)
            }
        }
        for (region, name) in [(GamepadArtworkRegion.shoulderL, "shoulderL"), (.shoulderR, "shoulderR"),
                               (.back, "back"), (.start, "start"), (.guide, "guide"),
                               (.share, "share"), (.backR, "backR")] {
            if let rect = spec.regions[region] {
                addHighlight(name: name, rect: rect, parent: base,
                             point: { CGPoint(x: $0.x - width / 2, y: height / 2 - $0.y) },
                             z: baseDepth + 0.5, ellipse: false)
            }
        }
    }

    private func addHighlight(name: String, rect: CGRect, parent: SCNNode,
                              point: @escaping (CGPoint) -> CGPoint, z: CGFloat, ellipse: Bool) {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = highlightImage(ellipse: ellipse)
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        let node = SCNNode(geometry: SCNPlane(width: rect.width, height: rect.height))
        node.name = "highlight-\(name)"
        let center = point(CGPoint(x: rect.midX, y: rect.midY))
        node.position = SCNVector3(center.x, center.y, z)
        node.geometry?.materials = [material]
        parent.addChildNode(node)
    }

    private func updateHighlights(spec: GamepadArtworkSpec, state: GamepadElementState) {
        for face in GamepadFace.allCases {
            node("highlight-face\(face.rawValue)")?.isHidden = !(state.face[face] ?? false)
        }
        for (name, pressed) in ["shoulderL": state.shoulderL, "shoulderR": state.shoulderR,
                                "back": state.back, "start": state.start, "guide": state.guide,
                                "share": state.extras[.share] ?? false, "backR": state.extras[.backR] ?? false] {
            node("highlight-\(name)")?.isHidden = !pressed
        }
        if let rect = spec.regions[.triggerL] {
            updateDepth(node: "highlight-depth-triggerL", rect: rect,
                        depth: state.triggerL.depth ?? (state.triggerL.pressed ? 1 : 0),
                        baseY: rect.maxY, point: { CGPoint(x: $0.x - spec.flightPivot!.x, y: spec.flightPivot!.y - $0.y) })
        }
        if let rect = spec.regions[.triggerR] {
            updateDepth(node: "highlight-depth-triggerR", rect: rect,
                        depth: state.triggerR.depth ?? (state.triggerR.pressed ? 1 : 0),
                        baseY: rect.maxY, point: { CGPoint(x: $0.x - spec.referenceSize.width / 2,
                                                           y: spec.referenceSize.height / 2 - $0.y) })
        }
    }

    private func updateDepth(node name: String, rect: CGRect, depth: Float,
                             baseY: CGFloat, point: (CGPoint) -> CGPoint) {
        let amount = CGFloat(min(1, max(0, depth.isFinite ? depth : 0)))
        guard let node = node(name) else { return }
        node.isHidden = amount <= 0
        node.scale.y = amount
        node.position.y = point(CGPoint(x: rect.midX, y: baseY)).y - rect.height * amount / 2
    }

    private func highlightImage(ellipse: Bool) -> CGImage? {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                      bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let color = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
        context.setFillColor(color)
        if ellipse {
            context.fillEllipse(in: CGRect(x: 3, y: 3, width: 58, height: 58))
        } else {
            let path = NSBezierPath(roundedRect: NSRect(x: 3, y: 3, width: 58, height: 58), xRadius: 8, yRadius: 8)
            context.addPath(path.cgPath)
            context.fillPath()
        }
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(3)
        if ellipse {
            context.strokeEllipse(in: CGRect(x: 3, y: 3, width: 58, height: 58))
        } else {
            let path = NSBezierPath(roundedRect: NSRect(x: 3, y: 3, width: 58, height: 58), xRadius: 8, yRadius: 8)
            context.addPath(path.cgPath)
            context.strokePath()
        }
        return context.makeImage()
    }

    private func node(_ name: String) -> SCNNode? {
        scene?.rootNode.childNode(withName: name, recursively: true)
    }

    private func report(_ message: String) {
        errorDescription = message
        NSLog("FlightStickSceneView: %@", message)
    }
}


private enum RasterMesh {
    static func node(image: CGImage, depth: CGFloat, chamfer: CGFloat, offset: CGPoint,
                     uv: @escaping (SCNVector3) -> CGPoint, sideColor: NSColor, frontZ: CGFloat) -> SCNNode? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, depth > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        func color(_ x: Int, _ y: Int) -> SCNVector4 {
            let offset = (y * width + x) * 4
            return SCNVector4(CGFloat(pixels[offset]) / 255, CGFloat(pixels[offset + 1]) / 255,
                              CGFloat(pixels[offset + 2]) / 255, CGFloat(pixels[offset + 3]) / 255)
        }
        func opaque(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            return pixels[(y * width + x) * 4 + 3] >= 128
        }
        let step = 2
        var vertices = [SCNVector3](), normals = [SCNVector3](), colors = [SCNVector4]()
        var coordinates = [CGPoint](), indices = [Int32]()
        var indicesByPoint = [Int: Int32]()
        func vertex(_ x: Int, _ y: Int, _ z: CGFloat, _ color: SCNVector4) -> Int32 {
            let key = y * width + x
            if let index = indicesByPoint[key] { return index }
            let point = SCNVector3(offset.x + CGFloat(x), offset.y - CGFloat(y), z)
            let index = Int32(vertices.count)
            vertices.append(point)
            normals.append(SCNVector3(0, 0, 1))
            colors.append(color)
            coordinates.append(uv(point))
            indicesByPoint[key] = index
            return index
        }
        var sideVertices = [SCNVector3](), sideNormals = [SCNVector3](), sideIndices = [Int32]()
        func sideVertex(_ x: Int, _ y: Int, _ z: CGFloat, _ normal: SCNVector3) -> Int32 {
            let index = Int32(sideVertices.count)
            sideVertices.append(SCNVector3(offset.x + CGFloat(x), offset.y - CGFloat(y), z))
            sideNormals.append(normal)
            return index
        }
        func side(_ a: (Int, Int), _ b: (Int, Int), _ normal: SCNVector3) {
            let topA = sideVertex(a.0, a.1, frontZ - chamfer, normal)
            let topB = sideVertex(b.0, b.1, frontZ - chamfer, normal)
            let bottomA = sideVertex(a.0, a.1, frontZ - depth, normal)
            let bottomB = sideVertex(b.0, b.1, frontZ - depth, normal)
            sideIndices.append(contentsOf: [topA, bottomA, topB, topB, bottomA, bottomB])
        }
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let x1 = min(width, x + step), y1 = min(height, y + step)
                let centerX = min(width - 1, (x + x1) / 2), centerY = min(height - 1, (y + y1) / 2)
                guard opaque(centerX, centerY) else { continue }
                let color = color(centerX, centerY)
                let boundary = !opaque(x - step, centerY) || !opaque(x1, centerY) ||
                    !opaque(centerX, y - step) || !opaque(centerX, y1)
                let z = frontZ - (boundary ? chamfer : 0)
                let a = vertex(x, y, z, color), b = vertex(x1, y, z, color)
                let c = vertex(x, y1, z, color), d = vertex(x1, y1, z, color)
                indices.append(contentsOf: [a, c, b, b, c, d])
                if !opaque(x - step, centerY) { side((x, y1), (x, y), SCNVector3(-1, 0, 0)) }
                if !opaque(x1, centerY) { side((x1, y), (x1, y1), SCNVector3(1, 0, 0)) }
                if !opaque(centerX, y - step) { side((x, y), (x1, y), SCNVector3(0, 1, 0)) }
                if !opaque(centerX, y1) { side((x1, y1), (x, y1), SCNVector3(0, -1, 0)) }
            }
        }
        guard !vertices.isEmpty else { return nil }
        let top = SCNGeometry(sources: [
            SCNGeometrySource(vertices: vertices),
            SCNGeometrySource(normals: normals),
            SCNGeometrySource(textureCoordinates: coordinates),
            SCNGeometrySource(data: colors.flatMap { [Float($0.x), Float($0.y), Float($0.z), Float($0.w)] }
                .withUnsafeBytes { Data($0) }, semantic: .color, vectorCount: colors.count,
                usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0, dataStride: MemoryLayout<Float>.size * 4),
        ], elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let topMaterial = SCNMaterial()
        topMaterial.lightingModel = .constant
        topMaterial.isDoubleSided = true
        topMaterial.diffuse.contents = NSColor.white
        top.materials = [topMaterial]
        let sides = SCNGeometry(sources: [
            SCNGeometrySource(vertices: sideVertices),
            SCNGeometrySource(normals: sideNormals),
        ], elements: [SCNGeometryElement(indices: sideIndices, primitiveType: .triangles)])
        let sideMaterial = SCNMaterial()
        sideMaterial.lightingModel = .lambert
        sideMaterial.diffuse.contents = sideColor
        sideMaterial.isDoubleSided = true
        sides.materials = [sideMaterial]
        let node = SCNNode(geometry: top)
        node.addChildNode(SCNNode(geometry: sides))
        return node
    }
}
