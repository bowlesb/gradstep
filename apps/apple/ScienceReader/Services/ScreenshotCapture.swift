import ScienceReaderCore
import UIKit

@MainActor
enum ScreenshotCapture {
    static func currentWindow() -> UIImage? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: \.isKeyWindow), !window.bounds.isEmpty else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.opaque = true; format.scale = min(window.screen.scale, 2)
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            UIColor.systemBackground.setFill(); context.fill(window.bounds)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }

    /// Re-render pixels to remove source metadata and flatten crop/redactions.
    /// Coordinates refer to the full displayed, orientation-correct image.
    static func prepare(_ image: UIImage, redactions: [CGRect] = [], crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> (image: UIImage, attachment: ReportImage) {
        guard image.size.width > 0, image.size.height > 0 else { throw ReaderError.corruptData }
        let region = crop.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard region.width > 0.01, region.height > 0.01 else { throw ReaderError.invalidEvent }
        let full = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let cropPixels = CGRect(x: region.minX * full.width, y: region.minY * full.height, width: region.width * full.width, height: region.height * full.height)
        let factor = min(1, 2560 / max(cropPixels.width, cropPixels.height))
        let output = CGSize(width: max(1, floor(cropPixels.width * factor)), height: max(1, floor(cropPixels.height * factor)))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let flattened = UIGraphicsImageRenderer(size: output, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: output))
            context.cgContext.scaleBy(x: factor, y: factor)
            context.cgContext.translateBy(x: -cropPixels.minX, y: -cropPixels.minY)
            image.draw(in: CGRect(origin: .zero, size: full))
            UIColor.black.setFill()
            for rectangle in redactions {
                let rect = rectangle.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                context.cgContext.fill(CGRect(x: rect.minX * full.width, y: rect.minY * full.height, width: rect.width * full.width, height: rect.height * full.height))
            }
        }
        if let png = flattened.pngData(), png.count <= 5 * 1024 * 1024 { return (flattened, ReportImage(bytes: png, mediaType: "image/png")) }
        for quality in [0.9, 0.75, 0.6] {
            if let jpeg = flattened.jpegData(compressionQuality: quality), jpeg.count <= 5 * 1024 * 1024, let preview = UIImage(data: jpeg) {
                return (preview, ReportImage(bytes: jpeg, mediaType: "image/jpeg"))
            }
        }
        throw ReaderError.invalidEvent
    }
}
