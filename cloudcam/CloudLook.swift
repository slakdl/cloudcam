import CoreImage
import CoreImage.CIFilterBuiltins

/// A castle in the sky. The darker parts of the scene dissolve into a deep blue sky that
/// pales into haze toward the bottom, while anything bright turns into glowing white, as if
/// made of cloud and light. The brightest points throw four-pointed sparkles, everything
/// glows softly, and a fine grain sits over it all like an old print. When the camera
/// spots a cloud, a rainbow arches behind it.
enum CloudLook {
    /// The looks the app can switch between.
    enum Mode: String, CaseIterable, Identifiable {
        case cloud = "Cloud"
        case pixel = "Pixel"
        case web = "Web"

        var id: String { rawValue }
    }

    /// A rainbow to draw behind a spotted cloud. `center` and `size` are fractions of the
    /// frame from its bottom-left corner; `strength` fades it in and out (0 to 1).
    struct Rainbow {
        var center = CGPoint(x: 0.5, y: 0.7)
        var size = 0.3
        var strength = 0.0
    }

    /// Runs on the GPU for every pixel: decides how much of this spot becomes sky and how
    /// much becomes white light, keeping the scene's own shading so shapes stay readable.
    private static let kernel: CIColorKernel? = CIColorKernel(source: """
        kernel vec4 heaven(__sample c, __sample average, float bottom, float height, vec2 cloud, float radius, float strength) {
            float l = dot(c.rgb, vec3(0.299, 0.587, 0.114));

            // What counts as "bright" depends on the scene: anything clearly brighter than
            // the average turns to light, so it works in a dim room as well as outdoors.
            float a = dot(average.rgb, vec3(0.299, 0.587, 0.114));
            float lo = clamp(a + 0.04, 0.06, 0.6);
            float y = clamp((destCoord().y - bottom) / height, 0.0, 1.0);

            // The sky: deep blue at the top, softer blue in the middle, pale haze at the bottom.
            vec3 top  = vec3(0.09, 0.32, 0.74);
            vec3 mid  = vec3(0.30, 0.55, 0.88);
            vec3 haze = vec3(0.80, 0.85, 0.93);
            vec3 sky = mix(mid, top, smoothstep(0.35, 1.0, y));
            sky = mix(haze, sky, smoothstep(0.0, 0.32, y));
            sky *= 0.82 + 0.35 * clamp(l / max(2.0 * a, 0.05), 0.0, 1.0);  // a ghost of the scene's shading stays in the sky

            // Bright things become white light, shaded a cool grey where they turn away.
            vec3 white = mix(vec3(0.70, 0.77, 0.90), vec3(1.0), smoothstep(lo + 0.05, min(lo + 0.5, 1.0), l));
            float glowing = smoothstep(lo, lo + 0.3, l);

            vec3 col = mix(sky, white, glowing);

            // The rainbow: an arc whose top passes right behind the cloud. Red on the outside,
            // violet on the inside, its feet fading into the air, and hidden wherever
            // something glows white, so the cloud sits in front of it.
            vec2 center = cloud - vec2(0.0, 0.8 * radius);
            float u = (length(destCoord() - center) - radius) / (0.14 * radius);
            float hue = (0.5 - u) * 0.78;
            vec3 spectrum = clamp(abs(fract(hue + vec3(0.0, 0.6667, 0.3333)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
            float band = smoothstep(0.62, 0.3, abs(u));
            float feet = smoothstep(center.y + 0.05 * radius, center.y + 0.5 * radius, destCoord().y);
            float bow = band * feet * strength * 0.9 * (1.0 - glowing);
            // Lay it on like light, then pull the color toward the pure spectrum so it
            // stays vivid against the pale sky.
            col = 1.0 - (1.0 - col) * (1.0 - spectrum * bow);
            col = mix(col, col * (0.55 + 0.6 * spectrum), bow * 0.6);
            return vec4(col, 1.0);
        }
        """)

