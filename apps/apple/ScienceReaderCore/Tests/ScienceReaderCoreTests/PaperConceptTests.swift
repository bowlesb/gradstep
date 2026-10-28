import Foundation
import Testing
@testable import ScienceReaderCore

/// "Go deeper" on a key concept of the paper's AI Explainer (PaperConcept.swift; JUDGMENT_LOG 27): the request, the checks
/// of the server's events, the progress bar's words, and what is kept with the explainer.
@Suite struct PaperConceptTests {
    static func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    static let item = PaperExplainer.Item(id: "b2", name: "Bradley-Terry preference model", line: "Turns pairwise preferences into probabilities.", paragraphs: [18, 19])
    static var context: LocalPaperChatContext {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundle = try! DeviceReaderPackage.decode(Data(contentsOf: root.appendingPathComponent("tests/fixtures/reader-arxiv/package.json")))
        return try! LocalPaperChatContext(reference: try! SourcePaperReference(membershipID: UUID(), sourceID: "2601.01234", revision: 2), bundle: bundle)
    }

    @Test func theRequestIsTheExplainersWithTheConceptAsItsPassage() throws {
        let request = try ChatGenerationRequest.paperConcept(operationID: UUID(), item: Self.item, kind: .background, profile: .standard,
                                                             localContext: Self.context, visualAnswers: true)
        #expect(request.action == .paperConcept)
        #expect(request.turns.map(\.text) == ["Go deeper: Bradley-Terry preference model"])
        // As scripts/paper-concept-probe.mjs sends it (the server's instructions name these parts).
        #expect(request.selection == "Concept: Bradley-Terry preference model\nKind: background the paper assumes\nThe explainer's line: Turns pairwise preferences into probabilities.\nParagraphs: [¶18] [¶19]")
        #expect(request.figures.isEmpty)
        let body = try #require(JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        #expect(body["action"] as? String == "paper_concept")
        #expect(body["topic_title"] == nil && body["follow_ups"] == nil, "no conversation: no title, no suggestions")
        // The explainer's own capabilities, so the server offers the same tools: the concept reads the explainer's cached paper.
        let explainer = try ChatGenerationRequest.paperExplainer(operationID: UUID(), profile: .standard, localContext: Self.context, visualAnswers: true)
        let explainerBody = try #require(JSONSerialization.jsonObject(with: explainer.encoded()) as? [String: Any])
        #expect(body["capabilities"] as? [String] == explainerBody["capabilities"] as? [String])
        let idea = PaperConcept.selection(.init(id: "i1", name: "DPO loss", line: "", paragraphs: []), kind: .idea)
        #expect(idea == "Concept: DPO loss\nKind: one of this paper's own ideas")
        #expect(ChatAction.paperConcept.isExplainer)
    }

    @Test func eventsAreCheckedAsTheServerChecksThem() throws {
        let raw: [String: Any] = ["format": "paper-concept-v1", "sections": [
            ["kind": "what", "title": "What it is", "text": "A model of pairwise choices [¶18].", "paragraphs": [18, 0, 18, 999]],
            ["kind": "where", "title": "Where it appears", "text": "", "places": [["paragraph": 18, "note": "Introduced"], ["paragraph": 18, "note": "again"],
                                                                                 ["paragraph": 0, "note": "none"], ["paragraph": 30, "note": String(repeating: "x", count: 200)]]],
            ["kind": "why", "title": "", "text": "No title"],
            ["kind": "why", "title": "Why", "text": ""],
            ["title": String(repeating: "t", count: 61), "text": "Too long a title"],
        ]]
        let concept = try #require(PaperConcept.validated(Self.json(raw), paragraphs: 100))
        #expect(concept.sections.map(\.title) == ["What it is", "Where it appears"], "no title, no words, or a title the server never sends: left out")
        #expect(concept.sections[0].paragraphs == [18], "within the paper, each once")
        #expect(concept.sections[0].known == .what)
        #expect(concept.sections[1].places == [.init(paragraph: 18, note: "Introduced")], "each paragraph once; a note longer than the server sends is dropped")
        #expect(concept.sections[1].known == .where)
        #expect(PaperConcept.validated(Self.json(["format": "paper-concept-v0", "sections": raw["sections"]!])) == nil, "an unknown format")
        #expect(PaperConcept.validated(Self.json(["format": "paper-concept-v1", "sections": [["title": "x", "text": ""]]])) == nil, "nothing usable")
        let streamed = try #require(PaperConcept.streamedSection(Self.json(["index": 1, "section": ["kind": "why", "title": "Why", "text": "Because [¶4]."]])))
        #expect(streamed.index == 1 && streamed.section.text == "Because [¶4].")
        #expect(PaperConcept.streamedSection(Self.json(["index": 6, "section": ["title": "Why", "text": "x"]])) == nil, "past the sixth")
        // Through the stream parser, as the server sends them.
        var parser = ChatSSEParser()
        let frames = "event: concept_progress\ndata: {\"stage\":\"writing\",\"characters\":420,\"parts\":5}\n\n"
            + "event: concept_section\ndata: {\"index\":0,\"section\":{\"kind\":\"what\",\"title\":\"What it is\",\"text\":\"x\",\"paragraphs\":[]}}\n\n"
            + "event: paper_concept\ndata: \(String(data: Self.json(raw), encoding: .utf8)!)\n\n"
        let events = try parser.consume(Data(frames.utf8))
        #expect(events.count == 3)
        #expect(events.first == .conceptProgress(FigureStreamProgress(stage: .writing, characters: 420, parts: 5)))
        // The stream doesn't know the paper's block count (the server checked against it): every paragraph number is kept.
        #expect(events.last == PaperConcept.validated(Self.json(raw)).map(ChatStreamEvent.paperConcept))
        #expect(concept.text.hasSuffix("**Where it appears**\n\n- [¶18] Introduced"))
    }

