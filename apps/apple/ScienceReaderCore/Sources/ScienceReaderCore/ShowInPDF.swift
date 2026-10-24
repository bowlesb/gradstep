import CoreGraphics
import Foundation

// Show in PDF (owner, 2026-10-24: "it would be neat to somehow have a feature where, wherever you select, it can guess where
// in the pdf that is and show it to you with a pop up that you can zoom around in"; docs/architecture/FIGURE_VIEW.md "Show in
// PDF"). A passage of an on-device reading is found again on its PDF: the reading's own record of where the block came from
// (provenance `blocks`, port revision 11) narrows the search to a page and a box, and the PDF's text layer, folded so that
// spacing, case, ligatures, accents and a word broken at a line's end don't matter, gives the exact words and their lines.
// Pure: the app reads the glyphs (DevicePDFTextLayer) and draws the page; this decides where.

/// What to find: the passage's text as the reading shows it, the text just around it (to tell repeated phrases apart),
/// and where the reading says its block came from.
public struct PDFPassageQuery: Equatable, Sendable {
    public var text: String
    public var before: String
    public var after: String
    /// The block's (or blocks') places on the PDF in reading order; empty for readings made before they were recorded.
    public var regions: [DevicePDFTextRegion]
    /// Without regions: the page the passage is likely on (its block's place in the reading × the page count), from 0,
    /// used only to choose between equally good matches.
    public var expectedPage: Double?

    public init(text: String, before: String = "", after: String = "", regions: [DevicePDFTextRegion] = [], expectedPage: Double? = nil) {
        self.text = text; self.before = before; self.after = after; self.regions = regions; self.expectedPage = expectedPage
    }
}

/// Where a passage is on the PDF: a page (from 0) and rectangles of it in points from the top left of the page as shown.
public struct PDFPassageLocation: Equatable, Sendable {
    public enum Match: Equatable, Sendable {
        /// The passage's words, exactly (folded), on these lines.
        case words
        /// Most of the passage's words in order (the reading differs from the PDF in places: a formula, a misread letter).
        case approximate
        /// No words found (a scanned page, text the model misread, an equation): the place the reading recorded for it.
        case region
    }
    public let page: Int
    /// The highlighted lines (or the recorded boxes), in reading order.
    public let lines: [CGRect]
    public let match: Match
    public init(page: Int, lines: [CGRect], match: Match) { self.page = page; self.lines = lines; self.match = match }
    /// All of it: what the view opens framed on.
    public var bounds: CGRect { lines.reduce(CGRect.null) { $0.union($1) } }
}

public enum PDFPassageLocator {
    /// The passage on the PDF: on the pages the reading recorded for it (its words there, else its recorded boxes), or,
    /// without a record, the best match anywhere in the document. Nil when there is nothing to show.
    /// `glyphs` reads a page's text layer (DevicePDFTextLayer.glyphs); it is asked only for the pages searched.
    public static func locate(_ query: PDFPassageQuery, pageCount: Int, glyphs: (Int) -> [DevicePDFGlyph]) -> PDFPassageLocation? {
        let needle = Array(fold(query.text).prefix(4_000))
        let regions = query.regions.filter { (0..<pageCount).contains($0.page) }
        var pages: [Int] = []
        for region in regions where !pages.contains(region.page) { pages.append(region.page) }
        if regions.isEmpty { pages = Array(0..<max(0, pageCount)) }
        var best: (score: Double, location: PDFPassageLocation)?
        if needle.count >= 2 {
            let before = Array(fold(query.before).suffix(contextLength)), after = Array(fold(query.after).prefix(contextLength))
            for page in pages {
                let stream = FoldedPage(glyphs(page))
                guard !stream.codes.isEmpty else { continue }
                let onPage = regions.filter { $0.page == page }.map(\.rect)
                for candidate in matches(needle, in: stream.codes) {
                    let picked = stream.glyphIndices(candidate.range)
                    guard let lines = lineRects(picked.map { stream.glyphs[$0] }), !lines.isEmpty else { continue }
                    var score = candidate.coverage * 10
                    if !onPage.isEmpty { score += 5 * inside(picked.map { stream.glyphs[$0] }, onPage) }
                    score += 2 * context(before: before, after: after, around: candidate.range, in: stream.codes)
                    if regions.isEmpty, let expected = query.expectedPage { score -= 0.1 * min(10, abs(Double(page) - expected)) }
                    if best == nil || score > best!.score {
                        best = (score, PDFPassageLocation(page: page, lines: lines, match: candidate.coverage >= 1 ? .words : .approximate))
                    }
                }
            }
        }
        if let best { return best.location }
        // Nothing matched: the reading's own record of where it read the block (its first page's boxes).
        guard let first = regions.first else { return nil }
        return PDFPassageLocation(page: first.page, lines: regions.filter { $0.page == first.page }.map(\.rect), match: .region)
    }

