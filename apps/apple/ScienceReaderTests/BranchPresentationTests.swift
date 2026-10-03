import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

@MainActor
final class BranchPresentationTests: XCTestCase {
    func testLateSiblingDoesNotReplaceTheObservedConversation() throws {
        let fixture = try BranchFixture()
        let original = try fixture.add(900, parent: fixture.root, text: "Reply already on screen")
        fixture.model.openConversation(fixture.conversation)
        XCTAssertEqual(fixture.model.activeBranchID, original)

        let sibling = try fixture.add(100, parent: fixture.root, text: "Reply arriving from another device")

        XCTAssertEqual(fixture.model.chatBranches.map(\.head), [sibling, original])
        XCTAssertEqual(fixture.model.activeBranchID, original)
        XCTAssertEqual(fixture.model.chatMessages.last?.payload.text, "Reply already on screen")
        XCTAssertNil(fixture.model.chatFollowRequest)
        fixture.model.newChat(general: true)
        fixture.model.openConversation(fixture.conversation)
        XCTAssertEqual(fixture.model.activeBranchID, original, "Reopening history retains the observed branch")
    }

    func testEachObservedContinuationIsPinnedBeforeTheNextFork() throws {
        let fixture = try BranchFixture()
        let first = try fixture.add(500, parent: fixture.root, text: "Shared question")
        fixture.model.openConversation(fixture.conversation)
        let continuing = try fixture.add(800, parent: first, text: "First reply seen")
        XCTAssertEqual(fixture.model.activeBranchID, continuing)
        _ = try fixture.add(100, parent: first, text: "Later sibling reply")
        XCTAssertEqual(fixture.model.activeBranchID, continuing)
        let next = try fixture.add(900, parent: continuing, text: "Continue this answer")
        XCTAssertEqual(fixture.model.activeBranchID, next)
        _ = try fixture.add(200, parent: continuing, text: "A second fork")
        XCTAssertEqual(fixture.model.activeBranchID, next)
        XCTAssertEqual(fixture.model.chatMessages.map(\.payload.text), ["Shared question", "First reply seen", "Continue this answer"])
        XCTAssertNil(fixture.model.chatFollowRequest)
    }

    func testExplicitChoiceWinsAndItsNextReplyDoesNotChangeTheScrollIntent() throws {
        let fixture = try BranchFixture()
        let first = try fixture.add(400, parent: fixture.root, text: "First branch")
        let second = try fixture.add(500, parent: fixture.root, text: "Second branch")
        fixture.model.openConversation(fixture.conversation)
        XCTAssertEqual(fixture.model.activeBranchID, first)
        fixture.model.activeBranchID = second
        let scroll = try XCTUnwrap(fixture.model.chatFollowRequest)
        _ = try fixture.add(100, parent: first, text: "Unselected continuation")
        let selectedContinuation = try fixture.add(900, parent: second, text: "Selected continuation")
        XCTAssertEqual(fixture.model.activeBranchID, selectedContinuation)
        XCTAssertEqual(fixture.model.chatFollowRequest, scroll, "Receiving a reply is not a new local scrolling gesture")
        fixture.model.activeBranchID = UUID()
        XCTAssertEqual(fixture.model.activeBranchID, selectedContinuation, "A foreign head is not a selectable branch")
    }

    func testDeletionRetainsTheObservedPrefixAndFollowsSurvivingDescendants() throws {
        let fixture = try BranchFixture()
        let common = try fixture.add(600, parent: fixture.root, text: "Common question")
        let retained = try fixture.add(700, parent: common, text: "Chosen answer")
        let removed = try fixture.add(800, parent: retained, text: "Deleted follow-up")
        _ = try fixture.add(100, parent: common, text: "Other branch")
        fixture.model.openConversation(fixture.conversation)
        fixture.model.activeBranchID = removed

        try fixture.remove(removed)
        XCTAssertEqual(fixture.model.activeBranchID, removed, "A deleted tip remains the path's causal anchor")
        XCTAssertEqual(fixture.model.chatMessages.map(\.id), [common, retained])
        let descendant = try fixture.add(900, parent: removed, text: "Surviving descendant")
        XCTAssertEqual(fixture.model.activeBranchID, descendant)
        XCTAssertFalse(fixture.model.chatMessages.contains { $0.id == removed })
        try fixture.remove(retained)
        XCTAssertEqual(fixture.model.activeBranchID, descendant)
        XCTAssertEqual(fixture.model.chatMessages.map(\.payload.text), ["Common question", "Surviving descendant"])
    }

