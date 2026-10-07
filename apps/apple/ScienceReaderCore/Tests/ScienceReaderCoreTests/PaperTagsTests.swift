import Foundation
import Testing
@testable import ScienceReaderCore

/// Topic tags (migration 029): text rules shared with the server, effective tags, the edit that
/// produces them, wire decoding, the vocabulary, and the durable tag command.
@Suite struct PaperTagsTests {
    @Test func normalizationMatchesTheServerRules() {
        #expect(PaperTags.normalized("  Diffusion   models \n") == "Diffusion models")
        #expect(PaperTags.normalized("tab\there") == "tab here")
        #expect(PaperTags.normalized("   ") == nil)
        #expect(PaperTags.normalized(String(repeating: "x", count: 40)) != nil)
        #expect(PaperTags.normalized(String(repeating: "x", count: 41)) == nil)
        #expect(PaperTags.normalized(String(repeating: "é", count: 40)) != nil) // 80 bytes
        #expect(PaperTags.normalized(String(repeating: "😀", count: 31)) == nil) // 124 bytes
        #expect(PaperTags.isValid(["A", "b"], limit: 2) && !PaperTags.isValid(["A", "a"], limit: 2))
        #expect(!PaperTags.isValid([" A"], limit: 2) && !PaperTags.isValid(["A", "B", "C"], limit: 2))
    }

