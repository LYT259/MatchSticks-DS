import SwiftUI
import SceneKit
import DSCore

struct ThumbstickScene: NSViewRepresentable {
    let spec: GamepadArtworkSpec
    let region: GamepadArtworkRegion
    let state: GamepadStickState
    let container: CGSize
    let sourceImage: NSImage

    func makeNSView(context: Context) -> ThumbstickSceneView {
        let view = ThumbstickSceneView(frame: CGRect(origin: .zero, size: container))
        _ = view.update(spec: spec, region: region, state: state, container: container, sourceImage: sourceImage)
        return view
    }

    func updateNSView(_ view: ThumbstickSceneView, context: Context) {
        _ = view.update(spec: spec, region: region, state: state, container: container, sourceImage: sourceImage)
    }
}

/// The controller body stays a flat artwork seen from straight above, so the stick is
/// built as if the photo camera sat `cameraPitch` in front of it: the pivot sits in
/// front of and below the cap, and the stick leans away from the viewer at rest.
final class ThumbstickSceneView: SCNView {
    private var configuration = ""
    private(set) var cameraPitch: CGFloat = 0
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
    func update(spec: GamepadArtworkSpec, region: GamepadArtworkRegion,
                state: GamepadStickState, container: CGSize, sourceImage: NSImage) -> Bool {
        let capRegion = region == .leftStick ? GamepadArtworkRegion.leftStickCap : .rightStickCap
        guard container.width > 0, container.height > 0,
              spec.regions[capRegion] != nil, spec.regions[region] != nil,
              let image = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            report("无法创建三维摇杆：图片或标定缺失")
            return false
        }
        let key = "\(spec.imageName):\(region.rawValue):\(container.width)x\(container.height):\(ObjectIdentifier(sourceImage))"
        if configuration != key {
            guard buildScene(spec: spec, region: region, container: container, image: image) else {
                report("无法创建三维摇杆几何")
                return false
            }
            configuration = key
        }
        let pose = ThumbstickMotion.pose(cap: spec.region(capRegion, in: container), state: state)
        scene?.rootNode.childNode(withName: "pivot", recursively: true)?.eulerAngles =
            SCNVector3(-cameraPitch + pose.tiltX, pose.tiltY, 0)
        scene?.rootNode.childNode(withName: "pressedRing", recursively: true)?.isHidden = !state.pressed
        errorDescription = nil
        setNeedsDisplay(bounds)
        return true
    }

    private func buildScene(spec: GamepadArtworkSpec, region: GamepadArtworkRegion,
                            container: CGSize, image: CGImage) -> Bool {
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
        let keyLight = SCNNode()
        keyLight.light = SCNLight()
        keyLight.light?.type = .directional
        keyLight.light?.intensity = 350
        keyLight.light?.castsShadow = true
        keyLight.light?.shadowColor = NSColor.black.withAlphaComponent(0.45)
        keyLight.position = SCNVector3(-container.width / 3, container.height / 3, max(container.width, container.height))
        keyLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(keyLight)
        let holes = [GamepadArtworkRegion.leftStick, .rightStick].compactMap { spec.regions[$0] }
        guard let maskedBody = GamepadArtworkImageSource.imageMaskingStickCaps(image, capRegions: holes) else { return false }
        let bodyMaterial = SCNMaterial()
        bodyMaterial.lightingModel = .constant
        bodyMaterial.diffuse.contents = maskedBody
        bodyMaterial.isDoubleSided = true
        let body = SCNNode(geometry: SCNPlane(width: container.width, height: container.height))
        body.name = "body"
        body.geometry?.materials = [bodyMaterial]
        scene.rootNode.addChildNode(body)

        let capRegion = region == .leftStick ? GamepadArtworkRegion.leftStickCap : .rightStickCap
        guard let cap = spec.regions[capRegion], let sourceWell = spec.regions[region],
              let maskedWell = GamepadArtworkImageSource.imageMaskingStickCaps(image, capRegions: [cap]),
              let wellTexture = GamepadArtworkImageSource.crop(maskedWell, rect: sourceWell),
              let sideColor = ThumbstickTexture.capSideColor(image: image, cap: cap),
              let wellColor = ThumbstickTexture.wellColor(image: image, well: sourceWell, cap: cap) else { return false }
        let wellFrame = spec.region(region, in: container)
        let capFrame = spec.region(capRegion, in: container)
        guard let geometry = ThumbstickGeometry.resolve(cap: capFrame),
              wellFrame.width >= capFrame.width, wellFrame.height >= capFrame.height else { return false }
        let radius = geometry.capRadius
        let pitch = geometry.cameraPitch
        let thickness = geometry.capThickness
        let height = geometry.stickHeight
        let depthRatio = geometry.capDepth / radius
        // The model is built in container points; the texture is cut from the artwork's own pixels.
        guard let topTexture = GamepadArtworkImageSource.crop(
            image, rect: CGRect(x: cap.minX, y: cap.minY, width: cap.width,
                                height: cap.width * depthRatio * cos(pitch))) else { return false }
        let wellRadius = wellFrame.width / 2
        let depth = max(1, radius * (1 - radius / wellRadius))

        let wellNode = SCNNode()
        wellNode.name = "well"
        wellNode.position = SCNVector3(wellFrame.midX - container.width / 2,
                                       container.height / 2 - wellFrame.midY,
                                       -radius + depth / 2)
        let wellShape = SCNNode(geometry: SCNCylinder(radius: wellRadius, height: depth))
        wellShape.rotation = SCNVector4(1, 0, 0, CGFloat.pi / 2)
        wellShape.geometry?.firstMaterial?.lightingModel = .lambert
        wellShape.geometry?.firstMaterial?.diffuse.contents = wellColor
        let wellSide = SCNNode()
        wellSide.scale.y = wellFrame.height / wellFrame.width
        wellSide.addChildNode(wellShape)
        wellNode.addChildNode(wellSide)
        let wellMaterial = SCNMaterial()
        wellMaterial.lightingModel = .lambert
        wellMaterial.diffuse.contents = wellTexture
        let wellSurface = SCNNode(geometry: Self.disk(radius: wellRadius, ratio: wellFrame.height / wellFrame.width,
                                                      material: wellMaterial))
        wellSurface.name = "wellSurface"
        wellSurface.position.z = depth
        wellNode.addChildNode(wellSurface)
        scene.rootNode.addChildNode(wellNode)

        let pivot = SCNNode()
        pivot.name = "pivot"
        // The cap top stays in front of the well floor at every attainable tilt.
        let capTopDepth = depth + height * (cos(pitch) - cos(pitch + ThumbstickGeometry.maxDeflection)) + 1
        pivot.position = SCNVector3(geometry.pivot.x - container.width / 2,
                                    container.height / 2 - geometry.pivot.y,
                                    capTopDepth - height * cos(pitch))
        pivot.eulerAngles = SCNVector3(-pitch, 0, 0)
        cameraPitch = pitch
        scene.rootNode.addChildNode(pivot)

        let shaft = SCNNode()
        shaft.name = "shaft"
        let shaftGeometry = SCNCylinder(radius: radius * 0.28, height: height - thickness + radius * 0.15)
        shaftGeometry.firstMaterial?.lightingModel = .lambert
        shaftGeometry.firstMaterial?.diffuse.contents = sideColor
        let shaftMesh = SCNNode(geometry: shaftGeometry)
        shaftMesh.rotation = SCNVector4(1, 0, 0, CGFloat.pi / 2)
        shaftMesh.position.z = shaftGeometry.height / 2
        shaft.addChildNode(shaftMesh)
        pivot.addChildNode(shaft)

        let capNode = SCNNode()
        capNode.name = "cap"
        pivot.addChildNode(capNode)
        let topMaterial = SCNMaterial()
        topMaterial.name = "capTop"
        topMaterial.lightingModel = .constant
        topMaterial.diffuse.contents = topTexture
        let top = SCNNode(geometry: Self.disk(radius: radius, ratio: depthRatio, material: topMaterial))
        top.name = "capTop"
        top.position.z = height + 0.004
        capNode.addChildNode(top)
        let sideMaterial = SCNMaterial()
        sideMaterial.name = "capSide"
        sideMaterial.lightingModel = .lambert
        sideMaterial.diffuse.contents = sideColor
        let side = SCNNode()
        side.name = "capSide"
        side.scale.y = depthRatio
        let sideMesh = SCNNode(geometry: SCNCylinder(radius: radius, height: thickness))
        sideMesh.rotation = SCNVector4(1, 0, 0, CGFloat.pi / 2)
        sideMesh.position.z = height - thickness / 2 + 0.002
        let openCap = SCNMaterial()
        openCap.diffuse.contents = NSColor.clear
        openCap.writesToDepthBuffer = false
        openCap.colorBufferWriteMask = []
        sideMesh.geometry?.materials = [sideMaterial, openCap, openCap]
        side.addChildNode(sideMesh)
        capNode.addChildNode(side)

        let pipe = max(0.75, radius * 0.025)
        let ring = SCNNode()
        ring.name = "pressedRing"
        ring.scale.y = depthRatio
        let ringMesh = SCNNode(geometry: SCNTorus(ringRadius: radius, pipeRadius: pipe))
        ringMesh.rotation = SCNVector4(1, 0, 0, CGFloat.pi / 2)
        ringMesh.position.z = height + pipe / 2
        ringMesh.geometry?.firstMaterial?.lightingModel = .constant
        ringMesh.geometry?.firstMaterial?.diffuse.contents = NSColor.systemBlue
        ring.addChildNode(ringMesh)
        capNode.addChildNode(ring)
        self.scene = scene
        self.pointOfView = cameraNode
        return true
    }

    private static func disk(radius: CGFloat, ratio: CGFloat, material: SCNMaterial) -> SCNGeometry {
        let segments = 96
        var vertices = [SCNVector3(0, 0, 0)]
        var normals = [SCNVector3(0, 0, 1)]
        var uv = [CGPoint(x: 0.5, y: 0.5)]
        var indices = [Int32]()
        for index in 0...segments {
            let angle = CGFloat(index) / CGFloat(segments) * 2 * .pi
            let x = cos(angle), y = sin(angle)
            vertices.append(SCNVector3(x * radius, y * radius * ratio, 0))
            normals.append(SCNVector3(0, 0, 1))
            // SceneKit reads v from the top of the image, so the disk's top edge takes the first row.
            uv.append(CGPoint(x: (x + 1) / 2, y: (1 - y) / 2))
        }
        for index in 1...segments {
            indices.append(contentsOf: [0, Int32(index), Int32(index + 1)])
        }
        let geometry = SCNGeometry(sources: [
            SCNGeometrySource(vertices: vertices),
            SCNGeometrySource(normals: normals),
            SCNGeometrySource(textureCoordinates: uv),
        ], elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.materials = [material]
        return geometry
    }

    private func report(_ message: String) {
        errorDescription = message
        NSLog("ThumbstickSceneView: %@", message)
    }
}

