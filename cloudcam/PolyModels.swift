import CoreGraphics
import SceneKit

/// PS1-style stand-ins for real things the camera recognizes: rocks, shoes, books, mugs, bottles,
/// plants, balls, fruit, boxes, lamps, laptops and chairs. Each is built 1 unit wide with its base
/// at the origin, so it can be scaled to the real object's width, and takes the real object's
/// color. Anything without a model of its own becomes a chunky block wearing a tiny pixelated
/// picture of the real thing.
enum PolyModels {
    /// The model for a Vision label, or nil if there's no model for it.
    static func model(for label: String, color: CGColor) -> SCNNode? {
        switch label {
        case "rocks": return rock(color)
        case "shoes", "sneaker", "boot", "sandal": return shoe(color)
        case "book": return books(color)
        case "cup", "mug": return mug(color)
        case "bottle", "wine_bottle": return bottle(color)
        case "plant", "decorative_plant", "flower", "flower_arrangement", "vase": return plant()
        case "ball", "baseball": return ball(color)
        case "apple", "oranges", "citrus_fruit", "fruit": return fruit(color)
        case "banana": return banana()
        case "cardboard_box": return box()
        case "lamp": return lamp(color)
        case "laptop", "computer": return laptop()
        case "chair", "armchair", "chair_other", "folding_chair", "swivel_chair": return chair(color)
        default: return nil
        }
    }

    /// A block shaped like the object's outline, wearing a tiny picture of it on the front.
    static func block(picture: CGImage?, color: CGColor, height: Float) -> SCNNode {
        let box = SCNBox(width: 1, height: CGFloat(height), length: 0.6, chamferRadius: 0)
        let side = PS1.material(color: color, shiny: false)
        box.materials = [PS1.material(texture: picture), side, side, side, side, side]
        let node = SCNNode(geometry: box)
        node.position = SCNVector3(0, height / 2, 0)
        return wrap(node)
    }

    // MARK: - Models

    private static func rock(_ color: CGColor) -> SCNNode {
        let sphere = SCNSphere(radius: 0.5)
        sphere.segmentCount = 5
        sphere.materials = [PS1.material(texture: speckle(color))]
        let node = SCNNode(geometry: sphere)
        node.scale = SCNVector3(1, Float.random(in: 0.5...0.75), Float.random(in: 0.7...0.95))
        node.position.y = 0.5 * node.scale.y * 0.9
        node.eulerAngles.y = .random(in: 0...6)
        return wrap(node)
    }

    private static func shoe(_ color: CGColor) -> SCNNode {
        let node = SCNNode()
        let sole = SCNBox(width: 1, height: 0.12, length: 0.38, chamferRadius: 0.04)
        sole.chamferSegmentCount = 1
        sole.materials = [PS1.material(color: CGColor(gray: 0.95, alpha: 1), shiny: false)]
        node.addChildNode(at(SCNNode(geometry: sole), 0, 0.06, 0))

        let upper = SCNBox(width: 0.62, height: 0.32, length: 0.34, chamferRadius: 0.08)
        upper.chamferSegmentCount = 1
        upper.materials = [PS1.material(color: color, shiny: false)]
        node.addChildNode(at(SCNNode(geometry: upper), -0.16, 0.27, 0))

        let toe = SCNSphere(radius: 0.19)
        toe.segmentCount = 6
        toe.materials = [PS1.material(color: color, shiny: false)]
        let toeNode = at(SCNNode(geometry: toe), 0.24, 0.17, 0)
        toeNode.scale = SCNVector3(1.4, 0.75, 0.9)
        node.addChildNode(toeNode)

        let laces = SCNBox(width: 0.3, height: 0.02, length: 0.14, chamferRadius: 0)
        laces.materials = [PS1.material(texture: laceTexture())]
        let laceNode = at(SCNNode(geometry: laces), 0.05, 0.3, 0)
        laceNode.eulerAngles.z = -0.35
        node.addChildNode(laceNode)
        return wrap(node)
    }

