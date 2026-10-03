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
}
