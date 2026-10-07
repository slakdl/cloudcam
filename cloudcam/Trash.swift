import CoreGraphics
import SceneKit

/// A floor's worth of low-poly trash in the style of a PlayStation 1 game: trash bags, soda
/// cans, candy wrappers, chip bags, paper balls and bottles. Everything is built from a handful
/// of polygons, wears tiny pixel-art textures shown with hard pixel edges, and has the PS1's
/// wobbly vertices (corners snap to a coarse grid as the camera moves) and reduced color depth.
enum Trash {
    /// About `count` pieces scattered around (0, 0, 0) on the floor, within `radius` metres.
    /// Bags and paper gather in a pile in the middle; cans and wrappers spread further out.
    static func pile(count: Int = 110, radius: Float = 1.6) -> SCNNode {
        let pile = SCNNode()
        for i in 0..<count {
            let roll = Float.random(in: 0...1)
            let item: SCNNode
            let spread: Float
            switch roll {
            case ..<0.06: item = bag(); spread = 0.6
            case ..<0.34: item = can(); spread = 1
            case ..<0.58: item = wrapper(); spread = 1
            case ..<0.70: item = chips(); spread = 0.9
            case ..<0.86: item = paper(); spread = 0.9
            default: item = bottle(); spread = 0.9
            }
            // Denser toward the middle: square the random distance.
            let r = radius * spread * pow(Float.random(in: 0...1), 0.8)
            let a = Float.random(in: 0...(2 * .pi))
            let holder = SCNNode()
            holder.position = SCNVector3(r * cos(a), 0, r * sin(a))
            holder.eulerAngles.y = .random(in: 0...(2 * .pi))
            holder.addChildNode(item)
            holder.name = "trash-\(i)"
            pile.addChildNode(holder)
        }
        return pile
    }

    // MARK: - Pieces

    /// A lumpy black or green bag with a knot on top, sometimes two leaning together.
    private static func bag() -> SCNNode {
        let color = Bool.random() ? CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
                                  : CGColor(red: 0.12, green: 0.22, blue: 0.12, alpha: 1)
        let node = SCNNode()
        for lump in 0..<Int.random(in: 1...2) {
            let sphere = SCNSphere(radius: 0.14)
            sphere.segmentCount = 7
            sphere.materials = [material(color: color, shiny: true)]
            let body = SCNNode(geometry: sphere)
            let h = Float.random(in: 0.85...1.25)
            body.scale = SCNVector3(Float.random(in: 0.9...1.15), h, Float.random(in: 0.8...1.05))
            body.position = SCNVector3(Float(lump) * 0.2, 0.13 * h, Float(lump) * 0.07)
            body.eulerAngles = SCNVector3(.random(in: -0.15...0.15), .random(in: 0...6), .random(in: -0.15...0.15))

            let knot = SCNPyramid(width: 0.045, height: 0.05, length: 0.045)
            knot.materials = [material(color: color, shiny: true)]
            let top = SCNNode(geometry: knot)
            top.position = SCNVector3(0, 0.13, 0)
            top.eulerAngles = SCNVector3(.random(in: -0.4...0.4), 0, .random(in: -0.4...0.4))
            body.addChildNode(top)
            node.addChildNode(body)
        }
        return node
    }

    /// An eight-sided soda can with a pixel-art label: standing, lying down or crushed.
    private static func can() -> SCNNode {
        let cylinder = SCNCylinder(radius: 0.033, height: 0.12)
        cylinder.radialSegmentCount = 8
        let metal = material(color: CGColor(gray: 0.72, alpha: 1), shiny: true)
        cylinder.materials = [material(texture: canLabel()), metal, metal]
        let body = SCNNode(geometry: cylinder)
        let node = SCNNode()
        node.addChildNode(body)
        switch Int.random(in: 0..<3) {
        case 0:  // standing
            body.position.y = 0.06
        case 1:  // lying on its side
            body.eulerAngles.z = .pi / 2
            body.position.y = 0.033
        default:  // crushed flat
            body.scale = SCNVector3(1.15, 0.45, 0.8)
            body.eulerAngles.z = .pi / 2 + .random(in: -0.3...0.3)
            body.position.y = 0.022
        }
        return node
    }

