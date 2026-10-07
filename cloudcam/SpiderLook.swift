import CoreGraphics
import CoreImage
import QuartzCore

/// The spider from the nielsthejls.com navigation, sitting on whatever the camera is pointed at.
/// Its body sits on the middle of the subject, and its eight feet are spread evenly round the
/// subject's outline, each gripping its own spot. Each leg is two thin strings (body to knee, knee to foot) with a random shape at the
/// knee and at the foot, drawn so they invert whatever is under them, like the nav over images.
/// The body is the orange accent. Legs are springy, with the same spring as the site, so they
/// pop out and scramble after the subject as it moves.
final class SpiderLook {
    // Same layout and feel as the site's spider (assets/js/app.js).
    private static let hipAngles: [Double] = [34, 68, 112, 148]  // degrees from the heading, front to back
    private static let spring = 0.22
    private static let damping = 0.3
    private static let accent = CIColor(red: 0xE2 / 255.0, green: 0x57 / 255.0, blue: 0x2B / 255.0)

    private enum Shape: CaseIterable {
        case square, squareSmall, squareTiny, circle, up, down
        var scale: Double { self == .squareSmall ? 0.75 : self == .squareTiny ? 0.5 : 1 }
    }

    private struct Leg {
        var angle: Double  // radians from the heading, negative on the left
        var knee = Shape.allCases.randomElement()!
        var foot = Shape.allCases.randomElement()!
        var position = CGPoint.zero
        var velocity = CGVector.zero
        var wobble = Double.random(in: 0...(2 * .pi))
    }

    /// Where the body and feet should be, as fractions of the frame from its bottom left.
    private struct Anchors {
        var body = CGPoint(x: 0.5, y: 0.5)
        var feet: [CGPoint]
    }

    private var legs: [Leg]
    private var body = CGPoint.zero
    private var bodyVelocity = CGVector.zero
    private var started = false
    private var canvas: CGContext?

    private let queue = DispatchQueue(label: "spider-measure", qos: .userInitiated)
    private let lock = NSLock()
    private var anchors: Anchors?
    private var measuredMask: CIImage?
    private let measureContext = CIContext(options: [.workingColorSpace: NSNull()])

    init() {
        legs = [-1.0, 1.0].flatMap { side in
            Self.hipAngles.map { degrees in
                Leg(angle: side * degrees * .pi / 180)
            }
        }
    }

    func apply(to image: CIImage, subject: CIImage?, time: Double) -> CIImage {
        let extent = image.extent
        let scale = extent.width / 1080
        measure(subject)

        // Where everything wants to be. With no subject, the spider rests in the middle with
        // its legs spread.
        let goal = currentAnchors()
        let goalBody = point(goal.body, in: extent)
        if !started {
            started = true
            body = goalBody
            for i in legs.indices { legs[i].position = body }  // legs pop out from the body
        }
        body = settle(body, &bodyVelocity, toward: goalBody)
        for i in legs.indices {
            var target = point(goal.feet[i], in: extent)
            let w = legs[i].wobble + time * 2.3  // a little fidget, like the site's restless legs
            target.x += CGFloat(sin(w) * 3 * scale)
            target.y += CGFloat(cos(w * 1.3) * 3 * scale)
            legs[i].position = settle(legs[i].position, &legs[i].velocity, toward: target)
        }

        // Draw the legs in white, then invert the photo under them.
        guard let strings = drawLegs(size: extent.size, scale: scale)?
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        else { return image }
        let invert = Self.invertUnder?.apply(extent: extent, arguments: [image, strings]) ?? image

        // The orange body on top.
        let side = 22 * scale
        let dot = CIImage(color: Self.accent)
            .cropped(to: CGRect(x: body.x - side / 2, y: body.y - side / 2, width: side, height: side))
        return dot.composited(over: invert).cropped(to: extent)
    }

