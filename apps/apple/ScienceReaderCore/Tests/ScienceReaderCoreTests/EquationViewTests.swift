import Foundation
import Testing
@testable import ScienceReaderCore

/// The equation view (EquationView.swift, docs/architecture/EQUATION_VIEW.md): the `equation` event, the equation's
/// markup, its request and the answers kept on the device.
@Suite struct EquationViewTests {
    static func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    static var event: [String: Any] { ["format": "equation-symbols-v1", "summary": "The DPO loss.", "symbols": [
        ["symbol": "β", "latex": "\\beta", "meaning": "Temperature.", "source": "paper", "paragraph": 2],
        ["symbol": "σ", "meaning": "Logistic function.", "source": "general"]]] }

    private func bundle() throws -> VerifiedReaderBundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try DeviceReaderPackage.decode(Data(contentsOf: root.appendingPathComponent("tests/fixtures/reader-arxiv/package.json")))
    }

    @Test func theEventIsCheckedAndBoundedAsTheServerBoundsIt() {
        #expect(EquationSymbols.validated(Self.json(Self.event)) == EquationSymbols(summary: "The DPO loss.", symbols: [
            .init(symbol: "β", latex: "\\beta", meaning: "Temperature.", source: .paper, paragraph: 2),
            .init(symbol: "σ", meaning: "Logistic function.", source: .general)]))
        // A paper symbol without a usable paragraph is general; a row without words is dropped; control characters go.
        let messy = EquationSymbols.validated(Self.json(["format": "equation-symbols-v1", "summary": " Sum\u{0}mary ", "symbols": [
            ["symbol": "x", "meaning": "Margin.", "source": "paper", "paragraph": 0], ["symbol": "", "meaning": "dropped", "source": "general"],
            ["symbol": "y", "meaning": "", "source": "general"]] + Array(repeating: ["symbol": "z", "meaning": "m", "source": "general"], count: 40)]))!
        #expect(messy.summary == "Summary")
        #expect(messy.symbols.first == .init(symbol: "x", meaning: "Margin.", source: .general))
        // As the server does: the first 24 rows are read, unusable ones among them dropped.
        #expect(messy.symbols.count == EquationSymbols.maximumSymbols - 2)
        #expect(EquationSymbols.validated(Self.json(["format": "other", "summary": "s", "symbols": []])) == nil)
        #expect(EquationSymbols.validated(Self.json(["format": "equation-symbols-v1", "summary": "", "symbols": []])) == nil)
    }

    @Test func theStreamCarriesTheSymbolsAndIgnoresUnusableOnes() throws {
        var parser = ChatSSEParser()
        let payload = String(decoding: Self.json(Self.event), as: UTF8.self)
        let events = try parser.consume(Array("event: equation\ndata: \(payload)\n\nevent: equation\ndata: {\"format\":\"x\"}\n\nevent: done\ndata: {\"stop_reason\":\"end_turn\",\"credits\":3}\n\n".utf8))
        #expect(events.count == 2)
        guard case .equation(let symbols) = events.first else { Issue.record("no equation event"); return }
        #expect(symbols.symbols.count == 2)
        #expect(events.last == .done(stopReason: "end_turn", credits: 3))
    }

    @Test func theEquationsOwnMarkupAndNumberAreFoundByItsID() throws {
        let data = try #require(try bundle().data(for: "index.html"))
        let page = try #require(String(data: data, encoding: .utf8))
        let display = try #require(EquationMarkup.element(in: page, equationID: "e-6b536bf95fcc-2"))
        #expect(display.hasPrefix("<span class=\"reader-equation reader-display reader-tagged\""))
        #expect(display.hasSuffix("<span class=\"reader-tag\">(1)</span></span>"))
        #expect(display.contains("<math display=\"block\">"))
        #expect(EquationMarkup.number(in: display) == "(1)")
        #expect(EquationMarkup.label(number: EquationMarkup.number(in: display)) == "Equation (1)")
        let inline = try #require(EquationMarkup.element(in: page, equationID: "e-6b536bf95fcc-1"))
        #expect(inline.hasSuffix("</math></span>")); #expect(EquationMarkup.number(in: inline) == nil)
        #expect(EquationMarkup.element(in: page, equationID: "b-6b536bf95fcc-4") == nil, "a paragraph is no equation")
        #expect(EquationMarkup.element(in: page, equationID: "e-missing") == nil)
        #expect(EquationMarkup.element(in: page, equationID: "e\" onclick=\"x") == nil)
        // Nested spans of the same name close at the right place.
        let nested = "<p><span id=\"e-1\" data-reader-equation=\"e-1\"><span>a</span><span class=\"reader-tag\">(<b>2</b>)</span></span><span>after</span></p>"
        #expect(EquationMarkup.element(in: nested, equationID: "e-1") == "<span id=\"e-1\" data-reader-equation=\"e-1\"><span>a</span><span class=\"reader-tag\">(<b>2</b>)</span></span>")
        #expect(EquationMarkup.number(in: nested) == "(2)")
    }

    @Test func manyEquationsBeforeALongUnicodeTailDoNotRescanAndCopyThatTailForEveryMathTag() {
        let ids = (0..<105).map { "e-\($0)" }
        let fragments = ids.map { id in
            "<span id=\"\(id)\" data-reader-equation=\"\(id)\"><math><mrow>"
                + String(repeating: "<mi>θ</mi><mo>+</mo><mi>β</mi>", count: 15)
                + "</mrow></math><span class=\"reader-tag\">(\(id.dropFirst(2)))</span></span>"
        }
        let html = fragments.joined() + String(repeating: "<p>αβγδ — a long appendix.</p>", count: 30_000)
        let started = ContinuousClock.now
        let found = EquationMarkup.elements(in: html, equationIDs: ids)
        #expect(found.count == 105)
        #expect(ids.enumerated().allSatisfy { found[$0.element] == fragments[$0.offset] })
        #expect(started.duration(to: .now) < .seconds(3), "The reported 105-equation paper must not spend minutes copying its suffix")
        #expect(EquationMarkup.elements(in: html, equationIDs: [ids[4], ids[0], "missing"])[ids[0]] == fragments[0])
    }

    @Test func theRequestIsTheChatsOwnWithTheEquationActionAndNoConversationExtras() throws {
        let bundle = try bundle()
        let context = try LocalPaperChatContext(reference: try SourcePaperReference(membershipID: UUID(), sourceID: "2601.01234", revision: 2), bundle: bundle)
        let profile = ChatProfileChoice(model: .haiku, effort: .low, length: .brief)
        let request = try ChatGenerationRequest.equation(.equation, operationID: UUID(), label: "Equation (1)", latex: "x^2", profile: profile,
                                                         localContext: context, visualAnswers: true)
        let body = try #require(try JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        #expect(body["action"] as? String == "equation"); #expect(body["follow_ups"] == nil); #expect(body["topic_title"] == nil)
        #expect((body["selection"] as? [String: Any])?["quote"] as? String == "x^2")
        #expect((body["messages"] as? [[String: Any]])?.map { $0["text"] as? String } == ["Equation (1)"])
        #expect((body["local_context"] as? [String: Any])?["format"] as? String == "reader-local-context-v2")
        // The chat's own capabilities and profile, so the server's tools and cache are the chat's.
        let chat = try ChatGenerationRequest.make(operationID: UUID(), documentID: nil, transcript: [ChatTurnInput(role: .user, text: "q")], selection: nil,
                                                  profile: profile, localContext: context, visualAnswers: true)
        let chatBody = try #require(try JSONSerialization.jsonObject(with: chat.encoded()) as? [String: Any])
        #expect(body["capabilities"] as? [String] == chatBody["capabilities"] as? [String])
        #expect(body["profile"] as? [String: String] == chatBody["profile"] as? [String: String])
        let background = try ChatGenerationRequest.equation(.equationBackground, operationID: UUID(), label: "Equation", latex: "x^2", profile: .standard,
                                                            localContext: context, visualAnswers: false)
        let backgroundBody = try #require(try JSONSerialization.jsonObject(with: background.encoded()) as? [String: Any])
        #expect(backgroundBody["action"] as? String == "equation_background"); #expect(backgroundBody["capabilities"] as? [String] == ["figure_view", "stop_signal"])
        #expect(throws: (any Error).self) { try ChatGenerationRequest.equation(.relevance, operationID: UUID(), label: "Equation", latex: "x", profile: .standard, localContext: context, visualAnswers: true) }
        #expect(throws: (any Error).self) { try ChatGenerationRequest.equation(.equation, operationID: UUID(), label: "Equation", latex: " ", profile: .standard, localContext: context, visualAnswers: true) }
    }

    @Test func answersAreKeptSealedPerPaperEquationActionAndProfile() throws {
        let key = EquationResultKey(manifestSHA256: String(repeating: "a", count: 64), equationID: "e-1", action: .equation, profile: .standard)
        #expect(key.fileName.count == 64 + ".sealed".count)
        #expect(key.fileName != EquationResultKey(manifestSHA256: key.manifestSHA256, equationID: "e-1", action: .equationBackground, profile: .standard).fileName)
        #expect(key.fileName != EquationResultKey(manifestSHA256: key.manifestSHA256, equationID: "e-1", action: .equation,
                                                  profile: ChatProfileChoice(model: .opus, effort: .low, length: .standard)).fileName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("equation-answers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID(), localKey = Data(repeating: 7, count: 32)
        let store = try EquationResultStore(directory: directory, accountID: account, localKey: localKey)
        #expect(store.read(key) == nil)
        let answer = EquationAnswer(symbols: EquationSymbols.validated(Self.json(Self.event)), text: "", credits: 3, model: "claude-sonnet-5-5")
        try store.write(answer, for: key)
        #expect(store.read(key) == answer)
        // Sealed: no plaintext on disk; another key or account opens nothing.
        let sealed = try Data(contentsOf: directory.appendingPathComponent(key.fileName))
        #expect(!String(decoding: sealed, as: UTF8.self).contains("Temperature"))
        #expect(try EquationResultStore(directory: directory, accountID: account, localKey: Data(repeating: 8, count: 32)).read(key) == nil)
        #expect(try EquationResultStore(directory: directory, accountID: UUID(), localKey: localKey).read(key) == nil)
        #expect(throws: (any Error).self) { try EquationResultStore(directory: directory, accountID: account, localKey: Data(count: 16)) }
    }

    /// Settings › Your assets (owner, build 62): every kept answer opens by its own file name, with what it explains; an
    /// answer kept before the subject existed still reads (and has none); another account's key lists nothing.
    @Test func keptAnswersAreListedWithWhatTheyExplain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("equation-answers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID(), localKey = Data(repeating: 7, count: 32), paper = UUID()
        let store = try EquationResultStore(directory: directory, accountID: account, localKey: localKey)
        let subject = ExplanationSubject(paperID: paper, paperTitle: "Direct Preference Optimization", manifestSHA256: String(repeating: "a", count: 64),
                                         itemID: "e-1", label: "Equation (7)", action: "equation", savedAt: Date(timeIntervalSince1970: 1_000))
        let first = EquationResultKey(manifestSHA256: subject.manifestSHA256, equationID: "e-1", action: .equation, profile: .standard)
        let old = EquationResultKey(manifestSHA256: subject.manifestSHA256, equationID: "e-2", action: .equation, profile: .standard)
        try store.write(EquationAnswer(text: "words", subject: subject), for: first)
        try store.write(EquationAnswer(text: "before subjects"), for: old)
        let kept = store.all(as: EquationAnswer.self)
        #expect(kept.count == 2)
        #expect(kept.compactMap(\.subject) == [subject])
        #expect(store.read(old)?.subject == nil, "an answer kept before the subject still reads")
        // Read again by the name it is listed under (a kept answer asked with other options); never outside the folder.
        let named = try #require(store.entries(as: EquationAnswer.self).first { $0.value.subject == subject })
        #expect(named.fileName == first.fileName)
        #expect(store.read(fileName: named.fileName, as: EquationAnswer.self)?.text == "words")
        #expect(store.read(fileName: "../" + named.fileName, as: EquationAnswer.self) == nil)
        // Answers written before 2026-10-16 had no `subject` key at all.
        #expect(try JSONDecoder().decode(EquationAnswer.self, from: Data(#"{"text":"x"}"#.utf8)).subject == nil)
        #expect(try JSONDecoder().decode(FigureAnswer.self, from: Data(#"{"text":"x"}"#.utf8)).subject == nil)
        #expect(try EquationResultStore(directory: directory, accountID: UUID(), localKey: localKey).all(as: EquationAnswer.self).isEmpty)
    }
}
