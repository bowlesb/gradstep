import Foundation
import Testing
@testable import ScienceReaderCore

/// Upload-capable (full-v5) library commands, migration 042: the read context a command's
/// preconditions were observed in chooses its endpoint family and dataset epoch.
@Suite struct LibraryV5CommandTests {
    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        let account = UUID(), localKey = ReaderCrypto.randomKey()
        let keys: KeyBundle
        let store: EncryptedStore
        var url: URL { directory.appendingPathComponent("state.sqlite") }
        var scope: LibraryCommandScope { try! .init(accountID: account, deploymentID: "https://v5-commands.supabase.co") }
        init() throws {
            keys = KeyBundle.generate(accountID: account)
            store = try EncryptedStore(url: directory.appendingPathComponent("state.sqlite"), accountID: account, localKey: localKey, keys: keys)
        }
        func reopen() throws -> EncryptedStore { try EncryptedStore(url: url, accountID: account, localKey: localKey, keys: keys) }
    }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func object(_ data: Data) throws -> [String: AnyHashable] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: AnyHashable])
    }
    private func imported(_ id: UUID, state: Int64) -> [String: Any] {
        ["kind": "import", "id": id.wire, "created_seq": state, "state_seq": state, "intent_revision": 1,
         "visible": true, "phase": "accepted", "source": "arxiv", "source_id": "2601.00001",
         "requested_revision": NSNull(), "source_revision": NSNull(), "metadata_id": NSNull(), "version_id": NSNull(),
         "metadata": NSNull(), "metadata_recorded_at": NSNull(), "source_url": "https://arxiv.org/abs/2601.00001",
         "document_id": NSNull(), "library_item_id": NSNull(), "error_code": NSNull(), "retryable": false]
    }
    private func reply(_ id: UUID, sequence: Int64, epoch: UUID?) throws -> LibraryCommandResponse {
        var value: [String: Any] = ["result": ["status": "applied", "kind": "import", "id": id.wire, "seq": sequence, "revision": 1],
                                    "replayed": false, "entry": imported(id, state: sequence)]
        if let epoch { value["dataset_epoch"] = epoch.wire }
        return try LibraryWire.decodeCommand(json(value))
    }
    /// A complete full-v5 observation (baseline then fixed-boundary catch-up) in `epoch`.
    private func observation(_ account: UUID, rows: [[String: Any]], cursor: Int64, epoch: UUID) throws -> LibraryCompleteObservation {
        var reconciler = LibraryReconciler(accountID: account, readContext: .uploadFull5(datasetEpoch: epoch))
        let next: Any = rows.last.map {
            ["format": 2, "account_id": account.wire, "through": cursor, "created_seq": $0["created_seq"]!, "id": $0["id"]!,
             "kind": $0["kind"]!, "read_level": 4, "dataset_epoch": epoch.wire] as [String: Any]
        } ?? NSNull()
        try reconciler.accept(LibraryWire.decodeBaseline(json(["format": 2, "account_id": account.wire, "baseline_cursor": cursor,
            "retained_after": 0, "entries": rows, "next_cursor": next, "has_more": false, "dataset_epoch": epoch.wire])),
            for: reconciler.nextRequest())
        try reconciler.accept(LibraryWire.decodeChanges(json(["format": 2, "account_id": account.wire, "through": cursor,
            "retained_after": 0, "changes": [], "next_cursor": cursor, "has_more": false, "dataset_epoch": epoch.wire])),
            for: reconciler.nextRequest())
        return try reconciler.completeObservation()
    }

    @Test func legacyBytesAreUnchangedAndV5AddsOnlyTheDatasetEpoch() throws {
        let scope = try LibraryCommandScope(accountID: UUID(), deploymentID: "https://v5-commands.supabase.co")
        let document = UUID(), imported = UUID(), approval = UUID(), operation = UUID(), epoch = UUID()
        let mutations: [(LibraryMutation, String)] = [
            (.beginImport(sourceID: "2601.00001", requestedRevision: 3, observedCursor: 91), "begin_import"),
            (.setMembership(documentID: document, present: true, expectedRevision: 0, approvalID: approval), "set_library_item"),
            (.cancelImport(importID: imported, expectedRevision: 2), "cancel_import"),
            (.retryImport(importID: imported, expectedRevision: 2), "retry_import"),
            (.setArchived(documentID: document, archived: true, expectedRevision: 4), "set_item_archived"),
            (.setTags(documentID: document, tags: ["Mine"], hiddenTags: ["Theirs"], expectedRevision: 5), "set_item_tags")]
        for (mutation, command) in mutations {
            let legacy = try mutation.request(operationID: operation, scope: scope, readContext: .legacyFull3)
            let v5 = try mutation.request(operationID: operation, scope: scope, readContext: .uploadFull5(datasetEpoch: epoch))
            #expect(legacy == (try mutation.request(operationID: operation, scope: scope)), "legacy stays the default")
            #expect(legacy.endpoint == "v2_" + command && v5.endpoint == "v5_" + command)
            var expected = try object(legacy.body); expected["p_dataset_epoch"] = epoch.wire
            #expect(try object(v5.body) == expected, "the v5 body is the v2 body plus the epoch")
            #expect(v5.operationID == legacy.operationID && v5.digest != legacy.digest)
        }
        // Rows persisted by earlier builds are re-derived and compared byte for byte.
        let begin = try mutations[0].0.request(operationID: operation, scope: scope, readContext: .legacyFull3)
        #expect(String(decoding: begin.body, as: UTF8.self) ==
            #"{"p_observed_cursor":91,"p_operation_id":"\#(operation.wire)","p_requested_revision":3,"p_source_id":"2601.00001"}"#)
    }

    @Test func sourceKeywordsUseTheServerFullListLimitAndRoundTripInReceipts() throws {
        let scope = try LibraryCommandScope(accountID: UUID(), deploymentID: "https://v5-commands.supabase.co")
        let importedID = UUID(), epoch = UUID()
        let tags = (0..<32).map { String(format: "%02d ", $0) + String(repeating: "数", count: 35) }
        let mutation = LibraryMutation.setSourceDetails(importID: importedID, archived: false, tags: tags, expectedRevision: 1)
        let request = try mutation.request(operationID: UUID(), scope: scope, readContext: .uploadFull5(datasetEpoch: epoch))
        #expect(request.body.count > 2_048 && request.body.count <= 8_192)
        var row = imported(importedID, state: 8)
        row["intent_revision"] = 2; row["user_tags"] = tags
        let response = try LibraryWire.decodeCommand(json(["result": ["status": "applied", "kind": "import",
            "id": importedID.wire, "seq": 8, "revision": 2], "entry": row, "replayed": false, "dataset_epoch": epoch.wire]))
        guard case .import(let entry) = response.entry else { Issue.record("Expected source membership receipt"); return }
        #expect(entry.userTags == tags)
        let tooMany = tags + ["Extra"]
        #expect(throws: LibraryCommandError.invalidMutation) {
            try LibraryMutation.setSourceDetails(importID: importedID, archived: false, tags: tooMany, expectedRevision: 1)
                .request(operationID: UUID(), scope: scope, readContext: .uploadFull5(datasetEpoch: epoch))
        }
        row["user_tags"] = tooMany
        #expect(throws: LibraryProtocolError.invalidEntry) {
            try LibraryWire.decodeCommand(json(["result": ["status": "applied", "kind": "import", "id": importedID.wire,
                "seq": 8, "revision": 2], "entry": row, "replayed": false, "dataset_epoch": epoch.wire]))
        }
        #expect(throws: LibraryCommandError.invalidMutation) {
            try LibraryMutation.setTags(documentID: UUID(), tags: tags, hiddenTags: [], expectedRevision: 1)
                .request(operationID: UUID(), scope: scope)
        }
    }

    @Test func v5CommandFreezesItsEpochAndAcceptsOnlyAReceiptFromThatDataset() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let epoch = UUID(), context = LibraryReadContext.uploadFull5(datasetEpoch: epoch)
        try await f.store.saveLibraryPresentation(observation(f.account, rows: [], cursor: 4, epoch: epoch), scope: f.scope)
        let mutation = LibraryMutation.beginImport(sourceID: "2601.00001", requestedRevision: nil, observedCursor: 4)
        await #expect(throws: LibraryCommandError.contextMismatch) {
            try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: mutation)
        }
        let handle = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: mutation, readContext: context)
        let row = try #require(try await f.store.libraryCommandSnapshot(scope: f.scope).commands.first)
        let request = try #require(row.request)
        #expect(row.readContext == context && request.endpoint == "v5_begin_import")
        #expect(try object(request.body)["p_dataset_epoch"] == AnyHashable(epoch.wire))
        await #expect(throws: LibraryCommandError.contextMismatch) { try await f.store.beginLibraryAttempt(handle, scope: f.scope) }
        let attempt = try await f.store.beginLibraryAttempt(handle, scope: f.scope, readContext: context)
        #expect(attempt.readContext == context && attempt.request == request)
        for wrong in [nil, UUID()] {
            await #expect(throws: LibraryCommandError.invalidReceipt) {
                try await f.store.recordLibraryReceipt(reply(handle.intentID, sequence: 5, epoch: wrong), for: attempt)
            }
        }
        let saved = try await f.store.recordLibraryReceipt(reply(handle.intentID, sequence: 5, epoch: epoch), for: attempt)
        let received = try #require(saved.commands.first)
        #expect(received.phase == .receiptAwaitingCatchup && received.receipt?.requiredCursor == 5)
        // The receipt floor is a position in the same v5 journal: a complete observation through it finishes the command.
        let caughtUp = try observation(f.account, rows: [imported(handle.intentID, state: 5)], cursor: 5, epoch: epoch)
        let done = try await f.store.reconcileLibraryCommands([.init(handle: handle, receiptID: received.receipt!.id)],
                                                               observation: caughtUp, scope: f.scope)
        #expect(done.commands.first?.phase == .finished)
        // Tag edits follow the same family.
        let tags = try await f.store.editLibraryTags(scope: f.scope, documentID: UUID(), tags: ["Mine"], hiddenTags: [],
                                                     observedRevision: 1, readContext: context)
        let tagged = try #require(try await f.store.libraryCommandSnapshot(scope: f.scope).commands.first { $0.handle == tags })
        #expect(tagged.request?.endpoint == "v5_set_item_tags")
        let before = try await f.store.libraryCommandSnapshot(scope: f.scope), restarted = try f.reopen()
        #expect(try await restarted.libraryCommandSnapshot(scope: f.scope).commands == before.commands, "v5 rows validate after a restart")
    }

    @Test func datasetRefusalSetsCommandAndHeldReversalAsideWithExactEvidence() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let old = UUID(), new = UUID(), context = LibraryReadContext.uploadFull5(datasetEpoch: old)
        try await f.store.saveLibraryPresentation(observation(f.account, rows: [], cursor: 2, epoch: old), scope: f.scope)
        let mutation = LibraryMutation.beginImport(sourceID: "2601.00001", requestedRevision: nil, observedCursor: 2)
        let parent = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: mutation, readContext: context)
        let attempt = try await f.store.beginLibraryAttempt(parent, scope: f.scope, readContext: context)
        let child = try await f.store.holdLibrarySuccessor(.cancelImport, after: parent, scope: f.scope)
        let refused = try await f.store.recordLibraryFailure(.datasetChanged, for: attempt)
        #expect(refused.commands.count == 2)
        #expect(refused.commands.allSatisfy { $0.phase == .needsReview && $0.failure == .datasetChanged && !$0.canAttempt && $0.receipt == nil })
        #expect(refused.commands[0].request == attempt.request && refused.commands[0].everSubmitted)
        #expect(refused.commands[1].handle == child && refused.commands[1].request == nil)
        // A fresh baseline in the new dataset keeps them for review; nothing is rebased onto it.
        try await f.store.saveLibraryPresentation(observation(f.account, rows: [], cursor: 0, epoch: new), scope: f.scope)
        let reviewed = try f.reopen()
        let after = try await reviewed.libraryCommandSnapshot(scope: f.scope)
        #expect(after.commands == refused.commands)
        await #expect(throws: LibraryCommandError.contextMismatch) {
            try await reviewed.beginLibraryAttempt(parent, scope: f.scope, readContext: .uploadFull5(datasetEpoch: new))
        }
        // The reader can act again from the new observation, as a new operation.
        let again = try await reviewed.enqueueLibraryCommand(scope: f.scope,
            mutation: .beginImport(sourceID: "2601.00001", requestedRevision: nil, observedCursor: 0),
            readContext: .uploadFull5(datasetEpoch: new))
        let fresh = try #require(try await reviewed.libraryCommandSnapshot(scope: f.scope).commands.first { $0.handle == again })
        #expect(again.intentID != parent.intentID && fresh.request?.endpoint == "v5_begin_import")
        let freshBody = try object(try #require(fresh.request).body)
        #expect(freshBody["p_dataset_epoch"] == AnyHashable(new.wire))
    }
}
