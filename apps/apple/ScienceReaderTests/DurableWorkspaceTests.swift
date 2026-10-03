import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

@MainActor
final class DurableWorkspaceTests: XCTestCase {
    func testCheckpointSeparatesTextIdentityFromExplicitBranchChoice() throws {
        var workspace = ChatWorkspace()
        let document = UUID(), context = "paper/\(document.wire)"
        workspace.setDraft("Same words", in: context)
        let first = try XCTUnwrap(workspace.checkpoint(in: context))
        workspace.setDraft("Same words", in: context)
        let second = try XCTUnwrap(workspace.checkpoint(in: context))
        XCTAssertEqual(second.documentID, document)
        XCTAssertGreaterThan(second.revision, first.revision)
        XCTAssertNotEqual(second.textRevision, first.textRevision)
        XCTAssertEqual(second.branchRevision, first.branchRevision)

        let observed = UUID()
        workspace.recordSelectedHead(observed, for: first.id)
        let automatic = try XCTUnwrap(workspace.checkpoint(for: first.id))
        XCTAssertGreaterThan(automatic.revision, second.revision)
        XCTAssertEqual(automatic.branchRevision, first.branchRevision)
        workspace.recordSelectedHead(observed, for: first.id, explicit: true)
        let explicit = try XCTUnwrap(workspace.checkpoint(for: first.id))
        XCTAssertGreaterThan(explicit.revision, automatic.revision)
        XCTAssertNotEqual(explicit.branchRevision, automatic.branchRevision)
        XCTAssertEqual(explicit.textRevision, second.textRevision)
    }

    func testRestoreSelectsLatestPerContextAndKeepsEveryDraftReachable() throws {
        let document = UUID(), conversation = UUID()
        let older = draft("Older unsent", time: 1)
        let latest = draft("Latest unsent", time: 3)
        let history = draft("Historical follow-up", conversation: conversation, time: 2)
        let paper = draft("Paper draft", document: document, time: 4)
        var workspace = ChatWorkspace()
        workspace.restore([older, paper, history, latest])

        XCTAssertEqual(workspace.composerID(in: "general"), latest.id)
        XCTAssertEqual(workspace.draft(in: "paper/\(document.wire)"), paper.text)
        XCTAssertEqual(Set(workspace.unsentDrafts.map(\.id)), [older.id, latest.id, paper.id])
        XCTAssertEqual(workspace.selectDraft(older.id), "general")
        XCTAssertEqual(workspace.draft(in: "general"), older.text)
        workspace.select(conversation, in: "general")
        XCTAssertEqual(workspace.composerID(in: "general"), history.id)
        XCTAssertEqual(workspace.draft(in: "general"), history.text)
        XCTAssertFalse(workspace.isSaving(in: "general"))
    }

    func testRestoreCannotReplaceGuestIntentEmptyNewChatOrANewerEdit() throws {
        var workspace = ChatWorkspace()
        workspace.setDraft("Live guest question", in: "general")
        let guest = try XCTUnwrap(workspace.composerID(in: "general"))
        let stored = draft("Restored account draft", time: 10_000)
        workspace.restore([stored])
        XCTAssertEqual(workspace.composerID(in: "general"), guest)
        XCTAssertEqual(workspace.draft(in: "general"), "Live guest question")
        XCTAssertTrue(workspace.unsentDrafts.contains { $0.id == stored.id })

        workspace.select(nil, in: "general")
        let intentionalEmpty = workspace.composerID(in: "general")
        workspace.restore([stored])
        XCTAssertEqual(workspace.composerID(in: "general"), intentionalEmpty)
        XCTAssertEqual(workspace.draft(in: "general"), "")

        _ = workspace.selectDraft(stored.id)
        workspace.setDraft("Newer live edit", in: "general")
        var late = stored
        late.revision = 50; late.textRevision = UUID(); late.text = "Older asynchronously delivered text"
        workspace.restore([late])
        XCTAssertEqual(workspace.draft(in: "general"), "Newer live edit")
        XCTAssertGreaterThan(try XCTUnwrap(workspace.checkpoint(for: stored.id)).revision, late.revision)
    }

