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
    private var balanceCalls = 0
    var requests: [ChatGenerationRequest] { lock.withLock { recorded } }
    var terminated: Int { lock.withLock { terminatedCount } }
    var creditCalls: Int { lock.withLock { balanceCalls } }

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

    func creditBalance(accountID: UUID) async throws -> CreditBalance {
        lock.withLock { balanceCalls += 1 }
        return CreditBalance(available: 120, reserved: 0)
    }

    /// The server's profile table; nil behaves like a server from before profiles (GET answers 405).
    var profiles: ChatProfileTable?
    func chatProfiles(accountID: UUID) async throws -> ChatProfileTable {
        guard let profiles = lock.withLock({ self.profiles }) else { throw ChatTransportError.rejected("method_unavailable") }
        return profiles
    }

    /// Every combination offered, with placeholder estimates.
    static let table: ChatProfileTable = {
        var estimates: [ChatProfileChoice: ChatProfileTable.Estimate] = [:]
        for model in ChatProfileChoice.Model.allCases {
            for effort in ChatProfileChoice.Effort.allCases {
                for length in ChatProfileChoice.Length.allCases {
                    estimates[ChatProfileChoice(model: model, effort: effort, length: length)] = .init(low: 1, high: 2, max: 3)
                }
            }
        }
        return ChatProfileTable(version: ChatProfileTable.supportedVersion, defaultChoice: .standard, estimates: estimates)
    }()
}

private actor LocalRequestCapture {
    var request: ChatGenerationRequest?
    func record(_ value: ChatGenerationRequest) { request = value }
}

private final class ConsentMemory: AuthenticationCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ name: String) throws -> Data? { lock.withLock { values[name] } }
    func write(_ data: Data, name: String) throws { lock.withLock { values[name] = data } }
    func delete(_ name: String) throws { lock.withLock { values[name] = nil } }
}

final class ChatGenerationOutcomeTests: XCTestCase {
    #if targetEnvironment(macCatalyst)
    func testAccountRetirementCancelsAJobRegisteredAfterTheFence() async {
        let jobs = LocalAIJobs(), id = UUID(), epoch = jobs.epoch
        jobs.cancelAll()
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        jobs.insert(task, id: id, epoch: epoch)
        XCTAssertTrue(task.isCancelled)
        await task.value
        jobs.remove(id)
        XCTAssertTrue(jobs.isEmpty)
    }
    func testCompletionBeforeRegistrationCannotLeaveAnActiveJob() {
        let jobs = LocalAIJobs(), id = UUID(), epoch = jobs.epoch
        jobs.remove(id)
        jobs.insert(Task {}, id: id, epoch: epoch)
        XCTAssertTrue(jobs.isEmpty)
    }
    #endif
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

#if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))
@MainActor
final class ChatGenerationTests: XCTestCase {
    private let sampleID = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!

