import Foundation

/// Encrypted library membership for a chosen/downloaded PDF. The server sees
/// only the ordinary encrypted event envelope, never its title or byte digest.
public struct LocalPDFMembership: Codable, Equatable, Sendable {
    public let format: String
    public let title: String
    public let pageCount: Int
    public let createdAt: Int64
    public var archived: Bool
    public var tags: [String]
    public init(title: String, pageCount: Int, createdAt: Int64, archived: Bool = false, tags: [String] = []) throws {
        self.format = "device-pdf-membership-v1"; self.title = title; self.pageCount = pageCount
        self.createdAt = createdAt; self.archived = archived; self.tags = tags
        try validate()
    }
    public func validate() throws {
        guard format == "device-pdf-membership-v1", (1...2000).contains(title.utf8.count),
              (1...250).contains(pageCount), createdAt >= 0, createdAt < 253_402_300_800_000,
              tags.count <= 32, tags.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 120 }) else { throw ReaderError.invalidEvent }
    }
    public func text() throws -> String { try validate(); return String(decoding: try ReaderCrypto.encode(self), as: UTF8.self) }
    public static func decode(_ event: PrivateEvent) throws -> Self {
        guard event.kind == .localPaper, let text = event.text, event.paperReference == nil, event.documentID == nil else { throw ReaderError.invalidEvent }
        let result = try JSONDecoder().decode(Self.self, from: Data(text.utf8)); try result.validate(); return result
    }
    public static func sourceID(_ id: UUID) -> String { "local:" + id.wire }
}
