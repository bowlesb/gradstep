import Foundation

// Structure first (docs/architecture/FIGURE_VIEW.md "Structure first"; subfigure detector round 3: 15.7 % of arXiv HTML
// figures already hold two or more images, 9.6 % with sub-captions). When the reader bundle's figure has several images,
// its parts are exact, no model needed: each image (or each sub-caption's images) is one band of the composed image the
// request carries (ChatFigureFinder.composite: every image scaled to the widest one's width, stacked top to bottom with 2 %
// of the width of white between them). This reads that structure from the figure's own markup in the bundle, describes it
// to the model next to the caption (so its sections line up), and matches the walkthrough's sections to it: by sub-caption
// letter (or label), then by a box that is clearly one band, then by order when the counts agree. A matched part is shown
// as its band, at the highest confidence (FigureFraming `exact`).
// The browser's apps/web/src/lib/figure-structure.ts is the same rules and numbers; both are checked against
// tests/fixtures/figure-crops/structure.json.

/// A figure's own structure: its sub-figures (at least two, all within the composed image), how many panel images the
/// figure has and how many of its images the composed image holds, and the composed image's size before scaling.
public struct FigureStructure: Equatable, Sendable {
    /// One sub-figure: its letter ("a"; nil when neither it nor the caption names one), its sub-caption's words (without the
    /// letter), the label the model is asked to use ("(a)", else "Image 2"), its images (indices into the figure's asset
    /// paths) and its band of the composed image, as fractions.
    public struct Part: Equatable, Sendable {
        public let letter: String?
        public let caption: String
        public let label: String
        public let images: [Int]
        public let rect: CropRect
    }
    public let parts: [Part]
    public let images: Int
    public let composed: Int
    public let width: Int
    public let height: Int

    /// Every threshold of the structure, in one place (the browser's `STRUCTURE`; the fixture states them).
    public enum Parameters {
        /// Images composed into the one image a request carries (ChatFigureFinder.maximumPanels).
        public static let maxImages = 4
        /// A walkthrough box matches a sub-figure when their intersection over union is at least this.
        public static let boxMatch = 0.6
        /// The longest sub-caption quoted to the model, in characters.
        public static let captionChars = 100
        /// The selection's limit (`ChatGenerationRequest.maximumSelectionScalars`): the note is left out when it doesn't fit.
        public static let quoteScalars = 4_000
        public static var all: [String: Double] {
            ["maxImages": Double(maxImages), "boxMatch": boxMatch, "captionChars": Double(captionChars), "quoteScalars": Double(quoteScalars)]
        }
    }

    /// The composed image's layout (ChatFigureFinder.composite): width, height, and each image's band [top, bottom].
    public static func stackLayout(_ sizes: [(width: Int, height: Int)]) -> (width: Int, height: Int, bands: [(top: Int, bottom: Int)]) {
        let width = sizes.map(\.width).max() ?? 0, gap = max(1, Int((Double(width) * 0.02).rounded()))
        var bands: [(top: Int, bottom: Int)] = [], top = 0
        for size in sizes {
            let h = Int((Double(size.height) * Double(width) / Double(size.width)).rounded())
            bands.append((top, top + h)); top += h + gap
        }
        return (width, top - gap, bands)
    }

