import CoreImage
import CoreImage.CIFilterBuiltins

/// An everyday object turned into a prop from an old N64 or PS1 game, sitting in the real world.
/// The main subject in view is rebuilt as a chunky, inflated low-poly model: a coarse polygon
/// outline, soft shading interpolated across each polygon with a big glossy plastic highlight,
/// a blurry low-resolution texture made from its own colors, chunky pixels with 15-bit color
/// and dithering, and a dark blob shadow underneath. The room around it stays a normal photo.
enum WebLook {
    private static let kernel: CIKernel? = CIKernel(source: """
        float hash(vec2 p) {
            return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
        }

        // A corner of the polygon mesh, in grid units, bobbing very slightly.
        vec2 corner(vec2 c, float t) {
            float h = hash(c);
            return c + 0.06 * vec2(sin(t * 0.8 + 6.2832 * h), cos(t * 0.7 + 6.2832 * h));
        }

        // Barycentric weights of p in triangle abc (all positive when p is inside).
        vec3 bary(vec2 p, vec2 a, vec2 b, vec2 c) {
            vec2 v0 = b - a;
            vec2 v1 = c - a;
            vec2 v2 = p - a;
            float den = v0.x * v1.y - v1.x * v0.y;
            float v = (v2.x * v1.y - v1.x * v2.y) / den;
            float w = (v0.x * v2.y - v2.x * v0.y) / den;
            return vec3(1.0 - v - w, v, w);
        }

        // Which way the inflated model faces at one of its corners, from how its height slopes.
        vec3 normalAt(sampler height, vec2 at, float reach) {
            float h  = sample(height, samplerTransform(height, at)).r;
            float hx = sample(height, samplerTransform(height, at + vec2(reach, 0.0))).r;
            float hy = sample(height, samplerTransform(height, at + vec2(0.0, reach))).r;
            return vec3((h - hx) * 5.0, (h - hy) * 5.0, 0.12);
        }

        kernel vec4 retro(sampler src, sampler texture, sampler subject, sampler height, sampler shadow,
                          sampler fill, float size, float t, float pixel) {
            vec2 real = destCoord();

            // The model is drawn at a low resolution: chunky pixels.
            vec2 d = (floor(real / pixel) + 0.5) * pixel;
            vec2 p = d / size;
            vec2 cell = floor(p);

            // Which polygon of the coarse mesh is this pixel in? Each grid square is two triangles.
            vec2 A = corner(cell, t);
            vec2 B = corner(cell + vec2(1.0, 0.0), t);
            vec2 C = corner(cell + vec2(1.0, 1.0), t);
            vec2 D = corner(cell + vec2(0.0, 1.0), t);
            vec3 w = bary(p, A, B, C);
            if (min(min(w.x, w.y), w.z) < 0.0) {
                B = C;
                C = D;
                w = bary(p, A, B, C);
            }

            // The model's outline: how much each corner is on the subject, blended across the
            // polygon and cut at the halfway point. That gives straight edges cutting across the
            // polygons, the clean but angular outline of a low-detail game model.
            float ma = sample(subject, samplerTransform(subject, A * size)).r;
            float mb = sample(subject, samplerTransform(subject, B * size)).r;
            float mc = sample(subject, samplerTransform(subject, C * size)).r;
            float on = step(0.5, dot(w, vec3(ma, mb, mc)));

            // Blend the corners' directions across the polygon and light that: soft wrap-around
            // light from the top left, a big glossy plastic highlight, darker toward the edges.
            float reach = size * 0.35;
            vec3 n = normalize(normalAt(height, A * size, reach) * w.x
                             + normalAt(height, B * size, reach) * w.y
                             + normalAt(height, C * size, reach) * w.z);
            float h = sample(height, samplerTransform(height, d)).r;
            vec3 l = normalize(vec3(-0.5, 0.65, 0.6));
            float diffuse = max(0.2 + 0.8 * dot(n, l), 0.0) * mix(0.35, 1.0, smoothstep(0.45, 0.8, h));
            float r = max(dot(reflect(-l, n), vec3(0.0, 0.0, 1.0)), 0.0);
            float spec = 0.35 * pow(r, 5.0) + 0.8 * pow(r, 40.0);

            // A blurry, low-resolution texture of the object's own colors, punched up.
            vec3 tex = sample(texture, samplerTransform(texture, d)).rgb;
            float grey = dot(tex, vec3(0.299, 0.587, 0.114));
            tex = clamp(mix(vec3(grey), tex, 1.5) * 1.1, 0.0, 1.0);

            vec3 model = tex * (0.25 + 1.1 * diffuse) + vec3(spec);

            // 15-bit color with a little ordered dithering, like an old console's output.
            float bayer = mod(floor(d.x / pixel), 2.0) * 0.5 + mod(floor(d.y / pixel), 2.0) * 0.25;
            // Done in screen tones, so the steps are even and the darks don't crush.
            model = pow(clamp(model, 0.0, 1.0), vec3(1.0 / 2.2));
            model = floor(model * 31.0 + bayer) / 31.0;
            model = pow(model, vec3(2.2));

            // The real world: where the object used to be but the model doesn't cover it, a guess
            // of what's behind it. Under the model, a dark blob shadow on the ground.
            float wasObject = step(0.5, sample(subject, samplerTransform(subject, real)).r);
            vec3 room = mix(sample(src, samplerTransform(src, real)).rgb,
                            sample(fill, samplerTransform(fill, real)).rgb, wasObject);
            float blob = sample(shadow, samplerTransform(shadow, real + vec2(-0.25, 0.6) * size)).r;
            room *= 1.0 - 0.6 * smoothstep(0.2, 0.6, blob);

            return vec4(mix(room, model, on), 1.0);
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

        // The object's colors as a tiny texture, smoothly stretched back up: blurry, like a
        // low-resolution game texture.
        let small = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: 1.0 / 18, y: 1.0 / 18))
        let texture = small
            .transformed(by: CGAffineTransform(scaleX: 18, y: 18))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .clampedToExtent()

        // A slightly softened outline, so the polygon corners agree on a simple shape.
        let silhouette = blurred(mask, 10 * scale)

        let polygon = 72 * scale
        return kernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect.insetBy(dx: -3 * polygon, dy: -3 * polygon) },
            arguments: [
                source,
                texture,
                silhouette,                         // which polygons belong to the model
                dome(mask, scale: scale),                // the model's inflated, rounded shape
                blurred(mask, 30 * scale),          // its blob shadow
                behind(image, mask: mask, scale: scale),
                Float(polygon), Float(time), Float(3 * scale),
            ]
        )?.cropped(to: extent) ?? image
    }

    /// The model's shape as a height map: rounded off at the edges like something inflated,
    /// with a gentle swell across the whole thing.
    private static func dome(_ mask: CIImage, scale: Double) -> CIImage {
        let edges = blurred(mask, 35 * scale)
        let swell = blurred(mask, 120 * scale)
        let add = CIFilter.additionCompositing()
        add.inputImage = edges
        add.backgroundImage = swell
        let half = CIFilter.colorMatrix()
        half.inputImage = add.outputImage
        half.rVector = CIVector(x: 0.5, y: 0, z: 0, w: 0)
        half.gVector = CIVector(x: 0, y: 0.5, z: 0, w: 0)
        half.bVector = CIVector(x: 0, y: 0, z: 0.5, w: 0)
        return (half.outputImage ?? swell).clampedToExtent()
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
