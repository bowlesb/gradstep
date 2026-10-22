import Foundation
import Testing
@testable import ScienceReaderCore

/// Study mode (ChatStudy.swift, reworked 2026-10-22): the tutor's hidden notes, the tutored request and the `study_state`
/// stream event; the visual-suggestion pattern the server uses.
@Suite struct ChatStudyTests {
    static let notes = StudyNotes(turn: 2, level: .core, concepts: [
        StudyNotes.Concept(name: "Scaled dot-product attention", status: .shaky, asked: [1, 2], paras: [3, 4]),
        StudyNotes.Concept(name: "Softmax saturation", status: .new, asked: [2], paras: [4])], next: "check scaling from a new angle")
    static func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    static var notesJSON: [String: Any] { [
        "turn": 2, "level": "core", "next": "check scaling from a new angle",
        "concepts": [["name": "Scaled dot-product attention", "status": "shaky", "asked": [1, 2], "paras": [3, 4]],
                     ["name": "Softmax saturation", "status": "new", "asked": [2], "paras": [4]]]] }

    @Test func notesAreRepairedAsTheServerRepairsThem() throws {
        #expect(StudyNotes.validated(Self.json(Self.notesJSON)) == Self.notes)
        let repaired = try #require(StudyNotes.validated(Self.json(["turn": "x", "level": "expert", "next": " revisit\u{0} <softmax> ",
            "concepts": [["name": " Softmax ", "status": "mastered", "asked": [3, 1, 1, 0, 9_999], "paras": [40, 2, 2]], ["name": ""], "junk",
                         ["name": "softmax", "status": "ok", "asked": [2], "paras": [4]]]]), paragraphs: 30))
        #expect(repaired.turn == 1); #expect(repaired.level == .core); #expect(repaired.next == "revisit softmax")
        #expect(repaired.concepts == [StudyNotes.Concept(name: "softmax", status: .ok, asked: [2], paras: [4])], "a repeated name keeps the newest")
        let unknown = try #require(StudyNotes.validated(Self.json(["concepts": [["name": "A", "status": "mastered", "asked": [3, 1, 1, 0, 9_999], "paras": [40, 2, 2]]]]), paragraphs: 30))
        #expect(unknown.concepts == [StudyNotes.Concept(name: "A", status: .new, asked: [1, 3], paras: [2])])
        let many = try #require(StudyNotes.validated(Self.json(["concepts": (0..<20).map { ["name": "Concept \($0)", "status": "ok"] }])))
        #expect(many.concepts.count == 12); #expect(many.concepts.first?.name == "Concept 8", "the newest twelve are kept")
        #expect(StudyNotes.validated(Self.json([1, 2])) == nil)
        #expect(StudyNotes.validated(Self.json(["next": String(repeating: "n", count: 300)]))?.next.unicodeScalars.count == 200)
    }

    @Test func aStudyTurnCarriesTheNotesNeedsNoSelectionAndAsksForNoFollowUps() throws {
        let request = try ChatGenerationRequest.make(operationID: UUID(), documentID: nil, transcript: [ChatTurnInput(role: .user, text: StudyMode.opening)],
                                                     selection: nil, action: .study, topicTitle: true, studyNotes: Self.notes)
        #expect(request.action == .study); #expect(request.studyNotes == Self.notes); #expect(request.selection == nil)
        let body = try JSONSerialization.jsonObject(with: request.encoded()) as! [String: Any]
        #expect(body["action"] as? String == "study"); #expect(body["follow_ups"] == nil); #expect(body["topic_title"] as? Bool == true)
        #expect(body["study"] == nil, "the retired knowledge map is never sent")
        let state = try #require(body["study_state"] as? [String: Any])
        #expect(state["turn"] as? Int == 2); #expect(state["level"] as? String == "core")
        #expect(((state["concepts"] as? [[String: Any]])?.first?["paras"] as? [Int]) == [3, 4])
        // The first turn has no notes yet; other actions never carry them.
        let first = try ChatGenerationRequest.make(operationID: UUID(), documentID: nil, transcript: [ChatTurnInput(role: .user, text: StudyMode.opening)], selection: nil, action: .study)
        let firstBody = try JSONSerialization.jsonObject(with: first.encoded()) as! [String: Any]
        #expect(firstBody["study_state"] == nil); #expect(firstBody["action"] as? String == "study")
        let plain = try ChatGenerationRequest.make(operationID: UUID(), documentID: nil, transcript: [ChatTurnInput(role: .user, text: "x")], selection: nil,
                                                   action: .relevance, studyNotes: Self.notes)
        #expect(plain.action == nil); #expect(plain.studyNotes == nil)
        #expect(StudyMode.entry == "Enter Study Mode – Quiz me and help me learn")
    }

    @Test func parserReadsStudyStateAndDropsUnusableNotes() throws {
        var parser = ChatSSEParser()
        let payload = String(decoding: Self.json(["state": Self.notesJSON]), as: UTF8.self)
        #expect(try parser.consume(Array("event: study_state\ndata: \(payload)\n\n".utf8)) == [.studyState(Self.notes)])
        for body in ["{\"state\":[1]}", "{\"state\":\"none\"}", "{}", "[]"] {
            var ignored = ChatSSEParser()
            #expect(try ignored.consume(Array("event: study_state\ndata: \(body)\n\n".utf8)).isEmpty, Comment(rawValue: body))
        }
        // The retired `study` event is ignored as any unknown event.
        var old = ChatSSEParser()
        #expect(try old.consume(Array("event: study\ndata: {\"map\":{\"concepts\":[],\"links\":[],\"journey\":[]}}\n\n".utf8)).isEmpty)
        var failure = ChatSSEParser()
        #expect(try failure.consume(Array("event: error\ndata: {\"code\":\"provider_unavailable\",\"credits\":0}\n\n".utf8)) == [.failure(code: "provider_unavailable", credits: 0)])
    }

    @Test func visualSuggestionsAreTheServersPattern() {
        for q in ["Create a diagram explaining the background of RLHF", "Draw how attention flows step by step", "Show the DPO pipeline as a visual",
                  "Make a flowchart of the training loop", "please sketch the encoder"] { #expect(VisualFollowUp.isVisual(q), Comment(rawValue: q)) }
        for q in ["Show how DPO compares to PPO", "What does Figure 2 show?", "Show me Figure 3", "How is the reward model trained?"] {
            #expect(!VisualFollowUp.isVisual(q), Comment(rawValue: q))
        }
    }
}
