import CoreGraphics
import ImageIO
import Foundation

// The completeness step for AI-written figure crops (docs/reviews/SUBFIGURE_DETECTOR_20261021.md, integration step 1;
// docs/architecture/FIGURE_VIEW.md "Complete crops"). A port of scripts/subfigure-detector/app_crops.py (and the
// `policy.complete` it calls), checked against the shared fixtures in tests/fixtures/figure-crops/ as the browser's
// figure-crops.ts is. Pure geometry on the exact image the request carried: each box grows over the ink it cuts (labels,
// ticks, its own clipped body), unowned context ink joins the nearest box when the boxes tile the figure, and a box that
// still cuts ink shows the whole figure instead. No model, no network; run it off the main actor.

/// [x0, y0, x1, y1]: pixels of the ink image (half-open), or fractions of it.
public struct CropRect: Equatable, Sendable {
    public var x0: Double, y0: Double, x1: Double, y1: Double
    public init(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) { self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1 }
    var area: Double { max(0, x1 - x0) * max(0, y1 - y0) }
    func intersection(_ b: CropRect) -> CropRect { CropRect(max(x0, b.x0), max(y0, b.y0), min(x1, b.x1), min(y1, b.y1)) }
    func union(_ b: CropRect) -> CropRect { CropRect(min(x0, b.x0), min(y0, b.y0), max(x1, b.x1), max(y1, b.y1)) }
    func gap(_ b: CropRect) -> Double { hypot(max(0, max(x0, b.x0) - min(x1, b.x1)), max(0, max(y0, b.y0) - min(y1, b.y1))) }
}

/// The ink of one image: min(R, G, B) < 235, and its components (ink joined within the dilation radius, 4-connected), in
/// the raster order of their first dilated pixel (scipy.ndimage.label).
public struct FigureInk: Sendable {
    public struct Component: Equatable, Sendable { public let box: CropRect; public let pixels: Int }
    public let width: Int, height: Int
    let mask: [UInt8]
    public let inkPixels: Int
    public let components: [Component]

    public static let inkThreshold: UInt8 = 235, radiusFraction = 0.003

    /// From RGB(A) bytes: `bytesPerPixel` 3 or 4, rows `bytesPerRow` apart.
    public init?(pixels: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int, bytesPerPixel: Int) {
        guard width > 0, height > 0, bytesPerPixel >= 3, bytesPerRow >= width * bytesPerPixel, pixels.count >= (height - 1) * bytesPerRow + width * bytesPerPixel else { return nil }
        var mask = [UInt8](repeating: 0, count: width * height), ink = 0
        mask.withUnsafeMutableBufferPointer { m in
            for y in 0..<height {
                var p = y * bytesPerRow
                for x in 0..<width {
                    if min(pixels[p], pixels[p + 1], pixels[p + 2]) < Self.inkThreshold { m[y * width + x] = 1; ink += 1 }
                    p += bytesPerPixel
                }
            }
        }
        self.width = width; self.height = height; self.mask = mask; inkPixels = ink
        components = Self.components(mask, width, height)
    }

    /// An image drawn on white into 8-bit RGBA without colour conversion of its own (a JPEG or PNG the device decoded).
    public init?(image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width * height <= 40_000_000 else { return nil }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let made = bytes.withUnsafeBytes { FigureInk(pixels: $0, width: width, height: height, bytesPerRow: width * 4, bytesPerPixel: 4) }
        guard let made else { return nil }
        self = made
    }

    /// Python's round(): half to even.
    static func roundHalfEven(_ v: Double) -> Int {
        let f = v.rounded(.down), d = v - f
        return Int(d > 0.5 ? f + 1 : d < 0.5 ? f : (Int(f) % 2 == 0 ? f : f + 1))
    }

