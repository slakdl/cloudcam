import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Vision

/// Works out what the object at a tapped spot is: cuts it out (the same subject detection the
/// Spider uses), asks Vision what it is, and measures its color and how much of the picture it
/// fills. Slow-ish (a few hundred milliseconds), so run it off the main thread.
enum ObjectScan {
    struct Result {
        var labels: [String]  // Vision's best guesses, most likely first
        var box: CGRect  // the object in the upright picture, 0...1 from the bottom left
        var color: CGColor
        var picture: CGImage?  // a tiny pixelated picture of it, for objects without a model
        var standsOut: Bool  // whether a separate object was actually found there
    }

    private static let context = CIContext()

    /// `buffer` is the camera image as ARKit captures it (sideways); `point` is the tap in a view
    /// of `viewSize` that shows the upright image filling the screen.
    static func scan(_ buffer: CVPixelBuffer, viewSize: CGSize, at point: CGPoint) -> Result? {
        let upright = CIImage(cvPixelBuffer: buffer).oriented(.right)
        let image = upright.extent.size
        let scale = max(viewSize.width / image.width, viewSize.height / image.height)
        let shown = CGSize(width: image.width * scale, height: image.height * scale)
        let tap = CGPoint(x: (point.x - (viewSize.width - shown.width) / 2) / shown.width,
                          y: 1 - (point.y - (viewSize.height - shown.height) / 2) / shown.height)

        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right)
        let found = objectBox(at: tap, handler: handler)
        let box = found ?? CGRect(x: tap.x - 0.18, y: tap.y - 0.12, width: 0.36, height: 0.24)

        let classify = VNClassifyImageRequest()
        classify.regionOfInterest = box.insetBy(dx: -0.03, dy: -0.03).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        try? handler.perform([classify])
        let labels = (classify.results ?? []).filter { $0.confidence > 0.05 }.prefix(8).map(\.identifier)

        let crop = upright.cropped(to: CGRect(x: upright.extent.minX + box.minX * image.width,
                                              y: upright.extent.minY + box.minY * image.height,
                                              width: box.width * image.width, height: box.height * image.height))
        return Result(labels: labels, box: box, color: averageColor(of: crop), picture: tiny(crop),
                      standsOut: found != nil)
    }

    /// The bounding box of the separate object under the tap, if one stands out there.
    private static func objectBox(at tap: CGPoint, handler: VNImageRequestHandler) -> CGRect? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        guard (try? handler.perform([request])) != nil, let result = request.results?.first else { return nil }
        let mask = result.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask)
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        func instance(_ x: Int, _ row: Int) -> UInt8 { pixels[row * rowBytes + x] }  // row 0 is the top

        // The mask may come back in the camera's own sideways orientation. If it's wider than
        // tall, it's sideways: the picture's left-right runs along its rows, bottom to top.
        let sideways = width > height
        func maskPoint(_ p: CGPoint) -> (Int, Int) {
            let fromTop = 1 - p.y
            let (cx, cy) = sideways ? (fromTop, 1 - p.x) : (p.x, fromTop)
            return (min(max(Int(cx * Double(width)), 0), width - 1), min(max(Int(cy * Double(height)), 0), height - 1))
        }
        let (tx, ty) = maskPoint(tap)
        let picked = instance(tx, ty)
        guard picked != 0 else { return nil }

        var minX = width, maxX = 0, minRow = height, maxRow = 0
        for row in 0..<height {
            for x in 0..<width where instance(x, row) == picked {
                minX = min(minX, x); maxX = max(maxX, x); minRow = min(minRow, row); maxRow = max(maxRow, row)
            }
        }
        let w = Double(width), h = Double(height)
        if sideways {
            return CGRect(x: 1 - Double(maxRow + 1) / h, y: 1 - Double(maxX + 1) / w,
                          width: Double(maxRow - minRow + 1) / h, height: Double(maxX - minX + 1) / w)
        }
        return CGRect(x: Double(minX) / w, y: 1 - Double(maxRow + 1) / h,
                      width: Double(maxX - minX + 1) / w, height: Double(maxRow - minRow + 1) / h)
    }

    private static func averageColor(of image: CIImage) -> CGColor {
        let average = CIFilter.areaAverage()
        average.inputImage = image
        average.extent = image.extent
        var rgba = [UInt8](repeating: 128, count: 4)
        if let pixel = average.outputImage {
            context.render(pixel, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: pixel.extent.minX, y: pixel.extent.minY, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        // A little punchier than real life, like game colors.
        func pop(_ v: UInt8) -> CGFloat { min(max((CGFloat(v) / 255 - 0.5) * 1.3 + 0.5, 0), 1) }
        return CGColor(red: pop(rgba[0]), green: pop(rgba[1]), blue: pop(rgba[2]), alpha: 1)
    }

    /// The object at 16 pixels across.
    private static func tiny(_ image: CIImage) -> CGImage? {
        let k = 16 / max(image.extent.width, 1)
        let small = image
            .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
        return context.createCGImage(small, from: CGRect(x: 0, y: 0, width: 16, height: max(1, (image.extent.height * k).rounded())))
    }
}
