import CryptoKit
import Foundation

/// This device's reading activity for one paper: when this account last opened it here, how far
/// through it the saved reading position is, and that position for the artifact it was read in.
/// Device-local convenience state: it never enters the event journal or the sync outbox.
public struct ReadingActivityEntry: Codable, Equatable, Sendable {
    public struct Location: Codable, Equatable, Sendable {
        public let blockIndex: Int?
        public let blockFraction: Double
        public let blockHeight: Double
        public let scrollY: Double
        public init(blockIndex: Int?, blockFraction: Double, blockHeight: Double, scrollY: Double) {
            self.blockIndex = blockIndex; self.blockFraction = blockFraction; self.blockHeight = blockHeight; self.scrollY = scrollY
        }
    }
    public let documentID: UUID
    public var openedAt: Date?
    /// 0…1 through the paper at the saved position.
    public var progress: Double?
    /// The immutable artifact the location belongs to (document/artifact/manifest).
    public var locationKey: String?
    public var location: Location?

    public init(documentID: UUID, openedAt: Date? = nil, progress: Double? = nil, locationKey: String? = nil, location: Location? = nil) {
        self.documentID = documentID; self.openedAt = openedAt; self.progress = progress
        self.locationKey = locationKey; self.location = location
    }

    func validate() throws {
        guard openedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
              progress.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              (locationKey?.utf8.count ?? 0) <= 512, (locationKey == nil) == (location == nil) else { throw ReaderError.corruptData }
        if let location {
            guard location.blockIndex.map({ (0...1_000_000).contains($0) }) ?? true,
                  location.blockFraction.isFinite, abs(location.blockFraction) < 1_000_000,
                  location.blockHeight.isFinite, (1...1_000_000_000).contains(location.blockHeight),
                  location.scrollY.isFinite, (0...1_000_000_000).contains(location.scrollY) else { throw ReaderError.corruptData }
        }
    }
}

/// One AES-GCM sealed file in the account's local folder, beside the encrypted private-state
/// store and under the same device-held local-store key (through a domain-separated HKDF
/// subkey). The account is bound into the authenticated data; the file has complete file
/// protection and is excluded from backup. Losing or failing to read it only forgets reading
/// positions, so an unreadable file is replaced on the next save rather than blocking reading.
public actor ReadingActivityStore {
    public static let maximumEntries = 5_000
    public static let fileName = "reading-activity.enc"
    private let url: URL
    private let accountID: UUID
    private let key: SymmetricKey

    public init(directory: URL, accountID: UUID, localKey: Data) throws {
        guard localKey.count == 32 else { throw ReaderError.invalidKey }
        self.url = directory.appendingPathComponent(Self.fileName)
        self.accountID = accountID
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: localKey), salt: Data(accountID.wire.utf8),
                                     info: Data("science-reader/local-reading/v1".utf8), outputByteCount: 32)
    }

    private var aad: Data { Data("science-reader/local-reading/v1\n\(accountID.wire)\n".utf8) }

    /// Missing → empty. Unreadable (wrong key, account, corruption) → empty and replaced later.
    public func load() -> [ReadingActivityEntry] {
        guard let sealed = try? Data(contentsOf: url) else { return [] }
        return (try? Self.open(sealed, key: key, aad: aad)) ?? []
    }

    /// Keeps the most recently opened entries within the bound, then replaces the file atomically.
    public func save(_ entries: [ReadingActivityEntry]) throws {
        let kept = try Self.bounded(entries)
        guard let sealed = try AES.GCM.seal(ReaderCrypto.encode(kept), using: key, authenticating: aad).combined else {
            throw ReaderError.corruptData
        }
        let directory = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { throw ReaderError.storageUnavailable }
        #if os(iOS)
        try sealed.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try sealed.write(to: url, options: .atomic)
        #endif
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var file = url; try? file.setResourceValues(values)
    }

    static func bounded(_ entries: [ReadingActivityEntry]) throws -> [ReadingActivityEntry] {
        var seen = Set<UUID>()
        for entry in entries {
            try entry.validate()
            guard seen.insert(entry.documentID).inserted else { throw ReaderError.corruptData }
        }
        guard entries.count > maximumEntries else { return entries }
        return Array(entries.sorted { ($0.openedAt ?? .distantPast) > ($1.openedAt ?? .distantPast) }.prefix(maximumEntries))
    }

    static func open(_ sealed: Data, key: SymmetricKey, aad: Data) throws -> [ReadingActivityEntry] {
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: aad)
        let entries = try JSONDecoder().decode([ReadingActivityEntry].self, from: plain)
        guard entries.count <= maximumEntries else { throw ReaderError.corruptData }
        return try bounded(entries)
    }
}
