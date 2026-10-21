import CoreGraphics
import Foundation

// How each AI-boxed part of a figure is framed (owner, 2026-10-21: "we present it as a crop of the whole thing, that they
// can expand, rather than an actual crop"; docs/architecture/FIGURE_VIEW.md "Parts as viewports"). A part card is a
// viewport into the whole figure: the figure on its white background, scaled and placed so the part's frame fills the
// card. How tightly it frames the part follows a confidence worked out from signals the device already has: completion
// (how much the box had to grow, or whether it still cuts ink), the caption's panel letters, and how the parts sit against
// each other (a neighbour's ink inside the frame, slivers); a hook takes the subfigure detector's agreement later. High: the
// part and its margin, as a crop looked; medium: looser, the part outlined; low: the whole figure, the part outlined. A
// caption that names its panels caps the parts: extra ones are outlines on the whole figure. A part that is one of the
// figure's own sub-figures (FigureStructure: its images in the bundle) is exact: its band, tight. When the AI's parts number
// neither the caption's lettered panels nor the figure's own sub-figures (count disagreement, subfigure detector round 3),
// its other parts show the whole figure with the part outlined.
// The browser's apps/web/src/lib/figure-framing.ts is the same rules and numbers; both are checked against
// tests/fixtures/figure-crops/framing.json.

public enum FigureFraming {
    /// Every threshold of the framing, in one place (the browser's `FRAMING` holds the same values; the shared fixture states
    /// them and both test suites check them).
    public enum Parameters {
        /// A score at or above `high` frames tightly; at or above `medium`, loosely with an outline; else the whole figure.
        public static let high = 0.75, medium = 0.45
        /// Completion growth (area added ÷ the AI box's area): free up to `growthFree`, then `growthPerUnit` per unit.
        public static let growthFree = 0.5, growthPerUnit = 0.6, growthMaxPenalty = 0.5
        /// A part's own letter isn't the caption's (the caption names L ≥ 2 panels).
        public static let countPenalty = 0.3
        /// Count disagreement: two or more parts, and their number is neither the caption's L ≥ 2 lettered panels nor the
        /// figure's own S ≥ 2 sub-figures (whichever it states): every part not exact scores at most this (the whole figure).
        public static let countCap = 0.3
        /// A neighbour's ink inside the part (the largest share of a component another part owns inside this region).
        public static let intrusionFree = 0.02, intrusionBase = 0.26, intrusionMaxPenalty = 0.4
        /// A sliver: narrower than `sliverSide` of the figure on either side, or smaller than `sliverArea` of it.
        public static let sliverSide = 0.08, sliverArea = 0.015, sliverPenalty = 0.3
        /// The detector's agreement (IoU of its best matching part), when there is one. Not wired yet.
        public static let detectorAgree = 0.7, detectorMaxPenalty = 0.4
        /// Without the pixels to check a box: medium.
        public static let uncheckedScore = 0.6
        /// Looser framing: each side extended by this share of the part's size (never less than the background margin).
        public static let looseFraction = 0.18
        /// The white veil over the rest of the figure at rest (opaque tight, soft loose, none whole), and once revealed.
        public static let veilHigh = 1.0, veilMedium = 0.4, veilLow = 0.0, veilRevealed = 0.4

        /// As the fixture states them (`parameters`), for the test that both ports agree.
        public static var all: [String: Double] {
            ["high": high, "medium": medium, "growthFree": growthFree, "growthPerUnit": growthPerUnit, "growthMaxPenalty": growthMaxPenalty,
             "countPenalty": countPenalty, "countCap": countCap, "intrusionFree": intrusionFree, "intrusionBase": intrusionBase, "intrusionMaxPenalty": intrusionMaxPenalty,
             "sliverSide": sliverSide, "sliverArea": sliverArea, "sliverPenalty": sliverPenalty, "detectorAgree": detectorAgree,
             "detectorMaxPenalty": detectorMaxPenalty, "uncheckedScore": uncheckedScore, "looseFraction": looseFraction,
             "veilHigh": veilHigh, "veilMedium": veilMedium, "veilLow": veilLow, "veilRevealed": veilRevealed]
        }
    }

    public enum Level: String, Sendable { case high, medium, low }
    public enum Reason: String, Sendable { case cut, grew, count, letter, overlap, sliver, detector, unchecked, extra }