    /// A sub-caption's letter and words: "(a) Routing criticality", "a) Routing criticality"; nil for any other paragraph.
    public static func subcaption(_ text: String) -> (letter: String, words: String)? {
        for pattern in [#"^\(([a-zA-Z])\)\s*([\s\S]*)$"#, #"^([a-z])\)\s+([\s\S]*)$"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let letter = Range(m.range(at: 1), in: text), let words = Range(m.range(at: 2), in: text) else { continue }
            return (text[letter].lowercased(), text[words].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// The structure of a figure block's markup (the bundle's `<figure data-reader-figure>`): its panel images in order (an
    /// `<img>` outside a paragraph; legend symbols inside words are not panels), each run of images followed by
    /// sub-captions ("(a) …" paragraphs: one for the run, or one per image), else the caption's letters in order when it
    /// names exactly as many panels as there are images. `assetPaths` are the figure's (the composed image's order); `sizes`
    /// the images' pixel sizes (manifest). Nil when the figure has fewer than two sub-figures in the composed image.
    public static func make(markup: String, assetPaths: [String], sizes: [(width: Int, height: Int)?], caption: String) -> FigureStructure? {
        let composed = min(Parameters.maxImages, assetPaths.count)
        guard composed >= 2, sizes.count >= composed else { return nil }
        let known = sizes.prefix(composed).compactMap { $0 }
        guard known.count == composed, known.allSatisfy({ $0.width > 0 && $0.height > 0 }) else { return nil }
        let layout = stackLayout(known)
        // The figure's own content, its caption left out.
        let body = markup.replacing(/<figcaption\b[\s\S]*?<\/figcaption>/, with: "")
        enum Token { case image(Int), sub(letter: String, words: String) }
        var tokens: [Token] = [], seen = Set<Int>()
        let regex = try! NSRegularExpression(pattern: #"<img\b[^>]*>|<p\b[^>]*>([\s\S]*?)</p>"#)
        for m in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let whole = Range(m.range, in: body) else { continue }
            let tag = String(body[whole])
            if tag.hasPrefix("<img") {
                if tag.contains(/\sclass="[^"]*reader-inline-image/) { continue }
                let src = tag.firstMatch(of: /\ssrc="([^"]*)"/).map { String($0.output.1) } ?? ""
                if let index = assetPaths.firstIndex(of: src), !seen.contains(index) { seen.insert(index); tokens.append(.image(index)) }
            } else {
                let inner = Range(m.range(at: 1), in: body).map { String(body[$0]) } ?? ""
                if let sub = subcaption(FigureCaptionText.plain(inner)) { tokens.append(.sub(letter: sub.letter, words: sub.words)) }
            }
        }
        // Runs of images, each with the sub-captions that follow it.
        var groups: [(images: [Int], subs: [(letter: String, words: String)])] = [([], [])]
        for token in tokens {
            switch token {
            case .image(let index):
                if !groups[groups.count - 1].subs.isEmpty { groups.append(([], [])) }
                groups[groups.count - 1].images.append(index)
            case .sub(let letter, let words): groups[groups.count - 1].subs.append((letter, words))
            }
        }
        var parts: [(letter: String?, caption: String, images: [Int])] = []
        for g in groups where !g.images.isEmpty {
            if g.subs.count == 1 { parts.append((g.subs[0].letter, g.subs[0].words, g.images)) }
            else if g.subs.count == g.images.count { for (i, image) in g.images.enumerated() { parts.append((g.subs[i].letter, g.subs[i].words, [image])) } }
            else { for image in g.images { parts.append((nil, "", [image])) } }
        }
        // A letter names one part (the first).
        var used = Set<String>()
        parts = parts.map { p in
            guard let letter = p.letter else { return p }
            if used.contains(letter) { return (nil, "", p.images) }
            used.insert(letter); return p
        }
        // No sub-captions: the caption's letters, in order, when it names exactly as many panels.
        let letters = FigureFraming.captionLetters(caption)
        if !parts.contains(where: { $0.letter != nil }), letters.count >= 2, letters.count == parts.count {
            parts = parts.enumerated().map { (letters[$0.offset], $0.element.caption, $0.element.images) }
        }
        let images = parts.reduce(0) { $0 + $1.images.count }
        let inside = parts.filter { $0.images.allSatisfy { $0 < composed } }
        guard inside.count >= 2 else { return nil }
        let H = Double(layout.height)
        return FigureStructure(parts: inside.enumerated().map { k, p in
            let top = p.images.map { layout.bands[$0].top }.min()!, bottom = p.images.map { layout.bands[$0].bottom }.max()!
            return Part(letter: p.letter, caption: p.caption, label: p.letter.map { "(\($0))" } ?? "Image \(k + 1)", images: p.images,
                        rect: CropRect(0, FigureFraming.round6(Double(top) / H), 1, FigureFraming.round6(Double(bottom) / H)))
        }, images: images, composed: composed, width: layout.width, height: layout.height)
    }

    private static func fraction(_ v: Double) -> String {
        let n = Int((v * 100).rounded())
        return n >= 100 ? "1.00" : "0." + (n < 10 ? "0" : "") + String(n)
    }
    private static func shorten(_ text: String, _ limit: Int) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count > limit else { return text }
        var cut = String(String.UnicodeScalarView(scalars.prefix(limit - 1)))
        while let last = cut.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) { cut.unicodeScalars.removeLast() }
        return cut + "…"
    }

    /// The structure as the model reads it, after the caption: each sub-figure's label, sub-caption and band.
    public var note: String {
        var lines = ["The image stacks this figure's \(parts.count) sub-figures top to bottom, each across its full width (y: fractions of the image's height):"]
        for p in parts {
            let words = p.caption.isEmpty ? "" : " " + Self.shorten(p.caption, Parameters.captionChars)
            lines.append("- \(p.label)\(words): y \(Self.fraction(p.rect.y0))–\(Self.fraction(p.rect.y1))")
        }
        if images > composed { lines.append("Only the first \(composed) of its \(images) images are in the image.") }
        lines.append("Give each its own panel card, labelled as listed, in this order.")
        return lines.joined(separator: "\n")
    }

    /// The walkthrough's selection: the caption, then the structure when the figure has one and both fit the limit.
    public static func quote(caption: String, _ structure: FigureStructure?) -> String {
        guard let structure else { return caption }
        let quote = caption + "\n\n" + structure.note
        return quote.unicodeScalars.count <= Parameters.quoteScalars ? quote : caption
    }

    /// Whether this structure describes a composed image of this size (its aspect within 2 %).
    public func fits(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && abs((Double(self.width) / Double(self.height)) / (Double(width) / Double(height)) - 1) <= 0.02
    }

    /// A walkthrough section as matching needs it: its label, title, kind and box (fractions), if any.
    public struct Section: Sendable {
        public let label: String, title: String, kind: String?, box: CropRect?
        public init(label: String, title: String, kind: String? = nil, box: CropRect? = nil) { self.label = label; self.title = title; self.kind = kind; self.box = box }
    }

    /// Which sub-figure each section shows (an index into `parts`), or nil. Panel sections only; a sub-figure is matched
    /// once. First by letter (the label's, else the title's when there is no label) or by the label the note gave
    /// ("Image 2"); then by a box whose intersection over union with one band is at least `boxMatch` (a section lettered
    /// otherwise is not moved); then, when there are exactly as many panel sections as sub-figures, the unboxed rest in
    /// order (a letter must not disagree). A section whose label names two panels ("(a) and (b)") is matched by none of
    /// these and stops the order step: it shows a group, not one sub-figure.
    public static func match(_ sections: [Section], _ structure: FigureStructure?) -> [Int?] {
        var out = [Int?](repeating: nil, count: sections.count)
        guard let s = structure else { return out }
        var taken = Set<Int>()
        let panels = sections.indices.filter { sections[$0].kind == nil || sections[$0].kind == "panel" }
        // A label naming two panels ("(a) and (b)") names no one sub-figure.
        func letter(_ x: Section) -> String? { let text = x.label.isEmpty ? x.title : x.label; return FigureFraming.captionLetters(text).count > 1 ? nil : FigureFraming.labelLetter(text) }
        func normal(_ t: String) -> String { t.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        func agrees(_ x: Section, _ k: Int) -> Bool { guard let l = letter(x), let p = s.parts[k].letter else { return true }; return l == p }
        for i in panels {
            let x = sections[i], l = letter(x)
            if let k = s.parts.indices.first(where: { k in !taken.contains(k) && ((l != nil && s.parts[k].letter == l) || (!x.label.isEmpty && normal(x.label) == normal(s.parts[k].label))) }) {
                out[i] = k; taken.insert(k)
            }
        }
        func area(_ b: CropRect) -> Double { max(0, b.x1 - b.x0) * max(0, b.y1 - b.y0) }
        for i in panels where out[i] == nil {
            guard let box = sections[i].box else { continue }
            var best = -1, score = 0.0
            for (k, p) in s.parts.enumerated() where !taken.contains(k) {
                let shared = area(box.intersection(p.rect)), v = shared / max(1e-9, area(box) + area(p.rect) - shared)
                if v > score { best = k; score = v }
            }
            if best >= 0, score >= Parameters.boxMatch, agrees(sections[i], best) { out[i] = best; taken.insert(best) }
        }
        // In order only when every panel section can be one sub-figure (none names two panels).
        if panels.count == s.parts.count, panels.allSatisfy({ FigureFraming.captionLetters(sections[$0].label.isEmpty ? sections[$0].title : sections[$0].label).count <= 1 }) {
            for (k, i) in panels.enumerated() where out[i] == nil && sections[i].box == nil && !taken.contains(k) && agrees(sections[i], k) {
                out[i] = k; taken.insert(k)
            }
        }
        return out
    }
}
