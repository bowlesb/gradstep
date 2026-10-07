import Foundation
import ScienceReaderCore
import SwiftUI
import XCTest
@testable import ScienceReader

/// Scripted transport: each request gets a stream the test drives explicitly.
private final class ScriptedChatTransport: ChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ChatGenerationRequest] = []
    private var streams: [AsyncThrowingStream<ChatStreamEvent, Error>.Continuation] = []
    private var terminatedCount = 0
    var requests: [ChatGenerationRequest] { lock.withLock { recorded } }
    var terminated: Int { lock.withLock { terminatedCount } }

    func chatStream(_ request: ChatGenerationRequest, accountID: UUID) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ChatStreamEvent.self, throwing: Error.self)
        continuation.onTermination = { [weak self] _ in self?.lock.withLock { self?.terminatedCount += 1 } }
        lock.withLock { recorded.append(request); streams.append(continuation) }
        return stream
    }

    func send(_ events: ChatStreamEvent..., request index: Int? = nil) {
        let continuation = lock.withLock { streams[index ?? streams.count - 1] }
        for event in events { continuation.yield(event) }
    }

    func end(request index: Int? = nil, throwing error: Error? = nil) {
        let continuation = lock.withLock { streams[index ?? streams.count - 1] }
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }

    func creditBalance(accountID: UUID) async throws -> CreditBalance { CreditBalance(available: 120, reserved: 0) }
}

private final class ConsentMemory: AuthenticationCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ name: String) throws -> Data? { lock.withLock { values[name] } }
    func write(_ data: Data, name: String) throws { lock.withLock { values[name] = data } }
    func delete(_ name: String) throws { lock.withLock { values[name] = nil } }
}

final class ChatGenerationOutcomeTests: XCTestCase {
    func testOutcomesKeepOnlyHonestText() {
        XCTAssertEqual(ChatGenerationOutcome.completed(stopReason: "end_turn").resolution(text: "Answer").status, .complete)
        XCTAssertEqual(ChatGenerationOutcome.completed(stopReason: "max_tokens").resolution(text: "Answer").status, .interrupted)
        XCTAssertEqual(ChatGenerationOutcome.completed(stopReason: "end_turn").resolution(text: " ").issue, "provider_unavailable")
        XCTAssertNil(ChatGenerationOutcome.completed(stopReason: "end_turn").resolution(text: " ").status)
        XCTAssertEqual(ChatGenerationOutcome.failed(code: "transport").resolution(text: "Half").status, .interrupted)
        XCTAssertEqual(ChatGenerationOutcome.failed(code: "transport").resolution(text: "Half").issue, "transport")
        XCTAssertNil(ChatGenerationOutcome.failed(code: "refused").resolution(text: "I can").status, "A refusal's partial is discarded")
        XCTAssertEqual(ChatGenerationOutcome.cancelled.resolution(text: "Partial").status, .interrupted)
        XCTAssertNil(ChatGenerationOutcome.cancelled.resolution(text: "").status)
        XCTAssertNil(ChatGenerationOutcome.cancelled.resolution(text: "").issue)
        XCTAssertEqual(String(repeating: "é", count: 150_000).boundedForPrivateEvent().utf8.count, 200_000)
    }

    func testConsentIsPerAccountAndVersioned() throws {
        let memory = ConsentMemory(), ledger = ChatConsentLedger(environment: "staging", store: memory)
        let first = UUID(), second = UUID()
        XCTAssertFalse(ledger.hasAccepted(first))
        try ledger.accept(first)
        XCTAssertTrue(ledger.hasAccepted(first))
        XCTAssertFalse(ledger.hasAccepted(second))
        XCTAssertFalse(ChatConsentLedger(environment: "production", store: memory).hasAccepted(first))
        try memory.write(Data("cloud-ai-v0".utf8), name: "staging.\(second.wire).cloud-ai-consent")
        XCTAssertFalse(ledger.hasAccepted(second), "An older consent version does not authorize requests")
    }
}

#if DEBUG && targetEnvironment(simulator)
@MainActor
final class ChatGenerationTests: XCTestCase {
    private let sampleID = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!

