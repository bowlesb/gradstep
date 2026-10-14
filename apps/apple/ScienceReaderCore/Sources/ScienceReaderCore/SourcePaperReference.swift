import Foundation

/// A metadata membership, explicitly distinct from a server PDF document.
public struct SourcePaperReference: Codable, Equatable, Hashable, Sendable {
    public let format: String
    public let membershipID: UUID
    public let source: String
    public let sourceID: String
    public let revision: Int

    public init(membershipID: UUID, sourceID: String, revision: Int) throws {
        self.format = "source-membership-v1"; self.membershipID = membershipID
        self.source = "arxiv"; self.sourceID = sourceID; self.revision = revision
        try validate()
    }
    public func validate() throws {
        guard format == "source-membership-v1", source == "arxiv" else { throw ReaderError.invalidEvent }
        _ = try ArxivReaderSource(sourceID: sourceID, revision: revision)
    }
    public var arxivSource: ArxivReaderSource { get throws { try validate(); return try ArxivReaderSource(sourceID: sourceID, revision: revision) } }
}
