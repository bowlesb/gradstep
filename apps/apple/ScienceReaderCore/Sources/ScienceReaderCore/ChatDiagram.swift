import Foundation

/// A diagram the assistant drew in a conversation. It is private content: the
/// device stores it as an encrypted `diagram` event (this JSON in `text`); the
/// server only relays the source while answering and keeps nothing.
public struct ChatDiagram: Codable, Equatable, Sendable {
    public static let currentFormat = "mermaid-v1"
    public static let maximumTitleScalars = 200
    public static let maximumSourceBytes = 16_000

    public let format: String
    public let title: String
    /// Mermaid source, rendered on device by the bundled Mermaid library.
    public let source: String
    /// Entity ID of the assistant message that drew it.
    public let messageID: UUID?

    public init?(title: String, source: String, messageID: UUID?) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.unicodeScalars.count <= Self.maximumTitleScalars,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.utf8.count <= Self.maximumSourceBytes else { return nil }
        format = Self.currentFormat; self.title = title; self.source = source; self.messageID = messageID
    }

    public func encodedText() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// Nil for anything that is not a well-formed diagram of a known format.
    public static func decode(_ text: String?) -> ChatDiagram? {
        guard let text, text.utf8.count <= maximumSourceBytes * 2,
              let value = try? JSONDecoder().decode(ChatDiagram.self, from: Data(text.utf8)), value.format == currentFormat,
              let checked = ChatDiagram(title: value.title, source: value.source, messageID: value.messageID) else { return nil }
        return checked
    }
}

public struct ChatDiagramLink: Equatable, Sendable {
    public let id: UUID
    public let title: String
}

public extension PrivateState {
    /// Saved diagrams, newest revision of each, in stable order.
    func diagrams() -> [(id: UUID, diagram: ChatDiagram)] {
        entities(kind: .diagram).compactMap { id in
            revisions(for: id).first.flatMap { ChatDiagram.decode($0.payload.text) }.map { (id, $0) }
        }
    }

    /// The diagram drawn by each assistant message (by message entity ID).
    func diagramsByMessage() -> [UUID: ChatDiagramLink] {
        var result: [UUID: ChatDiagramLink] = [:]
        for (id, diagram) in diagrams() {
            if let message = diagram.messageID, result[message] == nil { result[message] = ChatDiagramLink(id: id, title: diagram.title) }
        }
        return result
    }
}
