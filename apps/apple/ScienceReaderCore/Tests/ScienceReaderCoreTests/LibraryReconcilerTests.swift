import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct LibraryReconcilerTests {
    private let account = UUID(uuidString: "a0000000-0000-0000-0000-000000000001")!

    // JSON fixtures mirror jsonb_build_object in migration 010, including null
    // optionals, command receipts without account/format, and final-page cursors.
    private func uuid(_ number: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012llx", Int64(number))
    }

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func metadata() -> [String: Any] {
        ["title": "Attention, ∑ equations and sparse routing", "authors": ["A. Researcher"],
         "abstract": NSNull(), "published_at": "2026-10-02", "updated_at": NSNull(),
         "categories": ["cs.LG"], "venue": NSNull()]
    }

    private func item(_ number: Int, created: Int64? = nil, state: Int64? = nil,
                      revision: Int64 = 1, visible: Bool = true, approved: Bool = false) -> [String: Any] {
        let created = created ?? Int64(number), state = state ?? created
        return ["kind": "item", "id": uuid(number), "document_id": uuid(number + 10_000),
                "created_seq": created, "state_seq": state, "membership_revision": revision,
                "visible": visible, "added_at": "2026-10-03T01:02:03.123456+00:00",
                "last_remove_seq": visible ? 0 : state,
                "approval_id": approved ? uuid(20_001) : NSNull(), "version_id": approved ? uuid(20_002) : NSNull(),
                "metadata_id": approved ? uuid(20_003) : NSNull(), "source": approved ? "arxiv" : NSNull(),
                "source_id": approved ? "2601.00001" : NSNull(), "source_revision": approved ? 3 : NSNull(),
                "metadata": approved ? metadata() : NSNull(),
                "metadata_recorded_at": approved ? "2026-10-03T02:03:04+00:00" : NSNull(),
                "source_url": approved ? "https://arxiv.org/abs/2601.00001v3" : NSNull(),
                "scope": "shared_catalog", "page_count": 12,
                "original_object_id": approved ? uuid(20_004) : NSNull(), "artifact_id": NSNull(),
                "readiness": approved ? "pdf_ready" : "unverified"]
    }

    private func imported(_ number: Int, created: Int64? = nil, state: Int64? = nil,
                          phase: String = "accepted", itemNumber: Int? = nil) -> [String: Any] {
        let created = created ?? Int64(number)
        let resolved = itemNumber != nil
        return ["kind": "import", "id": uuid(number), "created_seq": created, "state_seq": state ?? created,
                "intent_revision": phase == "cancelled" ? 2 : 1,
                "visible": phase != "ready" && phase != "cancelled", "phase": phase,
                "source": "arxiv", "source_id": "2601.00001", "requested_revision": NSNull(),
                "source_revision": resolved ? 3 : NSNull(), "metadata_id": resolved ? uuid(20_003) : NSNull(),
                "version_id": resolved ? uuid(20_002) : NSNull(), "metadata": resolved ? metadata() : NSNull(),
                "metadata_recorded_at": resolved ? "2026-10-03T02:03:04Z" : NSNull(),
                "source_url": resolved ? "https://arxiv.org/abs/2601.00001v3" : "https://arxiv.org/abs/2601.00001",
                "document_id": itemNumber.map { uuid($0 + 10_000) } ?? (NSNull() as Any),
                "library_item_id": itemNumber.map(uuid) ?? (NSNull() as Any),
                "error_code": NSNull(), "retryable": false]
    }

    private func baseline(_ entries: [[String: Any]], high: Int64, more: Bool = false,
                          floor: Int64 = 0, accountID: UUID? = nil) throws -> LibraryBaselinePage {
        try LibraryWire.decodeBaseline(json(baselineJSON(entries, high: high, more: more, floor: floor, accountID: accountID)))
    }

    private func baselineJSON(_ entries: [[String: Any]], high: Int64, more: Bool = false,
                              floor: Int64 = 0, accountID: UUID? = nil) -> [String: Any] {
        let accountID = accountID ?? account
        let cursor: Any = entries.last.map { row in
            ["format": 2, "account_id": accountID.wire, "through": high,
             "created_seq": row["created_seq"]!, "id": row["id"]!, "kind": row["kind"]!] as [String: Any]
        } ?? (NSNull() as Any)
        return ["format": 2, "account_id": accountID.wire, "baseline_cursor": high, "retained_after": floor,
                "entries": entries, "next_cursor": cursor, "has_more": more]
    }

    private func changes(_ batches: [(Int64, [[String: Any]])], through: Int64,
                         more: Bool = false, floor: Int64 = 0) throws -> LibraryChangesPage {
        try LibraryWire.decodeChanges(json(changesJSON(batches, through: through, more: more, floor: floor)))
    }

    private func changesJSON(_ batches: [(Int64, [[String: Any]])], through: Int64,
                             more: Bool = false, floor: Int64 = 0) -> [String: Any] {
        ["format": 2, "account_id": account.wire, "through": through, "retained_after": floor,
         "changes": batches.map { ["seq": $0.0, "entries": $0.1] as [String: Any] },
         "next_cursor": more ? (batches.last?.0 ?? 0) : through, "has_more": more]
    }

    private func command(_ entry: [String: Any]?, receipt: Int64? = nil,
                         revision: Int64 = 1, replayed: Bool = false) throws -> LibraryCommandResponse {
        var result: [String: Any] = ["status": receipt == nil ? "revision_conflict" : "applied",
                                     "kind": entry?["kind"] ?? "item", "id": entry?["id"] ?? NSNull(),
                                     "revision": revision]
        if let receipt { result["seq"] = receipt }
        return try LibraryWire.decodeCommand(json(["result": result, "replayed": replayed, "entry": entry ?? (NSNull() as Any)]))
    }

    private func ready(_ entries: [[String: Any]], high: Int64) throws -> LibraryReconciler {
        var value = LibraryReconciler(accountID: account)
        let first = try value.nextRequest()
        try value.accept(baseline(entries, high: high), for: first)
        let catchUp = try value.nextRequest()
        try value.accept(changes([], through: high), for: catchUp)
        return value
    }

    /// Migration 019: web papers (open-access copies found through OpenAlex) in v3 reads.
    private func webItem(_ number: Int) -> [String: Any] {
        var row = item(number, approved: true)
        row["source"] = "web"; row["source_id"] = "openalex:W1000000001"; row["source_revision"] = 1
        row["source_url"] = "https://doi.org/10.1038/nature14539"; row["scope"] = "owner_private"
        return row
    }
    private func webImport(_ number: Int, itemNumber: Int? = nil) -> [String: Any] {
        var row = imported(number, phase: itemNumber == nil ? "acquiring" : "ready", itemNumber: itemNumber)
        row["source"] = "web"; row["source_id"] = "openalex:W1000000001"; row["source_url"] = "https://openalex.org/works/W1000000001"
        if itemNumber != nil { row["source_revision"] = 1 }
        return row
    }

    @Test func webPapersDecodeAndReconcile() throws {
        let value = try ready([webItem(1), webImport(2, itemNumber: 1), webImport(3), imported(4)], high: 4)
        let entries = try value.completeObservation().entries
        guard case .item(let item) = entries[.init(kind: .item, entityID: UUID(uuidString: uuid(1))!)] else { Issue.record("Expected item"); return }
        #expect(item.source == LibrarySource.web && item.sourceID == "openalex:W1000000001" && item.sourceURL == "https://doi.org/10.1038/nature14539")
        #expect(LibrarySource.isWebSourceID("openalex:W1000000001") && !LibrarySource.isWebSourceID("2305.18290")
                && !LibrarySource.isWebSourceID("openalex:W") && !LibrarySource.isWebSourceID("openalex:W12x")
                && !LibrarySource.isWebSourceID("openalex:W012"))
        #expect(LibrarySource.badge(sourceID: "openalex:W1000000001", revision: 1) == "Open access")
        #expect(LibrarySource.badge(sourceID: "2305.18290", revision: 3) == "arXiv v3" && LibrarySource.badge(sourceID: "2305.18290", revision: nil) == "arXiv")
        #expect(LibrarySource.badge(sourceID: nil, revision: nil) == nil)
        #expect(LibrarySource.placeholderTitle(sourceID: "openalex:W1000000001") == "Open-access paper"
                && LibrarySource.placeholderTitle(sourceID: "2305.18290") == "arXiv 2305.18290")
    }

    @Test func malformedWebEntriesAreRejected() throws {
        var relative = webItem(1); relative["source_url"] = "doi.org/10.1038/nature14539"
        var plain = webItem(1); plain["source_url"] = "http://doi.org/10.1038/nature14539"
        var revised = webItem(1); revised["source_revision"] = 2
        var arxivID = webItem(1); arxivID["source_id"] = "2305.18290"; arxivID["source_url"] = "https://doi.org/x"
        var unknown = item(1, approved: true); unknown["source"] = "semantic_scholar"
        var requested = webImport(2); requested["requested_revision"] = 1
        var elsewhere = webImport(2); elsewhere["source_url"] = "https://evil.example/W1000000001"
        var webAsArxiv = imported(2); webAsArxiv["source_id"] = "openalex:W1000000001"
        for row in [relative, plain, revised, arxivID, unknown, requested, elsewhere] {
            #expect(throws: LibraryProtocolError.self) { try baseline([row], high: 2) }
        }
        // An arXiv-kind import with an OpenAlex ID still needs an arXiv URL.
        #expect(throws: LibraryProtocolError.self) {
            var row = webAsArxiv; row["source_url"] = "https://openalex.org/works/W1000000001"; _ = try baseline([row], high: 2)
        }
    }

    @Test func optionalMetadataAndActualCommandShapesDecodeWithoutInventedFields() throws {
        var row = item(1, approved: true)
        row["metadata"] = ["title": "A paper", "authors": [], "categories": []]
        let page = try baseline([row], high: 1)
        guard case .item(let decoded) = page.entries[0] else { Issue.record("Expected item"); return }
        #expect(decoded.metadata?.authors == [])
        #expect(decoded.metadata?.abstract == nil && decoded.metadata?.publishedAt == nil && decoded.metadata?.venue == nil)
        #expect(page.nextCursor != nil && !page.hasMore)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(page.nextCursor!)) as! [String: Any]
        #expect(encoded["account_id"] as? String == account.wire)
        #expect(encoded["id"] as? String == uuid(1))

        let missing = try command(nil, revision: 0)
        #expect(missing.result.id == nil && missing.result.sequence == nil && missing.entry == nil)
        let pending = try baseline([imported(2)], high: 2)
        guard case .import(let imported) = pending.entries[0] else { Issue.record("Expected import"); return }
        #expect(imported.metadata == nil && imported.documentID == nil && imported.visible)
    }

    @Test func sixHundredAndOneRowsKeepH0SeparateFromFutureRowsAndFixedH1() throws {
        // The last row changes at 610 while the baseline creation boundary is601.
        var fixture = (1...601).map { item($0) }
        fixture[600] = item(601, state: 610, revision: 10, visible: false)
        var value = LibraryReconciler(accountID: account)
        for start in stride(from: 0, to: fixture.count, by: 77) {
            let end = min(start + 77, fixture.count)
            let request = try value.nextRequest(limit: 77)
            try value.accept(baseline(Array(fixture[start..<end]), high: 601, more: end < fixture.count), for: request)
            if end < fixture.count { #expect(value.committedCursor == nil) }
        }
        #expect(value.entries.count == 601 && value.phase == .catchingUp)
        #expect(value.baselineBoundary == 601 && value.committedCursor == 601)
        #expect(value.entries[.init(kind: .item, entityID: UUID(uuidString: uuid(601))!)]?.stateSequence == 610)

        for start in stride(from: 602, through: 610, by: 2) {
            let end = min(start + 1, 610)
            let request = try value.nextRequest(limit: 2)
            #expect(request.query == .changes(after: Int64(start - 1), through: start == 602 ? nil : 610))
            var rows: [(Int64, [[String: Any]])] = []
            for sequence in start...end {
                let row = item(601, state: Int64(sequence), revision: Int64(sequence - 600), visible: sequence != 610)
                rows.append((Int64(sequence), [row]))
            }
            let result = try value.accept(changes(rows, through: 610, more: end < 610), for: request)
            #expect(result.ignoredOlderEntries == (end == 610 ? 0 : 2))
        }
        #expect(value.phase == .ready && value.committedCursor == 610 && value.catchUpBoundary == nil)
        #expect(value.entries.count == 601)
        #expect(value.entries[.init(kind: .item, entityID: UUID(uuidString: uuid(601))!)]?.visible == false)
    }

    @Test func commandsAndHighRowRevisionsNeverSkipAccountCatchUp() throws {
        var value = try ready([item(1)], high: 1)
        let pageRequest = try value.nextRequest()
        let ticket = value.commandTicket(operationID: UUID())
        try value.accept(command(item(1, state: 9, revision: 3, visible: false), receipt: 2, revision: 2, replayed: true), for: ticket)
        #expect(value.committedCursor == 1 && value.inFlightRequest == pageRequest)
        let delta = try changes([(2, [item(1, state: 2, revision: 2)])], through: 2)
        let merged = try value.accept(delta, for: pageRequest)
        #expect(merged.ignoredOlderEntries == 1)
        #expect(value.committedCursor == 2 && value.entries.values.first?.stateSequence == 9)
        let next = try value.nextRequest()
        #expect(next.query == .changes(after: 2, through: nil))
    }

    @Test func equalRevisionConflictRollsBackEveryGroupAndTheCursor() throws {
        var value = try ready([item(1)], high: 1)
        let request = try value.nextRequest()
        let before = value
        let conflict = item(1, visible: false)
        let bad = try changes([(2, [imported(20, created: 2)]), (3, [conflict])], through: 3)
        #expect(throws: LibraryProtocolError.conflictingRevision(.init(kind: .item, entityID: UUID(uuidString: uuid(1))!), 1)) {
            try value.accept(bad, for: request)
        }
        #expect(value == before)
        let good = try changes([(2, [imported(20, created: 2)]), (3, [item(1, state: 3, revision: 2, visible: false)])], through: 3)
        try value.accept(good, for: request)
        #expect(value.entries.count == 2 && value.committedCursor == 3)
    }

    @Test func resolvedAndCancelledImportMappingsSurviveTombstonesAndKindCollision() throws {
        var value = try ready([imported(1)], high: 1)
        let request = try value.nextRequest()
        let resolution = try changes([(2, [imported(1, state: 2, phase: "ready", itemNumber: 1), item(1, created: 2, approved: true)])], through: 2)
        try value.accept(resolution, for: request)
        let sharedID = UUID(uuidString: uuid(1))!
        #expect(value.entries.count == 2 && value.importItemMapping[sharedID] == sharedID)
        #expect(value.entries[.init(kind: .import, entityID: sharedID)]?.visible == false)
        let cancel = try value.nextRequest()
        try value.accept(changes([(3, [imported(1, state: 3, phase: "cancelled", itemNumber: 1),
                                      item(1, created: 2, state: 3, revision: 2, visible: false, approved: true)])], through: 3), for: cancel)
        #expect(value.entries.count == 2 && value.importItemMapping[sharedID] == sharedID)
        #expect(value.entries.values.allSatisfy { !$0.visible })
    }

    @Test func baselineMayCarryForwardMappingBeforeNewerItemExists() throws {
        var value = LibraryReconciler(accountID: account)
        let request = try value.nextRequest()
        try value.accept(baseline([imported(1, state: 2, phase: "ready", itemNumber: 2)], high: 1), for: request)
        #expect(value.importItemMapping[UUID(uuidString: uuid(1))!] == UUID(uuidString: uuid(2))!)
        #expect(value.entries.count == 1 && value.committedCursor == 1)
        let delta = try value.nextRequest()
        try value.accept(changes([(2, [imported(1, state: 2, phase: "ready", itemNumber: 2), item(2, approved: true)])], through: 2), for: delta)
        #expect(value.entries.count == 2 && value.phase == .ready)
    }

    @Test func batchMayContainUnchangedItemAndRejectsInconsistentMappingAtomically() throws {
        var value = try ready([item(1, approved: true), imported(2)], high: 2)
        let request = try value.nextRequest()
        let before = value
        var mismatched = imported(2, state: 3, phase: "ready", itemNumber: 1)
        mismatched["document_id"] = uuid(90_000)
        let bad = try changes([(3, [mismatched, item(1, approved: true)])], through: 3)
        #expect(throws: LibraryProtocolError.identityConflict(.init(kind: .import, entityID: UUID(uuidString: uuid(2))!))) {
            try value.accept(bad, for: request)
        }
        #expect(value == before)
        let result = try value.accept(changes([(3, [imported(2, state: 3, phase: "ready", itemNumber: 1), item(1, approved: true)])], through: 3), for: request)
        #expect(result.identicalEntries == 1 && result.insertedOrUpdated == 1 && value.committedCursor == 3)
    }

    @Test func duplicateAndReorderedResponsesCannotAdvanceAnotherRequest() throws {
        var value = LibraryReconciler(accountID: account)
        let first = try value.nextRequest(limit: 1)
        #expect(try value.nextRequest(limit: 10) == first)
        let firstPage = try baseline([item(1)], high: 2, more: true)
        try value.accept(firstPage, for: first)
        let second = try value.nextRequest(limit: 1)
        let before = value
        #expect(try value.accept(firstPage, for: first).disposition == .ignoredStaleResponse)
        #expect(value == before)
        #expect(throws: LibraryProtocolError.invalidCursor) { try value.accept(firstPage, for: second) }
        #expect(value == before)
        try value.accept(baseline([item(2)], high: 2), for: second)
        let delta = try value.nextRequest()
        #expect(try value.accept(baseline([item(2)], high: 2), for: second).disposition == .ignoredStaleResponse)
        try value.accept(changes([], through: 2), for: delta)
        #expect(value.committedCursor == 2)
    }

    @Test func fixedBoundariesAndAccountBindingRejectResponsesWithoutMutation() throws {
        var value = LibraryReconciler(accountID: account)
        let first = try value.nextRequest()
        let before = value
        #expect(throws: LibraryProtocolError.accountMismatch) {
            try value.accept(baseline([item(1)], high: 1, accountID: UUID()), for: first)
        }
        #expect(value == before)
        try value.accept(baseline([item(1)], high: 2, more: true), for: first)
        let second = try value.nextRequest()
        #expect(throws: LibraryProtocolError.invalidCursor) { try value.accept(baseline([item(2)], high: 3), for: second) }
        try value.accept(baseline([item(2)], high: 2), for: second)
        let delta = try value.nextRequest()
        try value.accept(changes([(3, [item(1, state: 3, revision: 2)])], through: 5, more: true), for: delta)
        let continuation = try value.nextRequest()
        let fixed = value
        #expect(throws: LibraryProtocolError.invalidCursor) { try value.accept(changes([], through: 6), for: continuation) }
        #expect(value == fixed && value.catchUpBoundary == 5)
    }

    @Test func resetAndAccountSwitchFencePagesCommandsAndOldResyncErrors() throws {
        var value = try ready([item(1)], high: 1)
        let request = try value.nextRequest(), commandTicket = value.commandTicket(operationID: UUID())
        let oldSession = value.sessionID
        value.reset(accountID: account)
        #expect(value.sessionID != oldSession && value.entries.isEmpty && value.committedCursor == nil)
        #expect(try value.accept(changes([], through: 1), for: request).disposition == .ignoredStaleResponse)
        #expect(try value.accept(command(item(1), receipt: 1), for: commandTicket).disposition == .ignoredStaleResponse)
        let oldResyncAccepted = value.requireResync(for: request)
        #expect(!oldResyncAccepted)
        let current = try value.nextRequest()
        try value.accept(baseline([item(2)], high: 2), for: current)
        value.reset(accountID: UUID())
        #expect(value.entries.isEmpty && value.phase == .baseline)
        #expect(try value.accept(baseline([item(2)], high: 2), for: current).disposition == .ignoredStaleResponse)
    }

    @Test func compactionRequiresExplicitSessionResetAndCannotSkipMissingHistory() throws {
        var value = try ready([item(1)], high: 1)
        let request = try value.nextRequest()
        let before = value
        let compacted = try changes([(3, [item(1, state: 3, revision: 2)])], through: 3, floor: 2)
        #expect(throws: LibraryProtocolError.resyncRequired) { try value.accept(compacted, for: request) }
        #expect(value == before)
        let resyncAccepted = value.requireResync(for: request)
        #expect(resyncAccepted)
        #expect(value.phase == .baseline && value.entries.isEmpty && value.committedCursor == nil)
        #expect(throws: LibraryProtocolError.resyncRequired) { try baseline([], high: 1, floor: 2) }
    }

    @Test func integerCursorsDoNotRoundThroughDouble() throws {
        let high: Int64 = 9_007_199_254_740_993
        var value = LibraryReconciler(accountID: account)
        let request = try value.nextRequest()
        let page = try baseline([item(1, created: high)], high: high)
        try value.accept(page, for: request)
        #expect(page.nextCursor?.through == high && value.committedCursor == high)
    }

    @Test func capabilitiesFailClosedForUnverifiedUnknownRemovedAndUnsupportedScope() throws {
        var unverified = item(1)
        unverified["artifact_id"] = uuid(30_001)
        unverified["render_availability"] = "available"
        unverified["original_availability"] = "available"
        var unknown = item(2, approved: true)
        unknown["artifact_id"] = uuid(30_002)
        unknown["readiness"] = "future_verification_state"
        unknown["render_availability"] = "available"
        unknown["original_availability"] = "available"
        var removed = item(3, visible: false, approved: true)
        removed["artifact_id"] = uuid(30_003)
        removed["readiness"] = "converted_ready"
        removed["render_availability"] = "available"
        removed["original_availability"] = "available"
        for entry in try baseline([unverified, unknown, removed], high: 3).entries {
            guard case .item(let record) = entry else { Issue.record("Expected item"); continue }
            #expect(!record.canReadOriginal && !record.canReadStructured)
        }
        // Private conversions are pinned by an owner-private approval and are
        // readable by their owner (the server returns only the caller's items).
        var privateScope = item(4, approved: true)
        privateScope["scope"] = "owner_private"
        guard case .item(let record) = try baseline([privateScope], high: 4).entries[0] else { Issue.record("Expected item"); return }
        #expect(record.canReadOriginal)
    }

    @Test func optionalAvailabilityKeepsPinsAndDistinguishesOriginalFromConversion() throws {
        let legacy = try baseline([item(1, approved: true)], high: 1)
        guard case .item(let legacyRecord) = legacy.entries[0] else { Issue.record("Expected item"); return }
        #expect(legacyRecord.canReadOriginal && !legacyRecord.canReadStructured)
        var oldRow = item(1, approved: true)
        oldRow["artifact_id"] = uuid(30_001)
        oldRow["readiness"] = "converted_ready"
        var value = try ready([oldRow], high: 1)
        var unavailable = oldRow
        unavailable["state_seq"] = 2
        unavailable["readiness"] = "unavailable"
        unavailable["original_availability"] = "available"
        unavailable["render_availability"] = "quarantined"
        unavailable["original_availability_revision"] = 7
        unavailable["render_availability_revision"] = 9
        let request = try value.nextRequest()
        try value.accept(changes([(2, [unavailable])], through: 2), for: request)
        guard case .item(let partial) = value.entries.values.first else { Issue.record("Expected item"); return }
        #expect(partial.canReadOriginal && !partial.canReadStructured)
        #expect(partial.artifactID == UUID(uuidString: uuid(30_001)) && partial.membershipRevision == 1)

        var unknownCapability = unavailable
        unknownCapability["state_seq"] = 3
        unknownCapability["original_availability"] = "future_capability"
        unknownCapability["original_availability_revision"] = 10
        let next = try value.nextRequest()
        try value.accept(changes([(3, [unknownCapability])], through: 3), for: next)
        guard case .item(let unknown) = value.entries.values.first else { Issue.record("Expected item"); return }
        #expect(!unknown.canReadOriginal && !unknown.canReadStructured)

        var conflicting = unknownCapability
        conflicting["original_availability"] = "available"
        let before = value, ticket = value.commandTicket(operationID: UUID())
        #expect(throws: LibraryProtocolError.conflictingRevision(partialID(1), 3)) {
            try value.accept(command(conflicting, receipt: 2), for: ticket)
        }
        #expect(value == before)
    }

    private func partialID(_ number: Int, kind: LibraryEntryKind = .item) -> LibraryEntryID {
        .init(kind: kind, entityID: UUID(uuidString: uuid(number))!)
    }

    @Test func newerItemCannotRegressRevisionsOrReplaceEstablishedPins() throws {
        var oldRow = item(1, state: 5, revision: 3, visible: false, approved: true)
        oldRow["artifact_id"] = uuid(30_001)
        oldRow["readiness"] = "converted_ready"
        oldRow["original_availability_revision"] = 8
        var good = oldRow
        good["state_seq"] = 6
        good["visible"] = true
        // Availability publication may leave the membership revision unchanged.
        var mutations: [[String: Any]] = []
        for key in ["approval_id", "metadata_id", "version_id", "original_object_id", "artifact_id"] {
            var changed = good; changed[key] = uuid(99_999); mutations.append(changed)
        }
        var removedPins = item(1, state: 6, revision: 3)
        removedPins["last_remove_seq"] = 5
        mutations.append(removedPins)
        var removedArtifact = good
        removedArtifact["artifact_id"] = NSNull(); removedArtifact["readiness"] = "pdf_ready"
        mutations.append(removedArtifact)
        for (key, lower) in [("membership_revision", 2), ("last_remove_seq", 4), ("original_availability_revision", 7)] {
            var changed = good; changed[key] = lower; mutations.append(changed)
        }
        for malformed in mutations {
            var value = try ready([oldRow], high: 5)
            let request = try value.nextRequest(), before = value
            #expect(throws: LibraryProtocolError.identityConflict(partialID(1))) {
                try value.accept(changes([(6, [malformed])], through: 6), for: request)
            }
            #expect(value == before)
        }
        var value = try ready([oldRow], high: 5)
        let request = try value.nextRequest()
        try value.accept(changes([(6, [good])], through: 6), for: request)
        let ticket = value.commandTicket(operationID: UUID())
        let older = try value.accept(command(item(1), receipt: 1), for: ticket)
        #expect(older.ignoredOlderEntries == 1 && value.committedCursor == 6)
    }

    @Test func newerImportCannotLoseMappingMetadataOrRegressIntent() throws {
        var oldRow = imported(1, state: 5, phase: "ready", itemNumber: 2)
        oldRow["intent_revision"] = 3
        var good = imported(1, state: 6, phase: "cancelled", itemNumber: 2)
        good["intent_revision"] = 4
        var mutations: [[String: Any]] = []
        for key in ["metadata_id", "version_id", "library_item_id", "document_id"] {
            var changed = good; changed[key] = uuid(99_999); mutations.append(changed)
        }
        var lostMapping = good
        lostMapping["library_item_id"] = NSNull(); lostMapping["document_id"] = NSNull()
        mutations.append(lostMapping)
        var lostMetadata = imported(1, state: 6, phase: "cancelled")
        lostMetadata["intent_revision"] = 4
        mutations.append(lostMetadata)
        var regressed = good; regressed["intent_revision"] = 2; mutations.append(regressed)
        for malformed in mutations {
            var value = try ready([oldRow], high: 5)
            let request = try value.nextRequest(), before = value
            #expect(throws: LibraryProtocolError.identityConflict(partialID(1, kind: .import))) {
                try value.accept(changes([(6, [malformed])], through: 6), for: request)
            }
            #expect(value == before)
        }
        var value = try ready([oldRow], high: 5)
        let request = try value.nextRequest()
        try value.accept(changes([(6, [good])], through: 6), for: request)
        let ticket = value.commandTicket(operationID: UUID())
        let older = try value.accept(command(imported(1), receipt: 1), for: ticket)
        #expect(older.ignoredOlderEntries == 1 && value.importItemMapping[UUID(uuidString: uuid(1))!] == UUID(uuidString: uuid(2))!)
    }

    @Test func capacityFailurePreservesAllTombstonesAndTheAcceptedCursor() throws {
        // The current account limit allows 2,000 lifetime items and 2,000
        // imports. Hidden records and their collision-safe identities count.
        var value = LibraryReconciler(accountID: account)
        for first in stride(from: 1, through: 2_000, by: 50) {
            var rows: [[String: Any]] = []
            for number in first..<(first + 50) {
                rows.append(imported(number, phase: "cancelled"))
                rows.append(item(number, visible: false))
            }
            let request = try value.nextRequest()
            try value.accept(baseline(rows, high: 2_000, more: first < 1_951), for: request)
        }
        let request = try value.nextRequest()
        try value.accept(changes([], through: 2_000), for: request)
        #expect(value.entries.count == LibraryWire.maximumRetainedEntries && value.entries.values.allSatisfy { !$0.visible })
        let ticket = value.commandTicket(operationID: UUID()), before = value
        #expect(throws: LibraryProtocolError.capacityExceeded) {
            try value.accept(command(item(2_001), receipt: 2_001), for: ticket)
        }
        #expect(value == before && value.committedCursor == 2_000)
    }

    @Test func wireBoundsMalformedOrderingAndUnsupportedFormatsFailClosed() throws {
        #expect(throws: LibraryProtocolError.payloadTooLarge) {
            try LibraryWire.decodeBaseline(Data(repeating: 32, count: LibraryWire.maximumPageBytes + 1))
        }
        #expect(throws: LibraryProtocolError.invalidPage) { try baseline((1...101).map { item($0) }, high: 101) }
        #expect(throws: LibraryProtocolError.invalidPage) { try baseline([item(2), item(1)], high: 2) }
        #expect(throws: LibraryProtocolError.invalidPage) { try baseline([item(1), item(1)], high: 1) }
        #expect(throws: LibraryProtocolError.invalidPage) { try changes([(1, (1...5).map { item($0, created: 1) })], through: 1) }
        #expect(throws: LibraryProtocolError.invalidPage) { try changes([(1, [item(1)]), (1, [item(1)])], through: 1) }
        #expect(throws: LibraryProtocolError.invalidCursor) { try baseline([], high: 0, more: true) }
        var unsupported = baselineJSON([], high: 0)
        unsupported["format"] = 3
        #expect(throws: LibraryProtocolError.unsupportedFormat) { try LibraryWire.decodeBaseline(json(unsupported)) }
        var metadataRow = item(1, approved: true)
        var badMetadata = metadata()
        badMetadata["authors"] = Array(repeating: "x", count: 513)
        metadataRow["metadata"] = badMetadata
        #expect(throws: LibraryProtocolError.invalidMetadata) { try baseline([metadataRow], high: 1) }
        badMetadata = metadata(); badMetadata["published_at"] = "2026-02-30"
        metadataRow["metadata"] = badMetadata
        #expect(throws: LibraryProtocolError.invalidMetadata) { try baseline([metadataRow], high: 1) }
        badMetadata = metadata(); badMetadata["title"] = String(repeating: "é", count: 2_001)
        metadataRow["metadata"] = badMetadata
        #expect(throws: LibraryProtocolError.invalidMetadata) { try baseline([metadataRow], high: 1) }
        var badCursor = baselineJSON([item(1)], high: 1)
        var cursor = badCursor["next_cursor"] as! [String: Any]
        cursor["created_seq"] = NSNull(); badCursor["next_cursor"] = cursor
        #expect(throws: (any Error).self) { try LibraryWire.decodeBaseline(json(badCursor)) }
    }
}
