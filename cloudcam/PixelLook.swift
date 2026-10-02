import CoreImage
import CoreImage.CIFilterBuiltins

/// A world made of stretched pixels. Every row of the picture is smeared sideways into
/// long horizontal streaks, but each streak starts fresh at the edge of a shape, so
/// buildings, people and objects keep their outlines while their surfaces turn into
/// bands of pure color, like a scanner dragged across the scene.
enum PixelLook {
    /// For every pixel, walk left until we hit an edge in the scene, then take the color
    /// just past that edge. Everything between two edges becomes one horizontal streak.
    private static let kernel: CIKernel? = CIKernel(source: """
        kernel vec4 stretch(sampler src, sampler edges, float stride, float threshold) {
            vec2 d = destCoord();
            // Search on a fixed grid, so neighboring pixels agree on where their edge is.
            float start = floor(d.x / stride) * stride;
            // The search reaches across the whole frame; with no edge at all, the streak
            // starts at the left side of the picture.
            float anchor = 0.0;
            float found = 0.0;
            for (int i = 0; i < 112; i++) {
                float x = start - float(i) * stride;
                float e = sample(edges, samplerTransform(edges, vec2(x, d.y))).r;
                float hit = step(threshold, e) * step(anchor, x) * (1.0 - found);
                anchor = mix(anchor, x, hit);
                found = max(found, hit);
            }
            return sample(src, samplerTransform(src, vec2(anchor + 1.0, d.y)));
        }
        """)

    /// The effect runs at half size: it's much faster, and the chunkier pixels suit it.
    private static let workingScale = 0.5

    static func apply(to image: CIImage) -> CIImage {
        let extent = image.extent
        guard let kernel else { return image }

        let small = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: workingScale, y: workingScale))
        let bounds = CGRect(x: 0, y: 0, width: extent.width * workingScale, height: extent.height * workingScale)
        let source = small.clampedToExtent()

        // Where the vertical edges are: smear the picture up and down a little first, so the
        // edges line up from row to row and the streaks break cleanly along whole outlines.
        // Soften it too, so fine texture like grass or stars doesn't count as an edge.
        let settle = CIFilter.motionBlur()
        settle.inputImage = source
        settle.radius = 9
        settle.angle = .pi / 2
        let soften = CIFilter.gaussianBlur()
        soften.inputImage = settle.outputImage
        soften.radius = 3.5
        // Lift the shadows first, so outlines in a dim scene count as much as in daylight.
        let lift = CIFilter.gammaAdjust()
        lift.inputImage = soften.outputImage
        lift.power = 0.5
        let settled = (lift.outputImage ?? source).cropped(to: bounds).clampedToExtent()

        let difference = CIFilter.differenceBlendMode()
        difference.inputImage = settled.transformed(by: CGAffineTransform(translationX: 4, y: 0))
        difference.backgroundImage = settled
        // Boost it, so a clear outline reads as a strong edge in any light.
        let boost = CIFilter.colorMatrix()
        boost.inputImage = difference.outputImage
        boost.rVector = CIVector(x: 4, y: 0, z: 0, w: 0)
        boost.gVector = CIVector(x: 0, y: 4, z: 0, w: 0)
        boost.bVector = CIVector(x: 0, y: 0, z: 4, w: 0)
        let strongest = CIFilter.maximumComponent()
        strongest.inputImage = boost.outputImage
        let edges = (strongest.outputImage ?? settled).cropped(to: bounds).clampedToExtent()

        let streaked = kernel.apply(
            extent: bounds,
            roiCallback: { _, rect in CGRect(x: bounds.minX - 6, y: rect.minY - 2, width: rect.maxX - bounds.minX + 12, height: rect.height + 4) },
            arguments: [source, edges, Float(5), Float(0.3)]
        ) ?? small

        // Back to full size with hard pixel edges, then a little extra punch.
        let full = streaked
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: 1 / workingScale, y: 1 / workingScale))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))

        let punch = CIFilter.colorControls()
        punch.inputImage = full
        punch.saturation = 1.15
        punch.contrast = 1.05
        return (punch.outputImage ?? full).cropped(to: extent)
    }
}
