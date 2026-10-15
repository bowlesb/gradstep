import Foundation

/// A figure image sent with a question about it (server chat-figures.ts; consent cloud-ai-v3 names figures). `data` is
/// base64 JPEG or PNG prepared on the device from the paper's own figure; `blockID` and `assetPath` stay here so the
/// answer's figure parts can be cropped from the same image later.
public struct ChatFigureImage: Equatable, Sendable {
    public let id: String
    public let paragraph: Int
    public let caption: String
    public let mediaType: String
    public let data: String
    public let width: Int
    public let height: Int
    public let blockID: String
    public let assetPath: String
    /// Every panel's image when the figure has several (sent as one image, stacked; `ChatFigureFinder.composite`).
    public let assetPaths: [String]

    public init?(id: String, paragraph: Int, caption: String, mediaType: String, data: String, width: Int, height: Int, blockID: String, assetPath: String,
                 assetPaths: [String]? = nil) {
        guard ["F1", "F2", "F3"].contains(id), (1...20_000).contains(paragraph), ["image/jpeg", "image/png"].contains(mediaType),
              data.count >= 16, data.count <= 1_600_000, (8...1_600).contains(width), (8...1_600).contains(height) else { return nil }
        self.id = id; self.paragraph = paragraph; self.caption = String(caption.prefix(1_200)); self.mediaType = mediaType; self.data = data
        self.width = width; self.height = height; self.blockID = blockID; self.assetPath = assetPath
        self.assetPaths = assetPaths.flatMap { $0.isEmpty ? nil : Array($0.prefix(4)) } ?? [assetPath]
    }
}

/// The parts of an attached figure the answer named (the `figure_parts` event): boxes are fractions of the image.
public struct ChatFigureParts: Codable, Equatable, Sendable {
    public struct Part: Codable, Equatable, Sendable {
        public let label: String
        public let box: [Double]
        public let note: String
        public init(label: String, box: [Double], note: String) { self.label = label; self.box = box; self.note = note }
        /// The box clamped to the image, at least 3 % on each side (as the server checks it).
        public var isValid: Bool {
            box.count == 4 && box.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } && box[2] - box[0] >= 0.03 && box[3] - box[1] >= 0.03
                && !label.isEmpty && label.count <= 60 && !note.isEmpty && note.count <= 800
        }
    }
    public let figure: String
    public let paragraph: Int
    public let title: String
    public let parts: [Part]
    public init(figure: String, paragraph: Int, title: String, parts: [Part]) {
        self.figure = figure; self.paragraph = paragraph; self.title = title; self.parts = parts
    }
    public var isValid: Bool { !title.isEmpty && title.count <= 120 && (1...8).contains(parts.count) && parts.allSatisfy(\.isValid) }
}

/// What the device keeps for figure parts (a `diagram` event of format `figure-parts-v1`): the parts and where their
/// image is in the paper's bundle, never the image itself. Another device draws the crops from its own copy of the
/// same bundle, or shows the notes alone.
public struct StoredFigureParts: Codable, Equatable, Sendable {
    public let manifestSHA256: String
    public let blockID: String
    public let assetPath: String
    public let paragraph: Int
    public let title: String
    public let parts: [ChatFigureParts.Part]
    /// A figure of several panels: all of them, stacked as they were sent (absent for one image; older builds read
    /// `assetPath` alone).
    public let assetPaths: [String]?
    /// The images the parts' boxes refer to, in order.
    public var paths: [String] { assetPaths.flatMap { $0.isEmpty ? nil : $0 } ?? [assetPath] }

    public init(manifestSHA256: String, blockID: String, assetPath: String, paragraph: Int, title: String, parts: [ChatFigureParts.Part],
                assetPaths: [String]? = nil) {
        self.manifestSHA256 = manifestSHA256; self.blockID = blockID; self.assetPath = assetPath; self.paragraph = paragraph; self.title = title; self.parts = parts
        self.assetPaths = (assetPaths?.count ?? 0) > 1 ? assetPaths : nil
    }

    public func encodedText() -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    public static func decode(_ text: String) -> StoredFigureParts? {
        guard text.utf8.count <= ChatDiagram.maximumSourceBytes, let value = try? JSONDecoder().decode(StoredFigureParts.self, from: Data(text.utf8)),
              (1...8).contains(value.parts.count), value.parts.allSatisfy(\.isValid) else { return nil }
        return value
    }
}

/// `[[part N]]` lines in an answer with figure parts (owner, 2026-10-15: "the crops should be inline, right as the
/// chat discusses each one"): each marks where part N's crop goes. A marker is never shown as text: without its part
/// (no parts yet, another kind of answer, a number past the parts) the line is simply left out.
public enum FigurePartMarkers {
    public enum Segment: Equatable, Sendable { case text(String), part(Int) }

    private static var marker: Regex<(Substring, Substring)> { /^[ \t]*\[\[\s*part\s*([0-9]{1,2})\s*\]\][ \t]*/.ignoresCase() }

    public static func hasMarkers(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.firstMatch(of: marker) != nil }
    }

    /// The answer in order: the text between markers and the parts they name (1…`parts`). Text after a marker on the
    /// same line stays with the text that follows.
    public static func segments(_ text: String, parts: Int) -> [Segment] {
        var out: [Segment] = [], buffer: [Substring] = []
        func flush() {
            let joined = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { out.append(.text(joined)) }
            buffer = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let match = line.firstMatch(of: marker) {
                flush()
                if let n = Int(match.output.1), n >= 1, n <= parts { out.append(.part(n)) }
                let rest = line[match.range.upperBound...]
                if !rest.trimmingCharacters(in: .whitespaces).isEmpty { buffer.append(rest) }
            } else { buffer.append(line) }
        }
        flush()
        return out
    }

    /// The text without its marker lines (and, while an answer streams, without a marker still arriving at its end).
    public static func stripped(_ text: String, streaming: Bool = false) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> Substring? in
            guard let match = line.firstMatch(of: marker) else { return line }
            let rest = line[match.range.upperBound...]
            return rest.trimmingCharacters(in: .whitespaces).isEmpty ? nil : rest
        }
        if streaming, let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("[["), !last.contains("]]") { lines.removeLast() }
        var out = lines.joined(separator: "\n")
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out
    }
}