    static func apply(to image: CIImage, time: Double, rainbow: Rainbow = Rainbow()) -> CIImage {
        let extent = image.extent
        let scale = extent.width / 1080  // keep the look the same at any resolution
        guard let kernel else { return image }

        // 1. Soften the picture a touch, like the dreamy focus of the reference.
        let soften = CIFilter.gaussianBlur()
        soften.inputImage = image.clampedToExtent()
        soften.radius = Float(1.5 * scale)
        let soft = (soften.outputImage ?? image).cropped(to: extent)

        // 2. Sky and white light, judged against the scene's average brightness.
        let mean = CIFilter.areaAverage()
        mean.inputImage = soft
        mean.extent = extent
        let average = (mean.outputImage ?? CIImage(color: .gray)).clampedToExtent()

        var frame = kernel.apply(
            extent: extent,
            arguments: [
                soft, average, Float(extent.minY), Float(extent.height),
                CIVector(x: extent.minX + rainbow.center.x * extent.width, y: extent.minY + rainbow.center.y * extent.height),
                Float(max(rainbow.size * 0.75, 0.42) * extent.width),
                Float(rainbow.strength),
            ]
        ) ?? image

        // 3. Sparkles: the brightest points throw thin horizontal and vertical rays.
        frame = addSparkles(to: frame, from: soft, scale: scale)

        // 4. A soft glow around everything white.
        let glow = CIFilter.bloom()
        glow.inputImage = frame.clampedToExtent()
        glow.radius = Float(18 * scale)
        glow.intensity = 0.55
        frame = (glow.outputImage ?? frame).cropped(to: extent)

        // 5. Fine grain, re-rolled every frame so it shimmers like film.
        return addGrain(to: frame, time: time).cropped(to: extent)
    }

    // MARK: - Building blocks

    private static func addSparkles(to image: CIImage, from source: CIImage, scale: Double) -> CIImage {
        let extent = image.extent
        let small = 0.25  // rays are soft, so make them at quarter size

        // Only the very brightest spots: (brightness - 0.85) * 7, clamped.
        let isolate = CIFilter.colorMatrix()
        isolate.inputImage = source
        let gain = CIVector(x: 0.299 * 7, y: 0.587 * 7, z: 0.114 * 7, w: 0)
        isolate.rVector = gain
        isolate.gVector = gain
        isolate.bVector = gain
        isolate.biasVector = CIVector(x: -5.95, y: -5.95, z: -5.95, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = isolate.outputImage
        let bright = (clamp.outputImage ?? source).cropped(to: extent)

        // Keep only small bright points (tips, glints, lamps), not whole bright areas: take
        // away a blurred copy, so only spots brighter than their surroundings are left.
        let spread = CIFilter.gaussianBlur()
        spread.inputImage = bright.clampedToExtent()
        spread.radius = Float(10 * scale)
        let peaks = CIFilter.subtractBlendMode()
        peaks.inputImage = spread.outputImage?.cropped(to: extent)
        peaks.backgroundImage = bright
        let points = (peaks.outputImage ?? bright)
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: small, y: small))
        let bounds = CGRect(x: 0, y: 0, width: extent.width * small, height: extent.height * small)

        func ray(angle: Double, length: Double, strength: Double) -> CIImage {
            let blur = CIFilter.motionBlur()
            blur.inputImage = points.clampedToExtent()
            blur.radius = Float(length * scale)
            blur.angle = Float(angle)
            let boost = CIFilter.colorMatrix()
            boost.inputImage = blur.outputImage
            boost.rVector = CIVector(x: strength, y: 0, z: 0, w: 0)
            boost.gVector = CIVector(x: 0, y: strength, z: 0, w: 0)
            boost.bVector = CIVector(x: 0, y: 0, z: strength, w: 0)
            return (boost.outputImage ?? points).cropped(to: bounds)
        }

        let rays = screen(
            screen(ray(angle: 0, length: 45, strength: 4), ray(angle: .pi / 2, length: 60, strength: 4)),
            ray(angle: .pi / 4, length: 14, strength: 2)
        )
        .transformed(by: CGAffineTransform(scaleX: 1 / small, y: 1 / small))
        .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))

        return screen(rays, image).cropped(to: extent)
    }

    private static func addGrain(to image: CIImage, time: Double) -> CIImage {
        guard let noise = CIFilter.randomGenerator().outputImage else { return image }

        // Grey noise squeezed into a narrow band around mid-grey: under soft light,
        // mid-grey changes nothing, so only the speckle shows.
        let jump = (time * 24).rounded(.down) * 97
        let grey = CIFilter.colorMatrix()
        grey.inputImage = noise
            .transformed(by: CGAffineTransform(translationX: jump.truncatingRemainder(dividingBy: 3000), y: 0))
            .composited(over: CIImage(color: .black))
        let amount = 0.32
        let r = CIVector(x: amount, y: 0, z: 0, w: 0)
        grey.rVector = r
        grey.gVector = r
        grey.bVector = r
        grey.biasVector = CIVector(x: 0.5 - amount / 2, y: 0.5 - amount / 2, z: 0.5 - amount / 2, w: 0)

        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = grey.outputImage?.cropped(to: image.extent)
        blend.backgroundImage = image
        return blend.outputImage ?? image
    }

    private static func screen(_ top: CIImage, _ bottom: CIImage) -> CIImage {
        let filter = CIFilter.screenBlendMode()
        filter.inputImage = top
        filter.backgroundImage = bottom
        return filter.outputImage ?? bottom
    }
}
