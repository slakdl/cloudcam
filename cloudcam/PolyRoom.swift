import ARKit
import SceneKit
import SwiftUI

/// PlayStation 1 trash spilled across the real floor. ARKit finds the floor or a table in front
/// of the camera and covers it with low-poly trash (see Trash), lit by the room's own light and
/// casting shadows on the real surface. It stays put as you walk through it. Tap a real object
/// and a PS1 version of it appears on top of it (see ObjectScan and PolyModels).
final class PolyRoom: NSObject, ARSessionDelegate {
    let view = ARSCNView()
    private let group = SCNNode()
    private var placed = false

    override init() {
        super.init()
        view.scene = SCNScene()
        view.session.delegate = self
        view.automaticallyUpdatesLighting = true
        view.antialiasingMode = .multisampling4X
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        build()
    }

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .automatic  // real reflections on the glossy objects
        view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        group.removeFromParentNode()
        placed = false
        frames = 0
    }

    func stop() {
        view.session.pause()
    }

    /// The picture exactly as it looks on screen, objects and all.
    func snapshot() -> UIImage {
        view.snapshot()
    }

    // MARK: - Placing

    /// Until the objects are down, keep looking for a surface in the middle of the view.
    private var frames = 0

    /// Until the objects are down, look for a surface in the middle of the view. If none turns
    /// up within a couple of seconds, set them down a metre ahead anyway, on the floor or table
    /// the phone has found so far, or at about table height if it hasn't found one.
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard !placed, case .normal = frame.camera.trackingState else { return }
        frames += 1
        let query = frame.raycastQuery(from: CGPoint(x: 0.5, y: 0.5), allowing: .estimatedPlane, alignment: .horizontal)
        if let hit = session.raycast(query).first {
            place(at: hit.worldTransform.columns.3, camera: frame.camera)
        } else if frames > 120 {
            let eye = frame.camera.transform.columns.3
            var ahead = -SIMD3(frame.camera.transform.columns.2.x, 0, frame.camera.transform.columns.2.z)
            ahead = simd_length(ahead) > 0.01 ? simd_normalize(ahead) : [0, 0, -1]
            let surfaces = frame.anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .horizontal }
            let height = surfaces.map { $0.transform.columns.3.y }.filter { $0 < eye.y - 0.2 }.max() ?? eye.y - 0.6
            place(at: SIMD4(eye.x + ahead.x, height, eye.z + ahead.z, 1), camera: frame.camera)
        }
    }

    private func place(at point: SIMD4<Float>, camera: ARCamera) {
        placed = true
        var transform = matrix_identity_float4x4
        transform.columns.3 = point
        put(at: transform, facing: camera.eulerAngles.y)
        view.scene.rootNode.addChildNode(group)
    }

    /// Says what's going on ("Looking…", "a shoe!"), for the screen to show.
    var onMessage: ((String) -> Void)?
    private let scanQueue = DispatchQueue(label: "poly-scan", qos: .userInitiated)
    private var scanning = false

    /// Tap a real object: work out what it is and set a PS1 version of it down right on top.
    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        let location = tap.location(in: view)
        guard !scanning, let frame = view.session.currentFrame,
              let surface = view.raycastQuery(from: location, allowing: .estimatedPlane, alignment: .any)
                  .flatMap({ view.session.raycast($0).first })
        else {
            onMessage?("Point at an object sitting on a surface")
            return
        }
        // Where the model stands: the floor or table under the tap if there is one.
        let ground = view.raycastQuery(from: location, allowing: .estimatedPlane, alignment: .horizontal)
            .flatMap { view.session.raycast($0).first } ?? surface
        let camera = frame.camera
        let distance = simd_distance(surface.worldTransform.columns.3, camera.transform.columns.3)
        let buffer = frame.capturedImage
        let size = view.bounds.size

        scanning = true
        onMessage?("Looking…")
        scanQueue.async { [self] in
            let scan = ObjectScan.scan(buffer, viewSize: size, at: location)
            DispatchQueue.main.async { [self] in
                scanning = false
                guard let scan else { onMessage?("Couldn't make that out"); return }

                // How wide the object really is: its share of the picture, at that distance.
                let pixelsWide = Float(CVPixelBufferGetHeight(buffer)) * Float(scan.box.width)  // upright width
                let width = min(max(pixelsWide / camera.intrinsics[0][0] * distance, 0.05), 1.5)

                let label = scan.labels.first { PolyModels.model(for: $0, color: scan.color) != nil }
                let model = label.flatMap { PolyModels.model(for: $0, color: scan.color) }
                    ?? PolyModels.block(picture: scan.picture, color: scan.color,
                                        height: Float(scan.box.height / max(scan.box.width, 0.01)) * 0.75)
                drop(model, width: width, at: ground.worldTransform, facing: camera.eulerAngles.y)
                onMessage?(label.map { "A " + $0.replacingOccurrences(of: "_", with: " ") + "!" } ?? "Something!")
            }
        }
    }

    /// Sets a model down, scaled to `width` metres, with a little pop.
    private func drop(_ model: SCNNode, width: Float, at transform: simd_float4x4, facing yaw: Float) {
        let holder = SCNNode()
        holder.simdPosition = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        holder.eulerAngles.y = yaw
        holder.addChildNode(model)
        model.scale = SCNVector3(0.01, 0.01, 0.01)
        let grow = SCNAction.scale(to: CGFloat(width * 1.15), duration: 0.18)
        grow.timingMode = .easeOut
        let settle = SCNAction.scale(to: CGFloat(width), duration: 0.12)
        settle.timingMode = .easeInEaseOut
        model.runAction(.sequence([grow, settle]))
        view.scene.rootNode.addChildNode(holder)
    }

    private func put(at transform: simd_float4x4, facing yaw: Float) {
        group.simdPosition = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        group.eulerAngles.y = yaw  // the scene faces the camera
    }

    // MARK: - The trash

    private func build() {
        group.addChildNode(Trash.pile())

        // A light from above that casts the trash's shadows onto an invisible floor, so the
        // shadows land on the real surface.
        let light = SCNLight()
        light.type = .directional
        light.castsShadow = true
        light.shadowMode = .deferred
        light.shadowColor = CGColor(gray: 0, alpha: 0.45)
        light.shadowRadius = 4
        light.intensity = 700
        let sun = SCNNode()
        sun.light = light
        sun.eulerAngles = SCNVector3(-Float.pi / 2.6, 0.5, 0)

        let floorPlane = SCNPlane(width: 4, height: 4)
        let catcher = SCNMaterial()
        catcher.lightingModel = .shadowOnly
        floorPlane.materials = [catcher]
        let floor = SCNNode(geometry: floorPlane)
        floor.eulerAngles.x = -.pi / 2

        group.addChildNode(sun)
        group.addChildNode(floor)
    }
}

/// Shows the AR view in SwiftUI.
struct PolyView: UIViewRepresentable {
    let room: PolyRoom

    func makeUIView(context: Context) -> ARSCNView { room.view }
    func updateUIView(_ view: ARSCNView, context: Context) {}
}
