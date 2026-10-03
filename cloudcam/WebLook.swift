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

        kernel vec4 web(sampler soft, float size, float t, float step) {
            vec2 d = destCoord();
            vec3 w = vec3(0.299, 0.587, 0.114);
            float l  = dot(sample(soft, samplerTransform(soft, d)).rgb, w);
            float lx = dot(sample(soft, samplerTransform(soft, d + vec2(step, 0.0))).rgb, w);
            float ly = dot(sample(soft, samplerTransform(soft, d + vec2(0.0, step))).rgb, w);
            float dark = 1.0 - l;

            // Bend space so the cells come out stretched and organic, not geometric.
            // Leaning, stretched cells like a pulled net.
            vec2 p = d / size;
            p = vec2(0.8 * p.x + 0.35 * p.y, 0.55 * p.y);
            p += 0.35 * vec2(sin(p.y * 1.7 + t * 0.2), cos(p.x * 1.5 - t * 0.17));

            // The main web grows only into the subject (the darker half of the scene), its
            // strands swelling the darker it gets. Bright areas stay bare paper.
            float coarse = wall(p, t);
            float grow = smoothstep(0.4, 0.62, dark);
            float strand = mix(0.012, 0.2, smoothstep(0.5, 0.95, dark));
            float ink = (1.0 - smoothstep(strand, strand + 0.02, coarse)) * grow;

            // A finer, denser tangle that only grows into the dark parts.
            float fine = wall(p * 3.1 + 7.0, t * 1.3);
            float tangle = smoothstep(0.62, 0.9, dark);
            ink = max(ink, (1.0 - smoothstep(0.06, 0.11, fine)) * tangle);

            // The scene's own outlines become heavy veins.
            float edge = length(vec2(lx - l, ly - l));
            ink = max(ink, smoothstep(0.06, 0.12, edge));

            // Thin traced contours of brightness, the faint outlines between the strands.
            float level = fract(l * 7.0);
            float contour = 1.0 - smoothstep(0.0, 0.035, min(level, 1.0 - level) - 0.005);
            ink = max(ink, contour * 0.9 * smoothstep(0.2, 0.45, dark));

            // Ink on slightly warm paper.
            vec3 paper = vec3(0.96, 0.95, 0.93);
            vec3 col = mix(paper, vec3(0.0), clamp(ink, 0.0, 1.0));
            return vec4(col, 1.0);
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
            roiCallback: { _, rect in rect.insetBy(dx: -4 * scale - 2, dy: -4 * scale - 2) },
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