    /// Square dilation by r (zero outside the image), then 4-connected labels in raster order; each component's box and
    /// count are of its own ink pixels.
    static func components(_ mask: [UInt8], _ W: Int, _ H: Int) -> [Component] {
        let r = max(1, roundHalfEven(radiusFraction * Double(max(W, H))))
        var across = [UInt8](repeating: 0, count: W * H), dilated = [UInt8](repeating: 0, count: W * H)
        var out: [Component] = []
        mask.withUnsafeBufferPointer { m in
            across.withUnsafeMutableBufferPointer { a in
                for y in 0..<H {
                    let row = y * W
                    var count = 0
                    for x in 0..<min(W, r) { count += Int(m[row + x]) }
                    for x in 0..<W {
                        if x + r < W { count += Int(m[row + x + r]) }
                        if x - r - 1 >= 0 { count -= Int(m[row + x - r - 1]) }
                        a[row + x] = count > 0 ? 1 : 0
                    }
                }
            }
            across.withUnsafeBufferPointer { a in
                dilated.withUnsafeMutableBufferPointer { d in
                    for x in 0..<W {
                        var count = 0
                        for y in 0..<min(H, r) { count += Int(a[y * W + x]) }
                        for y in 0..<H {
                            if y + r < H { count += Int(a[(y + r) * W + x]) }
                            if y - r - 1 >= 0 { count -= Int(a[(y - r - 1) * W + x]) }
                            d[y * W + x] = count > 0 ? 1 : 0
                        }
                    }
                }
            }
            var seen = [UInt8](repeating: 0, count: W * H), stack = [Int32](repeating: 0, count: W * H)
            dilated.withUnsafeBufferPointer { d in
                seen.withUnsafeMutableBufferPointer { s in
                    stack.withUnsafeMutableBufferPointer { st in
                        for start in 0..<(W * H) where d[start] != 0 && s[start] == 0 {
                            var top = 0, x0 = Int.max, y0 = Int.max, x1 = Int.min, y1 = Int.min, pixels = 0
                            st[top] = Int32(start); top += 1; s[start] = 1
                            while top > 0 {
                                top -= 1
                                let i = Int(st[top]), x = i % W, y = i / W
                                if m[i] != 0 { pixels += 1; x0 = min(x0, x); x1 = max(x1, x + 1); y0 = min(y0, y); y1 = max(y1, y + 1) }
                                if x > 0, d[i - 1] != 0, s[i - 1] == 0 { s[i - 1] = 1; st[top] = Int32(i - 1); top += 1 }
                                if x + 1 < W, d[i + 1] != 0, s[i + 1] == 0 { s[i + 1] = 1; st[top] = Int32(i + 1); top += 1 }
                                if y > 0, d[i - W] != 0, s[i - W] == 0 { s[i - W] = 1; st[top] = Int32(i - W); top += 1 }
                                if y + 1 < H, d[i + W] != 0, s[i + W] == 0 { s[i + W] = 1; st[top] = Int32(i + W); top += 1 }
                            }
                            if pixels > 0 { out.append(Component(box: CropRect(Double(x0), Double(y0), Double(x1), Double(y1)), pixels: pixels)) }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Share of ink pixels inside the union of half-open rectangles (1 without ink).
    public func coverage(_ rects: [CropRect]) -> Double {
        guard inkPixels > 0 else { return 1 }
        var covered = 0
        mask.withUnsafeBufferPointer { m in
            for y in 0..<height {
                let yy = Double(y)
                let spans = rects.filter { yy >= $0.y0 && yy < $0.y1 }
                guard !spans.isEmpty else { continue }
                for x in 0..<width where m[y * width + x] != 0 {
                    let xx = Double(x)
                    if spans.contains(where: { xx >= $0.x0 && xx < $0.x1 }) { covered += 1 }
                }
            }
        }
        return Double(covered) / Double(inkPixels)
    }
}

/// The app step (app_crops.app_crops) and how a card presents its result.
public enum FigureCropCompletion {
    public static let maximumIterations = 4, tileMinimumCover = 0.7, orphanMaximumFraction = 0.5, figureWideFraction = 0.5,
                      otherOwnerFraction = 0.5, paddingFraction = 0.02, paddingMinimum = 8

    /// One crop per box: a pixel rectangle of the ink image, or nil where the card shows the whole figure. `coverage` is
    /// the share of ink inside the presented rectangles (whole-figure cards cover everything).
    public struct Result: Equatable, Sendable {
        public let crops: [CropRect?]
        public let tiled: Bool
        public let coverage: Double?
    }

    /// `fractions`: the AI's boxes as [x0, y0, x1, y1] fractions of the image.
    public static func complete(_ ink: FigureInk, fractions: [CropRect]) -> Result {
        let W = Double(ink.width), H = Double(ink.height)
        let boxes = fractions.map { CropRect($0.x0 * W, $0.y0 * H, $0.x1 * W, $0.y1 * H) }
        var grown = grow(boxes, ink, attachOrphans: false)
        let tiled = boxes.count >= 2 && ink.coverage(grown) >= tileMinimumCover
        if tiled { grown = grow(boxes, ink, attachOrphans: true) }
        let owner = owners(ink.components, boxes)
        let crops = grown.enumerated().map { k, b -> CropRect? in
            if cuts(ink, owner, k, b) { return nil }
            let x0 = max(0, b.x0.rounded(.down)), y0 = max(0, b.y0.rounded(.down)), x1 = min(W, b.x1.rounded(.up)), y1 = min(H, b.y1.rounded(.up))
            return x1 - x0 >= 2 && y1 - y0 >= 2 ? CropRect(x0, y0, x1, y1) : nil
        }
        let shown = crops.map { $0 ?? CropRect(0, 0, W, H) }
        return Result(crops: crops, tiled: tiled, coverage: shown.isEmpty ? nil : ink.coverage(shown))
    }

    /// Background around every presented crop (owner, 2026-10-21: "some margin around them"), in pixels of the ink image.
    public static func padding(width: Int, height: Int) -> Int {
        max(paddingMinimum, Int((paddingFraction * Double(min(width, height)) + 0.5).rounded(.down)))
    }

    /// Each component's crop: the original box holding the largest share of it (first on ties), and that share.
    static func owners(_ comps: [FigureInk.Component], _ orig: [CropRect]) -> [(k: Int?, frac: Double)] {
        comps.map { c in
            let a = c.box.area
            var best: Int?, frac = 0.0
            for (k, o) in orig.enumerated() {
                let f = c.box.intersection(o).area / max(1e-9, a)
                if f > frac { best = k; frac = f }
            }
            return (best, frac)
        }
    }

    /// policy.complete with the app options (orphans at most half the receiving box; ink inside a held orphan stays).
    static func grow(_ crops: [CropRect], _ ink: FigureInk, attachOrphans: Bool) -> [CropRect] {
        let W = Double(ink.width), H = Double(ink.height), comps = ink.components
        var boxes = crops
        let orig = crops, owner = owners(comps, orig)
        func swallows(_ k: Int, _ from: CropRect, _ to: CropRect) -> Bool {
            orig.indices.contains { j in j != k && to.intersection(orig[j]).area - from.intersection(orig[j]).area > 0.08 * orig[j].area }
        }
        for _ in 0..<maximumIterations {
            var changed = false
            for (ci, c) in comps.enumerated() {
                let cb = c.box, ca = cb.area
                for k in boxes.indices {
                    let b = boxes[k], ov = cb.intersection(b).area
                    if ov <= 0 { continue }
                    if ca > 1.5 * orig[k].area { continue }
                    if ov >= ca - 1e-6 { continue }
                    let (o, frac) = owner[ci]
                    if let o, o != k, frac >= 0.5 { continue }
                    if ca > 0.5 * orig[k].area, !(o == k && frac >= 0.6) { continue }
                    let nb = b.union(cb)
                    if swallows(k, b, nb) { continue }
                    if nb != b { boxes[k] = nb; changed = true }
                }
            }
            if !changed { break }
        }
        if attachOrphans, !boxes.isEmpty {
            var held: [CropRect] = []
            for c in comps {
                let cb = c.box, ca = cb.area
                if boxes.contains(where: { cb.intersection($0).area >= 0.999 * ca }) { continue }
                if held.contains(where: { cb.intersection($0).area >= 0.999 * ca }) { continue }
                if boxes.contains(where: { cb.intersection($0).area > 0 }), ca > 0.5 * W * H { continue }
                let d = boxes.enumerated().map { (dist: cb.gap($1), k: $0) }.sorted { $0.dist != $1.dist ? $0.dist < $1.dist : $0.k < $1.k }
                var near = [d[0].k]
                for e in d.dropFirst() where e.dist <= d[0].dist * 1.15 + 2 { near.append(e.k) }
                var attached = false
                for k in near {
                    if ca > orphanMaximumFraction * orig[k].area { continue }
                    let nb = boxes[k].union(cb)
                    if swallows(k, boxes[k], nb) { continue }
                    boxes[k] = nb; attached = true
                }
                if !attached { held.append(cb) }
            }
        }
        return boxes.map { CropRect(max(0, $0.x0), max(0, $0.y0), min(W, $0.x1), min(H, $0.y1)) }
    }

    /// Whether crop k's box still cuts a component it may own (figure-wide components and another crop's ink excepted).
    static func cuts(_ ink: FigureInk, _ owner: [(k: Int?, frac: Double)], _ k: Int, _ b: CropRect) -> Bool {
        let figure = figureWideFraction * Double(ink.width) * Double(ink.height)
        for (ci, c) in ink.components.enumerated() {
            let ov = c.box.intersection(b).area, ca = c.box.area
            if ov <= 0 || ov >= ca - 1e-6 || ca > figure { continue }
            let (o, frac) = owner[ci]
            if let o, o != k, frac >= otherOwnerFraction { continue }
            return true
        }
        return false
    }
}

/// What a card shows for one AI box: its region (fractions of the image), the background padding around it (fractions of
/// the image's width and height), and whether it is the whole figure because the crop could not be completed.
public struct PresentedCrop: Equatable, Sendable {
    public let region: CropRect
    public let whole: Bool
    public let padX: Double, padY: Double

    public init(ink width: Int, _ height: Int, crop: CropRect?) {
        let p = Double(FigureCropCompletion.padding(width: width, height: height)), W = Double(width), H = Double(height)
        let r = crop ?? CropRect(0, 0, W, H)
        region = CropRect(r.x0 / W, r.y0 / H, r.x1 / W, r.y1 / H); whole = crop == nil; padX = p / W; padY = p / H
    }

    /// Without the pixels to check (the image couldn't be decoded): the AI's box with the earlier 2 % of context, padded.
    public init(unchecked fractions: CropRect) {
        region = CropRect(max(0, fractions.x0 - 0.02), max(0, fractions.y0 - 0.02), min(1, fractions.x1 + 0.02), min(1, fractions.y1 + 0.02))
        whole = false; padX = 0.01; padY = 0.01
    }

    /// Every box of one figure, completed together on the ink of the image the request carried (or unchecked without it),
    /// with the share of the figure's ink the presented crops show (nil without the ink, or without boxes).
    public static func all(_ fractions: [CropRect], ink: FigureInk?) -> (crops: [PresentedCrop], coverage: Double?) {
        guard !fractions.isEmpty else { return ([], nil) }
        guard let ink else { return (fractions.map { PresentedCrop(unchecked: $0) }, nil) }
        let result = FigureCropCompletion.complete(ink, fractions: fractions)
        return (result.crops.map { PresentedCrop(ink: ink.width, ink.height, crop: $0) }, result.coverage)
    }

    /// The image a request carried (JPEG or PNG bytes), decoded as the device decodes it, as ink.
    public static func ink(of encoded: Data) -> FigureInk? {
        guard let source = CGImageSourceCreateWithData(encoded as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return FigureInk(image: image)
    }

    /// The region cut from an image of this size (outward rounding) on a background of its padding: a new image, drawn on
    /// white as figures are drawn in the paper. Nil when the region is under 2 px a side.
    public func image(from image: CGImage) -> CGImage? {
        let w = Double(image.width), h = Double(image.height)
        let left = max(0, Int((region.x0 * w + 1e-9).rounded(.down))), top = max(0, Int((region.y0 * h + 1e-9).rounded(.down)))
        let right = min(image.width, Int((region.x1 * w - 1e-9).rounded(.up))), bottom = min(image.height, Int((region.y1 * h - 1e-9).rounded(.up)))
        guard right - left >= 2, bottom - top >= 2, let cut = image.cropping(to: CGRect(x: left, y: top, width: right - left, height: bottom - top)) else { return nil }
        let px = max(1, Int((padX * w).rounded())), py = max(1, Int((padY * h).rounded()))
        let width = cut.width + 2 * px, height = cut.height + 2 * py
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        context.draw(cut, in: CGRect(x: px, y: py, width: cut.width, height: cut.height))
        return context.makeImage()
    }
}

public extension FigureWalkthrough.Box {
    /// As [x0, y0, x1, y1] fractions for the completeness step.
    var fractions: CropRect { CropRect(x, y, x + w, y + h) }
}

public extension ChatFigureParts.Part {
    var fractions: CropRect { CropRect(box[0], box[1], box[2], box[3]) }
}
