import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Vision

/// The heavy version of the Web look, made once when a photo is taken (it takes a moment, so it
/// can't run live). The main subject is turned into a game asset: a simple polygon outline,
/// about a dozen flat colors picked from the object itself, pixel-art resolution, stepped toon
/// shading with ordered dithering, a hard highlight and a dark pixel outline. It's then put back
/// into the real photo, standing on a blob shadow.
enum GameAsset {
    /// Turns the subject of `buffer` into a game asset in the real scene, or returns nil when
    /// there's no clear subject to work on.
    static func make(from buffer: CVPixelBuffer) -> CIImage? {
        let photo = CIImage(cvPixelBuffer: buffer)
        let extent = photo.extent
        guard let found = SubjectFinder.findSubject(in: buffer) else { return nil }
        let mask = fitted(found, to: extent)

        // Everything is worked out at pixel-art resolution: about 200 game pixels across.
        let pixel = max(3, (extent.width / 200).rounded())
        let size = CGSize(width: (extent.width / pixel).rounded(.up), height: (extent.height / pixel).rounded(.up))
        let small = CGRect(origin: .zero, size: size)
        let shrink = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: 1 / pixel, y: 1 / pixel))

        // 1. A simple polygon outline: trace the subject and straighten its edges.
        guard let polygons = outline(of: mask), let shape = fill(polygons, size: size) else { return nil }
        let bounds = polygons.map(\.boundingBox).reduce(CGRect.null) { $0.union($1) }
        let box = CGRect(x: bounds.minX * size.width, y: bounds.minY * size.height,
                         width: bounds.width * size.width, height: bounds.height * size.height).integral

        // 2. The object at pixel-art size, reduced to a few flat colors picked from itself.
        let tiny = photo.transformed(by: shrink).cropped(to: small)
        let clean = CIFilter.median()  // smooth away photo noise and fine detail first
        clean.inputImage = tiny
        let cleaned = (clean.outputImage ?? tiny).cropped(to: small)
        let means = CIFilter.kMeans()
        means.inputImage = vivid(cleaned)
        means.extent = box
        means.count = 12
        means.passes = 8
        means.perceptual = true
        guard let rawPalette = means.outputImage else { return nil }
        let palette = rawPalette.settingAlphaOne(in: rawPalette.extent)
        let palettize = CIFilter.palettize()
        palettize.inputImage = vivid(cleaned)
        palettize.paletteImage = palette
        palettize.perceptual = true
        guard let flat = palettize.outputImage?.cropped(to: small) else { return nil }

        // 3. Toon shading over a rounded version of the shape, dithered, with an outline.
        let roundness = blurred(shape, 0.1 * max(box.width, box.height))
        guard let model = toon?.apply(
            extent: small,
            roiCallback: { _, rect in rect.insetBy(dx: -3, dy: -3) },
            arguments: [flat, roundness, shape]
        ) else { return nil }

        // 4. Back to full size with hard pixel edges, onto the real photo.
        let grow = shrink.inverted()
        let modelFull = model.samplingNearest().transformed(by: grow).cropped(to: extent)
        let shapeFull = shape.samplingNearest().transformed(by: grow).cropped(to: extent)

        // Where the real object stood, a guess of what's behind it, so none of it peeks out.
        let room = blend(behind(photo, mask: mask), over: photo, where: blurred(mask, 4 * pixel))

        // A soft blob shadow under the model, a little down and to the right.
        let shadow = blurred(shapeFull, 10 * pixel)
            .transformed(by: CGAffineTransform(translationX: 2 * pixel, y: -4 * pixel))
        let darken = CIFilter.colorMatrix()
        darken.inputImage = shadow
        let k = CIVector(x: -0.55, y: 0, z: 0, w: 0)
        darken.rVector = k
        darken.gVector = k
        darken.bVector = k
        darken.biasVector = CIVector(x: 1, y: 1, z: 1, w: 1)
        let shade = CIFilter.multiplyCompositing()
        shade.inputImage = darken.outputImage?.cropped(to: extent)
        shade.backgroundImage = room
        let shaded = shade.outputImage ?? room

        return blend(modelFull, over: shaded, where: shapeFull).cropped(to: extent)
    }

    // MARK: - Outline

    /// The subject's outline(s) as simplified polygons, in 0...1 coordinates from the bottom left.
    private static func outline(of mask: CIImage) -> [CGPath]? {
        let request = VNDetectContoursRequest()
        request.detectsDarkOnLight = false  // a white subject on black
        request.contrastAdjustment = 1
        request.maximumImageDimension = 512
        guard (try? VNImageRequestHandler(ciImage: mask).perform([request])) != nil,
              let result = request.results?.first
        else { return nil }

        let shapes = result.topLevelContours.compactMap { contour -> CGPath? in
            let box = contour.normalizedPath.boundingBox
            guard box.width * box.height > 0.004,
                  let simple = try? contour.polygonApproximation(epsilon: 0.02),
                  simple.normalizedPoints.count >= 3
            else { return nil }
            let path = CGMutablePath()
            path.addLines(between: simple.normalizedPoints.map { CGPoint(x: Double($0.x), y: Double($0.y)) })
            path.closeSubpath()
            return path
        }
        return shapes.isEmpty ? nil : shapes
    }

    /// The polygons filled in white on black, at pixel-art size.
    private static func fill(_ polygons: [CGPath], size: CGSize) -> CIImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setShouldAntialias(false)  // hard pixel edges
        context.scaleBy(x: size.width, y: size.height)
        context.setFillColor(gray: 1, alpha: 1)
        for polygon in polygons { context.addPath(polygon) }
        context.fillPath()
        return context.makeImage().map { CIImage(cgImage: $0) }
    }

    // MARK: - Shading

    /// Stepped light from the top left over the rounded shape, blended between steps with a 4x4
    /// ordered dither, a hard highlight band, and a darker pixel outline around the edge.
    private static let toon: CIKernel? = CIKernel(source: """
        kernel vec4 toon(sampler color, sampler dome, sampler shape) {
            vec2 d = destCoord();
            vec3 c = sample(color, samplerTransform(color, d)).rgb;

            float h  = sample(dome, samplerTransform(dome, d)).r;
            float hx = sample(dome, samplerTransform(dome, d + vec2(2.0, 0.0))).r;
            float hy = sample(dome, samplerTransform(dome, d + vec2(0.0, 2.0))).r;
            vec3 n = normalize(vec3((h - hx) * 6.0, (h - hy) * 6.0, 0.2));
            vec3 l = normalize(vec3(-0.5, 0.65, 0.6));
            float light = clamp(0.25 + 0.85 * dot(n, l), 0.0, 1.0);

            // 4x4 ordered dither threshold.
            vec2 q = mod(floor(d), 4.0);
            float bayer = (mod(q.x, 2.0) * 8.0 + mod(q.y, 2.0) * 4.0
                         + floor(q.x / 2.0) * 2.0 + floor(q.y / 2.0)) / 16.0;

            // Four light steps, dithered only in a narrow band where one turns into the next.
            float level = floor(light * 3.0 + (bayer - 0.5) * 0.5);
            float shade = 0.5 + 0.2 * level;

            float r = max(dot(reflect(-l, n), vec3(0.0, 0.0, 1.0)), 0.0);
            float shine = step(0.88, r + (bayer - 0.5) * 0.08);

            vec3 col = c * shade + vec3(0.45) * shine;

            // Dark outline: one game pixel just inside the edge.
            float s = sample(shape, samplerTransform(shape, d)).r;
            float edge = 1.0 - min(min(sample(shape, samplerTransform(shape, d + vec2(1.0, 0.0))).r,
                                       sample(shape, samplerTransform(shape, d - vec2(1.0, 0.0))).r),
                                   min(sample(shape, samplerTransform(shape, d + vec2(0.0, 1.0))).r,
                                       sample(shape, samplerTransform(shape, d - vec2(0.0, 1.0))).r));
            col *= 1.0 - 0.45 * edge * s;
            return vec4(clamp(col, 0.0, 1.0), 1.0);
        }
        """)

    // MARK: - Helpers

    private static func fitted(_ mask: CIImage, to extent: CGRect) -> CIImage {
        mask
            .transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width, y: extent.height / mask.extent.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// More saturated and contrasty, so the picked colors are bold, like a game's.
    private static func vivid(_ image: CIImage) -> CIImage {
        let pop = CIFilter.colorControls()
        pop.inputImage = image
        pop.saturation = 1.3
        pop.contrast = 1.1
        return pop.outputImage ?? image
    }

    private static func blurred(_ image: CIImage, _ radius: Double) -> CIImage {
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image.clampedToExtent()
        blur.radius = Float(radius)
        return (blur.outputImage ?? image).cropped(to: image.extent)
    }

    private static func blend(_ top: CIImage, over background: CIImage, where mask: CIImage) -> CIImage {
        let blend = CIFilter.blendWithMask()
        blend.inputImage = top
        blend.backgroundImage = background
        blend.maskImage = mask
        return blend.outputImage ?? background
    }

    /// A rough guess of what's behind the subject: the surroundings smeared inward to fill it.
    private static func behind(_ image: CIImage, mask: CIImage) -> CIImage {
        let extent = image.extent
        let small = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: 0.25, y: 0.25))
        let picture = image.transformed(by: small)
        let bounds = picture.extent
        let keep = CIFilter.colorInvert()
        keep.inputImage = mask.transformed(by: small)
        let around = (keep.outputImage ?? picture).cropped(to: bounds)
        let cut = CIFilter.multiplyCompositing()
        cut.inputImage = picture
        cut.backgroundImage = around
        func spread(_ image: CIImage?) -> CIImage {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = image?.cropped(to: bounds).clampedToExtent()
            blur.radius = 12
            return (blur.outputImage ?? picture).cropped(to: bounds)
        }
        let floor = CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.02)).cropped(to: bounds)
        let divide = CIFilter.divideBlendMode()
        divide.inputImage = spread(around).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: floor])
        divide.backgroundImage = spread(cut.outputImage)
        return (divide.outputImage ?? picture).transformed(by: small.inverted()).cropped(to: extent)
    }
}