    private func makeModel(consented: Bool, transport: ScriptedChatTransport = ScriptedChatTransport()) async throws -> (ReaderModel, ScriptedChatTransport) {
        let memory = ConsentMemory()
        let model = ReaderModel(configuration: nil, chatTransport: transport, chatConsentStore: memory)
        try await model.configureDurableDraftFixture(reset: true)
        // The durable draft fixture's synthetic account.
        if consented { try ChatConsentLedger(environment: "local", store: memory).accept(UUID(uuidString: "eeeeeeee-0000-4000-8000-000000000001")!) }
        model.tab = .chat
        return (model, transport)
    }

    private func waitUntil(_ description: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { XCTFail("Timed out: \(description)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testFirstSendSavesQuestionAsksConsentThenStreamsAndSealsTheAnswer() async throws {
        let (model, transport) = try await makeModel(consented: false)
        XCTAssertFalse(model.generalChat)
        model.chatInput = "Why scale the dot products?"
        await model.sendMessage()
        XCTAssertEqual(model.chatMessages.map(\.payload.text), ["Why scale the dot products?"], "The question saves before consent")
        let prompt = try XCTUnwrap(model.chatConsentPrompt)
        XCTAssertTrue(transport.requests.isEmpty, "Nothing leaves the device before consent")

        model.acceptChatConsent(prompt)
        try await waitUntil("request issued") { transport.requests.count == 1 }
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.documentID, sampleID)
        XCTAssertEqual(request.turns, [ChatTurnInput(role: .user, text: "Why scale the dot products?")])
        XCTAssertNil(request.selection)
        XCTAssertTrue(model.isAnswering)
        let streamingID = try XCTUnwrap(model.chatStreamingMessageID)
        XCTAssertEqual(model.chatTranscriptMessages.last?.id, streamingID)
        XCTAssertEqual(model.chatTranscriptMessages.last?.payload.text, "", "Thinking placeholder before the first token")

        transport.send(.delta("Scaling keeps "), .delta("logits bounded \\(\\sqrt{d_k}\\)."))
        try await waitUntil("partial text") { model.chatTranscriptMessages.last?.payload.text == "Scaling keeps logits bounded \\(\\sqrt{d_k}\\)." }
        XCTAssertEqual(model.chatMessages.count, 1, "Partial text is transient until sealed")
        transport.send(.done(stopReason: "end_turn", credits: 1))
        try await waitUntil("answer sealed") { !model.isAnswering }
        let answer = try XCTUnwrap(model.chatMessages.last)
        XCTAssertEqual(answer.id, streamingID, "The streamed row and sealed message share one identity")
        XCTAssertEqual(answer.payload.role, .assistant)
        XCTAssertEqual(answer.payload.status, .complete)
        XCTAssertEqual(answer.payload.text, "Scaling keeps logits bounded \\(\\sqrt{d_k}\\).")
        XCTAssertEqual(answer.payload.parents, [model.chatMessages[0].id])
        XCTAssertEqual(model.activeBranchID, answer.id)
        XCTAssertNil(model.chatStreamingMessageID)
        XCTAssertNil(model.chatAnswerIssue)
        XCTAssertEqual(transport.terminated, 1, "The finished stream is released, closing its request")
        try await waitUntil("credit balance refreshed") { model.creditBalance?.available == 120 }

        model.chatInput = "And without scaling?"
        await model.sendMessage()
        XCTAssertNil(model.chatConsentPrompt, "Consent is remembered for this account")
        try await waitUntil("follow-up request") { transport.requests.count == 2 }
        XCTAssertEqual(transport.requests[1].turns.map(\.role), [.user, .assistant, .user])
        XCTAssertNotEqual(transport.requests[1].operationID, request.operationID)
        transport.send(.delta("Softmax saturates."), .done(stopReason: "end_turn", credits: 1))
        try await waitUntil("follow-up sealed") { !model.isAnswering }
        await model.flushDrafts()

        let reopened = ReaderModel(configuration: nil, chatTransport: ScriptedChatTransport(), chatConsentStore: ConsentMemory())
        try await reopened.configureDurableDraftFixture(reset: false)
        let conversation = try XCTUnwrap(model.activeConversation)
        reopened.openConversation(conversation)
        XCTAssertEqual(reopened.chatMessages.map(\.payload.text), ["Why scale the dot products?", "Scaling keeps logits bounded \\(\\sqrt{d_k}\\).",
                                                                     "And without scaling?", "Softmax saturates."], "Answers persist encrypted")
    }

    func testADrawnDiagramIsSealedWithItsAnswerAndSurvivesReopening() async throws {
        let (model, transport) = try await makeModel(consented: true)
        model.chatInput = "Draw the attention computation"
        await model.sendMessage()
        try await waitUntil("request issued") { transport.requests.count == 1 }
        transport.send(.delta("Here is the flow."), .diagram(title: "Attention", source: "flowchart LR\n Q --> S"),
                       .done(stopReason: "end_turn", credits: 1))
        try await waitUntil("answer sealed") { !model.isAnswering }
        let answer = try XCTUnwrap(model.chatMessages.last)
        XCTAssertEqual(answer.payload.text, "Here is the flow.")
        XCTAssertEqual(model.activeBranchID, answer.id, "The answer, not its diagram, is the branch head")
        let link = try XCTUnwrap(model.chatDiagrams[answer.payload.entityID])
        XCTAssertEqual(link.title, "Attention")
        let diagram = try XCTUnwrap(model.diagram(link.id))
        XCTAssertEqual(diagram.source, "flowchart LR\n Q --> S")
        XCTAssertEqual(diagram.messageID, answer.payload.entityID)
        let event = try XCTUnwrap(model.privateState.revisions(for: link.id).first)
        XCTAssertEqual(event.payload.conversationID, model.activeConversation)
        model.openDiagram(link.id)
        XCTAssertEqual(model.presentedDiagram, PresentedDiagram(id: link.id))
        await model.flushDrafts()

        let reopened = ReaderModel(configuration: nil, chatTransport: ScriptedChatTransport(), chatConsentStore: ConsentMemory())
        try await reopened.configureDurableDraftFixture(reset: false)
        XCTAssertEqual(reopened.privateState.diagrams().map(\.diagram.title), ["Attention"], "Diagrams persist encrypted")
    }

    func testADiagramFromAnInterruptedAnswerIsNotKept() async throws {
        let (model, transport) = try await makeModel(consented: true)
        model.chatInput = "Draw it"
        await model.sendMessage()
        try await waitUntil("request issued") { transport.requests.count == 1 }
        transport.send(.delta("Partial"), .diagram(title: "Half", source: "graph TD; a-->b"), .done(stopReason: "max_tokens", credits: 1))
        try await waitUntil("answer sealed") { !model.isAnswering }
        XCTAssertEqual(model.chatMessages.last?.payload.status, .interrupted)
        XCTAssertTrue(model.privateState.diagrams().isEmpty)
    }

    func testStopKeepsPartialTextAsAnInterruptedAnswer() async throws {
        let (model, transport) = try await makeModel(consented: true)
        model.chatInput = "Summarize section 3"
        await model.sendMessage()
        try await waitUntil("request issued") { transport.requests.count == 1 }
        transport.send(.delta("Section 3 introduces"))
        try await waitUntil("partial text") { model.chatTranscriptMessages.last?.payload.text == "Section 3 introduces" }
        model.stopAnswer()
        XCTAssertTrue(model.isStoppingAnswer)
        try await waitUntil("stopped") { !model.isAnswering }
        XCTAssertGreaterThanOrEqual(transport.terminated, 1, "Stop cancels the request stream")
        let answer = try XCTUnwrap(model.chatMessages.last)
        XCTAssertEqual(answer.payload.role, .assistant)
        XCTAssertEqual(answer.payload.status, .interrupted)
        XCTAssertEqual(answer.payload.text, "Section 3 introduces")
        XCTAssertNil(model.chatAnswerIssue, "Stopping is not an error")
        XCTAssertFalse(model.isStoppingAnswer)
    }

    func testStoppingBeforeTheFirstTokenKeepsNoAnswer() async throws {
        let (model, transport) = try await makeModel(consented: true)
        model.chatInput = "Question"
        await model.sendMessage()
        try await waitUntil("request issued") { transport.requests.count == 1 }
        model.stopAnswer()
        try await waitUntil("stopped") { !model.isAnswering }
        XCTAssertEqual(model.chatMessages.map(\.payload.role), [.user])
    }

    func testFailureShowsAnInlineIssueAndRetryUsesANewOperation() async throws {
        let (model, transport) = try await makeModel(consented: true)
        model.chatInput = "Explain Table 2"
        await model.sendMessage()
        try await waitUntil("request issued") { transport.requests.count == 1 }
        transport.send(.failure(code: "insufficient_credits"))
        try await waitUntil("failed") { !model.isAnswering }
        let issue = try XCTUnwrap(model.chatAnswerIssue)
        XCTAssertEqual(issue.code, "insufficient_credits")
        XCTAssertTrue(issue.message.hasPrefix("Not enough credits"))
        XCTAssertEqual(model.chatMessages.map(\.payload.role), [.user])
        XCTAssertNil(model.error, "Answer failures are inline, not alerts")

        model.retryAnswer()
        XCTAssertNil(model.chatAnswerIssue)
        try await waitUntil("retry issued") { transport.requests.count == 2 }
        XCTAssertNotEqual(transport.requests[0].operationID, transport.requests[1].operationID)
        XCTAssertEqual(transport.requests[0].turns, transport.requests[1].turns)
        transport.send(.delta("Table 2 compares"))
        transport.end(throwing: URLError(.networkConnectionLost))
        try await waitUntil("interrupted") { !model.isAnswering }
        XCTAssertEqual(model.chatMessages.last?.payload.status, .interrupted, "A dropped connection is never treated as complete")
        XCTAssertEqual(model.chatMessages.last?.payload.text, "Table 2 compares")
        XCTAssertNil(model.chatAnswerIssue, "The issue belongs to the question; the interrupted answer is now the head")

        model.chatInput = "Next"
        await model.sendMessage()
        try await waitUntil("third request") { transport.requests.count == 3 }
        transport.end()
        try await waitUntil("ended without done") { !model.isAnswering }
        XCTAssertEqual(model.chatAnswerIssue?.code, "transport", "An empty EOF is an interrupted answer, not success")
    }

    func testRefusalDiscardsPartialOutput() async throws {
        let (model, transport) = try await makeModel(consented: true)
        model.chatInput = "A question the provider declines"
        await model.sendMessage()
        try await waitUntil("request issued") { transport.requests.count == 1 }
        transport.send(.delta("I can"), .failure(code: "refused"))
        try await waitUntil("refused") { !model.isAnswering }
        XCTAssertEqual(model.chatMessages.map(\.payload.role), [.user])
        let issue = try XCTUnwrap(model.chatAnswerIssue)
        XCTAssertEqual(issue.code, "refused")
        XCTAssertFalse(issue.retryable)
    }

    func testDecliningConsentKeepsTheQuestionAndCanAskAgain() async throws {
        let (model, transport) = try await makeModel(consented: false)
        model.chatInput = "Keep this question"
        await model.sendMessage()
        model.declineChatConsent(try XCTUnwrap(model.chatConsentPrompt))
        XCTAssertEqual(model.chatAnswerIssue?.code, "consent_declined")
        XCTAssertEqual(model.chatAnswerIssue?.actionTitle, "Get answer")
        model.retryAnswer()
        XCTAssertNotNil(model.chatConsentPrompt, "Retrying asks again; nothing was sent")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testNewChatFencesALateAnswerToItsOwnConversation() async throws {
        let (model, transport) = try await makeModel(consented: true)
        model.chatInput = "Original question"
        await model.sendMessage()
        let original = try XCTUnwrap(model.activeConversation)
        try await waitUntil("request issued") { transport.requests.count == 1 }
        transport.send(.delta("Early text "))
        try await waitUntil("partial text") { model.chatTranscriptMessages.last?.payload.text == "Early text " }

        model.newChat(general: false)
        XCTAssertNil(model.activeConversation)
        XCTAssertTrue(model.chatTranscriptMessages.isEmpty, "A new chat never shows another conversation's stream")
        XCTAssertFalse(model.isAnswering, "The new composer's controls are available")
        transport.send(.delta("late text"), .done(stopReason: "end_turn", credits: 1))
        try await waitUntil("late answer sealed") { model.privateState.conversationBranches(original).first?.messages.count == 2 }
        XCTAssertTrue(model.chatTranscriptMessages.isEmpty)
        XCTAssertNil(model.activeConversation)

        model.openConversation(original)
        XCTAssertEqual(model.chatMessages.map(\.payload.text), ["Original question", "Early text late text"])
        XCTAssertFalse(model.isAnswering)
    }

    func testSelectionActionSendsItsQuoteAfterConsent() async throws {
        let (model, transport) = try await makeModel(consented: false)
        model.selectionAction(.define, quote: "scaled dot-product attention")
        try await waitUntil("consent requested") { model.chatConsentPrompt != nil }
        XCTAssertEqual(model.chatMessages.count, 1)
        model.acceptChatConsent(try XCTUnwrap(model.chatConsentPrompt))
        try await waitUntil("request issued") { transport.requests.count == 1 }
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.selection, "scaled dot-product attention")
        XCTAssertEqual(request.documentID, sampleID)
        XCTAssertEqual(request.turns.last?.text, "Explain in plain terms, including any symbols: scaled dot-product attention")
        transport.send(.done(stopReason: "end_turn", credits: 0))
        try await waitUntil("finished") { !model.isAnswering }
        XCTAssertEqual(model.chatAnswerIssue?.code, "provider_unavailable", "An empty completed answer is reported, not saved")
    }

    func testRelatedAsksTheServerToSearchForRelatedPapers() async throws {
        let (model, transport) = try await makeModel(consented: true)
        model.selectionAction(.similar, quote: "multi-head attention")
        try await waitUntil("request issued") { transport.requests.count == 1 }
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.action, .related)
        XCTAssertEqual(request.selection, "multi-head attention")
        XCTAssertEqual(SelectionAction.similar.title, "Related")
        transport.send(.done(stopReason: "end_turn", credits: 0))
        try await waitUntil("finished") { !model.isAnswering }
    }

