import CoreImage
import CoreImage.CIFilterBuiltins

/// The world as a living tangle of black ink on white paper. A web of organic cells grows
/// over the scene: its strands swell thick where the picture is dark and thin out where
/// it's light, a second, finer web knots densely into the darkest places, the outlines of
/// things become heavy veins, and thin traced contours wrap around everything. The cells
/// drift slowly, so the web seems to breathe and grow.
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

        kernel vec4 web(sampler soft, float size, float t, float px) {
            vec2 d = destCoord();
            float frame = floor(t * 12.0);  // grain and specks change 12 times a second

            // Tearing: now and then a horizontal band slips sideways.
            float band = floor(d.y / (size * 0.35));
            float tear = hash(vec2(band, floor(t * 2.5)));
            d.x += step(0.92, tear) * (hash(vec2(band, 7.0 + floor(t * 2.5))) - 0.5) * size * 0.9;

            // Bending: a slow, twisting current pushes everything around, the picture too.
            vec2 q = d / (size * 2.2);
            vec2 bend = vec2(fbm(q + vec2(0.0, t * 0.06)), fbm(q + vec2(5.2, -t * 0.05))) - 0.5;
            vec2 at = d + bend * size * 1.1;

            vec3 w = vec3(0.299, 0.587, 0.114);
            float l  = dot(sample(soft, samplerTransform(soft, at)).rgb, w);
            float lx = dot(sample(soft, samplerTransform(soft, at + vec2(px, 0.0))).rgb, w);
            float ly = dot(sample(soft, samplerTransform(soft, at + vec2(0.0, px))).rgb, w);
            float dark = 1.0 - l;

            // Leaning, stretched cells like a pulled net, warped by the same current.
            vec2 p = at / size;
            p = vec2(0.8 * p.x + 0.35 * p.y, 0.55 * p.y);
            p += 0.9 * (vec2(fbm(p * 0.7 + t * 0.03), fbm(p * 0.7 + 9.1 - t * 0.03)) - 0.5);

            // Frayed edges: the distance to each strand is jittered at two scales.
            float fray = (noise(d / 3.0 + frame) - 0.5) * 0.05 + (noise(d / 14.0) - 0.5) * 0.08;

            // The main web grows only into the subject, swelling the darker it gets.
            float coarse = wall(p, t) + fray;
            float grow = smoothstep(0.38, 0.62, dark + (noise(d / 40.0) - 0.5) * 0.2);
            float strand = mix(0.012, 0.22, smoothstep(0.5, 0.95, dark));
            float ink = (1.0 - smoothstep(strand, strand + 0.035, coarse)) * grow;

            // A finer, denser tangle in the darkest parts.
            float fine = wall(p * 3.1 + 7.0, t * 1.3) + fray * 0.7;
            ink = max(ink, (1.0 - smoothstep(0.05, 0.12, fine)) * smoothstep(0.6, 0.9, dark));

            // The scene's own outlines become heavy, smeared veins.
            float edge = length(vec2(lx - l, ly - l)) + fray * 0.4;
            ink = max(ink, smoothstep(0.05, 0.12, edge));

            // Thin wavering contours of brightness.
            float level = fract(l * 7.0 + fray * 2.0);
            float contour = 1.0 - smoothstep(0.0, 0.045, min(level, 1.0 - level) - 0.005);
            ink = max(ink, contour * 0.85 * smoothstep(0.2, 0.45, dark));

            // Patchy ink: thinner in some places, like a dry pen or a bad photocopy.
            ink *= 0.8 + 0.2 * smoothstep(0.35, 0.75, fbm(vec2(d.x / 60.0, d.y / 14.0) + 2.0));
            ink = clamp(ink, 0.0, 1.0);

            // Stained, blotchy paper that darkens toward the corners.
            vec2 uv = destCoord() / (size * vec2(15.4, 27.4));  // roughly 0..1 across the frame
            float stain = fbm(d / (size * 3.0) + 11.0);
            vec3 paper = vec3(0.93, 0.91, 0.86) * (0.84 + 0.2 * stain);
            float corner = length(uv - 0.5);
            paper *= 1.0 - smoothstep(0.35, 0.8, corner) * 0.55;

            vec3 col = mix(paper, vec3(0.03, 0.02, 0.02), ink);

            // Heavy grain, and stray specks of ink and dust.
            float g = hash(d + frame * 13.1);
            col += (g - 0.5) * 0.22;
            float speck = hash(floor(d / 2.0) + frame * 7.3);
            col = mix(col, vec3(0.02), step(0.9985, speck) * smoothstep(0.25, 0.5, dark));
            col = mix(col, paper, step(0.996, speck) * ink * 0.8);
            // All of the above was mixed in screen tones; convert to the linear light Core Image
            // works in, so solid ink stays black instead of washing out to grey.
            return vec4(pow(clamp(col, 0.0, 1.0), vec3(2.2)), 1.0);
        }
        """)

    static func apply(to image: CIImage, time: Double) -> CIImage {
        let extent = image.extent
        let scale = extent.width / 1080  // keep the look the same at any resolution
        guard let kernel else { return image }

        // Soften and even out the picture first, so the web follows shapes, not every speck,
        // and a dim room spreads across the same range of thick-to-thin as a bright day.
        let soften = CIFilter.gaussianBlur()
        soften.inputImage = image.clampedToExtent()
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
        shift.ev = Float(log2(0.5 / max(average, 0.04)))  // bring the average to mid-grey
        let soft = (shift.outputImage ?? image).clampedToExtent()

        return kernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect.insetBy(dx: -100 * scale, dy: -60 * scale) },
            arguments: [soft, Float(70 * scale), Float(time), Float(3 * scale)]
        )?.cropped(to: extent) ?? image
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
