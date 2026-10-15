import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import zlib

/// Pixels for the device route: pages rendered like pypdfium2 (`ceil(size × dpi / 72)` pixels over the crop box,
/// white), the layout's canvas, the recogniser's crop and its TexTeller preprocessing, and minimal PNGs (IHDR,
/// IDAT, IEND; the reader's PNG profile admits nothing else).
public enum DevicePDFRaster {
    public struct RGB: Sendable {
        public let width: Int, height: Int
        public var pixels: [UInt8]  // RGB, row-major
        public init(width: Int, height: Int, pixels: [UInt8]) { self.width = width; self.height = height; self.pixels = pixels }
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The page's crop box at `dpi`, on white.
    public static func render(_ page: CGPDFPage, dpi: Double) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let width = Int((box.width * dpi / 72).rounded(.up)), height = Int((box.height * dpi / 72).rounded(.up))
        guard width > 0, height > 0, width * height <= 120_000_000,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        // No font smoothing: macOS thickens glyph stems when it smooths (iOS never does), and the recogniser then reads
        // regular letters as bold (`\bm{X}` for X on 2610.04747v1). Antialiasing stays, as pdfium renders.
        ctx.setAllowsFontSmoothing(false); ctx.setShouldSmoothFonts(false)
        ctx.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    /// The page scaled to fit the layout canvas at the top left, white elsewhere (`coreml_layout.to_canvas`), as a
    /// BGRA pixel buffer for the model's image input; returns the scale.
    static func canvas(_ page: CGImage, width: Int, height: Int) throws -> (CVPixelBuffer, Double) {
        let s = min(Double(width) / Double(page.width), Double(height) / Double(page.height))
        let w = max(1, Int((Double(page.width) * s).rounded())), h = max(1, Int((Double(page.height) * s).rounded()))
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { throw DevicePDFModelError.unusable("canvas") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw DevicePDFModelError.unusable("canvas")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .medium  // PIL's bilinear
        ctx.draw(page, in: CGRect(x: 0, y: height - h, width: w, height: h))
        return (buffer, s)
    }

    /// RGB bytes of an image (drawn on white).
    public static func rgb(_ image: CGImage) -> RGB {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        rgba.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { out[i * 3] = rgba[i * 4]; out[i * 3 + 1] = rgba[i * 4 + 1]; out[i * 3 + 2] = rgba[i * 4 + 2] }
        return RGB(width: w, height: h, pixels: out)
    }

    /// A pixel rectangle (top-left origin, end exclusive) of a page image; parts outside the page are white.
    public static func crop(_ page: RGB, _ rect: [Int], margin: Int = 0) -> RGB {
        let x0 = rect[0], y0 = rect[1], w = max(0, rect[2] - rect[0]), h = max(0, rect[3] - rect[1])
        let W = w + 2 * margin, H = h + 2 * margin
        var out = [UInt8](repeating: 255, count: W * H * 3)
        for y in 0..<h {
            let sy = y0 + y
            guard sy >= 0, sy < page.height else { continue }
            for x in 0..<w {
                let sx = x0 + x
                guard sx >= 0, sx < page.width else { continue }
                let s = (sy * page.width + sx) * 3, d = ((y + margin) * W + x + margin) * 3
                out[d] = page.pixels[s]; out[d + 1] = page.pixels[s + 1]; out[d + 2] = page.pixels[s + 2]
            }
        }
        return RGB(width: W, height: H, pixels: out)
    }

    public static func cgImage(_ rgb: RGB) -> CGImage? {
        var rgba = [UInt8](repeating: 255, count: rgb.width * rgb.height * 4)
        for i in 0..<(rgb.width * rgb.height) { rgba[i * 4] = rgb.pixels[i * 3]; rgba[i * 4 + 1] = rgb.pixels[i * 3 + 1]; rgba[i * 4 + 2] = rgb.pixels[i * 3 + 2] }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: rgb.width, height: rgb.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rgb.width * 4, space: sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: TexTeller preprocessing (`texteller.preprocess_image`)

    /// Trim the background border (the most common corner colour; a pixel differs when the grey of its absolute
    /// difference exceeds 15, OpenCV's BGR2GRAY weights applied to RGB data as the reference does), grey
    /// (torchvision: 0.2989 R + 0.587 G + 0.114 B, truncated), resize so the shorter side is 447 unless the longer
    /// would pass 448 (bicubic, antialiased, PIL's kernel), scale to 0…1, normalise, pad right and bottom with 0.
    static func recogniserInput(_ crop: CGImage, size: Int, mean: Double, std: Double) throws -> MLMultiArray {
        let input = recogniserPixels(rgb(crop), size: size, mean: mean, std: std)
        let array = try MLMultiArray(shape: [1, 1, NSNumber(value: size), NSNumber(value: size)], dataType: .float32)
        input.withUnsafeBytes { src in array.withUnsafeMutableBytes { raw, _ in raw.copyMemory(from: src) } }
        return array
    }

    public static func recogniserPixels(_ image: RGB, size: Int, mean: Double, std: Double) -> [Float] {
        let trimmed = trimBorder(image)
        // Grey, torchvision's weights in float32, truncated to uint8.
        var grey = [Float](repeating: 0, count: trimmed.width * trimmed.height)
        for i in 0..<grey.count {
            let r = Float(trimmed.pixels[i * 3]), g = Float(trimmed.pixels[i * 3 + 1]), b = Float(trimmed.pixels[i * 3 + 2])
            grey[i] = Float(UInt8(min(255, max(0, (r * 0.2989 + g * 0.587 + b * 0.114).rounded(.towardZero)))))
        }
        let (nw, nh) = resizedSize(width: trimmed.width, height: trimmed.height, size: size - 1, maximum: size)
        let resized = resizeBicubic(grey, width: trimmed.width, height: trimmed.height, toWidth: nw, toHeight: nh)
        var out = [Float](repeating: 0, count: size * size)
        let m = Float(mean), s = Float(std)
        for y in 0..<min(nh, size) {
            for x in 0..<min(nw, size) {
                let v = min(255, max(0, (resized[y * nw + x]).rounded()))
                out[y * size + x] = (v / 255 - m) / s
            }
        }
        return out
    }

    static func trimBorder(_ image: RGB) -> RGB {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return image }
        func px(_ x: Int, _ y: Int) -> [UInt8] { let i = (y * w + x) * 3; return [image.pixels[i], image.pixels[i + 1], image.pixels[i + 2]] }
        let corners = [px(0, 0), px(w - 1, 0), px(0, h - 1), px(w - 1, h - 1)]
        // Counter.most_common(1): the highest count, the first seen among ties.
        var bg = corners[0], best = 0
        for c in corners { let n = corners.filter { $0 == c }.count; if n > best { best = n; bg = c } }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                let d0 = abs(Int(image.pixels[i]) - Int(bg[0])), d1 = abs(Int(image.pixels[i + 1]) - Int(bg[1])), d2 = abs(Int(image.pixels[i + 2]) - Int(bg[2]))
                // cv2.COLOR_BGR2GRAY on RGB-ordered data: channel 0 weighted as blue. Fixed-point rounding as OpenCV.
                let grey = (d0 * 1868 + d1 * 9617 + d2 * 4899 + 8192) >> 14
                if grey > 15 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }
        return crop(image, [minX, minY, maxX + 1, maxY + 1])
    }

