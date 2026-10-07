import CSQLite
import CryptoKit
import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct LibraryCommandStoreTests {
    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        let account = UUID(), device = UUID(), localKey = ReaderCrypto.randomKey()
        let keys: KeyBundle
        let store: EncryptedStore
        var url: URL { directory.appendingPathComponent("state.sqlite") }
        var scope: LibraryCommandScope { try! .init(accountID: account, deploymentID: "https://queue-test.supabase.co") }
        init() throws {
            keys = KeyBundle.generate(accountID: account)
            store = try EncryptedStore(url: directory.appendingPathComponent("state.sqlite"), accountID: account, localKey: localKey, keys: keys)
        }
        func reopen() throws -> EncryptedStore { try EncryptedStore(url: url, accountID: account, localKey: localKey, keys: keys) }
    }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func begin(_ source: String = "2601.00001", cursor: Int64 = 0) -> LibraryMutation {
        .beginImport(sourceID: source, requestedRevision: nil, observedCursor: cursor)
    }
    private func imported(_ id: UUID, state: Int64 = 1, revision: Int64 = 1, source: String = "2601.00001", phase: String = "accepted") -> [String: Any] {
        ["kind": "import", "id": id.wire, "created_seq": 1, "state_seq": state, "intent_revision": revision,
         "visible": phase != "cancelled", "phase": phase, "source": "arxiv", "source_id": source,
         "requested_revision": NSNull(), "source_revision": NSNull(), "metadata_id": NSNull(), "version_id": NSNull(),
         "metadata": NSNull(), "metadata_recorded_at": NSNull(), "source_url": "https://arxiv.org/abs/\(source)",
         "document_id": NSNull(), "library_item_id": NSNull(), "error_code": NSNull(), "retryable": false]
    }
    private func item(_ id: UUID, document: UUID, state: Int64 = 1, revision: Int64 = 1, visible: Bool = true) -> [String: Any] {
        ["kind": "item", "id": id.wire, "document_id": document.wire, "created_seq": 1,
         "state_seq": state, "membership_revision": revision, "visible": visible,
         "added_at": "2026-10-03T01:02:03Z", "last_remove_seq": visible ? 0 : state,
         "approval_id": NSNull(), "version_id": NSNull(), "metadata_id": NSNull(), "source": NSNull(),
         "source_id": NSNull(), "source_revision": NSNull(), "metadata": NSNull(), "metadata_recorded_at": NSNull(),
         "source_url": NSNull(), "scope": "shared_catalog", "page_count": 1,
         "original_object_id": NSNull(), "artifact_id": NSNull(), "readiness": "unverified"]
    }
    private func response(_ entry: [String: Any]?, sequence: Int64? = 1, revision: Int64 = 1, replayed: Bool = false) throws -> LibraryCommandResponse {
        let result: [String: Any] = ["status": sequence == nil ? "revision_conflict" : "applied",
                                   "kind": entry?["kind"] ?? "item", "id": entry?["id"] ?? NSNull(),
                                   "seq": sequence ?? (NSNull() as Any), "revision": revision]
        return try LibraryWire.decodeCommand(json(["result": result, "replayed": replayed, "entry": entry ?? (NSNull() as Any)]))
    }
    private func observation(account: UUID, rows: [[String: Any]], cursor: Int64) throws -> LibraryCompleteObservation {
        var reconciler = LibraryReconciler(accountID: account)
        let entries = rows.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
        let continuation: Any = entries.last.map {
            ["format": 2, "account_id": account.wire, "through": cursor, "created_seq": 1,
             "id": $0["id"]!, "kind": $0["kind"]!] as [String: Any]
        } ?? (NSNull() as Any)
        let baseline = try LibraryWire.decodeBaseline(json(["format": 2, "account_id": account.wire,
            "baseline_cursor": cursor, "retained_after": 0, "entries": entries, "next_cursor": continuation, "has_more": false]))
        try reconciler.accept(baseline, for: reconciler.nextRequest())
        let changes = try LibraryWire.decodeChanges(json(["format": 2, "account_id": account.wire,
            "through": cursor, "retained_after": 0, "changes": [], "next_cursor": cursor, "has_more": false]))
        try reconciler.accept(changes, for: reconciler.nextRequest())
        return try reconciler.completeObservation()
    }
    private func raw(_ database: SQLiteConnection, table: String, id: String = "1") throws -> Data {
        try database.statement("SELECT sealed FROM \(table) WHERE id=?", values: [.text(id)]) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw ReaderError.corruptData }
            return try SQLiteConnection.blob(statement, 0)
        }
    }
    private func makeFormat4(_ f: Fixture) throws -> Data {
        let db = try SQLiteConnection(url: f.url), key = SymmetricKey(data: f.localKey)
        let aad = Data("science-reader/local-metadata/v2/\(f.account.wire)".utf8)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: raw(db, table: "metadata")), using: key, authenticating: aad)
        var fields = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        fields["format"] = 4
        for field in ["libraryCommands", "libraryCommandSequence", "libraryCommandScope", "offlineCache"] { fields.removeValue(forKey: field) }
        let sealed = try #require(AES.GCM.seal(json(fields), using: key, authenticating: aad).combined)
        try db.execute("BEGIN IMMEDIATE; DROP TABLE local_reader_bundle_members; DROP TABLE local_reader_bundle_headers; DROP TABLE local_reader_bundle_index; DROP TABLE local_library_cache_entries; DROP TABLE local_library_cache_checkpoint; DROP TABLE local_library_commands; PRAGMA user_version=3")
        try db.update("UPDATE metadata SET sealed=? WHERE id=1", values: [.blob(sealed)])
        try db.execute("COMMIT")
        return sealed
    }

    @Test func enqueueIsDurableEncryptedAndIndependentOfHistoryAndDeployment() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let h = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin(cursor: 91), display: "SECRET-PENDING-PAPER")
        let snapshot = try await f.store.libraryCommandSnapshot(scope: f.scope)
        let row = try #require(snapshot.commands.first)
        #expect(row.handle == h && row.phase == .prepared && !row.everSubmitted)
        #expect(try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin(cursor: 91)) == h)
        #expect(try await f.store.libraryCommandSnapshot(scope: f.scope) == snapshot)
        let restarted = try f.reopen(), restored = try await restarted.libraryCommandSnapshot(scope: f.scope)
        #expect(restored.commands == snapshot.commands)
        #expect(restored.generation == snapshot.generation + 1)
        #expect(await restarted.state().events.isEmpty)
        #expect(await restarted.cursor() == 0)
        #expect(await restarted.pending().isEmpty)
        let request = try #require(row.request)
        #expect(request.endpoint == "v2_begin_import" && request.operationID == h.intentID)
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["p_observed_cursor"] as? Int == 91)
        for url in try FileManager.default.contentsOfDirectory(at: f.directory, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: url)
            #expect(bytes.range(of: Data("SECRET-PENDING-PAPER".utf8)) == nil)
            #expect(bytes.range(of: Data("2601.00001".utf8)) == nil)
        }
        let foreign = try LibraryCommandScope(accountID: UUID(), deploymentID: f.scope.deploymentID)
        await #expect(throws: ReaderError.wrongAccount) { try await restarted.libraryCommandSnapshot(scope: foreign) }
        let other = try LibraryCommandScope(accountID: f.account, deploymentID: "https://other.supabase.co")
        await #expect(throws: LibraryCommandError.invalidScope) { try await restarted.beginLibraryAttempt(h, scope: other) }
    }

    @Test func crashBeforeNetworkAndLostAcknowledgementRetryExactBytesUnderNewAttempt() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let h = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin(cursor: 7))
        let original = try await f.store.beginLibraryAttempt(h, scope: f.scope)
        #expect(try await f.store.libraryCommandSnapshot(scope: f.scope).commands[0].everSubmitted)
        let reopened = try f.reopen()
        let row = try await reopened.libraryCommandSnapshot(scope: f.scope).commands[0]
        #expect(row.phase == .submittedUnknown && row.attemptID == nil && row.attemptCount == 1)
        let retry = try await reopened.beginLibraryAttempt(h, scope: f.scope)
        #expect(retry.request == original.request && retry.attemptID != original.attemptID)
        let reply = try response(imported(h.intentID, state: 8), sequence: 8)
        await #expect(throws: LibraryCommandError.staleAttempt) { try await reopened.recordLibraryReceipt(reply, for: original) }
        await #expect(throws: ReaderError.storeChanged) { try await f.store.recordLibraryReceipt(reply, for: original) }
        await #expect(throws: ReaderError.storageUnavailable) { try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin("2601.00002")) }
        let received = try await reopened.recordLibraryReceipt(reply, for: retry)
        #expect(received.commands[0].receipt?.result.sequence == 8)
        #expect(await reopened.cursor() == 0)
    }

    @Test func offlineRemoveNeverRebasesAndHistoricalReplayMayShowLaterRestore() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let doc = UUID(), itemID = UUID()
        let h = try await f.store.enqueueLibraryCommand(scope: f.scope,
            mutation: .setMembership(documentID: doc, present: false, expectedRevision: 1, approvalID: nil))
        let attempt = try await f.store.beginLibraryAttempt(h, scope: f.scope)
        _ = try await f.store.recordLibraryFailure(.connection, for: attempt)
        let retry = try await f.store.beginLibraryAttempt(h, scope: f.scope)
        #expect(retry.request == attempt.request)
        let replay = try response(item(itemID, document: doc, state: 9, revision: 3, visible: true), sequence: 2, revision: 2, replayed: true)
        let saved = try await f.store.recordLibraryReceipt(replay, for: retry)
        let receipt = try #require(saved.commands[0].receipt)
        #expect(receipt.requiredCursor == 9)
        let refs = [LibraryCommandReconciliation(handle: h, receiptID: receipt.id)]
        let old = try observation(account: f.account, rows: [item(itemID, document: doc, state: 2, revision: 2, visible: false)], cursor: 2)
        await #expect(throws: LibraryCommandError.incompleteObservation) {
            try await f.store.reconcileLibraryCommands(refs, observation: old, scope: f.scope)
        }
        #expect(try await f.store.libraryCommandSnapshot(scope: f.scope) == saved)
        let current = try observation(account: f.account, rows: [item(itemID, document: doc, state: 9, revision: 3)], cursor: 9)
        let completed = try await f.store.reconcileLibraryCommands(refs, observation: current, scope: f.scope)
        #expect(completed.commands[0].phase == .finished)
        #expect(completed.commands[0].request == attempt.request && current.entries.values.first?.visible == true)
    }

    @Test func immutableConflictIsNotReissuedAtANewerRevision() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let doc = UUID(), itemID = UUID()
        let h = try await f.store.enqueueLibraryCommand(scope: f.scope,
            mutation: .setMembership(documentID: doc, present: false, expectedRevision: 1, approvalID: nil))
        let attempt = try await f.store.beginLibraryAttempt(h, scope: f.scope)
        let reply = try response(item(itemID, document: doc, state: 5, revision: 3), sequence: nil, revision: 3)
        let row = try await f.store.recordLibraryReceipt(reply, for: attempt).commands[0]
        await #expect(throws: LibraryCommandError.invalidTransition) { try await f.store.beginLibraryAttempt(h, scope: f.scope) }
        let proof = try observation(account: f.account, rows: [item(itemID, document: doc, state: 5, revision: 3)], cursor: 5)
        let ref = LibraryCommandReconciliation(handle: h, receiptID: try #require(row.receipt).id)
        #expect(try await f.store.reconcileLibraryCommands([ref], observation: proof, scope: f.scope).commands[0].phase == .needsReview)
        let new = try await f.store.enqueueLibraryCommand(scope: f.scope,
            mutation: .setMembership(documentID: doc, present: false, expectedRevision: 3, approvalID: nil))
        #expect(new.intentID != h.intentID)
    }

    @Test func heldCancelFreezesWithParentReceiptAndSurvivesCrashAtomically() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let h = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin())
        let attempt = try await f.store.beginLibraryAttempt(h, scope: f.scope)
        let child = try await f.store.holdLibrarySuccessor(.cancelImport, after: h, scope: f.scope)
        let before = try await f.store.libraryCommandSnapshot(scope: f.scope)
        #expect(before.commands.last?.phase == .held && before.commands.last?.request == nil)
        let db = try SQLiteConnection(url: f.url)
        try db.execute("CREATE TRIGGER interrupt_child BEFORE UPDATE ON local_library_commands WHEN NEW.id='\(child.intentID.wire)' BEGIN SELECT RAISE(ABORT,'test_interrupt'); END")
        let reply = try response(imported(h.intentID, state: 7, revision: 3), sequence: 1, revision: 1, replayed: true)
        await #expect(throws: (any Error).self) { try await f.store.recordLibraryReceipt(reply, for: attempt) }
        #expect(try await f.store.libraryCommandSnapshot(scope: f.scope) == before)
        try db.execute("DROP TRIGGER interrupt_child")
        let saved = try await f.store.recordLibraryReceipt(reply, for: attempt)
        let successor = try #require(saved.commands.first { $0.handle == child })
        #expect(successor.mutation == .cancelImport(importID: h.intentID, expectedRevision: 1))
        #expect(successor.phase == .prepared && successor.request != nil)
        let reopened = try f.reopen(), next = try await reopened.beginLibraryAttempt(child, scope: f.scope)
        #expect(next.request == successor.request)
        let bad = try response(imported(h.intentID, state: 8, revision: 3), sequence: nil, revision: 3)
        #expect(try await reopened.recordLibraryReceipt(bad, for: next).commands.last?.receipt?.result.status == .revisionConflict)
    }

    @Test func membershipReversalUsesOwnAppliedRevisionAndConflictCannotAuthorizeSuccessor() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let doc = UUID(), itemID = UUID()
        let h = try await f.store.enqueueLibraryCommand(scope: f.scope,
            mutation: .setMembership(documentID: doc, present: true, expectedRevision: 2, approvalID: UUID()))
        let attempt = try await f.store.beginLibraryAttempt(h, scope: f.scope)
        let child = try await f.store.holdLibrarySuccessor(.setMembership(present: false, approvalID: nil), after: h, scope: f.scope)
        let saved = try await f.store.recordLibraryReceipt(response(item(itemID, document: doc, state: 8, revision: 5), sequence: 3, revision: 3), for: attempt)
        let next = try #require(saved.commands.first { $0.handle == child })
        guard case .setMembership(let target, let present, let revision, _) = next.mutation else { Issue.record("Expected frozen membership reversal"); return }
        #expect(target == doc && !present && revision == 3)
        let secondDoc = UUID(), second = try await f.store.enqueueLibraryCommand(scope: f.scope,
            mutation: .setMembership(documentID: secondDoc, present: true, expectedRevision: 1, approvalID: UUID()))
        let secondAttempt = try await f.store.beginLibraryAttempt(second, scope: f.scope)
        let blocked = try await f.store.holdLibrarySuccessor(.setMembership(present: false, approvalID: nil), after: second, scope: f.scope)
        let conflict = try response(item(UUID(), document: secondDoc, state: 8, revision: 7), sequence: nil, revision: 7)
        let conflicted = try await f.store.recordLibraryReceipt(conflict, for: secondAttempt)
        #expect(conflicted.commands.first { $0.handle == blocked }?.phase == .needsReview)
        #expect(conflicted.commands.first { $0.handle == blocked }?.request == nil)
    }

    /// Migration 020: archive is an item command on the membership revision; its undo freezes at the applied revision.
    @Test func archiveEncodesValidatesReceiptsAndReversesLikeMembership() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let doc = UUID(), itemID = UUID()
        let request = try LibraryMutation.setArchived(documentID: doc, archived: true, expectedRevision: 4).request(operationID: UUID(), scope: f.scope)
        #expect(request.endpoint == "v2_set_item_archived")
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["p_document_id"] as? String == doc.wire && body["p_archived"] as? Bool == true && body["p_expected_revision"] as? Int == 4)
        #expect(throws: LibraryCommandError.invalidMutation) {
            _ = try LibraryMutation.setArchived(documentID: doc, archived: true, expectedRevision: 0).request(operationID: UUID(), scope: f.scope)
        }
        let h = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: .setArchived(documentID: doc, archived: true, expectedRevision: 4))
        // One lane per paper: a Remove of the same paper waits behind the archive.
        await #expect(throws: LibraryCommandError.targetBusy) {
            _ = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: .setMembership(documentID: doc, present: false, expectedRevision: 4, approvalID: nil))
        }
        let attempt = try await f.store.beginLibraryAttempt(h, scope: f.scope)
        let undo = try await f.store.holdLibrarySuccessor(.setArchived(archived: false), after: h, scope: f.scope)
        var archived = item(itemID, document: doc, state: 9, revision: 5); archived["archived"] = true
        await #expect(throws: (any Error).self) {
            try await f.store.recordLibraryReceipt(response(imported(UUID()), sequence: 9, revision: 5), for: attempt)
        }
        let saved = try await f.store.recordLibraryReceipt(response(archived, sequence: 9, revision: 5), for: attempt)
        let next = try #require(saved.commands.first { $0.handle == undo })
        guard case .setArchived(let target, let value, let revision) = next.mutation else { Issue.record("Expected a frozen unarchive"); return }
        #expect(target == doc && !value && revision == 5)
    }

    @Test func mismatchedTargetsRevisionsAndReceiptsCannotAcknowledgeCommands() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let h = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin())
        let attempt = try await f.store.beginLibraryAttempt(h, scope: f.scope)
        let before = try await f.store.libraryCommandSnapshot(scope: f.scope)
        let wrongID = try response(imported(UUID()))
        let wrongSource = try response(imported(h.intentID, source: "2601.00002"))
        let wrongRevision = try response(imported(h.intentID, state: 2, revision: 2), sequence: 2, revision: 2)
        for bad in [wrongID, wrongSource, wrongRevision] {
            await #expect(throws: LibraryCommandError.invalidReceipt) { try await f.store.recordLibraryReceipt(bad, for: attempt) }
        }
        #expect(try await f.store.libraryCommandSnapshot(scope: f.scope) == before)
        let saved = try await f.store.recordLibraryReceipt(response(imported(h.intentID)), for: attempt)
        await #expect(throws: LibraryCommandError.invalidReceipt) {
            try await f.store.recordLibraryReceipt(response(imported(h.intentID, state: 2), sequence: 2), for: attempt)
        }
        #expect(try await f.store.libraryCommandSnapshot(scope: f.scope) == saved)
        let proof = try observation(account: f.account, rows: [imported(h.intentID)], cursor: 1)
        await #expect(throws: LibraryCommandError.staleHandle) {
            try await f.store.reconcileLibraryCommands([.init(handle: h, receiptID: UUID())], observation: proof, scope: f.scope)
        }
    }

    @Test func fullQueueReservesReversalAndFailureStatusWithoutEvictingRequests() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        var handles: [LocalLibraryCommandHandle] = []
        for n in 1...64 {
            handles.append(try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin(String(format: "2601.%05d", n))))
        }
        let before = try await f.store.libraryCommandSnapshot(scope: f.scope)
        await #expect(throws: LibraryCommandError.capacityExceeded) { try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin("2601.99999")) }
        #expect(try await f.store.libraryCommandSnapshot(scope: f.scope) == before)
        for handle in handles { _ = try await f.store.holdLibrarySuccessor(.cancelImport, after: handle, scope: f.scope) }
        let attempt = try await f.store.beginLibraryAttempt(handles[0], scope: f.scope)
        let failed = try await f.store.recordLibraryFailure(.capacity, for: attempt)
        #expect(failed.commands.count == 128 && failed.commands[0].failure == .capacity && failed.commands[0].everSubmitted)
        #expect(try await f.store.beginLibraryAttempt(handles[0], scope: f.scope).request == attempt.request)
    }

    @Test func onlyUnissuedActionsMayBeDiscardedAndPrunedHandlesNeverUpsert() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let h = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin())
        let child = try await f.store.holdLibrarySuccessor(.cancelImport, after: h, scope: f.scope)
        let discarded = try await f.store.discardUnissuedLibraryIntent(h, expectedRevision: 1, scope: f.scope)
        #expect(discarded.commands.allSatisfy { $0.phase == .cancelled })
        #expect(try await f.store.pruneLibraryCommands(scope: f.scope).commands.isEmpty)
        await #expect(throws: LibraryCommandError.staleHandle) { try await f.store.beginLibraryAttempt(child, scope: f.scope) }
        let new = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin())
        #expect(new.localSequence > child.localSequence && new.intentID != h.intentID)
        let attempt = try await f.store.beginLibraryAttempt(new, scope: f.scope)
        let row = try await f.store.libraryCommandSnapshot(scope: f.scope).commands[0]
        await #expect(throws: LibraryCommandError.invalidTransition) {
            try await f.store.discardUnissuedLibraryIntent(new, expectedRevision: row.revision, scope: f.scope)
        }
        _ = try await f.store.recordLibraryFailure(.operationConflict, for: attempt)
        await #expect(throws: LibraryCommandError.invalidTransition) { try await f.store.beginLibraryAttempt(new, scope: f.scope) }
    }

    @Test func preparedAttemptFailureDoesNotAuthorizeNetworkOrChangeMemory() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let h = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin())
        let before = try await f.store.libraryCommandSnapshot(scope: f.scope), db = try SQLiteConnection(url: f.url)
        try db.execute("CREATE TRIGGER reject_attempt BEFORE UPDATE ON metadata BEGIN SELECT RAISE(ABORT,'synthetic_write_failure'); END")
        await #expect(throws: (any Error).self) { try await f.store.beginLibraryAttempt(h, scope: f.scope) }
        #expect(try await f.store.libraryCommandSnapshot(scope: f.scope) == before)
        try db.execute("DROP TRIGGER reject_attempt")
        #expect(try await f.reopen().libraryCommandSnapshot(scope: f.scope).commands[0].everSubmitted == false)
    }

    @Test(arguments: ["delete", "substitute", "rollback"])
    func commandManifestTamperingNeverBecomesAnEmptyQueue(change: String) async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let h = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin()), db = try SQLiteConnection(url: f.url)
        let first = try raw(db, table: "local_library_commands", id: h.intentID.wire)
        _ = try await f.store.beginLibraryAttempt(h, scope: f.scope)
        switch change {
        case "delete": try db.update("DELETE FROM local_library_commands WHERE id=?", values: [.text(h.intentID.wire)])
        case "substitute": try db.update("UPDATE local_library_commands SET sealed=? WHERE id=?", values: [.blob(Data(repeating: 0, count: 64)), .text(h.intentID.wire)])
        default: try db.update("UPDATE local_library_commands SET sealed=? WHERE id=?", values: [.blob(first), .text(h.intentID.wire)])
        }
        #expect(throws: (any Error).self) { try f.reopen() }
    }

    @Test func format4MigrationPreservesHistoryDraftsAndRollsBackTogether() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let event = try await f.store.append(PrivateEvent(kind: .note, text: "Existing private note"), deviceID: f.device)
        let draft = LocalDraft(id: UUID(), revision: 1, textRevision: UUID(), text: "Saved draft", editedAt: Date(), branchRevision: UUID())
        try await f.store.saveDraft(draft)
        let before = await f.store.snapshot(), db = try SQLiteConnection(url: f.url)
        let draftBytes = try raw(db, table: "local_drafts", id: draft.id.wire), oldMetadata = try makeFormat4(f)
        try db.execute("CREATE TRIGGER reject_queue_migration BEFORE UPDATE ON metadata BEGIN SELECT RAISE(ABORT,'synthetic_migration_failure'); END")
        #expect(throws: (any Error).self) { try f.reopen() }
        #expect(try raw(db, table: "metadata") == oldMetadata)
        let tableCount = try db.statement("SELECT count(*) FROM sqlite_master WHERE name='local_library_commands'") { statement in
            _ = sqlite3_step(statement); return sqlite3_column_int(statement, 0)
        }
        #expect(tableCount == 0)
        try db.execute("DROP TRIGGER reject_queue_migration")
        let migrated = try f.reopen(), snapshot = await migrated.snapshot()
        #expect(snapshot.state == before.state && snapshot.drafts == [draft] && snapshot.generation == before.generation + 1)
        #expect(await migrated.pending() == [event])
        #expect(try raw(db, table: "local_drafts", id: draft.id.wire) == draftBytes)
        #expect(try await migrated.libraryCommandSnapshot(scope: f.scope).commands.isEmpty)
        await #expect(throws: ReaderError.storeChanged) { try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin()) }
    }

    @Test func completeObservationCannotBeMintedFromPartialOrAheadState() throws {
        var reconciler = LibraryReconciler(accountID: UUID())
        #expect(throws: LibraryCommandError.incompleteObservation) { try reconciler.completeObservation() }
        _ = try reconciler.nextRequest()
        #expect(throws: LibraryCommandError.incompleteObservation) { try reconciler.completeObservation() }
        #expect(throws: LibraryCommandError.incompleteObservation) {
            try observation(account: UUID(), rows: [imported(UUID(), state: 9)], cursor: 2)
        }
        var mapped = imported(UUID(), state: 2, phase: "cancelled")
        mapped["document_id"] = UUID().wire; mapped["library_item_id"] = UUID().wire
        #expect(throws: LibraryCommandError.incompleteObservation) {
            try observation(account: UUID(), rows: [mapped], cursor: 2)
        }
    }

    @Test func zeroSequenceConflictNeedsOwnedCompleteObservationAndNewUserAction() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let empty = try observation(account: f.account, rows: [], cursor: 0)
        #expect(try await f.store.reconcileLibraryCommands([], observation: empty, scope: f.scope).commands.isEmpty)
        let handle = try await f.store.enqueueLibraryCommand(scope: f.scope,
            mutation: .setMembership(documentID: UUID(), present: false, expectedRevision: 1, approvalID: nil))
        let attempt = try await f.store.beginLibraryAttempt(handle, scope: f.scope)
        let row = try await f.store.recordLibraryReceipt(response(nil, sequence: nil, revision: 0), for: attempt).commands[0]
        let receipt = try #require(row.receipt)
        #expect(receipt.requiredCursor == 0 && receipt.result.id == nil)
        let ref = LibraryCommandReconciliation(handle: handle, receiptID: receipt.id)
        let foreign = try observation(account: UUID(), rows: [], cursor: 0)
        await #expect(throws: ReaderError.wrongAccount) {
            try await f.store.reconcileLibraryCommands([ref], observation: foreign, scope: f.scope)
        }
        let review = try await f.store.reconcileLibraryCommands([ref], observation: empty, scope: f.scope).commands[0]
        #expect(review.phase == .needsReview)
        _ = try await f.store.dismissLibraryCommand(handle, expectedRevision: review.revision, scope: f.scope)
        #expect(try await f.store.pruneLibraryCommands(scope: f.scope).commands.isEmpty)
        await #expect(throws: LibraryCommandError.staleHandle) {
            try await f.store.recordLibraryReceipt(response(nil, sequence: nil, revision: 0), for: attempt)
        }
    }

    @Test func keyRotationAndUnrelatedDraftWritesDoNotChangeFrozenRequestOrAttemptOwnership() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let handle = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin(cursor: 12))
        let first = try await f.store.beginLibraryAttempt(handle, scope: f.scope)
        var keys = f.keys; try keys.rotate(); try await f.store.updateKeys(keys)
        try await f.store.saveDraft(LocalDraft(id: UUID(), revision: 1, textRevision: UUID(), text: "Independent private draft", editedAt: Date(), branchRevision: UUID()))
        _ = try await f.store.recordLibraryFailure(.authentication, for: first)
        let second = try await f.store.beginLibraryAttempt(handle, scope: f.scope)
        #expect(second.request == first.request && second.attemptID != first.attemptID)
        await #expect(throws: LibraryCommandError.staleAttempt) { try await f.store.recordLibraryFailure(.connection, for: first) }
        let result = try await f.store.recordLibraryReceipt(response(imported(handle.intentID, state: 13), sequence: 13), for: second)
        #expect(result.commands[0].request == first.request && result.commands[0].receipt?.requiredCursor == 13)
        #expect(await f.store.snapshot().drafts.count == 1)
        #expect(await f.store.pending().isEmpty)
    }

    @Test func changedArgumentsOversizedHintsAndStaleDiscardLeaveAcceptedIntentUntouched() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let handle = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin(cursor: 1))
        let before = try await f.store.libraryCommandSnapshot(scope: f.scope)
        await #expect(throws: LibraryCommandError.targetBusy) {
            try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin(cursor: 2))
        }
        await #expect(throws: LibraryCommandError.invalidMutation) {
            try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin("2601.00002"), display: String(repeating: "x", count: 1_025))
        }
        await #expect(throws: LibraryCommandError.staleHandle) {
            try await f.store.discardUnissuedLibraryIntent(handle, expectedRevision: 2, scope: f.scope)
        }
        #expect(try await f.store.libraryCommandSnapshot(scope: f.scope) == before)
    }

    @Test func failedLocalAcknowledgementCanRetryWithoutRestartOrChangedOperation() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let h = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin())
        let first = try await f.store.beginLibraryAttempt(h, scope: f.scope)
        let db = try SQLiteConnection(url: f.url)
        try db.execute("CREATE TRIGGER reject_ack BEFORE UPDATE ON metadata BEGIN SELECT RAISE(ABORT,'synthetic_ack_failure'); END")
        let reply = try response(imported(h.intentID))
        await #expect(throws: (any Error).self) { try await f.store.recordLibraryReceipt(reply, for: first) }
        await #expect(throws: (any Error).self) { try await f.store.recordLibraryFailure(.suspended, for: first) }
        try db.execute("DROP TRIGGER reject_ack")
        let next = try await f.store.beginLibraryAttempt(h, scope: f.scope)
        #expect(next.request == first.request && next.attemptID != first.attemptID)
        await #expect(throws: LibraryCommandError.staleAttempt) { try await f.store.recordLibraryReceipt(reply, for: first) }
        #expect(try await f.store.recordLibraryReceipt(reply, for: next).commands[0].receipt != nil)
    }

    @Test(arguments: [false, true])
    func cancelDecidesAtomicallyWhenAttemptWinsOrLosesTheRace(issuedFirst: Bool) async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let handle = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin())
        if issuedFirst { _ = try await f.store.beginLibraryAttempt(handle, scope: f.scope) }
        let cancelled = try await f.store.cancelLibraryCommand(handle, scope: f.scope)
        if issuedFirst {
            #expect(cancelled.commands[0].everSubmitted && cancelled.commands[0].phase == .submittedUnknown)
            #expect(cancelled.commands.count == 2 && cancelled.commands[1].phase == .held)
        } else {
            #expect(cancelled.commands.count == 1 && cancelled.commands[0].phase == .cancelled)
            await #expect(throws: LibraryCommandError.invalidTransition) { try await f.store.beginLibraryAttempt(handle, scope: f.scope) }
        }
    }

    @Test func cancelAfterCatchupUsesRetainedReceiptButNeverRecreatesPrunedIdentity() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let handle = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin())
        let attempt = try await f.store.beginLibraryAttempt(handle, scope: f.scope)
        let row = try await f.store.recordLibraryReceipt(response(imported(handle.intentID)), for: attempt).commands[0]
        let proof = try observation(account: f.account, rows: [imported(handle.intentID)], cursor: 1)
        _ = try await f.store.reconcileLibraryCommands([.init(handle: handle, receiptID: try #require(row.receipt).id)], observation: proof, scope: f.scope)
        let cancelled = try await f.store.cancelLibraryCommand(handle, scope: f.scope)
        #expect(cancelled.commands[1].mutation == .cancelImport(importID: handle.intentID, expectedRevision: 1))
        #expect(cancelled.commands[1].phase == .prepared)
        _ = try await f.store.pruneLibraryCommands(scope: f.scope)
        await #expect(throws: LibraryCommandError.staleHandle) { try await f.store.cancelLibraryCommand(handle, scope: f.scope) }
        #expect(try await f.store.libraryCommandSnapshot(scope: f.scope).commands.count == 1)
    }

    @Test func snapshotsFenceReplacedWritersButRecoverAfterRolledBackWriteFailure() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let handle = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin())
        let before = try await f.store.libraryCommandSnapshot(scope: f.scope)
        let db = try SQLiteConnection(url: f.url)
        try db.execute("CREATE TRIGGER reject_snapshot_attempt BEFORE UPDATE ON metadata BEGIN SELECT RAISE(ABORT,'synthetic_write_failure'); END")
        await #expect(throws: (any Error).self) { try await f.store.beginLibraryAttempt(handle, scope: f.scope) }
        try db.execute("DROP TRIGGER reject_snapshot_attempt")
        #expect(try await f.store.libraryCommandSnapshot(scope: f.scope) == before)
        let attempt = try await f.store.beginLibraryAttempt(handle, scope: f.scope)
        #expect(attempt.request == before.commands[0].request)

        let current = try f.reopen()
        await #expect(throws: ReaderError.storeChanged) { try await f.store.libraryCommandSnapshot(scope: f.scope) }
        await #expect(throws: ReaderError.storageUnavailable) { try await f.store.libraryCommandSnapshot(scope: f.scope) }
        await #expect(throws: ReaderError.storageUnavailable) { try await f.store.beginLibraryAttempt(handle, scope: f.scope) }
        let restored = try await current.libraryCommandSnapshot(scope: f.scope)
        #expect(restored.commands[0].request == attempt.request && restored.commands[0].everSubmitted)
    }

    @Test func operationConflictAndHeldReversalRemainReviewableWithoutInventingReceipt() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let parent = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: begin())
        let attempt = try await f.store.beginLibraryAttempt(parent, scope: f.scope)
        let child = try await f.store.holdLibrarySuccessor(.cancelImport, after: parent, scope: f.scope)
        let failed = try await f.store.recordLibraryFailure(.operationConflict, for: attempt)
        #expect(failed.commands.count == 2 && failed.commands.allSatisfy { $0.phase == .needsReview && !$0.canAttempt && $0.receipt == nil })
        #expect(failed.commands[0].request == attempt.request && failed.commands[0].everSubmitted)
        #expect(failed.commands[1].request == nil && !failed.commands[1].everSubmitted)
        await #expect(throws: LibraryCommandError.invalidTransition) { try await f.store.holdLibrarySuccessor(.cancelImport, after: parent, scope: f.scope) }
        let restarted = try f.reopen()
        #expect(try await restarted.libraryCommandSnapshot(scope: f.scope).commands == failed.commands)
        for row in failed.commands { _ = try await restarted.dismissLibraryCommand(row.handle, expectedRevision: row.revision, scope: f.scope) }
        #expect(try await restarted.pruneLibraryCommands(scope: f.scope).commands.isEmpty)
        await #expect(throws: LibraryCommandError.staleHandle) { try await restarted.beginLibraryAttempt(child, scope: f.scope) }
        let fresh = try await restarted.enqueueLibraryCommand(scope: f.scope, mutation: begin())
        #expect(fresh.intentID != parent.intentID && fresh.localSequence > child.localSequence)
    }
}
