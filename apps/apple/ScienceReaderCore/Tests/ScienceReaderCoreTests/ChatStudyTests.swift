import Foundation
import Testing
@testable import ScienceReaderCore

/// Study (ChatStudy.swift, 2026-10-14): the knowledge map, the tutored request and the `study` stream event.
@Suite struct ChatStudyTests {
    static let sample = StudyMap(concepts: [
        StudyMap.Concept(id: "scaling", label: "Scaled dot-product attention", state: .learning, paragraphs: [2], note: "Mixes up d_k and d_model"),
        StudyMap.Concept(id: "softmax", label: "Softmax saturation", state: .unknown, paragraphs: [2]),
        StudyMap.Concept(id: "end", label: "End of sequence", state: .known, paragraphs: [])],
        links: [StudyMap.Link(from: "softmax", to: "scaling", kind: .prerequisite), StudyMap.Link(from: "scaling", to: "end", kind: .deeper)],
        focus: "scaling", journey: ["scaling", "softmax", "scaling"], next: .verify)
    static func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    static var sampleJSON: [String: Any] { [
        "concepts": [["id": "scaling", "label": "Scaled dot-product attention", "state": "learning", "paragraphs": [2], "note": "Mixes up d_k and d_model"],
                     ["id": "softmax", "label": "Softmax saturation", "state": "unknown", "paragraphs": [2]],
                     ["id": "end", "label": "End of sequence", "state": "known", "paragraphs": []]],
        "links": [["from": "softmax", "to": "scaling", "kind": "prerequisite"], ["from": "scaling", "to": "end", "kind": "deeper"]],
        "focus": "scaling", "journey": ["scaling", "softmax", "scaling"], "next": "verify"] }

    @Test func validationKeepsWholeMapsOnlyAndCleansWhatItKeeps() {
        #expect(StudyMap.validated(Self.json(Self.sampleJSON)) == Self.sample)
        let cleaned = StudyMap.validated(Self.json(["concepts": [["id": "scaling", "label": " Scaled\u{0}attention ", "state": "known", "paragraphs": [2, 2, 0, 1_000_000_000]]],
                                                    "links": [], "focus": "ghost", "journey": [], "next": "sideways"]))
        #expect(cleaned == StudyMap(concepts: [StudyMap.Concept(id: "scaling", label: "Scaled attention", state: .known, paragraphs: [2])], links: [], focus: nil, journey: [], next: .calibrate))
        var broken = Self.sampleJSON
        broken["concepts"] = [["id": "x", "label": "x", "state": "mastered", "paragraphs": []]]
        #expect(StudyMap.validated(Self.json(broken)) == nil, "unknown state")
        broken = Self.sampleJSON; broken["links"] = [["from": "scaling", "to": "ghost", "kind": "related"]]
        #expect(StudyMap.validated(Self.json(broken)) == nil, "dangling link")
        broken = Self.sampleJSON; broken["links"] = [["from": "scaling", "to": "scaling", "kind": "related"]]
        #expect(StudyMap.validated(Self.json(broken)) == nil, "self link")
        broken = Self.sampleJSON; broken["journey"] = ["ghost"]
        #expect(StudyMap.validated(Self.json(broken)) == nil, "journey off the map")
        broken = Self.sampleJSON; broken["concepts"] = (broken["concepts"] as! [[String: Any]]) + [["id": "scaling", "label": "dup", "state": "known", "paragraphs": []]]
        #expect(StudyMap.validated(Self.json(broken)) == nil, "duplicate id")
        #expect(StudyMap.validated(Self.json(["concepts": []])) == nil, "no links")
        #expect(StudyMap.validated(Self.json(["concepts": [], "links": [], "journey": []])) == .empty)
        #expect(Self.sample.summary == "3 concepts · 1 known · 1 learning · 1 not yet")
        #expect(StudyMap.empty.summary == "Built from your answers as you go")
        #expect(Self.sample.focusConcept?.label == "Scaled dot-product attention")
    }

