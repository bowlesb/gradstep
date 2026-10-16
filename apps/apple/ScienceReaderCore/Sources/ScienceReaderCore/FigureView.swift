import CryptoKit
import Foundation

// The figure view (docs/architecture/FIGURE_VIEW.md): a walkthrough of one figure on request, part by part, with a box
// (a fraction of the image) where a small detail needs the reader's eye, and any part again, more simply. Like the
// equation view, both requests are chat actions on the chat's own profile, capabilities and paper, so they read the
// chat's cached prefix.

/// The server's `figure` event (format `figure-walkthrough-v1`): a summary, then one section per part of the figure.
public struct FigureWalkthrough: Codable, Equatable, Sendable {
    public static let format = "figure-walkthrough-v1"
    public static let maximumSections = 12, maximumBoxes = 4, maximumParagraphs = 8
    public static let maximumText = 1_500, maximumSummary = 800, maximumLabel = 60, maximumTitle = 120
    public static let minimumSide = 0.04

    /// A region of the image that was sent, as fractions: x, y its top-left corner, w, h its size.
    public struct Box: Codable, Equatable, Sendable {
        public let x: Double, y: Double, w: Double, h: Double
        public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }

        /// Inside the image, each side at least 4 % (a rounding overshoot allowed), and not the whole figure.
        public var isValid: Bool {
            [x, y, w, h].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && w >= minimumSide - 0.0001 && h >= minimumSide - 0.0001
                && x + w <= 1.0001 && y + h <= 1.0001 && !(w >= 0.95 && h >= 0.95)
        }