    // MARK: Folding

    /// Text as compared: compatibility forms (ligatures, wide and mathematical letters) to their plain letters, case and
    /// accents dropped, and only letters and digits kept, so spacing, punctuation and a hyphen at a line's break vanish.
    public static func fold(_ text: String) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(text.unicodeScalars.count)
        appendFolded(text, to: &out)
        return out
    }

    static func appendFolded(_ text: String, to out: inout [UInt32]) {
        // The common case, one ASCII letter or digit, without Foundation.
        let scalars = text.unicodeScalars
        if scalars.allSatisfy(\.isASCII) {
            for s in scalars {
                let v = s.value
                if (48...57).contains(v) || (97...122).contains(v) { out.append(v) }
                else if (65...90).contains(v) { out.append(v + 32) }
            }
            return
        }
        let folded = text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        for s in folded.unicodeScalars where s.properties.isAlphabetic || s.properties.numericType != nil {
            // Combining marks the folding kept (a letter's own accent in some scripts) are not letters to compare.
            if s.properties.generalCategory == .nonspacingMark || s.properties.generalCategory == .spacingMark { continue }
            out.append(s.properties.lowercaseMapping.unicodeScalars.first?.value ?? s.value)
        }
    }

    // MARK: Matching

    static let contextLength = 32
    /// The approximate match's piece of the passage, and how much of it must be found in order.
    static let piece = 6, minimumCoverage = 0.45

    struct Candidate: Equatable { let range: Range<Int>; let coverage: Double }

    /// Every exact occurrence of `needle` in `haystack`; with none, the best approximate one (pieces of the passage found in
    /// order at about the same offsets), when it covers enough of the passage.
    static func matches(_ needle: [UInt32], in haystack: [UInt32]) -> [Candidate] {
        let exact = occurrences(needle, in: haystack).map { Candidate(range: $0..<($0 + needle.count), coverage: 1) }
        if !exact.isEmpty { return exact }
        return approximate(needle, in: haystack).map { [$0] } ?? []
    }

    static func occurrences(_ needle: [UInt32], in haystack: [UInt32]) -> [Int] {
        guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
        var out: [Int] = []
        let first = needle[0], last = haystack.count - needle.count
        var i = 0
        while i <= last {
            if haystack[i] == first {
                var j = 1
                while j < needle.count && haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { out.append(i); if out.count >= 64 { break } }
            }
            i += 1
        }
        return out
    }

    /// The passage cut in pieces of `piece` letters; each piece's occurrences vote for where the passage starts; the start
    /// with the most different pieces (within a tolerance that admits a formula or a few letters more or less) wins.
    static func approximate(_ needle: [UInt32], in haystack: [UInt32]) -> Candidate? {
        guard needle.count >= 2 * piece, haystack.count >= piece else { return nil }
        var positions: [UInt64: [Int]] = [:]
        func key(_ a: [UInt32], _ at: Int) -> UInt64 {
            var h: UInt64 = 1469598103934665603
            for k in 0..<piece { h = (h ^ UInt64(a[at + k])) &* 1099511628211 }
            return h
        }
        for i in 0...(haystack.count - piece) { positions[key(haystack, i), default: []].append(i) }
        let pieces = stride(from: 0, through: needle.count - piece, by: piece).map { $0 }
        var votes: [(start: Int, piece: Int, at: Int)] = []
        for (n, offset) in pieces.enumerated() {
            for at in (positions[key(needle, offset)] ?? []).prefix(200) { votes.append((at - offset, n, at)) }
        }
        guard !votes.isEmpty else { return nil }
        votes.sort { $0.start < $1.start }
        let tolerance = max(12, needle.count / 4)
        var best: (count: Int, low: Int, high: Int)?
        var lo = 0, counts: [Int: Int] = [:]
        for hi in votes.indices {
            counts[votes[hi].piece, default: 0] += 1
            while votes[hi].start - votes[lo].start > tolerance {
                counts[votes[lo].piece]! -= 1
                if counts[votes[lo].piece] == 0 { counts[votes[lo].piece] = nil }
                lo += 1
            }
            if best == nil || counts.count > best!.count { best = (counts.count, lo, hi) }
        }
        guard let best else { return nil }
        let coverage = Double(best.count) / Double(pieces.count)
        guard best.count >= 2, coverage >= minimumCoverage else { return nil }
        // The span the window's pieces cover, each piece's first place in it (a repeated piece elsewhere doesn't stretch it).
        var firstAt: [Int: Int] = [:]
        for vote in votes[best.low...best.high] where firstAt[vote.piece] == nil { firstAt[vote.piece] = vote.at }
        let starts = firstAt.values
        guard let start = starts.min(), let end = starts.max() else { return nil }
        return Candidate(range: start..<min(haystack.count, end + piece), coverage: min(0.999, coverage))
    }

    /// How much of the text just before and after the passage (folded) the PDF has there too, 0…1.
    static func context(before: [UInt32], after: [UInt32], around range: Range<Int>, in haystack: [UInt32]) -> Double {
        guard !before.isEmpty || !after.isEmpty else { return 0 }
        var agreed = 0
        var i = before.count - 1, j = range.lowerBound - 1
        while i >= 0, j >= 0, before[i] == haystack[j] { agreed += 1; i -= 1; j -= 1 }
        var k = 0, m = range.upperBound
        while k < after.count, m < haystack.count, after[k] == haystack[m] { agreed += 1; k += 1; m += 1 }
        return Double(agreed) / Double(before.count + after.count)
    }

    /// The share of the glyphs whose centres lie in one of the boxes (grown by 3 points).
    static func inside(_ glyphs: [DevicePDFGlyph], _ boxes: [CGRect]) -> Double {
        guard !glyphs.isEmpty else { return 0 }
        let grown = boxes.map { $0.insetBy(dx: -3, dy: -3) }
        let n = glyphs.filter { g in grown.contains { $0.contains(CGPoint(x: (g.x0 + g.x1) / 2, y: (g.top + g.bottom) / 2)) } }.count
        return Double(n) / Double(glyphs.count)
    }

    // MARK: Lines

    /// Glyphs (in the content stream's order) as the rectangles of their lines: a glyph starts a new line when its middle is
    /// outside the current line's height or it jumps back to the left; lines that share a band and touch are joined.
    static func lineRects(_ glyphs: [DevicePDFGlyph]) -> [CGRect]? {
        var lines: [CGRect] = []
        for g in glyphs where !g.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && g.x1 > g.x0 - 0.01 && g.bottom > g.top - 0.01 {
            let box = CGRect(x: g.x0, y: g.top, width: max(0.5, g.x1 - g.x0), height: max(0.5, g.bottom - g.top))
            if var line = lines.last {
                let middle = box.midY, size = max(box.height, line.height)
                let sameBand = middle >= line.minY - 0.15 * size && middle <= line.maxY + 0.15 * size
                if sameBand && box.minX >= line.minX - 0.5 * size && box.minX <= line.maxX + 4 * size {
                    line = line.union(box); lines[lines.count - 1] = line; continue
                }
            }
            lines.append(box)
        }
        // A superscript or a formula drawn out of order makes a line of its own over another: joined to it.
        var joined: [CGRect] = []
        for line in lines {
            if let index = joined.firstIndex(where: { other in
                let overlap = min(other.maxY, line.maxY) - max(other.minY, line.minY)
                return overlap > 0.5 * min(other.height, line.height) && line.minX <= other.maxX + 6 && line.maxX >= other.minX - 6
            }) { joined[index] = joined[index].union(line) } else { joined.append(line) }
        }
        guard joined.count <= 1_000 else { return nil }
        return joined.map { $0.insetBy(dx: -1, dy: -1) }
    }
}

