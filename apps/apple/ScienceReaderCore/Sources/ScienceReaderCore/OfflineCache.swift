import CryptoKit
import Foundation

public enum OfflineCacheError: Error, Equatable, Sendable {
    case invalidBinding, invalidObservation, staleObservation, conflictingObservation
    case corruptCache, capacityExceeded, installBusy, staleTicket, notInstalled
    case revisionConflict, blocked
}

/// Logical committed ciphertext ceilings, not physical disk or process memory.
public enum OfflineCacheLimits {
    public static let bundleBytes = 512 * 1024 * 1024
    public static let installedBundles = 100
    public static let presentationBytes = 256 * 1024 * 1024
    public static let presentationRowBytes = 65_536
    public static let presentationCheckpointBytes = 1_048_576
    public static let bundleIndexBytes = 131_072
    public static let bundleHeaderBytes = 524_288
    static let memberBytes = 16_777_216 + 28
}

public struct ReaderArtifactBinding: Codable, Equatable, Sendable {
    public let scope: LibraryCommandScope
    public let documentID: UUID
    public let artifactID: UUID
    public let manifestSHA256: String

    public init(scope: LibraryCommandScope, documentID: UUID, artifactID: UUID, manifestSHA256: String) throws {
        self.scope = scope; self.documentID = documentID; self.artifactID = artifactID
        self.manifestSHA256 = manifestSHA256
        try validate()
    }

    func validate() throws {
        try scope.validate()
        guard manifestSHA256.utf8.count == 64,
              manifestSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw OfflineCacheError.invalidBinding }
    }
}

/// Presentation only. It cannot construct a LibraryCompleteObservation or
/// resume a reconciler session, even when its cursor matches a server receipt.
public struct CachedLibraryPresentation: Equatable, Sendable {
    public let scope: LibraryCommandScope
    public let committedCursor: Int64
    public let capturedAt: Date
    public let entries: [LibraryEntryID: LibraryEntry]
}

public enum ReaderBundleBlock: String, Codable, Sendable {
    case quarantined, incompatible, artifactChanged
}

public struct InstalledReaderBundle: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let binding: ReaderArtifactBinding
    public let revision: Int64
    /// Header and members. The list total additionally includes its directory.
    public let ciphertextBytes: Int
    public let eligibility: ReaderBundleEligibility
    public var membershipVisible: Bool? { eligibility.membershipVisible }
    public var block: ReaderBundleBlock? { eligibility.block }
    public var canOpen: Bool { eligibility.canOpen }
}

/// The same reducer is used by the native coordinator before awaiting disk and
/// by the cache transaction. It conveys local eligibility, not download grants.
public struct ReaderBundleEligibility: Codable, Equatable, Sendable {
    public private(set) var hasObservation = false
    public private(set) var cursor: Int64 = 0
    public private(set) var itemState: Int64 = 0
    public private(set) var availabilityRevision: Int64?
    public private(set) var membershipVisible: Bool?
    public private(set) var block: ReaderBundleBlock?
    private var targetDocumentID: UUID?
    private var targetArtifactID: UUID?
    private var explicitBlock: ReaderBundleBlock?
    private var observedArtifactID: UUID?
    public var canOpen: Bool { block == nil && membershipVisible != false }
    public init() {}

    public func applying(observation: LibraryCompleteObservation, binding: ReaderArtifactBinding) throws -> Self {
        try binding.validate()
        guard observation.accountID == binding.scope.accountID else { throw ReaderError.wrongAccount }
        let items = observation.entries.values.compactMap { entry -> LibraryItemRecord? in
            if case .item(let item) = entry, item.documentID == binding.documentID { return item }; return nil
        }
        guard items.count <= 1 else { throw OfflineCacheError.invalidObservation }
        return try applying(cursor: observation.committedCursor, item: items.first,
                            documentID: binding.documentID, artifactID: binding.artifactID)
    }