    /// Inverts the photo wherever the strings are, in screen tones (like CSS invert(1) on the
    /// site), so they read as dark on light surfaces and light on dark ones.
    private static let invertUnder = CIColorKernel(source: """
        kernel vec4 invertUnder(__sample c, __sample m) {
            vec3 screen = pow(clamp(c.rgb, 0.0, 1.0), vec3(1.0 / 2.2));
            vec3 inverted = pow(1.0 - screen, vec3(2.2));
            return vec4(mix(c.rgb, inverted, m.a), c.a);
        }
        """)

    // MARK: - Motion

    /// One tick of the site's leg spring: pulled toward the goal, with springy damping.
    private func settle(_ p: CGPoint, _ v: inout CGVector, toward goal: CGPoint) -> CGPoint {
        v.dx = v.dx * (1 - Self.damping) + (goal.x - p.x) * Self.spring
        v.dy = v.dy * (1 - Self.damping) + (goal.y - p.y) * Self.spring
        return CGPoint(x: p.x + v.dx, y: p.y + v.dy)
    }

    /// Two-segment leg from the body to the foot.
    private func knee(of leg: Leg) -> CGPoint {
        let dx = leg.position.x - body.x, dy = leg.position.y - body.y
        let d = max(hypot(dx, dy), 1)
        let total = d * 1.3  // longer than the reach, so the knee always bends
        let upper = total * 78 / 174, lower = total * 96 / 174
        let a = acos(min(max((upper * upper + d * d - lower * lower) / (2 * upper * d), -1), 1))
        let base = atan2(dy, dx)
        let k1 = CGPoint(x: body.x + cos(base + a) * upper, y: body.y + sin(base + a) * upper)
        let k2 = CGPoint(x: body.x + cos(base - a) * upper, y: body.y + sin(base - a) * upper)
        // Knees bend outward, to the leg's own side, so the legs arch like a spider's.
        let side: CGFloat = leg.angle < 0 ? -1 : 1
        return (k1.x - body.x) * side > (k2.x - body.x) * side ? k1 : k2
    }

    // MARK: - Drawing

    private func drawLegs(size: CGSize, scale: Double) -> CIImage? {
        let width = Int(size.width), height = Int(size.height)
        if canvas?.width != width || canvas?.height != height {
            canvas = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        }
        guard let context = canvas else { return nil }
        context.clear(CGRect(origin: .zero, size: size))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(2.5 * scale)
        context.setLineJoin(.miter)

        let slot = 16 * scale
        for leg in legs {
            let k = knee(of: leg)
            context.move(to: body)
            context.addLine(to: k)
            context.addLine(to: leg.position)
            context.strokePath()
            // Shapes grow to full size as the leg gets away from the body, like on the site.
            let grown = min(hypot(leg.position.x - body.x, leg.position.y - body.y) / (36 * scale), 1)
            draw(leg.knee, at: k, size: slot * 0.75 * grown, in: context)
            draw(leg.foot, at: leg.position, size: slot * grown, in: context)
        }
        return context.makeImage().map { CIImage(cgImage: $0) }
    }

    private func draw(_ shape: Shape, at p: CGPoint, size: Double, in context: CGContext) {
        let a = (size * shape.scale).rounded()
        let h = a / 2
        switch shape {
        case .square, .squareSmall, .squareTiny:
            context.fill(CGRect(x: p.x - h, y: p.y - h, width: a, height: a))
        case .circle:
            context.fillEllipse(in: CGRect(x: p.x - h, y: p.y - h, width: a, height: a))
        case .up, .down:  // the drawing's y runs up the frame
            let tip = shape == .up ? h : -h
            context.move(to: CGPoint(x: p.x, y: p.y + tip))
            context.addLine(to: CGPoint(x: p.x + h, y: p.y - tip))
            context.addLine(to: CGPoint(x: p.x - h, y: p.y - tip))
            context.closePath()
            context.fillPath()
        }
    }

    // MARK: - Finding footholds

