import CoreImage
import CoreImage.CIFilterBuiltins

/// An everyday object turned into a low-poly 3D model, as if it were dropped into the real world
/// from a video game. The main subject in view is rebuilt from flat triangles, each filled with one
/// of its own colors and lit like a 3D surface, so it looks solid and slightly inflated. The mesh
/// slowly ripples and warps, the object casts a shadow on the real scene behind it, and the real
/// world keeps a little camera grain while the object stays perfectly clean, so it clearly doesn't
/// belong there.
enum WebLook {
    private static let kernel: CIKernel? = CIKernel(source: """
        float hash(vec2 p) {
            return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
        }

        // A corner of the triangle mesh, in grid units. Every corner wanders on its own, and a
        // slow wave runs through the whole mesh, so the shape warps and breathes.
        vec2 corner(vec2 c, float t) {
            float h = hash(c);
            float k = hash(c + 17.3);
            vec2 jitter = 0.3 * vec2(sin(t * 0.7 + 6.2832 * h), cos(t * 0.6 + 6.2832 * k));
            vec2 wave = 0.22 * vec2(sin(c.y * 0.55 + t * 0.9), cos(c.x * 0.5 - t * 0.8));
            return c + jitter + wave;
        }

        // The smallest of the three barycentric weights of p in triangle abc: positive inside,
        // negative outside, and close to zero near an edge.
        float inside(vec2 p, vec2 a, vec2 b, vec2 c) {
            vec2 v0 = b - a;
            vec2 v1 = c - a;
            vec2 v2 = p - a;
            float den = v0.x * v1.y - v1.x * v0.y;
            float v = (v2.x * v1.y - v1.x * v2.y) / den;
            float w = (v0.x * v2.y - v2.x * v0.y) / den;
            return min(min(1.0 - v - w, v), w);
        }

        kernel vec4 lowpoly(sampler src, sampler tone, sampler subject, sampler height, sampler shadow, sampler fill,
                            float size, float t) {
            vec2 d = destCoord();
            vec2 p = d / size;
            vec2 cell = floor(p);

            // Find the triangle of the warped mesh that this pixel falls in: the one where it sits
            // most comfortably inside. Each grid square is split into two triangles.
            float best = -9.0;
            vec2 A = vec2(0.0);
            vec2 B = vec2(0.0);
            vec2 C = vec2(0.0);
            for (int y = -1; y <= 1; y++) {
                for (int x = -1; x <= 1; x++) {
                    vec2 c = cell + vec2(float(x), float(y));
                    vec2 c00 = corner(c, t);
                    vec2 c10 = corner(c + vec2(1.0, 0.0), t);
                    vec2 c01 = corner(c + vec2(0.0, 1.0), t);
                    vec2 c11 = corner(c + vec2(1.0, 1.0), t);
                    float s1 = inside(p, c00, c10, c11);
                    if (s1 > best) { best = s1; A = c00; B = c10; C = c11; }
                    float s2 = inside(p, c00, c11, c01);
                    if (s2 > best) { best = s2; A = c00; B = c11; C = c01; }
                }
            }

            // Does this facet belong to the object? Judge by its center, so the outline is made
            // of whole triangles: a crisp, jagged polygon edge.
            vec2 center = (A + B + C) / 3.0 * size;
            float on = step(0.5, sample(subject, samplerTransform(subject, center)).r);

            // The facet's one color: the object's average color around its center, a little more vivid.
            vec3 base = sample(tone, samplerTransform(tone, center)).rgb;
            float grey = dot(base, vec3(0.299, 0.587, 0.114));
            base = clamp(mix(vec3(grey), base, 1.35), 0.0, 1.0);

            // Light it like a 3D surface: treat the object as a rounded, inflated shape and work
            // out which way this flat facet faces.
            float lift = size * 2.4;
            vec3 a3 = vec3(A * size, lift * sample(height, samplerTransform(height, A * size)).r);
            vec3 b3 = vec3(B * size, lift * sample(height, samplerTransform(height, B * size)).r);
            vec3 c3 = vec3(C * size, lift * sample(height, samplerTransform(height, C * size)).r);
            vec3 n = normalize(cross(b3 - a3, c3 - a3));
            if (n.z < 0.0) { n = -n; }
            vec3 light = normalize(vec3(-0.45, 0.6, 0.75));
            float diffuse = max(dot(n, light), 0.0);
            float spec = pow(max(dot(reflect(-light, n), vec3(0.0, 0.0, 1.0)), 0.0), 18.0);
            vec3 facet = base * (0.32 + 0.9 * diffuse) + vec3(0.3) * spec;

            // Faint bright seams between facets, like an untextured 3D model.
            facet = mix(facet * 1.18 + 0.03, facet, smoothstep(0.0, 0.035, best));

            // The real world: where the object used to be but no facet covers it now, a guess of
            // what's behind it. A touch dimmer than real life, with a soft shadow from the object
            // falling down and to the right, and fine camera grain.
            float wasObject = step(0.5, sample(subject, samplerTransform(subject, d)).r);
            vec3 room = mix(sample(src, samplerTransform(src, d)).rgb,
                            sample(fill, samplerTransform(fill, d)).rgb, wasObject);
            float shade = sample(shadow, samplerTransform(shadow, d + vec2(-0.7, 1.0) * size)).r;
            room *= 0.9 * (1.0 - 0.7 * smoothstep(0.0, 0.7, shade));
            room += (hash(d + floor(t * 24.0) * 13.1) - 0.5) * 0.04;

            return vec4(clamp(mix(room, facet, on), 0.0, 1.0), 1.0);
        }
        """)