/// One page's text layer folded, each folded letter knowing its glyph.
struct FoldedPage {
    let glyphs: [DevicePDFGlyph]
    private(set) var codes: [UInt32] = []
    private var owners: [Int] = []

    init(_ glyphs: [DevicePDFGlyph]) {
        self.glyphs = glyphs
        codes.reserveCapacity(glyphs.count); owners.reserveCapacity(glyphs.count)
        for (i, g) in glyphs.enumerated() {
            let before = codes.count
            PDFPassageLocator.appendFolded(g.text, to: &codes)
            owners.append(contentsOf: repeatElement(i, count: codes.count - before))
        }
    }

    /// The glyphs from the first letter's to the last's, in stream order.
    func glyphIndices(_ range: Range<Int>) -> [Int] {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= owners.count else { return [] }
        let a = owners[range.lowerBound], b = owners[range.upperBound - 1]
        return a <= b ? Array(a...b) : Array(Set(owners[range])).sorted()
    }
}

// MARK: - Drawing a part of a page

extension DevicePDFRaster {
    /// The page as shown (its crop box turned by its /Rotate), in points: what `render` draws and the glyphs are measured in.
    public static func shownSize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        return rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// `region` of the page (points from the top left of the page as shown) at `pixelsPerPoint`, on white, drawn exactly as
    /// `render` draws the whole page: what a zoomed view shows sharp without drawing the rest of the page.
    public static func render(_ page: CGPDFPage, pixelsPerPoint density: Double, region: CGRect) -> CGImage? {
        let shown = shownSize(page)
        let clip = region.intersection(CGRect(origin: .zero, size: shown))
        guard !clip.isNull, density > 0, density.isFinite else { return nil }
        let width = Int((clip.width * density).rounded(.up)), height = Int((clip.height * density).rounded(.up))
        guard width > 0, height > 0, width * height <= 40_000_000,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(width) / clip.width, y: CGFloat(height) / clip.height)
        // Page space has its origin at the bottom left: the region's bottom edge is `shown.height - maxY` up from it.
        ctx.translateBy(x: -clip.minX, y: -(shown.height - clip.maxY))
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: shown), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }
}

