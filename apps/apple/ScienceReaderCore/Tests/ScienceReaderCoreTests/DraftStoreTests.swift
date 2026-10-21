import CSQLite
import CryptoKit
import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct DraftStoreTests {
    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        let account = UUID(), device = UUID(), localKey = ReaderCrypto.randomKey()
        let keys: KeyBundle
        let store: EncryptedStore
        var url: URL { directory.appendingPathComponent("state.sqlite") }

        init() throws {
            keys = KeyBundle.generate(accountID: account)
            store = try EncryptedStore(url: directory.appendingPathComponent("state.sqlite"), accountID: account, localKey: localKey, keys: keys)
        }
        func reopen(keys: KeyBundle? = nil) throws -> EncryptedStore {
            try EncryptedStore(url: url, accountID: account, localKey: localKey, keys: keys ?? self.keys)
        }
    }

    private func draft(_ text: String = "A private question", documentID: UUID? = nil) -> LocalDraft {
        LocalDraft(id: UUID(), documentID: documentID, revision: 1, textRevision: UUID(), text: text,
                   editedAt: Date(timeIntervalSince1970: 1_700_000_000), branchRevision: UUID())
    }

    private func changed(_ draft: LocalDraft, text: String) -> LocalDraft {
        var result = draft
        result.revision += 1; result.textRevision = UUID(); result.text = text
        result.editedAt += 1
        return result
    }

    private func submission(_ draft: LocalDraft) -> (events: [(id: UUID, event: PrivateEvent)], consumption: DraftConsumption) {
        let conversation = draft.conversationID ?? UUID(), message = UUID()
        var events: [(id: UUID, event: PrivateEvent)] = [], parents = draft.selectedHead.map { [$0] } ?? []
        if draft.conversationID == nil {
            let root = UUID()
            events.append((root, PrivateEvent(kind: .conversation, entityID: conversation, documentID: draft.documentID, text: "Private conversation")))
            parents = [root]
        }
        events.append((message, PrivateEvent(kind: .message, entityID: message, parents: parents,
                                            conversationID: conversation, documentID: draft.documentID,
                                            text: draft.text.trimmingCharacters(in: .whitespacesAndNewlines), role: .user, status: .complete)))
        return (events, DraftConsumption(draft: draft, submissionID: message))
    }

    private func rawDraft(_ id: UUID, in database: SQLiteConnection) throws -> Data {
        try database.statement("SELECT sealed FROM local_drafts WHERE id=?", values: [.text(id.wire)]) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw ReaderError.corruptData }
            return try SQLiteConnection.blob(statement, 0)
        }
    }

    private func afterReopen(_ value: LocalStoreSnapshot) -> LocalStoreSnapshot {
        .init(state: value.state, generation: value.generation + 1, pendingCount: value.pendingCount, drafts: value.drafts,
              pendingEventIDs: value.pendingEventIDs, pendingNoteBlobs: value.pendingNoteBlobs, noteDestination: value.noteDestination)
    }

    private func makeLegacy(_ fixture: Fixture, format: Int) throws -> Data {
        let database = try SQLiteConnection(url: fixture.url)
        let aad = Data("science-reader/local-metadata/v2/\(fixture.account.wire)".utf8)
        let key = SymmetricKey(data: fixture.localKey)
        let current = try database.statement("SELECT sealed FROM metadata WHERE id=1") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw ReaderError.corruptData }
            return try SQLiteConnection.blob(statement, 0)
        }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: current), using: key, authenticating: aad)
        var fields = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        fields["format"] = format; fields.removeValue(forKey: "drafts")
        fields.removeValue(forKey: "libraryCommands"); fields.removeValue(forKey: "libraryCommandSequence")
        fields.removeValue(forKey: "libraryCommandScope"); fields.removeValue(forKey: "offlineCache")
        fields.removeValue(forKey: "noteUploads"); fields.removeValue(forKey: "noteHolds")
        let sealed = try #require(AES.GCM.seal(JSONSerialization.data(withJSONObject: fields), using: key, authenticating: aad).combined)
        try database.execute("BEGIN IMMEDIATE; DROP TABLE local_note_blobs; DROP TABLE local_reader_bundle_members; DROP TABLE local_reader_bundle_headers; DROP TABLE local_reader_bundle_index; DROP TABLE local_library_cache_entries; DROP TABLE local_library_cache_checkpoint; DROP TABLE local_drafts; DROP TABLE local_library_commands; PRAGMA user_version=2")
        try database.update("UPDATE metadata SET sealed=? WHERE id=1", values: [.blob(sealed)])
        try database.execute("COMMIT")
        return sealed
    }

    @Test func checkpointsSurviveRestartEncryptedAndRemainAccountScoped() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let general = draft("SECRET-GENERAL-DRAFT"), paper = draft("SECRET-PAPER-DRAFT", documentID: UUID())
        try await fixture.store.saveDraft(general)
        try await fixture.store.saveDraft(paper)
        let before = await fixture.store.snapshot()
        #expect(before.generation == 2 && before.pendingCount == 0 && before.state.events.isEmpty)
        let reopened = try fixture.reopen()
        #expect(await reopened.snapshot() == afterReopen(before))
        #expect(Set(before.drafts.map(\.id)) == [general.id, paper.id])
        for file in try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: file)
            #expect(bytes.range(of: Data("SECRET-GENERAL-DRAFT".utf8)) == nil)
            #expect(bytes.range(of: Data("SECRET-PAPER-DRAFT".utf8)) == nil)
        }
        let other = UUID()
        #expect(throws: (any Error).self) {
            try EncryptedStore(url: fixture.url, accountID: other, localKey: fixture.localKey, keys: KeyBundle.generate(accountID: other))
        }
        #expect(throws: (any Error).self) {
            try EncryptedStore(url: fixture.url, accountID: fixture.account, localKey: ReaderCrypto.randomKey(), keys: fixture.keys)
        }
    }

    @Test func reverseAutosavesAndConflictingEqualRevisionsCannotReplaceNewestText() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = draft(), latest = changed(first, text: "Newer edit")
        #expect(try await fixture.store.saveDraft(latest) == latest)
        let committed = await fixture.store.snapshot()
        #expect(try await fixture.store.saveDraft(first) == latest)
        #expect(try await fixture.store.saveDraft(latest) == latest)
        var conflict = latest; conflict.text = "Same revision, different text"
        await #expect(throws: ReaderError.eventConflict) { try await fixture.store.saveDraft(conflict) }
        #expect(await fixture.store.snapshot() == committed)
        #expect(try await fixture.reopen().snapshot() == afterReopen(committed))
    }

    @Test func sendAndConsumptionCommitTogetherAndExactRetriesDoNotDuplicate() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let captured = draft("  Send this once.\n"), turn = submission(captured)
        try await fixture.store.saveDraft(captured)
        let saved = try await fixture.store.commitDraftSubmission(turn.events, deviceID: fixture.device, consuming: turn.consumption)
        #expect(saved.draft.text.isEmpty)
        #expect(saved.draft.conversationID == turn.events.last?.event.conversationID)
        #expect(saved.draft.selectedHead == turn.consumption.submissionID)
        #expect(saved.draft.acknowledgedSubmissionID == saved.receiptID)
        let committed = await fixture.store.snapshot()
        #expect(committed.state.events.count == 2 && committed.pendingCount == 2 && committed.drafts.isEmpty)
        #expect(try await fixture.store.commitDraftSubmission(turn.events, deviceID: fixture.device, consuming: turn.consumption) == saved)
        #expect(try await fixture.store.saveDraft(captured) == saved.draft)
        #expect(await fixture.store.snapshot() == committed)
        let duplicated = submission(captured)
        await #expect(throws: ReaderError.eventConflict) {
            try await fixture.store.commitDraftSubmission(duplicated.events, deviceID: fixture.device, consuming: duplicated.consumption)
        }
        let reopened = try fixture.reopen()
        let recovered = await reopened.snapshot()
        #expect(recovered.state == committed.state && recovered.pendingCount == 2 && recovered.drafts.isEmpty)
        #expect(recovered.generation == committed.generation + 1) // Fresh-owner receipt collection.
    }

    @Test(arguments: ["record", "draft"])
    func interruptedSubmissionKeepsDraftWithoutAnOrphanConversation(stage: String) async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let captured = draft(), turn = submission(captured)
        try await fixture.store.saveDraft(captured)
        let before = await fixture.store.snapshot(), database = try SQLiteConnection(url: fixture.url)
        if stage == "record" {
            try database.execute("CREATE TRIGGER interrupt_draft_send BEFORE INSERT ON records WHEN NEW.ordinal=2 BEGIN SELECT RAISE(ABORT,'synthetic_failure'); END")
        } else {
            try database.execute("CREATE TRIGGER interrupt_draft_send BEFORE UPDATE ON local_drafts BEGIN SELECT RAISE(ABORT,'synthetic_failure'); END")
        }
        await #expect(throws: (any Error).self) {
            try await fixture.store.commitDraftSubmission(turn.events, deviceID: fixture.device, consuming: turn.consumption)
        }
        #expect(await fixture.store.snapshot() == before)
        let reopened = try fixture.reopen()
        #expect(await reopened.snapshot() == afterReopen(before))
        try database.execute("DROP TRIGGER interrupt_draft_send")
        let saved = try await reopened.commitDraftSubmission(turn.events, deviceID: fixture.device, consuming: turn.consumption)
        #expect(saved.draft.text.isEmpty && saved.envelopes.count == 2)
    }

    @Test(arguments: [false, true])
    func newerTextSurvivesEitherCheckpointOrderAndBindsToSavedConversation(checkpointFirst: Bool) async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let captured = draft(), next = changed(captured, text: "Next question while saving"), turn = submission(captured)
        try await fixture.store.saveDraft(captured)
        if checkpointFirst { try await fixture.store.saveDraft(next) }
        let saved = try await fixture.store.commitDraftSubmission(turn.events, deviceID: fixture.device, consuming: turn.consumption)
        if !checkpointFirst { try await fixture.store.saveDraft(next) }
        let restored = try #require(try await fixture.reopen().snapshot().drafts.first)
        #expect(restored.id == next.id && restored.text == next.text && restored.textRevision == next.textRevision)
        #expect(restored.conversationID == saved.draft.conversationID)
        #expect(restored.selectedHead == turn.consumption.submissionID)
        let followup = submission(restored)
        let current = try fixture.reopen()
        _ = try await current.commitDraftSubmission(followup.events, deviceID: fixture.device, consuming: followup.consumption)
        #expect(await current.state().events.count == 3)
        #expect(await current.snapshot().drafts.isEmpty)
    }

    @Test func identicalTextAfterAnEditIsNotMistakenForConsumedText() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let captured = draft(), edited = changed(changed(captured, text: "Different"), text: captured.text), turn = submission(captured)
        try await fixture.store.saveDraft(edited)
        _ = try await fixture.store.commitDraftSubmission(turn.events, deviceID: fixture.device, consuming: turn.consumption)
        let restored = try #require(try await fixture.reopen().snapshot().drafts.first)
        #expect(restored.text == captured.text && restored.textRevision == edited.textRevision)
    }

    @Test func lateCheckpointCannotUndoReceiptButAcknowledgedAutomaticHeadsAdvance() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let captured = draft(), turn = submission(captured)
        let saved = try await fixture.store.commitDraftSubmission(turn.events, deviceID: fixture.device, consuming: turn.consumption)
        var late = captured; late.revision += 1
        let normalized = try await fixture.store.saveDraft(late)
        #expect(normalized.text.isEmpty && normalized.selectedHead == saved.receiptID)
        let conversation = try #require(saved.draft.conversationID)
        let assistant = try await fixture.store.append(PrivateEvent(kind: .message, parents: [saved.receiptID], conversationID: conversation,
                                                                    text: "A durable assistant reply", role: .assistant, status: .complete), deviceID: fixture.device)
        var followup = changed(normalized, text: "Continue this branch")
        followup.selectedHead = assistant.id; followup.acknowledgedSubmissionID = saved.receiptID
        #expect(try await fixture.store.saveDraft(followup).selectedHead == assistant.id)
        var unknownAcknowledgment = followup
        unknownAcknowledgment.revision += 1; unknownAcknowledgment.acknowledgedSubmissionID = UUID()
        unknownAcknowledgment.selectedHead = turn.events[0].id
        #expect(try await fixture.store.saveDraft(unknownAcknowledgment).selectedHead == assistant.id)
        let restored = try #require(try await fixture.reopen().snapshot().drafts.first)
        #expect(restored.selectedHead == assistant.id && restored.text == followup.text)
    }

    @Test func explicitBranchChoiceDuringSendSurvivesCompletionAndRestart() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = draft(), initial = submission(first)
        let saved = try await fixture.store.commitDraftSubmission(initial.events, deviceID: fixture.device, consuming: initial.consumption)
        let followup = changed(saved.draft, text: "A follow-up"), turn = submission(followup)
        try await fixture.store.saveDraft(followup)
        var switched = changed(followup, text: "Draft for the other branch")
        switched.branchRevision = UUID(); switched.selectedHead = initial.events[0].id
        try await fixture.store.saveDraft(switched)
        let result = try await fixture.store.commitDraftSubmission(turn.events, deviceID: fixture.device, consuming: turn.consumption)
        #expect(result.draft.selectedHead == switched.selectedHead && result.draft.text == switched.text)
        let restored = try #require(try await fixture.reopen().snapshot().drafts.first)
        #expect(restored.selectedHead == switched.selectedHead && restored.branchRevision == switched.branchRevision)
    }

    @Test func discardRejectsStaleOwnershipAndFencesLateCheckpointsUntilFreshOwner() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = draft(), newer = changed(first, text: "Do not delete this edit")
        try await fixture.store.saveDraft(newer)
        let before = await fixture.store.snapshot()
        await #expect(throws: ReaderError.eventConflict) { try await fixture.store.discardDraft(id: first.id, revision: first.revision) }
        #expect(await fixture.store.snapshot() == before)
        try await fixture.store.discardDraft(id: newer.id, revision: newer.revision)
        try await fixture.store.discardDraft(id: newer.id, revision: newer.revision)
        await #expect(throws: ReaderError.eventConflict) { try await fixture.store.saveDraft(first) }
        await #expect(throws: ReaderError.eventConflict) { try await fixture.store.saveDraft(changed(newer, text: "Late callback")) }
        let beforeCleanup = await fixture.store.snapshot()
        let reopened = try fixture.reopen()
        #expect(await reopened.snapshot().drafts.isEmpty)
        #expect(await reopened.snapshot().generation == beforeCleanup.generation + 1)
        await #expect(throws: ReaderError.storeChanged) { try await fixture.store.saveDraft(draft("Old owner cannot write after cleanup")) }
        let notYetSaved = draft()
        try await reopened.discardDraft(id: notYetSaved.id, revision: notYetSaved.revision)
        await #expect(throws: ReaderError.eventConflict) { try await reopened.saveDraft(notYetSaved) }
    }

    @Test func rebasingPreservesDraftBranchesReceiptsAndExactSendRetries() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let captured = draft(), turn = submission(captured)
        let saved = try await fixture.store.commitDraftSubmission(turn.events, deviceID: fixture.device, consuming: turn.consumption)
        let followup = changed(saved.draft, text: "Still on this branch")
        try await fixture.store.saveDraft(followup)
        var keys = fixture.keys; try keys.rotate()
        try await fixture.store.updateKeys(keys)
        let mapping = try await fixture.store.rebasePendingAfterCatchUp(deviceID: UUID(), verifiedEpoch: keys.epoch, cursor: 0)
        let reopened = try fixture.reopen(keys: keys)
        let restored = try #require(await reopened.snapshot().drafts.first)
        #expect(restored.selectedHead == mapping[saved.receiptID])
        #expect(restored.acknowledgedSubmissionID == saved.receiptID)
        let retried = try await reopened.commitDraftSubmission(turn.events, deviceID: fixture.device, consuming: turn.consumption)
        #expect(retried.envelopes.map(\.id) == turn.events.map { mapping[$0.id]! })
        #expect(retried.draft.text == followup.text)
        #expect(await reopened.state().events.count == 2)
        try await reopened.saveDraft(changed(restored, text: "Edit after rotation"))
    }

    @Test(arguments: ["delete", "substitute", "rollback"])
    func corruptedDraftManifestNeverBecomesAnEmptyStore(change: String) async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = draft(), other = draft("Other draft")
        try await fixture.store.saveDraft(first)
        try await fixture.store.saveDraft(other)
        let database = try SQLiteConnection(url: fixture.url), old = try rawDraft(first.id, in: database)
        try await fixture.store.saveDraft(changed(first, text: "Newest private text"))
        switch change {
        case "delete": try database.update("DELETE FROM local_drafts WHERE id=?", values: [.text(first.id.wire)])
        case "substitute": try database.update("UPDATE local_drafts SET sealed=? WHERE id=?", values: [.blob(rawDraft(other.id, in: database)), .text(first.id.wire)])
        default: try database.update("UPDATE local_drafts SET sealed=? WHERE id=?", values: [.blob(old), .text(first.id.wire)])
        }
        #expect(throws: (any Error).self) { try fixture.reopen() }
    }

    @Test func invalidScopeAndCapacityFailuresKeepTheCommittedCheckpoint() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var last = draft()
        for index in 0..<128 { last = draft("Unsent \(index)"); try await fixture.store.saveDraft(last) }
        let before = await fixture.store.snapshot()
        await #expect(throws: ReaderError.localCapacityExceeded) { try await fixture.store.saveDraft(draft("Over capacity")) }
        var oversized = changed(last, text: String(repeating: "x", count: 200_001))
        await #expect(throws: ReaderError.invalidEvent) { try await fixture.store.saveDraft(oversized) }
        oversized.text = "Private"; oversized.selectedHead = UUID()
        await #expect(throws: ReaderError.invalidEvent) { try await fixture.store.saveDraft(oversized) }
        #expect(await fixture.store.snapshot() == before)
        let reopened = try fixture.reopen()
        #expect(await reopened.snapshot() == afterReopen(before))
        let replacement = changed(last, text: "Editing an existing draft still works at capacity")
        #expect(try await reopened.saveDraft(replacement) == replacement)
    }

    @Test func totalCiphertextAndSingleRowBoundsNeverTruncateDrafts() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for _ in 0..<41 { try await fixture.store.saveDraft(draft(String(repeating: "x", count: 200_000))) }
        let before = await fixture.store.snapshot()
        await #expect(throws: ReaderError.localCapacityExceeded) {
            try await fixture.store.saveDraft(draft(String(repeating: "y", count: 200_000)))
        }
        // Encoding size is independently bounded, including JSON escapes.
        await #expect(throws: ReaderError.localCapacityExceeded) {
            try await fixture.store.saveDraft(draft(String(repeating: "\u{0}", count: 60_000)))
        }
        #expect(await fixture.store.snapshot() == before)
        #expect(try await fixture.reopen().snapshot() == afterReopen(before))
    }

    @Test func emptyCoordinationRowsAreBoundedAndCollectedOnlyByAFreshOwner() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for _ in 0..<1_024 { try await fixture.store.saveDraft(draft("")) }
        let before = await fixture.store.snapshot()
        #expect(before.generation == 1_024 && before.drafts.isEmpty)
        await #expect(throws: ReaderError.localCapacityExceeded) { try await fixture.store.saveDraft(draft("Must stay in memory until space is available")) }
        #expect(await fixture.store.snapshot() == before)
        let reopened = try fixture.reopen()
        #expect(await reopened.snapshot().generation == 1_025)
        let retained = draft("Fresh owner has collected old empty coordination rows")
        try await reopened.saveDraft(retained)
        #expect(await reopened.snapshot().drafts == [retained])
        await #expect(throws: ReaderError.storeChanged) {
            try await fixture.store.append(PrivateEvent(kind: .note, text: "Old owner remains fenced"), deviceID: fixture.device)
        }
    }

    @Test(arguments: [2, 3])
    func legacyFormatMigrationPreservesHistoryOutboxAndExistingCiphertext(format: Int) async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let event = try await fixture.store.append(PrivateEvent(kind: .note, text: "Existing encrypted history"), deviceID: fixture.device)
        let before = await fixture.store.snapshot(), database = try SQLiteConnection(url: fixture.url)
        let recordBefore = try database.statement("SELECT sealed FROM records WHERE ordinal=1") { statement in
            _ = sqlite3_step(statement); return try SQLiteConnection.blob(statement, 0)
        }
        _ = try makeLegacy(fixture, format: format)
        let migrated = try fixture.reopen(), snapshot = await migrated.snapshot()
        #expect(snapshot.state == before.state && snapshot.pendingCount == before.pendingCount)
        #expect(snapshot.generation == before.generation + 1 && snapshot.drafts.isEmpty)
        #expect(await migrated.pending() == [event])
        let recordAfter = try database.statement("SELECT sealed FROM records WHERE ordinal=1") { statement in
            _ = sqlite3_step(statement); return try SQLiteConnection.blob(statement, 0)
        }
        #expect(recordAfter == recordBefore)
        let checkpoint = draft("New format draft")
        try await migrated.saveDraft(checkpoint)
        #expect(try await fixture.reopen().snapshot().drafts == [checkpoint])
        await #expect(throws: ReaderError.storeChanged) { try await fixture.store.saveDraft(draft("Old loaded owner")) }
    }

    @Test func failedMigrationRollsBackSchemaAndUnknownSchemaRemainsUntouched() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.store.append(PrivateEvent(kind: .note, text: "Never reset this history"), deviceID: fixture.device)
        let legacyMetadata = try makeLegacy(fixture, format: 3), database = try SQLiteConnection(url: fixture.url)
        try database.execute("CREATE TRIGGER interrupt_migration BEFORE UPDATE ON metadata BEGIN SELECT RAISE(ABORT,'synthetic_migration_failure'); END")
        #expect(throws: (any Error).self) { try fixture.reopen() }
        let noDraftTable = try database.statement("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='local_drafts'") { statement in
            _ = sqlite3_step(statement); return sqlite3_column_int(statement, 0)
        }
        #expect(noDraftTable == 0)
        let stillLegacy = try database.statement("SELECT sealed FROM metadata WHERE id=1") { statement in
            _ = sqlite3_step(statement); return try SQLiteConnection.blob(statement, 0)
        }
        #expect(stillLegacy == legacyMetadata)
        try database.execute("DROP TRIGGER interrupt_migration")
        let migrated = try fixture.reopen()
        #expect(await migrated.state().events.count == 1)
        try database.execute("PRAGMA user_version=99")
        #expect(throws: ReaderError.unsupportedFormat) { try fixture.reopen() }
        let preserved = try database.statement("PRAGMA user_version") { statement in
            _ = sqlite3_step(statement); return sqlite3_column_int(statement, 0)
        }
        #expect(preserved == 99)
    }

    @Test func deletedConversationRetainsItsUnsentFollowupAcrossRestartButCannotSend() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = draft(documentID: UUID()), turn = submission(first)
        let saved = try await fixture.store.commitDraftSubmission(turn.events, deviceID: fixture.device, consuming: turn.consumption)
        let followup = changed(saved.draft, text: "Keep this text even if the conversation was deleted")
        try await fixture.store.saveDraft(followup)
        let conversation = try #require(followup.conversationID)
        try await fixture.store.append(PrivateEvent(kind: .tombstone, entityID: conversation), deviceID: fixture.device)
        let before = await fixture.store.snapshot(), reopened = try fixture.reopen()
        #expect(await reopened.snapshot() == afterReopen(before))
        #expect(before.drafts == [followup] && before.state.isDeleted(conversation))
        let retry = submission(followup)
        await #expect(throws: ReaderError.invalidEvent) {
            try await reopened.commitDraftSubmission(retry.events, deviceID: fixture.device, consuming: retry.consumption)
        }
        #expect(await reopened.snapshot() == afterReopen(before))
        var headless = changed(followup, text: "Still recoverable without a selected tip")
        headless.selectedHead = nil
        try await reopened.saveDraft(headless)
        #expect(try await fixture.reopen().snapshot().drafts == [headless])
    }

    @Test func draftScopeRequiresARealMatchingRootButPreservesMissingHeadsUntilCatchup() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let conversation = UUID(), paper = UUID()
        let root = try await fixture.store.append(PrivateEvent(kind: .conversation, entityID: conversation, documentID: paper, text: "Paper chat"), deviceID: fixture.device)
        var missingRoot = draft()
        missingRoot.conversationID = UUID()
        await #expect(throws: ReaderError.invalidEvent) { try await fixture.store.saveDraft(missingRoot) }
        var foreignContext = draft()
        foreignContext.conversationID = conversation
        await #expect(throws: ReaderError.invalidEvent) { try await fixture.store.saveDraft(foreignContext) }
        var incomplete = draft("Do not lose a draft while history is incomplete", documentID: paper)
        incomplete.conversationID = conversation; incomplete.selectedHead = UUID()
        try await fixture.store.saveDraft(incomplete)
        let before = await fixture.store.snapshot(), reopened = try fixture.reopen()
        #expect(await reopened.snapshot() == afterReopen(before))
        let pending = submission(incomplete)
        await #expect(throws: ReaderError.invalidEvent) {
            try await reopened.commitDraftSubmission(pending.events, deviceID: fixture.device, consuming: pending.consumption)
        }
        #expect(await reopened.snapshot() == afterReopen(before))
        var ready = changed(incomplete, text: "The first question")
        ready.selectedHead = root.id
        let first = submission(ready)
        let sent = try await reopened.commitDraftSubmission(first.events, deviceID: fixture.device, consuming: first.consumption)
        #expect(sent.envelopes.count == 1 && sent.draft.text.isEmpty)
    }

    @Test(arguments: ["missing", "unrooted", "foreign", "multiple"])
    func incompleteParentCannotConsumeDraftOrAppendAnEvent(kind: String) async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let conversation = UUID(), rootID = UUID(), remoteID = UUID()
        let root = try ReaderCrypto.seal(PrivateEvent(kind: .conversation, entityID: conversation, text: "Remote chat"),
                                         id: rootID, deviceID: UUID(), keys: fixture.keys)
        var events = [root]
        let parents: [UUID]
        switch kind {
        case "missing": parents = [UUID()]
        case "unrooted": parents = []
        case "foreign":
            let foreign = try ReaderCrypto.seal(PrivateEvent(kind: .conversation, text: "Another chat"), id: UUID(), deviceID: UUID(), keys: fixture.keys)
            events.append(foreign); parents = [foreign.id]
        default:
            let branches = try (0..<2).map { index in
                try ReaderCrypto.seal(PrivateEvent(kind: .message, parents: [rootID], conversationID: conversation,
                                                   text: "Branch \(index)", role: .assistant, status: .complete),
                                      id: UUID(), deviceID: UUID(), keys: fixture.keys)
            }
            events += branches; parents = branches.map(\.id)
        }
        events.append(try ReaderCrypto.seal(PrivateEvent(kind: .message, parents: parents, conversationID: conversation,
                                                        text: "An incomplete remote message", role: .assistant, status: .complete),
                                           id: remoteID, deviceID: UUID(), keys: fixture.keys))
        try await fixture.store.ingest(events.enumerated().map { RemoteEvent(cursor: Int64($0.offset + 1), envelope: $0.element, digest: $0.element.sha256) })
        var checkpoint = draft("Preserve my unsent follow-up")
        checkpoint.conversationID = conversation; checkpoint.selectedHead = remoteID
        try await fixture.store.saveDraft(checkpoint)
        let before = await fixture.store.snapshot(), turn = submission(checkpoint)
        await #expect(throws: ReaderError.invalidEvent) {
            try await fixture.store.commitDraftSubmission(turn.events, deviceID: fixture.device, consuming: turn.consumption)
        }
        #expect(await fixture.store.snapshot() == before)
        #expect(try await fixture.reopen().snapshot() == afterReopen(before))
    }
}
