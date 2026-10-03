import CoreImage
import CoreImage.CIFilterBuiltins

/// An everyday object, turned into something alive while it sits in the real world. The
/// main subject in view is hollowed out into a lattice of glossy, sinewy strands made of its own
/// colors, and those strands don't stop at its outline: they bleed out and creep into the room
/// as tendrils. The space around it bends toward it and darkens, as if it pulls in the light.
/// The cells drift slowly, so it seems to breathe and grow.
enum WebLook {
    private static let kernel: CIKernel? = CIKernel(source: """
        float hash(vec2 p) {
            return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
        }

        // Distance to the nearest cell wall in a web of wobbling cells (Voronoi F2 - F1).
        float wall(vec2 p, float t) {
            vec2 cell = floor(p);
            float f1 = 9.0;
            float f2 = 9.0;
            for (int y = -1; y <= 1; y++) {
                for (int x = -1; x <= 1; x++) {
                    vec2 c = cell + vec2(float(x), float(y));
                    float h = hash(c);
                    float k = hash(c + 17.3);
                    vec2 point = c + 0.5 + 0.38 * vec2(sin(t * 0.35 + 6.2832 * h), cos(t * 0.29 + 6.2832 * k));
                    float d = length(p - point);
                    if (d < f1) { f2 = f1; f1 = d; } else if (d < f2) { f2 = d; }
                }
            }
            return f2 - f1;
        }

        // Smooth random hills, for bending, staining and fraying.
        float noise(vec2 p) {
            vec2 i = floor(p);
            vec2 f = fract(p);
            f = f * f * (3.0 - 2.0 * f);
            float a = hash(i);
            float b = hash(i + vec2(1.0, 0.0));
            float c = hash(i + vec2(0.0, 1.0));
            float e = hash(i + vec2(1.0, 1.0));
            return mix(mix(a, b, f.x), mix(c, e, f.x), f.y);
        }

        float fbm(vec2 p) {
            return 0.5 * noise(p) + 0.3 * noise(p * 2.1 + 3.7) + 0.2 * noise(p * 4.3 + 8.1);
        }

        kernel vec4 web(sampler src, sampler soft, sampler subject, sampler halo, sampler fill,
                        sampler aura, float size, float t, float px) {
            vec2 d = destCoord();
            vec3 w = vec3(0.299, 0.587, 0.114);
            float frame = floor(t * 24.0);

            // How close we are to the subject: 1 on it, fading out over the room around it.
            float reach = sample(halo, samplerTransform(halo, d)).r;
            float hx = sample(halo, samplerTransform(halo, d + vec2(px * 6.0, 0.0))).r;
            float hy = sample(halo, samplerTransform(halo, d + vec2(0.0, px * 6.0))).r;
            vec2 toward = vec2(hx - reach, hy - reach);  // points toward the subject
            toward = toward / max(length(toward), 0.0001);

            // The world bends only near the subject, twisting harder the closer it gets.
            vec2 q = d / (size * 2.2);
            vec2 bend = vec2(fbm(q + vec2(0.0, t * 0.06)), fbm(q + vec2(5.2, -t * 0.05))) - 0.5;
            float pull = smoothstep(0.02, 0.6, reach);
            vec2 at = d + bend * size * 1.3 * pull;

            float m = sample(subject, samplerTransform(subject, at)).r;
            float l  = dot(sample(soft, samplerTransform(soft, at)).rgb, w);
            float lx = dot(sample(soft, samplerTransform(soft, at + vec2(px, 0.0))).rgb, w);
            float ly = dot(sample(soft, samplerTransform(soft, at + vec2(0.0, px))).rgb, w);
            float dark = 1.0 - l;
            float fray = (noise(d / 3.0 + frame) - 0.5) * 0.04 + (noise(d / 14.0) - 0.5) * 0.07;
            float inside = smoothstep(0.3, 0.7, m + fray * 2.0);

            // Leaning, stretched cells, warped by the same current.
            vec2 p = at / size;
            p = vec2(0.8 * p.x + 0.35 * p.y, 0.55 * p.y);
            p += 0.9 * (vec2(fbm(p * 0.7 + t * 0.03), fbm(p * 0.7 + 9.1 - t * 0.03)) - 0.5);

            // Each strand as a profile: 1 along its spine, falling to 0 at its edge, so it can
            // be shaded like something round and physical.
            float cellsW = mix(0.08, 0.2, dark);
            float cells = clamp(1.0 - (wall(p, t) + fray) / cellsW, 0.0, 1.0);
            float level = fract(l * 6.0 + reach * 2.5 + fray * 1.2 - t * 0.04);
            float wrapW = mix(0.06, 0.16, dark);
            float wrap = clamp(1.0 - min(level, 1.0 - level) / wrapW, 0.0, 1.0);
            float knot = clamp(1.0 - (wall(p * 3.1 + 7.0, t * 1.3) + fray) / 0.09, 0.0, 1.0)
                       * (1.0 - smoothstep(0.6, 0.95, m));
            float rim = clamp(1.0 - abs(m + fray * 2.0 - 0.5) / 0.16, 0.0, 1.0);
            float body = inside * max(max(cells, wrap), knot);
            body = max(body, rim);

            // Tendrils extruding from the subject into the room, thinning as they reach out.
            float tw = mix(0.0, 0.2, smoothstep(0.02, 0.65, reach));
            float tendril = clamp(1.0 - (wall(p * 0.5 + 3.0, t * 0.7) + fray) / max(tw, 0.0001), 0.0, 1.0);
            tendril *= step(0.0001, tw) * (1.0 - inside);
            float strand = max(body, tendril);
            float cover = smoothstep(0.0, 0.22, strand);

            // What the strands are made of: the subject's own colors, dragged outward along the
            // tendrils, darkened and made glossy, like wet sinew.
            // On the subject that's its own color right there; out in the room it's the subject's
            // colors spread outward (the aura), so the tendrils carry its flesh with them.
            vec3 own = sample(src, samplerTransform(src, at)).rgb;
            vec3 spread = sample(aura, samplerTransform(aura, d)).rgb;
            vec3 flesh = mix(spread, own, inside);
            float shade = sqrt(strand);
            float shine = pow(strand, 10.0);
            vec3 material = flesh * mix(0.12 + 0.45 * shade, 0.18 + 0.6 * shade, inside) * mix(vec3(0.75, 0.55, 0.5), vec3(1.0), inside)
                           + vec3(0.85, 0.82, 0.8) * shine * 0.35;

            // Behind the strands: outside, the real room (bent near the subject); inside, the
            // hollowed object, showing a guess of what's behind it, stained with its own color.
            vec3 room = sample(src, samplerTransform(src, at)).rgb;
            vec3 behind = sample(fill, samplerTransform(fill, d)).rgb;
            vec3 cavity = mix(behind, flesh * 0.35, 0.4);
            vec3 base = mix(room, cavity, inside);

            // The room darkens around the subject, as if it casts a shadow and soaks up light.
            base *= 1.0 - 0.6 * smoothstep(0.02, 0.6, reach) * (1.0 - inside);

            // Tendrils cast a soft shadow onto the room beside them, so they sit on its surfaces.
            float shadowSide = clamp(1.0 - (wall(p * 0.5 + 3.0 + vec2(0.035, -0.05), t * 0.7) + fray)
                                     / max(tw * 1.6, 0.0001), 0.0, 1.0) * step(0.0001, tw) * (1.0 - inside);
            base *= 1.0 - 0.5 * smoothstep(0.0, 0.5, shadowSide);

            vec3 col = mix(base, material, cover);

            // A light camera grain over everything, so it all sits in one photo.
            col += (hash(d + frame * 13.1) - 0.5) * 0.035;
            return vec4(clamp(col, 0.0, 1.0), 1.0);
        }
        """)

