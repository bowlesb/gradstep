import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

#if targetEnvironment(simulator)
@MainActor
final class DurableDraftIntegrationTests: XCTestCase {
    func testDeferredSelectionCannotSendAChangedConversationOrDraft() async throws {
        let model = ReaderModel(configuration: nil)
        try await model.configureDurableDraftFixture(reset: true)
        model.selectionAction(.define, quote: "the selected expression")
        let selectedPrompt = model.chatInput
        model.newChat(general: true)
        model.chatInput = "Do not send this newer draft"
        await model.flushDrafts()
        await Task.yield()
        XCTAssertTrue(model.privateState.events.isEmpty)
        XCTAssertEqual(model.chatInput, "Do not send this newer draft")
        XCTAssertTrue(model.unsentDrafts.contains { $0.text == selectedPrompt })
    }

    func testVerifiedEquationSourceReachesEncryptedHistoryAndSurvivesReopen() async throws {
        var model: ReaderModel? = ReaderModel(configuration: nil)
        try await model!.configureDurableDraftFixture(reset: true)
        let bundle = try XCTUnwrap(model!.selectedPaper?.readerBundle)
        let equation = try XCTUnwrap(bundle.index.equations.first)
        let scope = try XCTUnwrap(model!.readerDocumentScope)
        let selection = ReaderSelection(manifestSHA256: bundle.manifestSHA256,
            parts: [.init(kind: "equation", blockID: equation.blockID, equationID: equation.id)])
        let quote = try selection.resolvedQuote(in: bundle)
        model!.selectionAction(.define, selection: selection, scope: scope)
        let sent = expectation(description: "Selection action commits the captured question")
        let observation = Task { @MainActor in
            for _ in 0..<100 {
                if model?.chatMessages.count == 1 { sent.fulfill(); return }
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        await fulfillment(of: [sent], timeout: 5)
        observation.cancel()
        await model!.flushDrafts()
        XCTAssertEqual(model!.chatMessages.first?.payload.text, "Explain this in plain terms, in the context of this paper (for notation or an equation, say what each symbol means): " + quote)
        let conversation = try XCTUnwrap(model!.activeConversation)
        model = nil
        let reopened = ReaderModel(configuration: nil)
        try await reopened.configureDurableDraftFixture(reset: false)
        reopened.openConversation(conversation)
        XCTAssertEqual(reopened.chatMessages.map(\.payload.text), ["Explain this in plain terms, in the context of this paper (for notation or an equation, say what each symbol means): " + quote])
        XCTAssertEqual(reopened.chatInput, "")
    }

    /// Opened / Read in the Library: this device's reading activity is sealed in the account's local
    /// folder (no plaintext identifiers), survives relaunch, and restores the saved reading position.
    func testReadingActivityIsSealedOnDeviceAndRestoredAfterRelaunch() async throws {
        var model: ReaderModel? = ReaderModel(configuration: nil)
        try await model!.configureDurableDraftFixture(reset: true)
        let paper = try XCTUnwrap(model!.selectedPaper)
        let opened = try XCTUnwrap(model!.readingActivity[paper.id]?.openedAt, "Opening records the time on this device")
        let key = "\(paper.id.uuidString)/artifact/manifest"
        let location = PaperReadingLocation(blockIndex: 7, blockFraction: 0.3, blockHeight: 90, scrollY: 1_200, progress: 0.55)
        model!.recordReadingLocation(location, key: key, documentID: paper.id)
        model!.flushReadingActivity()
        await model!.flushDrafts()
        let file = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("workflow-draft-fixture/" + ReadingActivityStore.fileName)
        let disk = try Data(contentsOf: file)
        XCTAssertNil(disk.range(of: Data(paper.id.uuidString.utf8)))
        XCTAssertNil(disk.range(of: Data(paper.id.wire.utf8)))
        XCTAssertNil(disk.range(of: Data("artifact/manifest".utf8)))
        model = nil

        let reopened = ReaderModel(configuration: nil)
        try await reopened.configureDurableDraftFixture(reset: false)
        XCTAssertEqual(reopened.readingActivity[paper.id]?.progress, 0.55)
        XCTAssertEqual(reopened.paperLocations[key], location, "Reopening the same artifact returns to its place")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(reopened.readingActivity[paper.id]?.openedAt), opened)
        XCTAssertEqual(reopened.libraryFacts(for: .paper(paper)).progress, 0.55)
    }

    func testOldSelectionScopeCannotCreateAQuestionAfterPaperChange() throws {
        let model = ReaderModel(configuration: nil)
        model.openSample()
        let scope = try XCTUnwrap(model.readerDocumentScope)
        let bundle = try XCTUnwrap(model.selectedPaper?.readerBundle)
        let equation = try XCTUnwrap(bundle.index.equations.first)
        let selection = ReaderSelection(manifestSHA256: bundle.manifestSHA256,
            parts: [.init(kind: "equation", blockID: equation.blockID, equationID: equation.id)])
        model.selectedPaper = nil
        model.newChat(general: true); model.chatInput = "Keep this draft"
        model.selectionAction(.define, selection: selection, scope: scope)
        XCTAssertTrue(model.generalChat)
        XCTAssertEqual(model.chatInput, "Keep this draft")
        XCTAssertEqual(model.selectedQuote, "")
    }

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
