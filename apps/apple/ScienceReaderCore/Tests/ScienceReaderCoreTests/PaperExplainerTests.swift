import Foundation
import Testing
@testable import ScienceReaderCore

/// The paper's AI Explainer (PaperExplainer.swift) against the fixture the browser's paper-explainer.ts is checked against
/// too (tests/fixtures/paper-explainer.json): the same diagram source, plain text and progress bar, exactly.
@Suite struct PaperExplainerTests {
    static var fixture: [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try! Data(contentsOf: root.appendingPathComponent("tests/fixtures/paper-explainer.json"))
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }

    @Test func diagramAndTextAreTheFixtures() throws {
        let cases = try #require(Self.fixture["explainers"] as? [[String: Any]])
        #expect(cases.count >= 2)
        for entry in cases {
            let name = entry["name"] as? String ?? "?"
            let raw = try #require(entry["explainer"])
            // As the browser's fixture generator: the drawing and text functions on the explainer as written (the first case
            // is a checked explainer from the evaluation; the second deliberately exceeds the checks' limits).
            let explainer = try JSONDecoder().decode(PaperExplainer.self, from: Self.json(raw))
            #expect(explainer.mermaid == entry["mermaid"] as? String, Comment(rawValue: name))
            #expect(explainer.text == entry["text"] as? String, Comment(rawValue: name))
        }
    }

