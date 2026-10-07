import ARKit
import SceneKit
import SwiftUI

/// PlayStation 1 trash spilled across the real floor. ARKit finds the floor or a table in front
/// of the camera and covers it with low-poly trash (see Trash), lit by the room's own light and
/// casting shadows on the real surface. It stays put as you walk through it. Tap a surface to
/// move the pile there.
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

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard let query = view.raycastQuery(from: tap.location(in: view), allowing: .estimatedPlane, alignment: .horizontal),
              let hit = view.session.raycast(query).first,
              let camera = view.session.currentFrame?.camera
        else { return }
        if !placed {
            place(at: hit.worldTransform.columns.3, camera: camera)
            return
        }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.5
        put(at: hit.worldTransform, facing: camera.eulerAngles.y)
        SCNTransaction.commit()
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