// MARK: - Viewing

/// The pop-up's zoom: opening framed on the passage, never closer than `maximumFraction` of the view's width for a passage
/// (a single word doesn't fill the screen), never further out than the whole page.
public enum PDFPassageZoom {
    /// The zoom (view points per page point) and the page rectangle to centre, to show `focus` with a margin in `view`.
    public static func opening(focus: CGRect, page: CGSize, view: CGSize, maximumZoom: CGFloat) -> (zoom: CGFloat, centre: CGPoint) {
        let whole = FigureZoomMath.fitZoom(CGRect(origin: .zero, size: page), in: view)
        guard !focus.isNull, focus.width > 0, focus.height > 0 else { return (whole, CGPoint(x: page.width / 2, y: page.height / 2)) }
        // A margin of a sixth of the passage's size, at least 24 points of the page, at most the page.
        let margin = max(24, min(focus.width, focus.height) / 6)
        var framed = focus.insetBy(dx: -margin, dy: -margin)
        // A narrow passage (a word, a line's end) keeps some of its line in view: at least 45 % of the page's width.
        if framed.width < page.width * 0.45 { framed = framed.insetBy(dx: -(page.width * 0.45 - framed.width) / 2, dy: 0) }
        let zoom = min(maximumZoom, max(whole, FigureZoomMath.fitZoom(framed, in: view)))
        return (zoom, CGPoint(x: focus.midX, y: focus.midY))
    }

    /// The content offset that puts `centre` (page points) in the middle of `view` at `zoom`, kept on the page.
    public static func offset(centre: CGPoint, zoom: CGFloat, page: CGSize, view: CGSize) -> CGPoint {
        let proposed = CGPoint(x: centre.x * zoom - view.width / 2, y: centre.y * zoom - view.height / 2)
        return FigureZoomMath.clampedOffset(proposed, zoom: zoom, view: view, bounds: CGRect(origin: .zero, size: page))
    }
}
