import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import MetalKit
import SwiftUI

/// Shows the camera with the cloud look applied, drawn on the GPU with Metal.
/// SwiftUI has no built-in live-video view, so we wrap UIKit's MTKView.
struct CameraPreviewView: UIViewRepresentable {
    let renderer: CameraRenderer
    let mode: CloudLook.Mode
    /// When there's no camera (the simulator), draw a moving test pattern instead.
    let showsTestPattern: Bool

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.framebufferOnly = false  // Core Image needs to write into the drawable
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        renderer.mode = mode
        renderer.showsTestPattern = showsTestPattern
    }
}

/// Draws one styled frame each time the view asks for one (30 times a second).
///
/// Every finished picture is first drawn into an off-screen buffer and then shown.
/// That buffer is what gets saved when you take a photo.
final class CameraRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    var mode: CloudLook.Mode = .spider
    var showsTestPattern = false

    private let frames: FrameStore
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    private let startTime = CACurrentMediaTime()
    private let subjects = SubjectFinder()
    private let spider = SpiderLook()
    private var buffers: [CVPixelBuffer] = []
    private var latest: CVPixelBuffer?

    init(frames: FrameStore) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { preconditionFailure("This device doesn't support Metal") }

        self.frames = frames
        self.device = device
        self.commandQueue = queue
        self.ciContext = CIContext(mtlDevice: device)
        super.init()
    }

    /// The last picture that was shown, exactly as it looked. Only valid until the next frame is drawn.
    func snapshot() -> CIImage? {
        latest.map { CIImage(cvPixelBuffer: $0) }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let time = CACurrentMediaTime() - startTime

        let source: CIImage
        if let buffer = frames.latest() {
            source = CIImage(cvPixelBuffer: buffer)
            if mode == .spider { subjects.look(at: buffer, now: time) }
        } else if showsTestPattern {
            source = TestPattern.image(time: time)
        } else {
            return  // nothing to show yet
        }

        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        // 1. Apply the look and draw the result into an off-screen buffer.
        let styled: CIImage
        switch mode {
        case .spider: styled = spider.apply(to: source, subject: subjects.latest(), time: time)
        case .pixel: styled = PixelLook.apply(to: source)
        case .poly: styled = source  // Poly mode shows the AR view instead of this one
        }
        guard let target = nextBuffer(for: source.extent.size) else { return }

        let destination = CIRenderDestination(pixelBuffer: target)
        destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        guard let task = try? ciContext.startTask(toRender: styled, to: destination) else { return }
        _ = try? task.waitUntilCompleted()
        latest = target

        // 2. Show it, scaled up to fill the whole screen, cropping the overflow.
        let shown = CIImage(cvPixelBuffer: target)
        let size = view.drawableSize
        let scale = max(size.width / shown.extent.width, size.height / shown.extent.height)
        let scaled = shown.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let fitted = scaled.transformed(by: CGAffineTransform(
            translationX: (size.width - scaled.extent.width) / 2 - scaled.extent.minX,
            y: (size.height - scaled.extent.height) / 2 - scaled.extent.minY
        ))

        ciContext.render(
            fitted,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(origin: .zero, size: size),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Two off-screen buffers that take turns, so the last picture stays intact while the next one is drawn.
    private func nextBuffer(for size: CGSize) -> CVPixelBuffer? {
        let width = Int(size.width)
        let height = Int(size.height)
        if buffers.isEmpty || CVPixelBufferGetWidth(buffers[0]) != width || CVPixelBufferGetHeight(buffers[0]) != height {
            let attributes: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            buffers = (0..<2).compactMap { _ in
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
                return buffer
            }
            latest = nil
        }
        guard buffers.count == 2 else { return nil }
        return buffers.first { $0 !== latest }
    }
}

/// A sliding checkerboard with an orange top-left and teal bottom-right, so it's
/// obvious which way is up and how a look bends straight lines.
enum TestPattern {
    static func image(time: Double) -> CIImage {
        let bounds = CGRect(x: 0, y: 0, width: 1080, height: 1920)

        let checkerboard = CIFilter.checkerboardGenerator()
        checkerboard.center = CGPoint(x: time * 40, y: time * 25)
        checkerboard.color0 = CIColor(red: 1, green: 1, blue: 1)
        checkerboard.color1 = CIColor(red: 0.55, green: 0.55, blue: 0.55)
        checkerboard.width = 90

        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: bounds.height)
        gradient.point1 = CGPoint(x: bounds.width, y: 0)
        gradient.color0 = CIColor(red: 1, green: 0.5, blue: 0.1)
        gradient.color1 = CIColor(red: 0.1, green: 0.7, blue: 0.8)

        let tinted = CIFilter.multiplyCompositing()
        tinted.inputImage = checkerboard.outputImage
        tinted.backgroundImage = gradient.outputImage
        return (tinted.outputImage ?? CIImage.empty()).cropped(to: bounds)
    }
}
