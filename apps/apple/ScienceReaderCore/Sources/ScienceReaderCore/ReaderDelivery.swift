import Foundation

public enum ReaderMemberTransport: Sendable, Equatable {
    case signedStorage, bounded

    /// Exact known transports on the configured origin. Never attach account
    /// credentials to a descriptor-supplied arbitrary URL or redirect target.
    public static func validated(_ url: URL, backendURL: URL) throws -> Self {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https",
              parts.host == backendURL.host, parts.port == backendURL.port,
              parts.user == nil, parts.password == nil, parts.fragment == nil else { throw ReaderError.corruptData }
        if parts.path.hasPrefix("/storage/v1/object/sign/") { return .signedStorage }
        let query = parts.queryItems ?? []
        guard parts.path == "/functions/v1/reader-member", query.count == 2,
              Set(query.map(\.name)) == Set(["grant", "member"]),
              let grant = query.first(where: { $0.name == "grant" })?.value,
              grant.utf8.count == 64, grant.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let member = query.first(where: { $0.name == "member" })?.value, UUID(uuidString: member) != nil else { throw ReaderError.corruptData }
        return .bounded
    }
}

/// Response of the authenticated `reader-artifact` function: the trusted
/// manifest digest plus short-lived member delivery URLs. The
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
