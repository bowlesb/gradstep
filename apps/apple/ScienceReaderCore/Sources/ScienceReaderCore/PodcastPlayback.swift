import CryptoKit
import Foundation

// Listening position and history (docs/architecture/PAPER_PODCASTS.md, "Listening history"): device-local in v1,
// sealed in the account's local folder like reading activity. Nothing here enters the encrypted history stream or
// any server table. The merge rule is defined now (and tested) so a later encrypted podcast stream can reuse it.
//
// Ordering is by play session, not by position: `max(position)` would undo an intentional seek backwards or a replay.
// A session starts when playback of a release starts on a device; each saved update within it takes the next
// sequence number. Of two records for one release, the one from the later-started session wins, and within a session
// the higher sequence wins. Ties (the same session seen twice) are duplicates. Removing a saved entry is a tombstone
// with its own session, so an older record arriving later cannot bring it back.

public struct PodcastPlaybackRecord: Codable, Equatable, Sendable {
    public let releaseID: UUID
    public var positionMS: Int
    public var durationMS: Int
    public var completed: Bool
    public let sessionID: UUID
    public let sessionStartedAt: Date
    public var sequence: Int64
    public let deviceID: UUID
    public var updatedAt: Date
    /// Removed from history ("Clear"); kept as a tombstone, never shown or resumed.
    public var removed: Bool

    public init(releaseID: UUID, positionMS: Int, durationMS: Int, completed: Bool, sessionID: UUID, sessionStartedAt: Date,
                sequence: Int64, deviceID: UUID, updatedAt: Date, removed: Bool = false) {
        self.releaseID = releaseID; self.positionMS = positionMS; self.durationMS = durationMS; self.completed = completed
        self.sessionID = sessionID; self.sessionStartedAt = sessionStartedAt; self.sequence = sequence
        self.deviceID = deviceID; self.updatedAt = updatedAt; self.removed = removed
    }

    /// Deterministic total order used by `merge`: later session, then later sequence, then a stable tie-break.
    public func supersedes(_ other: PodcastPlaybackRecord) -> Bool {
        if sessionStartedAt != other.sessionStartedAt { return sessionStartedAt > other.sessionStartedAt }
        if sessionID != other.sessionID { return sessionID.wire > other.sessionID.wire }
        if sequence != other.sequence { return sequence > other.sequence }
        // The same (session, sequence) twice is a duplicate; prefer the removal so a tombstone is never undone.
        return removed && !other.removed
    }

    func validate() throws {
        guard positionMS >= 0, positionMS <= PodcastEpisode.maximumDurationMS, (0...PodcastEpisode.maximumDurationMS).contains(durationMS),
              sequence >= 0, sessionStartedAt.timeIntervalSinceReferenceDate.isFinite, updatedAt.timeIntervalSinceReferenceDate.isFinite
        else { throw ReaderError.corruptData }
    }
}

/// One playback run of one release on this device: the source of sequence numbers for its updates.
public struct PodcastPlaybackSession: Equatable, Sendable {
    public let releaseID: UUID
    public let id: UUID
    public let startedAt: Date
    public let deviceID: UUID
    public private(set) var sequence: Int64 = 0

    public init(releaseID: UUID, id: UUID = UUID(), startedAt: Date, deviceID: UUID) {
        self.releaseID = releaseID; self.id = id; self.startedAt = startedAt; self.deviceID = deviceID
    }

    /// The next record of this session (position as played, which may be earlier than the last one).
    public mutating func record(positionMS: Int, durationMS: Int, completed: Bool, at date: Date) -> PodcastPlaybackRecord {
        sequence += 1
        return PodcastPlaybackRecord(releaseID: releaseID, positionMS: max(0, min(positionMS, durationMS > 0 ? durationMS : positionMS)),
                                     durationMS: max(0, durationMS), completed: completed, sessionID: id, sessionStartedAt: startedAt,
                                     sequence: sequence, deviceID: deviceID, updatedAt: date)
    }
}

public struct PodcastPlaybackLedger: Codable, Equatable, Sendable {
    public static let maximumRecords = 500
    public private(set) var records: [UUID: PodcastPlaybackRecord] = [:]

