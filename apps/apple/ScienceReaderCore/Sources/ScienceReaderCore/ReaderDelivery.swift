import Foundation

/// Response of the authenticated `reader-artifact` function: the trusted
/// manifest digest plus short-lived signed URLs for each bundle member. The
/// installer re-verifies every byte against `manifestSHA256` before use.
public struct ReaderArtifactDescriptor: Decodable, Sendable, Equatable {
    public struct Member: Decodable, Sendable, Equatable {
        public let path: String
        public let sha256: String
        public let bytes: Int
        public let url: URL
    }
    public let itemID: UUID
    public let documentID: UUID
    public let artifactID: UUID
    public let rendererVersion: String
    public let manifestSHA256: String
    public let manifestData: Data
    public let members: [Member]

    private enum CodingKeys: String, CodingKey {
        case members, manifest
        case itemID = "item_id", documentID = "document_id", artifactID = "artifact_id"
        case rendererVersion = "renderer_version", manifestSHA256 = "manifest_sha256"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try c.decode(UUID.self, forKey: .itemID)
        documentID = try c.decode(UUID.self, forKey: .documentID)
        artifactID = try c.decode(UUID.self, forKey: .artifactID)
        rendererVersion = try c.decode(String.self, forKey: .rendererVersion)
        manifestSHA256 = try c.decode(String.self, forKey: .manifestSHA256)
        guard let manifest = Data(base64Encoded: try c.decode(String.self, forKey: .manifest)) else { throw ReaderError.corruptData }
        manifestData = manifest
        members = try c.decode([Member].self, forKey: .members)
        try validate()
    }

    func validate() throws {
        let hex = { (value: String) in value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        guard hex(manifestSHA256), manifestData.count <= 262_144, (1...512).contains(members.count),
              rendererVersion.utf8.count <= 64,
              Set(members.map(\.path)).count == members.count,
              members.allSatisfy({ hex($0.sha256) && (1...16_777_216).contains($0.bytes) && $0.url.scheme == "https"
                  && !$0.path.isEmpty && !$0.path.contains("..") && !$0.path.hasPrefix("/") }),
              members.reduce(0, { $0 + $1.bytes }) <= 33_554_432 else { throw ReaderError.corruptData }
    }
}
