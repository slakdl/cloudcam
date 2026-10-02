@preconcurrency import AVFoundation
import Observation

/// Holds the newest camera frame. The camera writes to it from a background
/// queue and the screen reads from it on the main thread, so it needs a lock.
nonisolated final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?

    func store(_ newBuffer: CVPixelBuffer) {
        lock.lock()
        buffer = newBuffer
        lock.unlock()
    }

    func latest() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// Owns the camera: asks for permission, starts it, and hands out frames.
@Observable
final class CameraService: NSObject {
    enum Status {
        case starting
        case running
        case denied       // the user said no to camera access
        case unavailable  // no camera on this device (e.g. the simulator)
    }

    private(set) var status: Status = .starting

    let frames = FrameStore()

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let outputQueue = DispatchQueue(label: "camera.output")
    private var isConfigured = false

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            // This is the moment iOS shows the "Allow camera?" popup.
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                status = .denied
                return
            }
        default:
            status = .denied
            return
        }

        guard configureIfNeeded() else {
            status = .unavailable
            return
        }

        // startRunning() blocks until the camera is up, so keep it off the main thread.
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
        status = .running
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureIfNeeded() -> Bool {
        if isConfigured { return true }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .hd1920x1080

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { return false }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true  // if we fall behind, skip frames instead of lagging
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)

        // The sensor is landscape; rotate frames so they arrive upright for portrait.
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        isConfigured = true
        return true
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    // Called ~30 times a second on `outputQueue`, not the main thread.
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frames.store(pixelBuffer)
    }
}