    @Test func effectiveTagsAreCatalogMinusHiddenThenOwn() {
        let catalog = ["Natural language processing", "Transformers", "Long context"]
        #expect(PaperTags.effective(catalog: catalog, own: ["Reading group"], hidden: ["long context"])
                == ["Natural language processing", "Transformers", "Reading group"])
        #expect(PaperTags.effective(catalog: [], own: [], hidden: []) == [])
        // An own tag equal to a catalog one (case-insensitively) shows once.
        #expect(PaperTags.effective(catalog: ["Transformers"], own: ["transformers", "Mine"], hidden: []) == ["Transformers", "Mine"])
        let edit = PaperTags.edit(catalog: catalog, desired: ["Transformers", "  Reading  group ", "reading group", "Natural language processing"])
        #expect(edit.own == ["Reading group"] && edit.hidden == ["Long context"])
        #expect(PaperTags.effective(catalog: catalog, own: edit.own, hidden: edit.hidden)
                == ["Natural language processing", "Transformers", "Reading group"])
    }

    @Test func vocabularyNamesSuggestionsAndCategories() {
        #expect((60...120).contains(TagVocabulary.tags.count))
        #expect(Set(TagVocabulary.tags.map { $0.name.lowercased() }).count == TagVocabulary.tags.count)
        #expect(TagVocabulary.tags.allSatisfy { PaperTags.normalized($0.name) == $0.name && !$0.definition.isEmpty })
        #expect(TagVocabulary.tag(named: "diffusion MODELS")?.name == "Diffusion models")
        #expect(TagVocabulary.name(forCategory: "cs.CL") == "Natural language processing")
        #expect(TagVocabulary.names(forCategories: ["cs.LG", "stat.ML", "cs.CV", "hep-th"]) == ["Machine learning", "Computer vision"])
        let suggestions = TagVocabulary.suggestions(for: "rein", excluding: [], limit: 3).map(\.name)
        #expect(suggestions.first == "Reinforcement learning" && suggestions.contains("Offline reinforcement learning"))
        #expect(!TagVocabulary.suggestions(for: "diff", excluding: ["Diffusion models"]).map(\.name).contains("Diffusion models"))
        #expect(TagVocabulary.suggestions(for: "  ", excluding: []).isEmpty)
    }

    @Test func itemEntriesDecodeTagListsOnlyWhenPresent() throws {
        func entry(_ extra: [String: Any]) throws -> LibraryItemRecord {
            var value: [String: Any] = ["kind": "item", "id": UUID().wire, "document_id": UUID().wire, "created_seq": 1,
                "state_seq": 1, "membership_revision": 1, "visible": true, "added_at": "2026-10-07T01:02:03Z", "last_remove_seq": 0,
                "approval_id": NSNull(), "version_id": NSNull(), "metadata_id": NSNull(), "source": NSNull(), "source_id": NSNull(),
                "source_revision": NSNull(), "metadata": NSNull(), "metadata_recorded_at": NSNull(), "source_url": NSNull(),
                "scope": "shared_catalog", "page_count": 1, "original_object_id": NSNull(), "artifact_id": NSNull(), "readiness": "unverified"]
            value.merge(extra) { _, new in new }
            let data = try JSONSerialization.data(withJSONObject: value)
            return try JSONDecoder().decode(LibraryItemRecord.self, from: data)
        }
        let plain = try entry([:])
        #expect(plain.tags == nil && plain.userTags == nil && plain.effectiveTags.isEmpty)
        let tagged = try entry(["tags": ["Transformers", "Long context"], "user_tags": ["Reading group"], "hidden_tags": ["Long context"]])
        #expect(tagged.effectiveTags == ["Transformers", "Reading group"])
        // An older cached entry without the keys and a newer one encode/decode round trip.
        let reencoded = try JSONDecoder().decode(LibraryItemRecord.self, from: JSONEncoder().encode(tagged))
        #expect(reencoded == tagged)
    }

    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        let account = UUID(), localKey = ReaderCrypto.randomKey()
        let store: EncryptedStore
        var scope: LibraryCommandScope { try! .init(accountID: account, deploymentID: "https://tags-test.supabase.co") }
        init() throws {
            store = try EncryptedStore(url: directory.appendingPathComponent("state.sqlite"), accountID: account, localKey: localKey,
                                       keys: KeyBundle.generate(accountID: account))
        }
    }

    private func response(document: UUID, item: UUID, sequence: Int64?, revision: Int64) throws -> LibraryCommandResponse {
        let entry: [String: Any] = ["kind": "item", "id": item.wire, "document_id": document.wire, "created_seq": 1,
            "state_seq": sequence ?? 1, "membership_revision": revision, "visible": true, "added_at": "2026-10-07T01:02:03Z",
            "last_remove_seq": 0, "approval_id": NSNull(), "version_id": NSNull(), "metadata_id": NSNull(), "source": NSNull(),
            "source_id": NSNull(), "source_revision": NSNull(), "metadata": NSNull(), "metadata_recorded_at": NSNull(),
            "source_url": NSNull(), "scope": "shared_catalog", "page_count": 1, "original_object_id": NSNull(),
            "artifact_id": NSNull(), "readiness": "unverified", "user_tags": ["Mine"]]
        let result: [String: Any] = ["status": sequence == nil ? "revision_conflict" : "applied", "kind": "item", "id": item.wire,
                                     "seq": sequence ?? (NSNull() as Any), "revision": revision]
        return try LibraryWire.decodeCommand(JSONSerialization.data(withJSONObject: ["result": result, "replayed": false, "entry": entry]))
    }

    private func observation(account: UUID, document: UUID, item: UUID, revision: Int64) throws -> LibraryCompleteObservation {
        let entry: [String: Any] = ["kind": "item", "id": item.wire, "document_id": document.wire, "created_seq": 1,
            "state_seq": 3, "membership_revision": revision, "visible": true, "added_at": "2026-10-07T01:02:03Z",
            "last_remove_seq": 0, "approval_id": NSNull(), "version_id": NSNull(), "metadata_id": NSNull(), "source": NSNull(),
            "source_id": NSNull(), "source_revision": NSNull(), "metadata": NSNull(), "metadata_recorded_at": NSNull(),
            "source_url": NSNull(), "scope": "shared_catalog", "page_count": 1, "original_object_id": NSNull(),
            "artifact_id": NSNull(), "readiness": "unverified"]
        var reconciler = LibraryReconciler(accountID: account)
        let baseline = try LibraryWire.decodeBaseline(JSONSerialization.data(withJSONObject: ["format": 2, "account_id": account.wire,
            "baseline_cursor": 3, "retained_after": 0, "entries": [entry], "has_more": false,
            "next_cursor": ["format": 2, "account_id": account.wire, "through": 3, "created_seq": 1, "id": item.wire, "kind": "item"]]))
        try reconciler.accept(baseline, for: reconciler.nextRequest())
        let changes = try LibraryWire.decodeChanges(JSONSerialization.data(withJSONObject: ["format": 2, "account_id": account.wire,
            "through": 3, "retained_after": 0, "changes": [], "next_cursor": 3, "has_more": false]))
        try reconciler.accept(changes, for: reconciler.nextRequest())
        return try reconciler.completeObservation()
    }

    @Test func tagCommandEncodesAndValidates() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let doc = UUID()
        let request = try LibraryMutation.setTags(documentID: doc, tags: ["Reading group"], hiddenTags: ["Long context"], expectedRevision: 3)
            .request(operationID: UUID(), scope: f.scope)
        #expect(request.endpoint == "v2_set_item_tags")
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["p_document_id"] as? String == doc.wire && body["p_tags"] as? [String] == ["Reading group"]
                && body["p_hidden_tags"] as? [String] == ["Long context"] && body["p_expected_revision"] as? Int == 3)
        for bad: LibraryMutation in [.setTags(documentID: doc, tags: [" x"], hiddenTags: [], expectedRevision: 3),
                                     .setTags(documentID: doc, tags: ["A", "a"], hiddenTags: [], expectedRevision: 3),
                                     .setTags(documentID: doc, tags: (1...13).map { "t\($0)" }, hiddenTags: [], expectedRevision: 3),
                                     .setTags(documentID: doc, tags: [], hiddenTags: [], expectedRevision: 0)] {
            #expect(throws: LibraryCommandError.invalidMutation) { _ = try bad.request(operationID: UUID(), scope: f.scope) }
        }
        // The largest valid edit fits the 2 KiB request bound.
        let longest = (1...12).map { String(format: "%02d", $0) + String(repeating: "\u{e9}", count: 38) }
        let hidden = (1...8).map { String(repeating: "h\($0)", count: 13) }
        #expect(throws: Never.self) {
            _ = try LibraryMutation.setTags(documentID: doc, tags: longest, hiddenTags: hidden, expectedRevision: Int64.max - 1)
                .request(operationID: UUID(), scope: f.scope)
        }
    }

    /// Editing again before an edit synced: an unsent edit is replaced (one command), a sent one is
    /// followed by the new lists at its applied revision; another pending change to the paper waits.
    @Test func reEditingReplacesOrFollowsThePendingEdit() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let doc = UUID(), itemID = UUID()
        let first = try await f.store.editLibraryTags(scope: f.scope, documentID: doc, tags: ["A"], hiddenTags: [], observedRevision: 4)
        let second = try await f.store.editLibraryTags(scope: f.scope, documentID: doc, tags: ["B"], hiddenTags: [], observedRevision: 4)
        var snapshot = try await f.store.libraryCommandSnapshot(scope: f.scope)
        #expect(first != second)
        #expect(snapshot.commands.first { $0.handle == first }?.phase == .cancelled)
        let live = snapshot.commands.filter(\.isUnfinished)
        #expect(live.count == 1 && live.first?.mutation == .setTags(documentID: doc, tags: ["B"], hiddenTags: [], expectedRevision: 4))

        // Sent: the next edit waits for its receipt and freezes at the applied revision.
        let attempt = try await f.store.beginLibraryAttempt(second, scope: f.scope)
        let third = try await f.store.editLibraryTags(scope: f.scope, documentID: doc, tags: ["C"], hiddenTags: ["X"], observedRevision: 4)
        let fourth = try await f.store.editLibraryTags(scope: f.scope, documentID: doc, tags: ["D"], hiddenTags: [], observedRevision: 4)
        snapshot = try await f.store.libraryCommandSnapshot(scope: f.scope)
        #expect(snapshot.commands.first { $0.handle == third }?.phase == .cancelled)
        #expect(snapshot.commands.first { $0.handle == fourth }?.phase == .held)
        // Archive of the same paper is a different change: it waits.
        await #expect(throws: LibraryCommandError.targetBusy) {
            _ = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: .setArchived(documentID: doc, archived: true, expectedRevision: 4))
        }
        snapshot = try await f.store.recordLibraryReceipt(response(document: doc, item: itemID, sequence: 9, revision: 5), for: attempt)
        let next = try #require(snapshot.commands.first { $0.handle == fourth })
        #expect(next.phase == .prepared && next.mutation == .setTags(documentID: doc, tags: ["D"], hiddenTags: [], expectedRevision: 5))
        // A pending archive blocks a tag edit until it finishes.
        let other = UUID()
        _ = try await f.store.enqueueLibraryCommand(scope: f.scope, mutation: .setArchived(documentID: other, archived: true, expectedRevision: 2))
        await #expect(throws: LibraryCommandError.targetBusy) {
            _ = try await f.store.editLibraryTags(scope: f.scope, documentID: other, tags: ["A"], hiddenTags: [], observedRevision: 2)
        }
        // A sent edit cannot be cancelled (edit again instead); an unsent one is discarded.
        let unsent = try await f.store.editLibraryTags(scope: f.scope, documentID: UUID(), tags: ["Z"], hiddenTags: [], observedRevision: 1)
        snapshot = try await f.store.cancelLibraryCommand(unsent, scope: f.scope)
        #expect(snapshot.commands.first { $0.handle == unsent }?.phase == .cancelled)
    }

    @Test func aConflictingEditNeedsReviewAndItsFollowerToo() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let doc = UUID(), itemID = UUID()
        let edit = try await f.store.editLibraryTags(scope: f.scope, documentID: doc, tags: ["A"], hiddenTags: [], observedRevision: 4)
        let attempt = try await f.store.beginLibraryAttempt(edit, scope: f.scope)
        let follower = try await f.store.editLibraryTags(scope: f.scope, documentID: doc, tags: ["B"], hiddenTags: [], observedRevision: 4)
        let snapshot = try await f.store.recordLibraryReceipt(response(document: doc, item: itemID, sequence: nil, revision: 6), for: attempt)
        #expect(snapshot.commands.first { $0.handle == follower }?.phase == .needsReview)
        await #expect(throws: LibraryCommandError.targetBusy) {
            _ = try await f.store.editLibraryTags(scope: f.scope, documentID: doc, tags: ["B"], hiddenTags: [], observedRevision: 6)
        }
        // Catch-up shows the current state; the conflict needs review, and a fresh edit starts at the observed revision.
        let receipt = try #require(snapshot.commands.first { $0.handle == edit }?.receipt)
        _ = try await f.store.reconcileLibraryCommands([LibraryCommandReconciliation(handle: edit, receiptID: receipt.id)],
            observation: observation(account: f.account, document: doc, item: itemID, revision: 6), scope: f.scope)
        let fresh = try await f.store.editLibraryTags(scope: f.scope, documentID: doc, tags: ["B"], hiddenTags: [], observedRevision: 6)
        let after = try await f.store.libraryCommandSnapshot(scope: f.scope)
        #expect(after.commands.first { $0.handle == fresh }?.mutation == .setTags(documentID: doc, tags: ["B"], hiddenTags: [], expectedRevision: 6))
    }
}