    /// Hosts the real chat screen and records screenshots of each answer phase.
    func testChatScreenPresentsThinkingStreamingStopAndIssues() async throws {
        let (model, transport) = try await makeModel(consented: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        // RootView covers itself while the test host's scene is inactive, so
        // host the sheet and chat screens directly.
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        func capture(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(450))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
            add(attachment)
        }
        model.chatInput = "Why does the paper scale the dot products?"
        await model.sendMessage()
        try await waitUntil("consent sheet") { model.chatConsentPrompt != nil }
        let prompt = try XCTUnwrap(model.chatConsentPrompt)
        window.rootViewController = UIHostingController(rootView: ChatConsentView(model: model, prompt: prompt))
        try await capture("1 consent sheet")
        window.rootViewController = UIHostingController(rootView: ChatView(model: model))
        model.acceptChatConsent(prompt)
        try await waitUntil("request issued") { transport.requests.count == 1 }
        try await capture("2 thinking placeholder with stop")
        transport.send(.delta(ChatFixtureTransport.answer.prefix(180).description))
        try await waitUntil("partial") { (model.chatTranscriptMessages.last?.payload.text?.count ?? 0) == 180 }
        try await capture("3 partial answer streaming")
        transport.send(.delta(String(ChatFixtureTransport.answer.dropFirst(180))), .done(stopReason: "end_turn", credits: 2))
        try await waitUntil("sealed") { !model.isAnswering }
        try await capture("4 sealed answer with send restored")
        model.chatInput = "Follow-up that runs out of credits"
        await model.sendMessage()
        try await waitUntil("second request") { transport.requests.count == 2 }
        transport.send(.failure(code: "insufficient_credits"))
        try await waitUntil("issue") { model.chatAnswerIssue != nil }
        try await capture("5 inline credit issue")
    }

    func testGeneralChatSendsNoDocument() async throws {
        let (model, transport) = try await makeModel(consented: true)
        model.newChat(general: true)
        model.chatInput = "What is a residual connection?"
        await model.sendMessage()
        try await waitUntil("request issued") { transport.requests.count == 1 }
        XCTAssertNil(transport.requests[0].documentID)
        transport.send(.delta("A skip path."), .done(stopReason: "end_turn", credits: 1))
        try await waitUntil("sealed") { !model.isAnswering }
        XCTAssertNil(model.chatMessages.last?.payload.documentID)
        XCTAssertEqual(model.chatMessages.last?.payload.text, "A skip path.")
    }
}
#endif
