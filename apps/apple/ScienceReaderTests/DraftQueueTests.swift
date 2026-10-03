import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

@MainActor
final class DraftQueueTests: XCTestCase {
    func testCoalescedEditsAreOwnedBeforeImmediateSignOutAndReopen() async throws {
        let fixture = DraftQueueFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let persistence = ReaderLocalPersistence(), retirement = ReaderRetirementQueue()
        _ = try await persistence.activate(url: fixture.url, accountID: fixture.account, localKey: fixture.localKey, keys: fixture.keys)
        var saved: [LocalDraft] = []
        let queue = ReaderDraftQueue(persistence: persistence) { _, result in
            if case .success(let draft) = result { saved.append(draft) }
            else { XCTFail("The accepted draft should persist") }
        }
        let id = UUID()
        try queue.save(fixture.draft(id, revision: 1, text: "First edit"))
        try queue.save(fixture.draft(id, revision: 2, text: "Second edit"))
        try queue.save(fixture.draft(id, revision: 3, text: "The final accepted edit"))
        queue.close()
        retirement.retire(sync: nil, persistence: persistence)
        await retirement.wait()

        XCTAssertEqual(saved.map(\.text), ["The final accepted edit"], "Intermediate edits coalesce without delaying initial ownership")
        let replacement = ReaderLocalPersistence()
        let reopened = try await replacement.activate(url: fixture.url, accountID: fixture.account, localKey: fixture.localKey, keys: fixture.keys)
        let snapshot = await reopened.snapshot()
        XCTAssertEqual(snapshot.drafts.map(\.text), ["The final accepted edit"])
        XCTAssertEqual(snapshot.drafts.first?.revision, 3)
        XCTAssertTrue(snapshot.state.events.isEmpty)
        XCTAssertEqual(snapshot.pendingCount, 0, "A local draft must not become a synced message")
        do { try queue.save(fixture.draft(id, revision: 4, text: "Too late")); XCTFail("A retired queue cannot accept another account's edit") }
        catch { XCTAssertEqual(error as? ReaderError, .storageUnavailable) }
    }

    func testCapacityFailureKeepsThePreviousDraftAndAllowsAnEditedRetry() async throws {
        let fixture = DraftQueueFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let persistence = ReaderLocalPersistence()
        let store = try await persistence.activate(url: fixture.url, accountID: fixture.account, localKey: fixture.localKey, keys: fixture.keys)
        var successful: [Bool] = []
        let queue = ReaderDraftQueue(persistence: persistence) { _, result in
            switch result { case .success: successful.append(true); case .failure: successful.append(false) }
        }
        let id = UUID()
        try queue.save(fixture.draft(id, revision: 1, text: "Preserve this"))
        await persistence.waitForAcceptedWrites()
        try queue.save(fixture.draft(id, revision: 2, text: String(repeating: "x", count: 200_001)))
        await persistence.waitForAcceptedWrites()
        let afterFailure = await store.snapshot()
        XCTAssertEqual(afterFailure.drafts.first?.text, "Preserve this")
        try queue.save(fixture.draft(id, revision: 3, text: "Edited to fit"))
        await persistence.waitForAcceptedWrites()
        let retried = await store.snapshot()
        XCTAssertEqual(successful, [true, false, true])
        XCTAssertEqual(retried.drafts.first?.text, "Edited to fit")
    }

    func testDiscardFencesAQueuedCheckpointAndEveryLateEditForItsOldIdentity() async throws {
        let fixture = DraftQueueFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let persistence = ReaderLocalPersistence()
        let store = try await persistence.activate(url: fixture.url, accountID: fixture.account, localKey: fixture.localKey, keys: fixture.keys)
        var failures = 0
        let queue = ReaderDraftQueue(persistence: persistence) { _, result in
            if case .failure = result { failures += 1 }
        }
        let id = UUID()
        try queue.save(fixture.draft(id, revision: 1, text: "Discard this"))
        let discarding = try queue.discard(id: id, revision: 1)
        try await discarding.value
        try queue.save(fixture.draft(id, revision: 2, text: "A late callback with the discarded ID"))
        await persistence.waitForAcceptedWrites()
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.drafts.isEmpty)
        XCTAssertEqual(failures, 1)
        let replacement = fixture.draft(UUID(), revision: 1, text: "A deliberate new draft")
        try queue.save(replacement)
        await persistence.waitForAcceptedWrites()
        let recovered = await store.snapshot()
        XCTAssertEqual(recovered.drafts.map(\.id), [replacement.id])
    }
}

private struct DraftQueueFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("draft-queue-\(UUID().wire)", isDirectory: true)
    let account = UUID(), localKey = ReaderCrypto.randomKey()
    let keys: KeyBundle
    var url: URL { folder.appendingPathComponent("state.sqlite") }
    init() { keys = KeyBundle.generate(accountID: account) }
    func draft(_ id: UUID, revision: Int64, text: String) -> LocalDraft {
        LocalDraft(id: id, revision: revision, textRevision: UUID(), text: text, editedAt: Date(), branchRevision: UUID())
    }
}
