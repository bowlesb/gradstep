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

    public init?(id: String, paragraph: Int, caption: String, mediaType: String, data: String, width: Int, height: Int, blockID: String, assetPath: String) {
        guard ["F1", "F2", "F3"].contains(id), (1...20_000).contains(paragraph), ["image/jpeg", "image/png"].contains(mediaType),
              data.count >= 16, data.count <= 1_600_000, (8...1_600).contains(width), (8...1_600).contains(height) else { return nil }
        self.id = id; self.paragraph = paragraph; self.caption = String(caption.prefix(1_200)); self.mediaType = mediaType; self.data = data
        self.width = width; self.height = height; self.blockID = blockID; self.assetPath = assetPath
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

    public init(manifestSHA256: String, blockID: String, assetPath: String, paragraph: Int, title: String, parts: [ChatFigureParts.Part]) {
        self.manifestSHA256 = manifestSHA256; self.blockID = blockID; self.assetPath = assetPath; self.paragraph = paragraph; self.title = title; self.parts = parts
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