    /// `subject` is a mask of the main thing in view (white on it), or nil to let the darker
    /// parts of the scene stand in for it.
    static func apply(to image: CIImage, time: Double, subject: CIImage? = nil) -> CIImage {
        let extent = image.extent
        let scale = extent.width / 1080  // keep the look the same at any resolution
        guard let kernel else { return image }
        let source = image.clampedToExtent()

        // A softened, evened-out copy for reading the subject's light and dark, so a dim room
        // spreads across the same range of thick-to-thin strands as a bright day.
        let soften = CIFilter.gaussianBlur()
        soften.inputImage = source
        soften.radius = Float(6 * scale)
        let balance = CIFilter.colorControls()
        balance.inputImage = soften.outputImage
        balance.saturation = 0
        balance.contrast = 1.25
        let mean = CIFilter.areaAverage()
        mean.inputImage = image
        mean.extent = extent
        let average = mean.outputImage.flatMap { averageBrightness(of: $0) } ?? 0.5
        let shift = CIFilter.exposureAdjust()
        shift.inputImage = balance.outputImage
        shift.ev = Float(log2(0.5 / max(average, 0.04)))
        let soft = (shift.outputImage ?? image).clampedToExtent()

        // The subject mask, fitted to the frame. With no subject found, the darker parts of the
        // scene stand in for it.
        let rawMask: CIImage
        if let subject, subject.extent.width > 0 {
            rawMask = subject
                .transformed(by: CGAffineTransform(translationX: -subject.extent.minX, y: -subject.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: extent.width / subject.extent.width,
                                                   y: extent.height / subject.extent.height))
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        } else {
            let invert = CIFilter.colorMatrix()
            invert.inputImage = soft
            let gain = CIVector(x: -0.299 * 4, y: -0.587 * 4, z: -0.114 * 4, w: 0)
            invert.rVector = gain
            invert.gVector = gain
            invert.bVector = gain
            invert.biasVector = CIVector(x: 2.5, y: 2.5, z: 2.5, w: 0)  // (0.625 - brightness) * 4
            let clamp = CIFilter.colorClamp()
            clamp.inputImage = invert.outputImage
            rawMask = clamp.outputImage ?? soft
        }
        func blurred(_ image: CIImage, _ radius: Double) -> CIImage {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = image.clampedToExtent()
            blur.radius = Float(radius * scale)
            return (blur.outputImage ?? image).clampedToExtent()
        }

        return kernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect.insetBy(dx: -200 * scale, dy: -200 * scale) },
            arguments: [source, soft, blurred(rawMask, 5), blurred(rawMask, 150), behind(image, mask: rawMask, scale: scale),
                        aura(image, mask: rawMask, scale: scale),
                        Float(70 * scale), Float(time), Float(3 * scale)]
        )?.cropped(to: extent) ?? image
    }

    /// A rough guess of what's behind the subject: the surroundings smeared inward to fill the
    /// hole where it stands.
    private static func behind(_ image: CIImage, mask: CIImage, scale: Double) -> CIImage {
        let keep = CIFilter.colorInvert()  // 1 where the surroundings are, 0 on the subject
        keep.inputImage = mask
        return spreadOut(image, from: keep.outputImage ?? mask, radius: 40 * scale)
    }

    /// The subject's colors spread outward into the room, for the tendrils to carry.
    private static func aura(_ image: CIImage, mask: CIImage, scale: Double) -> CIImage {
        spreadOut(image, from: mask, radius: 70 * scale)
    }

    /// Smears the parts of `image` where `weight` is white over everything else: blur the
    /// picture with the rest cut out, then divide by how much of the blur came from the kept
    /// part. Made at quarter size, since it's blurry anyway.
    private static func spreadOut(_ image: CIImage, from weight: CIImage, radius: Double) -> CIImage {
        let extent = image.extent
        let small = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: 0.25, y: 0.25))
        let picture = image.transformed(by: small)
        let bounds = picture.extent
        let kept = weight.transformed(by: small).cropped(to: bounds)

        let cut = CIFilter.multiplyCompositing()
        cut.inputImage = picture
        cut.backgroundImage = kept

        func blur(_ image: CIImage?) -> CIImage {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = image?.cropped(to: bounds).clampedToExtent()
            blur.radius = Float(radius)
            return (blur.outputImage ?? picture).cropped(to: bounds)
        }
        let floor = CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.02)).cropped(to: bounds)
        let divide = CIFilter.divideBlendMode()
        divide.inputImage = blur(kept).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: floor])
        divide.backgroundImage = blur(cut.outputImage)

        return (divide.outputImage ?? picture)
            .transformed(by: small.inverted())
            .clampedToExtent()
    }

    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// Reads back the single averaged pixel. Cheap: it's one pixel.
    private static func averageBrightness(of pixel: CIImage) -> Double? {
        var rgba = [UInt8](repeating: 0, count: 4)
        context.render(pixel, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: pixel.extent.minX, y: pixel.extent.minY, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        return (0.299 * Double(rgba[0]) + 0.587 * Double(rgba[1]) + 0.114 * Double(rgba[2])) / 255
    }
}
