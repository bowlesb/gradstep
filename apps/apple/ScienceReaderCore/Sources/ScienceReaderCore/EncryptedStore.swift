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

/// A coherent view of one committed local generation. Generation is local to
/// this account's store; it is neither a cloud cursor nor a message timestamp.
public struct LocalStoreSnapshot: Equatable, Sendable {
    public let state: PrivateState
    public let generation: Int64
    public let pendingCount: Int
    public let drafts: [LocalDraft]
    public init(state: PrivateState, generation: Int64, pendingCount: Int, drafts: [LocalDraft] = []) {
        self.state = state; self.generation = generation; self.pendingCount = pendingCount
        self.drafts = drafts
    }
}

private struct LocalMetadata: Codable, Equatable {
    var format: Int
    let accountID: UUID
    var generation: Int64 = 0
    var cursor: Int64 = 0
    var count: Int64 = 0
    var chain = Data(repeating: 0, count: 32)
    var outbox: [UUID] = []
    // Optional only for decoding formats 2/3. Format 4 requires this bounded
    // authenticated manifest, including empty coordination rows and tombstones.
    var drafts: [String: Data]?
    var libraryCommands: [String: Data]?
    var libraryCommandSequence: Int64?
    var libraryCommandScope: LibraryCommandScope?
    var offlineCache: OfflineCacheRoots?
    init(accountID: UUID) {
        self.format = 6; self.accountID = accountID; self.drafts = [:]
        self.libraryCommands = [:]; self.libraryCommandSequence = 0; self.offlineCache = .init()
    }
}

private struct DraftReceipt: Codable, Equatable {
    let submissionID: UUID
    let checkpointRevision: Int64
    let textRevision: UUID
    let branchRevision: UUID
    let requestDigest: Data
    let eventIDs: [UUID]
    let deviceID: UUID
}