        /// The box in pixels of an image of this size, whole pixels within the image; nil when under 2 px a side.
        public func pixels(width: Int, height: Int) -> (x: Int, y: Int, width: Int, height: Int)? {
            guard width > 0, height > 0 else { return nil }
            let left = max(0, min(width, Int((x * Double(width)).rounded(.down)))), top = max(0, min(height, Int((y * Double(height)).rounded(.down))))
            let right = max(left, min(width, Int(((x + w) * Double(width)).rounded(.up))))
            let bottom = max(top, min(height, Int(((y + h) * Double(height)).rounded(.up))))
            guard right - left >= 2, bottom - top >= 2 else { return nil }
            return (left, top, right - left, bottom - top)
        }
    }

    public struct Section: Codable, Equatable, Sendable {
        /// The part as the figure names it ("(a)", "Left panel"); may be empty.
        public let label: String
        public let title: String
        /// Markdown with `\( \)` math and `[¶N]` citations.
        public let text: String
        public let paragraphs: [Int]
        public let box: Box?
        public init(label: String, title: String, text: String, paragraphs: [Int] = [], box: Box? = nil) {
            self.label = label; self.title = title; self.text = text; self.paragraphs = paragraphs; self.box = box
        }
        /// How the part is named in a request ("Left panel", else its title).
        public var name: String { label.isEmpty ? title : label }
    }

    public let format: String
    public let summary: String
    public let sections: [Section]

    public init(summary: String, sections: [Section]) { format = Self.format; self.summary = summary; self.sections = sections }

    /// The event's JSON, checked and bounded as the server checks it, degrading rather than refusing: a section without a
    /// title or text is left out, a box that doesn't fit is dropped (the section stays), the first 12 sections and 4 boxes
    /// are kept. Nil when no section is left.
    public static func validated(_ data: Data) -> FigureWalkthrough? {
        struct Raw: Decodable {
            struct RawBox: Decodable { let x: Double?; let y: Double?; let w: Double?; let h: Double? }
            struct Row: Decodable { let label: String?; let title: String?; let text: String?; let paragraphs: [Int]?; let box: RawBox? }
            let format: String; let summary: String?; let sections: [Row]
        }
        guard data.count <= 128 * 1024, let raw = try? JSONDecoder().decode(Raw.self, from: data), raw.format == format else { return nil }
        var sections: [Section] = [], boxes = 0
        for row in raw.sections {
            guard sections.count < maximumSections else { break }
            var label = line(row.label, maximumLabel), title = line(row.title, maximumTitle)
            if title.isEmpty { title = label; label = "" }
            let text = prose(row.text, maximumText)
            guard !title.isEmpty, !text.isEmpty else { continue }
            var numbers: [Int] = []
            for n in row.paragraphs ?? [] where (1...100_000).contains(n) && !numbers.contains(n) && numbers.count < maximumParagraphs { numbers.append(n) }
            var box: Box?
            if boxes < maximumBoxes, let b = row.box, let x = b.x, let y = b.y, let w = b.w, let h = b.h {
                let candidate = Box(x: x, y: y, w: w, h: h)
                if candidate.isValid { box = candidate; boxes += 1 }
            }
            sections.append(Section(label: label, title: title, text: text, paragraphs: numbers, box: box))
        }
        guard !sections.isEmpty else { return nil }
        return FigureWalkthrough(summary: prose(raw.summary, maximumSummary), sections: sections)
    }

    /// One line, control characters and runs of white space as one space, cut with "…".
    static func line(_ value: String?, _ limit: Int) -> String {
        guard let value else { return "" }
        let text = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.count <= limit ? text : String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Prose: line breaks kept, other control characters dropped, cut at the limit.
    static func prose(_ value: String?, _ limit: Int) -> String {
        guard let value else { return "" }
        let kept = value.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars
            .map { $0 == "\n" ? "\n" : CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        let text = kept.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}

extension ChatGenerationRequest {
    /// A figure view request: one turn naming the figure ("Figure 1", or "Figure 1 Left panel" for one part), the caption
    /// (or the part's text) as the selection, exactly this figure's image, and the chat's own profile and visual-answers
    /// setting on the paper numbered on this device, so the tools, instructions and paper are the chat's byte for byte.
    public static func figure(_ action: ChatAction, operationID: UUID, label: String, quote: String, profile: ChatProfileChoice,
                              localContext: LocalPaperChatContext, visualAnswers: Bool, image: ChatFigureImage) throws -> ChatGenerationRequest {
        guard action.isFigure, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatRequestError.emptyContext }
        return try make(operationID: operationID, documentID: nil, transcript: [ChatTurnInput(role: .user, text: label)], selection: quote,
                        action: action, profile: profile, topicTitle: false, localContext: localContext, visualAnswers: visualAnswers, figures: [image])
    }
}

/// What the device keeps of one figure view request (not synced, not chat history): the walkthrough or the words.
/// Boxes are kept, never the crops (they are cut again from the paper's own image).
public struct FigureAnswer: Codable, Equatable, Sendable {
    /// The walkthrough (action `figure`); nil when the server sent words instead, and for `figure_simpler`.
    public var walkthrough: FigureWalkthrough?
    /// A part explained more simply, or the words sent instead of a walkthrough.
    public var text: String
    public var model: String?
    public init(walkthrough: FigureWalkthrough? = nil, text: String = "", model: String? = nil) {
        self.walkthrough = walkthrough; self.text = text; self.model = model
    }
}

/// A sealed answer's identity in `EquationResultStore`: a file name that names nothing about the paper.
public protocol SealedAnswerKey: Hashable, Sendable { var fileName: String { get } }

/// One kept figure answer: the paper revision (bundle manifest), the figure, the action, the part (a digest of its text,
/// for `figure_simpler`: a new walkthrough's parts are new parts) and the chat profile.
public struct FigureResultKey: SealedAnswerKey {
    public let manifestSHA256: String
    public let figureID: String
    public let action: ChatAction
    public let part: String?
    public let profile: ChatProfileChoice
    public init(manifestSHA256: String, figureID: String, action: ChatAction, part: String? = nil, profile: ChatProfileChoice) {
        self.manifestSHA256 = manifestSHA256; self.figureID = figureID; self.action = action; self.profile = profile
        self.part = part.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
    }
    public var fileName: String {
        let identity = "figure-answer-v1\n\(manifestSHA256)\n\(figureID)\n\(action.rawValue)\n\(part ?? "-")\n\(profile.id)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined() + ".sealed"
    }
}

/// A caption in the page's markup as text the chat renders: each equation as its LaTeX (`\( … \)`), other tags left out,
/// entities read. The figure view uses it for a table, whose caption is part of its block.
public enum FigureCaptionText {
    public static func caption(inBlock markup: String) -> String? {
        var captions: [String] = []
        var rest = markup[...]
        while let start = rest.range(of: "<p class=\"reader-caption\"") {
            guard let open = rest[start.upperBound...].firstIndex(of: ">"), let close = rest[open...].range(of: "</p>") else { break }
            let text = plain(String(rest[rest.index(after: open)..<close.lowerBound]))
            if !text.isEmpty { captions.append(text) }
            rest = rest[close.upperBound...]
        }
        return captions.isEmpty ? nil : captions.joined(separator: " ")
    }

    /// Markup as text: `data-latex` equations as `\( … \)`, tags dropped, entities read, white space collapsed.
    public static func plain(_ markup: String) -> String {
        var text = markup.replacing(/<span[^>]*\sdata-latex="([^"]*)"[^>]*>[\s\S]*?<\/math><\/span>/) { match in
            "\\(" + entities(String(match.output.1)) + "\\)"
        }
        text = text.replacing(/<[^>]*>/, with: "")
        return entities(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func entities(_ text: String) -> String {
        text.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }
}