    /// A twisted candy wrapper: a flat pillow with two pinched ends.
    private static func wrapper() -> SCNNode {
        let texture = material(texture: stripes(width: 16, height: 8))
        let pillow = SCNBox(width: 0.07, height: 0.012, length: 0.035, chamferRadius: 0.004)
        pillow.chamferSegmentCount = 1
        pillow.materials = [texture]
        let node = SCNNode(geometry: pillow)
        node.position.y = 0.006
        for side: Float in [-1, 1] {
            let end = SCNPyramid(width: 0.03, height: 0.03, length: 0.012)
            end.materials = [texture]
            let twist = SCNNode(geometry: end)
            twist.eulerAngles = SCNVector3(0, 0, -side * .pi / 2)
            twist.position = SCNVector3(side * 0.05, -0.006, 0)
            twist.eulerAngles.x = .random(in: -0.5...0.5)
            node.addChildNode(twist)
        }
        node.eulerAngles.x = .random(in: -0.15...0.15)
        return node
    }

    /// A puffy chip bag lying flat, with a loud label.
    private static func chips() -> SCNNode {
        let bag = SCNBox(width: 0.13, height: 0.035, length: 0.18, chamferRadius: 0.015)
        bag.chamferSegmentCount = 1
        let label = material(texture: chipLabel())
        bag.materials = [label, label, label, label, label, label]
        let node = SCNNode(geometry: bag)
        node.position.y = 0.017
        node.eulerAngles = SCNVector3(.random(in: -0.1...0.1), 0, .random(in: -0.12...0.12))
        return node
    }

    /// A crumpled ball of paper: a very low-poly sphere, squashed and dented.
    private static func paper() -> SCNNode {
        let ball = SCNSphere(radius: 0.04)
        ball.segmentCount = 5
        ball.materials = [material(texture: crumple())]
        let node = SCNNode(geometry: ball)
        node.scale = SCNVector3(Float.random(in: 0.8...1.2), Float.random(in: 0.7...1), Float.random(in: 0.8...1.2))
        node.position.y = 0.035
        node.eulerAngles = SCNVector3(.random(in: 0...6), .random(in: 0...6), .random(in: 0...6))
        return node
    }