    @Test func progressIsTheFixtures() throws {
        let stated = try #require(Self.fixture["parameters"] as? [String: Any])
        #expect(Set(stated.keys) == Set(PaperExplainerProgress.Parameters.all.keys))
        for (name, value) in PaperExplainerProgress.Parameters.all { #expect((stated[name] as? NSNumber)?.doubleValue == value, Comment(rawValue: name)) }
        let cases = try #require(Self.fixture["progress"] as? [[String: Any]])
        #expect(cases.count >= 10)
        for entry in cases {
            let i = try #require(entry["input"] as? [String: Any]), e = try #require(entry["expected"] as? [String: Any])
            let stage = try #require((i["stage"] as? String).flatMap(PaperExplainerProgress.Stage.init(rawValue:)))
            let input = PaperExplainerProgress.Input(stage: stage,
                summary: i["summary"] as? Bool ?? false, items: (i["items"] as? NSNumber)?.intValue ?? 0, ideas: (i["ideas"] as? NSNumber)?.intValue ?? 0,
                characters: (i["characters"] as? NSNumber)?.intValue ?? 0, charactersAtLast: (i["charactersAtLast"] as? NSNumber)?.intValue ?? 0,
                expected: (i["expected"] as? NSNumber)?.intValue, previous: (i["previous"] as? NSNumber)?.doubleValue)
            let state = PaperExplainerProgress.state(input)
            #expect(state.label == e["label"] as? String, Comment(rawValue: entry["name"] as? String ?? "?"))
            #expect(state.value == (e["value"] as? NSNumber)?.doubleValue, Comment(rawValue: entry["name"] as? String ?? "?"))
        }
    }

    @Test func checksDropWhatIsUnusableAndKeepTheRest() throws {
        let raw: [String: Any] = ["format": "paper-explainer-v1", "summary": "S.", "background": [
            ["id": "b1", "name": "Softmax", "line": "x", "paragraphs": [4, 4, 99, 0]], ["id": "B 2", "name": "Bad id"], ["id": "b3", "name": ""],
            ["id": "b1", "name": "Duplicate"]],
            "ideas": [["id": "i1", "name": "Attention", "line": String(repeating: "l", count: 300), "paragraphs": [5]]],
            "links": [["from": "b1", "to": "i1", "label": "feeds"], ["from": "i1", "to": "i1"], ["from": "b1", "to": "ghost"], ["from": "b1", "to": "i1", "label": "again"]]]
        let checked = try #require(PaperExplainer.validated(Self.json(raw), paragraphs: 30))
        #expect(checked.background == [PaperExplainer.Item(id: "b1", name: "Softmax", line: "x", paragraphs: [4])])
        #expect(checked.ideas == [PaperExplainer.Item(id: "i1", name: "Attention", line: "", paragraphs: [5])], "a line over 240 characters is left out")
        #expect(checked.links == [PaperExplainer.Link(from: "b1", to: "i1", label: "feeds")])
        #expect(PaperExplainer.validated(Self.json(["format": "other", "background": [["id": "b1", "name": "x"]]])) == nil)
        #expect(PaperExplainer.validated(Self.json(["format": "paper-explainer-v1", "background": []])) == nil)
    }

    @Test func streamedEventsParseAndTheTrackerShowsThemInOrder() throws {
        var parser = ChatSSEParser()
        let stream = """
        event: paper_progress
        data: {"stage":"reading"}

        event: paper_progress
        data: {"stage":"writing","characters":120,"items":3}

        event: paper_summary
        data: {"summary":"The paper does one thing."}

        event: paper_item
        data: {"kind":"background","index":0,"item":{"id":"b1","name":"Softmax","line":"Weights.","paragraphs":[4]}}

        event: paper_item
        data: {"kind":"elsewhere","index":0,"item":{"id":"b1","name":"x"}}

        event: paper_item
        data: {"kind":"idea","index":0,"item":{"id":"i1","name":"Attention","line":"","paragraphs":[]}}

        event: paper_progress
        data: {"stage":"sideways"}


        """
        let events = try parser.consume(Array(stream.utf8))
        #expect(events.count == 5, "an unknown kind and an unknown stage are dropped, never fatal")
        var tracker = PaperExplainerProgress.Tracker()
        tracker.opened()
        #expect(tracker.state().label == "Reading the paper…")
        var changed = 0
        for event in events { if tracker.apply(event) { changed += 1 } }
        #expect(changed == 3)
        #expect(tracker.explainerSoFar?.summary == "The paper does one thing.")
        #expect(tracker.explainerSoFar?.background.map(\.id) == ["b1"]); #expect(tracker.explainerSoFar?.ideas.map(\.id) == ["i1"])
        let state = tracker.state()
        #expect(state.label == "Writing the key ideas, 3 of 3…"); #expect(state.value != nil)
        // The final explainer replaces what streamed.
        let final = PaperExplainer(summary: "Final.", background: [.init(id: "b1", name: "Softmax", line: "", paragraphs: [])], ideas: [], links: [])
        let replaced = tracker.apply(.paperExplainer(final)); #expect(replaced)
        #expect(tracker.explainerSoFar == final)
    }

    @Test func theRequestIsTheChatsOwnWithTheActionAndNoPassage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundle = try DeviceReaderPackage.decode(Data(contentsOf: root.appendingPathComponent("tests/fixtures/reader-arxiv/package.json")))
        let context = try LocalPaperChatContext(reference: try SourcePaperReference(membershipID: UUID(), sourceID: "2601.01234", revision: 2), bundle: bundle)
        let request = try ChatGenerationRequest.paperExplainer(operationID: UUID(), profile: .standard, localContext: context, visualAnswers: true)
        let body = try JSONSerialization.jsonObject(with: request.encoded()) as! [String: Any]
        #expect(body["action"] as? String == "paper_explainer"); #expect(body["selection"] == nil); #expect(body["figures"] == nil)
        #expect(body["follow_ups"] == nil); #expect(body["topic_title"] == nil); #expect(body["mode"] as? String == "paper")
        #expect((body["messages"] as? [[String: Any]])?.map { $0["text"] as? String } == ["Explain this paper"])
        #expect(body["capabilities"] as? [String] == ["visual_answers", "figure_requests", "figure_view", "stop_signal"], "the chat's capabilities: its cached tools")
        #expect(PaperExplainerKey(manifestSHA256: "a", profile: .standard).fileName != PaperExplainerKey(manifestSHA256: "b", profile: .standard).fileName)
    }
}