    func testDeletingOneReplyDoesNotSelectItsOnlySurvivingSibling() throws {
        let fixture = try BranchFixture()
        let common = try fixture.add(600, parent: fixture.root, text: "Common question")
        let selected = try fixture.add(900, parent: common, text: "Chosen reply")
        fixture.model.openConversation(fixture.conversation)
        let sibling = try fixture.add(100, parent: common, text: "Other reply")
        try fixture.remove(selected)
        XCTAssertEqual(fixture.model.activeBranchID, selected)
        XCTAssertEqual(fixture.model.chatMessages.map(\.id), [common])
        XCTAssertTrue(fixture.model.chatContextComplete)
        XCTAssertEqual(Set(fixture.model.chatBranches.map(\.head)), [sibling, selected])
        _ = try fixture.add(200, parent: sibling, text: "More on the other branch")
        XCTAssertEqual(fixture.model.activeBranchID, selected)
        try fixture.remove(common)
        XCTAssertTrue(fixture.model.chatMessages.isEmpty)
        XCTAssertTrue(fixture.model.chatHasRemovedMessages)
        XCTAssertTrue(fixture.model.chatContextComplete, "Individual removals allow an explicit new message; they do not delete the conversation")
        let continuation = try fixture.add(950, parent: selected, text: "Return to this path")
        XCTAssertEqual(fixture.model.activeBranchID, continuation)
        XCTAssertEqual(fixture.model.chatMessages.map(\.id), [continuation])
        XCTAssertFalse(fixture.model.chatHasRemovedMessages)
    }

    func testObservedBranchSurvivesRealKeyRotationAndEventReplacement() async throws {
        let account = UUID(), device = UUID(), conversation = UUID(), root = UUID(), head = UUID()
        var keys = KeyBundle.generate(accountID: account)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("branch-rebase-\(UUID().wire)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try EncryptedStore(url: folder.appendingPathComponent("state.sqlite"), accountID: account, localKey: ReaderCrypto.randomKey(), keys: keys)
        try await store.appendBatch([
            (root, PrivateEvent(kind: .conversation, entityID: conversation, text: "Offline history")),
            (head, PrivateEvent(kind: .message, entityID: head, parents: [root], conversationID: conversation, text: "Chosen offline reply", role: .user, status: .complete))
        ], deviceID: device)
        let model = ReaderModel(configuration: nil)
        model.publish(await store.snapshot())
        model.openConversation(conversation)
        model.activeBranchID = head
        let explicitIntent = model.chatFollowRequest
        try keys.rotate()
        try await store.updateKeys(keys)
        let replacement = try await store.rebasePendingAfterCatchUp(deviceID: UUID(), verifiedEpoch: keys.epoch, cursor: 0)
        model.publish(await store.snapshot())
        XCTAssertEqual(model.activeBranchID, replacement[head])
        XCTAssertEqual(model.chatMessages.last?.payload.text, "Chosen offline reply")
        XCTAssertEqual(model.chatFollowRequest, explicitIntent)
    }

    func testIncompleteMergeCannotDisplaceTheReadableBranch() throws {
        let fixture = try BranchFixture()
        let original = try fixture.add(800, parent: fixture.root, text: "Readable answer")
        fixture.model.openConversation(fixture.conversation)
        let other = try fixture.add(900, parent: fixture.root, text: "Independent answer")
        let broken = UUID()
        try fixture.state.apply(AppliedEvent(id: broken, deviceID: UUID(), payload: PrivateEvent(kind: .message,
            parents: [original, other], conversationID: fixture.conversation, text: "Ambiguous merge", role: .user, status: .complete)))
        fixture.generation += 1
        fixture.model.publish(LocalStoreSnapshot(state: fixture.state, generation: fixture.generation, pendingCount: 0))
        XCTAssertEqual(fixture.model.activeBranchID, original)
        XCTAssertEqual(fixture.model.chatMessages.map(\.id), [original])
        XCTAssertTrue(fixture.model.chatContextComplete)
        fixture.model.activeBranchID = broken
        XCTAssertFalse(fixture.model.chatContextComplete, "An explicit inspection of incomplete context must still block sending")
    }

    func testLateSnapshotAndDeletedConversationCannotRestoreAnOldBranch() throws {
        let fixture = try BranchFixture()
        let first = try fixture.add(400, parent: fixture.root, text: "Earlier answer")
        fixture.model.openConversation(fixture.conversation)
        let stale = LocalStoreSnapshot(state: fixture.state, generation: fixture.generation, pendingCount: 0)
        let next = try fixture.add(900, parent: first, text: "Latest answer")
        XCTAssertFalse(fixture.model.publish(stale))
        XCTAssertEqual(fixture.model.activeBranchID, next)
        try fixture.remove(fixture.conversation)
        XCTAssertTrue(fixture.model.chatWasDeleted)
        XCTAssertNil(fixture.model.activeBranchID)
        XCTAssertTrue(fixture.model.chatMessages.isEmpty)
        XCTAssertFalse(fixture.model.chatContextComplete)
    }
}

@MainActor
private final class BranchFixture {
    let model = ReaderModel(configuration: nil)
    let conversation = UUID(), root = UUID(), device = UUID()
    var state = PrivateState()
    var generation: Int64 = 0

    init() throws {
        try state.apply(AppliedEvent(id: root, deviceID: device, payload: PrivateEvent(kind: .conversation, entityID: conversation, text: "Branch fixture")))
        publish()
    }

    func add(_ number: Int, parent: UUID, text: String) throws -> UUID {
        let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
        try state.apply(AppliedEvent(id: id, deviceID: device, payload: PrivateEvent(kind: .message, entityID: id, parents: [parent], conversationID: conversation, text: text, role: .assistant, status: .complete)))
        publish()
        return id
    }

    func remove(_ entity: UUID) throws {
        try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .tombstone, entityID: entity)))
        publish()
    }

    private func publish() {
        generation += 1
        model.publish(LocalStoreSnapshot(state: state, generation: generation, pendingCount: 0))
    }
}
