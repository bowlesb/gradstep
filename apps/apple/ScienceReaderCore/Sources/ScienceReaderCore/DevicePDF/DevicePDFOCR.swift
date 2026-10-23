import CoreGraphics
import Foundation
import Vision

/// The text of a page whose PDF text layer is missing (a scan) or unreadable (fonts without a Unicode mapping, read as
/// `(cid:N)`), recognised from the page's own 150 dpi render with Apple's on-device text recogniser (Vision), so the
/// route still reads the paper instead of showing nothing or nonsense (degrade, never refuse; venue corpus 2026-10-22:
/// one CVPR 2025 paper of 31 has a text layer of `(cid:N)` only, and scanned papers have none).
///
/// Each recognised word becomes glyphs spread evenly over its box, in the font `GradstepOCR` (unknown to the tagger, so
/// read as prose; the converter counts these pages in its warnings). Math in such pages is read only where the layout
/// finds displays, by the formula recogniser from the image.
public enum DevicePDFOCR {
    public static let font = "GradstepOCR"

    /// Whether a page's glyphs are no text to read: fewer than 5 visible characters (a scan), or, of 20 or more, three in
    /// ten codes without a Unicode mapping (`(cid:N)`), private-use or replacement characters, or words that are no words
    /// (a font whose Unicode mapping names the wrong letters: "iJlLfNjPlJKLMN").
    public static func unreadable(_ glyphs: [DevicePDFGlyph]) -> Bool {
        let shown = glyphs.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if shown.count < 5 { return true }
        if shown.count < 20 { return false }
        let bad = shown.filter { g in
            if g.text.hasPrefix("(cid:") { return true }
            return g.text.unicodeScalars.contains { s in (0xE000...0xF8FF).contains(s.value) || s.value == 0xFFFD || s.value < 0x20 }
        }.count
        return Double(bad) >= 0.3 * Double(shown.count) || gibberish(shown)
    }

    /// Words (runs of letters at letter spacing on one line) of four letters or more: a quarter or more with a capital
    /// after a small letter inside them, or two in five with no vowel, is not text in any Latin-script language.
    static func gibberish(_ glyphs: [DevicePDFGlyph]) -> Bool {
        var words: [String] = [], current = "", last: DevicePDFGlyph?
        for g in glyphs {
            let letter = g.text.count == 1 && g.text.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
            let joined = last.map { l in abs(g.top - l.top) < 0.5 * max(1, g.size) && g.x0 - l.x1 < 0.2 * max(1, g.size) && g.x0 > l.x0 } ?? false
            if !letter || !joined { if current.count >= 4 { words.append(current) }; current = "" }
            if letter { current += g.text }
            last = g
        }
        if current.count >= 4 { words.append(current) }
        guard words.count >= 50 else { return false }
        let camel = words.filter { w in zip(w, w.dropFirst()).contains { $0.isLowercase && $1.isUppercase } }.count
        let vowels = Set("aeiouyAEIOUYàáâäèéêëìíîïòóôöùúûüÿ")
        let voiceless = words.filter { !$0.contains(where: vowels.contains) }.count
        return Double(camel) >= 0.25 * Double(words.count) || Double(voiceless) >= 0.4 * Double(words.count)
    }

    /// The page's text recognised from `image` (the page rendered at any resolution, the page's displayed orientation)
    /// as glyphs in points on a page of `size` points, top-left origin, in reading order of Vision's lines.
    public static func glyphs(image: CGImage, size: CGSize) -> [DevicePDFGlyph] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        let observations = (request.results ?? []).sorted { a, b in
            // Top to bottom, then left to right (Vision's normalised boxes have their origin at the bottom left).
            let ta = 1 - a.boundingBox.maxY, tb = 1 - b.boundingBox.maxY
            return abs(ta - tb) > 0.004 ? ta < tb : a.boundingBox.minX < b.boundingBox.minX
        }
        // Lines set sideways (arXiv's identifier down the margin) read as tall boxes that would cross the text's lines.
        let heights = observations.map { Double($0.boundingBox.height) }.sorted()
        let typical = heights.isEmpty ? 0 : heights[heights.count / 2]
        var out: [DevicePDFGlyph] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            if Double(observation.boundingBox.height) > 3 * typical && observation.boundingBox.height > observation.boundingBox.width { continue }
            let text = candidate.string
            var index = text.startIndex
            while index < text.endIndex {
                // One word at a time: its box from Vision, its characters spread evenly over it.
                guard let start = text[index...].firstIndex(where: { !$0.isWhitespace }) else { break }
                let end = text[start...].firstIndex(where: { $0.isWhitespace }) ?? text.endIndex
                index = end
                let word = text[start..<end]
                let box = (try? candidate.boundingBox(for: start..<end))?.boundingBox ?? observation.boundingBox
                // Vision's word box takes in ascenders and descenders and touches the lines above and below; the glyphs
                // keep its middle 70 % (a text layer's character boxes do not overlap the next line's) and an em of 0.8
                // of its height.
                // Its sides come in by 0.15 em, so neighbouring words (whose boxes Vision draws touching) keep a word gap.
                let fullTop = Double(1 - box.maxY) * size.height, fullBottom = Double(1 - box.minY) * size.height, h = fullBottom - fullTop
                let top = fullTop + 0.15 * h, bottom = fullBottom - 0.15 * h
                let inset = min(0.12 * h, 0.2 * Double(box.width) * size.width)
                let x0 = Double(box.minX) * size.width + inset, x1 = Double(box.maxX) * size.width - inset
                guard x1 > x0, bottom > top else { continue }
                let characters = Array(word), step = (x1 - x0) / Double(characters.count)
                for (k, character) in characters.enumerated() {
                    out.append(DevicePDFGlyph(text: String(character), x0: x0 + Double(k) * step, top: top, x1: x0 + Double(k + 1) * step,
                                              bottom: bottom, size: 0.8 * h, font: font, upright: true))
                }
            }
        }
        return out
    }

    /// The page's glyphs from its text layer, or recognised from its render when the layer is unreadable (and recognition
    /// finds more to read than the layer had).
    public static func glyphs(layer: [DevicePDFGlyph], image: CGImage, size: CGSize) -> [DevicePDFGlyph] {
        guard unreadable(layer) else { return layer }
        let recognised = glyphs(image: image, size: size)
        return recognised.count > layer.filter({ !$0.text.hasPrefix("(cid:") }).count ? recognised : layer
    }
}
