import Foundation
import Testing
@testable import ScienceReaderCore

struct ChatDiagramTests {
    @Test func roundTripsAndRejectsUnknownOrOversizedContent() throws {
        let message = UUID()
        let diagram = try #require(ChatDiagram(title: "  DPO pipeline ", source: "flowchart LR\n a --> b", messageID: message))
        #expect(diagram.title == "DPO pipeline")
        #expect(ChatDiagram.decode(diagram.encodedText()) == diagram)
        #expect(ChatDiagram.decode("{\"format\":\"svg-v1\",\"title\":\"x\",\"source\":\"<svg/>\"}") == nil)
        #expect(ChatDiagram.decode("not json") == nil)
        #expect(ChatDiagram.decode(nil) == nil)
        #expect(ChatDiagram(title: "x", source: String(repeating: "a", count: ChatDiagram.maximumSourceBytes + 1), messageID: nil) == nil)
        #expect(ChatDiagram(title: String(repeating: "t", count: ChatDiagram.maximumTitleScalars + 1), source: "graph", messageID: nil) == nil)
    }

    @Test func diagramsAreIndexedByTheirAssistantMessage() throws {
        var state = PrivateState()
        let message = UUID(), deleted = UUID(), device = UUID()
        let first = try #require(ChatDiagram(title: "First", source: "graph TD; a-->b", messageID: message))
        let other = try #require(ChatDiagram(title: "Gone", source: "graph TD; c-->d", messageID: UUID()))
        let firstID = UUID()
        try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .diagram, entityID: firstID, text: first.encodedText())))
        try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .diagram, entityID: deleted, text: other.encodedText())))
        try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .tombstone, entityID: deleted)))
        try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .diagram, entityID: UUID(), text: "{}")))
        #expect(state.diagrams().map(\.id) == [firstID])
        #expect(state.diagramsByMessage() == [message: ChatDiagramLink(id: firstID, title: "First")])
        // Deleting the conversation removes its diagrams from the list.
        let conversation = UUID()
        let inChat = try #require(ChatDiagram(title: "In chat", source: "graph TD; e-->f", messageID: UUID()))
        try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .diagram, entityID: UUID(), conversationID: conversation, text: inChat.encodedText())))
        #expect(state.diagrams().count == 2)
        try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .tombstone, entityID: conversation)))
        #expect(state.diagrams().map(\.id) == [firstID])
    }
}
