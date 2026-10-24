import CryptoKit
import Foundation

/// How a library paper becomes full-text documents (docs/architecture/NATIVE_LIBRARY_SEARCH.md, "Full-text index").
public enum FullTextLibrary {
    /// The paper's reading text: each block's text in reading order (a figure's caption when its block has no
    /// text), without the chat context's `[¶N]` markers or heading marks, so a number in a marker is never a match.
    public static func bodyText(_ index: ReaderBundleIndex) -> String {
        let captions = Dictionary(index.figures.map { ($0.blockID, $0.caption.isEmpty ? $0.alt : $0.caption) }, uniquingKeysWith: { first, _ in first })
        var parts: [String] = []
        parts.reserveCapacity(index.blocks.count)
        for block in index.blocks {
            let text = block.text.isEmpty && block.kind == "figure" ? (captions[block.id] ?? "") : block.text
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined(separator: "\n\n")
    }

    /// A paper's metadata document. Its fingerprint changes exactly when an indexed field does.
    public static func metadata(group: String, title: String, authors: String, tags: [String], abstract: String, notes: String) -> FullTextDocument {
        let fields: [FullTextField: String] = [.title: title, .authors: authors, .tags: tags.joined(separator: ", "), .abstract: abstract, .notes: notes]
        return FullTextDocument(id: .init(group: group, part: .metadata), fingerprint: fingerprint(fields), fields: fields)
    }

    /// A paper's body document; `fingerprint` names the reading it came from (a stored copy's digest).
    public static func body(group: String, fingerprint: String, text: String) -> FullTextDocument {
        FullTextDocument(id: .init(group: group, part: .body), fingerprint: fingerprint, fields: [.body: text])
    }

    static func fingerprint(_ fields: [FullTextField: String]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("v\(FullTextIndexStore.version)".utf8))
        for field in FullTextField.allCases {
            hasher.update(data: Data([0x1F, UInt8(field.rawValue)]))
            hasher.update(data: Data((fields[field] ?? "").utf8))
        }
        return hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
