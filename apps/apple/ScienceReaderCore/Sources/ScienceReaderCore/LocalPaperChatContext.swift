import Foundation

/// The paper as the chat model reads it (`reader-local-context-v2`): the verified reader index, block by block, each
/// block numbered `[¶N]` in index order so an answer can cite the exact passage and the reader can jump to it.
/// Headings keep their level, display equations their LaTeX, figures and tables their captions. The browser
/// (`apps/web/src/lib/paper-context.ts`) produces the same text; tests/fixtures/reader-arxiv/local-context-v2.txt
/// is the shared golden output both implementations must match byte for byte.
public enum PaperChatContext {
    public static let format = "reader-local-context-v2"

    public static func text(_ index: ReaderBundleIndex) -> String {
        let levels = Dictionary(index.headings.map { ($0.id, $0.level) }, uniquingKeysWith: { first, _ in first })
        var equations: [String: [ReaderBundleIndex.Equation]] = [:]
        for equation in index.equations { equations[equation.blockID, default: []].append(equation) }
        let figures = Dictionary(index.figures.map { ($0.blockID, $0) }, uniquingKeysWith: { first, _ in first })
        var parts: [String] = []
        parts.reserveCapacity(index.blocks.count)
        for (offset, block) in index.blocks.enumerated() {
            let marker = "[¶\(offset + 1)]"
            let body: String
            switch block.kind {
            case "heading":
                let level = levels[block.id] ?? (offset == 0 ? 1 : 2)
                body = String(repeating: "#", count: max(1, min(6, level))) + " " + block.text
            case "equation":
                if let list = equations[block.id], !list.isEmpty {
                    body = list.map { $0.sourceForm == "environment" ? $0.latex : "\\[ \($0.latex) \\]" }.joined(separator: "\n")
                } else { body = block.text }
            case "figure":
                let figure = figures[block.id]
                let caption = figure.map(\.caption).flatMap { $0.isEmpty ? nil : $0 } ?? (block.text.isEmpty ? (figure?.alt ?? "") : block.text)
                body = Self.trimmedEnd("[Figure] " + caption)
            case "table": body = Self.trimmedEnd("[Table] " + block.text)
            case "list": body = "- " + block.text
            default: body = block.text
            }
            parts.append(body.isEmpty ? marker : marker + " " + body)
        }
        return parts.joined(separator: "\n\n")
    }

    /// The block a cited marker names (1-based), or nil when the answer cites a block the paper lacks.
    public static func citedBlock(_ index: ReaderBundleIndex, marker: Int) -> ReaderBundleIndex.Block? {
        marker >= 1 && marker <= index.blocks.count ? index.blocks[marker - 1] : nil
    }

    /// The marker of an answer's citation anchor (`elementID` "¶12"), if the anchor is one.
    public static func citedMarker(_ elementID: String?) -> Int? {
        guard let elementID, elementID.hasPrefix("¶"), elementID.count <= 6, let marker = Int(elementID.dropFirst()), marker >= 1 else { return nil }
        return marker
    }

    private static func trimmedEnd(_ value: String) -> String {
        var scalars = value.unicodeScalars
        while let last = scalars.last, CharacterSet.whitespaces.contains(last) { scalars.removeLast() }
        return String(scalars)
    }
}

/// Ephemeral text sent only when a reader requests a cloud paper answer. It is
/// derived from the verified index; it contains no PDF, HTML or image bytes.
public struct LocalPaperChatContext: Encodable, Equatable, Sendable {
    public let format = PaperChatContext.format
    /// The library membership the request names; for the reader's own PDF, the paper's id on this device (never sent).
    public let membershipID: String
    /// `arxiv`, or `local` for a PDF the reader added (`isOwnPDF`).
    public let source: String
    public let sourceID: String
    public let revision: Int
    public let manifestSHA256: String
    public let sourceSHA256: String
    public let text: String
    private enum CodingKeys: String, CodingKey {
        case format, source, revision, text
        case membershipID = "membership_id", sourceID = "source_id", manifestSHA256 = "manifest_sha256", sourceSHA256 = "source_sha256"
    }
    /// A PDF the reader added, read by the on-device model.
    public var isOwnPDF: Bool { source == "local" }

    /// `bundle` is the paper's reading on this device: its arXiv HTML reading (that exact revision), or the on-device
    /// model's reading of the paper's PDF, of any arXiv revision kept here (docs/architecture/DEVICE_PDF_ROUTE.md: the
    /// device reads the PDF it has, which may be another revision than the library's). Either way the text is the verified
    /// index's, never the PDF, and the request names the library membership as it is (its revision is what the server
    /// authorizes).
    public init(reference: SourcePaperReference, bundle: VerifiedReaderBundle) throws {
        let source = try reference.arxivSource
        guard bundle.arxivSource == source || bundle.devicePDFArxivSource?.sourceID == source.sourceID else { throw ReaderError.invalidEvent }
        let text = try Self.text(bundle)
        self.source = "arxiv"; membershipID = reference.membershipID.wire; sourceID = reference.sourceID; revision = reference.revision
        manifestSHA256 = bundle.manifestSHA256; sourceSHA256 = bundle.manifest.source.sha256; self.text = text
    }

    /// A PDF the reader added (`paperID`, its `local:` library entry), read by the on-device model: only the reading's
    /// numbered text is sent (`encode(to:)`), never the paper's id, title or the digests of the PDF or the reading, which
    /// stay on this device like the end-to-end encrypted entry itself.
    public init(ownPDF paperID: UUID, bundle: VerifiedReaderBundle) throws {
        guard let paper = bundle.devicePDFSource?.paper, paper.sourceID == LocalPDFMembership.sourceID(paperID) else { throw ReaderError.invalidEvent }
        let text = try Self.text(bundle)
        source = "local"; membershipID = paperID.wire; sourceID = paper.sourceID; revision = paper.revision
        manifestSHA256 = bundle.manifestSHA256; sourceSHA256 = bundle.manifest.source.sha256; self.text = text
    }

    private static func text(_ bundle: VerifiedReaderBundle) throws -> String {
        let text = PaperChatContext.text(bundle.index)
        guard !text.isEmpty, text.utf8.count <= 2_097_152 else { throw ChatRequestError.questionTooLarge }
        return text
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // The order the synthesized encoding used (declaration order).
        try container.encode(format, forKey: .format)
        if !isOwnPDF { try container.encode(membershipID, forKey: .membershipID) }
        try container.encode(source, forKey: .source)
        if !isOwnPDF {
            try container.encode(sourceID, forKey: .sourceID); try container.encode(revision, forKey: .revision)
            try container.encode(manifestSHA256, forKey: .manifestSHA256); try container.encode(sourceSHA256, forKey: .sourceSHA256)
        }
        try container.encode(text, forKey: .text)
    }
}
