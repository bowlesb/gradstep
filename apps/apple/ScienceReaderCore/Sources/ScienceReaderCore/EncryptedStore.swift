import CSQLite
import CryptoKit
import Darwin
import Foundation

public struct RemoteEvent: Sendable {
    public let cursor: Int64
    public let envelope: EventEnvelope
    public let digest: Data
    public init(cursor: Int64, envelope: EventEnvelope, digest: Data) { self.cursor = cursor; self.envelope = envelope; self.digest = digest }
}

private struct LocalMetadata: Codable, Equatable {
    var format: Int
    let accountID: UUID
    var generation: Int64 = 0
    var cursor: Int64 = 0
    var count: Int64 = 0
    var chain = Data(repeating: 0, count: 32)
    var outbox: [UUID] = []
    init(accountID: UUID) { self.format = 3; self.accountID = accountID }
}

private struct ReplacementMarker: Codable {
    let localOperation: String
    let epoch: Int
    let sourceCursor: Int64
    let replacements: [String: UUID]
    init(epoch: Int, cursor: Int64, mapping: [UUID: UUID]) {
        localOperation = "replace-unpublished/v1"; self.epoch = epoch; sourceCursor = cursor
        replacements = Dictionary(uniqueKeysWithValues: mapping.map { ($0.key.wire, $0.value) })
    }
    func mapping() throws -> [UUID: UUID] {
        guard localOperation == "replace-unpublished/v1", epoch > 0, sourceCursor >= 0, !replacements.isEmpty,
              replacements.count <= 1_000 else { throw ReaderError.corruptData }
        return try Dictionary(uniqueKeysWithValues: replacements.map { old, new in
            guard let id = UUID(uuidString: old), id.wire == old else { throw ReaderError.corruptData }
            return (id, new)
        })
    }
}
private enum JournalRecord { case event(EventEnvelope), replacement(ReplacementMarker) }