    public init(records: [PodcastPlaybackRecord] = []) {
        for record in records { _ = apply(record) }
    }

    /// Keeps `record` if it supersedes what is known for its release. Returns whether anything changed.
    @discardableResult
    public mutating func apply(_ record: PodcastPlaybackRecord) -> Bool {
        if let current = records[record.releaseID], !record.supersedes(current) { return false }
        records[record.releaseID] = record
        return true
    }

    /// Union by the same rule (commutative, associative, idempotent), for a future second copy of this history.
    public func merged(with other: PodcastPlaybackLedger) -> PodcastPlaybackLedger {
        var result = self
        for record in other.records.values { result.apply(record) }
        return result.bounded()
    }

    /// Where to resume: nothing for a finished, removed or barely started release.
    public func resumePositionMS(for releaseID: UUID) -> Int? {
        guard let record = records[releaseID], !record.removed, !record.completed, record.positionMS >= 5_000 else { return nil }
        // Near the end, start again rather than resuming into the last seconds.
        if record.durationMS > 0, record.durationMS - record.positionMS < 10_000 { return nil }
        return record.positionMS
    }

    public func isCompleted(_ releaseID: UUID) -> Bool { records[releaseID].map { $0.completed && !$0.removed } ?? false }

    /// History rows, most recent first.
    public var history: [PodcastPlaybackRecord] {
        records.values.filter { !$0.removed }.sorted { $0.updatedAt == $1.updatedAt ? $0.releaseID.wire < $1.releaseID.wire : $0.updatedAt > $1.updatedAt }
    }

    /// A tombstone in a new session of its own: it supersedes every record started before now.
    public mutating func remove(_ releaseID: UUID, deviceID: UUID, at date: Date) {
        // Strictly after the known session even if the clock reads the same instant.
        let start = max(date, (records[releaseID]?.sessionStartedAt ?? .distantPast).addingTimeInterval(0.001))
        apply(PodcastPlaybackRecord(releaseID: releaseID, positionMS: 0, durationMS: records[releaseID]?.durationMS ?? 0,
                                    completed: false, sessionID: UUID(), sessionStartedAt: start, sequence: 1, deviceID: deviceID,
                                    updatedAt: date, removed: true))
    }

    /// The most recently updated records within the bound.
    public func bounded() -> PodcastPlaybackLedger {
        guard records.count > Self.maximumRecords else { return self }
        let kept = records.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.maximumRecords)
        var result = PodcastPlaybackLedger(); for record in kept { result.records[record.releaseID] = record }
        return result
    }

    public init(from decoder: any Decoder) throws {
        let list = try decoder.singleValueContainer().decode([PodcastPlaybackRecord].self)
        guard list.count <= Self.maximumRecords, Set(list.map(\.releaseID)).count == list.count else { throw ReaderError.corruptData }
        for record in list { try record.validate(); records[record.releaseID] = record }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(records.values.sorted { $0.releaseID.wire < $1.releaseID.wire })
    }
}

/// A verified audio file on this device and the episode (with its transcript) it belongs to. `kept` marks an explicit
/// "Download" for offline listening; other files are the transient copy Play needed, evicted after a few others.
public struct PodcastDownloadRecord: Codable, Equatable, Sendable {
    public let episode: PodcastEpisode
    public let fileName: String
    public let bytes: Int
    public let sha256: String
    public let mediaType: String
    public var kept: Bool
    public let verifiedAt: Date
    public var lastUsedAt: Date

    public init(episode: PodcastEpisode, fileName: String, bytes: Int, sha256: String, mediaType: String, kept: Bool,
                verifiedAt: Date, lastUsedAt: Date) {
        self.episode = episode; self.fileName = fileName; self.bytes = bytes; self.sha256 = sha256; self.mediaType = mediaType
        self.kept = kept; self.verifiedAt = verifiedAt; self.lastUsedAt = lastUsedAt
    }

    /// File names are derived from the release, never from server text.
    public static func fileName(for releaseID: UUID, mediaType: String) -> String {
        let suffix = switch mediaType { case "audio/mpeg": "mp3"; case "audio/wav": "wav"; case "audio/aac": "aac"; default: "m4a" }
        return "\(releaseID.wire).\(suffix)"
    }