    private static func books(_ color: CGColor) -> SCNNode {
        let node = SCNNode()
        var y: Float = 0
        for _ in 0..<Int.random(in: 3...5) {
            let h = Float.random(in: 0.1...0.18)
            let book = SCNBox(width: CGFloat(Float.random(in: 0.85...1)), height: CGFloat(h), length: 0.7, chamferRadius: 0)
            let cover = PS1.material(texture: spine())
            let pages = PS1.material(color: CGColor(red: 0.95, green: 0.92, blue: 0.82, alpha: 1), shiny: false)
            box(book, front: cover, back: cover, left: pages, right: cover, top: cover, bottom: cover)
            let b = at(SCNNode(geometry: book), 0, y + h / 2, 0)
            b.eulerAngles.y = .random(in: -0.25...0.25)
            node.addChildNode(b)
            y += h
        }
        _ = color
        return wrap(node)
    }

    private static func mug(_ color: CGColor) -> SCNNode {
        let node = SCNNode()
        let body = SCNCylinder(radius: 0.38, height: 0.9)
        body.radialSegmentCount = 8
        body.materials = [PS1.material(color: color, shiny: true),
                          PS1.material(color: CGColor(gray: 0.15, alpha: 1), shiny: false),
                          PS1.material(color: color, shiny: true)]
        node.addChildNode(at(SCNNode(geometry: body), -0.1, 0.45, 0))
        let handle = SCNTorus(ringRadius: 0.2, pipeRadius: 0.06)
        handle.ringSegmentCount = 8
        handle.pipeSegmentCount = 4
        handle.materials = [PS1.material(color: color, shiny: true)]
        let h = at(SCNNode(geometry: handle), 0.3, 0.45, 0)
        h.eulerAngles.x = .pi / 2
        node.addChildNode(h)
        return wrap(node)
    }

