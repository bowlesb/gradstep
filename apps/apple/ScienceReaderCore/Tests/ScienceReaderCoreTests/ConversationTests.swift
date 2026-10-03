import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct ConversationTests {
    @Test func causalMessagesStayOrderedAndConcurrentRepliesRemainSeparate() throws {
        let conversation = UUID(), device = UUID()
        let first = AppliedEvent(id: UUID(uuidString: "ffffffff-0000-4000-8000-000000000001")!, deviceID: device,
            payload: PrivateEvent(kind: .message, conversationID: conversation, text: "Question", role: .user, status: .complete))
        let second = AppliedEvent(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, deviceID: device,
            payload: PrivateEvent(kind: .message, parents: [first.id], conversationID: conversation, text: "Answer A", role: .assistant, status: .complete))
        let concurrent = AppliedEvent(id: UUID(), deviceID: UUID(),
            payload: PrivateEvent(kind: .message, parents: [first.id], conversationID: conversation, text: "Answer B", role: .assistant, status: .complete))
        var a = PrivateState(), b = PrivateState()
        for event in [concurrent, first, second] { try a.apply(event) }
        for event in [second, concurrent, first] { try b.apply(event) }
        #expect(a.conversationBranches(conversation) == b.conversationBranches(conversation))
        let branches = a.conversationBranches(conversation)
        #expect(branches.count == 2)
        #expect(branches.allSatisfy { $0.complete && $0.messages.count == 2 && $0.messages.first?.id == first.id })
        #expect(Set(branches.compactMap { $0.messages.last?.id }) == [second.id, concurrent.id])
    }

    @Test func missingOrForeignParentsDoNotCreateACompleteAIContext() throws {
        let conversation = UUID(), parentID = UUID(), device = UUID()
        var state = PrivateState()
        try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .message, parents: [parentID], conversationID: conversation, text: "child", role: .user, status: .complete)))
        #expect(state.conversationBranches(conversation).first?.complete == false)
        try state.apply(AppliedEvent(id: parentID, deviceID: device, payload: PrivateEvent(kind: .message, conversationID: UUID(), text: "another context", role: .user, status: .complete)))
        #expect(state.conversationBranches(conversation).first?.complete == false)
    }

    @Test func cyclesAreRejectedWhenAnEarlierMissingParentArrives() throws {
        let a = UUID(), b = UUID(), device = UUID()
        var state = PrivateState()
        try state.apply(AppliedEvent(id: a, deviceID: device, payload: PrivateEvent(kind: .note, parents: [b], text: "waiting")))
        #expect(throws: ReaderError.invalidEvent) { try state.apply(AppliedEvent(id: b, deviceID: device, payload: PrivateEvent(kind: .note, parents: [a], text: "cycle"))) }
        #expect(state.events.count == 1)
    }

    @Test func deletedIntermediateMessageDoesNotResurrectOrSplitItsBranch() throws {
        let conversation = UUID(), device = UUID(), firstID = UUID(), deletedID = UUID(), lastID = UUID(), deletedEntity = UUID()
        var state = PrivateState()
        try state.apply(AppliedEvent(id: firstID, deviceID: device, payload: PrivateEvent(kind: .message, conversationID: conversation, text: "first", role: .user, status: .complete)))
        try state.apply(AppliedEvent(id: deletedID, deviceID: device, payload: PrivateEvent(kind: .message, entityID: deletedEntity, parents: [firstID], conversationID: conversation, text: "deleted", role: .assistant, status: .complete)))
        try state.apply(AppliedEvent(id: lastID, deviceID: device, payload: PrivateEvent(kind: .message, parents: [deletedID], conversationID: conversation, text: "last", role: .user, status: .complete)))
        try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .tombstone, entityID: deletedEntity)))
        let branches = state.conversationBranches(conversation)
        #expect(branches.count == 1)
        #expect(branches.first?.messages.map(\.id) == [firstID, lastID])
    }

    @Test func retainedProjectionDoesNotJumpToASiblingWhenItsTipIsDeleted() throws {
        let conversation = UUID(), device = UUID(), common = UUID(), selected = UUID(), sibling = UUID(), later = UUID()
        var state = PrivateState()
        for (id, parents, text) in [(common, [UUID](), "Common question"), (selected, [common], "Chosen answer"), (sibling, [common], "Other answer")] {
            try state.apply(AppliedEvent(id: id, deviceID: device, payload: PrivateEvent(kind: .message, entityID: id,
                parents: parents, conversationID: conversation, text: text, role: .assistant, status: .complete)))
        }
        try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .tombstone, entityID: selected)))
        let retained = try #require(state.conversationBranch(conversation, through: selected))
        #expect(retained.head == selected && retained.complete)
        #expect(retained.messages.map(\.id) == [common])
        #expect(state.conversationBranches(conversation).map(\.head) == [sibling])

        try state.apply(AppliedEvent(id: later, deviceID: device, payload: PrivateEvent(kind: .message, entityID: later,
            parents: [selected], conversationID: conversation, text: "Continue the chosen path", role: .user, status: .complete)))
        let continuation = try #require(state.conversationBranch(conversation, through: later))
        #expect(continuation.complete && continuation.messages.map(\.id) == [common, later])
        #expect(state.conversationBranch(conversation, through: selected) == retained, "An interior projection never includes later replies or sibling text")
        #expect(state.conversationBranch(conversation, through: common)?.messages.map(\.id) == [common])
        #expect(state.conversationBranches(conversation).contains(continuation))
    }

    @Test func allDeletedMessagesKeepAnEmptyCausalProjectionButDeletedConversationsDoNot() throws {
        let conversation = UUID(), root = UUID(), first = UUID(), last = UUID(), device = UUID()
        var state = PrivateState()
        try state.apply(AppliedEvent(id: root, deviceID: device, payload: PrivateEvent(kind: .conversation, entityID: conversation, text: "Conversation")))
        for (id, parent) in [(first, root), (last, first)] {
            try state.apply(AppliedEvent(id: id, deviceID: device, payload: PrivateEvent(kind: .message, entityID: id,
                parents: [parent], conversationID: conversation, text: "Removed text", role: .user, status: .complete)))
            try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .tombstone, entityID: id)))
        }
        let empty = try #require(state.conversationBranch(conversation, through: last))
        #expect(empty.head == last && empty.messages.isEmpty && empty.complete)
        #expect(state.conversationBranches(conversation).isEmpty)
        #expect(state.conversationBranch(conversation, through: root) == nil, "A conversation root is not a message tip")

        let child = UUID()
        try state.apply(AppliedEvent(id: child, deviceID: device, payload: PrivateEvent(kind: .message, entityID: child,
            parents: [last], conversationID: conversation, text: "New content", role: .user, status: .complete)))
        #expect(state.conversationBranch(conversation, through: child)?.messages.map(\.id) == [child])
        try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .tombstone, entityID: conversation)))
        #expect(state.conversationBranch(conversation, through: last) == nil)
        #expect(state.conversationBranch(conversation, through: child) == nil)
        #expect(state.conversationBranches(conversation).isEmpty)
    }

    @Test func projectionRejectsForeignHeadsAndNeverTreatsBrokenAncestryAsComplete() throws {
        let conversation = UUID(), otherConversation = UUID(), device = UUID(), missingParent = UUID(), child = UUID()
        var state = PrivateState()
        try state.apply(AppliedEvent(id: child, deviceID: device, payload: PrivateEvent(kind: .message, parents: [missingParent],
            conversationID: conversation, text: "Own child", role: .user, status: .complete)))
        #expect(state.conversationBranch(conversation, through: UUID()) == nil)
        #expect(state.conversationBranch(otherConversation, through: child) == nil)
        #expect(state.conversationBranch(conversation, through: child)?.complete == false)

        try state.apply(AppliedEvent(id: missingParent, deviceID: device, payload: PrivateEvent(kind: .message,
            conversationID: otherConversation, text: "Foreign content", role: .assistant, status: .complete)))
        let broken = try #require(state.conversationBranch(conversation, through: child))
        #expect(!broken.complete && broken.messages.map(\.id) == [child])
        #expect(state.conversationBranch(conversation, through: missingParent) == nil)

        let first = UUID(), second = UUID(), merge = UUID()
        for id in [first, second] {
            try state.apply(AppliedEvent(id: id, deviceID: device, payload: PrivateEvent(kind: .message,
                conversationID: conversation, text: "Independent reply", role: .assistant, status: .complete)))
        }
        try state.apply(AppliedEvent(id: merge, deviceID: device, payload: PrivateEvent(kind: .message, parents: [first, second],
            conversationID: conversation, text: "Ambiguous merge", role: .user, status: .complete)))
        let ambiguous = try #require(state.conversationBranch(conversation, through: merge))
        #expect(!ambiguous.complete && ambiguous.messages.map(\.id) == [merge])
    }

    @Test func retainedProjectionResolvesReplacementChainsWithoutRevivingDeletedText() throws {
        let conversation = UUID(), device = UUID(), first = UUID(), tip = UUID(), nextFirst = UUID(), nextTip = UUID(), finalTip = UUID()
        let firstPayload = PrivateEvent(kind: .message, entityID: first, conversationID: conversation, text: "Keep this question", role: .user, status: .complete)
        let tipPayload = PrivateEvent(kind: .message, entityID: tip, parents: [first], conversationID: conversation, text: "Removed answer", role: .assistant, status: .complete)
        var state = PrivateState()
        try state.apply(AppliedEvent(id: first, deviceID: device, payload: firstPayload))
        try state.apply(AppliedEvent(id: tip, deviceID: device, payload: tipPayload))
        try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .tombstone, entityID: tip)))
        try state.apply(AppliedEvent(id: nextFirst, deviceID: device, payload: firstPayload))
        var replacement = tipPayload; replacement.parents = [nextFirst]
        try state.apply(AppliedEvent(id: nextTip, deviceID: device, payload: replacement))
        try state.applyLocalReplacements([first: nextFirst, tip: nextTip])
        try state.apply(AppliedEvent(id: finalTip, deviceID: device, payload: replacement))
        try state.applyLocalReplacements([nextTip: finalTip])

        let retained = try #require(state.conversationBranch(conversation, through: tip))
        #expect(retained.head == finalTip && retained.complete)
        #expect(retained.messages.map(\.id) == [nextFirst])
        #expect(retained.messages.map(\.payload.text) == ["Keep this question"])
        #expect(state.conversationBranch(conversation, through: nextTip) == retained)
    }
}