    @Test func theBarReadsThePaperThenCountsSectionsAndSaysWhileItWaits() {
        var tracker = PaperConceptTracker()
        var labels: [String] = []
        func step(_ event: ChatStreamEvent? = nil) { if let event { tracker.apply(event) }; labels.append(tracker.state().label) }
        step()
        tracker.opened(); step()
        step(.status(ChatProgress(kind: .waiting)))
        step(.status(ChatProgress(kind: .switching, query: "Claude Haiku 5.5")))
        #expect(labels == ["Preparing the paper…", "Reading the paper…", "Still waiting for the model…", "Switching to Claude Haiku 5.5…"])
        tracker.apply(.conceptProgress(FigureStreamProgress(stage: .writing, characters: 300, parts: 4)))
        let writing = tracker.state()
        #expect(writing.label == "Writing section 1 of 4…")
        #expect((writing.value ?? 0) > 0 && (writing.value ?? 1) < 0.25)
        step(.status(ChatProgress(kind: .waiting)))
        #expect(labels.last == "Writing section 1 of 4…", "a notice never replaces the writing")
        let section = PaperConcept.Section(kind: "what", title: "What it is", text: "x")
        let first = tracker.apply(.conceptSection(index: 0, section: section)), repeated = tracker.apply(.conceptSection(index: 0, section: section))
        #expect(first && !repeated, "each section once")
        step()
        #expect(labels.last == "Writing section 2 of 4…")
        #expect(tracker.conceptSoFar?.sections.count == 1)
        let final = PaperConcept(sections: [section, .init(title: "Why", text: "y")])
        tracker.apply(.paperConcept(final))
        #expect(tracker.conceptSoFar == final, "the final concept replaces what streamed")
    }

    @Test func aDeepenedConceptIsKeptWithTheExplainerAndOlderFilesStillOpen() throws {
        // An explainer kept before concepts existed decodes without them.
        let old = #"{"text":"","model":"gemini-3.8-flash","explainer":{"format":"paper-explainer-v1","summary":"S","background":[{"id":"b2","name":"BT","line":"","paragraphs":[18]}],"ideas":[],"links":[]}}"#
        let decoded = try JSONDecoder().decode(PaperExplainerAnswer.self, from: Data(old.utf8))
        #expect(decoded.concepts == nil && decoded.deepened.isEmpty)
        var answer = decoded
        let deeper = PaperConceptAnswer(concept: PaperConcept(sections: [.init(kind: "what", title: "What it is", text: "x [¶18]", paragraphs: [18])]),
                                        model: "claude-haiku-5-5", savedAt: Date(timeIntervalSince1970: 1_700_000_000))
        answer.concepts = ["b2": deeper]
        let again = try JSONDecoder().decode(PaperExplainerAnswer.self, from: JSONEncoder().encode(answer))
        #expect(again == answer)
        #expect(again.deepened == ["b2"])
        #expect(again.concepts?["b2"]?.words == "**What it is**\n\nx [¶18]")
        // Sealed in the explainer's own file, written again under the name it was read from.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("concept-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EquationResultStore(directory: directory, accountID: UUID(), localKey: Data(repeating: 7, count: 32))
        let key = PaperExplainerKey(manifestSHA256: "m", profile: .standard)
        try store.write(decoded, for: key)
        let held = try #require(store.entries(as: PaperExplainerAnswer.self).first)
        try store.write(answer, fileName: held.fileName)
        #expect(store.read(key, as: PaperExplainerAnswer.self)?.deepened == ["b2"], "the same file, still opened by its key")
        #expect(store.entries(as: PaperExplainerAnswer.self).count == 1, "no copy")
        #expect(throws: (any Error).self) { try store.write(answer, fileName: "../x.sealed") }
    }

    @Test func yourAIUsageNamesIt() {
        #expect(AIUsageFormat.activityLabel(.chat, provenance: .init(kind: .paper, action: "paper_concept", itemID: "b2")) == "Concept explainer")
        #expect(AIUsageFormat.activityLabel(.chat, provenance: .init(kind: .paper, action: "paper_explainer", itemID: "paper")) == "AI Explainer")
    }
}