    /// A six-sided plastic bottle lying on its side, with a cap.
    private static func bottle() -> SCNNode {
        let tint = [CGColor(red: 0.45, green: 0.75, blue: 0.95, alpha: 0.75),
                    CGColor(red: 0.4, green: 0.8, blue: 0.45, alpha: 0.75)].randomElement()!
        let body = SCNCylinder(radius: 0.035, height: 0.2)
        body.radialSegmentCount = 6
        body.materials = [material(color: tint, shiny: true)]
        let neck = SCNCone(topRadius: 0.013, bottomRadius: 0.035, height: 0.05)
        neck.radialSegmentCount = 6
        neck.materials = [material(color: tint, shiny: true)]
        let lid = SCNCylinder(radius: 0.014, height: 0.02)
        lid.radialSegmentCount = 6
        lid.materials = [material(color: [CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1),
                                          CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)].randomElement()!, shiny: false)]

        let bottle = SCNNode(geometry: body)
        let top = SCNNode(geometry: neck)
        top.position.y = 0.125
        let cap = SCNNode(geometry: lid)
        cap.position.y = 0.16
        bottle.addChildNode(top)
        bottle.addChildNode(cap)
        bottle.eulerAngles.z = .pi / 2
        bottle.position.y = 0.035
        let node = SCNNode()
        node.addChildNode(bottle)
        return node
    }

    // MARK: - The PS1 look

    /// Corners snap to a coarse grid around the camera, so edges wobble as it moves, and the
    /// final color is cut down to 15-bit, like the PlayStation's output.
    private static let wobble: [SCNShaderModifierEntryPoint: String] = [
        .geometry: """
            float4 viewPosition = scn_node.modelViewTransform * _geometry.position;
            viewPosition.xyz = round(viewPosition.xyz * 70.0) / 70.0;
            _geometry.position = scn_node.inverseModelViewTransform * viewPosition;
            """,
        .fragment: """
            _output.color.rgb = round(_output.color.rgb * 31.0) / 31.0;
            """,
    ]

    static func material(color: CGColor, shiny: Bool) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = shiny ? .blinn : .lambert
        m.diffuse.contents = color
        if shiny {
            m.specular.contents = CGColor(gray: 0.35, alpha: 1)
            m.shininess = 0.8
        }
        if color.alpha < 1 { m.transparency = color.alpha }
        m.shaderModifiers = wobble
        return m
    }

    static func material(texture: CGImage?) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = texture
        m.diffuse.magnificationFilter = .nearest  // big, hard pixels
        m.diffuse.minificationFilter = .nearest
        m.diffuse.mipFilter = .none
        m.shaderModifiers = wobble
        return m
    }

    // MARK: - Pixel-art textures

    private static let brights: [(CGFloat, CGFloat, CGFloat)] = [
        (0.9, 0.1, 0.15), (0.1, 0.45, 0.9), (0.15, 0.75, 0.25), (0.98, 0.8, 0.1),
        (0.95, 0.45, 0.1), (0.6, 0.2, 0.75), (0.95, 0.4, 0.65), (0.1, 0.1, 0.12),
    ]

    static func pixels(_ width: Int, _ height: Int, draw: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setShouldAntialias(false)
        draw(context)
        return context.makeImage()
    }

    static func fill(_ c: CGContext, _ color: (CGFloat, CGFloat, CGFloat), _ rect: CGRect) {
        c.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
        c.fill(rect)
    }

    /// A soda brand: a base color, a contrasting band, and a blocky "logo" of random pixels.
    private static func canLabel() -> CGImage? {
        pixels(32, 16) { c in
            let base = brights.randomElement()!
            var band = brights.randomElement()!
            while band == base { band = brights.randomElement()! }
            fill(c, base, CGRect(x: 0, y: 0, width: 32, height: 16))
            fill(c, band, CGRect(x: 0, y: 5, width: 32, height: 3))
            fill(c, (0.95, 0.95, 0.95), CGRect(x: 0, y: 12, width: 32, height: 1))
            for _ in 0..<14 {  // logo
                fill(c, (1, 1, 1), CGRect(x: Int.random(in: 4...12), y: Int.random(in: 8...11), width: 1, height: 1))
            }
        }
    }

    private static func stripes(width: Int, height: Int) -> CGImage? {
        pixels(width, height) { c in
            let a = brights.randomElement()!, b = brights.randomElement()!
            for x in 0..<width { fill(c, x % 4 < 2 ? a : b, CGRect(x: x, y: 0, width: 1, height: height)) }
            fill(c, (1, 1, 1), CGRect(x: width / 2 - 2, y: height / 2 - 1, width: 4, height: 2))
        }
    }

    private static func chipLabel() -> CGImage? {
        pixels(16, 16) { c in
            let base = brights.randomElement()!
            fill(c, base, CGRect(x: 0, y: 0, width: 16, height: 16))
            fill(c, (0.98, 0.85, 0.2), CGRect(x: 4, y: 5, width: 8, height: 6))  // a chip
            fill(c, (0.85, 0.6, 0.1), CGRect(x: 5, y: 6, width: 2, height: 2))
            fill(c, (1, 1, 1), CGRect(x: 2, y: 12, width: 12, height: 2))       // the brand
        }
    }

    private static func crumple() -> CGImage? {
        pixels(16, 16) { c in
            for y in 0..<16 {
                for x in 0..<16 {
                    let g = CGFloat.random(in: 0.78...0.95)
                    fill(c, (g, g, g * 0.97), CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            for y in stride(from: 3, to: 16, by: 5) { fill(c, (0.6, 0.65, 0.85), CGRect(x: 0, y: y, width: 16, height: 1)) }
        }
    }
}
