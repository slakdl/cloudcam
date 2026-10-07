import CoreGraphics
import SceneKit

/// The PlayStation 1 look shared by the Poly models: wobbly vertices (corners snap to a coarse
/// grid as the camera moves), 15-bit color, and tiny pixel-art textures with hard pixel edges.
enum PS1 {
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
}