enum ThumbstickTexture {
    static func sideColor(image: CGImage, cap: CGRect) -> NSColor? {
        guard cap.width > 0, cap.height > 0 else { return nil }
        return sampleArc(image: image, center: CGPoint(x: cap.midX, y: cap.midY),
                         radiusX: cap.width * 0.45, radiusY: cap.height * 0.45)
    }

    /// The cap's visible side wall: the darkest quarter of the strip along the bottom
    /// of the cap outline, where the photo shows that wall rather than the top face.
    static func capSideColor(image: CGImage, cap: CGRect) -> NSColor? {
        guard cap.width > 0, cap.height > 0 else { return nil }
        return sampleArc(image: image, center: CGPoint(x: cap.midX, y: cap.midY),
                         radiusX: cap.width * 0.46, radiusY: cap.height * 0.46,
                         from: .pi * 0.2, to: .pi * 0.8, darkest: 8)
    }

    static func wellColor(image: CGImage, well: CGRect, cap: CGRect) -> NSColor? {
        guard well.width > 0, well.height > 0, cap.width > 0, cap.height > 0 else { return nil }
        return sampleArc(image: image, center: CGPoint(x: well.midX, y: well.midY),
                         radiusX: (well.width + cap.width) / 4,
                         radiusY: (well.height + cap.height) / 4)
    }