    /// torchvision's `_compute_resized_output_size` with `max_size`.
    static func resizedSize(width w: Int, height h: Int, size: Int, maximum: Int) -> (Int, Int) {
        let (short, long) = w <= h ? (w, h) : (h, w)
        var newShort = size, newLong = Int(Double(size) * Double(long) / Double(short))
        if newLong > maximum { newShort = Int(Double(maximum) * Double(newShort) / Double(newLong)); newLong = maximum }
        return w <= h ? (newShort, newLong) : (newLong, newShort)
    }

    /// Separable bicubic resampling with PIL's coefficients (a = −0.5, support scaled when shrinking).
    static func resizeBicubic(_ src: [Float], width: Int, height: Int, toWidth: Int, toHeight: Int) -> [Float] {
        func coefficients(_ inSize: Int, _ outSize: Int) -> [(start: Int, weights: [Float])] {
            let scale = Double(inSize) / Double(outSize)
            let filterScale = max(1, scale), support = 2.0 * filterScale
            return (0..<outSize).map { xx in
                let center = (Double(xx) + 0.5) * scale
                let xmin = max(Int(center - support + 0.5), 0), xmax = min(Int(center + support + 0.5), inSize)
                var w: [Double] = []
                for x in xmin..<max(xmin, xmax) {
                    var t = abs((Double(x) - center + 0.5) / filterScale)
                    let a = -0.5
                    if t < 1 { t = ((a + 2) * t - (a + 3)) * t * t + 1 } else if t < 2 { t = (((t - 5) * t + 8) * t - 4) * a } else { t = 0 }
                    w.append(t)
                }
                let total = w.reduce(0, +)
                return (xmin, w.map { Float(total != 0 ? $0 / total : 0) })
            }
        }
        let cx = coefficients(width, toWidth), cy = coefficients(height, toHeight)
        var mid = [Float](repeating: 0, count: toWidth * height)
        for y in 0..<height {
            for (x, c) in cx.enumerated() {
                var v: Float = 0
                for (k, w) in c.weights.enumerated() { v += src[y * width + c.start + k] * w }
                mid[y * toWidth + x] = min(255, max(0, v.rounded()))
            }
        }
        var out = [Float](repeating: 0, count: toWidth * toHeight)
        for (y, c) in cy.enumerated() {
            for x in 0..<toWidth {
                var v: Float = 0
                for (k, w) in c.weights.enumerated() { v += mid[(c.start + k) * toWidth + x] * w }
                out[y * toWidth + x] = v
            }
        }
        return out
    }

    // MARK: PNG

    /// 8-bit RGB, filter 0, one IDAT: the restricted profile `ReaderPNGValidator` and `admitReaderImage` accept.
    public static func png(_ image: RGB) -> Data {
        let row = image.width * 3 + 1
        var raw = [UInt8](repeating: 0, count: row * image.height)
        for y in 0..<image.height {
            raw.replaceSubrange((y * row + 1)..<((y + 1) * row), with: image.pixels[(y * image.width * 3)..<((y + 1) * image.width * 3)])
        }
        var compressedLength = compressBound(uLong(raw.count))
        var compressed = [UInt8](repeating: 0, count: Int(compressedLength))
        let status = compress2(&compressed, &compressedLength, raw, uLong(raw.count), 6)
        precondition(status == Z_OK)
        compressed.removeSubrange(Int(compressedLength)...)
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            var out = withUnsafeBytes(of: UInt32(body.count).bigEndian, Array.init) + Array(type.utf8) + body
            let crc = out[4...].withUnsafeBufferPointer { crc32(0, $0.baseAddress, uInt($0.count)) }
            out += withUnsafeBytes(of: UInt32(crc).bigEndian, Array.init)
            return out
        }
        var header = withUnsafeBytes(of: UInt32(image.width).bigEndian, Array.init) + withUnsafeBytes(of: UInt32(image.height).bigEndian, Array.init)
        header += [8, 2, 0, 0, 0]
        return Data([137, 80, 78, 71, 13, 10, 26, 10] + chunk("IHDR", header) + chunk("IDAT", compressed) + chunk("IEND", []))
    }
}