    /// Distinct panel letters a caption names: "(a)", "a) " and "\textbf{(a)}" (policy.caption_letters).
    public static func captionLetters(_ caption: String) -> [String] {
        var letters = Set<String>()
        for (pattern, lower) in [(#"\(([a-hA-H])\)"#, true), (#"(?<![\w\\])([a-h])\)\s"#, false), (#"\\textbf\{\s*\(?([a-hA-H])\)?\s*[.:]?\s*\}"#, true)] {
            for m in matches(pattern, caption) { letters.insert(lower ? m.lowercased() : m) }
        }
        return letters.sorted()
    }

    /// The panel letter a part's label names: "(b)", "(b) Win rate", "b) Win rate", "b. Win rate", "b", "B", "Panel b"
    /// (not "A closer look").
    public static func labelLetter(_ label: String) -> String? {
        for (pattern, options) in [(#"\(([a-hA-H])\)"#, NSRegularExpression.Options()), (#"^\s*([a-hA-H])[).:]?\s*$"#, []), (#"^\s*([a-h])[).:]\s"#, []),
                                   (#"\bpanel\s+([a-hA-H])\b"#, .caseInsensitive)] {
            if let m = matches(pattern, label, options: options).first { return m.lowercased() }
        }
        return nil
    }

    /// Which parts the caption has room for: when it names L ≥ 2 panels and more parts were boxed, the parts whose labels
    /// name a caption letter (the first for each), then unlettered parts in order, up to L. Every part otherwise.
    public static func keptParts(_ labels: [String], letters: [String]) -> [Bool] {
        let L = letters.count
        guard L >= 2, labels.count > L else { return labels.map { _ in true } }
        var kept = labels.map { _ in false }, used = Set<String>()
        for (i, label) in labels.enumerated() {
            if let c = labelLetter(label), letters.contains(c), !used.contains(c) { used.insert(c); kept[i] = true }
        }
        var room = L - used.count
        for (i, label) in labels.enumerated() where !kept[i] && room > 0 && labelLetter(label) == nil { kept[i] = true; room -= 1 }
        return kept
    }

    private static func matches(_ pattern: String, _ text: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { m in Range(m.range(at: 1), in: text).map { String(text[$0]) } }
    }

    static func round6(_ v: Double) -> Double { (v * 1e6).rounded() / 1e6 }

    /// Every part of one set (a walkthrough's boxes, a chat answer's parts, one extracted part) framed, on the ink of the
    /// image the request carried (completed together, extras left out), or unchecked without it (`width`/`height` give the
    /// size then). Also the share of the figure's ink the kept parts' completed crops show (the whole figure for a part that
    /// couldn't be completed; nil without ink or boxes), for the coverage note.
    /// `exact`: each part's exact region when it is one of the figure's own sub-figures (`FigureStructure.match`), as
    /// fractions; nil for a part the AI boxed. `structureParts`: how many sub-figures the figure's own structure has (0
    /// without one), for the count check.
    public static func frame(_ ink: FigureInk?, width: Int, height: Int, boxes: [CropRect], caption: String = "", labels: [String] = [],
                             detector: [Double?]? = nil, exact: [CropRect?]? = nil, structureParts: Int = 0) -> (parts: [FramedPart], coverage: Double?) {
        let W = Double(ink?.width ?? width), H = Double(ink?.height ?? height)
        guard !boxes.isEmpty, W > 0, H > 0 else { return ([], nil) }
        let pad = Double(FigureCropCompletion.padding(width: Int(W), height: Int(H))), padX = pad / W, padY = pad / H
        let letters = captionLetters(caption), names = boxes.indices.map { $0 < labels.count ? labels[$0] : "" }
        // A sub-figure of the figure's own is exact: always kept, its band its region (and its box for completion).
        let exact: [CropRect?] = boxes.indices.map { k in exact.flatMap { k < $0.count ? $0[k] : nil } }
        let shape = boxes.indices.map { exact[$0] ?? boxes[$0] }
        let kept = zip(keptParts(names, letters: letters), exact).map { $0 || $1 != nil }
        let keptIndex = boxes.indices.filter { kept[$0] }, extras = boxes.count - keptIndex.count
        // Count disagreement: two or more parts whose number is neither the caption's lettered panels nor the figure's own
        // sub-figures (when either is stated).
        let L = letters.count, S = structureParts, N = boxes.count
        let disagree = N >= 2 && (L >= 2 || S >= 2) && !(L >= 2 && N == L) && !(S >= 2 && N == S)
        func px(_ b: CropRect) -> CropRect { CropRect(b.x0 * W, b.y0 * H, b.x1 * W, b.y1 * H) }
        let done = ink.flatMap { ink in keptIndex.isEmpty ? nil : FigureCropCompletion.complete(ink, fractions: keptIndex.map { shape[$0] }) }
        let crops: [CropRect?] = boxes.indices.map { k in keptIndex.firstIndex(of: k).flatMap { done?.crops[$0] } }
        let regions = boxes.indices.map { k in exact[k].map(px) ?? crops[k] ?? px(boxes[k]) }
        let owner = ink.flatMap { ink in done.map { _ in FigureCropCompletion.owners(ink.components, keptIndex.map { px(shape[$0]) }) } } ?? []
        let parts = boxes.indices.map { k -> FramedPart in
            let region = regions[k]
            var reasons: [Reason] = [], score = 1.0
            if exact[k] != nil { /* the figure's own sub-figure: exact */ }
            else if !kept[k] { reasons.append(.extra); score = 0 }
            else if done == nil { reasons.append(.unchecked); score = Parameters.uncheckedScore }
            else if crops[k] == nil { reasons.append(.cut); score = 0 }
            else {
                let growth = region.area / max(1, px(boxes[k]).area) - 1
                let grew = min(Parameters.growthMaxPenalty, max(0, growth - Parameters.growthFree) * Parameters.growthPerUnit)
                if grew > 0 { reasons.append(.grew); score -= grew }
            }
            if score > 0, exact[k] == nil {
                let own = labelLetter(names[k])
                if disagree { reasons.append(.count) }
                else if letters.count >= 2, let own, !letters.contains(own) { reasons.append(.letter); score -= Parameters.countPenalty }
                if let ink, done != nil, let me = keptIndex.firstIndex(of: k) {
                    let wide = 0.5 * W * H
                    var intrusion = 0.0
                    for (ci, c) in ink.components.enumerated() {
                        let o = owner[ci]
                        guard let ok = o.k, ok != me, o.frac >= 0.5, c.box.area <= wide else { continue }
                        intrusion = max(intrusion, c.box.intersection(region).area / max(1, c.box.area))
                    }
                    if intrusion > Parameters.intrusionFree { reasons.append(.overlap); score -= min(Parameters.intrusionMaxPenalty, Parameters.intrusionBase + intrusion) }
                }
                let w = (region.x1 - region.x0) / W, h = (region.y1 - region.y0) / H
                if w < Parameters.sliverSide || h < Parameters.sliverSide || w * h < Parameters.sliverArea { reasons.append(.sliver); score -= Parameters.sliverPenalty }
                if let agreement = detector?[safe: k] ?? nil, agreement < Parameters.detectorAgree {
                    reasons.append(.detector); score -= Parameters.detectorMaxPenalty * (Parameters.detectorAgree - agreement) / Parameters.detectorAgree
                }
                if disagree { score = min(score, Parameters.countCap) }
            }
            score = round6(min(1, max(0, score)))
            let level: Level = score >= Parameters.high ? .high : score >= Parameters.medium ? .medium : .low
            let frame: CropRect
            switch level {
            case .high: frame = CropRect(region.x0 - pad, region.y0 - pad, region.x1 + pad, region.y1 + pad)
            case .medium:
                let ex = max(pad, Parameters.looseFraction * (region.x1 - region.x0)), ey = max(pad, Parameters.looseFraction * (region.y1 - region.y0))
                func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
                frame = CropRect(clamp(region.x0 - ex, -pad, W + pad), clamp(region.y0 - ey, -pad, H + pad), clamp(region.x1 + ex, -pad, W + pad), clamp(region.y1 + ey, -pad, H + pad))
            case .low: frame = CropRect(-pad, -pad, W + pad, H + pad)
            }
            func f(_ r: CropRect) -> CropRect { CropRect(round6(r.x0 / W), round6(r.y0 / H), round6(r.x1 / W), round6(r.y1 / H)) }
            return FramedPart(level: level, score: score, reasons: reasons, frame: f(frame), region: f(region), padX: padX, padY: padY,
                              veil: level == .high ? Parameters.veilHigh : level == .medium ? Parameters.veilMedium : Parameters.veilLow,
                              outlined: level != .high, extra: !kept[k], exact: exact[k] != nil)
        }
        // The share of the ink the kept parts show: an exact part its band, another its completed crop (the whole figure when
        // it couldn't be completed).
        guard let done, let ink else { return (parts, nil) }
        if extras > 0 { return (parts, 1) }
        guard exact.contains(where: { $0 != nil }) else { return (parts, done.coverage ?? 1) }
        let shown = keptIndex.enumerated().map { i, k in exact[k].map(px) ?? done.crops[i] ?? CropRect(0, 0, W, H) }
        return (parts, ink.coverage(shown))
    }
}

/// One part as a card shows it. Rectangles are fractions of the image (the frame may reach past 0–1 by the margin).
public struct FramedPart: Equatable, Sendable {
    public let level: FigureFraming.Level
    /// 0–1; the level follows from it (a cut part and an extra part are 0).
    public let score: Double
    public let reasons: [FigureFraming.Reason]
    /// What the card frames (its aspect is the card's, in pixels of the image).
    public let frame: CropRect
    /// The part itself: its completed crop, or the AI's box where completion couldn't hold it (outlined).
    public let region: CropRect
    /// The figure's white margin around the image, as fractions of its width and height (the viewport's canvas).
    public let padX: Double, padY: Double
    /// The veil's opacity over the rest of the figure, and whether the outline shows, at rest.
    public let veil: Double
    public let outlined: Bool
    /// A part beyond the caption's panels: an outline on the whole figure, not a crop of its own.
    public let extra: Bool
    /// One of the figure's own sub-figures (its band of the composed image): exact, framed tightly.
    public var exact = false

    /// The frame's aspect (width ÷ height) in pixels of an image of this size: the card's.
    public func aspect(width: Int, height: Int) -> Double {
        (frame.x1 - frame.x0) * Double(width) / max(1e-6, (frame.y1 - frame.y0) * Double(height))
    }
    /// The veil and outline as they show: at rest, or once the reader has zoomed or panned (a tight frame's veil turns soft
    /// and its outline shows, so what lies around the part reads as context).
    public func look(revealed: Bool) -> (veil: Double, outlined: Bool) {
        revealed ? (min(veil, FigureFraming.Parameters.veilRevealed), true) : (veil, outlined)
    }

    /// What a view of the figure shows (`view`: a rectangle in pixels of `image`, which may reach into the white margin),
    /// as a new image at `scale` pixels per image pixel: the figure on white, the veil over the rest of the figure and the
    /// part's outline (`outline` colour, `lineWidth` in output pixels). Chat's parts at rest and Save snippet use it.
    public func render(_ image: CGImage, view: CropRect, scale: Double, revealed: Bool, outline: CGColor, lineWidth: Double) -> CGImage? {
        let vw = view.x1 - view.x0, vh = view.y1 - view.y0
        let s = min(scale, 4096 / max(vw, vh)), width = max(1, Int((vw * s).rounded())), height = max(1, Int((vh * s).rounded()))
        guard vw > 0, vh > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let W = Double(image.width), H = Double(image.height), look = look(revealed: revealed)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Image pixels (top-left origin) to the context (bottom-left origin).
        func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> CGRect {
            CGRect(x: (x0 - view.x0) * s, y: Double(height) - (y1 - view.y0) * s, width: (x1 - x0) * s, height: (y1 - y0) * s)
        }
        context.interpolationQuality = .high
        context.draw(image, in: rect(0, 0, W, H))
        let part = rect(region.x0 * W, region.y0 * H, region.x1 * W, region.y1 * H)
        if look.veil > 0 {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: look.veil))
            context.addRect(CGRect(x: -1, y: -1, width: width + 2, height: height + 2)); context.addRect(part)
            context.fillPath(using: .evenOdd)
        }
        if look.outlined {
            context.setStrokeColor(outline); context.setLineWidth(lineWidth)
            context.stroke(part.insetBy(dx: -lineWidth, dy: -lineWidth))
        }
        return context.makeImage()
    }
    /// The frame at rest, as an image (chat's figure parts): `scale` pixels per image pixel.
    public func renderFrame(_ image: CGImage, scale: Double = 1, outline: CGColor, lineWidth: Double) -> CGImage? {
        let W = Double(image.width), H = Double(image.height)
        return render(image, view: CropRect(frame.x0 * W, frame.y0 * H, frame.x1 * W, frame.y1 * H), scale: scale, revealed: false, outline: outline, lineWidth: lineWidth)
    }
}

fileprivate extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
