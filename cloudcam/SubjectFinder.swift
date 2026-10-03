import CoreImage
import CoreVideo
import Vision

/// Finds the main subject in the camera view (a lamp, a person, a cup) a few times a second,
/// using the same subject detection as "lift subject from background" in Photos. The result is
/// a mask: white on the subject, black everywhere else. Safe to call from any thread.
nonisolated final class SubjectFinder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "subject-finder", qos: .userInitiated)
    private let lock = NSLock()
    private var mask: CIImage?
    private var busy = false
    private var lastLook = 0.0

    /// The newest mask, or nil when nothing stands out in the scene.
    func latest() -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        return mask
    }

    /// Hand over the newest camera frame. Only every ~0.2 seconds is actually looked at.
    func look(at buffer: CVPixelBuffer, now: Double) {
        lock.lock()
        guard !busy, now - lastLook > 0.2 else { lock.unlock(); return }
        busy = true
        lastLook = now
        lock.unlock()

        queue.async { [self] in
            let found = Self.findSubject(in: buffer)
            lock.lock()
            mask = found
            busy = false
            lock.unlock()
        }
    }

    /// Looks for the subject right now and waits for the answer. Used when there's no live
    /// feed to keep up with, such as trying the look out on a still photo.
    static func findSubject(in buffer: CVPixelBuffer) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let result = request.results?.first,
              let scaled = try? result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        else { return nil }
        return CIImage(cvPixelBuffer: scaled)
    }
}