    public func applying(cursor: Int64, item: LibraryItemRecord?, documentID: UUID, artifactID: UUID) throws -> Self {
        guard cursor >= self.cursor else { throw OfflineCacheError.staleObservation }
        guard targetDocumentID == nil || targetDocumentID == documentID,
              targetArtifactID == nil || targetArtifactID == artifactID else { throw OfflineCacheError.invalidBinding }
        var next = self
        next.hasObservation = true; next.cursor = cursor
        next.targetDocumentID = documentID; next.targetArtifactID = artifactID
        if let item {
            try item.validate()
            guard item.documentID == documentID, item.stateSequence <= cursor,
                  item.stateSequence >= itemState else { throw OfflineCacheError.staleObservation }
            next.itemState = item.stateSequence; next.membershipVisible = item.visible
            next.observedArtifactID = item.artifactID
            if item.artifactID == artifactID {
                guard item.renderAvailabilityRevision.map({ $0 >= (availabilityRevision ?? 0) }) ?? true
                else { throw OfflineCacheError.staleObservation }
                if item.renderAvailability == .quarantined { next.explicitBlock = .quarantined }
                else if item.renderAvailability == .unknown("incompatible") || item.readiness == .unknown("incompatible") {
                    next.explicitBlock = .incompatible
                } else if item.canReadStructured, item.renderAvailability == .available,
                          explicitBlock == nil || (item.renderAvailabilityRevision ?? -1) > (availabilityRevision ?? -1) ||
                            (availabilityRevision == nil && item.stateSequence > itemState) {
                    next.explicitBlock = nil
                }
                if let revision = item.renderAvailabilityRevision { next.availabilityRevision = revision }
            }
            next.block = next.explicitBlock ?? (item.artifactID.map { $0 != artifactID } == true ? .artifactChanged : nil)
        } else {
            next.membershipVisible = false
        }
        if hasObservation, cursor == self.cursor, next != self { throw OfflineCacheError.conflictingObservation }
        return next
    }

    func validate(documentID: UUID, artifactID: UUID) throws {
        guard cursor >= 0, itemState >= 0, itemState <= cursor,
              availabilityRevision.map({ $0 >= 0 }) ?? true,
              targetDocumentID == nil || targetDocumentID == documentID,
              targetArtifactID == nil || targetArtifactID == artifactID,
              explicitBlock != .artifactChanged,
              block == explicitBlock || (explicitBlock == nil && block == .artifactChanged && observedArtifactID != artifactID),
              hasObservation || (cursor == 0 && itemState == 0 && membershipVisible == nil && block == nil)
        else { throw OfflineCacheError.corruptCache }
    }
}

public struct InstalledReaderBundleList: Equatable, Sendable {
    public let scope: LibraryCommandScope
    public let generation: Int64
    public let installations: [InstalledReaderBundle]
    public let ciphertextBytes: Int
}

/// Opaque and deliberately not Codable. Ending one operation cannot cancel a
/// successor on the same actor, or authorize work on a new writer.
public struct ReaderInstallTicket: Equatable, Sendable {
    public let id: UUID
    public let binding: ReaderArtifactBinding
    let writerID: UUID
    let installationID: UUID
}

public struct ReaderBundleOpenToken: Equatable, Sendable {
    public let installationID: UUID
    public let binding: ReaderArtifactBinding
    public let revision: Int64
    let writerID: UUID
}

/// Owned decrypted bytes; the native caller must run its shared PNG/ImageIO
/// loader and then validate the token before exposing a WebKit handle.
public struct StoredReaderBundlePayload: Sendable {
    public let manifestData: Data
    public let members: [String: Data]
    public let openToken: ReaderBundleOpenToken
}

// Only these compact roots enter private-history metadata. Derived-cache
// children are read on demand and never gate private-history/draft recovery.
struct OfflineCacheRoots: Codable, Equatable {
    var scope: LibraryCommandScope?
    var presentation: Data?
    var bundles: Data?

    func validate(accountID: UUID) throws {
        if let scope { try scope.validate(); guard scope.accountID == accountID else { throw ReaderError.wrongAccount } }
        guard presentation.map({ $0.count == 32 }) ?? true,
              bundles.map({ $0.count == 32 }) ?? true,
              scope != nil || (presentation == nil && bundles == nil) else { throw ReaderError.corruptData }
    }
}

struct CacheEntryReference: Codable, Equatable {
    let rowID: UUID
    let digest: Data
    let bytes: Int
    let documentID: UUID?
    enum CodingKeys: String, CodingKey { case rowID = "r", digest = "d", bytes = "n", documentID = "doc" }
}

struct CachePresentationCheckpoint: Codable {
    let format: Int
    let scope: LibraryCommandScope
    let cursor: Int64
    let capturedAt: Date
    let rows: [String: CacheEntryReference]
}