    private static func sampleArc(image: CGImage, center: CGPoint, radiusX: CGFloat, radiusY: CGFloat,
                                  from: CGFloat = 0, to: CGFloat = .pi, darkest: Int = 0) -> NSColor? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, radiusX > 0, radiusY > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var samples: [(luminance: CGFloat, red: CGFloat, green: CGFloat, blue: CGFloat)] = []
        for index in 0..<32 {
            let angle = from + CGFloat(index) / 31 * (to - from)
            let x = Int((center.x + cos(angle) * radiusX).rounded())
            let sourceY = Int((center.y + sin(angle) * radiusY).rounded())
            let y = sourceY
            guard x >= 0, x < width, y >= 0, y < height else { continue }
            let offset = (y * width + x) * 4
            let weight = CGFloat(pixels[offset + 3]) / 255
            guard weight > 0 else { continue }
            let red = CGFloat(pixels[offset]) / 255, green = CGFloat(pixels[offset + 1]) / 255
            let blue = CGFloat(pixels[offset + 2]) / 255
            samples.append((0.299 * red + 0.587 * green + 0.114 * blue, red, green, blue))
        }
        guard !samples.isEmpty else { return nil }
        if darkest > 0, samples.count > darkest {
            samples.sort { $0.luminance < $1.luminance }
            samples = Array(samples.prefix(darkest))
        }
        let total = CGFloat(samples.count)
        return NSColor(deviceRed: samples.reduce(0) { $0 + $1.red } / total,
                       green: samples.reduce(0) { $0 + $1.green } / total,
                       blue: samples.reduce(0) { $0 + $1.blue } / total, alpha: 1)
    }
}