    @Test func mermaidUsesSafeIdsQuotedCleanedLabelsAndStateClasses() {
        var map = Self.sample
        map.concepts[2] = StudyMap.Concept(id: "end", label: "End \"of\" [seq] {x} <y>", state: .known, paragraphs: [])
        let source = map.mermaid
        #expect(source.hasPrefix("flowchart TD\n"))
        #expect(source.contains("s_scaling[\"Scaled dot-product attention\"]:::learning"))
        #expect(source.contains("s_end[\"End of seq x y\"]:::known"))
        #expect(source.contains("s_softmax --> s_scaling")); #expect(source.contains("s_scaling -.-> s_end"))
        #expect(source.contains("style s_scaling stroke-width:3px"))
        #expect(!source.contains("\n  end"))
        #expect(StudyMap.empty.mermaid.contains("classDef verified"))
    }

    @Test func aStudyTurnCarriesTheMapNeedsNoSelectionAndAsksForNoFollowUps() throws {
        let request = try ChatGenerationRequest.make(operationID: UUID(), documentID: nil, transcript: [ChatTurnInput(role: .user, text: StudyMap.startMessage())],
                                                     selection: nil, action: .study, topicTitle: true, study: Self.sample)
        #expect(request.action == .study); #expect(request.study == Self.sample); #expect(request.selection == nil)
        let body = try JSONSerialization.jsonObject(with: request.encoded()) as! [String: Any]
        #expect(body["action"] as? String == "study"); #expect(body["follow_ups"] == nil); #expect(body["topic_title"] as? Bool == true)
        let study = body["study"] as! [String: Any]
        #expect((study["concepts"] as! [[String: Any]]).count == 3); #expect(study["focus"] as? String == "scaling"); #expect(study["next"] as? String == "verify")
        // The first turn sends an empty map; other actions still need their quote and carry no map.
        let first = try ChatGenerationRequest.make(operationID: UUID(), documentID: nil, transcript: [ChatTurnInput(role: .user, text: "Start")], selection: nil, action: .study)
        #expect(first.study == .empty)
        let firstBody = try JSONSerialization.jsonObject(with: first.encoded()) as! [String: Any]
        #expect(((firstBody["study"] as! [String: Any])["concepts"] as! [Any]).isEmpty)
        let plain = try ChatGenerationRequest.make(operationID: UUID(), documentID: nil, transcript: [ChatTurnInput(role: .user, text: "x")], selection: nil, action: .relevance, study: Self.sample)
        #expect(plain.action == nil); #expect(plain.study == nil)
        #expect(StudyMap.startMessage(selection: "divide by sqrt(d_k)").contains("divide by sqrt(d_k)"))
        #expect(StudyMap.startMessage(selection: "  ") == "Start studying this paper.")
    }

    @Test func parserReadsTheStudyEventAndDropsUnusableMapsAndReadsFailureCredits() throws {
        var parser = ChatSSEParser()
        let payload = String(decoding: Self.json(["map": Self.sampleJSON]), as: UTF8.self)
        let events = try parser.consume(Array("event: study\ndata: \(payload)\n\n".utf8))
        #expect(events == [.study(Self.sample)])
        for body in ["{\"map\":{\"concepts\":[{\"id\":\"x\",\"label\":\"x\",\"state\":\"fluent\",\"paragraphs\":[]}],\"links\":[],\"journey\":[]}}", "{\"map\":\"none\"}", "{}"] {
            var ignored = ChatSSEParser()
            #expect(try ignored.consume(Array("event: study\ndata: \(body)\n\n".utf8)).isEmpty, Comment(rawValue: body))
        }
        var failure = ChatSSEParser()
        #expect(try failure.consume(Array("event: error\ndata: {\"code\":\"provider_unavailable\",\"credits\":0}\n\n".utf8)) == [.failure(code: "provider_unavailable", credits: 0)])
        #expect(try failure.consume(Array("event: error\ndata: {\"code\":\"provider_unavailable\",\"credits\":-1}\n\n".utf8)) == [.failure(code: "provider_unavailable", credits: nil)])
        #expect(try failure.consume(Array("event: error\ndata: {\"code\":\"refused\"}\n\n".utf8)) == [.failure(code: "refused")])
    }
}
