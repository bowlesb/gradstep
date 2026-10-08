import CryptoKit
import Foundation
import Testing
@testable import ScienceReaderCore

/// Captured PostgreSQL responses, not hand-built mirrors of the expected wire.
/// Keep LibraryWire unchanged: these tests protect already-installed clients.
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
}
