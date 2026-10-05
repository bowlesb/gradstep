// visual-check compare <before-dir> <after-dir> <out-dir>
//   For every PNG present in both (same relative path): a side-by-side image
//   (before | after | changed pixels in red) and the share of pixels changed.
//   Writes <out-dir>/report.md, most changed first.
// visual-check sheet <dir> <out.png>
//   One contact sheet of every PNG under <dir>, labelled, for a quick look.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

func load(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
func save(_ image: CGImage, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
}
func pngs(under root: URL) -> [String] {
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    var found: [String] = []
    while let url = enumerator?.nextObject() as? URL {
        if url.pathExtension == "png" { found.append(String(url.path.dropFirst(root.path.count + 1))) }
    }
    return found.sorted()
}
func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: width * height * 4)
    data.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.interpolationQuality = .medium
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return data
}
func label(_ context: CGContext, _ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 22) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    let attributed = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0, alpha: 1)])
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
}

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    print("usage: visual-check compare <before> <after> <out> | visual-check sheet <dir> <out.png>"); exit(2)
}

switch arguments[1] {
case "compare" where arguments.count >= 5:
    let before = URL(fileURLWithPath: arguments[2]), after = URL(fileURLWithPath: arguments[3]), out = URL(fileURLWithPath: arguments[4])
    var rows: [(String, Double, String)] = []
    let afterSet = Set(pngs(under: after))
    for path in pngs(under: before) where afterSet.contains(path) {
        guard let a = load(before.appendingPathComponent(path)), let b = load(after.appendingPathComponent(path)) else { continue }
        // Compare at a common working size (half of the after image).
        let w = max(b.width / 2, 1), h = max(b.height / 2, 1)
        let pa = rgba(a, width: w, height: h), pb = rgba(b, width: w, height: h)
        var mask = [UInt8](repeating: 0, count: w * h * 4), changed = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            let delta = abs(Int(pa[i]) - Int(pb[i])) + abs(Int(pa[i + 1]) - Int(pb[i + 1])) + abs(Int(pa[i + 2]) - Int(pb[i + 2]))
            let gray = UInt8((Int(pb[i]) + Int(pb[i + 1]) + Int(pb[i + 2])) / 6 + 128)
            if delta > 60 { changed += 1; mask[i] = 255; mask[i + 1] = 30; mask[i + 2] = 30 } else { mask[i] = gray; mask[i + 1] = gray; mask[i + 2] = gray }
            mask[i + 3] = 255
        }
        let fraction = Double(changed) / Double(w * h)
        // Side by side: before | after | changes, with a header.
        let header = 40, gap = 12, total = w * 3 + gap * 2
        guard let context = CGContext(data: nil, width: total, height: h + header, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: total, height: h + header))
        context.draw(a, in: CGRect(x: 0, y: 0, width: w, height: h))
        context.draw(b, in: CGRect(x: w + gap, y: 0, width: w, height: h))
        let maskImage = mask.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        if let maskImage { context.draw(maskImage, in: CGRect(x: (w + gap) * 2, y: 0, width: w, height: h)) }
        label(context, "before", x: 8, y: CGFloat(h + 12)); label(context, "after", x: CGFloat(w + gap + 8), y: CGFloat(h + 12))
        label(context, String(format: "changed %.2f%%", fraction * 100), x: CGFloat((w + gap) * 2 + 8), y: CGFloat(h + 12))
        let file = path.replacingOccurrences(of: ".png", with: "-compare.png")
        if let image = context.makeImage() { save(image, out.appendingPathComponent(file)) }
        rows.append((path, fraction, file))
    }
    rows.sort { $0.1 > $1.1 }
    var md = "# Visual comparison\n\nBefore: `\(before.path)`  \nAfter: `\(after.path)`\n\nChanged pixels (≥ 0.3 % flagged ⚠︎ — check it was intended; under 0.3 % is usually a caret or clock).\n\n"
    md += rows.map { String(format: "- %@ %.2f%% `%@` → `%@`", $0.1 >= 0.003 ? "⚠︎" : "·", $0.1 * 100, $0.0, $0.2) }.joined(separator: "\n") + "\n"
    let missing = Set(pngs(under: before)).symmetricDifference(afterSet).sorted()
    if !missing.isEmpty { md += "\nOnly on one side: " + missing.map { "`\($0)`" }.joined(separator: ", ") + "\n" }
    try md.write(to: out.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
    print("Compared \(rows.count) screens; \(rows.filter { $0.1 >= 0.003 }.count) changed ≥ 0.3%: \(out.appendingPathComponent("report.md").path)")

case "sheet":
    let root = URL(fileURLWithPath: arguments[2]), out = URL(fileURLWithPath: arguments[3])
    let paths = pngs(under: root).filter { !$0.hasSuffix("-compare.png") }
    guard !paths.isEmpty else { print("No PNGs under \(root.path)"); exit(1) }
    let cell = 300.0, columns = min(paths.count, 6), header = 34.0
    let images = paths.compactMap { path in load(root.appendingPathComponent(path)).map { (path, $0) } }
    let heights = images.map { cell * Double($0.1.height) / Double($0.1.width) }
    let rowHeight = (heights.max() ?? cell) + header
    let rowsCount = (images.count + columns - 1) / columns
    guard let context = CGContext(data: nil, width: Int(cell) * columns, height: Int(rowHeight) * rowsCount, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: Int(cell) * columns, height: Int(rowHeight) * rowsCount))
    for (index, (path, image)) in images.enumerated() {
        let column = index % columns, row = index / columns
        let top = Double(rowsCount - row) * rowHeight
        let height = heights[index]
        context.draw(image, in: CGRect(x: Double(column) * cell + 4, y: top - header - height, width: cell - 8, height: height - 8))
        label(context, String(path.replacingOccurrences(of: ".png", with: "").suffix(34)), x: CGFloat(Double(column) * cell + 6), y: CGFloat(top - 24), size: 15)
    }
    if let image = context.makeImage() { save(image, out) }
    print("Contact sheet: \(out.path) (\(images.count) screens)")

default:
    print("unknown command"); exit(2)
}
