import CSQLite
import CryptoKit
import Foundation
import Testing
@testable import ScienceReaderCore

private final class ProjectionVisits: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func visit() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}

private enum ProjectionFixtureFailure: Error, Equatable { case projector }

@Suite(.serialized) struct OfflineCacheTests {
    private struct Fixture {
        let directory: URL
        let url: URL
        let account = UUID()
        let key = ReaderCrypto.randomKey()
        let keys: KeyBundle
        let scope: LibraryCommandScope
        let store: EncryptedStore
        init(directory: URL) throws {
            self.directory = directory; url = directory.appendingPathComponent("state.sqlite")
            keys = .generate(accountID: account)
            scope = try .init(accountID: account, deploymentID: "https://offline-fixture.invalid")
            store = try .init(url: url, accountID: account, localKey: key, keys: keys)
        }
        func reopen() throws -> EncryptedStore { try .init(url: url, accountID: account, localKey: key, keys: keys) }
        func binding(_ bundle: VerifiedReaderBundle, document: UUID = UUID(), artifact: UUID = UUID()) throws -> ReaderArtifactBinding {
            try .init(scope: scope, documentID: document, artifactID: artifact, manifestSHA256: bundle.manifestSHA256)
        }
    }
    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        defer { try? FileManager.default.removeItem(at: directory) }
        // All actors/SQLite handles created by the body leave their scope before
        // the outer cleanup, avoiding unlinked live SQLite databases.
        func run() async throws { let fixture = try Fixture(directory: directory); try await body(fixture) }
        try await run()
    }
    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private func bundle(memberCount: Int = 4, payloadBytes: Int? = nil) throws -> VerifiedReaderBundle {
        let index: [String: Any] = ["format": "reader-index-v1", "title": "Offline sample", "headings": [],
            "blocks": [["id": "b-one", "kind": "paragraph", "text": "PRIVATE-CACHED-READER-TEXT"]], "equations": [], "figures": []]
        var files = ["index.html": Data("<p>PRIVATE-CACHED-READER-TEXT</p>".utf8), "reader.css": Data("body{color:black}".utf8),
                     "provenance.json": Data("{}".utf8), "reader.json": try json(index)]
        for number in 4..<memberCount { files["notice-\(number).txt"] = Data([0x61]) }
        if let payloadBytes {
            var left = payloadBytes - files.values.reduce(0) { $0 + $1.count }, number = 0
            while left > 0 { let count = min(left, 16_777_216); files["padding-\(number).txt"] = Data(repeating: 0x62, count: count); left -= count; number += 1 }
        }
        let roles = ["index.html": "html", "reader.css": "style", "provenance.json": "provenance", "reader.json": "index"]
        let mime = ["html": "text/html", "style": "text/css", "provenance": "application/json", "index": "application/json"]
        let manifest: [String: Any] = ["format": "reader-bundle-v1",
            "renderer": ["id": "timestep-mmd-v1", "build_sha256": String(repeating: "a", count: 64)],
            "source": ["kind": "authored-mmd", "sha256": String(repeating: "b", count: 64), "provenance_path": "provenance.json"],
            "entrypoint": "index.html", "index_path": "reader.json", "members": files.keys.sorted().map { path -> [String: Any] in
                let role = roles[path] ?? "notice", bytes = files[path]!
                return ["path": path, "role": role, "media_type": mime[role] ?? "text/plain", "bytes": bytes.count, "sha256": VerifiedReaderBundle.digest(bytes)]
            }]
        let raw = Data(" \n".utf8) + (try json(manifest)) + Data("\n ".utf8)
        return try .verify(manifest: raw, expectedSHA256: VerifiedReaderBundle.digest(raw), members: files)
    }
    private func item(binding: ReaderArtifactBinding, id: UUID = UUID(), created: Int64 = 1) -> [String: Any] {
        ["kind": "item", "id": id.wire, "document_id": binding.documentID.wire,
         "created_seq": created, "state_seq": created, "membership_revision": 1, "visible": true,
         "added_at": "2026-10-03T12:00:00.123456Z", "last_remove_seq": 0,
         "approval_id": UUID().wire, "version_id": UUID().wire, "metadata_id": UUID().wire,
         "source": "arxiv", "source_id": "1706.03762", "source_revision": 7,
         "metadata": ["title": "PRIVATE-CACHED-LIBRARY-TITLE", "authors": ["Author"], "categories": ["cs.CL"]],
         "metadata_recorded_at": "2026-10-03T12:01:00.654321Z", "source_url": "https://arxiv.org/abs/1706.03762v7",
         "scope": "shared_catalog", "page_count": 1, "original_object_id": UUID().wire, "artifact_id": binding.artifactID.wire,
         "readiness": "converted_ready", "original_availability": "available", "render_availability": "available",
         "original_availability_revision": 1, "render_availability_revision": 1]
    }
    private func observation(_ account: UUID, rows: [[String: Any]], cursor: Int64,
                             context: LibraryReadContext = .legacyFull3) throws -> LibraryCompleteObservation {
        var reconciler = LibraryReconciler(accountID: account, readContext: context)
        let sorted = rows.sorted {
            let left = ($0["created_seq"] as! Int64, $0["id"] as! String, $0["kind"] as! String)
            let right = ($1["created_seq"] as! Int64, $1["id"] as! String, $1["kind"] as! String)
            return left < right
        }
        let chunks = sorted.isEmpty ? [[]] : stride(from: 0, to: sorted.count, by: 20).map { Array(sorted[$0..<min($0 + 20, sorted.count)]) }
        for (position, chunk) in chunks.enumerated() {
            let more = position + 1 < chunks.count
            let next: Any
            if let last = chunk.last {
                var value: [String: Any] = ["format": 2, "account_id": account.wire, "through": cursor,
                        "created_seq": last["created_seq"]!, "id": last["id"]!, "kind": last["kind"]!]
                if let epoch = context.datasetEpoch { value["read_level"] = 4; value["dataset_epoch"] = epoch.wire }
                next = value
            } else { next = NSNull() }
            var value: [String: Any] = ["format": 2, "account_id": account.wire, "baseline_cursor": cursor,
                "retained_after": 0, "entries": chunk, "next_cursor": next, "has_more": more]
            if let epoch = context.datasetEpoch { value["dataset_epoch"] = epoch.wire }
            let page = try LibraryWire.decodeBaseline(json(value))
            try reconciler.accept(page, for: reconciler.nextRequest())
        }
        var delta: [String: Any] = ["format": 2, "account_id": account.wire, "through": cursor,
            "retained_after": 0, "changes": [], "next_cursor": cursor, "has_more": false]
        if let epoch = context.datasetEpoch { delta["dataset_epoch"] = epoch.wire }
        let changes = try LibraryWire.decodeChanges(json(delta))
        try reconciler.accept(changes, for: reconciler.nextRequest())
        return try reconciler.completeObservation()
    }
    private func install(_ bundle: VerifiedReaderBundle, binding: ReaderArtifactBinding, store: EncryptedStore) async throws -> InstalledReaderBundle {
        let ticket = try await store.beginReaderInstall(binding: binding)
        return try await store.commitReaderInstall(ticket, bundle: bundle)
    }
    private func count(_ db: SQLiteConnection, _ table: String) throws -> Int {
        try db.statement("SELECT count(*) FROM \(table)") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw ReaderError.corruptData }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }
    private func raw(_ db: SQLiteConnection, _ table: String) throws -> Data {
        try db.statement("SELECT sealed FROM \(table) WHERE id=1") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw ReaderError.corruptData }
            return try SQLiteConnection.blob(statement, 0)
        }
    }

    private func imported(id: UUID = UUID(), created: Int64, target: (UUID, UUID)? = nil) -> [String: Any] {
        ["kind": "import", "id": id.wire, "created_seq": created, "state_seq": created,
         "intent_revision": 1, "visible": target == nil, "phase": target == nil ? "accepted" : "ready",
         "source": "arxiv", "source_id": "2404.00001", "source_url": "https://arxiv.org/abs/2404.00001",
         "document_id": target.map { $0.1.wire as Any } ?? NSNull(),
         "library_item_id": target.map { $0.0.wire as Any } ?? NSNull(), "retryable": false]
    }

    private func checkpoint(_ f: Fixture, _ db: SQLiteConnection) throws -> CachePresentationCheckpoint {
        let sealed = try raw(db, "local_library_cache_checkpoint")
        return try OfflineCacheCodec.decode(CachePresentationCheckpoint.self, from:
            OfflineCacheCodec.open(sealed, digest: OfflineCacheCodec.digest(sealed), domain: "presentation",
                scope: f.scope, key: SymmetricKey(data: f.key), maximum: OfflineCacheLimits.presentationCheckpointBytes))
    }

    /// Deliberately authenticate a semantically malformed child and checkpoint.
    /// Reopening exercises normal root authentication rather than a test-only
    /// store entry point; the read must still reject invalid cross-row facts.
    private func rewriteCache(_ f: Fixture, edit: (inout [String: CacheLibraryRow]) throws -> Void) throws {
        let db = try SQLiteConnection(url: f.url), key = SymmetricKey(data: f.key)
        let before = try checkpoint(f, db)
        var rows: [String: CacheLibraryRow] = [:]
        for (name, ref) in before.rows {
            let sealed = try db.statement("SELECT sealed FROM local_library_cache_entries WHERE id=?", values: [.text(ref.rowID.wire)]) {
                guard sqlite3_step($0) == SQLITE_ROW else { throw ReaderError.corruptData }
                return try SQLiteConnection.blob($0, 0)
            }
            rows[name] = try OfflineCacheCodec.decode(CacheLibraryRow.self, from:
                OfflineCacheCodec.open(sealed, digest: ref.digest, domain: "presentation-row", scope: f.scope,
                    identity: [ref.rowID.wire], key: key, maximum: OfflineCacheLimits.presentationRowBytes))
        }
        try edit(&rows)
        var refs: [String: CacheEntryReference] = [:], children: [(UUID, Data)] = []
        for (name, row) in rows {
            let sealed = try OfflineCacheCodec.seal(OfflineCacheCodec.encode(row), domain: "presentation-row",
                scope: f.scope, identity: [row.rowID.wire], key: key, maximum: OfflineCacheLimits.presentationRowBytes)
            refs[name] = .init(rowID: row.rowID, digest: OfflineCacheCodec.digest(sealed), bytes: sealed.count,
                               documentID: OfflineCacheCodec.documentID(row.entry))
            children.append((row.rowID, sealed))
        }
        let checkpoint = CachePresentationCheckpoint(format: before.format, scope: before.scope,
            cursor: before.cursor, capturedAt: before.capturedAt, rows: refs,
            readContext: before.readContext, retainedBlocks: before.retainedBlocks)
        let sealed = try OfflineCacheCodec.seal(OfflineCacheCodec.encode(checkpoint), domain: "presentation",
            scope: f.scope, key: key, maximum: OfflineCacheLimits.presentationCheckpointBytes)
        let aad = Data("science-reader/local-metadata/v2/\(f.account.wire)".utf8)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: raw(db, "metadata")), using: key, authenticating: aad)
        var metadata = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        var roots = try #require(metadata["offlineCache"] as? [String: Any])
        roots["presentation"] = OfflineCacheCodec.digest(sealed).base64EncodedString()
        metadata["offlineCache"] = roots
        let sealedMetadata = try #require(AES.GCM.seal(json(metadata), using: key, authenticating: aad).combined)
        try db.execute("BEGIN IMMEDIATE")
        do {
            for (id, bytes) in children {
                try db.update("UPDATE local_library_cache_entries SET sealed=? WHERE id=?", values: [.blob(bytes), .text(id.wire)])
            }
            try db.update("UPDATE local_library_cache_checkpoint SET sealed=? WHERE id=1", values: [.blob(sealed)])
            try db.update("UPDATE metadata SET sealed=? WHERE id=1", values: [.blob(sealedMetadata)])
            try db.execute("COMMIT")
        } catch { try? db.execute("ROLLBACK"); throw error }
    }

    private func replacing(_ row: CacheLibraryRow, fields: [String: Any]) throws -> CacheLibraryRow {
        var value = try #require(JSONSerialization.jsonObject(with: OfflineCacheCodec.encode(row.entry)) as? [String: Any])
        for (name, field) in fields { value[name] = field }
        return .init(format: row.format, rowID: row.rowID,
            entry: try OfflineCacheCodec.decode(LibraryEntry.self, from: json(value)), readerPolicy: nil)
    }

    @Test func maximumCheckpointMeasurement() throws {
        let scope = try LibraryCommandScope(accountID: UUID(), deploymentID: "https://offline-fixture.invalid")
        var refs: [String: CacheEntryReference] = [:], blocks: [String: CacheRetainedReaderBlock] = [:]
        for index in 0..<4_000 {
            refs["item:\(UUID().wire)"] = .init(rowID: UUID(), digest: Data(repeating: 255, count: 32),
                bytes: OfflineCacheLimits.presentationRowBytes, documentID: UUID())
            let artifact = UUID(), document = UUID()
            let policy = try ReaderBundleEligibility().applying(cursor: Int64(index), item: nil,
                documentID: document, artifactID: artifact)
            blocks[artifact.wire] = .init(documentID: document, eligibility: policy)
        }
        let value = CachePresentationCheckpoint(format: 4, scope: scope, cursor: Int64.max,
            capturedAt: Date(), rows: refs, readContext: .uploadFull5(datasetEpoch: UUID()), retainedBlocks: blocks)
        let bytes = try OfflineCacheCodec.encode(value).count + 28
        print("Maximum native checkpoint (4000 refs + 4000 retained bindings): \(bytes) sealed bytes")
        #expect(bytes <= OfflineCacheLimits.presentationCheckpointBytes)
    }

    @Test func resumedCheckpointRequiresFreshCatchupAndKeepsEpochWhenChildCorrupts() async throws {
        try await withFixture { f in
            let context = LibraryReadContext.uploadFull5(datasetEpoch: UUID())
            let value = try observation(f.account, rows: [item(binding: f.binding(bundle()))], cursor: 8, context: context)
            try await f.store.saveLibraryPresentation(value, scope: f.scope)
            let restarted = try f.reopen()
            #expect(try await restarted.rememberedLibraryReadContext(scope: f.scope) == context)
            let seed = try #require(await restarted.cachedLibraryReplicaSeed(scope: f.scope))
            var replica = try LibraryReconciler(resuming: seed, scope: f.scope)
            #expect(replica.phase == .catchingUp)
            #expect(throws: LibraryCommandError.incompleteObservation) { try replica.completeObservation() }
            let request = try replica.nextRequest()
            #expect(request.query == .changes(after: 8, through: nil) && request.readContext == context)
            let delta = try LibraryWire.decodeChanges(json(["format": 2, "account_id": f.account.wire,
                "dataset_epoch": context.datasetEpoch!.wire, "through": 8, "retained_after": 0,
                "changes": [], "next_cursor": 8, "has_more": false]))
            try replica.accept(delta, for: request)
            #expect(try replica.completeObservation().entries == value.entries)
            let wrong = try LibraryCommandScope(accountID: f.account, deploymentID: "https://another.invalid")
            #expect(throws: LibraryProtocolError.invalidCursor) { try LibraryReconciler(resuming: seed, scope: wrong) }
            let db = try SQLiteConnection(url: f.url)
            try db.execute("UPDATE local_library_cache_checkpoint SET sealed=zeroblob(length(sealed))")
            let damaged = try f.reopen()
            #expect(try await damaged.rememberedLibraryReadContext(scope: f.scope) == context)
            await #expect(throws: OfflineCacheError.corruptCache) { try await damaged.cachedLibraryReplicaSeed(scope: f.scope) }
            #expect(await damaged.pending().isEmpty)
        }
    }

    @Test func restoredLowerCursorReplacesRowsButRetainsRemovedOrUnsafePolicyAfterDiscard() async throws {
        for removed in [false, true] {
            try await withFixture { f in
                let bundle = try bundle(), binding = try f.binding(bundle)
                let oldContext = LibraryReadContext.uploadFull5(datasetEpoch: UUID())
                let newContext = LibraryReadContext.uploadFull5(datasetEpoch: UUID())
                var row = item(binding: binding), readable = row
                try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 50, context: oldContext), scope: f.scope)
                let installed = try await install(bundle, binding: binding, store: f.store)
                row["state_seq"] = Int64(51)
                if removed { row["visible"] = false; row["last_remove_seq"] = Int64(51); row["membership_revision"] = 2 }
                else { row["render_availability"] = "quarantined"; row["render_availability_revision"] = 2 }
                try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 51, context: oldContext), scope: f.scope)
                let blocked = try await f.store.listInstalledReaderBundles(scope: f.scope).installations[0]
                #expect(!blocked.canOpen)
                try await f.store.removeReaderBundle(id: installed.id, expectedRevision: blocked.revision, scope: f.scope)
                // The restored database has no row at all. The independent map must survive that absence.
                let empty = try await f.store.saveLibraryPresentation(observation(f.account, rows: [], cursor: 0, context: newContext), scope: f.scope)
                #expect(empty.entries.isEmpty && empty.committedCursor == 0 && empty.readContext == newContext)
                let restarted = try f.reopen()
                await #expect(throws: OfflineCacheError.blocked) { try await restarted.beginReaderInstall(binding: binding) }
                readable["state_seq"] = Int64(1)
                try await restarted.saveLibraryPresentation(observation(f.account, rows: [readable], cursor: 1, context: newContext), scope: f.scope)
                let again = try f.reopen()
                await #expect(throws: OfflineCacheError.blocked) { try await again.beginReaderInstall(binding: binding) }
                #expect(try await again.listInstalledReaderBundles(scope: f.scope).installations.isEmpty)
            }
        }
    }

    @Test func restoredReadableBundleCanContinueButSameContextCannotRewind() async throws {
        try await withFixture { f in
            let bundle = try bundle(), binding = try f.binding(bundle), row = item(binding: binding)
            let oldContext = LibraryReadContext.uploadFull5(datasetEpoch: UUID()), newContext = LibraryReadContext.uploadFull5(datasetEpoch: UUID())
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 50, context: oldContext), scope: f.scope)
            let installed = try await install(bundle, binding: binding, store: f.store)
            await #expect(throws: OfflineCacheError.staleObservation) {
                try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 1, context: oldContext), scope: f.scope)
            }
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 1, context: newContext), scope: f.scope)
            let reopened = try f.reopen()
            #expect(try await reopened.listInstalledReaderBundles(scope: f.scope).installations[0].canOpen)
            #expect(try await reopened.readReaderBundle(id: installed.id, scope: f.scope).manifestData == bundle.manifestData)
            #expect(try await reopened.cachedLibraryReplicaSeed(scope: f.scope)?.committedCursor == 1)
        }
    }

    @Test func legacyCheckpointNeverSeedsAnEpochlessReplica() async throws {
        try await withFixture { f in
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [], cursor: 20), scope: f.scope, format: 3)
            #expect(try await f.reopen().cachedLibraryReplicaSeed(scope: f.scope) == nil)
        }
    }

    @Test func buildEighteenCacheRebasesRetryPresentationWithoutRevisionConflict() async throws {
        try await withFixture { f in
            let context = LibraryReadContext.uploadFull5(datasetEpoch: UUID())
            let library = try build15Library()
            var row = try #require(library.entries.first { $0["kind"] as? String == "import" && $0["phase"] as? String == "failed" })
            row["auto_retry_at"] = nil
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: library.cursor, context: context),
                                                     scope: f.scope, format: 4)
            let reopened = try f.reopen()
            #expect(try await reopened.cachedLibraryPresentation(scope: f.scope)?.entries.count == 1, "Offline display stays available")
            #expect(try await reopened.cachedLibraryReplicaSeed(scope: f.scope) == nil, "Older decoded fields require a fresh baseline")
            row["auto_retry_at"] = "2026-10-08T01:00:00Z"
            let current = try observation(f.account, rows: [row], cursor: library.cursor, context: context)
            try await reopened.saveLibraryPresentation(current, scope: f.scope)
            let again = try f.reopen()
            #expect(try await again.cachedLibraryReplicaSeed(scope: f.scope)?.entries == current.entries)
            // Once both copies include the field, equal-revision divergence remains a protocol violation.
            row["auto_retry_at"] = "2026-10-08T02:00:00Z"
            await #expect(throws: OfflineCacheError.conflictingObservation) {
                try await again.saveLibraryPresentation(observation(f.account, rows: [row], cursor: library.cursor, context: context), scope: f.scope)
            }
        }
    }

    @Test func retainedBlockCapacityPausesCheckpointAtomicallyWithoutEviction() async throws {
        try await withFixture { f in
            let bundle = try bundle(), oldContext = LibraryReadContext.uploadFull5(datasetEpoch: UUID())
            let newContext = LibraryReadContext.uploadFull5(datasetEpoch: UUID())
            var rows: [[String: Any]] = [], first: ReaderArtifactBinding?
            for index in 0..<OfflineCacheLimits.retainedReaderBlocks {
                let binding = try f.binding(bundle)
                if index == 0 { first = binding }
                var row = item(binding: binding, created: Int64(index + 1))
                row["visible"] = false; row["last_remove_seq"] = Int64(index + 1)
                rows.append(row)
            }
            try await f.store.saveLibraryPresentation(observation(f.account, rows: rows, cursor: 4_000, context: oldContext), scope: f.scope)
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [], cursor: 0, context: newContext), scope: f.scope)
            let extra = try f.binding(bundle)
            var row = item(binding: extra); row["visible"] = false; row["last_remove_seq"] = Int64(1)
            let saved = try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 1, context: newContext), scope: f.scope)
            let before = await f.store.snapshot()
            await #expect(throws: OfflineCacheError.capacityExceeded) {
                try await f.store.saveLibraryPresentation(observation(f.account, rows: [], cursor: 0,
                    context: .uploadFull5(datasetEpoch: UUID())), scope: f.scope)
            }
            #expect(await f.store.snapshot() == before)
            let reopened = try f.reopen()
            #expect(try await reopened.cachedLibraryPresentation(scope: f.scope) == saved)
            #expect(try await reopened.rememberedLibraryReadContext(scope: f.scope) == newContext)
            await #expect(throws: OfflineCacheError.blocked) { try await reopened.beginReaderInstall(binding: first!) }
            await #expect(throws: OfflineCacheError.blocked) { try await reopened.beginReaderInstall(binding: extra) }
        }
    }

    @Test func checkpointAndOldDomainCommandReviewCommitTogetherAndKeepExactEvidence() async throws {
        try await withFixture { f in
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [], cursor: 0), scope: f.scope)
            let handle = try await f.store.enqueueLibraryCommand(scope: f.scope,
                mutation: .beginImport(sourceID: "2404.00001", requestedRevision: nil, observedCursor: 0))
            let attempt = try await f.store.beginLibraryAttempt(handle, scope: f.scope)
            let ack = try LibraryWire.decodeCommand(json(["result": ["status": "applied", "kind": "import",
                "id": handle.intentID.wire, "seq": 1, "revision": 1], "replayed": false,
                "entry": imported(id: handle.intentID, created: 1)]))
            try await f.store.recordLibraryReceipt(ack, for: attempt)
            _ = try await f.store.holdLibrarySuccessor(.cancelImport, after: handle, scope: f.scope)
            _ = try await f.store.enqueueLibraryCommand(scope: f.scope,
                mutation: .beginImport(sourceID: "1706.03762", requestedRevision: nil, observedCursor: 0))
            let before = try await f.store.libraryCommandSnapshot(scope: f.scope)
            let context = LibraryReadContext.uploadFull5(datasetEpoch: UUID())
            let restored = try observation(f.account, rows: [], cursor: 0, context: context)
            let db = try SQLiteConnection(url: f.url)
            try db.execute("CREATE TRIGGER reject_epoch_commit BEFORE UPDATE ON metadata BEGIN SELECT RAISE(ABORT,'fixture'); END")
            await #expect(throws: (any Error).self) { try await f.store.saveLibraryPresentation(restored, scope: f.scope) }
            #expect(try await f.store.libraryCommandSnapshot(scope: f.scope) == before)
            #expect(try await f.store.rememberedLibraryReadContext(scope: f.scope) == .legacyFull3)
            try db.execute("DROP TRIGGER reject_epoch_commit")
            try await f.store.saveLibraryPresentation(restored, scope: f.scope)
            await #expect(throws: LibraryCommandError.staleAttempt) { try await f.store.recordLibraryReceipt(ack, for: attempt) }
            let reopened = try f.reopen(), reviewed = try await reopened.libraryCommandSnapshot(scope: f.scope)
            #expect(reviewed.commands.count == 3)
            #expect(reviewed.commands.allSatisfy { $0.phase == .needsReview && $0.failure == .datasetChanged && !$0.canAttempt })
            for command in reviewed.commands {
                let prior = try #require(before.commands.first { $0.id == command.id })
                #expect(command.request == prior.request && command.receipt == prior.receipt && command.readContext == prior.readContext)
            }
            let received = try #require(reviewed.commands.first { $0.handle == handle })
            try await reopened.reconcileLibraryCommands([.init(handle: handle, receiptID: received.receipt!.id)],
                observation: restored, scope: f.scope)
            #expect(try await reopened.libraryCommandSnapshot(scope: f.scope).commands.first { $0.handle == handle }?.phase == .needsReview)
            await #expect(throws: LibraryCommandError.contextMismatch) {
                try await reopened.beginLibraryAttempt(handle, scope: f.scope, readContext: context)
            }
        }
    }

    @Test func projectedCheckpointPreservesContentsOrderScopeAndPrivateState() async throws {
        try await withFixture { f in
            let bundle = try bundle(), first = try f.binding(bundle), second = try f.binding(bundle)
            let sharedID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
            var row = item(binding: first, id: sharedID)
            row["metadata"] = ["title": "Équations 東京", "authors": ["Zoë", "李"],
                "abstract": "Full searchable \n metadata", "categories": ["cs.LG", "数学"],
                "published_at": "2024-04-03", "updated_at": "2024-05-01", "venue": "Fixture"]
            let observed = try observation(f.account, rows: [item(binding: second, created: 2),
                row, imported(id: sharedID, created: 1, target: (sharedID, first.documentID))], cursor: 2)
            let cached = try await f.store.saveLibraryPresentation(observed, scope: f.scope)
            let note = try await f.store.append(.init(kind: .note, text: "Keep private state"), deviceID: UUID())
            let before = await f.store.snapshot(), pending = await f.store.pending()
            let db = try SQLiteConnection(url: f.url), metadata = try raw(db, "metadata")
            let projected = try #require(await f.store.cachedLibraryProjection(scope: f.scope, project: { $0 }))
            #expect(projected.scope == f.scope && projected.committedCursor == cached.committedCursor)
            #expect(projected.capturedAt == cached.capturedAt && projected.validatedEntryCount == 3)
            #expect(Dictionary(uniqueKeysWithValues: projected.rows.map { ($0.id, $0) }) == cached.entries)
            #expect(projected.rows == cached.entries.values.sorted { LibraryOrderingKey($0) < LibraryOrderingKey($1) })
            #expect(projected.rows.prefix(2).map(\.id.kind) == [.import, .item])
            let filtered = try #require(await f.store.cachedLibraryProjection(scope: f.scope) { entry -> UUID? in
                guard case .item(let item) = entry else { return nil }; return item.documentID
            })
            #expect(filtered.validatedEntryCount == 3 && filtered.rows == [first.documentID, second.documentID])
            let after = await f.store.snapshot(), remaining = await f.store.pending()
            #expect(after == before && remaining == pending && pending == [note])
            #expect(try raw(db, "metadata") == metadata)
            let foreign = try LibraryCommandScope(accountID: UUID(), deploymentID: f.scope.deploymentID)
            await #expect(throws: ReaderError.wrongAccount) { try await f.store.cachedLibraryProjection(scope: foreign) { $0.id } }
            let wrongDeployment = try LibraryCommandScope(accountID: f.account, deploymentID: "https://another.invalid")
            await #expect(throws: LibraryCommandError.invalidScope) { try await f.store.cachedLibraryProjection(scope: wrongDeployment) { $0.id } }
        }
    }

    @Test(arguments: ["duplicate_document", "missing_import_target", "wrong_import_document"])
    func authenticatedInvalidCrossRowFactsRejectBothReaders(_ kind: String) async throws {
        try await withFixture { f in
            let bundle = try bundle(), first = try f.binding(bundle), second = try f.binding(bundle)
            let firstID = UUID(), secondID = UUID(), importID = UUID()
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [item(binding: first, id: firstID),
                item(binding: second, id: secondID, created: 2),
                imported(id: importID, created: 3, target: (firstID, first.documentID))], cursor: 3), scope: f.scope)
            try rewriteCache(f) { rows in
                let target = kind == "duplicate_document" ? LibraryEntryID(kind: .item, entityID: secondID)
                    : LibraryEntryID(kind: .import, entityID: importID)
                let name = OfflineCacheCodec.entryKey(target), row = try #require(rows[name])
                let fields: [String: Any]
                switch kind {
                case "duplicate_document": fields = ["document_id": first.documentID.wire]
                case "missing_import_target": fields = ["library_item_id": UUID().wire]
                default: fields = ["document_id": UUID().wire]
                }
                rows[name] = try replacing(row, fields: fields)
            }
            let store = try f.reopen(), before = await store.snapshot(), visits = ProjectionVisits()
            await #expect(throws: OfflineCacheError.invalidObservation) {
                try await store.cachedLibraryProjection(scope: f.scope) { entry in _ = visits.visit(); return entry.id }
            }
            if kind != "duplicate_document" { #expect(visits.count == 3, "Cross-row links are checked before any complete result escapes") }
            await #expect(throws: OfflineCacheError.invalidObservation) { try await store.cachedLibraryPresentation(scope: f.scope) }
            #expect(await store.snapshot() == before)
            _ = try await store.append(.init(kind: .note, text: "Cache failure preserves private writes"), deviceID: UUID())
        }
    }

    @Test(arguments: ["last_row", "missing_child", "extra_child"])
    func projectedReadRejectsCorruptOrInexactChildrenWithoutAPartialResult(_ kind: String) async throws {
        try await withFixture { f in
            let bundle = try bundle()
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [item(binding: f.binding(bundle)),
                item(binding: f.binding(bundle), created: 2)], cursor: 2), scope: f.scope)
            let db = try SQLiteConnection(url: f.url), checkpoint = try checkpoint(f, db)
            let name = try #require(checkpoint.rows.keys.sorted().last), ref = try #require(checkpoint.rows[name])
            switch kind {
            case "last_row":
                try db.update("UPDATE local_library_cache_entries SET sealed=zeroblob(?) WHERE id=?", values: [.integer(Int64(ref.bytes)), .text(ref.rowID.wire)])
            case "missing_child": try db.update("DELETE FROM local_library_cache_entries WHERE id=?", values: [.text(ref.rowID.wire)])
            default: try db.update("INSERT INTO local_library_cache_entries(id,sealed) VALUES(?,zeroblob(28))", values: [.text(UUID().wire)])
            }
            let visits = ProjectionVisits()
            await #expect(throws: OfflineCacheError.corruptCache) {
                try await f.store.cachedLibraryProjection(scope: f.scope) { _ in _ = visits.visit(); return Int?.none }
            }
            #expect(visits.count == (kind == "last_row" ? 1 : 0), "Even a projector that discards every row must validate all children")
            await #expect(throws: OfflineCacheError.corruptCache) { try await f.store.cachedLibraryPresentation(scope: f.scope) }
        }
    }

    @Test(arguments: [0, 1, 3])
    func projectedReadChecksCancellationBeforeBetweenAndAfterRows(_ cancelAt: Int) async throws {
        try await withFixture { f in
            let bundle = try bundle()
            let rows = try (1...3).map { try item(binding: f.binding(bundle), created: Int64($0)) }
            try await f.store.saveLibraryPresentation(observation(f.account, rows: rows, cursor: 3), scope: f.scope)
            let store = f.store, scope = f.scope, before = await store.snapshot(), visits = ProjectionVisits()
            let work = Task.detached {
                if cancelAt == 0 { withUnsafeCurrentTask { $0?.cancel() } }
                return try await store.cachedLibraryProjection(scope: scope) { entry -> LibraryEntryID? in
                    if visits.visit() == cancelAt { withUnsafeCurrentTask { $0?.cancel() } }
                    // Returning nil also tests final cancellation with no sort
                    // comparator invocation to accidentally supply the check.
                    return nil
                }
            }
            await #expect(throws: CancellationError.self) { try await work.value }
            let after = await store.snapshot()
            #expect(visits.count == cancelAt && after == before)
            #expect(try await store.cachedLibraryPresentation(scope: scope)?.entries.count == 3)
        }
    }

    @Test func projectorFailureDoesNotMutateAndCancelledAcceptedWritesStillDrain() async throws {
        try await withFixture { f in
            let bundle = try bundle(), binding = try f.binding(bundle)
            var row = item(binding: binding)
            let first = try observation(f.account, rows: [row], cursor: 1)
            try await f.store.saveLibraryPresentation(first, scope: f.scope)
            let store = f.store, scope = f.scope, before = await store.snapshot()
            await #expect(throws: ProjectionFixtureFailure.projector) {
                try await store.cachedLibraryProjection(scope: scope) { _ -> Int? in throw ProjectionFixtureFailure.projector }
            }
            #expect(await store.snapshot() == before)
            row["state_seq"] = Int64(2); row["render_availability"] = "quarantined"; row["render_availability_revision"] = 2
            let changed = try observation(f.account, rows: [row], cursor: 2)
            let work = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                let old = try await store.cachedLibraryPresentation(scope: scope)
                let saved = try await store.saveLibraryPresentation(changed, scope: scope)
                return (old?.committedCursor, saved.committedCursor)
            }
            let result = try await work.value
            #expect(result.0 == 1 && result.1 == 2)
            #expect(try await store.cachedLibraryPresentation(scope: scope)?.entries == changed.entries)
        }
    }

    @Test func exactManifestAndCompletePresentationSurviveEncryptedRestart() async throws {
        try await withFixture { f in
            let bundle = try bundle(), binding = try f.binding(bundle)
            let observed = try observation(f.account, rows: [item(binding: binding)], cursor: 1)
            let cached = try await f.store.saveLibraryPresentation(observed, scope: f.scope)
            let draft = LocalDraft(id: UUID(), revision: 1, textRevision: UUID(), text: "PRIVATE-DRAFT", editedAt: Date(), branchRevision: UUID())
            try await f.store.saveDraft(draft)
            let event = try await f.store.append(.init(kind: .note, text: "PRIVATE-HISTORY"), deviceID: UUID())
            let installed = try await install(bundle, binding: binding, store: f.store)
            let token = try await f.store.readReaderBundle(id: installed.id, scope: f.scope).openToken
            try await f.store.append(.init(kind: .note, text: "Unrelated later note"), deviceID: UUID())
            #expect(try await f.store.validateReaderOpen(token) == installed)
            let restarted = try f.reopen()
            #expect(try await restarted.cachedLibraryPresentation(scope: f.scope) == cached)
            #expect(await restarted.cursor() == 0)
            #expect(await restarted.pending().contains(event))
            #expect(await restarted.snapshot().drafts == [draft])
            let payload = try await restarted.readReaderBundle(id: installed.id, scope: f.scope)
            #expect(payload.manifestData == bundle.manifestData)
            let verified = try VerifiedReaderBundle.verify(manifest: payload.manifestData, expectedSHA256: binding.manifestSHA256, members: payload.members)
            #expect(verified.data(for: "index.html") == bundle.data(for: "index.html"))
            #expect(try await restarted.validateReaderOpen(payload.openToken) == installed)
            await #expect(throws: OfflineCacheError.staleTicket) { try await restarted.validateReaderOpen(token) }
            for file in try FileManager.default.contentsOfDirectory(at: f.directory, includingPropertiesForKeys: nil) {
                let bytes = try Data(contentsOf: file)
                for marker in ["PRIVATE-CACHED-READER", "PRIVATE-CACHED-LIBRARY", "PRIVATE-DRAFT", "PRIVATE-HISTORY"] {
                    #expect(bytes.range(of: Data(marker.utf8)) == nil)
                }
            }
        }
    }

    @Test func cancellationRemovalAndFreshWriterCannotResurrectACompletedOperation() async throws {
        try await withFixture { f in
            let bundle = try bundle(), binding = try f.binding(bundle)
            let cancelled = try await f.store.beginReaderInstall(binding: binding)
            try await f.store.cancelReaderInstall(cancelled)
            let current = try await f.store.beginReaderInstall(binding: binding)
            try await f.store.cancelReaderInstall(cancelled)
            await #expect(throws: (any Error).self) { try await f.store.commitReaderInstall(cancelled, bundle: bundle) }
            let installed = try await f.store.commitReaderInstall(current, bundle: bundle)
            #expect(try await f.store.commitReaderInstall(current, bundle: bundle) == installed)
            try await f.store.removeReaderBundle(id: installed.id, expectedRevision: installed.revision, scope: f.scope)
            await #expect(throws: (any Error).self) { try await f.store.commitReaderInstall(current, bundle: bundle) }
            let again = try await install(bundle, binding: binding, store: f.store)
            #expect(again.id != installed.id)
            await #expect(throws: (any Error).self) { try await f.store.commitReaderInstall(current, bundle: bundle) }
            let newWriter = try f.reopen()
            await #expect(throws: ReaderError.storeChanged) { try await f.store.listInstalledReaderBundles(scope: f.scope) }
            await #expect(throws: OfflineCacheError.staleTicket) { try await newWriter.commitReaderInstall(current, bundle: bundle) }
            #expect(try await newWriter.listInstalledReaderBundles(scope: f.scope).installations == [again])
        }
    }

    @Test func quarantineSurvivesOutageRemovalAndReinstallUntilNewerAvailability() async throws {
        try await withFixture { f in
            let bundle = try bundle(), binding = try f.binding(bundle)
            var row = item(binding: binding)
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 1), scope: f.scope)
            let installed = try await install(bundle, binding: binding, store: f.store)
            let open = try await f.store.readReaderBundle(id: installed.id, scope: f.scope).openToken
            row["state_seq"] = Int64(2); row["render_availability"] = "quarantined"; row["render_availability_revision"] = 2
            let blocked = try observation(f.account, rows: [row], cursor: 2)
            let liveGuard = try installed.eligibility.applying(observation: blocked, binding: binding)
            #expect(liveGuard.block == .quarantined && !liveGuard.canOpen)
            try await f.store.saveLibraryPresentation(blocked, scope: f.scope)
            await #expect(throws: OfflineCacheError.revisionConflict) { try await f.store.validateReaderOpen(open) }
            row["state_seq"] = Int64(3); row["render_availability"] = "unavailable"; row["render_availability_revision"] = 3
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 3), scope: f.scope)
            let current = try await f.store.listInstalledReaderBundles(scope: f.scope).installations[0]
            #expect(current.block == .quarantined && current.ciphertextBytes == installed.ciphertextBytes)
            try await f.store.removeReaderBundle(id: current.id, expectedRevision: current.revision, scope: f.scope)
            let restarted = try f.reopen()
            await #expect(throws: OfflineCacheError.blocked) { try await restarted.beginReaderInstall(binding: binding) }
            // Equal availability revision cannot clear an explicit block.
            row["state_seq"] = Int64(4); row["render_availability"] = "available"
            try await restarted.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 4), scope: f.scope)
            await #expect(throws: OfflineCacheError.blocked) { try await restarted.beginReaderInstall(binding: binding) }
            row["state_seq"] = Int64(5); row["render_availability_revision"] = 4
            try await restarted.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 5), scope: f.scope)
            #expect(try await install(bundle, binding: binding, store: restarted).canOpen)
        }
    }

    @Test func outagePreservesLocalReadingButNewBlockDefeatsPendingInstall() async throws {
        try await withFixture { f in
            let bundle = try bundle(), binding = try f.binding(bundle)
            var row = item(binding: binding)
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 1), scope: f.scope)
            let ticket = try await f.store.beginReaderInstall(binding: binding)
            row["state_seq"] = Int64(2); row["render_availability"] = "quarantined"; row["render_availability_revision"] = 2
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 2), scope: f.scope)
            await #expect(throws: OfflineCacheError.blocked) { try await f.store.commitReaderInstall(ticket, bundle: bundle) }
            #expect(try await f.store.listInstalledReaderBundles(scope: f.scope).installations.isEmpty)
            row["state_seq"] = Int64(3); row["render_availability"] = "available"; row["render_availability_revision"] = 3
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 3), scope: f.scope)
            let installed = try await f.store.commitReaderInstall(ticket, bundle: bundle)
            let openToken = try await f.store.readReaderBundle(id: installed.id, scope: f.scope).openToken
            let previousList = try await f.store.listInstalledReaderBundles(scope: f.scope)
            row["state_seq"] = Int64(4); row["render_availability"] = "unavailable"; row["render_availability_revision"] = 4
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 4), scope: f.scope)
            let advanced = try await f.store.listInstalledReaderBundles(scope: f.scope)
            #expect(advanced.generation > previousList.generation)
            #expect(advanced.installations[0].revision == installed.revision)
            #expect(try await f.store.validateReaderOpen(openToken).canOpen)
            let restarted = try f.reopen()
            #expect(try await restarted.listInstalledReaderBundles(scope: f.scope).installations[0].canOpen)
            #expect(try await restarted.readReaderBundle(id: installed.id, scope: f.scope).manifestData == bundle.manifestData)
        }
    }

    @Test func membershipRemovalRetainsReclaimableCopyHistoryAndDraft() async throws {
        try await withFixture { f in
            let bundle = try bundle(), binding = try f.binding(bundle)
            var row = item(binding: binding)
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 1), scope: f.scope)
            let installed = try await install(bundle, binding: binding, store: f.store)
            let note = try await f.store.append(.init(kind: .note, text: "Keep independent history"), deviceID: UUID())
            row["state_seq"] = Int64(2); row["membership_revision"] = 2; row["visible"] = false; row["last_remove_seq"] = 2
            let complete = try observation(f.account, rows: [row], cursor: 2)
            try await f.store.saveLibraryPresentation(complete, scope: f.scope)
            let list = try await f.store.listInstalledReaderBundles(scope: f.scope), summary = list.installations[0]
            #expect(summary.id == installed.id && summary.membershipVisible == false && !summary.canOpen)
            try await f.store.removeReaderBundle(id: summary.id, expectedRevision: summary.revision, scope: f.scope)
            #expect(try await f.store.listInstalledReaderBundles(scope: f.scope).ciphertextBytes < list.ciphertextBytes)
            #expect(try await f.store.cachedLibraryPresentation(scope: f.scope)?.entries == complete.entries)
            #expect(await f.store.pending() == [note])
        }
    }

    @Test func partialBundleAndPresentationTransactionsRollBackTogether() async throws {
        try await withFixture { f in
            let bundle = try bundle(), binding = try f.binding(bundle)
            var row = item(binding: binding)
            let old = try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 1), scope: f.scope)
            let db = try SQLiteConnection(url: f.url)
            try db.execute("CREATE TRIGGER fail_member BEFORE INSERT ON local_reader_bundle_members WHEN NEW.ordinal=2 BEGIN SELECT RAISE(ABORT,'fixture'); END")
            let ticket = try await f.store.beginReaderInstall(binding: binding), before = await f.store.snapshot()
            await #expect(throws: (any Error).self) { try await f.store.commitReaderInstall(ticket, bundle: bundle) }
            #expect(try count(db, "local_reader_bundle_headers") == 0 && count(db, "local_reader_bundle_members") == 0)
            #expect(await f.store.snapshot() == before)
            try db.execute("DROP TRIGGER fail_member")
            let installed = try await f.store.commitReaderInstall(ticket, bundle: bundle)
            try db.execute("CREATE TRIGGER fail_cache_checkpoint BEFORE UPDATE ON local_library_cache_checkpoint BEGIN SELECT RAISE(ABORT,'fixture'); END")
            row["state_seq"] = Int64(2); row["render_availability"] = "quarantined"; row["render_availability_revision"] = 2
            await #expect(throws: (any Error).self) { try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 2), scope: f.scope) }
            #expect(try await f.store.cachedLibraryPresentation(scope: f.scope) == old)
            #expect(try await f.store.listInstalledReaderBundles(scope: f.scope).installations == [installed])
            try db.execute("DROP TRIGGER fail_cache_checkpoint")
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 2), scope: f.scope)
            #expect(try await f.store.listInstalledReaderBundles(scope: f.scope).installations[0].block == .quarantined)
        }
    }

    @Test(arguments: ["local_library_cache_checkpoint", "local_library_cache_entries", "local_reader_bundle_index", "local_reader_bundle_headers", "local_reader_bundle_members"])
    func corruptCacheChildrenDoNotPreventPrivateRecoveryOrWriting(table: String) async throws {
        try await withFixture { f in
            let bundle = try bundle(), binding = try f.binding(bundle)
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [item(binding: binding)], cursor: 1), scope: f.scope)
            let installed = try await install(bundle, binding: binding, store: f.store)
            let event = try await f.store.append(.init(kind: .note, text: "Private data survives"), deviceID: UUID())
            let db = try SQLiteConnection(url: f.url)
            try db.execute("UPDATE \(table) SET sealed=zeroblob(8388608)")
            let restarted = try f.reopen()
            #expect(await restarted.pending() == [event])
            try await restarted.append(.init(kind: .note, text: "Independent new private edit"), deviceID: UUID())
            if table.hasPrefix("local_library_cache") {
                await #expect(throws: (any Error).self) { try await restarted.cachedLibraryPresentation(scope: f.scope) }
                #expect(try await restarted.readReaderBundle(id: installed.id, scope: f.scope).manifestData == bundle.manifestData)
            } else {
                await #expect(throws: (any Error).self) { try await restarted.readReaderBundle(id: installed.id, scope: f.scope) }
                #expect(try await restarted.cachedLibraryPresentation(scope: f.scope)?.entries.count == 1)
                if table != "local_reader_bundle_index" {
                    #expect(try await restarted.listInstalledReaderBundles(scope: f.scope).installations == [installed])
                    try await restarted.removeReaderBundle(id: installed.id, expectedRevision: installed.revision, scope: f.scope)
                    #expect(try await restarted.listInstalledReaderBundles(scope: f.scope).installations.isEmpty)
                }
            }
        }
    }

    @Test func completeCacheRejectsLostRowsPinsAndConflictingCursorsAcrossSessions() async throws {
        try await withFixture { f in
            let bundle = try bundle(), binding = try f.binding(bundle), row = item(binding: binding)
            let saved = try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 3), scope: f.scope)
            await #expect(throws: OfflineCacheError.staleObservation) { try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 2), scope: f.scope) }
            await #expect(throws: OfflineCacheError.invalidObservation) { try await f.store.saveLibraryPresentation(observation(f.account, rows: [], cursor: 4), scope: f.scope) }
            var changed = row; changed["state_seq"] = Int64(2)
            await #expect(throws: OfflineCacheError.conflictingObservation) { try await f.store.saveLibraryPresentation(observation(f.account, rows: [changed], cursor: 3), scope: f.scope) }
            changed["artifact_id"] = UUID().wire
            await #expect(throws: (any Error).self) { try await f.store.saveLibraryPresentation(observation(f.account, rows: [changed], cursor: 4), scope: f.scope) }
            #expect(try await f.store.cachedLibraryPresentation(scope: f.scope) == saved)
            let guardValue = try ReaderBundleEligibility().applying(observation: observation(f.account, rows: [row], cursor: 3), binding: binding)
            #expect(throws: OfflineCacheError.conflictingObservation) { try guardValue.applying(observation: observation(f.account, rows: [], cursor: 3), binding: binding) }
        }
    }

    /// A snapshot saved by a build that read v2 (web papers left out) is replaced by the
    /// first v3 observation at the same cursor instead of conflicting with it.
    @Test func v2SnapshotIsReplacedByTheFirstV3Observation() async throws {
        try await withFixture { f in
            let bundle = try bundle(), binding = try f.binding(bundle), row = item(binding: binding)
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 3), scope: f.scope, format: 1)
            var web = item(binding: try f.binding(try self.bundle()), created: 2)
            web["source"] = "web"; web["source_id"] = "openalex:W1000000001"; web["source_revision"] = 1
            web["source_url"] = "https://doi.org/10.1038/nature14539"; web["scope"] = "owner_private"
            let replaced = try await f.store.saveLibraryPresentation(observation(f.account, rows: [row, web], cursor: 3), scope: f.scope)
            #expect(replaced.entries.count == 2)
            #expect(try await f.store.cachedLibraryPresentation(scope: f.scope) == replaced)
            // From then on the snapshot is compared as before.
            await #expect(throws: OfflineCacheError.conflictingObservation) {
                try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 3), scope: f.scope)
            }
            await #expect(throws: OfflineCacheError.staleObservation) {
                try await f.store.saveLibraryPresentation(observation(f.account, rows: [row, web], cursor: 2), scope: f.scope)
            }
        }
    }

    /// A staging library as build 15 received it (2026-10-07, anonymized): 56 entries at cursor 281, items with
    /// catalog `tags` (migration 030), an archived item, removed items, ready/cancelled/failed imports.
    private func build15Library() throws -> (cursor: Int64, entries: [[String: Any]]) {
        let url = try #require(Bundle.module.url(forResource: "library-build15-shapes", withExtension: "json"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entries = try #require(object["entries"] as? [[String: Any]])
        return ((object["cursor"] as! NSNumber).int64Value, entries.map { entry in
            entry.mapValues { ($0 as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0 : $0.int64Value as Any } ?? $0 }
        })
    }

    /// What build 14 kept of each entry: it didn't decode the fields migrations 029/030 added.
    private func asBuild14Decoded(_ entries: [[String: Any]]) -> [[String: Any]] {
        entries.map { $0.filter { !["tags", "user_tags", "hidden_tags", "progress_detail"].contains($0.key) } }
    }

    /// Owner, build 15: "Your latest library update wasn't saved for offline use. Reopen the app to try again" on
    /// every launch. Build 14 had cached items without their `tags`; build 15 decodes them, so the same
    /// `state_seq` compared unequal (conflictingObservation) and the cache never saved again.
    @Test func build14SnapshotTakesBuild15TagsInsteadOfConflicting() async throws {
        try await withFixture { f in
            let library = try build15Library()
            #expect(library.entries.count == 56)
            let old = asBuild14Decoded(library.entries)
            try await f.store.saveLibraryPresentation(observation(f.account, rows: old, cursor: library.cursor), scope: f.scope, format: 2)
            // The strict rule still holds between snapshots of the same format: this is exactly what build 15 hit.
            try await f.store.saveLibraryPresentation(observation(f.account, rows: old, cursor: library.cursor), scope: f.scope)
            await #expect(throws: OfflineCacheError.conflictingObservation) {
                try await f.store.saveLibraryPresentation(observation(f.account, rows: library.entries, cursor: library.cursor), scope: f.scope)
            }
            // Write a real earlier checkpoint through the test-only format parameter, then reopen it.
            try await f.store.saveLibraryPresentation(observation(f.account, rows: old, cursor: library.cursor), scope: f.scope, format: 2, rebuild: true)
            let fresh = try f.reopen()
            let saved = try await fresh.saveLibraryPresentation(observation(f.account, rows: library.entries, cursor: library.cursor), scope: f.scope)
            let restored = try #require(try await fresh.cachedLibraryPresentation(scope: f.scope))
            #expect(restored == saved)
            let tagged = restored.entries.values.compactMap { entry -> LibraryItemRecord? in
                if case .item(let item) = entry, item.tags != nil { return item }; return nil
            }
            #expect(tagged.count == 17)
            #expect(tagged.contains { $0.tags == ["AI for science", "Evaluation", "Computer vision"] })
            // From then on it is compared as before, and a later cursor applies normally.
            try await fresh.saveLibraryPresentation(observation(f.account, rows: library.entries, cursor: library.cursor), scope: f.scope)
            let latest = try await fresh.saveLibraryPresentation(observation(f.account, rows: library.entries, cursor: library.cursor + 1), scope: f.scope)
            #expect(try await f.reopen().cachedLibraryPresentation(scope: f.scope) == latest)
        }
    }

    /// Conflicting decoded display fields can be repaired; unreadable eligibility cannot be discarded.
    @Test func conflictingSavedLibraryIsRebuiltButUnreadablePolicyIsPreserved() async throws {
        try await withFixture { f in
            let bundle = try bundle(), binding = try f.binding(bundle), row = item(binding: binding)
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 3), scope: f.scope)
            let installed = try await install(bundle, binding: binding, store: f.store)
            var changed = row; changed["tags"] = ["Transformers"]
            let error = await #expect(throws: OfflineCacheError.self) {
                try await f.store.saveLibraryPresentation(observation(f.account, rows: [changed], cursor: 3), scope: f.scope)
            }
            #expect(error?.replacesSavedLibrary == true)
            let rebuilt = try await f.store.rebuildLibraryPresentation(observation(f.account, rows: [changed], cursor: 3), scope: f.scope)
            #expect(try await f.store.cachedLibraryPresentation(scope: f.scope) == rebuilt)
            #expect(try await f.store.listInstalledReaderBundles(scope: f.scope).installations == [installed])
            #expect(try await f.store.readReaderBundle(id: installed.id, scope: f.scope).manifestData == bundle.manifestData)
            // An older cursor is still refused, rebuild or not.
            await #expect(throws: OfflineCacheError.staleObservation) {
                try await f.store.rebuildLibraryPresentation(observation(f.account, rows: [changed], cursor: 2), scope: f.scope)
            }
            // A damaged saved row cannot prove its availability history. Keep its bytes and refuse repair.
            let db = try SQLiteConnection(url: f.url)
            try db.update("UPDATE local_library_cache_entries SET sealed=zeroblob(64)", values: [])
            let damaged = try f.reopen()
            await #expect(throws: (any Error).self) { try await damaged.cachedLibraryPresentation(scope: f.scope) }
            await #expect(throws: (any Error).self) {
                try await damaged.rebuildLibraryPresentation(observation(f.account, rows: [changed], cursor: 4), scope: f.scope)
            }
            #expect(try await damaged.listInstalledReaderBundles(scope: f.scope).installations.count == 1)
        }
    }

    @Test func rebuildingPresentationKeepsQuarantineAfterLocalRemovalAndRejectsChangedPins() async throws {
        try await withFixture { f in
            let bundle = try bundle(), binding = try f.binding(bundle)
            var row = item(binding: binding)
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 1), scope: f.scope)
            _ = try await install(bundle, binding: binding, store: f.store)
            row["state_seq"] = Int64(2); row["render_availability"] = "quarantined"; row["render_availability_revision"] = 2
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 2), scope: f.scope)
            row["state_seq"] = Int64(3); row["render_availability"] = "unavailable"; row["render_availability_revision"] = 3
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [row], cursor: 3), scope: f.scope)
            let blocked = try #require(try await f.store.listInstalledReaderBundles(scope: f.scope).installations.first)
            try await f.store.removeReaderBundle(id: blocked.id, expectedRevision: blocked.revision, scope: f.scope)
            row["tags"] = ["Transformers"]
            let repaired = try await f.store.rebuildLibraryPresentation(observation(f.account, rows: [row], cursor: 3), scope: f.scope)
            let reopened = try f.reopen()
            await #expect(throws: OfflineCacheError.blocked) { try await reopened.beginReaderInstall(binding: binding) }
            for (key, value) in [("artifact_id", UUID().wire), ("version_id", UUID().wire), ("render_availability", "available")] {
                var inconsistent = row; inconsistent[key] = value
                await #expect(throws: (any Error).self) {
                    try await reopened.rebuildLibraryPresentation(observation(f.account, rows: [inconsistent], cursor: 3), scope: f.scope)
                }
            }
            await #expect(throws: (any Error).self) {
                try await reopened.rebuildLibraryPresentation(observation(f.account, rows: [], cursor: 4), scope: f.scope)
            }
            let additional = item(binding: try f.binding(bundle), created: 2)
            await #expect(throws: OfflineCacheError.conflictingObservation) {
                try await reopened.rebuildLibraryPresentation(observation(f.account, rows: [row, additional], cursor: 3), scope: f.scope)
            }
            #expect(try await reopened.cachedLibraryPresentation(scope: f.scope) == repaired)
            await #expect(throws: OfflineCacheError.blocked) { try await reopened.beginReaderInstall(binding: binding) }
        }
    }

    /// Adding a decoded entry field must bump `CachePresentationCheckpoint.currentFormat` (see its comment), or
    /// snapshots saved before the field existed conflict with the server forever.
    @Test func snapshotFormatCoversEveryDecodedEntryField() throws {
        let library = try build15Library()
        var item = try #require(library.entries.first { $0["kind"] as? String == "item" && $0["tags"] != nil && $0["visible"] as? Bool == true })
        item["user_tags"] = ["Mine"]; item["hidden_tags"] = ["Computer vision"]; item["archived"] = true
        var active = try #require(library.entries.first { $0["kind"] as? String == "import" && $0["phase"] as? String == "failed" })
        active["requested_revision"] = active["source_revision"]
        active["document_id"] = UUID().wire; active["library_item_id"] = UUID().wire
        active["progress"] = "downloading"; active["progress_detail"] = ["step": "downloading", "percent": 12]
        active["auto_retry_at"] = "2026-10-08T01:00:00Z"
        func keys(_ row: [String: Any]) throws -> Set<String> {
            let entry = try JSONDecoder().decode(LibraryEntry.self, from: json(row))
            return Set(try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any]).keys)
        }
        let descriptor: [String: Any] = ["descriptor_id": UUID().wire, "revision": 1, "epoch": 1,
                                        "sha256": String(repeating: "a", count: 64)]
        item["descriptor_ref"] = descriptor; active["descriptor_ref"] = descriptor
        #expect(CachePresentationCheckpoint.currentFormat == 5)
        #expect(try keys(item) == ["kind", "id", "document_id", "created_seq", "state_seq", "membership_revision", "visible", "added_at",
            "last_remove_seq", "approval_id", "version_id", "metadata_id", "source", "source_id", "source_revision", "metadata",
            "metadata_recorded_at", "source_url", "scope", "page_count", "original_object_id", "artifact_id", "readiness",
            "original_availability", "render_availability", "original_availability_revision", "render_availability_revision",
            "archived", "tags", "user_tags", "hidden_tags", "descriptor_ref"])
        #expect(try keys(active) == ["kind", "id", "created_seq", "state_seq", "intent_revision", "visible", "phase", "source", "source_id",
            "requested_revision", "source_revision", "metadata_id", "version_id", "metadata", "metadata_recorded_at", "source_url",
            "document_id", "library_item_id", "error_code", "retryable", "progress", "progress_detail", "auto_retry_at", "descriptor_ref"])
    }

    @Test func exactBindingScopeAndEmptyLibraryCannotAuthorizeDifferentInstall() async throws {
        try await withFixture { f in
            let first = try bundle(), binding = try f.binding(first)
            let ticket = try await f.store.beginReaderInstall(binding: binding)
            let different = try bundle(memberCount: 5)
            await #expect(throws: OfflineCacheError.invalidBinding) { try await f.store.commitReaderInstall(ticket, bundle: different) }
            let wrong = try LibraryCommandScope(accountID: UUID(), deploymentID: f.scope.deploymentID)
            await #expect(throws: ReaderError.wrongAccount) { try await f.store.cachedLibraryPresentation(scope: wrong) }
            try await f.store.cancelReaderInstall(ticket)
            try await f.store.saveLibraryPresentation(observation(f.account, rows: [], cursor: 0), scope: f.scope)
            await #expect(throws: OfflineCacheError.blocked) { try await f.store.beginReaderInstall(binding: binding) }
            let other = try LibraryCommandScope(accountID: f.account, deploymentID: "https://other.invalid")
            await #expect(throws: LibraryCommandError.invalidScope) { try await f.store.listInstalledReaderBundles(scope: other) }
        }
    }

    @Test func hundredCopyLimitPreservesCopiesAndExplicitRemovalRestoresCapacity() async throws {
        try await withFixture { f in
            let bundle = try bundle()
            var first: InstalledReaderBundle?
            for _ in 0..<100 {
                let value = try await install(bundle, binding: f.binding(bundle), store: f.store)
                if first == nil { first = value }
            }
            let full = try await f.store.listInstalledReaderBundles(scope: f.scope)
            #expect(full.installations.count == 100)
            let refused = try f.binding(bundle)
            await #expect(throws: OfflineCacheError.capacityExceeded) { try await f.store.beginReaderInstall(binding: refused) }
            #expect(try await f.store.listInstalledReaderBundles(scope: f.scope) == full)
            let removed = try #require(first)
            try await f.store.removeReaderBundle(id: removed.id, expectedRevision: removed.revision, scope: f.scope)
            _ = try await install(bundle, binding: refused, store: f.store)
            #expect(try await f.store.listInstalledReaderBundles(scope: f.scope).installations.count == 100)
        }
    }

    @Test func fullMemberCountFitsHeaderAndRoundTripsWithoutEagerOtherCopies() async throws {
        try await withFixture { f in
            let bundle = try bundle(memberCount: 512), binding = try f.binding(bundle)
            let installed = try await install(bundle, binding: binding, store: f.store)
            let reopened = try await f.store.readReaderBundle(id: installed.id, scope: f.scope)
            #expect(reopened.members.count == 512 && reopened.manifestData == bundle.manifestData)
        }
    }

    @Test func formatFiveMigrationIsAtomicAndPreservesPrivateRowsAndCommands() async throws {
        try await withFixture { f in
            let note = try await f.store.append(.init(kind: .note, text: "Legacy private history"), deviceID: UUID())
            let draft = LocalDraft(id: UUID(), revision: 1, textRevision: UUID(), text: "Legacy draft", editedAt: Date(), branchRevision: UUID())
            try await f.store.saveDraft(draft)
            let command = try await f.store.enqueueLibraryCommand(scope: f.scope,
                mutation: .beginImport(sourceID: "1706.03762", requestedRevision: nil, observedCursor: 0))
            let before = await f.store.snapshot(), db = try SQLiteConnection(url: f.url)
            let aad = Data("science-reader/local-metadata/v2/\(f.account.wire)".utf8), key = SymmetricKey(data: f.key)
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: raw(db, "metadata")), using: key, authenticating: aad)
            var metadata = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
            metadata["format"] = 5; metadata.removeValue(forKey: "offlineCache"); metadata.removeValue(forKey: "noteUploads"); metadata.removeValue(forKey: "noteHolds")
            let legacy = try #require(AES.GCM.seal(json(metadata), using: key, authenticating: aad).combined)
            try db.execute("BEGIN IMMEDIATE; DROP TABLE local_note_blobs; DROP TABLE local_reader_bundle_members; DROP TABLE local_reader_bundle_headers; DROP TABLE local_reader_bundle_index; DROP TABLE local_library_cache_entries; DROP TABLE local_library_cache_checkpoint; PRAGMA user_version=4")
            try db.update("UPDATE metadata SET sealed=? WHERE id=1", values: [.blob(legacy)])
            try db.execute("COMMIT; CREATE TRIGGER fail_format_six BEFORE UPDATE ON metadata BEGIN SELECT RAISE(ABORT,'fixture'); END")
            #expect(throws: (any Error).self) { try f.reopen() }
            #expect(try raw(db, "metadata") == legacy)
            let created = try db.statement("SELECT count(*) FROM sqlite_master WHERE name LIKE 'local_reader_bundle_%' OR name LIKE 'local_library_cache_%'") { statement in
                _ = sqlite3_step(statement); return sqlite3_column_int(statement, 0)
            }
            #expect(created == 0)
            try db.execute("DROP TRIGGER fail_format_six")
            let restored = try f.reopen(), snapshot = await restored.snapshot()
            #expect(snapshot.state == before.state && snapshot.drafts == [draft] && snapshot.generation == before.generation + 1)
            #expect(await restored.pending() == [note])
            #expect(try await restored.libraryCommandSnapshot(scope: f.scope).commands.first?.handle == command)
            #expect(try await restored.cachedLibraryPresentation(scope: f.scope) == nil)
            #expect(try await restored.listInstalledReaderBundles(scope: f.scope).installations.isEmpty)
            let version = try db.statement("PRAGMA user_version") { statement in _ = sqlite3_step(statement); return sqlite3_column_int(statement, 0) }
            #expect(version == 6)
            await #expect(throws: ReaderError.storeChanged) { try await f.store.append(.init(kind: .note, text: "Stale old owner"), deviceID: UUID()) }
        }
    }

    @Test func fullPayloadsReachCiphertextQuotaWithoutEvictionOrPartialWrites() async throws {
        try await withFixture { f in
            let full = try bundle(payloadBytes: 33_554_432)
            for _ in 0..<15 { _ = try await install(full, binding: f.binding(full), store: f.store) }
            let before = try await f.store.listInstalledReaderBundles(scope: f.scope)
            #expect(before.ciphertextBytes > 15 * 33_554_432 && before.installations.count == 15)
            let refused = try await f.store.beginReaderInstall(binding: f.binding(full))
            await #expect(throws: OfflineCacheError.capacityExceeded) { try await f.store.commitReaderInstall(refused, bundle: full) }
            #expect(try await f.store.listInstalledReaderBundles(scope: f.scope) == before)
            let db = try SQLiteConnection(url: f.url)
            #expect(try count(db, "local_reader_bundle_headers") == 15)
            try await f.store.cancelReaderInstall(refused)
            let smaller = try bundle(payloadBytes: 31 * 1024 * 1024)
            let admitted = try await install(smaller, binding: f.binding(smaller), store: f.store)
            let after = try await f.store.listInstalledReaderBundles(scope: f.scope)
            #expect(after.installations.count == 16 && after.ciphertextBytes <= OfflineCacheLimits.bundleBytes)
            #expect(after.installations.contains(admitted))
            // Listing 511 MiB of installed data reads only its compact index.
            let restarted = try f.reopen()
            let restoredList = try await restarted.listInstalledReaderBundles(scope: f.scope)
            #expect(restoredList.installations == after.installations && restoredList.ciphertextBytes == after.ciphertextBytes)
            #expect(restoredList.generation == after.generation + 1)
        }
    }

    @Test func allFourThousandMaximumMetadataRowsRoundTripWithinSeparateQuota() async throws {
        try await withFixture { f in
            var metadata: [String: Any] = ["title": String(repeating: "T", count: 2_000), "authors": [String](),
                "abstract": String(repeating: "a", count: 24_000), "categories": ["cs.CL"],
                "venue": String(repeating: "V", count: 1_024), "published_at": "2026-10-01", "updated_at": "2026-10-02"]
            var authors: [String] = []
            while true {
                let remaining = 32_768 - (try json(metadata).count)
                let overhead = authors.isEmpty ? 2 : 3
                if remaining <= overhead { break }
                authors.append(String(repeating: "A", count: min(256, remaining - overhead)))
                metadata["authors"] = authors
            }
            let finalPadding = 32_768 - (try json(metadata).count)
            metadata["categories"] = ["cs.CL" + String(repeating: "a", count: finalPadding)]
            #expect(try json(metadata).count == 32_768)
            let smallBundle = try bundle()
            var rows: [[String: Any]] = []
            for index in 1...4_000 {
                var row = try item(binding: f.binding(smallBundle), created: Int64(index))
                row["metadata"] = metadata
                // Unknown bounded values must survive the local codec too.
                row["readiness"] = String(repeating: "\t", count: 64)
                row["original_availability"] = String(repeating: "\\", count: 64)
                row["render_availability"] = String(repeating: "\"", count: 64)
                rows.append(row)
            }
            let observed = try observation(f.account, rows: rows, cursor: 4_000)
            let started = Date()
            let saved = try await f.store.saveLibraryPresentation(observed, scope: f.scope)
            let commitSeconds = Date().timeIntervalSince(started)
            let db = try SQLiteConnection(url: f.url)
            let sizes = try db.statement("SELECT count(*),max(length(sealed)),sum(length(sealed)) FROM local_library_cache_entries") { statement -> (Int, Int, Int) in
                _ = sqlite3_step(statement)
                return (Int(sqlite3_column_int64(statement, 0)), Int(sqlite3_column_int64(statement, 1)), Int(sqlite3_column_int64(statement, 2)))
            }
            #expect(sizes.0 == 4_000 && sizes.1 <= OfflineCacheLimits.presentationRowBytes)
            #expect(sizes.2 + (try raw(db, "local_library_cache_checkpoint").count) <= OfflineCacheLimits.presentationBytes)
            let restarted = try f.reopen(), restoreStarted = Date()
            #expect(try await restarted.cachedLibraryPresentation(scope: f.scope) == saved)
            let restoreSeconds = Date().timeIntervalSince(restoreStarted)
            let projected = try #require(await restarted.cachedLibraryProjection(scope: f.scope, project: { $0 }))
            #expect(projected.validatedEntryCount == 4_000 && projected.committedCursor == saved.committedCursor)
            #expect(projected.rows == saved.entries.values.sorted { LibraryOrderingKey($0) < LibraryOrderingKey($1) })
            #expect(Dictionary(uniqueKeysWithValues: projected.rows.map { ($0.id, $0) }) == saved.entries)
            print("offline_cache_fixture rows=4000 sealed_bytes=\(sizes.2) max_row=\(sizes.1) commit_wall_s=\(commitSeconds) restore_wall_s=\(restoreSeconds)")
        }
    }
}
