import Foundation

/// Ephemeral text sent only when a reader requests a cloud paper answer. It is
/// derived from the verified index; it contains no PDF, HTML or image bytes.
public struct LocalPaperChatContext: Encodable, Equatable, Sendable {
    public let format = "reader-local-context-v1"
    public let membershipID: String
    public let source = "arxiv"
    public let sourceID: String
    public let revision: Int
    public let manifestSHA256: String
    public let sourceSHA256: String
    public let text: String
    private enum CodingKeys: String, CodingKey {
        case format, source, revision, text
        case membershipID = "membership_id", sourceID = "source_id", manifestSHA256 = "manifest_sha256", sourceSHA256 = "source_sha256"
    }
    public init(reference: SourcePaperReference, bundle: VerifiedReaderBundle) throws {
        guard try bundle.arxivSource == reference.arxivSource else { throw ReaderError.invalidEvent }
        let text = bundle.index.blocks.map(\.text).joined(separator: "\n\n")
        guard !text.isEmpty, text.utf8.count <= 2_097_152 else { throw ChatRequestError.questionTooLarge }
        membershipID = reference.membershipID.wire; sourceID = reference.sourceID; revision = reference.revision
        manifestSHA256 = bundle.manifestSHA256; sourceSHA256 = bundle.manifest.source.sha256; self.text = text
    }
}
