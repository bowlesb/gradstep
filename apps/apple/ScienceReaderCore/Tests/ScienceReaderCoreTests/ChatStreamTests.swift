import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct ChatStreamTests {
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func paperRequestMatchesTheServerContract() throws {
        let operation = UUID(), document = UUID()
        let request = try ChatGenerationRequest.make(operationID: operation, documentID: document, transcript: [
            ChatTurnInput(role: .user, text: "What is \\(d_k\\)?"), ChatTurnInput(role: .assistant, text: "The key width."),
            ChatTurnInput(role: .user, text: "Why scale by it?")
        ], selection: "softmax(QK^T / sqrt(d_k))")
        let body = try object(request.encoded())
        // Visual answers are on by default, so the capability list is always sent (an empty list says off).
        #expect(Set(body.keys) == ["operation_id", "consent_version", "mode", "document_id", "messages", "selection", "follow_ups", "capabilities"])
        #expect(body["capabilities"] as? [String] == ["visual_answers"])
        #expect(body["operation_id"] as? String == operation.wire)
        #expect(body["document_id"] as? String == document.wire)
        // v3 (2026-10-15) names figures (CHAT.md "Figures in chat").
        #expect(body["consent_version"] as? String == "cloud-ai-v4")
        #expect(body["mode"] as? String == "paper")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "text": "What is \\(d_k\\)?"], ["role": "assistant", "text": "The key width."],
                             ["role": "user", "text": "Why scale by it?"]])
        #expect((body["selection"] as? [String: String]) == ["quote": "softmax(QK^T / sqrt(d_k))"])
    }

    @Test func ingestActionTravelsOnlyWithASelection() throws {
        let transcript = [ChatTurnInput(role: .user, text: "Find and add the paper referenced in this passage: [12]")]
        let ingest = try object(ChatGenerationRequest.make(operationID: UUID(), documentID: UUID(), transcript: transcript,
                                                           selection: "[12] Rafailov et al.", action: .ingest).encoded())
        #expect(ingest["action"] as? String == "ingest")
        // This build shows web papers, so Ingest may add them (server migration 019).
        #expect(ingest["capabilities"] as? [String] == ["web_import", "visual_answers"])
        let unselected = try ChatGenerationRequest.make(operationID: UUID(), documentID: UUID(), transcript: transcript, selection: " ", action: .ingest)
        #expect(unselected.action == nil)
        #expect(try object(unselected.encoded())["action"] == nil)
        #expect(try object(unselected.encoded())["capabilities"] as? [String] == ["visual_answers"], "no Add paper without a selection")
    }

    @Test func generalRequestOmitsDocumentAndSelection() throws {
        let request = try ChatGenerationRequest.make(operationID: UUID(), documentID: nil,
            transcript: [ChatTurnInput(role: .user, text: "Explain dropout")], selection: "   ")
        let body = try object(request.encoded())
        #expect(body["mode"] as? String == "general")
        #expect(body["document_id"] == nil)
        #expect(body["selection"] == nil)
    }

    @Test func contextKeepsTheNewestTurnsWithinServerBounds() throws {
        var transcript: [ChatTurnInput] = []
        for index in 0..<80 { transcript.append(ChatTurnInput(role: index.isMultiple(of: 2) ? .user : .assistant, text: "turn \(index)")) }
        transcript.append(ChatTurnInput(role: .user, text: "latest"))
        let request = try ChatGenerationRequest.make(operationID: UUID(), documentID: nil, transcript: transcript, selection: nil)
        #expect(request.turns.count <= ChatGenerationRequest.maximumTurns)
        #expect(request.turns.first?.role == .user)
        #expect(request.turns.last == ChatTurnInput(role: .user, text: "latest"))

        let large = String(repeating: "x", count: 150_000)
        let bounded = try ChatGenerationRequest.make(operationID: UUID(), documentID: nil, transcript: [
            ChatTurnInput(role: .user, text: large), ChatTurnInput(role: .assistant, text: large), ChatTurnInput(role: .user, text: "  "),
            ChatTurnInput(role: .user, text: "short follow-up")
        ], selection: nil)
        #expect(bounded.turns == [ChatTurnInput(role: .user, text: "short follow-up")],
                "Older turns that exceed the byte bound are dropped, then a leading assistant turn")
        #expect(throws: ChatRequestError.emptyContext) {
            try ChatGenerationRequest.make(operationID: UUID(), documentID: nil, transcript: [ChatTurnInput(role: .assistant, text: "a")], selection: nil)
        }
        #expect(throws: ChatRequestError.questionTooLarge) {
            try ChatGenerationRequest.make(operationID: UUID(), documentID: nil,
                transcript: [ChatTurnInput(role: .user, text: String(repeating: "é", count: 100_001))], selection: nil)
        }
    }

    @Test func selectionIsBoundedByUnicodeScalars() throws {
        let quote = String(repeating: "𝑥", count: 4_100)
        let request = try ChatGenerationRequest.make(operationID: UUID(), documentID: UUID(),
            transcript: [ChatTurnInput(role: .user, text: "Define")], selection: quote)
        #expect(request.selection?.unicodeScalars.count == ChatGenerationRequest.maximumSelectionScalars)
    }

    @Test func parserHandlesSplitFramesCommentsAndLineEndings() throws {
        var parser = ChatSSEParser()
        let wire = Array(": open\n\nevent: delta\r\ndata: {\"text\":\"Hello \\u00e9\"}\r\n\r\n: ping\n\nevent: unknown\ndata: {}\n\nevent: delta\rdata: {\"text\":\"\\\\(x\\\\)\"}\r\revent: done\ndata: {\"stop_reason\":\"end_turn\",\"credits\":3,\"usage\":{}}\n\n".utf8)
        var events: [ChatStreamEvent] = []
        // Feed in awkward chunk sizes, including splitting CRLF and UTF-8.
        var index = 0, size = 1
        while index < wire.count {
            let end = min(wire.count, index + size)
            events += try parser.consume(wire[index..<end])
            index = end; size = size % 7 + 1
        }
        #expect(events == [.delta("Hello é"), .delta("\\(x\\)"), .done(stopReason: "end_turn", credits: 3)])
    }

    @Test func parserJoinsMultilineDataAndReportsErrors() throws {
        var parser = ChatSSEParser()
        let events = try parser.consume(Array("event: error\ndata: {\"code\":\ndata: \"insufficient_credits\"}\n\n".utf8))
        #expect(events == [.failure(code: "insufficient_credits")])
        var truncated = ChatSSEParser()
        #expect(try truncated.consume(Array("event: done\ndata: {\"stop_reason\":\"end_turn\",\"credits\":1}".utf8)).isEmpty)
        truncated.finish()
        #expect(try truncated.consume(Array("\n".utf8)).isEmpty, "An unterminated event is dropped at end of input")
    }

    @Test func parserReadsBoundedDiagrams() throws {
        var parser = ChatSSEParser()
        let events = try parser.consume(Array("event: diagram\ndata: {\"title\":\"DPO\",\"source\":\"flowchart LR\\n a --> b\"}\n\n".utf8))
        #expect(events == [.diagram(title: "DPO", source: "flowchart LR\n a --> b")])
        for body in ["{\"title\":\"\",\"source\":\"graph\"}", "{\"title\":\"t\",\"source\":\"  \"}", "{\"title\":\"t\"}",
                     "{\"title\":\"t\",\"source\":\"" + String(repeating: "a", count: ChatDiagram.maximumSourceBytes + 1) + "\"}"] {
            var invalid = ChatSSEParser()
            #expect(throws: ChatStreamError.malformed) { try invalid.consume(Array("event: diagram\ndata: \(body)\n\n".utf8)) }
        }
    }

    @Test func parserReadsFollowUpsCleanedAndBoundedAndIgnoresUnusableOnes() throws {
        var parser = ChatSSEParser()
        let events = try parser.consume(Array("event: followups\ndata: {\"questions\":[\"  How is \\u03b2 chosen? \",\"x\",\"What does the\\tKL term do?\",\"One\",\"Two\",\"Three\"]}\n\n".utf8))
        #expect(events == [.followUps(["How is β chosen?", "What does the KL term do?", "One"])])
        for body in ["{\"questions\":\"none\"}", "{\"questions\":[1,\"\"]}", "{\"questions\":[\"" + String(repeating: "q", count: 121) + "\"]}", "{}"] {
            var ignored = ChatSSEParser()
            #expect(try ignored.consume(Array("event: followups\ndata: \(body)\n\n".utf8)).isEmpty, Comment(rawValue: body))
        }
        #expect(ChatFollowUps.clean(["Same?", "same?", "Other?"]) == ["Same?", "Other?"])
    }

    @Test func parserReadsStatusEventsAndIgnoresUnknownOrMalformedOnes() throws {
        var parser = ChatSSEParser()
        let wire = "event: status\ndata: {\"kind\":\"searching\",\"query\":\"DPO\\nfollow-ups\\u0000 2025\"}\n\n"
            + "event: status\ndata: {\"kind\":\"reading\",\"query\":\"ignored\"}\n\n"
            + "event: status\ndata: {\"kind\":\"finding_paper\"}\n\nevent: status\ndata: {\"kind\":\"adding_paper\"}\n\n"
            + "event: status\ndata: {\"kind\":\"thinking_harder\"}\n\nevent: status\ndata: {\"query\":1}\n\nevent: status\ndata: nope\n\n"
            + "event: status\ndata: {\"kind\":\"searching\",\"query\":\"   \"}\n\nevent: delta\ndata: {\"text\":\"A\"}\n\n"
        let events = try parser.consume(Array(wire.utf8))
        #expect(events == [.status(ChatProgress(kind: .searching, query: "DPO follow-ups 2025")), .status(ChatProgress(kind: .reading)),
                           .status(ChatProgress(kind: .findingPaper)), .status(ChatProgress(kind: .addingPaper)),
                           .status(ChatProgress(kind: .searching)), .delta("A")])
        #expect(ChatProgress(kind: .searching, query: "DPO follow-ups").text == "Searching the web for “DPO follow-ups”")
        #expect(ChatProgress(kind: .searching).text == "Searching the web…")
        #expect(ChatProgress(kind: .reading, query: "x").query == nil, "Only a search carries its query")
        #expect(ChatProgress(kind: .findingPaper).text == "Finding the paper…")
        #expect(ChatProgress(kind: .addingPaper).text == "Adding to your library…")
        #expect(ChatProgress(kind: .searching, query: String(repeating: "q", count: 500)).query?.count == ChatProgress.maximumQueryCharacters)
    }

    @Test func parserRejectsMalformedAndOversizedInput() throws {
        var malformed = ChatSSEParser()
        #expect(throws: ChatStreamError.malformed) { try malformed.consume(Array("event: delta\ndata: {\"txt\":1}\n\n".utf8)) }
        var negative = ChatSSEParser()
        #expect(throws: ChatStreamError.malformed) { try negative.consume(Array("event: done\ndata: {\"stop_reason\":\"x\",\"credits\":-1}\n\n".utf8)) }
        var long = ChatSSEParser()
        #expect(throws: ChatStreamError.tooLarge) { try long.consume(Array(repeating: 0x61, count: ChatSSEParser.maximumLineBytes + 1)) }
        var event = ChatSSEParser()
        let line = Array("data: ".utf8) + Array(repeating: 0x61, count: 200_000) + [0x0A]
        #expect(throws: ChatStreamError.tooLarge) { _ = try event.consume(line); _ = try event.consume(line) }
    }

    @Test func displayTextKeepsLatexBackslashesButNotInsideCodeSpans() throws {
        let source = #"Scale by \(1/\sqrt{d_k}\), sets \{x\}, `"\n"` and ``a\`b`` then \[ x_{i} \]"#
        let prepared = ChatDisplayText.inlineMarkdownPreservingBackslashes(source)
        #expect(prepared == #"Scale by \\(1/\\sqrt{d_k}\\), sets \\{x\\}, `"\n"` and ``a\`b`` then \\[ x_{i} \\]"#)
        let rendered = String(try AttributedString(markdown: prepared,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)).characters)
        #expect(rendered == #"Scale by \(1/\sqrt{d_k}\), sets \{x\}, "\n" and a\`b then \[ x_{i} \]"#)
        #expect(ChatDisplayText.inlineMarkdownPreservingBackslashes("**bold** and *em*") == "**bold** and *em*")
    }

    @Test func failureCodesHaveCustomerWording() {
        #expect(ChatFailureText.message(for: "insufficient_credits").hasPrefix("Not enough credits"))
        #expect(ChatFailureText.message(for: "platform_budget_exhausted").hasPrefix("AI answers are paused"))
        #expect(ChatFailureText.message(for: "something_new") == "The answer couldn’t be completed. Try again.")
        #expect(!ChatFailureText.isRetryable("refused"))
        #expect(ChatFailureText.isRetryable("provider_unavailable"))
    }

    @Test func figureRequestsAreParsedAndOfferedOnlyWithTheLocalPaper() throws {
        var parser = ChatSSEParser()
        let events = try parser.consume(Data("event: figure_request\ndata: {\"figure\":\"Figure 4\"}\n\nevent: figure_request\ndata: {\"figure\":\"the big one\"}\n\n".utf8))
        #expect(events == [.figureRequest("Figure 4")], "a label that is not a figure's is dropped")
        #expect(ChatGenerationRequest.capabilities(action: nil, visualAnswers: true, figureRequests: true) == ["visual_answers", "figure_requests"])
        #expect(ChatGenerationRequest.capabilities(action: nil, visualAnswers: false, figureRequests: true) == [])
        #expect(ChatGenerationRequest.capabilities(action: .ingest, visualAnswers: true, figureRequests: true) == ["web_import", "visual_answers"])
        #expect(ChatProgress(kind: .lookingAtFigure, query: "Figure 4").text == "Looking at Figure 4…")
    }
}