    func testLateCheckpointCallbacksPreserveTextAndTheNewestSaveStatus() throws {
        var workspace = ChatWorkspace()
        workspace.setDraft("First", in: "general")
        let id = try XCTUnwrap(workspace.composerID(in: "general"))
        let first = try XCTUnwrap(workspace.beginCheckpoint(for: id))
        workspace.setDraft("Second", in: "general")
        let second = try XCTUnwrap(workspace.beginCheckpoint(for: id))
        workspace.failCheckpoint(first, message: "Old failure")
        workspace.acknowledge(first, stored: first.draft)
        XCTAssertEqual(workspace.draft(in: "general"), "Second")
        XCTAssertEqual(workspace.draftStatus(in: "general"), .saving)
        workspace.acknowledge(second, stored: second.draft)
        XCTAssertEqual(workspace.draftStatus(in: "general"), .saved)
        XCTAssertNil(workspace.beginCheckpoint(for: id), "An unchanged durable checkpoint needs no new write")

        workspace.setDraft("Second", in: "general")
        let failing = try XCTUnwrap(workspace.beginCheckpoint(for: id))
        workspace.failCheckpoint(failing, message: "Disk unavailable")
        XCTAssertEqual(workspace.draftStatus(in: "general"), .failed("Disk unavailable"))
        workspace.setDraft("Third", in: "general")
        XCTAssertEqual(workspace.draftStatus(in: "general"), .changed)
        workspace.acknowledge(second, stored: second.draft)
        XCTAssertEqual(workspace.draft(in: "general"), "Third")
        XCTAssertEqual(workspace.draftStatus(in: "general"), .changed)
    }

    func testCanonicalSendCannotClearIdenticalReplacementOrExplicitChoice() throws {
        var workspace = ChatWorkspace()
        workspace.setDraft("Repeat this question", in: "general")
        let submission = try XCTUnwrap(workspace.beginSubmission(in: "general"))
        let captured = try XCTUnwrap(submission.checkpoint)
        workspace.setDraft("Repeat this question", in: "general")
        let replacementRevision = try XCTUnwrap(workspace.checkpoint(in: "general")).textRevision
        let chosen = UUID()
        workspace.recordSelectedHead(chosen, for: submission.composerID, explicit: true)
        let explicitRevision = try XCTUnwrap(workspace.checkpoint(for: submission.composerID)).branchRevision
        workspace.select(nil, in: "general")
        workspace.setDraft("A different conversation", in: "general")
        let visible = workspace.composerID(in: "general")

        XCTAssertTrue(workspace.complete(submission, stored: consumed(submission, captured), receiptID: submission.id))
        XCTAssertEqual(workspace.composerID(in: "general"), visible)
        let completed = try XCTUnwrap(workspace.checkpoint(for: submission.composerID))
        XCTAssertEqual(completed.text, "Repeat this question")
        XCTAssertEqual(completed.textRevision, replacementRevision)
        XCTAssertEqual(completed.selectedHead, chosen)
        XCTAssertEqual(completed.branchRevision, explicitRevision)
        XCTAssertEqual(completed.conversationID, submission.conversationID)
        XCTAssertEqual(completed.acknowledgedSubmissionID, submission.id)
        XCTAssertGreaterThan(completed.revision, captured.revision)
        workspace.select(submission.conversationID, in: "general")
        XCTAssertEqual(workspace.draft(in: "general"), "Repeat this question")
        XCTAssertFalse(workspace.isSaving(in: "general"))
    }

    func testCanonicalSendClearsOnlyCapturedTextAndProducesLaterReceiptCheckpoint() throws {
        var workspace = ChatWorkspace()
        workspace.setDraft("A durable question", in: "general")
        let submission = try XCTUnwrap(workspace.beginSubmission(in: "general"))
        let captured = try XCTUnwrap(submission.checkpoint)
        let canonical = consumed(submission, captured)
        XCTAssertTrue(workspace.complete(submission, stored: canonical, receiptID: submission.id))
        let acknowledged = try XCTUnwrap(workspace.checkpoint(in: "general"))
        XCTAssertEqual(acknowledged.text, "")
        XCTAssertNotEqual(acknowledged.textRevision, captured.textRevision)
        XCTAssertEqual(acknowledged.selectedHead, submission.id)
        XCTAssertEqual(acknowledged.acknowledgedSubmissionID, submission.id)
        XCTAssertGreaterThan(acknowledged.revision, canonical.revision)
        let nextHead = UUID()
        workspace.recordSelectedHead(nextHead, for: submission.composerID)
        let advanced = try XCTUnwrap(workspace.checkpoint(in: "general"))
        XCTAssertEqual(advanced.selectedHead, nextHead)
        XCTAssertEqual(advanced.branchRevision, captured.branchRevision)
        XCTAssertEqual(advanced.acknowledgedSubmissionID, submission.id)
        let token = try XCTUnwrap(workspace.beginCheckpoint(for: submission.composerID))
        workspace.acknowledge(token, stored: token.draft)
        XCTAssertEqual(workspace.draftStatus(in: "general"), .saved)
    }

