import CoreImage
import ImageIO
import Photos

/// Turns a finished picture into a JPEG and saves it to the photo library.
enum PhotoSaver {
    enum Failure: Error {
        case accessDenied
    }

    private static let context = CIContext()

    /// Encode right away: the picture is only valid until the next frame is drawn,
    /// and the permission popup below can keep the save waiting for a while.
    static func jpeg(from image: CIImage) -> Data? {
        context.jpegRepresentation(
            of: image,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92]
        )
    }

    static func save(_ jpeg: Data) async throws {
        // Ask for "add only" access: the app can put photos in the library but can't read it.
        // This is the moment iOS shows the "Allow saving photos?" popup.
        let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard access == .authorized || access == .limited else { throw Failure.accessDenied }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: jpeg, options: nil)
        }
    }
}