    func validate() throws {
        guard fileName == Self.fileName(for: episode.id, mediaType: mediaType), bytes == episode.audio.bytes, sha256 == episode.audio.sha256,
              mediaType == episode.audio.mediaType else { throw ReaderError.corruptData }
        try episode.validate()
    }
}

/// The account's podcast files on this device, sealed with AES-GCM under domain-separated subkeys of the
/// device-held local-store key (as `ReadingActivityStore`). The account is bound into the authenticated data.
/// An unreadable file only forgets history or the downloads list (the audio is re-verified before use).
public actor PodcastLocalStore {
    public static let historyFile = "podcast-history.enc"
    public static let downloadsFile = "podcast-downloads.enc"
    public static let maximumDownloads = 100
    private let directory: URL
    private let accountID: UUID
    private let historyKey: SymmetricKey
    private let downloadsKey: SymmetricKey

    public init(directory: URL, accountID: UUID, localKey: Data) throws {
        guard localKey.count == 32 else { throw ReaderError.invalidKey }
        self.directory = directory; self.accountID = accountID
        let input = SymmetricKey(data: localKey), salt = Data(accountID.wire.utf8)
        historyKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt, info: Data("science-reader/local-podcast-history/v1".utf8), outputByteCount: 32)
        downloadsKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt, info: Data("science-reader/local-podcast-downloads/v1".utf8), outputByteCount: 32)
    }

    private func aad(_ domain: String) -> Data { Data("science-reader/\(domain)/v1\n\(accountID.wire)\n".utf8) }

    public func loadHistory() -> PodcastPlaybackLedger {
        guard let sealed = try? Data(contentsOf: directory.appendingPathComponent(Self.historyFile)),
              let plain = try? AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: historyKey, authenticating: aad("local-podcast-history")),
              let ledger = try? JSONDecoder.podcast.decode(PodcastPlaybackLedger.self, from: plain) else { return PodcastPlaybackLedger() }
        return ledger
    }

    public func saveHistory(_ ledger: PodcastPlaybackLedger) throws {
        try write(JSONEncoder.podcast.encode(ledger.bounded()), key: historyKey, domain: "local-podcast-history", file: Self.historyFile)
    }

    public func loadDownloads() -> [PodcastDownloadRecord] {
        guard let sealed = try? Data(contentsOf: directory.appendingPathComponent(Self.downloadsFile)),
              let plain = try? AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: downloadsKey, authenticating: aad("local-podcast-downloads")),
              let records = try? JSONDecoder.podcast.decode([PodcastDownloadRecord].self, from: plain),
              records.count <= Self.maximumDownloads, Set(records.map(\.episode.id)).count == records.count,
              (try? records.forEach { try $0.validate() }) != nil else { return [] }
        return records
    }

    public func saveDownloads(_ records: [PodcastDownloadRecord]) throws {
        guard records.count <= Self.maximumDownloads, Set(records.map(\.episode.id)).count == records.count else { throw ReaderError.localCapacityExceeded }
        try records.forEach { try $0.validate() }
        try write(JSONEncoder.podcast.encode(records), key: downloadsKey, domain: "local-podcast-downloads", file: Self.downloadsFile)
    }

    private func write(_ plain: Data, key: SymmetricKey, domain: String, file: String) throws {
        guard let sealed = try AES.GCM.seal(plain, using: key, authenticating: aad(domain)).combined else { throw ReaderError.corruptData }
        // Never recreate a folder that sign-out retirement or account deletion removed.
        guard FileManager.default.fileExists(atPath: directory.path) else { throw ReaderError.storageUnavailable }
        let url = directory.appendingPathComponent(file)
        #if os(iOS)
        try sealed.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try sealed.write(to: url, options: .atomic)
        #endif
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var target = url; try? target.setResourceValues(values)
    }
}

extension JSONEncoder {
    static var podcast: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; return encoder }
}
extension JSONDecoder {
    static var podcast: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970; return decoder }
}