    func testObservedReceiptAllowsLaterAutomaticHeadToSurviveSendCompletion() throws {
        var workspace = ChatWorkspace()
        workspace.setDraft("Question", in: "general")
        let submission = try XCTUnwrap(workspace.beginSubmission(in: "general"))
        let canonical = consumed(submission, try XCTUnwrap(submission.checkpoint))
        workspace.restore([canonical])
        let laterHead = UUID()
        workspace.recordSelectedHead(laterHead, for: submission.composerID)
        XCTAssertTrue(workspace.complete(submission, stored: canonical, receiptID: submission.id))
        XCTAssertEqual(workspace.checkpoint(in: "general")?.selectedHead, laterHead)
    }

    func testDiscardRetiresOnlyCapturedRevisionAndRehomesAnInterveningEdit() throws {
        var workspace = ChatWorkspace()
        workspace.setDraft("Original", in: "general")
        let original = try XCTUnwrap(workspace.composerID(in: "general"))
        let oldCheckpoint = try XCTUnwrap(workspace.beginCheckpoint(for: original))
        let discard = try XCTUnwrap(workspace.prepareDiscard(original))
        XCTAssertTrue(workspace.isDiscarding(in: "general"))
        XCTAssertNil(workspace.beginSubmission(in: "general"), "Do not send a composer while its deletion is pending")
        workspace.setDraft("Edited during deletion", in: "general")
        workspace.select(nil, in: "general")
        workspace.setDraft("Current conversation", in: "general")
        let current = workspace.composerID(in: "general")
        let rehomed = try XCTUnwrap(workspace.completeDiscard(discard))
        XCTAssertNotEqual(rehomed, original)
        XCTAssertEqual(workspace.composerID(in: "general"), current)
        XCTAssertEqual(workspace.checkpoint(for: rehomed)?.text, "Edited during deletion")
        XCTAssertNil(workspace.checkpoint(for: rehomed)?.acknowledgedSubmissionID)
        workspace.acknowledge(oldCheckpoint, stored: oldCheckpoint.draft)
        workspace.restore([oldCheckpoint.draft])
        XCTAssertNil(workspace.checkpoint(for: original))
        XCTAssertTrue(workspace.unsentDrafts.contains { $0.id == rehomed })
    }

    func testDiscardFailureAndOldWorkspaceAcknowledgementsCannotRemoveLiveText() throws {
        var workspace = ChatWorkspace()
        workspace.setDraft("Keep me", in: "general")
        let id = try XCTUnwrap(workspace.composerID(in: "general"))
        let checkpoint = try XCTUnwrap(workspace.beginCheckpoint(for: id))
        let discard = try XCTUnwrap(workspace.prepareDiscard(id))
        workspace.setDraft("Keep newer text", in: "general")
        workspace.failDiscard(discard)
        XCTAssertFalse(workspace.isDiscarding(in: "general"))
        XCTAssertEqual(workspace.composerID(in: "general"), id)
        XCTAssertEqual(workspace.draft(in: "general"), "Keep newer text")
        XCTAssertNil(workspace.completeDiscard(discard))

        workspace = ChatWorkspace()
        workspace.restore([checkpoint.draft])
        workspace.setDraft("New account-session edit", in: "general")
        workspace.acknowledge(checkpoint, stored: checkpoint.draft)
        workspace.failCheckpoint(checkpoint, message: "Old session")
        workspace.completeDiscard(discard)
        XCTAssertEqual(workspace.draft(in: "general"), "New account-session edit")
        XCTAssertEqual(workspace.draftStatus(in: "general"), .changed)
    }

