import Foundation

/// Conversations linked to the passage they came from (docs/DECISIONS.md, "Passage-linked conversations").
/// The anchor rides inside the conversation's encrypted event (`PrivateEvent.anchor`, a field every build since
/// the first has decoded), so the service learns nothing and the wire format is unchanged.
public extension TextAnchor {
    /// Characters of the paper's text kept on each side of the passage.
    static let contextCharacters = 32

    /// The anchor a selection action writes on its new conversation: the artifact being read, the first block the
    /// selection touches, the quote exactly as asked about, and up to 32 characters of the paper's text on each
    /// side (whitespace collapsed). Nil when there is nothing to anchor or a value is out of bounds.
    static func passage(artifactID: UUID, selection: ReaderSelection, quote: String) -> TextAnchor? {
        let quote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty, quote.utf8.count <= 20_000 else { return nil }
        let element = selection.parts.first?.blockID
        let prefix = String(collapsed(selection.context?.prefix ?? "").suffix(contextCharacters))
        let suffix = String(collapsed(selection.context?.suffix ?? "").prefix(contextCharacters))
        let anchor = TextAnchor(artifactID: artifactID, quote: quote,
                                prefix: prefix.utf8.count <= 1_000 ? prefix : "", suffix: suffix.utf8.count <= 1_000 ? suffix : "",
                                elementID: element.flatMap { (1...200).contains($0.utf8.count) ? $0 : nil })
        return (try? anchor.validate()) == nil ? nil : anchor
    }

    /// One line for lists: the quote with whitespace collapsed.
    var displayQuote: String { Self.collapsed(quote) }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
