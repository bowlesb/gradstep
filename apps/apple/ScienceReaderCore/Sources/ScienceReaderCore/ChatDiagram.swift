import Foundation

/// A diagram the assistant drew in a conversation. It is private content: the
/// device stores it as an encrypted `diagram` event (this JSON in `text`); the
/// server only relays the source while answering and keeps nothing.
public struct ChatDiagram: Codable, Equatable, Sendable {
    public static let currentFormat = "mermaid-v1"
    /// A visual answer (server chat-visual.ts, 2026-10-15): a sanitized HTML fragment the device shows in a frame
    /// with no scripts and no network. Stored like a diagram so builds before it ignore it rather than fail.
    public static let htmlFormat = "html-v1"
    public static let maximumTitleScalars = 200
    public static let maximumSourceBytes = 16_000
    public static let maximumHTMLBytes = 24_000

    public let format: String
    public let title: String
    /// Mermaid source, rendered on device by the bundled Mermaid library; or the visual's HTML fragment.
    public let source: String
    /// Entity ID of the assistant message that drew it.
    public let messageID: UUID?

    public var isHTML: Bool { format == Self.htmlFormat }

    public init?(title: String, source: String, messageID: UUID?, format: String = ChatDiagram.currentFormat) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard format == Self.currentFormat || format == Self.htmlFormat,
              !title.isEmpty, title.unicodeScalars.count <= Self.maximumTitleScalars,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.utf8.count <= (format == Self.htmlFormat ? Self.maximumHTMLBytes : Self.maximumSourceBytes) else { return nil }
        self.format = format; self.title = title; self.source = source; self.messageID = messageID
    }

    public func encodedText() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// Nil for anything that is not a well-formed diagram of a known format.
    public static func decode(_ text: String?) -> ChatDiagram? {
        guard let text, text.utf8.count <= maximumHTMLBytes * 2,
              let value = try? JSONDecoder().decode(ChatDiagram.self, from: Data(text.utf8)),
              let checked = ChatDiagram(title: value.title, source: value.source, messageID: value.messageID, format: value.format) else { return nil }
        return checked
    }
}

public struct ChatDiagramLink: Equatable, Sendable {
    public let id: UUID
    public let title: String
    /// A visual answer (HTML) rather than a Mermaid diagram.
    public var isHTML = false
}

public extension PrivateState {
    /// Saved diagrams, newest revision of each, in stable order. A diagram of
    /// a deleted conversation is gone with it.
    func diagrams() -> [(id: UUID, diagram: ChatDiagram)] {
        entities(kind: .diagram).compactMap { id in
            guard let event = revisions(for: id).first,
                  event.payload.conversationID.map({ !isDeleted($0) }) ?? true else { return nil }
            return ChatDiagram.decode(event.payload.text).map { (id, $0) }
        }
    }

    /// The diagram drawn by each assistant message (by message entity ID).
    func diagramsByMessage() -> [UUID: ChatDiagramLink] {
        var result: [UUID: ChatDiagramLink] = [:]
        for (id, diagram) in diagrams() {
            if let message = diagram.messageID, result[message] == nil { result[message] = ChatDiagramLink(id: id, title: diagram.title, isHTML: diagram.isHTML) }
        }
        return result
    }
}
