import CoreImage
import CoreVideo
import Vision

/// Watches the camera for clouds a couple of times a second. Apple's built-in image
/// recognition says whether the view looks cloudy, and a quick scan of a tiny copy of the
/// frame finds where the cloud is: the bright, colorless patch. Safe to call from any thread.
nonisolated final class CloudSpotter: @unchecked Sendable {
    /// What was last seen. `position` and `size` are fractions of the frame, measured
    /// from its bottom-left corner, like Core Image.
    struct Sighting {
        var cloudy = false
        var position = CGPoint(x: 0.5, y: 0.7)
        var size = 0.3
    }

    private let queue = DispatchQueue(label: "cloud-spotter", qos: .utility)
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let lock = NSLock()
    private var sighting = Sighting()
    private var busy = false
    private var lastLook = 0.0

    /// How sure the recognizer has to be before we call it a cloud.
    private let threshold: Float = 0.3

    func latest() -> Sighting {
        lock.lock()
        defer { lock.unlock() }
        return sighting
    }

    /// Hand over the newest camera frame. Only every ~0.4 seconds is actually looked at.
    func look(at buffer: CVPixelBuffer, now: Double) {
        lock.lock()
        guard !busy, now - lastLook > 0.4 else { lock.unlock(); return }
        busy = true
        lastLook = now
        lock.unlock()

        queue.async { [self] in
            let result = examine(buffer)
            lock.lock()
            if let result { sighting = result }
            busy = false
            lock.unlock()
        }
    }

    private func examine(_ buffer: CVPixelBuffer) -> Sighting? {
        // 1. Is there a cloud at all?
        let request = VNClassifyImageRequest()
        try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
        let confidence = request.results?.first { $0.identifier == "cloudy" }?.confidence ?? 0
        guard confidence >= threshold else { return Sighting(cloudy: false) }

        // 2. Where? Shrink the frame to a few thousand pixels and average the positions of
        //    the bright, nearly colorless ones.
        let image = CIImage(cvPixelBuffer: buffer)
        let width = 48
        let scale = Double(width) / image.extent.width
        let height = Int(image.extent.height * scale)
        let small = image
            .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(small, toBitmap: &pixels, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        var sumX = 0.0, sumY = 0.0, sumXX = 0.0, count = 0.0
        for row in 0..<height {
            for column in 0..<width {
                let i = (row * width + column) * 4
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                let brightness = 0.299 * r + 0.587 * g + 0.114 * b
                let colorfulness = max(r, g, b) - min(r, g, b)
                guard brightness > 0.6, colorfulness < 0.2 else { continue }
                // The bitmap's first row is the bottom of the image, like Core Image.
                let x = (Double(column) + 0.5) / Double(width)
                let y = (Double(row) + 0.5) / Double(height)
                sumX += x; sumY += y; sumXX += x * x; count += 1
            }
        }
        guard count > 6 else { return Sighting(cloudy: false) }

        let meanX = sumX / count
        let spread = sqrt(max(sumXX / count - meanX * meanX, 0))
        return Sighting(
            cloudy: true,
            position: CGPoint(x: meanX, y: sumY / count),
            size: min(max(spread * 2.5, 0.2), 0.9)
        )
    }
}