    /// `subject` is a mask of the main thing in view (white on it), or nil to let the darker
    /// parts of the scene stand in for it.
    static func apply(to image: CIImage, time: Double, subject: CIImage? = nil) -> CIImage {
        let extent = image.extent
        let scale = extent.width / 1080  // keep the look the same at any resolution
        guard let kernel else { return image }
        let source = image.clampedToExtent()

        // The subject mask, fitted to the frame. With no subject found, the darker parts of the
        // scene stand in for it.
        let mask: CIImage
        if let subject, subject.extent.width > 0 {
            mask = subject
                .transformed(by: CGAffineTransform(translationX: -subject.extent.minX, y: -subject.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: extent.width / subject.extent.width,
                                                   y: extent.height / subject.extent.height))
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        } else {
            let invert = CIFilter.colorMatrix()
            invert.inputImage = blurred(source, 8 * scale)
            let gain = CIVector(x: -0.299 * 4, y: -0.587 * 4, z: -0.114 * 4, w: 0)
            invert.rVector = gain
            invert.gVector = gain
            invert.bVector = gain
            invert.biasVector = CIVector(x: 1.8, y: 1.8, z: 1.8, w: 0)  // (0.45 - brightness) * 4
            let clamp = CIFilter.colorClamp()
            clamp.inputImage = invert.outputImage
            mask = clamp.outputImage ?? source
        }

        let facet = 40 * scale
        return kernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect.insetBy(dx: -3 * facet, dy: -3 * facet) },
            arguments: [
                source,
                blurred(image, 9 * scale),   // each facet's color, averaged over its area
                blurred(mask, 2 * scale),     // crisp, for deciding which facets belong
                blurred(mask, 60 * scale),    // soft and rounded, the object's 3D bulge
                blurred(mask, 22 * scale),    // the shadow it casts
                behind(image, mask: mask, scale: scale),
                Float(facet), Float(time),
            ]
        )?.cropped(to: extent) ?? image
    }

    private static func blurred(_ image: CIImage, _ radius: Double) -> CIImage {
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image.clampedToExtent()
        blur.radius = Float(radius)
        return (blur.outputImage ?? image).clampedToExtent()
    }

    /// A rough guess of what's behind the subject: the surroundings smeared inward to fill the
    /// hole where it stands. Blur the picture with the subject cut out, then divide by how much
    /// of the blur came from real surroundings. Made at quarter size, since it's blurry anyway.
    private static func behind(_ image: CIImage, mask: CIImage, scale: Double) -> CIImage {
        let extent = image.extent
        let small = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: 0.25, y: 0.25))
        let picture = image.transformed(by: small)
        let bounds = picture.extent

        let keep = CIFilter.colorInvert()  // 1 where the surroundings are, 0 on the subject
        keep.inputImage = mask.transformed(by: small)
        let around = (keep.outputImage ?? picture).cropped(to: bounds)

        let cut = CIFilter.multiplyCompositing()
        cut.inputImage = picture
        cut.backgroundImage = around

        func spread(_ image: CIImage?) -> CIImage {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = image?.cropped(to: bounds).clampedToExtent()
            blur.radius = Float(40 * scale)
            return (blur.outputImage ?? picture).cropped(to: bounds)
        }
        let floor = CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.02)).cropped(to: bounds)
        let divide = CIFilter.divideBlendMode()
        divide.inputImage = spread(around).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: floor])
        divide.backgroundImage = spread(cut.outputImage)

        return (divide.outputImage ?? picture)
            .transformed(by: small.inverted())
            .clampedToExtent()
    }
}