    private func point(_ p: CGPoint, in extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + p.x * extent.width, y: extent.minY + p.y * extent.height)
    }

    private func currentAnchors() -> Anchors {
        lock.lock()
        defer { lock.unlock() }
        return anchors ?? resting()
    }

    /// No subject: legs spread evenly around the middle of the frame.
    private func resting() -> Anchors {
        Anchors(feet: legs.map { leg in
            let a = .pi / 2 - leg.angle
            return CGPoint(x: 0.5 + cos(a) * 0.3, y: 0.5 + sin(a) * 0.3 * 9 / 16)
        })
    }

    /// Whenever a new subject mask arrives, work out the footholds in the background: the
    /// middle of the subject, and where a line from there at each leg's angle leaves it.
    private func measure(_ mask: CIImage?) {
        guard mask !== measuredMask else { return }
        measuredMask = mask
        guard let mask else {
            lock.lock(); anchors = nil; lock.unlock()
            return
        }
        let angles = legs.map(\.angle)
        queue.async { [self] in
            let found = Self.footholds(in: mask, angles: angles, context: measureContext)
            lock.lock(); anchors = found; lock.unlock()
        }
    }

    private static func footholds(in mask: CIImage, angles: [Double], context: CIContext) -> Anchors? {
        let width = 72, height = 128
        let small = mask
            .transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: Double(width) / mask.extent.width,
                                               y: Double(height) / mask.extent.height))
        var pixels = [UInt8](repeating: 0, count: width * height)
        context.render(small, toBitmap: &pixels, rowBytes: width, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .L8, colorSpace: nil)
        // The bitmap's first row is the top of the picture; y here runs up, like Core Image.
        func on(_ col: Int, _ y: Int) -> Bool { pixels[(height - 1 - y) * width + col] > 127 }
        func inside(_ x: Double, _ y: Double) -> Bool {
            let col = Int(x), row = Int(y)
            guard col >= 0, col < width, row >= 0, row < height else { return false }
            return on(col, row)
        }

        var sumX = 0.0, sumY = 0.0, count = 0.0
        for row in 0..<height {
            for col in 0..<width where on(col, row) {
                sumX += Double(col) + 0.5; sumY += Double(row) + 0.5; count += 1
            }
        }
        guard count > 20 else { return nil }
        let cx = sumX / count, cy = sumY / count

        // Every point on the subject's outline, ordered around the middle, starting straight
        // below it and going round through the left, the top and the right.
        var edge: [(angle: Double, x: Double, y: Double)] = []
        for row in 0..<height {
            for col in 0..<width where on(col, row) {
                let outside = !inside(Double(col - 1), Double(row)) || !inside(Double(col + 1), Double(row))
                    || !inside(Double(col), Double(row - 1)) || !inside(Double(col), Double(row + 1))
                guard outside else { continue }
                let x = Double(col) + 0.5, y = Double(row) + 0.5
                edge.append((atan2(x - cx, y - cy), x, y))  // 0 is straight up, positive to the right
            }
        }
        edge.sort { $0.angle < $1.angle }
        guard edge.count >= angles.count else { return nil }

        // Walk round the outline and drop the feet at even distances along it, so every leg
        // grips its own spot and the spider spreads over the whole shape. Legs are handed out
        // in the same order round the body, so none cross.
        var along = [0.0]
        for i in 1..<edge.count {
            along.append(along[i - 1] + hypot(edge[i].x - edge[i - 1].x, edge[i].y - edge[i - 1].y))
        }
        let total = along.last! + hypot(edge[0].x - edge.last!.x, edge[0].y - edge.last!.y)
        let order = angles.indices.sorted { angles[$0] < angles[$1] }
        var feet = [CGPoint](repeating: .zero, count: angles.count)
        var j = 0
        for (rank, leg) in order.enumerated() {
            let goal = total * (Double(rank) + 0.5) / Double(angles.count)
            while j < along.count - 1 && along[j] < goal { j += 1 }
            feet[leg] = CGPoint(x: edge[j].x / Double(width), y: edge[j].y / Double(height))
        }
        return Anchors(body: CGPoint(x: cx / Double(width), y: cy / Double(height)), feet: feet)
    }
}
