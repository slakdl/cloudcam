import ARKit
import SceneKit
import SwiftUI

/// Low-poly objects in the real room, like an old 3D render dropped into your space. ARKit finds
/// a floor or table in front of the camera and sets down a little scene there: a glossy pink ball,
/// a spinning orange ring, a yellow cube, a teal pillar and a hovering green crystal. They're
/// faceted (every triangle flat-shaded), lit by the room's own light, cast shadows on the real
/// surface, and stay put as you walk around them. Tap a surface to move them there.
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

    // MARK: - The objects

    private func build() {
        // Pink ball, glossy like a 90s render.
        let ball = SCNNode(geometry: Self.icosphere(radius: 0.12, color: UIColor(red: 0.85, green: 0.1, blue: 0.45, alpha: 1)))
        ball.position = SCNVector3(-0.22, 0.12, 0.05)

        // Orange ring, standing up and slowly spinning.
        let ring = SCNNode(geometry: Self.torus(radius: 0.14, tube: 0.04, color: UIColor(red: 0.95, green: 0.45, blue: 0.1, alpha: 1)))
        ring.eulerAngles.x = .pi / 2
        let ringHolder = SCNNode()
        ringHolder.position = SCNVector3(0.2, 0.3, -0.1)
        ringHolder.addChildNode(ring)
        ringHolder.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 7)))

        // Yellow cube.
        let box = SCNBox(width: 0.15, height: 0.15, length: 0.15, chamferRadius: 0)
        box.materials = [Self.material(UIColor(red: 0.98, green: 0.85, blue: 0.1, alpha: 1))]
        let cube = SCNNode(geometry: box)
        cube.position = SCNVector3(0.27, 0.075, 0.2)
        cube.eulerAngles.y = 0.5

        // Teal pillar: a six-sided column with a slab on top.
        let pillar = SCNNode(geometry: Self.prism(sides: 6, radius: 0.05, height: 0.42, color: UIColor(red: 0.1, green: 0.55, blue: 0.6, alpha: 1)))
        pillar.position = SCNVector3(-0.45, 0, -0.2)
        let slab = SCNBox(width: 0.15, height: 0.03, length: 0.15, chamferRadius: 0)
        slab.materials = [Self.material(UIColor(red: 0.1, green: 0.55, blue: 0.6, alpha: 1))]
        let cap = SCNNode(geometry: slab)
        cap.position = SCNVector3(-0.45, 0.435, -0.2)

        // Green crystal, hovering, spinning and bobbing like a pickup in a game.
        let crystal = SCNNode(geometry: Self.octahedron(size: 0.08, color: UIColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1)))
        crystal.position = SCNVector3(-0.02, 0.32, -0.3)
        crystal.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 4)))
        let bob = SCNAction.sequence([.moveBy(x: 0, y: 0.04, z: 0, duration: 1.2), .moveBy(x: 0, y: -0.04, z: 0, duration: 1.2)])
        bob.timingMode = .easeInEaseOut
        crystal.runAction(.repeatForever(bob))

        // A light from above that casts the objects' shadows onto an invisible floor, so the
        // shadows land on the real surface.
        let light = SCNLight()
        light.type = .directional
        light.castsShadow = true
        light.shadowMode = .deferred
        light.shadowColor = UIColor.black.withAlphaComponent(0.45)
        light.shadowRadius = 6
        light.intensity = 600
        let sun = SCNNode()
        sun.light = light
        sun.eulerAngles = SCNVector3(-Float.pi / 2.6, 0.5, 0)

        let floorPlane = SCNPlane(width: 3, height: 3)
        let catcher = SCNMaterial()
        catcher.lightingModel = .shadowOnly
        floorPlane.materials = [catcher]
        let floor = SCNNode(geometry: floorPlane)
        floor.eulerAngles.x = -.pi / 2

        [ball, ringHolder, cube, pillar, cap, crystal, sun, floor].forEach(group.addChildNode)
    }

    private static func material(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = 0.25
        m.metalness.contents = 0.0
        return m
    }

    // MARK: - Faceted meshes

    /// Turns a list of triangles into a mesh where every triangle is flat-shaded, which is what
    /// gives the low-poly look. Each triangle is turned to face away from `inside` for it.
    private static func faceted(_ triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)], color: UIColor,
                                inside: (SIMD3<Float>) -> SIMD3<Float>) -> SCNGeometry {
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        for var (a, b, c) in triangles {
            var n = simd_normalize(simd_cross(b - a, c - a))
            let center = (a + b + c) / 3
            if simd_dot(n, center - inside(center)) < 0 {
                swap(&b, &c)
                n = -n
            }
            for p in [a, b, c] {
                positions.append(SCNVector3(p))
                normals.append(SCNVector3(n))
            }
        }
        let indices = (0..<Int32(positions.count)).map { $0 }
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
        geometry.materials = [material(color)]
        return geometry
    }

    /// A ball made of 80 triangles: an icosahedron with each face split in four.
    private static func icosphere(radius: Float, color: UIColor) -> SCNGeometry {
        let t: Float = (1 + sqrt(5)) / 2
        let v: [SIMD3<Float>] = [
            [-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t],
            [0, -1, -t], [0, 1, -t], [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1],
        ].map { simd_normalize($0) }
        let faces = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2),
            (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5),
            (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
        ]
        var triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        for (i, j, k) in faces {
            let a = v[i], b = v[j], c = v[k]
            let ab = simd_normalize(a + b), bc = simd_normalize(b + c), ca = simd_normalize(c + a)
            triangles += [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
        }
        return faceted(triangles.map { ($0.0 * radius, $0.1 * radius, $0.2 * radius) }, color: color) { _ in .zero }
    }

    /// A chunky ring: 12 segments around, 6 around the tube, lying flat.
    private static func torus(radius: Float, tube: Float, color: UIColor) -> SCNGeometry {
        let around = 12, across = 6
        func point(_ i: Int, _ j: Int) -> SIMD3<Float> {
            let u = Float(i) / Float(around) * 2 * .pi, w = Float(j) / Float(across) * 2 * .pi
            let r = radius + tube * cos(w)
            return [r * cos(u), tube * sin(w), r * sin(u)]
        }
        var triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        for i in 0..<around {
            for j in 0..<across {
                let a = point(i, j), b = point(i + 1, j), c = point(i + 1, j + 1), d = point(i, j + 1)
                triangles += [(a, b, c), (a, c, d)]
            }
        }
        // The inside of the tube at any point is the nearest spot on the ring's centre line.
        return faceted(triangles, color: color) { p in
            let flat = SIMD3<Float>(p.x, 0, p.z)
            return simd_normalize(flat) * radius
        }
    }

    /// A column with flat sides, standing on its base.
    private static func prism(sides: Int, radius: Float, height: Float, color: UIColor) -> SCNGeometry {
        func corner(_ i: Int, _ y: Float) -> SIMD3<Float> {
            let a = Float(i) / Float(sides) * 2 * .pi
            return [radius * cos(a), y, radius * sin(a)]
        }
        var triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        let top = SIMD3<Float>(0, height, 0), bottom = SIMD3<Float>(0, 0, 0)
        for i in 0..<sides {
            let a = corner(i, 0), b = corner(i + 1, 0), c = corner(i + 1, height), d = corner(i, height)
            triangles += [(a, b, c), (a, c, d), (d, c, top), (b, a, bottom)]
        }
        return faceted(triangles, color: color) { _ in [0, height / 2, 0] }
    }

    /// Two four-sided pyramids base to base: a classic game crystal.
    private static func octahedron(size: Float, color: UIColor) -> SCNGeometry {
        let up = SIMD3<Float>(0, size * 1.5, 0), down = SIMD3<Float>(0, -size * 1.5, 0)
        let ring: [SIMD3<Float>] = [[size, 0, 0], [0, 0, size], [-size, 0, 0], [0, 0, -size]]
        var triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        for i in 0..<4 {
            let a = ring[i], b = ring[(i + 1) % 4]
            triangles += [(a, b, up), (b, a, down)]
        }
        return faceted(triangles, color: color) { _ in .zero }
    }
}

/// Shows the AR view in SwiftUI.
struct PolyView: UIViewRepresentable {
    let room: PolyRoom

    func makeUIView(context: Context) -> ARSCNView { room.view }
    func updateUIView(_ view: ARSCNView, context: Context) {}
}