    func testTestingAllowanceDecodesAlongsideLegacyBalances() throws {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(CreditBalance.self, from: Data(#"{"available":400,"reserved":2}"#.utf8))
        XCTAssertNil(legacy.unlimitedTesting)
        XCTAssertEqual(legacy.available, 400)
        let unlimited = try decoder.decode(CreditBalance.self, from: Data(#"{"available":100000,"reserved":50,"unlimited_testing":true}"#.utf8))
        XCTAssertEqual(unlimited.availableLabel, "Unlimited testing")
        XCTAssertEqual(unlimited.reserved, 50)
        XCTAssertThrowsError(try decoder.decode(CreditBalance.self, from: Data(#"{"available":100000,"reserved":0,"unlimited_testing":"true"}"#.utf8)))
    }

    #if targetEnvironment(macCatalyst)
    func testLocalAnswerNeedsNoCloudConsentOrCreditsAndIsSealed() async throws {
        let (model, cloud) = try await makeModel(consented: false)
        model.generalChat = true; model.localAIModelID = "qwen35-4b"
        model.localAI.fixtureStream = { request in AsyncThrowingStream { c in
            c.yield(.delta("Local answer.")); c.yield(.done(stopReason: "end_turn", credits: 0, model: "local/qwen35-4b/fixture")); c.finish()
        } }
        let balancesBefore = cloud.creditCalls
        model.chatInput = "Explain a gradient"
        await model.sendMessage()
        try await waitUntil("local answer sealed") { model.chatMessages.last?.payload.role == .assistant && !model.isAnswering }
        XCTAssertEqual(model.chatMessages.last?.payload.text, "Local answer.")
        XCTAssertEqual(model.chatMessages.last?.payload.status, .complete)
        XCTAssertNil(model.chatConsentPrompt)
        XCTAssertTrue(cloud.requests.isEmpty)
        XCTAssertEqual(cloud.creditCalls, balancesBefore)
    }

    func testLocalStopAndLateAnswerCannotFallBackToCloudOrCrossAccount() async throws {
        let (model, cloud) = try await makeModel(consented: false)
        model.generalChat = true; model.localAIModelID = "qwen35-4b"
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ChatStreamEvent.self, throwing: Error.self)
        model.localAI.fixtureStream = { _ in stream }
        model.chatInput = "Explain a gradient"
        await model.sendMessage()
        try await waitUntil("local generation") { model.isAnswering }
        continuation.yield(.delta("Partial local text"))
        try await waitUntil("local text") { model.chatTranscriptMessages.last?.payload.text == "Partial local text" }
        model.localAIModelID = nil // changing the next request's choice cannot change this request's Stop.
        model.stopAnswer()
        try await waitUntil("stop") { !model.isAnswering }
        XCTAssertTrue(cloud.requests.isEmpty)
        XCTAssertEqual(model.chatMessages.last?.payload.status, .interrupted)
        await model.signOut()
        continuation.yield(.delta("late account text")); continuation.finish()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(model.chatMessages.contains { $0.payload.text?.contains("late account text") == true })
    }

    func testLocalPDFChatUsesDeviceBundleAndCannotEncodeCloudRequest() async throws {
        let (model, cloud) = try await makeModel(consented: false)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundle = try DeviceReaderPackage.decode(Data(contentsOf: root.appendingPathComponent("tests/fixtures/reader-arxiv/package.json")))
        // Route a verified bundle as a local PDF item: no arXiv membership or legacy server context exists.
        var paper = Paper(id: UUID(), title: "Local PDF", authors: "", year: nil, abstract: "", keywords: [], fileURL: nil, artifactID: nil)
        paper.isLocalPDF = true; paper = paper.displaying(bundle)
        model.papers.append(paper); model.selectedPaper = paper; model.chatPaperID = paper.id
        model.generalChat = false; model.localAIModelID = "qwen35-4b"
        let capture = LocalRequestCapture()
        model.localAI.fixtureStream = { request in AsyncThrowingStream { c in Task {
            await capture.record(request)
            c.yield(.delta("Local PDF answer")); c.yield(.done(stopReason: "end_turn", credits: 0)); c.finish()
        } } }
        model.chatInput = "What does Figure 1 show?"
        await model.sendMessage()
        try await waitUntil("local PDF answer sealed") { model.chatMessages.last?.payload.text == "Local PDF answer" && !model.isAnswering }
        let captured = await capture.request
        let request = try XCTUnwrap(captured)
        XCTAssertTrue(request.isLocalInference)
        XCTAssertEqual(request.onDevicePaperText, PaperChatContext.text(bundle.index))
        XCTAssertNil(request.localContext)
        XCTAssertEqual(request.figures.count, 1)
        XCTAssertThrowsError(try request.encoded())
        XCTAssertTrue(cloud.requests.isEmpty)
        model.selectionAction(.define, quote: String(repeating: "x", count: ChatGenerationRequest.maximumSelectionScalars + 1))
        XCTAssertEqual(model.localAIModelID, "qwen35-4b", "Selection actions preserve the explicit engine instead of adopting the scenario default")
        await model.sendMessage()
        try await waitUntil("oversized local selection rejected") { model.chatAnswerIssue != nil }
        XCTAssertEqual(model.chatAnswerIssue?.code, "local_context_large", "Do not collapse the actual local failure into invalid_request")
        XCTAssertFalse(model.chatAnswerIssue?.retryable ?? true)
        XCTAssertTrue(cloud.requests.isEmpty)
    }

    #else
    func testPhoneRetainedLocalTurnCannotInvokeCloudOrSpendCredits() async throws {
        let (model, cloud) = try await makeModel(consented: false)
        model.generalChat = true; model.localAIModelID = "qwen35-4b"
        model.chatInput = "Continue my saved local conversation"
        let before = cloud.creditCalls
        await model.sendMessage()
        try await waitUntil("Mac-only error") { model.chatAnswerIssue != nil }
        XCTAssertEqual(model.chatAnswerIssue?.code, "local_mac_only")
        XCTAssertFalse(model.chatAnswerIssue?.retryable ?? true)
        XCTAssertTrue(cloud.requests.isEmpty)
        XCTAssertEqual(cloud.creditCalls, before)
        XCTAssertNil(model.chatConsentPrompt)
        XCTAssertEqual(model.localAI.identity("qwen35-4b"), "local/qwen35-4b/0e7ffd5c629e", "Old encrypted explanations retain their cache identity")
    }
    #endif

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

    /// Status events show what the server is doing until text resumes or the answer ends; never sealed.
    func testServerStatusShowsUntilTextResumesAndIsNeverSaved() async throws {
        let (model, transport) = try await makeModel(consented: true)
        model.chatInput = "What followed DPO?"
        await model.sendMessage()
        try await waitUntil("request issued") { transport.requests.count == 1 }
        transport.send(.status(ChatProgress(kind: .searching, query: "DPO follow-ups")))
        try await waitUntil("searching shown") { model.chatStreamingProgress == ChatProgress(kind: .searching, query: "DPO follow-ups") }
        transport.send(.status(ChatProgress(kind: .reading)))
        try await waitUntil("reading shown") { model.chatStreamingProgress?.kind == .reading }
        transport.send(.delta("IPO generalizes it."))
        try await waitUntil("cleared by text") { model.chatStreamingProgress == nil }
        transport.send(.status(ChatProgress(kind: .searching, query: "KTO")))
        try await waitUntil("second search shown") { model.chatStreamingProgress?.query == "KTO" }
        transport.send(.done(stopReason: "end_turn", credits: 1))
        try await waitUntil("answer sealed") { !model.isAnswering }
        XCTAssertNil(model.chatStreamingProgress, "Cleared when the answer ends")
        XCTAssertEqual(model.chatMessages.last?.payload.text, "IPO generalizes it.", "Status text is never part of the answer")
    }

    /// Follow-up suggestions (2026-10-14) belong to the newest complete answer only; a tap fills the message box and
    /// the next question clears them. An interrupted answer offers none.
    func testFollowUpsShowUnderACompleteAnswerFillTheComposerAndClearOnTheNextQuestion() async throws {
        let (model, transport) = try await makeModel(consented: true)
        model.chatInput = "What followed DPO?"
        await model.sendMessage()
        try await waitUntil("request issued") { transport.requests.count == 1 }
        transport.send(.delta("IPO generalizes it."), .followUps(["How does IPO regularize?", "What about KTO?"]))
        XCTAssertEqual(model.chatFollowUpQuestions, [], "Nothing is offered while the answer streams")
        transport.send(.done(stopReason: "end_turn", credits: 1))
        try await waitUntil("answer sealed") { !model.isAnswering }
        try await waitUntil("follow-ups offered") { model.chatFollowUpQuestions == ["How does IPO regularize?", "What about KTO?"] }
        XCTAssertFalse(model.chatMessages.contains { ($0.payload.text ?? "").contains("KTO") }, "Suggestions are never saved as messages")
        model.useFollowUp("What about KTO?")
        XCTAssertEqual(model.chatInput, "What about KTO?")
        XCTAssertTrue(model.takeComposerFocusRequest())
        await model.sendMessage()
        try await waitUntil("second request issued") { transport.requests.count == 2 }
        XCTAssertEqual(model.chatFollowUpQuestions, [], "The next question clears the previous suggestions")
        transport.send(.delta("Partial"), .followUps(["Dropped?", "Also dropped?"]), .failure(code: "provider_unavailable"))
        try await waitUntil("interrupted") { !model.isAnswering }
        XCTAssertEqual(model.chatFollowUpQuestions, [], "An interrupted answer offers no follow-ups")
    }

    /// Study (experimental, 2026-10-14): a tutored chat on a paper numbered on this device. The opening turn carries
    /// an empty map; each answer sends the map back; a complete tutored answer advances it; a failed one keeps it;
    /// ending the study keeps the conversation and drops the map, which is never saved.
    func testStudySendsTheMapWithEveryTurnAdvancesItOnCompleteAnswersOnlyAndEndsWithoutATrace() async throws {
        let (model, transport) = try await makeModel(consented: true)
        // The paper numbered on this device: the shared arXiv HTML fixture, as its membership.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundle = try DeviceReaderPackage.decode(Data(contentsOf: root.appendingPathComponent("tests/fixtures/reader-arxiv/package.json")))
        let reference = try SourcePaperReference(membershipID: UUID(), sourceID: "2601.01234", revision: 2)
        // A membership's library row carries the membership id (its events bind to the reference by that id).
        var paper = Paper(id: reference.membershipID, title: "Authored HTML fixture", authors: "A. Author", year: 2026, abstract: "", keywords: [], fileURL: nil, artifactID: nil)
        paper.sourceID = "2601.01234"; paper.sourceRevision = 2; paper.sourceMembership = reference
        let numbered = paper.displaying(bundle)
        model.papers.append(numbered); model.selectedPaper = numbered; model.chatPaperID = numbered.id; model.generalChat = false
        XCTAssertTrue(model.canStudyPaper); XCTAssertNil(model.chatStudyMap)
        let first = StudyMap(concepts: [StudyMap.Concept(id: "attention", label: "Attention", state: .learning, paragraphs: [2])], links: [], focus: "attention", journey: ["attention"], next: .calibrate)
        let grown = StudyMap(concepts: [StudyMap.Concept(id: "attention", label: "Attention", state: .known, paragraphs: [2]), StudyMap.Concept(id: "softmax", label: "Softmax", state: .learning, paragraphs: [2])],
                             links: [StudyMap.Link(from: "softmax", to: "attention", kind: .prerequisite)], focus: "softmax", journey: ["attention", "softmax"], next: .teach)
        await model.startStudy()
        try await waitUntil("opening turn issued") { transport.requests.count == 1 }
        let opening = transport.requests[0]
        XCTAssertEqual(opening.action, .study); XCTAssertEqual(opening.study, .empty); XCTAssertNotNil(opening.localContext); XCTAssertNil(opening.selection)
        XCTAssertEqual(opening.turns.last?.text, StudyMap.startMessage())
        XCTAssertEqual(model.chatStudyMap, .empty, "the study starts with an empty map")
        transport.send(.delta("**What does attention compute?**"), .study(first), .done(stopReason: "end_turn", credits: 4))
        try await waitUntil("answer sealed") { !model.isAnswering }
        XCTAssertEqual(model.chatStudyMap, first)
        XCTAssertEqual(model.chatFollowUpQuestions, [], "the tutor asks its own question")
        // The reader's answer carries the current map; a failed answer leaves it unchanged, with its cost shown.
        model.chatInput = "A weighted sum of the values."
        await model.sendMessage()
        try await waitUntil("answer turn issued") { transport.requests.count == 2 }
        XCTAssertEqual(transport.requests[1].action, .study); XCTAssertEqual(transport.requests[1].study, first)
        // The provider never started: nothing to keep, nothing charged, and the question can be asked again.
        transport.send(.study(grown), .failure(code: "provider_unavailable", credits: 0))
        try await waitUntil("failed") { !model.isAnswering }
        XCTAssertEqual(model.chatStudyMap, first, "a failed answer keeps the previous map")
        XCTAssertEqual(model.chatAnswerIssue?.code, "provider_unavailable"); XCTAssertEqual(model.chatAnswerIssue?.credits, 0)
        model.retryAnswer()
        try await waitUntil("retry issued") { transport.requests.count == 3 }
        XCTAssertEqual(transport.requests[2].study, first, "a retry sends the same map")
        transport.send(.delta("Right. **Next?**"), .study(grown), .done(stopReason: "end_turn", credits: 4))
        try await waitUntil("retry sealed") { !model.isAnswering && model.chatStudyMap == grown }
        // Nothing of the map was saved: the history holds the messages only.
        XCTAssertFalse(model.chatMessages.contains { ($0.payload.text ?? "").contains("Softmax") })
        model.endStudy()
        XCTAssertNil(model.chatStudyMap)
        XCTAssertEqual(model.chatMessages.count, 4, "the conversation stays")
        // A paper without its reader on this device is not offered a study.
        model.generalChat = true
        XCTAssertFalse(model.canStudyPaper)
    }

    /// Owner feedback (build 21): a reference's Discuss in chat opens this paper's chat with the entry quoted in the
    /// message box, ready to type; nothing is sent. An empty new chat keeps its unsent words after the quote; a
    /// conversation under way is left as it was and the reference starts a new one.
    func testDiscussReferenceQuotesTheEntryInThisPapersChatWithoutSending() async throws {
        let (model, transport) = try await makeModel(consented: true)
        let paper = try XCTUnwrap(model.selectedPaper)
        model.tab = .paper
        model.chatInput = "Compare with PPO."
        let composer = model.chatComposerID
        model.discussReference("A. Chowdhery, S. Narang,\n and J. Devlin. PaLM: Scaling language modeling with pathways. arXiv:2204.02311, 2022.")
        XCTAssertEqual(model.tab, .chat)
        XCTAssertFalse(model.generalChat)
        XCTAssertEqual(model.chatPaper?.id, paper.id)
        XCTAssertEqual(model.chatInput, "About “A. Chowdhery, S. Narang, and J. Devlin. PaLM: Scaling language modeling with pathways. "
                       + "arXiv:2204.02311, 2022.”: Compare with PPO.")
        XCTAssertEqual(model.chatComposerID, composer, "The empty chat and its unsent words are kept")
        XCTAssertTrue(model.takeComposerFocusRequest(), "The message box takes the focus, once")
        XCTAssertFalse(model.takeComposerFocusRequest())
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(transport.requests.isEmpty, "Nothing is sent")

        model.chatInput = "What is DPO?"
        await model.sendMessage()
        try await waitUntil("request issued") { transport.requests.count == 1 }
        transport.send(.delta("A method."), .done(stopReason: "end_turn", credits: 1))
        try await waitUntil("answer sealed") { !model.isAnswering }
        let conversation = try XCTUnwrap(model.activeConversation)
        model.tab = .paper
        model.discussReference("R. A. Bradley and M. E. Terry. Rank analysis of incomplete block designs. Biometrika, 1952.")
        XCTAssertEqual(model.tab, .chat)
        XCTAssertNil(model.activeConversation, "A new chat for the reference")
        XCTAssertEqual(model.chatInput, "About “R. A. Bradley and M. E. Terry. Rank analysis of incomplete block designs. Biometrika, 1952.”: ")
        XCTAssertEqual(transport.requests.count, 1, "Nothing more is sent")
        XCTAssertEqual(model.privateState.revisions(for: conversation).first?.payload.kind, .conversation, "The earlier conversation is untouched")
    }

    /// Owner feedback #10/#3: Quote in Chat quotes into the composer; Explain/Define ask in this chat,
    /// never over a draft; menus on answer text and formulas carry these actions and copy LaTeX.
    func testAnswerTextAndFormulaActions() async throws {
        let (model, transport) = try await makeModel(consented: true)
        model.chatQuoteAction(.ask, quote: "  softmax temperature ")
        XCTAssertEqual(model.chatInput, "About “softmax temperature”: ")
        model.chatQuoteAction(.explain, quote: "\\(\\beta\\)")
        XCTAssertTrue(model.chatInput.hasPrefix("Explain in plain terms, including any symbols: \\(\\beta\\)\n\nAbout “softmax temperature”:"),
                      "A draft is kept and the question waits in the composer")
        XCTAssertTrue(transport.requests.isEmpty)
        model.chatInput = ""
        model.chatQuoteAction(.define, quote: "KL divergence")
        try await waitUntil("sent as a new question in this chat") { transport.requests.count == 1 }
        XCTAssertEqual(transport.requests[0].turns.last?.text, "Define the terms and symbols in: KL divergence")
        transport.send(.delta("It measures…"), .done(stopReason: "end_turn", credits: 1))
        try await waitUntil("answer sealed") { !model.isAnswering }

        // The selectable answer text: quotes and Copy keep formulas as LaTeX.
        let text = NSMutableAttributedString(string: "Scale by ")
        let formula = NSMutableAttributedString(attachment: NSTextAttachment(image: UIImage(systemName: "x.squareroot")!))
        formula.addAttribute(.chatLatex, value: "1/\\sqrt{d_k}", range: NSRange(location: 0, length: formula.length))
        text.append(formula); text.append(NSAttributedString(string: " here."))
        XCTAssertEqual(ChatSelectableText.quote(text, range: NSRange(location: 0, length: text.length)), "Scale by \\(1/\\sqrt{d_k}\\) here.")
        XCTAssertEqual(ChatSelectableText.soleFormula(text, range: NSRange(location: 9, length: 1)), "1/\\sqrt{d_k}")
        XCTAssertEqual(ChatSelectableText.soleFormula(text, range: NSRange(location: 8, length: 2)), "1/\\sqrt{d_k}", "Spaces around it are fine")
        XCTAssertNil(ChatSelectableText.soleFormula(text, range: NSRange(location: 0, length: 10)))

        var asked: [(ReaderModel.ChatQuoteAction, String)] = []
        let coordinator = ChatSelectableText.Coordinator()
        coordinator.onQuote = { asked.append(($0, $1)) }
        let view = UITextView(); view.attributedText = text
        let copy = UIMenu(identifier: .standardEdit, options: .displayInline, children: [UIAction(title: "Copy") { _ in }])
        let share = UIAction(title: "Share") { _ in }
        let menu = try XCTUnwrap(coordinator.textView(view, editMenuForTextIn: NSRange(location: 0, length: 5), suggestedActions: [copy, share]))
        let titles = menu.children.flatMap { ($0 as? UIMenu)?.children ?? [$0] }.compactMap { ($0 as? UIAction)?.title }
        XCTAssertEqual(titles, ["Copy", "Quote in Chat", "Explain", "Define", "Share"], "Copy first, then the chat actions, then the rest")
        let formulaMenu = try XCTUnwrap(coordinator.textView(view, editMenuForTextIn: NSRange(location: 9, length: 1), suggestedActions: [copy]))
        XCTAssertEqual(formulaMenu.children.compactMap { ($0 as? UIAction)?.title }, ["Copy LaTeX", "Copy as text", "Quote in Chat", "Explain", "Define"])
        coordinator.onQuote = nil
        XCTAssertNil(coordinator.textView(view, editMenuForTextIn: NSRange(location: 0, length: 5), suggestedActions: [copy]),
                     "Without actions (streaming, your own messages) the system menu is unchanged")
        XCTAssertTrue(asked.isEmpty)
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

    /// A3: a complete answer whose local save fails stays readable, and Try again saves that answer: it is never asked
    /// for (and paid for) a second time.
    func testAnAnswerThatCouldNotBeSavedStaysAndTryAgainOnlySavesIt() async throws {
        let (model, transport) = try await makeModel(consented: true)
        model.chatInput = "Why scale the dot products?"
        await model.sendMessage()
        try await waitUntil("request issued") { transport.requests.count == 1 }
        await model.flushDrafts()
        model.localPersistence.failingWritesForTesting = 1
        transport.send(.delta("Scaling keeps logits bounded."), .done(stopReason: "end_turn", credits: 1))
        try await waitUntil("finished") { !model.isAnswering }
        let issue = try XCTUnwrap(model.chatAnswerIssue)
        XCTAssertEqual(issue.code, "storage"); XCTAssertTrue(issue.retryable)
        XCTAssertEqual(model.chatMessages.map(\.payload.role), [.user], "Nothing was saved")
        XCTAssertEqual(model.chatTranscriptMessages.map(\.payload.text), ["Why scale the dot products?", "Scaling keeps logits bounded."],
                       "The answer that arrived stays readable")

        model.retryAnswer()
        try await waitUntil("saved") { model.chatMessages.count == 2 && !model.isAnswering }
        XCTAssertEqual(transport.requests.count, 1, "Try again saves the same answer; nothing is requested again")
        XCTAssertEqual(model.chatMessages.last?.payload.text, "Scaling keeps logits bounded.")
        XCTAssertEqual(model.chatMessages.last?.payload.status, .complete)
        XCTAssertNil(model.chatAnswerIssue)
        XCTAssertEqual(model.chatTranscriptMessages.count, 2, "No second copy of the answer")

        // A transport failure still asks again, as before.
        model.chatInput = "And without scaling?"
        await model.sendMessage()
        try await waitUntil("second request") { transport.requests.count == 2 }
        transport.send(.failure(code: "provider_unavailable"))
        try await waitUntil("failed") { !model.isAnswering }
        model.retryAnswer()
        try await waitUntil("asked again") { transport.requests.count == 3 }
        transport.send(.done(stopReason: "end_turn", credits: 0))
        try await waitUntil("finished again") { !model.isAnswering }
    }

    /// A2: a selection action whose question couldn't be saved keeps its quote and action, so Send again asks the
    /// same thing rather than a plain question.
    func testASelectionActionThatCouldNotBeSavedKeepsItsQuoteAndAction() async throws {
        let (model, transport) = try await makeModel(consented: true)
        model.selectionAction(.similar, quote: "multi-head attention")
        // The draft writes above were accepted synchronously; the next write is the question's commit.
        model.localPersistence.failingWritesForTesting = 1
        try await waitUntil("save failed") { model.error != nil }
        XCTAssertTrue(model.chatMessages.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(model.chatInput, SelectionAction.similar.prompt("multi-head attention"), "The prompt stays in the composer")
        model.error = nil

        await model.sendMessage()
        try await waitUntil("request issued") { transport.requests.count == 1 }
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.action, .related, "The action went with the second Send")
        XCTAssertEqual(request.selection, "multi-head attention", "The quote went with the second Send")
        transport.send(.done(stopReason: "end_turn", credits: 0))
        try await waitUntil("finished") { !model.isAnswering }
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

    func testWhyItMattersAsksForThePaperOnly() async throws {
        let (model, transport) = try await makeModel(consented: true)
        model.selectionAction(.relevance, quote: "We use label smoothing of 0.1.")
        try await waitUntil("request issued") { transport.requests.count == 1 }
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.action, .relevance, "The server leaves web search out")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        XCTAssertEqual(body["action"] as? String, "relevance")
        // Capabilities are always a list (an empty one says visual answers are off); Why it matters never adds papers.
        XCTAssertFalse((body["capabilities"] as? [String] ?? []).contains("web_import"))
        transport.send(.done(stopReason: "end_turn", credits: 0))
        try await waitUntil("finished") { !model.isAnswering }
        XCTAssertEqual(SelectionAction.define.chatAction, nil)
        XCTAssertEqual(SelectionAction.ingest.chatAction, .ingest)
    }

    /// Diagrams are checked before they are kept; one that doesn't parse is sent back once (its own metered request).
    func testABrokenDiagramIsSentBackOnceAndTheCorrectionKept() async throws {
        let (model, transport) = try await makeModel(consented: true)
        var checked: [String] = []
        model.diagramCheck = { source in
            checked.append(source)
            return source.contains("(x)") ? .invalid("Parse error on line 2: Expecting 'SQE', got 'PS'") : .valid
        }
        model.chatInput = "Draw the encoder"
        await model.sendMessage()
        try await waitUntil("request issued") { transport.requests.count == 1 }
        transport.send(.delta("Here it is."), .diagram(title: "Encoder", source: "flowchart TD\n A[Input (x)] --> B[Encoder]"),
                       .done(stopReason: "end_turn", credits: 3))
        try await waitUntil("repair requested") { transport.requests.count == 2 }
        let repair = transport.requests[1]
        XCTAssertEqual(repair.action, .diagramFix)
        XCTAssertNil(repair.documentID); XCTAssertNil(repair.selection)
        XCTAssertNotEqual(repair.operationID, transport.requests[0].operationID, "Its own operation: held and charged on its own")
        XCTAssertEqual(repair.turns.map(\.role), [.user])
        XCTAssertEqual(repair.turns.first?.text,
                       "Title: Encoder\nMermaid error: Parse error on line 2: Expecting 'SQE', got 'PS'\n\nflowchart TD\n A[Input (x)] --> B[Encoder]")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: repair.encoded()) as? [String: Any])
        XCTAssertEqual(body["mode"] as? String, "general"); XCTAssertEqual(body["action"] as? String, "diagram_fix")
        XCTAssertTrue(model.isAnswering, "The answer waits for its diagram")
        XCTAssertEqual(model.chatStreamingProgress?.text, "Fixing the diagram…")
        transport.send(.diagram(title: "Encoder v2", source: "flowchart TD\n A[\"Input x\"] --> B[Encoder]"), .done(stopReason: "end_turn", credits: 2))
        try await waitUntil("answer sealed") { !model.isAnswering }
        let answer = try XCTUnwrap(model.chatMessages.last)
        XCTAssertEqual(answer.payload.text, "Here it is.", "The repair adds no text")
        let link = try XCTUnwrap(model.chatDiagrams[answer.payload.entityID])
        XCTAssertEqual(link.title, "Encoder", "The answer's title stays")
        XCTAssertEqual(model.diagram(link.id)?.source, "flowchart TD\n A[\"Input x\"] --> B[Encoder]")
        XCTAssertEqual(checked.count, 2, "The correction is checked too")
        XCTAssertNil(model.chatStreamingProgress)
    }

    func testAFailedCorrectionKeepsTheOriginalAndAValidDiagramIsNotSentBack() async throws {
        let (model, transport) = try await makeModel(consented: true)
        model.diagramCheck = { $0.contains("broken") ? .invalid("Parse error") : .valid }
        model.chatInput = "Draw it"
        await model.sendMessage()
        try await waitUntil("request issued") { transport.requests.count == 1 }
        transport.send(.delta("Flow."), .diagram(title: "Flow", source: "flowchart TD\n broken"), .done(stopReason: "end_turn", credits: 1))
        try await waitUntil("repair requested") { transport.requests.count == 2 }
        transport.send(.failure(code: "insufficient_credits"))
        try await waitUntil("answer sealed") { !model.isAnswering }
        let answer = try XCTUnwrap(model.chatMessages.last)
        let link = try XCTUnwrap(model.chatDiagrams[answer.payload.entityID])
        XCTAssertEqual(model.diagram(link.id)?.source, "flowchart TD\n broken", "Kept; its view says it couldn't be drawn")
        XCTAssertNil(model.chatAnswerIssue, "The answer itself is fine")

        model.chatInput = "And another"
        await model.sendMessage()
        try await waitUntil("second question") { transport.requests.count == 3 }
        transport.send(.delta("Flow."), .diagram(title: "Flow", source: "flowchart TD\n a --> b"), .done(stopReason: "end_turn", credits: 1))
        try await waitUntil("answer sealed") { !model.isAnswering && model.chatMessages.count == 4 }
        XCTAssertEqual(transport.requests.count, 3, "A diagram that parses is never sent back")
        XCTAssertEqual(transport.requests.filter { $0.action == .diagramFix }.count, 1)
    }

    func testAnUnconfirmedDiagramCorrectionKeepsTheOriginal() async throws {
        let (model, transport) = try await makeModel(consented: true)
        model.diagramCheck = { $0.contains("broken") ? .invalid("Parse error") : .valid }
        let original = "flowchart TD\n broken"
        for ending in ["failure", "eof", "max_tokens"] {
            let firstRequest = transport.requests.count
            model.chatInput = "Draw it with \(ending)"
            await model.sendMessage()
            try await waitUntil("answer request issued") { transport.requests.count == firstRequest + 1 }
            transport.send(.delta("The complete answer."), .diagram(title: "Flow", source: original),
                           .done(stopReason: "end_turn", credits: 1))
            try await waitUntil("repair request issued") { transport.requests.count == firstRequest + 2 }
            transport.send(.diagram(title: "Flow", source: "flowchart TD\n A --> B"))
            switch ending {
            case "failure": transport.send(.failure(code: "provider_unavailable"))
            case "eof": transport.end()
            default: transport.send(.done(stopReason: "max_tokens", credits: 1))
            }
            try await waitUntil("original answer saved") { !model.isAnswering }
            let answer = try XCTUnwrap(model.chatMessages.last)
            let link = try XCTUnwrap(model.chatDiagrams[answer.payload.entityID])
            XCTAssertEqual(model.diagram(link.id)?.source, original, ending)
            XCTAssertEqual(answer.payload.status, .complete, "The original answer was already complete")
            XCTAssertEqual(transport.requests.count, firstRequest + 2, "No second repair on an uncertain result")
        }
    }

    /// The real check: the bundled Mermaid's parser in an off-screen web view.
    func testTheBundledMermaidParserChecksDiagrams() async throws {
        // Study (2026-10-14): the knowledge map's flowchart (state classes, link styles, the focus border) is valid
        // Mermaid for the bundled renderer, labels with Mermaid syntax characters included.
        let map = StudyMap(concepts: [StudyMap.Concept(id: "scaling", label: "Scaled dot-product attention (QK^T)", state: .learning, paragraphs: [2]),
            StudyMap.Concept(id: "softmax", label: "Softmax \"saturation\" [large logits]", state: .unknown, paragraphs: [2]), StudyMap.Concept(id: "end", label: "End of sequence", state: .verified, paragraphs: [])],
            links: [StudyMap.Link(from: "softmax", to: "scaling", kind: .prerequisite), StudyMap.Link(from: "scaling", to: "end", kind: .deeper), StudyMap.Link(from: "end", to: "softmax", kind: .related)],
            focus: "scaling", journey: ["scaling", "softmax"], next: .teach)
        if case .invalid(let error) = await MermaidCheck.check(map.mermaid) { XCTFail("The knowledge map must draw: \(error)") }
        if case .invalid(let error) = await MermaidCheck.check(StudyMap.empty.mermaid) { XCTFail("An empty map must draw: \(error)") }
        let valid = await MermaidCheck.check("flowchart TD\n A[\"Input (x)\"] --> B[Encoder]\n B --> C[Loss]")
        XCTAssertEqual(valid, .valid)
        let broken = await MermaidCheck.check("flowchart TD\n A[Input (x)] --> B[Encoder]")
        guard case .invalid(let message) = broken else { return XCTFail("\(broken)") }
        XCTAssertTrue(message.contains("Parse error"), message)
        let sequence = await MermaidCheck.check("sequenceDiagram\n Alice->>Bob: hi")
        XCTAssertEqual(sequence, .valid)
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

    // MARK: Model, effort, length and topic titles (2026-10-08)

    private func makeProfiledModel() async throws -> (ReaderModel, ScriptedChatTransport) {
        let transport = ScriptedChatTransport()
        transport.profiles = ScriptedChatTransport.table
        let (model, _) = try await makeModel(consented: true, transport: transport)
        // Settings › Chat defaults persist in this device's preferences (a UI journey may have changed them).
        model.chatDefaultProfile = .standard
        model.refreshChatProfiles()
        try await waitUntil("profile table loaded") { model.chatProfileTable != nil }
        return (model, transport)
    }

    func testFlashDefaultIsSentForANewChatAndExplicitSonnetStillWins() async throws {
        let key = "chat.defaultProfile", saved = UserDefaults.standard.object(forKey: "chat.defaultProfile")
        UserDefaults.standard.removeObject(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let transport = ScriptedChatTransport()
        let flash = ChatProfileChoice(model: .gemini, effort: .medium, length: .standard)
        transport.profiles = ChatProfileTable(version: ChatProfileTable.supportedVersion, defaultChoice: flash,
            estimates: ScriptedChatTransport.table.estimates)
        let (model, _) = try await makeModel(consented: true, transport: transport)
        model.refreshChatProfiles()
        try await waitUntil("Flash table loaded") { model.chatProfileTable != nil }
        XCTAssertEqual(model.chatDefaultProfile, flash)
        XCTAssertEqual(model.chatProfile, flash)
        model.chatInput = "What is the contribution?"
        await model.sendMessage()
        try await waitUntil("Flash request") { transport.requests.count == 1 }
        XCTAssertEqual(transport.requests[0].profile.id, "gemini-auto-standard")
        transport.send(.delta("The contribution."), .done(stopReason: "end_turn", credits: 1,
            model: "gemini-3.8-flash", profile: "gemini-medium-standard"))
        try await waitUntil("Flash sealed") { !model.isAnswering }
        model.chatDefaultProfile = .standard
        model.newChat(general: true)
        XCTAssertEqual(model.chatProfile, .standard)
        XCTAssertEqual(model.chatDefaultProfile, .standard, "an explicit preference overrides the recommended default")
    }

    func testAChosenProfileIsSentSavedWithTheAnswerAndKeptForTheChat() async throws {
        let (model, transport) = try await makeProfiledModel()
        XCTAssertEqual(model.chatProfile, .standard, "A new chat starts with Settings › Chat defaults")
        let opus = ChatProfileChoice(model: .opus, effort: .high, length: .detailed)
        model.setChatProfile(opus)
        XCTAssertEqual(model.chatProfile, opus)
        model.chatInput = "Why scale the dot products?"
        await model.sendMessage()
        try await waitUntil("request issued") { transport.requests.count == 1 }
        // The reader's model and length, with the effort the server chooses for each question (2026-10-16).
        let sent = ChatProfileChoice(model: .opus, effort: .auto, length: .detailed)
        XCTAssertEqual(transport.requests[0].profile, sent)
        XCTAssertTrue(transport.requests[0].topicTitle, "A chat without a topic title asks for one")
        transport.send(.delta("Scaling keeps logits bounded."), .title("Scaling in dot-product attention"),
                       .done(stopReason: "end_turn", credits: 9, model: "claude-opus-5-5", profile: opus.id))
        try await waitUntil("answer sealed") { !model.isAnswering }
        let answer = try XCTUnwrap(model.chatMessages.last)
        XCTAssertEqual(answer.payload.model, "claude-opus-5-5")
        XCTAssertEqual(answer.payload.profile, "opus-high-detailed")
        XCTAssertEqual(model.chatTitle, "Scaling in dot-product attention")
        XCTAssertTrue(model.chatHasTopicTitle)
        let summary = try XCTUnwrap(model.conversationSummaries.first { $0.id == model.activeConversation })
        XCTAssertEqual(summary.titleSource, PrivateEvent.generatedTitle)
        XCTAssertEqual(ChatHistoryRow(summary: summary, paperTitle: nil).title, "Scaling in dot-product attention", "All chats shows the topic")
        XCTAssertEqual(model.activeBranchID, answer.id, "The answer, not the title, is the branch head")

        // The follow-up keeps the chat's choice and asks for no second title.
        model.chatInput = "And without scaling?"
        await model.sendMessage()
        try await waitUntil("follow-up") { transport.requests.count == 2 }
        XCTAssertEqual(transport.requests[1].profile, sent)
        XCTAssertFalse(transport.requests[1].topicTitle)
        transport.send(.delta("Softmax saturates."), .title("Another title"), .done(stopReason: "end_turn", credits: 1))
        try await waitUntil("sealed") { !model.isAnswering }
        XCTAssertEqual(model.chatTitle, "Scaling in dot-product attention", "A titled chat keeps its title")
        await model.flushDrafts()

        // Reopened elsewhere (a fresh model on the same encrypted store), the chat remembers its choice from its answers.
        let reopened = ReaderModel(configuration: nil, chatTransport: ScriptedChatTransport(), chatConsentStore: ConsentMemory())
        try await reopened.configureDurableDraftFixture(reset: false)
        reopened.openConversation(try XCTUnwrap(model.activeConversation))
        XCTAssertEqual(reopened.chatProfile.model, .opus); XCTAssertEqual(reopened.chatProfile.length, .detailed)
        XCTAssertEqual(reopened.chatTitle, "Scaling in dot-product attention")

        // A new chat starts from the default again.
        model.newChat(general: false)
        XCTAssertEqual(model.chatProfile, .standard)
    }

    func testWithoutTheServerTableRequestsAreExactlyAsBefore() async throws {
        let (model, transport) = try await makeModel(consented: true)
        model.refreshChatProfiles()
        try await waitUntil("fetch failed") { model.chatProfileTableFailed }
        model.setChatProfile(ChatProfileChoice(model: .haiku, effort: .low, length: .brief))
        model.chatInput = "Why scale the dot products?"
        await model.sendMessage()
        try await waitUntil("request issued") { transport.requests.count == 1 }
        XCTAssertEqual(transport.requests[0].profile, .standard)
        XCTAssertFalse(transport.requests[0].topicTitle)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: try transport.requests[0].encoded()) as? [String: Any])
        XCTAssertNil(body["profile"]); XCTAssertNil(body["topic_title"])
        transport.send(.delta("Scaling keeps logits bounded."), .done(stopReason: "end_turn", credits: 1))
        try await waitUntil("sealed") { !model.isAnswering }
        XCTAssertNil(model.chatMessages.last?.payload.profile, "An older server reports no profile; none is invented")
        XCTAssertFalse(model.chatHasTopicTitle)
        XCTAssertEqual(model.chatTitle, "Why scale the dot products?")
    }

    func testSelectionActionsUseTheChatsChoiceAndUntitledChatsGetATitleLater() async throws {
        let (model, transport) = try await makeProfiledModel()
        let haiku = ChatProfileChoice(model: .haiku, effort: .medium, length: .brief)
        model.setChatProfile(haiku)
        model.selectionAction(.define, quote: "scaled dot-product attention")
        try await waitUntil("request issued") { transport.requests.count == 1 }
        // The chat's model and length, with the server's automatic effort (2026-10-16).
        let sent = ChatProfileChoice(model: .haiku, effort: .auto, length: .brief)
        XCTAssertEqual(transport.requests[0].profile, sent, "The action uses the choice visible in the chat")
        XCTAssertTrue(transport.requests[0].topicTitle)
        // The title arrives but the answer is interrupted: neither is kept as a title.
        transport.send(.delta("Partial"), .title("Should not be kept"))
        transport.end(throwing: URLError(.networkConnectionLost))
        try await waitUntil("interrupted") { !model.isAnswering }
        XCTAssertEqual(model.chatMessages.last?.payload.status, .interrupted)
        XCTAssertEqual(model.chatMessages.last?.payload.profile, sent.id, "An interrupted answer keeps the profile it was asked with")
        XCTAssertFalse(model.chatHasTopicTitle)
        XCTAssertTrue(model.chatTitle.hasPrefix("Explain · scaled dot-product attention"))

        // The chat is used again later: it asks for its title then.
        model.chatInput = "Say more"
        await model.sendMessage()
        try await waitUntil("second request") { transport.requests.count == 2 }
        XCTAssertTrue(transport.requests[1].topicTitle)
        transport.send(.delta("More."), .title("Scaled dot-product attention"), .done(stopReason: "end_turn", credits: 1, model: "claude-haiku-5-5", profile: haiku.id))
        try await waitUntil("sealed") { !model.isAnswering }
        XCTAssertEqual(model.chatTitle, "Scaled dot-product attention")
    }

    func testRenamingReplacesTheTitleAndAGeneratedTitleNeverOverwritesIt() async throws {
        let (model, transport) = try await makeProfiledModel()
        model.chatInput = "Why scale the dot products?"
        await model.sendMessage()
        try await waitUntil("request issued") { transport.requests.count == 1 }
        // Renamed while the answer streams: its generated title must not replace the reader's.
        let conversation = try XCTUnwrap(model.activeConversation)
        await model.renameConversation(conversation, to: "  My attention\nnotes ")
        XCTAssertEqual(model.chatTitle, "My attention notes")
        transport.send(.delta("Bounded."), .title("Scaling in dot-product attention"), .done(stopReason: "end_turn", credits: 1))
        try await waitUntil("sealed") { !model.isAnswering }
        XCTAssertEqual(model.chatTitle, "My attention notes")
        XCTAssertEqual(model.conversationSummaries.first { $0.id == conversation }?.titleSource, PrivateEvent.renamedTitle)
        await model.renameConversation(conversation, to: "   ")
        XCTAssertEqual(model.chatTitle, "My attention notes", "An empty name is ignored")
        XCTAssertEqual(model.chatMessages.count, 2, "Renaming adds no message")
    }

    func testChatDefaultsAreStoredAndAnUnofferedChoiceFallsBackToTheServersDefault() async throws {
        let (model, transport) = try await makeProfiledModel()
        let saved = model.chatDefaultProfile
        defer { model.chatDefaultProfile = saved }
        model.chatDefaultProfile = ChatProfileChoice(model: .sonnet, effort: .medium, length: .detailed)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "chat.defaultProfile"), "sonnet-medium-detailed")
        model.newChat(general: false)
        XCTAssertEqual(model.chatProfile.id, "sonnet-medium-detailed")
        // A server that stopped offering Opus answers with its default instead of the reader's stale choice.
        var estimates = ScriptedChatTransport.table.estimates
        for key in estimates.keys where key.model == .opus { estimates[key] = nil }
        transport.profiles = ChatProfileTable(version: ChatProfileTable.supportedVersion, defaultChoice: .standard, estimates: estimates)
        model.refreshChatProfiles(force: true)
        try await waitUntil("table replaced") { model.chatProfileTable?.offers(ChatProfileChoice(model: .opus, effort: .low, length: .standard)) == false }
        model.setChatProfile(ChatProfileChoice(model: .opus, effort: .low, length: .brief))
        model.chatInput = "Hello"
        await model.sendMessage()
        try await waitUntil("request issued") { transport.requests.count == 1 }
        XCTAssertEqual(transport.requests[0].profile, .standard)
    }
}
#endif
