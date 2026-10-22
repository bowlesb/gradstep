import Foundation
import Testing
@testable import ScienceReaderCore

/// The figure view (FigureView.swift, docs/architecture/FIGURE_VIEW.md): the `figure` event, the crop of a box, the
/// request and the answers kept on the device.
@Suite struct FigureViewTests {
    static func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    static var event: [String: Any] { ["format": "figure-walkthrough-v1", "summary": "Two pipelines side by side.", "sections": [
        ["label": "Left panel", "title": "RLHF", "text": "The red panel fits a reward model [¶21].", "paragraphs": [21, 9]],
        ["label": "(b)", "title": "DPO", "text": "The teal panel skips it.", "paragraphs": [13], "box": ["x": 0.5, "y": 0, "w": 0.5, "h": 0.9]]]] }

    private func bundle() throws -> VerifiedReaderBundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try DeviceReaderPackage.decode(Data(contentsOf: root.appendingPathComponent("tests/fixtures/reader-arxiv/package.json")))
    }

    @Test func theEventIsCheckedAsTheServerChecksIt() throws {
        let walkthrough = try #require(FigureWalkthrough.validated(Self.json(Self.event)))
        #expect(walkthrough.summary == "Two pipelines side by side.")
        #expect(walkthrough.sections.map(\.name) == ["Left panel", "(b)"])
        #expect(walkthrough.sections[0].paragraphs == [21, 9]); #expect(walkthrough.sections[0].box == nil)
        #expect(walkthrough.sections[1].box == .init(x: 0.5, y: 0, w: 0.5, h: 0.9))
        // Degrades: no title takes the label, no text drops the section, a bad box drops the box, at most 12 boxes and 12 sections.
        let box: [String: Any] = ["x": 0.1, "y": 0.1, "w": 0.2, "h": 0.2]
        var rows: [[String: Any]] = [["label": "Inset", "title": "", "text": "Small print."], ["label": "x", "title": "t", "text": " "],
                                     ["label": "", "title": "Too thin", "text": "t", "box": ["x": 0.1, "y": 0.1, "w": 0.01, "h": 0.5]],
                                     ["label": "", "title": "Whole", "text": "t", "box": ["x": 0, "y": 0, "w": 1, "h": 1]],
                                     ["label": "", "title": "Outside", "text": "t", "box": ["x": 0.9, "y": 0.1, "w": 0.5, "h": 0.5]]]
        rows += Array(repeating: ["label": "", "title": "Boxed", "text": "t", "box": box], count: 12)
        let messy = try #require(FigureWalkthrough.validated(Self.json(["format": "figure-walkthrough-v1", "sections": rows])))
        #expect(messy.summary.isEmpty)
        #expect(messy.sections.count == FigureWalkthrough.maximumSections)
        #expect(messy.sections[0].label.isEmpty && messy.sections[0].title == "Inset")
        #expect(messy.sections[1].title == "Too thin" && messy.sections[1].box == nil)
        #expect(messy.sections[2].box == nil && messy.sections[3].box == nil, "the whole figure and a box outside it are no crops")
        #expect(messy.sections.compactMap(\.box).count == 8)
        #expect(FigureWalkthrough.validated(Self.json(["format": "figure-walkthrough-v1", "summary": "s", "sections": []])) == nil)
        #expect(FigureWalkthrough.validated(Self.json(["format": "other", "sections": Self.event["sections"]!])) == nil)
    }

    @Test func pixelCoverageDistinguishesCompleteSplitsFromHolesAndWholeFigureFallback() throws {
        func walk(_ boxes: [FigureWalkthrough.Box]) -> FigureWalkthrough {
            .init(summary: "", sections: boxes.map { .init(label: "", title: "Panel", text: "Text", box: $0) })
        }
        let grid = [0.0, 0.5].flatMap { y in [0.0, 1.0/3, 2.0/3].map { x in
            FigureWalkthrough.Box(x: x, y: y, w: 1.0/3, h: 0.5)
        } }
        #expect(walk(grid).cropCoverage(width: 1001, height: 503) == 1)
        #expect(walk(grid + [.init(x: 0.2, y: 0.2, w: 0.1, h: 0.1)]).cropCoverage(width: 1001, height: 503) == 1)
        let partial: [FigureWalkthrough.Box] = [.init(x: 0, y: 0, w: 0.7, h: 0.8), .init(x: 0.3, y: 0, w: 0.7, h: 0.8)]
        #expect(try #require(walk(partial).cropCoverage(width: 1001, height: 503)) < 0.83)
        let hole: [FigureWalkthrough.Box] = [.init(x: 0, y: 0, w: 0.4, h: 1), .init(x: 0.6, y: 0, w: 0.4, h: 1),
            .init(x: 0, y: 0, w: 1, h: 0.4), .init(x: 0, y: 0.6, w: 1, h: 0.4)]
        #expect(try #require(walk(hole).cropCoverage(width: 1001, height: 503)) < 1)
        #expect(walk([]).cropCoverage(width: 1001, height: 503) == nil)
        #expect(walk([.init(x: 0, y: 0, w: 1, h: 1)]).cropCoverage(width: 1001, height: 503) == nil)
    }

    @Test func cardKindsAreAdditiveAndDoNotCropNonPanelCards() throws {
        let row: [String: Any] = ["label": "", "title": "Prior method", "text": "This paper describes it.",
            "paragraphs": [2], "box": ["x": 0, "y": 0, "w": 0.5, "h": 1]]
        let rows = ["concept", "related_work", "future"].map { kind in row.merging(["kind": kind]) { _, new in new } } + [row]
        let walk = try #require(FigureWalkthrough.validated(Self.json(["format": FigureWalkthrough.format, "sections": rows])))
        #expect(walk.sections.map(\.typeLabel) == ["Concept", "Related work", "Panel", "Panel"])
        #expect(walk.sections.map { $0.box != nil } == [false, false, true, true])
        let old = try JSONDecoder().decode(FigureWalkthrough.Section.self, from: Self.json(row))
        #expect(old.cardKind == .panel)
        let restored = try JSONDecoder().decode(FigureWalkthrough.self, from: JSONEncoder().encode(walk))
        #expect(restored == walk)
    }

    @Test func theStreamCarriesTheWalkthroughAndIgnoresAnUnusableOne() throws {
        var parser = ChatSSEParser()
        let payload = String(decoding: Self.json(Self.event), as: UTF8.self)
        let events = try parser.consume(Array("event: figure\ndata: \(payload)\n\nevent: figure\ndata: {\"format\":\"x\"}\n\nevent: done\ndata: {\"stop_reason\":\"end_turn\",\"credits\":4}\n\n".utf8))
        #expect(events.count == 2)
        guard case .figure(let walkthrough) = events.first else { Issue.record("no figure event"); return }
        #expect(walkthrough.sections.count == 2)
    }

    /// The streamed walkthrough (servers from 2026-10-22): progress, the summary and each part before the unchanged final
    /// `figure`; each part checked exactly as the final walkthrough's are; anything malformed dropped, never fatal.
    @Test func theStreamedWalkthroughIsParsedAndCheckedAsTheFinalOne() throws {
        let sections = try #require(Self.event["sections"] as? [[String: Any]])
        func event(_ name: String, _ value: Any) -> String { "event: \(name)\ndata: \(String(decoding: Self.json(value), as: UTF8.self))\n\n" }
        var stream = event("figure_progress", ["stage": "reading"])
            + event("figure_progress", ["stage": "writing", "characters": 120, "parts": 2])
            + event("figure_summary", ["summary": "  Two pipelines side by side.  "])
            + event("figure_section", ["index": 0, "section": sections[0]])
            + event("figure_progress", ["stage": "writing", "characters": 900])
            + event("figure_section", ["index": 1, "section": sections[1]])
        // Malformed or unusable: each dropped, the stream goes on.
        stream += event("figure_progress", ["stage": "thinking"]) + "event: figure_progress\ndata: {\n\n"
            + event("figure_progress", ["stage": "writing", "characters": 950, "parts": 40])
            + event("figure_progress", ["stage": "writing", "characters": 1.5])
            + event("figure_summary", ["summary": "   "]) + event("figure_summary", ["text": "x"])
            + event("figure_section", ["index": 2, "section": ["label": "x", "title": "", "text": " "]])
            + event("figure_section", ["index": 12, "section": sections[0]]) + event("figure_section", ["index": -1, "section": sections[0]])
            + event("figure_section", ["section": sections[0]])
        stream += event("figure", Self.event) + "event: done\ndata: {\"stop_reason\":\"end_turn\",\"credits\":4}\n\n"
        var parser = ChatSSEParser()
        let events = try parser.consume(Array(stream.utf8))
        let final = try #require(FigureWalkthrough.validated(Self.json(Self.event)))
        #expect(events == [
            .figureProgress(.init(stage: .reading)), .figureProgress(.init(stage: .writing, characters: 120, parts: 2)),
            .figureSummary("Two pipelines side by side."),
            .figureSection(index: 0, section: final.sections[0]),
            .figureProgress(.init(stage: .writing, characters: 900)),
            .figureSection(index: 1, section: final.sections[1]),
            .figureProgress(.init(stage: .writing, characters: 950)), .figureProgress(.init(stage: .writing)),
            .figure(final), .done(stopReason: "end_turn", credits: 4)])
        // One check for both: a streamed part is exactly the final walkthrough's part (labels, kinds, paragraphs, boxes).
        let odd: [String: Any] = ["kind": "concept", "label": "  Inset\u{7}", "title": "", "text": "Line one\r\nline two", "paragraphs": [0, 3, 3, 4],
                                  "box": ["x": 0.1, "y": 0.1, "w": 0.3, "h": 0.3]]
        let streamed = try #require(FigureWalkthrough.streamedSection(Self.json(["index": 0, "section": odd])))
        let whole = try #require(FigureWalkthrough.validated(Self.json(["format": FigureWalkthrough.format, "summary": "s", "sections": [odd]])))
        #expect(streamed.section == whole.sections[0])
        #expect(streamed.section.title == "Inset" && streamed.section.box == nil && streamed.section.paragraphs == [3, 4])
    }

    /// "Extract the subfigure and more context" (`figure_detail`) was removed on 2026-10-21 (owner: one AI result, the
    /// walkthrough). This client never asks for it; a stray `figure_detail` event is ignored; an older build's kept detail
    /// answer still decodes (its `detail` ignored) and is neither shown nor listed in Settings › Your assets.
    @Test func extractTheSubfigureIsGoneButOldAnswersStillRead() throws {
        #expect(ChatAction(rawValue: "figure_detail") == nil)
        #expect(ChatAction.figure.isFigure && ChatAction.figureSimpler.isFigure)
        var parser = ChatSSEParser()
        let detail = #"{"format":"figure-detail-v1","label":"(a)","title":"The RLHF pipeline","text":"Up close [¶12].","paragraphs":[12],"box":{"x":0.02,"y":0.1,"w":0.45,"h":0.5}}"#
        let events = try parser.consume(Array("event: figure_detail\ndata: \(detail)\n\nevent: done\ndata: {\"stop_reason\":\"end_turn\",\"credits\":3}\n\n".utf8))
        #expect(events.count == 1)
        guard case .done = events.first else { Issue.record("only done: \(events)"); return }
        let subject = #"{"paperID":"\#(UUID().uuidString)","paperTitle":"P","manifestSHA256":"m","itemID":"f1","label":"Figure 1","action":"figure_detail","savedAt":0}"#
        let kept = try JSONDecoder().decode(FigureAnswer.self, from: Data(#"{"detail":\#(detail),"text":"","model":"m","subject":\#(subject)}"#.utf8))
        #expect(kept.walkthrough == nil && kept.text.isEmpty && kept.subject?.action == "figure_detail")
        #expect(!FigureAnswer.isShownFigureAction("figure_detail"))
        #expect(FigureAnswer.isShownFigureAction("figure") && FigureAnswer.isShownFigureAction("figure_simpler"))
        #expect(!FigureAnswer.isShownFigureAction("equation"))
        // An answer kept before subjects existed still reads.
        let old = try JSONDecoder().decode(FigureAnswer.self, from: Data(#"{"text":"words","model":"m"}"#.utf8))
        #expect(old.text == "words")
    }

    @Test func aBoxIsCutInWholePixelsInsideTheImage() throws {
        let box = FigureWalkthrough.Box(x: 0.5, y: 0, w: 0.5, h: 0.9)
        let sent = try #require(box.pixels(width: 1376, height: 275))
        #expect(sent.x == 688 && sent.y == 0 && sent.width == 688 && sent.height == 248)
        // The same fractions on the paper's larger image: the same region, at its resolution.
        let original = try #require(box.pixels(width: 2752, height: 550))
        #expect(original.x == 1376 && original.width == 1376 && original.height == 495)
        let edge = FigureWalkthrough.Box(x: 0.96, y: 0.96, w: 0.04, h: 0.04)
        let corner = try #require(edge.pixels(width: 100, height: 100))
        #expect(corner.x == 96 && corner.y == 96 && corner.width == 4 && corner.height == 4)
        #expect(edge.pixels(width: 20, height: 20) == nil, "under 2 px a side is no crop")
        #expect(!FigureWalkthrough.Box(x: 0.2, y: 0.2, w: 0.9, h: 0.1).isValid)
    }

    @Test func displayedPanelKeepsNearbyAxisTextAndClampsAtImageEdges() throws {
        // FDE-Gym Figure 5's live detail stopped at 49%, clipping the final label near the centre.
        let original = FigureWalkthrough.Box(x: 0, y: 0, w: 0.49, h: 0.98)
        let shown = try #require(original.displayBox.pixels(width: 1000, height: 400))
        #expect(shown.x == 0 && shown.y == 0)
        #expect(shown.x + shown.width >= 510 && shown.height == 400)
        #expect(original.w == 0.49, "Stored model geometry is unchanged")
        let other = try #require(FigureWalkthrough.Box(x: 0.5, y: 0.01, w: 0.49, h: 0.98).displayBox.pixels(width: 1000, height: 400))
        #expect(other.x <= 480 && other.x + other.width == 1000 && other.height == 400)
    }

    @Test func theRequestIsTheChatsOwnWithTheFigureAndNoConversationExtras() throws {
        let bundle = try bundle()
        let context = try LocalPaperChatContext(reference: try SourcePaperReference(membershipID: UUID(), sourceID: "2601.01234", revision: 2), bundle: bundle)
        let profile = ChatProfileChoice(model: .haiku, effort: .low, length: .brief)
        let image = try #require(ChatFigureImage(id: "F1", paragraph: 6, caption: "Figure 1: A test figure.", mediaType: "image/jpeg",
                                                 data: String(repeating: "A", count: 64), width: 12, height: 8, blockID: "b-6", assetPath: "assets/a.jpg"))
        let request = try ChatGenerationRequest.figure(.figure, operationID: UUID(), label: "Figure 1", quote: "Figure 1: A test figure.",
                                                       profile: profile, localContext: context, visualAnswers: true, image: image)
        let body = try #require(try JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        #expect(body["action"] as? String == "figure"); #expect(body["follow_ups"] == nil); #expect(body["topic_title"] == nil)
        #expect(body["document_id"] == nil); #expect(body["mode"] as? String == "paper")
        #expect((body["selection"] as? [String: Any])?["quote"] as? String == "Figure 1: A test figure.")
        #expect((body["messages"] as? [[String: Any]])?.map { $0["text"] as? String } == ["Figure 1"])
        #expect((body["figures"] as? [[String: Any]])?.map { $0["id"] as? String } == ["F1"])
        // The chat's own capabilities (with figure_view) and profile, so the server's tools and cache are the chat's.
        let chat = try ChatGenerationRequest.make(operationID: UUID(), documentID: nil, transcript: [ChatTurnInput(role: .user, text: "q")], selection: nil,
                                                  profile: profile, localContext: context, visualAnswers: true)
        let chatBody = try #require(try JSONSerialization.jsonObject(with: chat.encoded()) as? [String: Any])
        #expect(chatBody["capabilities"] as? [String] == ["visual_answers", "figure_requests", "figure_view", "stop_signal"])
        #expect(body["capabilities"] as? [String] == chatBody["capabilities"] as? [String])
        #expect(body["profile"] as? [String: String] == chatBody["profile"] as? [String: String])
        let equation = try ChatGenerationRequest.equation(.equation, operationID: UUID(), label: "Equation (1)", latex: "x^2", profile: profile,
                                                          localContext: context, visualAnswers: true)
        let equationBody = try #require(try JSONSerialization.jsonObject(with: equation.encoded()) as? [String: Any])
        #expect(equationBody["capabilities"] as? [String] == chatBody["capabilities"] as? [String], "every paper chat request says figure_view")
        let simpler = try ChatGenerationRequest.figure(.figureSimpler, operationID: UUID(), label: "Figure 1 Left panel", quote: "The red panel.",
                                                       profile: profile, localContext: context, visualAnswers: false, image: image)
        let simplerBody = try #require(try JSONSerialization.jsonObject(with: simpler.encoded()) as? [String: Any])
        #expect(simplerBody["action"] as? String == "figure_simpler"); #expect(simplerBody["capabilities"] as? [String] == ["figure_view", "stop_signal"])
        // Never offered for Add paper, a repair or general chat.
        #expect(!ChatGenerationRequest.capabilities(action: .ingest, visualAnswers: true, figureRequests: true, paper: true).contains("figure_view"))
        #expect(!ChatGenerationRequest.capabilities(action: .diagramFix, visualAnswers: true, paper: true).contains("figure_view"))
        #expect(!ChatGenerationRequest.capabilities(action: nil, visualAnswers: true, paper: false).contains("figure_view"))
        #expect(throws: (any Error).self) { try ChatGenerationRequest.figure(.equation, operationID: UUID(), label: "Figure 1", quote: "c", profile: .standard, localContext: context, visualAnswers: true, image: image) }
        #expect(throws: (any Error).self) { try ChatGenerationRequest.figure(.figure, operationID: UUID(), label: "Figure 1", quote: " ", profile: .standard, localContext: context, visualAnswers: true, image: image) }
    }

    @Test func answersAreKeptPerPaperFigureActionPartAndProfile() throws {
        let manifest = String(repeating: "a", count: 64)
        let key = FigureResultKey(manifestSHA256: manifest, figureID: "b-6", action: .figure, profile: .standard)
        #expect(key.fileName.count == 64 + ".sealed".count)
        let part = FigureResultKey(manifestSHA256: manifest, figureID: "b-6", action: .figureSimpler, part: "The red panel.", profile: .standard)
        #expect(part.fileName != key.fileName)
        #expect(part.fileName != FigureResultKey(manifestSHA256: manifest, figureID: "b-6", action: .figureSimpler, part: "Another part.", profile: .standard).fileName)
        #expect(key.fileName != EquationResultKey(manifestSHA256: manifest, equationID: "b-6", action: .equation, profile: .standard).fileName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("figure-answers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EquationResultStore(directory: directory, accountID: UUID(), localKey: Data(repeating: 7, count: 32))
        let answer = FigureAnswer(walkthrough: FigureWalkthrough.validated(Self.json(Self.event)), text: "", model: "claude-sonnet-5-5")
        try store.write(answer, for: key)
        #expect(store.read(key, as: FigureAnswer.self) == answer)
        #expect(store.read(part, as: FigureAnswer.self) == nil)
        // The equation view's answers are read as before.
        let equationKey = EquationResultKey(manifestSHA256: manifest, equationID: "e-1", action: .equation, profile: .standard)
        try store.write(EquationAnswer(text: "kept"), for: equationKey)
        #expect(store.read(equationKey)?.text == "kept")
    }

    @Test func aTablesCaptionIsReadFromItsBlock() throws {
        let data = try #require(try bundle().data(for: "index.html"))
        let page = try #require(String(data: data, encoding: .utf8))
        let table = try #require(EquationMarkup.block(in: page, blockID: "b-6b536bf95fcc-7"))
        #expect(table.hasPrefix("<div class=\"reader-table\"") && table.hasSuffix("</div>"))
        #expect(FigureCaptionText.caption(inBlock: table) == "Table 1: Values.")
        #expect(EquationMarkup.block(in: page, blockID: "e-6b536bf95fcc-2") == nil, "an equation is no block")
        let math = "<p class=\"reader-caption\">Table 2: <span class=\"reader-equation reader-inline\" data-latex=\"\\tau^{2}\" data-reader-equation=\"e-1\" id=\"e-1\"><math><msup><mi>τ</mi><mn>2</mn></msup></math></span> &amp; more</p>"
        #expect(FigureCaptionText.caption(inBlock: math) == "Table 2: \\(\\tau^{2}\\) & more")
    }
}
