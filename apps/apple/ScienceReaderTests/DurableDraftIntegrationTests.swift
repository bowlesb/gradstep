import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

#if targetEnvironment(simulator)
@MainActor
final class DurableDraftIntegrationTests: XCTestCase {
    func testAccountWorkspaceRestoresDraftsAndDoesNotRestoreASentQuestion() async throws {
        var first: ReaderModel? = ReaderModel(configuration: nil)
        try await first!.configureDurableDraftFixture(reset: true)
        first!.newChat(general: true)
        first!.chatInput = "First general question"
        let firstID = try XCTUnwrap(first!.chatComposerID)
        await first!.flushDrafts()
        first!.newChat(general: true)
        first!.chatInput = "Second general question"
        let secondID = try XCTUnwrap(first!.chatComposerID)
        await first!.flushDrafts()
        first!.openSample()
        first!.chatInput = "Question for this sample paper"
        let paperID = try XCTUnwrap(first!.chatComposerID)
        await first!.flushDrafts()
        XCTAssertEqual(first!.chatDraftStatusText, "Draft saved on this device")
        first = nil

        var reopened: ReaderModel? = ReaderModel(configuration: nil)
        try await reopened!.configureDurableDraftFixture(reset: false)
        XCTAssertEqual(Set(reopened!.unsentDrafts.map(\.id)), [firstID, secondID, paperID])
        XCTAssertEqual(reopened!.chatInput, "Question for this sample paper")
        reopened!.generalChat = true
        XCTAssertEqual(reopened!.chatInput, "Second general question", "Each context restores its latest draft")
        reopened!.openUnsentDraft(firstID)
        XCTAssertEqual(reopened!.chatInput, "First general question")
        await reopened!.sendMessage()
        await reopened!.flushDrafts()
        XCTAssertNil(reopened!.error)
        XCTAssertEqual(reopened!.chatInput, "")
        let conversation = try XCTUnwrap(reopened!.activeConversation)
        let sentHead = try XCTUnwrap(reopened!.activeBranchID)
        XCTAssertEqual(reopened!.chatMessages.map(\.payload.text), ["First general question"])
        reopened = nil

        let restored = ReaderModel(configuration: nil)
        try await restored.configureDurableDraftFixture(reset: false)
        XCTAssertEqual(Set(restored.unsentDrafts.map(\.id)), [secondID, paperID])
        restored.openConversation(conversation)
        XCTAssertEqual(restored.chatInput, "", "The question and its consumed draft commit together")
        XCTAssertEqual(restored.activeBranchID, sentHead)
        XCTAssertEqual(restored.chatMessages.map(\.payload.text), ["First general question"])
        restored.chatInput = "A follow-up for the saved conversation"
        await restored.flushDrafts()
        let followupID = try XCTUnwrap(restored.chatComposerID)
        XCTAssertEqual(restored.chatDraftStatusText, "Draft saved on this device")
        restored.openUnsentDraft(paperID)
        XCTAssertFalse(restored.generalChat)
        XCTAssertEqual(restored.chatInput, "Question for this sample paper")
        try restored.privateState.apply(AppliedEvent(id: UUID(), deviceID: UUID(), payload: PrivateEvent(kind: .tombstone, entityID: conversation)))
        XCTAssertTrue(restored.unsentDrafts.contains { $0.id == followupID }, "A deleted conversation cannot orphan its unsent follow-up")
        restored.openUnsentDraft(followupID)
        XCTAssertEqual(restored.chatInput, "A follow-up for the saved conversation")
        XCTAssertTrue(restored.chatWasDeleted)
        await restored.sendMessage()
        XCTAssertEqual(restored.chatInput, "A follow-up for the saved conversation")
        XCTAssertNotNil(restored.error, "Recovery keeps the text reachable without restoring the deleted conversation")
    }
}
#endif