private struct StoredDraft: Codable, Equatable {
    var draft: LocalDraft
    var checkpointDigest: Data
    var discarded = false
    var receipt: DraftReceipt?
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
    private var localDrafts: [UUID: StoredDraft]
    private var draftBytes: [UUID: Int]
    private var libraryJournal: LibraryCommandJournal
    private let libraryWriterID = UUID()
    private var readerInstallTicket: ReaderInstallTicket?
    private var needsReopen = false
    private static let maximumPending = 1_000
    private static let maximumPendingBytes = 16 * 1024 * 1024
    private static let maximumDraftRows = 1_024
    private static let maximumNonemptyDrafts = 128
    private static let maximumDraftBytes = 8 * 1024 * 1024
    private static let maximumDraftRowBytes = 262_144

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
            try database.execute("BEGIN IMMEDIATE; CREATE TABLE records(ordinal INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, sealed BLOB NOT NULL); CREATE TABLE metadata(id INTEGER PRIMARY KEY CHECK(id=1), sealed BLOB NOT NULL); CREATE TABLE local_drafts(id TEXT PRIMARY KEY NOT NULL, sealed BLOB NOT NULL); CREATE TABLE local_library_commands(id TEXT PRIMARY KEY NOT NULL, sealed BLOB NOT NULL); PRAGMA application_id=1397903940; PRAGMA user_version=5;")
            do {
                try database.execute(OfflineCacheStorage.createTables)
                let sealed = try Self.sealMetadata(LocalMetadata(accountID: accountID), key: symmetricKey)
                try database.update("INSERT INTO metadata(id,sealed) VALUES(1,?)", values: [.blob(sealed)])
                try database.execute("COMMIT")
            } catch { try? database.execute("ROLLBACK"); throw error }
        }
        try database.execute("BEGIN")
        var loaded = try Self.readMetadata(database, key: symmetricKey, accountID: accountID)
        guard [2, 3, 4, 5, 6].contains(loaded.format) else { throw ReaderError.unsupportedFormat }
        let schemaVersion = try database.statement("PRAGMA user_version") { statement -> Int32 in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw ReaderError.corruptData }
            return sqlite3_column_int(statement, 0)
        }
        guard schemaVersion == (loaded.format == 6 ? 5 : loaded.format == 5 ? 4 : loaded.format == 4 ? 3 : 2) else { throw ReaderError.unsupportedFormat }
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
        var drafts: [UUID: StoredDraft] = [:], sizes: [UUID: Int] = [:]
        if loaded.format >= 4 {
            guard let manifest = loaded.drafts, manifest.count <= Self.maximumDraftRows else { throw ReaderError.corruptData }
            try database.statement("SELECT id,sealed FROM local_drafts") { statement in
                while true {
                    let result = sqlite3_step(statement)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW else { throw DatabaseFailure(code: result) }
                    let name = try SQLiteConnection.text(statement, 0)
                    guard let id = UUID(uuidString: name), id.wire == name, drafts[id] == nil else { throw ReaderError.corruptData }
                    let sealed = try SQLiteConnection.blob(statement, 1)
                    guard sealed.count <= Self.maximumDraftRowBytes, manifest[name] == Data(SHA256.hash(data: sealed)) else { throw ReaderError.corruptData }
                    let row = try Self.openDraft(sealed, id: id, accountID: accountID, key: symmetricKey)
                    try Self.validateStoredDraft(row, state: state)
                    drafts[id] = row; sizes[id] = sealed.count
                }
            }
            guard drafts.count == manifest.count, sizes.values.reduce(0, +) <= Self.maximumDraftBytes,
                  drafts.values.filter({ !$0.discarded && !$0.draft.text.isEmpty }).count <= Self.maximumNonemptyDrafts else { throw ReaderError.corruptData }
        } else {
            guard loaded.drafts == nil else { throw ReaderError.corruptData }
        }
        var commands = LibraryCommandJournal()
        if loaded.format >= 5 {
            guard let manifest = loaded.libraryCommands, manifest.count <= LibraryCommandJournal.maximumRows,
                  let sequence = loaded.libraryCommandSequence, sequence >= 0 else { throw ReaderError.corruptData }
            commands.scope = loaded.libraryCommandScope; commands.sequence = sequence
            if let scope = commands.scope { try scope.validate(); guard scope.accountID == accountID else { throw ReaderError.wrongAccount } }
            var bytes = 0
            try database.statement("SELECT id,sealed FROM local_library_commands") { statement in
                while true {
                    let result = sqlite3_step(statement)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW else { throw DatabaseFailure(code: result) }
                    let name = try SQLiteConnection.text(statement, 0)
                    guard let id = UUID(uuidString: name), id.wire == name, commands.rows[id] == nil,
                          let scope = commands.scope else { throw ReaderError.corruptData }
                    let sealed = try SQLiteConnection.blob(statement, 1)
                    guard sealed.count <= LibraryCommandJournal.maximumRowBytes,
                          manifest[name] == Data(SHA256.hash(data: sealed)) else { throw ReaderError.corruptData }
                    let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: symmetricKey,
                                                 authenticating: Self.libraryCommandAAD(id: id, scope: scope))
                    let row = try JSONDecoder().decode(LocalLibraryCommand.self, from: plain)
                    guard row.id == id else { throw ReaderError.corruptData }
                    commands.rows[id] = row; bytes += sealed.count
                }
            }
            guard commands.rows.count == manifest.count, bytes <= LibraryCommandJournal.maximumBytes else { throw ReaderError.corruptData }
            try commands.validate()
        } else {
            guard loaded.libraryCommands == nil, loaded.libraryCommandSequence == nil,
                  loaded.libraryCommandScope == nil else { throw ReaderError.corruptData }
        }
        if loaded.format == 6 {
            guard let roots = loaded.offlineCache else { throw ReaderError.corruptData }
            try roots.validate(accountID: accountID)
            if let scope = roots.scope, let commands = loaded.libraryCommandScope {
                guard scope == commands else { throw ReaderError.corruptData }
            }
        } else { guard loaded.offlineCache == nil else { throw ReaderError.corruptData } }
        try database.execute("COMMIT")

        // Only a fresh store owner may collect coordination rows. Its metadata
        // generation change fences any previous actor still holding callbacks.
        // Ordinary same-account activation reuses this actor and never prunes.
        let pruned = drafts.filter { $0.value.discarded || $0.value.draft.text.isEmpty }.map(\.key)
        if exists {
            guard loaded.generation < Int64.max else { throw ReaderError.storageUnavailable }
            var migrated = loaded
            try database.execute("BEGIN IMMEDIATE")
            do {
                guard try Self.readMetadata(database, key: symmetricKey, accountID: accountID) == loaded else { throw ReaderError.storeChanged }
                if loaded.format < 4 {
                    try database.execute("CREATE TABLE local_drafts(id TEXT PRIMARY KEY NOT NULL, sealed BLOB NOT NULL)")
                    migrated.drafts = [:]
                }
                if loaded.format < 5 {
                    try database.execute("CREATE TABLE local_library_commands(id TEXT PRIMARY KEY NOT NULL, sealed BLOB NOT NULL)")
                    migrated.libraryCommands = [:]; migrated.libraryCommandSequence = 0
                }
                if loaded.format < 6 {
                    try database.execute(OfflineCacheStorage.createTables)
                    migrated.offlineCache = .init()
                }
                let previousCommands = commands
                try commands.reopen()
                for row in commands.rows.values where previousCommands.rows[row.id] != row {
                    let sealed = try Self.sealLibraryCommand(row, key: symmetricKey)
                    try database.update("UPDATE local_library_commands SET sealed=? WHERE id=?", values: [.blob(sealed), .text(row.id.wire)])
                    migrated.libraryCommands?[row.id.wire] = Data(SHA256.hash(data: sealed))
                }
                for id in pruned {
                    try database.update("DELETE FROM local_drafts WHERE id=?", values: [.text(id.wire)])
                    migrated.drafts?.removeValue(forKey: id.wire)
                }
                migrated.format = 6; migrated.generation += 1
                try database.execute("PRAGMA user_version=5")
                try database.update("UPDATE metadata SET sealed=? WHERE id=1", values: [.blob(Self.sealMetadata(migrated, key: symmetricKey))])
                try database.execute("COMMIT")
            } catch { if database.inTransaction { try? database.execute("ROLLBACK") }; throw error }
            loaded = migrated
            for id in pruned { drafts.removeValue(forKey: id); sizes.removeValue(forKey: id) }
        }
        metadata = loaded; pendingEnvelopes = pending; reduced = state
        localDrafts = drafts; draftBytes = sizes
        libraryJournal = commands
    }

    public func state() -> PrivateState { reduced }
    public func cursor() -> Int64 { metadata.cursor }
    public func pending() -> [EventEnvelope] { metadata.outbox.compactMap { pendingEnvelopes[$0] } }
    public func snapshot() -> LocalStoreSnapshot {
        let drafts = localDrafts.values.filter { !$0.discarded && !$0.draft.text.isEmpty }
            .map { canonicalDraft($0.draft) }
            .sorted { $0.editedAt == $1.editedAt ? $0.id.wire < $1.id.wire : $0.editedAt > $1.editedAt }
        return LocalStoreSnapshot(state: reduced, generation: metadata.generation, pendingCount: metadata.outbox.count, drafts: drafts)
    }

    public func libraryCommandSnapshot(scope: LibraryCommandScope) throws -> LocalLibraryCommandSnapshot {
        try libraryJournal.requireScope(scope, accountID: accountID)
        try validateLibraryAuthority()
        return LocalLibraryCommandSnapshot(generation: metadata.generation,
            commands: libraryJournal.rows.values.sorted { $0.handle.localSequence < $1.handle.localSequence })
    }

    public func cachedLibraryPresentation(scope: LibraryCommandScope) throws -> CachedLibraryPresentation? {
        try withOfflineCache(scope: scope) { try $0.presentation($1) }
    }

    /// The synchronous projector runs on this store's actor, one validated row
    /// at a time. It must not publish partial state, await, or mutate the store.
    /// No projection escapes unless the entire checkpoint and all links pass.
    public func cachedLibraryProjection<Row: Sendable>(scope: LibraryCommandScope,
        project: @Sendable (LibraryEntry) throws -> Row?) throws -> CachedLibraryProjection<Row>? {
        let result = try withOfflineCache(scope: scope) { try $0.projectPresentation($1, project: project) }
        try Task.checkCancellation()
        return result
    }

    @discardableResult
    public func saveLibraryPresentation(_ observation: LibraryCompleteObservation, scope: LibraryCommandScope,
                                         capturedAt: Date = Date()) throws -> CachedLibraryPresentation {
        try saveLibraryPresentation(observation, scope: scope, capturedAt: capturedAt, format: CachePresentationCheckpoint.currentFormat)
    }

    /// Replaces the saved library list with `observation` when it can't be saved over it
    /// (`OfflineCacheError.replacesSavedLibrary`). Only the list of papers is rewritten, from the
    /// server's complete state; downloaded papers, notes, chats and pending changes are untouched.
    @discardableResult
    public func rebuildLibraryPresentation(_ observation: LibraryCompleteObservation, scope: LibraryCommandScope,
                                           capturedAt: Date = Date()) throws -> CachedLibraryPresentation {
        try saveLibraryPresentation(observation, scope: scope, capturedAt: capturedAt,
                                    format: CachePresentationCheckpoint.currentFormat, rebuild: true)
    }

    /// An earlier `format` only in tests: a snapshot as an older build saved it.
    @discardableResult
    func saveLibraryPresentation(_ observation: LibraryCompleteObservation, scope: LibraryCommandScope,
                                 capturedAt: Date = Date(), format: Int, rebuild: Bool = false) throws -> CachedLibraryPresentation {
        guard observation.accountID == accountID else { throw ReaderError.wrongAccount }
        let prepared = try withOfflineCache(scope: scope) {
            try $0.preparePresentation(observation, roots: $1, capturedAt: capturedAt, format: format, rebuild: rebuild)
        }
        if let mutation = prepared.0 { try persistOfflineCache(mutation) }
        return prepared.1
    }

    public func listInstalledReaderBundles(scope: LibraryCommandScope) throws -> InstalledReaderBundleList {
        try withOfflineCache(scope: scope) { try $0.list($1, generation: metadata.generation) }
    }

    public func beginReaderInstall(binding: ReaderArtifactBinding) throws -> ReaderInstallTicket {
        try binding.validate()
        let installationID = try withOfflineCache(scope: binding.scope) { storage, roots -> UUID in
            let index = try storage.index(roots).value
            let existing = index.installations.first { $0.artifactID == binding.artifactID }
            if let existing {
                guard try existing.binding(scope: binding.scope) == binding else { throw OfflineCacheError.invalidBinding }
            }
            let current = try storage.eligibility(binding: binding, roots: roots, existing: existing?.eligibility ?? .init())
            guard current.block == nil, current.membershipVisible != false else { throw OfflineCacheError.blocked }
            guard existing != nil || index.installations.count < OfflineCacheLimits.installedBundles else { throw OfflineCacheError.capacityExceeded }
            return existing?.id ?? UUID()
        }
        if let current = readerInstallTicket {
            guard current.binding == binding else { throw OfflineCacheError.installBusy }
            return current
        }
        let ticket = ReaderInstallTicket(id: UUID(), binding: binding, writerID: libraryWriterID, installationID: installationID)
        readerInstallTicket = ticket
        return ticket
    }

    /// An ended ticket is harmless; it never cancels a later install. There is
    /// no database mutation, so retirement may always release its own ticket.
    public func cancelReaderInstall(_ ticket: ReaderInstallTicket) throws {
        guard ticket.writerID == libraryWriterID else { throw OfflineCacheError.staleTicket }
        if readerInstallTicket == ticket { readerInstallTicket = nil }
    }

    /// Core verification is not PNG/ImageIO admission. Native callers must run
    /// ReaderBundleLoader before accepting this commit and after reopening.
    @discardableResult
    public func commitReaderInstall(_ ticket: ReaderInstallTicket, bundle: VerifiedReaderBundle) throws -> InstalledReaderBundle {
        guard ticket.writerID == libraryWriterID else { throw OfflineCacheError.staleTicket }
        let prepared = try withOfflineCache(scope: ticket.binding.scope) { storage, roots in
            if readerInstallTicket != ticket {
                let existing = try storage.installed(ticket.installationID, roots: roots)
                guard try existing.binding(scope: ticket.binding.scope) == ticket.binding else { throw OfflineCacheError.staleTicket }
            }
            return try storage.prepareInstall(ticket.binding, id: ticket.installationID, bundle: bundle, roots: roots)
        }
        if let mutation = prepared.0 { try persistOfflineCache(mutation) }
        if readerInstallTicket == ticket { readerInstallTicket = nil }
        return prepared.1
    }

    public func readReaderBundle(id: UUID, scope: LibraryCommandScope) throws -> StoredReaderBundlePayload {
        try withOfflineCache(scope: scope) { try $0.read(id, roots: $1, writerID: libraryWriterID) }
    }

    public func validateReaderOpen(_ token: ReaderBundleOpenToken) throws -> InstalledReaderBundle {
        guard token.writerID == libraryWriterID else { throw OfflineCacheError.staleTicket }
        return try withOfflineCache(scope: token.binding.scope) { storage, roots in
            let value = try storage.installed(token.installationID, roots: roots)
            guard value.revision == token.revision, try value.binding(scope: token.binding.scope) == token.binding
            else { throw OfflineCacheError.revisionConflict }
            let summary = try value.summary(scope: token.binding.scope)
            guard summary.canOpen else { throw OfflineCacheError.blocked }
            return summary
        }
    }

    public func removeReaderBundle(id: UUID, expectedRevision: Int64, scope: LibraryCommandScope) throws {
        let prepared = try withOfflineCache(scope: scope) { try $0.prepareRemoval(id, revision: expectedRevision, roots: $1) }
        try persistOfflineCache(prepared.0)
        if readerInstallTicket?.binding == prepared.1 { readerInstallTicket = nil }
    }

    private func withOfflineCache<T>(scope: LibraryCommandScope,
        _ body: (OfflineCacheStorage, OfflineCacheRoots) throws -> T) throws -> T {
        try scope.validate()
        guard scope.accountID == accountID else { throw ReaderError.wrongAccount }
        guard let roots = metadata.offlineCache else { throw ReaderError.corruptData }
        guard roots.scope == nil || roots.scope == scope,
              metadata.libraryCommandScope == nil || metadata.libraryCommandScope == scope
        else { throw LibraryCommandError.invalidScope }
        // A coherent read snapshot cannot mix a new index with an old header.
        // The later write transaction repeats the authoritative metadata CAS.
        try database.execute("BEGIN")
        do {
            try validateLibraryAuthority()
            let result = try body(OfflineCacheStorage(database: database, key: localKey, scope: scope), roots)
            try database.execute("COMMIT")
            return result
        } catch {
            if database.inTransaction { do { try database.execute("ROLLBACK") } catch { needsReopen = true } }
            throw error
        }
    }

    private func persistOfflineCache(_ mutation: OfflineCacheMutation) throws {
        var next = metadata
        do { try commit(records: [], next: &next, cache: mutation) }
        catch { if error as? ReaderError == .storeChanged { needsReopen = true }; throw error }
        metadata = next
    }

    @discardableResult
    public func enqueueLibraryCommand(scope: LibraryCommandScope, mutation: LibraryMutation,
                                      display: String? = nil) throws -> LocalLibraryCommandHandle {
        try libraryJournal.requireScope(scope, accountID: accountID)
        var next = libraryJournal
        next.prune()
        let handle = try next.enqueue(mutation, scope: scope, display: display)
        try persistLibraryJournal(next)
        return handle
    }

    /// A tag edit for one library item (migration 030), resolved against pending edits in one transaction.
    @discardableResult
    public func editLibraryTags(scope: LibraryCommandScope, documentID: UUID, tags: [String], hiddenTags: [String],
                                observedRevision: Int64, display: String? = nil) throws -> LocalLibraryCommandHandle {
        try libraryJournal.requireScope(scope, accountID: accountID)
        var next = libraryJournal
        next.prune()
        let handle = try next.editTags(documentID: documentID, tags: tags, hiddenTags: hiddenTags, observedRevision: observedRevision,
                                       scope: scope, display: display)
        try persistLibraryJournal(next)
        return handle
    }

    @discardableResult
    public func holdLibrarySuccessor(_ successor: LibrarySuccessor, after handle: LocalLibraryCommandHandle,
                                     scope: LibraryCommandScope, display: String? = nil) throws -> LocalLibraryCommandHandle {
        try libraryJournal.requireScope(scope, accountID: accountID)
        var next = libraryJournal
        let child = try next.hold(successor, after: handle, display: display)
        try persistLibraryJournal(next)
        return child
    }

    public func beginLibraryAttempt(_ handle: LocalLibraryCommandHandle, scope: LibraryCommandScope) throws -> LibraryCommandAttempt {
        try libraryJournal.requireScope(scope, accountID: accountID)
        var next = libraryJournal
        let attempt = try next.begin(handle, writerID: libraryWriterID)
        try persistLibraryJournal(next)
        return attempt
    }

    @discardableResult
    public func cancelLibraryCommand(_ handle: LocalLibraryCommandHandle,
                                      scope: LibraryCommandScope) throws -> LocalLibraryCommandSnapshot {
        try libraryJournal.requireScope(scope, accountID: accountID)
        var next = libraryJournal
        try next.cancel(handle)
        try persistLibraryJournal(next)
        return try libraryCommandSnapshot(scope: scope)
    }

    @discardableResult
    public func recordLibraryReceipt(_ response: LibraryCommandResponse, for attempt: LibraryCommandAttempt) throws -> LocalLibraryCommandSnapshot {
        try libraryJournal.requireScope(attempt.scope, accountID: accountID)
        var next = libraryJournal
        try next.receive(response, for: attempt, writerID: libraryWriterID)
        try persistLibraryJournal(next)
        return try libraryCommandSnapshot(scope: attempt.scope)
    }

    @discardableResult
    public func recordLibraryFailure(_ failure: LibraryCommandFailure, for attempt: LibraryCommandAttempt) throws -> LocalLibraryCommandSnapshot {
        try libraryJournal.requireScope(attempt.scope, accountID: accountID)
        var next = libraryJournal
        try next.failed(failure, for: attempt, writerID: libraryWriterID)
        try persistLibraryJournal(next)
        return try libraryCommandSnapshot(scope: attempt.scope)
    }

    @discardableResult
    public func discardUnissuedLibraryIntent(_ handle: LocalLibraryCommandHandle, expectedRevision: Int64,
                                             scope: LibraryCommandScope) throws -> LocalLibraryCommandSnapshot {
        try libraryJournal.requireScope(scope, accountID: accountID)
        var next = libraryJournal
        try next.discard(handle, revision: expectedRevision)
        try persistLibraryJournal(next)
        return try libraryCommandSnapshot(scope: scope)
    }

    /// Caller guarantees a complete pull begun after these exact receipts.
    /// Core also validates account, sequence floor, targets and revisions.
    @discardableResult
    public func reconcileLibraryCommands(_ receipts: [LibraryCommandReconciliation],
                                         observation: LibraryCompleteObservation,
                                         scope: LibraryCommandScope) throws -> LocalLibraryCommandSnapshot {
        try libraryJournal.requireScope(scope, accountID: accountID)
        guard observation.accountID == accountID else { throw ReaderError.wrongAccount }
        var next = libraryJournal
        try next.reconcile(receipts, observation: observation)
        try persistLibraryJournal(next)
        return try libraryCommandSnapshot(scope: scope)
    }

    @discardableResult
    public func dismissLibraryCommand(_ handle: LocalLibraryCommandHandle, expectedRevision: Int64,
                                      scope: LibraryCommandScope) throws -> LocalLibraryCommandSnapshot {
        try libraryJournal.requireScope(scope, accountID: accountID)
        var next = libraryJournal
        try next.dismiss(handle, revision: expectedRevision)
        try persistLibraryJournal(next)
        return try libraryCommandSnapshot(scope: scope)
    }

    @discardableResult
    public func pruneLibraryCommands(scope: LibraryCommandScope) throws -> LocalLibraryCommandSnapshot {
        try libraryJournal.requireScope(scope, accountID: accountID)
        var next = libraryJournal; next.prune()
        try persistLibraryJournal(next)
        return try libraryCommandSnapshot(scope: scope)
    }

    private func persistLibraryJournal(_ journal: LibraryCommandJournal) throws {
        try journal.validate()
        if let scope = metadata.offlineCache?.scope, let commandScope = journal.scope {
            guard scope == commandScope else { throw LibraryCommandError.invalidScope }
        }
        try validateLibraryAuthority()
        guard journal != libraryJournal else { return }
        var sealed: [UUID: Data] = [:]
        for row in journal.rows.values where libraryJournal.rows[row.id] != row {
            sealed[row.id] = try Self.sealLibraryCommand(row, key: localKey)
        }
        var next = metadata
        do { try commit(records: [], next: &next, library: (journal, sealed)) }
        catch { if error as? ReaderError == .storeChanged { needsReopen = true }; throw error }
        metadata = next; libraryJournal = journal
    }

    private func validateLibraryAuthority() throws {
        guard !needsReopen else { throw ReaderError.storageUnavailable }
        // Even an exact/no-op command checks disk authority before allowing a
        // caller to rely on the queue. Snapshots use the same check so a safely
        // rolled-back storage failure can resume, but a stale actor cannot.
        guard try Self.readMetadata(database, key: localKey, accountID: accountID) == metadata else {
            needsReopen = true; throw ReaderError.storeChanged
        }
    }

    @discardableResult
    public func append(_ event: PrivateEvent, deviceID: UUID, id: UUID = UUID()) throws -> EventEnvelope {
        try appendBatch([(id: id, event: event)], deviceID: deviceID)[0]
    }

    /// Append dependent events as one local transaction. The caller allocates
    /// stable IDs before saving and places parents before their children. Exact
    /// retries return the original envelopes without adding them to the outbox.
    @discardableResult
    public func appendBatch(_ events: [(id: UUID, event: PrivateEvent)], deviceID: UUID) throws -> [EventEnvelope] {
        var prepared = try prepareAppend(events, deviceID: deviceID)
        guard !prepared.additions.isEmpty else { return prepared.results }
        try commit(records: prepared.additions, next: &prepared.metadata)
        publish(prepared)
        return prepared.results
    }

    /// Checkpoint immediately after accepting an edit. A late checkpoint cannot
    /// resurrect consumed text, undo a send's conversation binding, or overwrite
    /// a newer checkpoint. Equal revisions must be exact retries.
    @discardableResult
    public func saveDraft(_ draft: LocalDraft) throws -> LocalDraft {
        let row = try checkpoint(draft, over: localDrafts[draft.id])
        guard row != localDrafts[draft.id] else { return canonicalDraft(row.draft) }
        let sealed = try prepareDraft(row)
        var next = metadata
        try commit(records: [], next: &next, draft: (row, sealed))
        metadata = next; localDrafts[draft.id] = row; draftBytes[draft.id] = sealed.count
        return canonicalDraft(row.draft)
    }

    /// The caller supplies the latest revision it actually observed. A newer
    /// durable edit makes this discard fail, rather than silently deleting it.
    /// A successfully discarded composer ID cannot be reused by this writer.
    public func discardDraft(id: UUID, revision: Int64) throws {
        guard revision > 0 else { throw ReaderError.invalidEvent }
        var row: StoredDraft
        if let existing = localDrafts[id] {
            guard existing.draft.revision <= revision else { throw ReaderError.eventConflict }
            if existing.discarded {
                guard existing.draft.revision == revision else { throw ReaderError.eventConflict }
                return
            }
            row = existing
        } else {
            let placeholder = LocalDraft(id: id, revision: revision, textRevision: UUID(), text: "", editedAt: Date(), branchRevision: UUID())
            row = StoredDraft(draft: placeholder, checkpointDigest: try Self.draftDigest(placeholder))
        }
        row.discarded = true; row.draft.revision = revision; row.draft.text = ""
        let sealed = try prepareDraft(row)
        var next = metadata
        try commit(records: [], next: &next, draft: (row, sealed))
        metadata = next; localDrafts[id] = row; draftBytes[id] = sealed.count
    }

    /// One SQLite commit contains the first conversation root (when needed),
    /// user message, outbox changes, and consumption receipt. Newer edits remain
    /// attached to the same composer and are promoted to the saved conversation.
    public func commitDraftSubmission(_ events: [(id: UUID, event: PrivateEvent)], deviceID: UUID,
                                      consuming consumption: DraftConsumption) throws -> DraftSubmissionResult {
        let captured = consumption.draft
        try Self.validateDraft(captured)
        try validateSubmission(events, consumption: consumption)
        let digest = try Self.draftDigest(captured)
        let current = localDrafts[captured.id]
        guard current?.discarded != true else { throw ReaderError.eventConflict }
        if let receipt = current?.receipt {
            if receipt.textRevision == captured.textRevision {
                guard receipt.submissionID == consumption.submissionID, receipt.requestDigest == digest,
                      receipt.eventIDs == events.map(\.id), receipt.deviceID == deviceID else { throw ReaderError.eventConflict }
                let retry = try prepareAppend(events, deviceID: deviceID)
                guard retry.additions.isEmpty, let current else { throw ReaderError.corruptData }
                return DraftSubmissionResult(envelopes: retry.results, draft: canonicalDraft(current.draft), receiptID: receipt.submissionID)
            }
            guard captured.revision > receipt.checkpointRevision else { throw ReaderError.eventConflict }
        }
        var row = try checkpoint(captured, over: current)
        var prepared = try prepareAppend(events, deviceID: deviceID)
        guard let message = prepared.results.last,
              let payload = prepared.state.events[message.id]?.payload,
              let conversation = payload.conversationID else { throw ReaderError.invalidEvent }
        guard !prepared.state.isDeleted(conversation),
              row.draft.conversationID == nil || row.draft.conversationID == conversation else { throw ReaderError.eventConflict }
        row.draft.conversationID = conversation
        if row.draft.textRevision == captured.textRevision { row.draft.text = "" }
        if row.draft.branchRevision == captured.branchRevision { row.draft.selectedHead = message.id }
        row.draft.acknowledgedSubmissionID = consumption.submissionID
        row.receipt = DraftReceipt(submissionID: consumption.submissionID, checkpointRevision: captured.revision,
                                   textRevision: captured.textRevision, branchRevision: captured.branchRevision,
                                   requestDigest: digest, eventIDs: events.map(\.id), deviceID: deviceID)
        let sealed = try prepareDraft(row, state: prepared.state)
        try commit(records: prepared.additions, next: &prepared.metadata, draft: (row, sealed))
        publish(prepared)
        localDrafts[captured.id] = row; draftBytes[captured.id] = sealed.count
        return DraftSubmissionResult(envelopes: prepared.results, draft: canonicalDraft(row.draft), receiptID: consumption.submissionID)
    }

    private struct PreparedAppend {
        let state: PrivateState
        var metadata: LocalMetadata
        let results: [EventEnvelope]
        let additions: [EventEnvelope]
    }

    private func prepareAppend(_ events: [(id: UUID, event: PrivateEvent)], deviceID: UUID) throws -> PreparedAppend {
        guard !events.isEmpty, events.count <= 200, Set(events.map(\.id)).count == events.count else { throw ReaderError.invalidEvent }
        var state = reduced, next = metadata
        var results: [EventEnvelope] = [], additions: [EventEnvelope] = []
        var resolvedIDs = Set<UUID>()
        var pendingBytes = pendingEnvelopes.values.reduce(0) { $0 + $1.ciphertext.count }
        for input in events {
            var event = input.event
            event.parents = event.parents.map { state.resolvedEventID($0) }
            guard event.parents.allSatisfy({ state.events[$0] != nil }) else { throw ReaderError.invalidEvent }
            let resolvedID = state.resolvedEventID(input.id)
            guard resolvedIDs.insert(resolvedID).inserted else { throw ReaderError.invalidEvent }
            if let existing = try lookup(resolvedID) {
                guard (existing.deviceID == deviceID || resolvedID != input.id),
                      try ReaderCrypto.open(existing, keys: keys) == event else { throw ReaderError.eventConflict }
                results.append(existing)
                continue
            }
            guard next.outbox.count < Self.maximumPending else { throw ReaderError.localCapacityExceeded }
            let envelope = try ReaderCrypto.seal(event, id: input.id, deviceID: deviceID, keys: keys)
            pendingBytes += envelope.ciphertext.count
            guard pendingBytes <= Self.maximumPendingBytes else { throw ReaderError.localCapacityExceeded }
            try state.apply(AppliedEvent(id: envelope.id, deviceID: deviceID, payload: event))
            next.outbox.append(envelope.id)
            additions.append(envelope); results.append(envelope)
        }
        return PreparedAppend(state: state, metadata: next, results: results, additions: additions)
    }

    private func publish(_ prepared: PreparedAppend) {
        metadata = prepared.metadata; reduced = prepared.state
        for envelope in prepared.additions { pendingEnvelopes[envelope.id] = envelope }
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

    private func canonicalDraft(_ draft: LocalDraft) -> LocalDraft {
        var result = draft
        result.selectedHead = draft.selectedHead.map { reduced.resolvedEventID($0) }
        return result
    }

    private func checkpoint(_ incoming: LocalDraft, over existing: StoredDraft?) throws -> StoredDraft {
        try Self.validateDraft(incoming)
        let digest = try Self.draftDigest(incoming)
        guard let existing else {
            guard incoming.acknowledgedSubmissionID == nil else { throw ReaderError.invalidEvent }
            try Self.validateDraftContext(incoming, state: reduced)
            return StoredDraft(draft: incoming, checkpointDigest: digest)
        }
        guard !existing.discarded, existing.draft.documentID == incoming.documentID,
              incoming.conversationID == nil || existing.draft.conversationID == nil || incoming.conversationID == existing.draft.conversationID else {
            throw ReaderError.eventConflict
        }
        if incoming.revision < existing.draft.revision { return existing }
        if incoming.revision == existing.draft.revision {
            guard digest == existing.checkpointDigest || canonicalDraft(incoming) == canonicalDraft(existing.draft) else { throw ReaderError.eventConflict }
            return existing
        }
        var next = incoming
        if let conversation = existing.draft.conversationID { next.conversationID = conversation }
        if let receipt = existing.receipt {
            // A text revision identifies a user edit, not its string value.
            // Late branch-only checkpoints of sent text must remain consumed.
            if next.textRevision == receipt.textRevision { next.text = "" }
            // Acknowledgment is equality with this exact receipt, not merely
            // any nonnil UUID. An unknown/older ID has no authority to undo it.
            if next.branchRevision == receipt.branchRevision, incoming.acknowledgedSubmissionID != receipt.submissionID {
                next.selectedHead = existing.draft.selectedHead
            }
            next.acknowledgedSubmissionID = receipt.submissionID
        } else {
            guard incoming.acknowledgedSubmissionID == nil else { throw ReaderError.invalidEvent }
        }
        try Self.validateDraftContext(next, state: reduced)
        return StoredDraft(draft: next, checkpointDigest: digest, receipt: existing.receipt)
    }

    private func validateSubmission(_ events: [(id: UUID, event: PrivateEvent)], consumption: DraftConsumption) throws {
        let draft = consumption.draft
        guard let message = events.last, message.id == consumption.submissionID,
              message.event.kind == .message, message.event.role == .user, message.event.status == .complete,
              message.event.documentID == draft.documentID,
              message.event.text == draft.text.trimmingCharacters(in: .whitespacesAndNewlines),
              message.event.text?.isEmpty == false, let conversation = message.event.conversationID,
              message.event.parents.count == 1 else { throw ReaderError.invalidEvent }
        if let existing = draft.conversationID {
            guard events.count == 1, existing == conversation, !reduced.isDeleted(existing) else { throw ReaderError.invalidEvent }
            let parent = reduced.resolvedEventID(message.event.parents[0])
            guard draft.selectedHead == nil || draft.selectedHead.map({ reduced.resolvedEventID($0) }) == parent else { throw ReaderError.invalidEvent }
            var context = draft; context.selectedHead = parent
            try Self.validateDraftContext(context, state: reduced)
            try validateSubmissionParent(parent, conversation: conversation, documentID: draft.documentID)
        } else {
            guard events.count == 2, let root = events.first, root.event.kind == .conversation,
                  root.event.entityID == conversation, root.event.documentID == draft.documentID,
                  root.event.parents.isEmpty, draft.selectedHead == nil,
                  message.event.parents == [root.id] else { throw ReaderError.invalidEvent }
        }
    }

    private static func validateDraft(_ draft: LocalDraft) throws {
        guard draft.revision > 0, draft.text.utf8.count <= 200_000, draft.editedAt.timeIntervalSince1970.isFinite else { throw ReaderError.invalidEvent }
    }

    private static func validateDraftContext(_ draft: LocalDraft, state: PrivateState) throws {
        guard let conversation = draft.conversationID else {
            guard draft.selectedHead == nil else { throw ReaderError.invalidEvent }
            return
        }
        // Inspect immutable roots instead of visible revisions: a conversation
        // tombstone must not make an otherwise recoverable draft corrupt.
        let roots = state.events.values.filter { $0.payload.kind == .conversation && $0.payload.entityID == conversation }
        guard !roots.isEmpty, roots.allSatisfy({ $0.payload.documentID == draft.documentID }) else { throw ReaderError.invalidEvent }
        guard let head = draft.selectedHead,
              let event = state.events[state.resolvedEventID(head)] else { return }
        // Preserve an unavailable tip while catch-up is incomplete. Only send
        // requires a complete projection; recovery must retain the user's text.
        guard
              event.payload.documentID == draft.documentID,
              (event.payload.kind == .conversation && event.payload.entityID == conversation) ||
              (event.payload.kind == .message && event.payload.conversationID == conversation) else { throw ReaderError.invalidEvent }
    }

    private func validateSubmissionParent(_ parent: UUID, conversation: UUID, documentID: UUID?) throws {
        guard let first = reduced.events[parent] else { throw ReaderError.invalidEvent }
        if first.payload.kind == .message {
            guard reduced.conversationBranch(conversation, through: parent)?.complete == true else { throw ReaderError.invalidEvent }
        }
        // The reducer retains partial remote histories. A local send additionally
        // needs a path rooted in this conversation, including through deleted
        // messages whose text is omitted from the visible projection.
        var pending = [parent], visited = Set<UUID>(), foundRoot = false
        while let id = pending.popLast() {
            guard visited.insert(id).inserted else { continue }
            guard let event = reduced.events[id], event.payload.documentID == documentID else { throw ReaderError.invalidEvent }
            switch event.payload.kind {
            case .conversation:
                guard event.payload.entityID == conversation else { throw ReaderError.invalidEvent }
                foundRoot = true
            case .message:
                guard event.payload.conversationID == conversation, !event.payload.parents.isEmpty else { throw ReaderError.invalidEvent }
                pending.append(contentsOf: event.payload.parents.map { reduced.resolvedEventID($0) })
            default: throw ReaderError.invalidEvent
            }
        }
        guard foundRoot else { throw ReaderError.invalidEvent }
    }

    private static func validateStoredDraft(_ row: StoredDraft, state: PrivateState) throws {
        try validateDraft(row.draft)
        try validateDraftContext(row.draft, state: state)
        guard row.checkpointDigest.count == 32, !row.discarded || row.draft.text.isEmpty else { throw ReaderError.corruptData }
        if let receipt = row.receipt {
            guard receipt.checkpointRevision > 0, receipt.checkpointRevision <= row.draft.revision,
                  receipt.requestDigest.count == 32, (1...2).contains(receipt.eventIDs.count),
                  Set(receipt.eventIDs).count == receipt.eventIDs.count,
                  receipt.eventIDs.last == receipt.submissionID,
                  receipt.eventIDs.allSatisfy({ state.events[state.resolvedEventID($0)] != nil }),
                  let message = state.events[state.resolvedEventID(receipt.submissionID)],
                  message.payload.kind == .message, message.payload.role == .user,
                  message.payload.conversationID == row.draft.conversationID,
                  message.payload.documentID == row.draft.documentID,
                  row.draft.textRevision != receipt.textRevision || row.draft.text.isEmpty,
                  row.draft.acknowledgedSubmissionID == receipt.submissionID else { throw ReaderError.corruptData }
        } else {
            guard row.draft.acknowledgedSubmissionID == nil else { throw ReaderError.corruptData }
        }
    }

    private static func draftDigest(_ draft: LocalDraft) throws -> Data { Data(SHA256.hash(data: try ReaderCrypto.encode(draft))) }

    private func prepareDraft(_ row: StoredDraft, state: PrivateState? = nil) throws -> Data {
        try Self.validateStoredDraft(row, state: state ?? reduced)
        guard localDrafts[row.draft.id] != nil || localDrafts.count < Self.maximumDraftRows else { throw ReaderError.localCapacityExceeded }
        let nonempty = localDrafts.values.filter { $0.draft.id != row.draft.id && !$0.discarded && !$0.draft.text.isEmpty }.count
        guard nonempty + (row.discarded || row.draft.text.isEmpty ? 0 : 1) <= Self.maximumNonemptyDrafts else { throw ReaderError.localCapacityExceeded }
        guard let sealed = try AES.GCM.seal(ReaderCrypto.encode(row), using: localKey,
                                            authenticating: Self.draftAAD(accountID: accountID, id: row.draft.id)).combined else { throw ReaderError.corruptData }
        guard sealed.count <= Self.maximumDraftRowBytes,
              draftBytes.values.reduce(0, +) - (draftBytes[row.draft.id] ?? 0) + sealed.count <= Self.maximumDraftBytes else { throw ReaderError.localCapacityExceeded }
        return sealed
    }

    private static func draftAAD(accountID: UUID, id: UUID) -> Data {
        Data("science-reader/local-draft/v1\n\(accountID.wire)\n\(id.wire)\n".utf8)
    }

    private static func openDraft(_ sealed: Data, id: UUID, accountID: UUID, key: SymmetricKey) throws -> StoredDraft {
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: draftAAD(accountID: accountID, id: id))
        let row = try JSONDecoder().decode(StoredDraft.self, from: plain)
        guard row.draft.id == id else { throw ReaderError.corruptData }
        return row
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

    private func commit(records: [EventEnvelope], next: inout LocalMetadata, replacement: ReplacementMarker? = nil,
                        draft: (row: StoredDraft, sealed: Data)? = nil,
                        library: (journal: LibraryCommandJournal, sealed: [UUID: Data])? = nil,
                        cache: OfflineCacheMutation? = nil) throws {
        guard !needsReopen, metadata.generation < Int64.max else { throw ReaderError.storageUnavailable }
        try database.execute("BEGIN IMMEDIATE")
        do {
            guard try Self.readMetadata(database, key: localKey, accountID: accountID) == metadata else { throw ReaderError.storeChanged }
            for envelope in records {
                try insertRecord(ReaderCrypto.encode(envelope), id: envelope.id, next: &next)
            }
            if let replacement { try insertRecord(ReaderCrypto.encode(replacement), id: UUID(), next: &next) }
            if let draft {
                try database.update("INSERT INTO local_drafts(id,sealed) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET sealed=excluded.sealed",
                                    values: [.text(draft.row.draft.id.wire), .blob(draft.sealed)])
                next.drafts?[draft.row.draft.id.wire] = Data(SHA256.hash(data: draft.sealed))
            }
            if let library {
                for id in libraryJournal.rows.keys where library.journal.rows[id] == nil {
                    try database.update("DELETE FROM local_library_commands WHERE id=?", values: [.text(id.wire)])
                    next.libraryCommands?.removeValue(forKey: id.wire)
                }
                for (id, sealed) in library.sealed {
                    try database.update("INSERT INTO local_library_commands(id,sealed) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET sealed=excluded.sealed",
                                        values: [.text(id.wire), .blob(sealed)])
                    next.libraryCommands?[id.wire] = Data(SHA256.hash(data: sealed))
                }
                next.libraryCommandScope = library.journal.scope
                next.libraryCommandSequence = library.journal.sequence
            }
            if let cache {
                guard let scope = cache.roots.scope else { throw OfflineCacheError.invalidBinding }
                try OfflineCacheStorage(database: database, key: localKey, scope: scope).apply(cache)
                next.offlineCache = cache.roots
            }
            next.format = 6
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

    private static func libraryCommandAAD(id: UUID, scope: LibraryCommandScope) -> Data {
        Data("science-reader/local-library-command/v1\n\(scope.accountID.wire)\n\(scope.deploymentID)\n\(id.wire)\n".utf8)
    }

    private static func sealLibraryCommand(_ row: LocalLibraryCommand, key: SymmetricKey) throws -> Data {
        guard let sealed = try AES.GCM.seal(ReaderCrypto.encode(row), using: key,
                                           authenticating: libraryCommandAAD(id: row.id, scope: row.scope)).combined,
              sealed.count <= LibraryCommandJournal.maximumRowBytes else { throw LibraryCommandError.capacityExceeded }
        return sealed
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
