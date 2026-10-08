import CryptoKit
import Foundation
import Testing
@testable import ScienceReaderCore

/// Captured PostgreSQL responses, not hand-built mirrors of the expected wire.
/// The legacy cases remain unchanged; native v5 has its own capture/lineage.
@Suite struct LibraryVisibilityIntegrationTests {
    private let account = UUID(uuidString: "39500000-0000-0000-0000-000000000001")!
    private let arxiv = UUID(uuidString: "39500000-0000-0000-0000-000000000012")!
    private let web = UUID(uuidString: "39500000-0000-0000-0000-000000000014")!

    private func fixtureURL(_ name: String) -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("tests/fixtures/library-visibility/\(name)")
    }

    private func fixture() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL("legacy-v3.json"))) as? [String: Any])
    }

    private func raw(_ kind: String, _ index: Int) throws -> [String: Any] {
        let pages = try #require(fixture()[kind] as? [[String: Any]])
        return pages[index]
    }

    private func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func baseline(_ index: Int) throws -> LibraryBaselinePage {
        try LibraryWire.decodeBaseline(json(raw("baselines", index)))
    }

    private func changes(_ index: Int) throws -> LibraryChangesPage {
        try LibraryWire.decodeChanges(json(raw("changes", index)))
    }

    @Test func fixtureRetainsItsSqlCaptureDigestAndContainsNoHiddenFields() throws {
        let bytes = try Data(contentsOf: fixtureURL("legacy-v3.json"))
        let lineage = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL("lineage.json"))) as? [String: Any])
        #expect(Data(SHA256.hash(data: bytes)).hex == lineage["fixture_sha256"] as? String)
        let object = try fixture()
        #expect((object["baselines"] as? [Any])?.count == 2)
        #expect((object["changes"] as? [Any])?.count == 5)
        func check(_ value: Any) {
            if let fields = value as? [String: Any] {
                #expect(fields["descriptor_ref"] == nil && fields["minimum_source_level"] == nil)
                #expect(fields["read_level"] == nil && fields["dataset_epoch"] == nil)
                #expect(fields["source"] as? String != "upload")
                #expect(!(fields["source_id"] as? String ?? "").hasPrefix("upload:"))
                for child in fields.values { check(child) }
            } else if let array = value as? [Any] {
                for child in array { check(child) }
            }
        }
        check(object)
        let text = try #require(String(data: bytes, encoding: .utf8))
        for hidden in ["39500000-0000-0000-0000-000000000011", "39500000-0000-0000-0000-000000000013"] {
            #expect(!text.contains(hidden)) // Includes the source-null upload tombstone.
        }
    }

    @Test(arguments: [0, 1]) func sourceRestrictedBaselinesDecodeWithoutChangingInstalledCodec(_ index: Int) throws {
        let page = try baseline(index)
        #expect(page.accountID == account && page.format == 2 && page.baselineCursor == 5)
        #expect(!page.hasMore && page.retainedAfter == 0)
        #expect(page.entries.map { $0.id.entityID } == (index == 0 ? [arxiv] : [arxiv, web]))
        #expect(page.nextCursor?.through == 5 && page.nextCursor?.entityID == (index == 0 ? arxiv : web))
        #expect(page.entries.allSatisfy { $0.visible })
    }

    @Test(arguments: [0, 1, 2, 3, 4]) func visibleBatchAndCompletionPagesDecodeWithoutChangingInstalledCodec(_ index: Int) throws {
        let page = try changes(index)
        let expectedSequences: [[Int64]] = [[2], [4], [2], [], [6]]
        let expectedIDs: [[UUID]] = [[arxiv], [web], [arxiv], [], [arxiv]]
        #expect(page.accountID == account && page.format == 2 && page.retainedAfter == 0)
        #expect(page.changes.map(\.sequence) == expectedSequences[index])
        #expect(page.changes.flatMap(\.entries).map { $0.id.entityID } == expectedIDs[index])
        #expect(page.through == [5, 5, 3, 5, 6][index])
        #expect(page.nextCursor == [2, 5, 3, 5, 6][index])
        #expect(page.hasMore == (index == 0))
        if page.hasMore {
            #expect(page.nextCursor == page.changes.last?.sequence && page.nextCursor < page.through)
        } else {
            #expect(page.nextCursor == page.through)
        }
        if index == 4 {
            #expect(page.changes.count == 1 && page.changes[0].entries.count == 1)
            #expect(!page.changes[0].entries[0].visible && page.changes[0].entries[0].stateSequence == 6)
        }
    }

    @Test func capturedBaselineCatchupAndMixedRemovalProduceOneCompleteObservation() throws {
        var reconciler = LibraryReconciler(accountID: account)
        let first = try reconciler.nextRequest()
        try reconciler.accept(baseline(1), for: first)
        let catchup = try reconciler.nextRequest()
        #expect(catchup.query == .changes(after: 5, through: nil))
        try reconciler.accept(changes(3), for: catchup)
        #expect(try reconciler.completeObservation().entries.count == 2)
        let update = try reconciler.nextRequest()
        try reconciler.accept(changes(4), for: update)
        let observation = try reconciler.completeObservation()
        #expect(observation.committedCursor == 6 && observation.entries.count == 2)
        #expect(observation.entries[.init(kind: .import, entityID: arxiv)]?.visible == false)
        #expect(observation.entries[.init(kind: .import, entityID: web)]?.visible == true)
    }

    @Test(arguments: [false, true]) func oldRawScanShapesRemainRejected(_ empty: Bool) throws {
        var broken = try raw("changes", 0)
        // Reproduce both forms of the reviewed bug: empty intermediate page,
        // or a cursor advanced past the last visible batch into a hidden tail.
        if empty { broken["changes"] = []; broken["next_cursor"] = 1 }
        else { broken["next_cursor"] = 3 }
        #expect(throws: LibraryProtocolError.invalidCursor) { try LibraryWire.decodeChanges(json(broken)) }
    }

    private func nativeFixture() throws -> [String: Any] {
        let bytes = try Data(contentsOf: fixtureURL("native-v5.json"))
        let lineage = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL("native-v5-lineage.json"))) as? [String: Any])
        #expect(Data(SHA256.hash(data: bytes)).hex == lineage["fixture_sha256"] as? String)
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    @Test func actualV5FullPagesKeepDescriptorRevisionsAndAtomicSourceNullRemoval() throws {
        let fixture = try nativeFixture()
        let capabilities = try ReaderCapabilities.decode(json(#require(fixture["capabilities"] as? [String: Any])), accountID: account)
        #expect(!capabilities.uploads.enabled) // disabled ingress does not hide these reads
        let baselines = try #require(fixture["baselines"] as? [[String: Any]])
        let deltas = try #require(fixture["changes"] as? [[String: Any]])
        var reconciler = LibraryReconciler(accountID: account, readContext: capabilities.readContext)
        for fields in baselines { try reconciler.accept(LibraryWire.decodeBaseline(json(fields)), for: reconciler.nextRequest()) }
        #expect(reconciler.phase == .catchingUp && reconciler.committedCursor == 4)
        let upload = try #require(reconciler.entries[.init(kind: .import,
            entityID: UUID(uuidString: "39500000-0000-0000-0000-000000000011")!)])
        #expect(upload.descriptorReference?.revision == 1)
        try reconciler.accept(LibraryWire.decodeChanges(json(deltas[0])), for: reconciler.nextRequest())
        let renamed = try reconciler.completeObservation()
        #expect(renamed.entries[upload.id]?.descriptorReference?.revision == 2)
        #expect(renamed.readContext == capabilities.readContext && renamed.committedCursor == 5)

        // Existing command ACKs omit descriptor refs. They cannot downgrade the
        // already observed immutable reference or fabricate a complete cursor.
        var ackEntry = try #require((baselines[0]["entries"] as? [[String: Any]])?.first)
        ackEntry.removeValue(forKey: "descriptor_ref")
        let ack = try LibraryWire.decodeCommand(json(["result": ["status": "applied", "kind": "import",
            "id": upload.id.entityID.wire, "seq": 1, "revision": 1], "replayed": true, "entry": ackEntry]))
        try reconciler.accept(ack, for: reconciler.commandTicket(operationID: upload.id.entityID))
        #expect(try reconciler.completeObservation() == renamed)

        let group = try LibraryWire.decodeChanges(json(deltas[1]))
        #expect(group.changes.count == 1 && group.changes[0].entries.count == 2)
        try reconciler.accept(group, for: reconciler.nextRequest())
        let removed = try reconciler.completeObservation()
        guard case .import(let tombstone) = removed.entries[upload.id] else { Issue.record("Missing upload tombstone"); return }
        #expect(!tombstone.visible && tombstone.source == nil && tombstone.sourceID == nil)
        #expect(tombstone.descriptorReference == renamed.entries[upload.id]?.descriptorReference)
        #expect(removed.entries[.init(kind: .import, entityID: arxiv)]?.visible == false)
    }

    @Test func sourceNullTombstoneWithoutLocalSourceIsRetainedWithoutInventingIdentity() throws {
        let fixture = try nativeFixture(), deltas = try #require(fixture["changes"] as? [[String: Any]])
        let group = try LibraryWire.decodeChanges(json(deltas[1]))
        let epoch = try #require(group.datasetEpoch)
        var reconciler = LibraryReconciler(accountID: account, readContext: group.readContext)
        let empty = try LibraryWire.decodeBaseline(json(["format": 2, "account_id": account.wire,
            "dataset_epoch": epoch.wire, "baseline_cursor": 5, "retained_after": 0,
            "entries": [], "next_cursor": NSNull(), "has_more": false]))
        try reconciler.accept(empty, for: reconciler.nextRequest())
        try reconciler.accept(group, for: reconciler.nextRequest())
        let observation = try reconciler.completeObservation()
        #expect(observation.entries.count == 2)
        let absentSource = observation.entries.values.compactMap { if case .import(let value) = $0, value.source == nil { value } else { nil } }
        #expect(absentSource.count == 1 && absentSource[0].sourceID == nil && !absentSource[0].visible)
        var visible = try #require((deltas[1]["changes"] as? [[String: Any]])?.first?["entries"] as? [[String: Any]]).first!
        visible["visible"] = true
        #expect(throws: LibraryProtocolError.invalidEntry) { try JSONDecoder().decode(LibraryEntry.self, from: json(visible)) }
    }

    @Test func fullV5EpochAndCompactWireCannotCrossReplicaContexts() throws {
        let fixture = try nativeFixture(), baselines = try #require(fixture["baselines"] as? [[String: Any]])
        let full = try LibraryWire.decodeBaseline(json(baselines[0]))
        for context in [LibraryReadContext.legacyFull3, .uploadFull5(datasetEpoch: UUID())] {
            var replica = LibraryReconciler(accountID: account, readContext: context)
            let ticket = try replica.nextRequest()
            #expect(throws: LibraryProtocolError.contextMismatch) { try replica.accept(full, for: ticket) }
            #expect(replica.entries.isEmpty && replica.inFlightRequest == ticket)
        }
        var compact = baselines[0]; compact["format"] = 5
        #expect(throws: LibraryProtocolError.unsupportedFormat) { try LibraryWire.decodeBaseline(json(compact)) }
        var missingLevel = baselines[0], cursor = try #require(missingLevel["next_cursor"] as? [String: Any])
        cursor.removeValue(forKey: "read_level"); missingLevel["next_cursor"] = cursor
        #expect(throws: LibraryProtocolError.invalidCursor) { try LibraryWire.decodeBaseline(json(missingLevel)) }
    }
}
