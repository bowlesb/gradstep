import CoreGraphics
import Foundation
import ImageIO
import ScienceReaderCore
import UniformTypeIdentifiers

/// The figures a question is about (docs/proposals/CHAT_TOOLS.md item 4): "Figure 2", "Fig. 3", "Table 1" in the
/// question or the selected passage, matched to the paper's own figure captions, each image prepared on the device for
/// the model (at most 1,568 px on a side and about 1.15 megapixels, JPEG on white), at most two figures per question.
enum ChatFigureFinder {
    static let maximumFigures = 2
    static let maximumSide = 1_568
    static let maximumPixels = 1_150_000.0

    /// "figure 2", "table 1" named in the text, in order of first mention.
    static func mentions(in text: String) -> [(kind: String, number: Int)] {
        var found: [(kind: String, number: Int)] = []
        for match in text.matches(of: /(?i)\b(fig(?:ure)?s?\.?|tables?)\s*(\d{1,3})\b/) {
            let kind = match.output.1.lowercased().hasPrefix("tab") ? "table" : "figure"
            guard let number = Int(match.output.2), !found.contains(where: { $0.kind == kind && $0.number == number }) else { continue }
            found.append((kind, number))
        }
        return found
    }

    /// "Figure 4" or "Table 2" from a caption that starts with its number; nil otherwise.
    static func label(_ caption: String) -> String? {
        guard let match = caption.firstMatch(of: /^\s*(?i)(figure|fig\.?|table)\s*(\d{1,3})\b/), let number = Int(match.output.2) else { return nil }
        return "\(match.output.1.lowercased().hasPrefix("tab") ? "Table" : "Figure") \(number)"
    }

    /// The figure whose caption names it ("Figure 2:", "Fig. 2.", "Table 1:").
    static func figure(_ mention: (kind: String, number: Int), in index: ReaderBundleIndex) -> ReaderBundleIndex.Figure? {
        index.figures.first { figure in
            guard let match = figure.caption.firstMatch(of: /^\s*(?i)(figure|fig\.?|table)\s*(\d{1,3})\b/), let number = Int(match.output.2) else { return false }
            let kind = match.output.1.lowercased().hasPrefix("tab") ? "table" : "figure"
            return kind == mention.kind && number == mention.number
        }
    }

    /// The images to send with a question, from the open paper's bundle.
    static func images(question: String, selection: String?, bundle: VerifiedReaderBundle) -> [ChatFigureImage] {
        let mentions = self.mentions(in: [selection, question].compactMap { $0 }.joined(separator: "\n"))
        var figures: [ReaderBundleIndex.Figure] = []
        for mention in mentions {
            guard let figure = figure(mention, in: bundle.index), !figures.contains(where: { $0.id == figure.id }) else { continue }
            figures.append(figure)
            if figures.count == maximumFigures { break }
        }
        var result: [ChatFigureImage] = []
        for figure in figures {
            guard let image = image(for: figure, bundle: bundle, id: "F\(result.count + 1)") else { continue }
            result.append(image)
        }
        return result
    }

    /// One figure's image as a question (or the figure view) sends it. A figure of several panels goes as one image, its
    /// panels stacked (2610.19525's Figure 1, (a) and (b)).
    static func image(for figure: ReaderBundleIndex.Figure, bundle: VerifiedReaderBundle, id: String = "F1") -> ChatFigureImage? {
        let paths = Array(figure.assetPaths.prefix(maximumPanels))
        guard let path = paths.first,
              let prepared = paths.count > 1
                  ? composite(paths.compactMap { bundle.data(for: $0).flatMap(image) }).flatMap(prepare)
                  : bundle.data(for: path).flatMap(prepare),
              let paragraph = bundle.index.blocks.firstIndex(where: { $0.id == figure.blockID }).map({ $0 + 1 }) else { return nil }
        return ChatFigureImage(id: id, paragraph: paragraph, caption: figure.caption, mediaType: "image/jpeg",
                               data: prepared.data.base64EncodedString(), width: prepared.width, height: prepared.height,
                               blockID: figure.blockID, assetPath: path, assetPaths: paths)
    }

    static let maximumPanels = 4

    /// A figure's panels as one image: each scaled to the widest panel's width, top to bottom, 2 % of the width of white
    /// between them. The same on every device (the parts' boxes are fractions of it; the browser composes it alike).
    static func composite(_ panels: [CGImage]) -> CGImage? {
        guard !panels.isEmpty else { return nil }
        if panels.count == 1 { return panels[0] }
        let width = panels.map(\.width).max()!, gap = max(1, Int((Double(width) * 0.02).rounded()))
        let heights = panels.map { Int((Double($0.height) * Double(width) / Double($0.width)).rounded()) }
        let height = heights.reduce(0, +) + gap * (panels.count - 1)
        guard width * height <= 40_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        var top = 0
        for (panel, h) in zip(panels, heights) {
            context.draw(panel, in: CGRect(x: 0, y: height - top - h, width: width, height: h))
            top += h + gap
        }
        return context.makeImage()
    }

    /// A composed figure, scaled and encoded as `prepare(_ data:)` does.
    static func prepare(_ image: CGImage) -> (data: Data, width: Int, height: Int)? {
        let long = Double(max(image.width, image.height)), short = Double(min(image.width, image.height))
        let scale = min(Double(maximumSide), (maximumPixels * long / short).squareRoot(), long) / long
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        guard (8...1_600).contains(w), (8...1_600).contains(h),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flat = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= 1_150_000 else { return nil }
        return (output as Data, w, h)
    }

    /// A figure as the model reads it best: scaled to the provider's resolution, JPEG on white (no transparency).
    static func prepare(_ data: Data) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let long = Double(max(width, height)), short = Double(min(width, height))
        let limit = min(Double(maximumSide), (maximumPixels * long / short).squareRoot(), long)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: Int(limit),
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let w = scaled.width, h = scaled.height
        guard (8...1_600).contains(w), (8...1_600).contains(h),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.draw(scaled, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flat = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= 1_150_000 else { return nil }
        return (output as Data, w, h)
    }

    /// A stored figure's image, decoded for cropping.
    static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