    private static func bottle(_ color: CGColor) -> SCNNode {
        let node = SCNNode()
        let glass = PS1.material(color: color.copy(alpha: 0.8) ?? color, shiny: true)
        let body = SCNCylinder(radius: 0.5, height: 1.8)
        body.radialSegmentCount = 6
        body.materials = [glass]
        node.addChildNode(at(SCNNode(geometry: body), 0, 0.9, 0))
        let neck = SCNCone(topRadius: 0.18, bottomRadius: 0.5, height: 0.6)
        neck.radialSegmentCount = 6
        neck.materials = [glass]
        node.addChildNode(at(SCNNode(geometry: neck), 0, 2.1, 0))
        let lid = SCNCylinder(radius: 0.2, height: 0.25)
        lid.radialSegmentCount = 6
        lid.materials = [PS1.material(color: CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1), shiny: false)]
        node.addChildNode(at(SCNNode(geometry: lid), 0, 2.52, 0))
        return wrap(node)
    }

    private static func plant() -> SCNNode {
        let node = SCNNode()
        let pot = SCNCone(topRadius: 0.5, bottomRadius: 0.36, height: 0.6)
        pot.radialSegmentCount = 8
        pot.materials = [PS1.material(color: CGColor(red: 0.75, green: 0.36, blue: 0.2, alpha: 1), shiny: false)]
        node.addChildNode(at(SCNNode(geometry: pot), 0, 0.3, 0))
        for i in 0..<7 {
            let leaf = SCNPyramid(width: 0.22, height: 0.75, length: 0.05)
            leaf.materials = [PS1.material(color: CGColor(red: 0.15, green: Double.random(in: 0.5...0.75), blue: 0.2, alpha: 1), shiny: false)]
            let l = at(SCNNode(geometry: leaf), 0, 0.55, 0)
            l.eulerAngles = SCNVector3(Float.random(in: 0.2...0.6), Float(i) / 7 * 2 * .pi, 0)
            node.addChildNode(l)
        }
        return wrap(node)
    }

    private static func ball(_ color: CGColor) -> SCNNode {
        let sphere = SCNSphere(radius: 0.5)
        sphere.segmentCount = 8
        sphere.materials = [PS1.material(texture: bands(color))]
        return wrap(at(SCNNode(geometry: sphere), 0, 0.5, 0))
    }

    private static func fruit(_ color: CGColor) -> SCNNode {
        let node = SCNNode()
        let sphere = SCNSphere(radius: 0.5)
        sphere.segmentCount = 7
        sphere.materials = [PS1.material(color: color, shiny: true)]
        node.addChildNode(at(SCNNode(geometry: sphere), 0, 0.48, 0))
        let stem = SCNCylinder(radius: 0.03, height: 0.18)
        stem.radialSegmentCount = 4
        stem.materials = [PS1.material(color: CGColor(red: 0.35, green: 0.22, blue: 0.1, alpha: 1), shiny: false)]
        node.addChildNode(at(SCNNode(geometry: stem), 0, 1.0, 0))
        let leaf = SCNPyramid(width: 0.2, height: 0.3, length: 0.03)
        leaf.materials = [PS1.material(color: CGColor(red: 0.2, green: 0.65, blue: 0.2, alpha: 1), shiny: false)]
        let l = at(SCNNode(geometry: leaf), 0.08, 0.98, 0)
        l.eulerAngles.z = -1
        node.addChildNode(l)
        return wrap(node)
    }

    private static func banana() -> SCNNode {
        let node = SCNNode()
        let yellow = PS1.material(color: CGColor(red: 0.98, green: 0.85, blue: 0.2, alpha: 1), shiny: false)
        for i in 0..<5 {  // five short pieces along a curve
            let t = Float(i) / 4 - 0.5
            let piece = SCNCylinder(radius: 0.13 - CGFloat(abs(t)) * 0.08, height: 0.28)
            piece.radialSegmentCount = 5
            piece.materials = [yellow]
            let p = at(SCNNode(geometry: piece), t * 0.85, 0.12 + t * t * 0.6, 0)
            p.eulerAngles = SCNVector3(0, 0, .pi / 2 + t * 1.6)
            node.addChildNode(p)
        }
        return wrap(node)
    }

    private static func box() -> SCNNode {
        let cardboard = SCNBox(width: 1, height: 0.7, length: 0.8, chamferRadius: 0)
        let side = PS1.material(texture: tape(top: false))
        box(cardboard, front: side, back: side, left: side, right: side, top: PS1.material(texture: tape(top: true)), bottom: side)
        return wrap(at(SCNNode(geometry: cardboard), 0, 0.35, 0))
    }

    private static func lamp(_ color: CGColor) -> SCNNode {
        let node = SCNNode()
        let base = SCNCylinder(radius: 0.3, height: 0.06)
        base.radialSegmentCount = 8
        base.materials = [PS1.material(color: CGColor(gray: 0.2, alpha: 1), shiny: true)]
        node.addChildNode(at(SCNNode(geometry: base), 0, 0.03, 0))
        let pole = SCNCylinder(radius: 0.03, height: 1.1)
        pole.radialSegmentCount = 4
        pole.materials = [PS1.material(color: CGColor(gray: 0.2, alpha: 1), shiny: true)]
        node.addChildNode(at(SCNNode(geometry: pole), 0, 0.6, 0))
        let shade = SCNCone(topRadius: 0.24, bottomRadius: 0.5, height: 0.5)
        shade.radialSegmentCount = 6
        shade.materials = [PS1.material(color: color, shiny: false)]
        node.addChildNode(at(SCNNode(geometry: shade), 0, 1.25, 0))
        return wrap(node)
    }

    private static func laptop() -> SCNNode {
        let node = SCNNode()
        let grey = PS1.material(color: CGColor(gray: 0.7, alpha: 1), shiny: true)
        let base = SCNBox(width: 1, height: 0.04, length: 0.68, chamferRadius: 0)
        base.materials = [grey]
        node.addChildNode(at(SCNNode(geometry: base), 0, 0.02, 0))
        let lid = SCNBox(width: 1, height: 0.66, length: 0.03, chamferRadius: 0)
        box(lid, front: PS1.material(texture: screen()), back: grey, left: grey, right: grey, top: grey, bottom: grey)
        let l = at(SCNNode(geometry: lid), 0, 0.33, -0.34)
        l.pivot = SCNMatrix4MakeTranslation(0, -0.33, 0)
        l.position.y = 0.04
        l.eulerAngles.x = -0.25
        node.addChildNode(l)
        return wrap(node)
    }

    private static func chair(_ color: CGColor) -> SCNNode {
        let node = SCNNode()
        let wood = PS1.material(color: color, shiny: false)
        let seat = SCNBox(width: 1, height: 0.1, length: 0.9, chamferRadius: 0)
        seat.materials = [wood]
        node.addChildNode(at(SCNNode(geometry: seat), 0, 0.9, 0))
        for (x, z) in [(-0.42, -0.38), (0.42, -0.38), (-0.42, 0.38), (0.42, 0.38)] as [(Float, Float)] {
            let leg = SCNBox(width: 0.08, height: 0.85, length: 0.08, chamferRadius: 0)
            leg.materials = [wood]
            node.addChildNode(at(SCNNode(geometry: leg), x, 0.425, z))
        }
        let back = SCNBox(width: 1, height: 0.9, length: 0.08, chamferRadius: 0)
        back.materials = [wood]
        node.addChildNode(at(SCNNode(geometry: back), 0, 1.4, -0.41))
        return wrap(node)
    }

    // MARK: - Helpers

    private static func at(_ node: SCNNode, _ x: Float, _ y: Float, _ z: Float) -> SCNNode {
        node.position = SCNVector3(x, y, z)
        return node
    }

    private static func wrap(_ node: SCNNode) -> SCNNode {
        let holder = SCNNode()
        holder.addChildNode(node)
        return holder
    }

    /// SCNBox materials go front, right, back, left, top, bottom.
    private static func box(_ box: SCNBox, front: SCNMaterial, back: SCNMaterial, left: SCNMaterial, right: SCNMaterial,
                            top: SCNMaterial, bottom: SCNMaterial) {
        box.materials = [front, right, back, left, top, bottom]
    }

    private static func rgb(_ c: CGColor) -> (CGFloat, CGFloat, CGFloat) {
        let rgb = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0.5, 0.5, 0.5]
        return rgb.count >= 3 ? (rgb[0], rgb[1], rgb[2]) : (rgb[0], rgb[0], rgb[0])
    }

    // MARK: - Pixel-art textures

    private static func speckle(_ color: CGColor) -> CGImage? {
        let base = rgb(color)
        return PS1.pixels(16, 16) { c in
            for y in 0..<16 {
                for x in 0..<16 {
                    let k = CGFloat.random(in: 0.7...1.1)
                    PS1.fill(c, (base.0 * k, base.1 * k, base.2 * k), CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }

    private static func bands(_ color: CGColor) -> CGImage? {
        let base = rgb(color)
        return PS1.pixels(16, 16) { c in
            PS1.fill(c, base, CGRect(x: 0, y: 0, width: 16, height: 16))
            PS1.fill(c, (1, 1, 1), CGRect(x: 0, y: 6, width: 16, height: 4))
        }
    }

    private static func spine() -> CGImage? {
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.7, 0.1, 0.1), (0.1, 0.25, 0.6), (0.15, 0.45, 0.2), (0.85, 0.7, 0.2), (0.3, 0.15, 0.4)]
        return PS1.pixels(16, 8) { c in
            PS1.fill(c, colors.randomElement()!, CGRect(x: 0, y: 0, width: 16, height: 8))
            PS1.fill(c, (0.95, 0.85, 0.4), CGRect(x: 2, y: 3, width: 9, height: 2))  // the title
        }
    }

    private static func laceTexture() -> CGImage? {
        PS1.pixels(8, 4) { c in
            PS1.fill(c, (0.95, 0.95, 0.95), CGRect(x: 0, y: 0, width: 8, height: 4))
            for x in stride(from: 1, to: 8, by: 2) { PS1.fill(c, (0.6, 0.6, 0.6), CGRect(x: x, y: 0, width: 1, height: 4)) }
        }
    }

    private static func tape(top: Bool) -> CGImage? {
        PS1.pixels(16, 16) { c in
            PS1.fill(c, (0.72, 0.52, 0.3), CGRect(x: 0, y: 0, width: 16, height: 16))
            if top { PS1.fill(c, (0.85, 0.75, 0.55), CGRect(x: 6, y: 0, width: 4, height: 16)) }
            PS1.fill(c, (0.6, 0.42, 0.24), CGRect(x: 0, y: 15, width: 16, height: 1))
        }
    }

    private static func screen() -> CGImage? {
        PS1.pixels(16, 12) { c in
            PS1.fill(c, (0.1, 0.1, 0.12), CGRect(x: 0, y: 0, width: 16, height: 12))
            PS1.fill(c, (0.1, 0.3, 0.75), CGRect(x: 1, y: 1, width: 14, height: 10))
            PS1.fill(c, (0.85, 0.85, 0.9), CGRect(x: 3, y: 6, width: 6, height: 3))  // a window
        }
    }
}
