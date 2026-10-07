import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct ConversationSummaryTests {
    private let device = UUID()
    private let base: Int64 = 1_790_000_000_000

    private func root(_ conversation: UUID, _ title: String, document: UUID? = nil, at: Int64? = nil) -> AppliedEvent {
        AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .conversation, entityID: conversation, documentID: document,
                                                                         text: title, createdAt: at))
    }

    private func message(_ conversation: UUID, after parent: UUID, _ role: PrivateEvent.Role, _ text: String, at: Int64? = nil) -> AppliedEvent {
        let id = UUID()
        return AppliedEvent(id: id, deviceID: device, payload: PrivateEvent(kind: .message, entityID: id, parents: [parent],
            conversationID: conversation, text: text, role: role, status: .complete, createdAt: at))
    }

    @Test func lastUsedIsTheNewestMessageTimeAndStartedTheRootTime() throws {
        let conversation = UUID(), paper = UUID()
        var state = PrivateState()
        let start = root(conversation, "Why scale by √d?", document: paper, at: base)
        let question = message(conversation, after: start.id, .user, "Why scale by √d?", at: base)
        let answer = message(conversation, after: question.id, .assistant, "**Variance** grows with $d$.\n\n$$x$$", at: base + 5_000)
        let followUp = message(conversation, after: answer.id, .user, "And for small d?", at: base + 3_600_000)
        for event in [start, question, answer, followUp] { try state.apply(event) }
        let summary = try #require(state.conversationSummaries().first)
        #expect(summary.id == conversation)
        #expect(summary.title == "Why scale by √d?")
        #expect(summary.documentID == paper)
        #expect(summary.messageCount == 3)
        #expect(summary.startedAt == Date(timeIntervalSince1970: Double(base) / 1000))
        #expect(summary.lastUsedAt == Date(timeIntervalSince1970: Double(base + 3_600_000) / 1000))
        #expect(summary.latestAnswer?.hasPrefix("**Variance**") == true)
        #expect(summary.questions == "And for small d?\nWhy scale by √d?")
        #expect(ChatPreview.plain(summary.latestAnswer ?? "") == "Variance grows with d.")
    }

    @Test func deletedConversationsAndMessagesAreLeftOut() throws {
        let kept = UUID(), removed = UUID()
        var state = PrivateState()
        let keptRoot = root(kept, "Kept"), removedRoot = root(removed, "Removed")
        let question = message(kept, after: keptRoot.id, .user, "Kept question")
        let answer = message(kept, after: question.id, .assistant, "Deleted answer")
        for event in [keptRoot, removedRoot, question, answer] { try state.apply(event) }
        try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .tombstone, entityID: removed)))
        try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .tombstone, entityID: answer.payload.entityID)))
        let summaries = state.conversationSummaries()
        #expect(summaries.map(\.id) == [kept])
        #expect(summaries.first?.messageCount == 1)
        #expect(summaries.first?.latestAnswer == nil)
    }

    @Test func historyWithoutTimesFallsBackToArrivalOrder() throws {
        let older = UUID(), newer = UUID()
        var state = PrivateState()
        let olderRoot = root(older, "Older"), newerRoot = root(newer, "Newer")
        try state.apply(olderRoot); try state.apply(newerRoot)
        try state.apply(message(older, after: olderRoot.id, .user, "A later question in the older conversation"))
        let summaries = Dictionary(uniqueKeysWithValues: state.conversationSummaries().map { ($0.id, $0) })
        #expect(summaries[older]?.lastUsedAt == nil)
        #expect(summaries[older]?.startedAt == nil)
        // The older conversation's newest event arrived last.
        #expect((summaries[older]?.lastArrival ?? 0) > (summaries[newer]?.lastArrival ?? 0))
    }

    @Test func arrivalOrderIsNotPartOfEqualityOrEncoding() throws {
        let note = UUID()
        let first = AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .note, entityID: note, text: "a"))
        let second = AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .note, entityID: UUID(), text: "b"))
        var a = PrivateState(), b = PrivateState()
        try a.apply(first); try a.apply(second)
        try b.apply(second); try b.apply(first)
        #expect(a == b)
        #expect(a.arrivalIndex(first.id) == 0 && b.arrivalIndex(first.id) == 1)
        let decoded = try JSONDecoder().decode(PrivateState.self, from: JSONEncoder().encode(a))
        #expect(decoded == a)
        #expect(decoded.arrivalIndex(first.id) == nil)
    }

    @Test func storeReloadKeepsJournalOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.sqlite")
        let account = UUID(), key = ReaderCrypto.randomKey(), keys = KeyBundle.generate(accountID: account)
        let store = try EncryptedStore(url: path, accountID: account, localKey: key, keys: keys)
        var ids: [UUID] = []
        for index in 0..<5 { ids.append(try await store.append(PrivateEvent(kind: .note, text: "note \(index)"), deviceID: device).id) }
        let reopened = try EncryptedStore(url: path, accountID: account, localKey: key, keys: keys)
        let state = await reopened.state()
        #expect(ids.map { state.arrivalIndex($0) } == [0, 1, 2, 3, 4])
    }

    @Test func creationTimeRoundTripsAndOlderPayloadsStillDecode() throws {
        let keys = KeyBundle.generate(accountID: UUID())
        let event = PrivateEvent(kind: .message, conversationID: UUID(), text: "Q", role: .user, status: .complete, createdAt: base)
        let envelope = try ReaderCrypto.seal(event, id: UUID(), deviceID: device, keys: keys)
        #expect(try ReaderCrypto.open(envelope, keys: keys).createdAt == base)
        // A payload from before 2026-10-07 has no time.
        let legacy = try ReaderCrypto.seal(PrivateEvent(kind: .note, text: "old"), id: UUID(), deviceID: device, keys: keys)
        #expect(try ReaderCrypto.open(legacy, keys: keys).createdAt == nil)
        // An older reader (no `createdAt` field) ignores the key.
        struct OlderPayload: Decodable { let kind: String; let text: String? }
        let older = try JSONDecoder().decode(OlderPayload.self, from: ReaderCrypto.encode(event))
        #expect(older.text == "Q")
        #expect(throws: ReaderError.invalidEvent) {
            try PrivateEvent(kind: .note, text: "x", createdAt: -1).validate()
        }
        #expect(PrivateEvent.timestamp(Date(timeIntervalSince1970: 1.2345)) == 1_234)
    }

    /// Hundreds of conversations: one pass, well under a frame budget's worth of work per history change.
    @Test func manyConversationsSummarizeInOnePass() throws {
        var state = PrivateState()
        for n in 0..<500 {
            let conversation = UUID(), start = root(conversation, "Question \(n)", at: base + Int64(n) * 1_000)
            try state.apply(start)
            var parent = start.id
            for turn in 0..<10 {
                let next = message(conversation, after: parent, turn % 2 == 0 ? .user : .assistant, "Message \(turn) of \(n)",
                                   at: base + Int64(n) * 1_000 + Int64(turn))
                try state.apply(next); parent = next.id
            }
        }
        let clock = ContinuousClock(), started = clock.now
        let summaries = state.conversationSummaries()
        let elapsed = clock.now - started
        #expect(summaries.count == 500)
        #expect(summaries.allSatisfy { $0.messageCount == 10 })
        #expect(summaries.map(\.id) == summaries.map(\.id).sorted { $0.wire < $1.wire }, "Stable order")
        #expect(elapsed < .seconds(2), "5,500 events took \(elapsed)")
    }

    @Test func previewDropsMarkdownCodeAndSources() {
        let answer = "## Short answer\n\n- It *keeps* the `softmax` well-scaled.\n\n```\ncode\n```\n\nSee [the paper](https://example.com).\n\nSources:\n1. https://example.com/a"
        #expect(ChatPreview.plain(answer) == "Short answer: It keeps the softmax well-scaled. See the paper (https://example.com).")
        #expect(ChatPreview.readableMath(#"\sqrt{d_k}"#) == "√d_k")
        #expect(ChatPreview.readableMath(#"z = \mu + \sigma \odot \epsilon"#) == "z = μ + σ ⊙ ε")
        #expect(ChatPreview.readableMath(#"\log \pi_{\mathrm{ref}}(y|x) \in \mathbb{R}"#) == "log π_ref(y|x) ∈ R")
        #expect(ChatPreview.readableMath(#"QK^\top"#) == "QKᵀ")
        #expect(ChatPreview.plain(String(repeating: "word ", count: 100), limit: 20) == "word word word word…")
        #expect(ChatPreview.plain("a * b") == "a * b")
    }
}