struct CacheLibraryRow: Codable {
    let format: Int
    let rowID: UUID
    let entry: LibraryEntry
    let readerPolicy: CacheItemPolicy?
}

struct CacheItemPolicy: Codable, Equatable {
    let artifactID: UUID
    let eligibility: ReaderBundleEligibility
}

struct CacheInstallation: Codable, Equatable {
    let id: UUID
    let documentID: UUID
    let artifactID: UUID
    let manifestSHA256: String
    let headerDigest: Data
    let headerBytes: Int
    let memberCount: Int
    let ciphertextBytes: Int
    var revision: Int64
    var eligibility: ReaderBundleEligibility

    func binding(scope: LibraryCommandScope) throws -> ReaderArtifactBinding {
        try ReaderArtifactBinding(scope: scope, documentID: documentID, artifactID: artifactID, manifestSHA256: manifestSHA256)
    }
    func summary(scope: LibraryCommandScope) throws -> InstalledReaderBundle {
        .init(id: id, binding: try binding(scope: scope), revision: revision, ciphertextBytes: ciphertextBytes, eligibility: eligibility)
    }
}

struct CacheBundleIndex: Codable {
    let format: Int
    let scope: LibraryCommandScope
    var installations: [CacheInstallation]
}

struct CacheMemberReference: Codable {
    let ordinal: Int
    let digest: Data
    let bytes: Int
    enum CodingKeys: String, CodingKey { case ordinal = "o", digest = "d", bytes = "n" }
}

struct CacheBundleHeader: Codable {
    let format: Int
    let installationID: UUID
    let binding: ReaderArtifactBinding
    let manifestData: Data
    let members: [CacheMemberReference]
}

enum CacheWrite {
    case checkpoint(Data), presentationRow(UUID, Data), deletePresentationRow(UUID)
    case bundleIndex(Data), header(UUID, Data), member(UUID, Int, Data), deleteBundle(UUID)
}

struct OfflineCacheMutation {
    var roots: OfflineCacheRoots
    var writes: [CacheWrite]
}

enum OfflineCacheCodec {
    // Cache timestamps preserve Foundation's exact Date value. This private
    // encoder/decoder mode is never enabled by LibraryWire's network decoder.
    static let dateKey = CodingUserInfoKey(rawValue: "science-reader/local-library-date/v1")!
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.userInfo[dateKey] = true
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, from bytes: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.userInfo[dateKey] = true
        return try decoder.decode(type, from: bytes)
    }
    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func entryKey(_ id: LibraryEntryID) -> String { "\(id.kind.rawValue):\(id.entityID.wire)" }
    static func entryID(_ value: String) throws -> LibraryEntryID {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let kind = LibraryEntryKind(rawValue: String(parts[0])),
              let id = UUID(uuidString: String(parts[1])), id.wire == parts[1] else { throw OfflineCacheError.corruptCache }
        return .init(kind: kind, entityID: id)
    }
    static func documentID(_ entry: LibraryEntry) -> UUID? {
        if case .item(let value) = entry { return value.documentID }
        return nil
    }
    static func aad(_ domain: String, scope: LibraryCommandScope, identity: [String] = []) throws -> Data {
        // JSON string arrays are unambiguous even if a future identity contains
        // separators. Scope validation occurs before every database operation.
        try encode(["science-reader/offline-cache/v1", domain, scope.accountID.wire, scope.deploymentID] + identity)
    }
    static func seal(_ plain: Data, domain: String, scope: LibraryCommandScope, identity: [String] = [],
                     key: SymmetricKey, maximum: Int) throws -> Data {
        guard plain.count <= maximum - 28,
              let sealed = try AES.GCM.seal(plain, using: key, authenticating: aad(domain, scope: scope, identity: identity)).combined,
              sealed.count <= maximum else { throw OfflineCacheError.capacityExceeded }
        return sealed
    }
    static func open(_ sealed: Data, digest: Data, domain: String, scope: LibraryCommandScope,
                     identity: [String] = [], key: SymmetricKey, maximum: Int) throws -> Data {
        guard (28...maximum).contains(sealed.count), Self.digest(sealed) == digest else { throw OfflineCacheError.corruptCache }
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key,
                                     authenticating: aad(domain, scope: scope, identity: identity)) }
        catch { throw OfflineCacheError.corruptCache }
    }
}