/// Immutable sealed records and an encrypted cursor/outbox checkpoint share one
/// SQLite transaction. Private text never enters SQLite, including its WAL.
public actor EncryptedStore {
    private let database: SQLiteConnection
    private let localKey: SymmetricKey
    private let accountID: UUID
    private var keys: KeyBundle
    private var metadata: LocalMetadata
    private var pendingEnvelopes: [UUID: EventEnvelope]
    private var reduced: PrivateState
    private var needsReopen = false
    private static let maximumPending = 1_000
    private static let maximumPendingBytes = 16 * 1024 * 1024

    public init(url: URL, accountID: UUID, localKey: Data, keys: KeyBundle) throws {
        guard localKey.count == 32 else { throw ReaderError.invalidKey }
        try keys.validate(accountID: accountID)
        let symmetricKey = SymmetricKey(data: localKey)
        self.accountID = accountID; self.localKey = symmetricKey; self.keys = keys
        let manager = FileManager.default
        var directory = url.deletingLastPathComponent()
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        try manager.setAttributes(attributes, ofItemAtPath: directory.path)
        var protection = URLResourceValues(); protection.isExcludedFromBackup = true
        try directory.setResourceValues(protection)
        let exists = manager.fileExists(atPath: url.path)
        if !exists {
            let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw ReaderError.storageUnavailable }
            Darwin.close(descriptor)
            #if os(iOS)
            try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            #endif
        } else {
            // Preserve an incompatible prototype, truncated DB, or symlink.
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ReaderError.corruptData }
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            guard try file.read(upToCount: 16) == Data("SQLite format 3\0".utf8) else { throw ReaderError.unsupportedFormat }
        }
        database = try SQLiteConnection(url: url)
        try database.execute("PRAGMA trusted_schema=OFF; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY; PRAGMA synchronous=FULL; PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=128;")
        if !exists {
            try database.execute("BEGIN IMMEDIATE; CREATE TABLE records(ordinal INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, sealed BLOB NOT NULL); CREATE TABLE metadata(id INTEGER PRIMARY KEY CHECK(id=1), sealed BLOB NOT NULL); PRAGMA application_id=1397903940; PRAGMA user_version=2;")
            do {
                let sealed = try Self.sealMetadata(LocalMetadata(accountID: accountID), key: symmetricKey)
                try database.update("INSERT INTO metadata(id,sealed) VALUES(1,?)", values: [.blob(sealed)])
                try database.execute("COMMIT")
            } catch { try? database.execute("ROLLBACK"); throw error }
        }
        try database.execute("BEGIN")
        let loaded = try Self.readMetadata(database, key: symmetricKey, accountID: accountID)
        guard [2, 3].contains(loaded.format) else { throw ReaderError.unsupportedFormat }
        guard loaded.cursor >= 0, loaded.count >= 0, loaded.generation >= 0, loaded.chain.count == 32,
              loaded.outbox.count <= Self.maximumPending, Set(loaded.outbox).count == loaded.outbox.count else { throw ReaderError.corruptData }
        var count: Int64 = 0; var chain = Data(repeating: 0, count: 32)
        var state = PrivateState(); var pending: [UUID: EventEnvelope] = [:]
        let outbox = Set(loaded.outbox)
        try database.statement("SELECT ordinal,id,sealed FROM records ORDER BY ordinal") { statement in
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw DatabaseFailure(code: result) }
                let ordinal = sqlite3_column_int64(statement, 0)
                guard ordinal == count + 1, let id = UUID(uuidString: try SQLiteConnection.text(statement, 1)) else { throw ReaderError.corruptData }
                let sealed = try SQLiteConnection.blob(statement, 2)
                switch try Self.openRecord(sealed, id: id, ordinal: ordinal, accountID: accountID, key: symmetricKey) {
                case .event(let envelope):
                    let payload = try ReaderCrypto.open(envelope, keys: keys)
                    try state.apply(AppliedEvent(id: envelope.id, deviceID: envelope.deviceID, payload: payload))
                    if outbox.contains(id) { pending[id] = envelope }
                case .replacement(let marker):
                    guard loaded.format >= 3, marker.sourceCursor <= loaded.cursor, marker.epoch <= keys.epoch else { throw ReaderError.corruptData }
                    try state.applyLocalReplacements(marker.mapping())
                }
                chain = Self.advanceChain(chain, sealed: sealed, id: id, ordinal: ordinal, accountID: accountID)
                count = ordinal
            }
        }
        guard count == loaded.count, chain == loaded.chain, pending.count == loaded.outbox.count else { throw ReaderError.corruptData }
        try database.execute("COMMIT")
        metadata = loaded; pendingEnvelopes = pending; reduced = state
    }

    public func state() -> PrivateState { reduced }
    public func cursor() -> Int64 { metadata.cursor }
    public func pending() -> [EventEnvelope] { metadata.outbox.compactMap { pendingEnvelopes[$0] } }

    @discardableResult
    public func append(_ event: PrivateEvent, deviceID: UUID, id: UUID = UUID()) throws -> EventEnvelope {
        var event = event
        event.parents = event.parents.map { reduced.resolvedEventID($0) }
        guard event.parents.allSatisfy({ reduced.events[$0] != nil }) else { throw ReaderError.invalidEvent }
        let resolvedID = reduced.resolvedEventID(id)
        if let existing = try lookup(resolvedID) {
            var expected = event; expected.parents = expected.parents.map { reduced.resolvedEventID($0) }
            guard (existing.deviceID == deviceID || resolvedID != id), try ReaderCrypto.open(existing, keys: keys) == expected else { throw ReaderError.eventConflict }
            return existing
        }
        guard metadata.outbox.count < Self.maximumPending else { throw ReaderError.localCapacityExceeded }
        let envelope = try ReaderCrypto.seal(event, id: id, deviceID: deviceID, keys: keys)
        guard pendingEnvelopes.values.reduce(envelope.ciphertext.count, { $0 + $1.ciphertext.count }) <= Self.maximumPendingBytes else { throw ReaderError.localCapacityExceeded }
        var state = reduced
        try state.apply(AppliedEvent(id: envelope.id, deviceID: deviceID, payload: event))
        var next = metadata; next.outbox.append(envelope.id)
        try commit(records: [envelope], next: &next)
        metadata = next; reduced = state; pendingEnvelopes[envelope.id] = envelope
        return envelope
    }

    public func acknowledge(_ envelope: EventEnvelope) throws {
        guard try lookup(envelope.id) == envelope else { throw ReaderError.eventConflict }
        guard metadata.outbox.contains(envelope.id) else { return }
        var next = metadata; next.outbox.removeAll { $0 == envelope.id }
        try commit(records: [], next: &next)
        metadata = next; pendingEnvelopes.removeValue(forKey: envelope.id)
    }

    public func ingest(_ page: [RemoteEvent]) throws {
        guard !page.isEmpty else { return }
        guard page.count <= 200 else { throw ReaderError.invalidEvent }
        var next = metadata; var state = reduced; var additions: [EventEnvelope] = []
        var received = Set<UUID>()
        for remote in page {
            guard next.cursor < Int64.max, remote.cursor == next.cursor + 1 else { throw ReaderError.cursorGap }
            let envelope = remote.envelope
            guard received.insert(envelope.id).inserted, envelope.sha256 == remote.digest else { throw ReaderError.corruptData }
            if let existing = try lookup(envelope.id) {
                guard existing == envelope else { throw ReaderError.eventConflict }
            } else { additions.append(envelope) }
            let payload = try ReaderCrypto.open(envelope, keys: keys)
            try state.apply(AppliedEvent(id: envelope.id, deviceID: envelope.deviceID, payload: payload))
            next.outbox.removeAll { $0 == envelope.id }; next.cursor = remote.cursor
        }
        try commit(records: additions, next: &next)
        metadata = next; reduced = state
        for id in received { pendingEnvelopes.removeValue(forKey: id) }
    }

    public func updateKeys(_ newKeys: KeyBundle) throws {
        try newKeys.validate(accountID: accountID)
        guard newKeys.epoch >= keys.epoch, keys.contentKeys.allSatisfy({ newKeys.contentKeys[$0.key] == $0.value }) else { throw ReaderError.invalidKey }
        keys = newKeys
    }

    /// Caller must first refresh server authority and pull to the end. A newer
    /// server epoch fences all late old-epoch submissions; only then is absence
    /// from that catch-up proof that these pending events were never committed.
    @discardableResult
    public func rebasePendingAfterCatchUp(deviceID: UUID, verifiedEpoch: Int, cursor: Int64) throws -> [UUID: UUID] {
        guard verifiedEpoch == keys.epoch, cursor == metadata.cursor else { throw ReaderError.staleEpoch }
        let pending = metadata.outbox.compactMap { pendingEnvelopes[$0] }
        let payloads = try Dictionary(uniqueKeysWithValues: pending.map { ($0.id, try ReaderCrypto.open($0, keys: keys)) })
        var affected = Set(pending.filter { $0.epoch < verifiedEpoch }.map(\.id))
        guard !affected.isEmpty else { return [:] }
        var grew = true
        while grew {
            grew = false
            for envelope in pending where !affected.contains(envelope.id) {
                if payloads[envelope.id]!.parents.contains(where: { affected.contains($0) }) { affected.insert(envelope.id); grew = true }
            }
        }
        let mapping = Dictionary(uniqueKeysWithValues: affected.map { ($0, UUID()) })
        var replacements: [EventEnvelope] = [], state = reduced
        for original in pending where affected.contains(original.id) {
            var payload = payloads[original.id]!
            payload.parents = payload.parents.map { mapping[$0] ?? $0 }
            let envelope = try ReaderCrypto.seal(payload, id: mapping[original.id]!, deviceID: deviceID, keys: keys)
            replacements.append(envelope)
            try state.apply(AppliedEvent(id: envelope.id, deviceID: deviceID, payload: payload))
        }
        try state.applyLocalReplacements(mapping)
        var next = metadata; next.outbox = next.outbox.map { mapping[$0] ?? $0 }
        try commit(records: replacements, next: &next, replacement: ReplacementMarker(epoch: verifiedEpoch, cursor: cursor, mapping: mapping))
        metadata = next; reduced = state
        for id in affected { pendingEnvelopes.removeValue(forKey: id) }
        for envelope in replacements { pendingEnvelopes[envelope.id] = envelope }
        return mapping
    }

    private func lookup(_ id: UUID) throws -> EventEnvelope? {
        guard !needsReopen else { throw ReaderError.storageUnavailable }
        return try database.statement("SELECT ordinal,sealed FROM records WHERE id=?", values: [.text(id.wire)]) { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw DatabaseFailure(code: result) }
            switch try Self.openRecord(SQLiteConnection.blob(statement, 1), id: id, ordinal: sqlite3_column_int64(statement, 0), accountID: accountID, key: localKey) {
            case .event(let envelope): return envelope
            case .replacement: throw ReaderError.eventConflict
            }
        }
    }

    private func commit(records: [EventEnvelope], next: inout LocalMetadata, replacement: ReplacementMarker? = nil) throws {
        guard !needsReopen, metadata.generation < Int64.max else { throw ReaderError.storageUnavailable }
        try database.execute("BEGIN IMMEDIATE")
        do {
            guard try Self.readMetadata(database, key: localKey, accountID: accountID) == metadata else { throw ReaderError.storeChanged }
            for envelope in records {
                try insertRecord(ReaderCrypto.encode(envelope), id: envelope.id, next: &next)
            }
            if let replacement { try insertRecord(ReaderCrypto.encode(replacement), id: UUID(), next: &next) }
            next.format = 3
            next.generation += 1
            try database.update("UPDATE metadata SET sealed=? WHERE id=1", values: [.blob(Self.sealMetadata(next, key: localKey))])
            try database.execute("COMMIT")
        } catch {
            if database.inTransaction {
                do { try database.execute("ROLLBACK") } catch { needsReopen = true }
            } else {
                if let actual = try? Self.readMetadata(database, key: localKey, accountID: accountID) {
                    if actual == next { return }
                    if actual != metadata { needsReopen = true }
                } else { needsReopen = true }
            }
            throw error
        }
    }

    private func insertRecord(_ plain: Data, id: UUID, next: inout LocalMetadata) throws {
        guard next.count < Int64.max else { throw ReaderError.localCapacityExceeded }
        let ordinal = next.count + 1
        let aad = Self.recordAAD(accountID: accountID, id: id, ordinal: ordinal)
        guard let sealed = try AES.GCM.seal(plain, using: localKey, authenticating: aad).combined else { throw ReaderError.corruptData }
        try database.update("INSERT INTO records(ordinal,id,sealed) VALUES(?,?,?)", values: [.integer(ordinal), .text(id.wire), .blob(sealed)])
        next.chain = Self.advanceChain(next.chain, sealed: sealed, id: id, ordinal: ordinal, accountID: accountID)
        next.count = ordinal
    }

    private static func sealMetadata(_ metadata: LocalMetadata, key: SymmetricKey) throws -> Data {
        let aad = Data("science-reader/local-metadata/v2/\(metadata.accountID.wire)".utf8)
        guard let bytes = try AES.GCM.seal(ReaderCrypto.encode(metadata), using: key, authenticating: aad).combined else { throw ReaderError.corruptData }
        return bytes
    }

    private static func readMetadata(_ database: SQLiteConnection, key: SymmetricKey, accountID: UUID) throws -> LocalMetadata {
        try database.statement("SELECT sealed FROM metadata WHERE id=1") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw ReaderError.corruptData }
            let sealed = try SQLiteConnection.blob(statement, 0)
            let aad = Data("science-reader/local-metadata/v2/\(accountID.wire)".utf8)
            let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: aad)
            let metadata = try JSONDecoder().decode(LocalMetadata.self, from: bytes)
            guard metadata.accountID == accountID else { throw ReaderError.wrongAccount }
            return metadata
        }
    }

    private static func recordAAD(accountID: UUID, id: UUID, ordinal: Int64) -> Data {
        Data("science-reader/local-record/v2\n\(accountID.wire)\n\(ordinal)\n\(id.wire)\n".utf8)
    }
    private static func advanceChain(_ chain: Data, sealed: Data, id: UUID, ordinal: Int64, accountID: UUID) -> Data {
        Data(SHA256.hash(data: Data("science-reader/local-chain/v2\n".utf8) + recordAAD(accountID: accountID, id: id, ordinal: ordinal) + chain + sealed))
    }
    private static func openRecord(_ sealed: Data, id: UUID, ordinal: Int64, accountID: UUID, key: SymmetricKey) throws -> JournalRecord {
        let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: recordAAD(accountID: accountID, id: id, ordinal: ordinal))
        struct Header: Decodable { let localOperation: String? }
        if try JSONDecoder().decode(Header.self, from: bytes).localOperation != nil {
            return .replacement(try JSONDecoder().decode(ReplacementMarker.self, from: bytes))
        }
        let envelope = try JSONDecoder().decode(EventEnvelope.self, from: bytes)
        guard envelope.id == id else { throw ReaderError.corruptData }
        return .event(envelope)
    }
}