    func testDisplacedHistoricalDraftRemainsReachableAndRehomingDropsReceipt() throws {
        let conversation = UUID()
        var stored = draft("Stored follow-up", conversation: conversation, time: 1)
        stored.acknowledgedSubmissionID = UUID(); stored.selectedHead = UUID()
        var workspace = ChatWorkspace()
        workspace.select(conversation, in: "general")
        workspace.setDraft("Live history edit", in: "general")
        let live = workspace.composerID(in: "general")
        workspace.restore([stored])
        XCTAssertEqual(workspace.composerID(in: "general"), live)
        XCTAssertTrue(workspace.unsentDrafts.contains { $0.id == stored.id })
        let discard = try XCTUnwrap(workspace.prepareDiscard(stored.id))
        _ = workspace.selectDraft(stored.id)
        workspace.setDraft("Edit rescued from discard", in: "general")
        let replacement = try XCTUnwrap(workspace.completeDiscard(discard))
        let rescued = try XCTUnwrap(workspace.checkpoint(for: replacement))
        XCTAssertNil(rescued.acknowledgedSubmissionID)
        XCTAssertEqual(rescued.conversationID, conversation)
        XCTAssertEqual(rescued.selectedHead, stored.selectedHead)
        workspace.select(conversation, in: "general")
        XCTAssertEqual(workspace.composerID(in: "general"), replacement)
        XCTAssertTrue(workspace.unsentDrafts.contains { $0.id == live })
    }

    func testPendingSubmissionIsEphemeralAndUntouchedEmptyComposersDoNotWrite() throws {
        var workspace = ChatWorkspace()
        workspace.select(nil, in: "general")
        let untouched = try XCTUnwrap(workspace.composerID(in: "general"))
        XCTAssertNotNil(workspace.checkpoint(for: untouched))
        XCTAssertNil(workspace.beginCheckpoint(for: untouched))
        workspace.setDraft("A question before termination", in: "general")
        let submission = try XCTUnwrap(workspace.beginSubmission(in: "general"))
        var restarted = ChatWorkspace()
        restarted.restore([try XCTUnwrap(submission.checkpoint)])
        XCTAssertFalse(restarted.isSaving(in: "general"))
        XCTAssertNil(restarted.conversation(in: "general"))
        XCTAssertEqual(restarted.draft(in: "general"), "A question before termination")
        XCTAssertNotNil(restarted.beginSubmission(in: "general"))
    }

    func testDeletedConversationKeepsFollowUpDraftReachableWithoutChangingItsBinding() throws {
        let conversation = UUID()
        let saved = draft("Follow-up to recover", conversation: conversation, time: 1)
        var workspace = ChatWorkspace()
        workspace.restore([saved])
        XCTAssertTrue(workspace.unsentDrafts.isEmpty)
        workspace.setDeletedConversations([conversation])
        XCTAssertEqual(workspace.unsentDrafts.map(\.id), [saved.id])
        workspace.select(nil, in: "general")
        XCTAssertEqual(workspace.selectDraft(saved.id), "general")
        XCTAssertEqual(workspace.draft(in: "general"), saved.text)
        XCTAssertEqual(workspace.conversation(in: "general"), conversation)
        XCTAssertEqual(workspace.checkpoint(for: saved.id)?.conversationID, conversation)
        let discard = try XCTUnwrap(workspace.prepareDiscard(saved.id))
        workspace.completeDiscard(discard)
        XCTAssertNil(workspace.checkpoint(for: saved.id))
        XCTAssertTrue(workspace.unsentDrafts.isEmpty)
    }

    private func draft(_ text: String, document: UUID? = nil, conversation: UUID? = nil, time: TimeInterval) -> LocalDraft {
        LocalDraft(id: UUID(), documentID: document, conversationID: conversation, revision: 1,
            textRevision: UUID(), text: text, editedAt: Date(timeIntervalSince1970: time), branchRevision: UUID())
    }

    private func consumed(_ submission: ChatWorkspace.Submission, _ captured: LocalDraft) -> LocalDraft {
        var result = captured
        result.conversationID = submission.conversationID
        result.text = ""; result.selectedHead = submission.id; result.acknowledgedSubmissionID = submission.id
        return result
    }
}
