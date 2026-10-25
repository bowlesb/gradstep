import Foundation
import Testing
@testable import ScienceReaderCore

/// Your AI usage by range and by day, and each row's way back (owner, TestFlight 92; AIUsageRange.swift).
@Suite struct AIUsageRangeTests {
    private static let now = Date(timeIntervalSince1970: 1_792_929_600) // 2026-10-25 12:00 UTC

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!; calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// One server row: `minutesAgo` before `now`, settled 20 s later.
    private static func op(_ n: Int, minutesAgo: Double, _ activity: String = "chat", credits: Int? = 2, held: Int = 0,
                           input: Int = 100, output: Int = 10, settled: Bool = true) throws -> AIUsageOperation {
        let created = now.addingTimeInterval(-minutesAgo * 60)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let row: [String: Any] = [
            "id": String(format: "00000000-0000-4000-8000-%012d", n), "created_at": iso.string(from: created),
            "settled_at": settled ? iso.string(from: created.addingTimeInterval(20)) : NSNull(), "kind": "chat", "activity": activity,
            "action": NSNull(), "ending": NSNull(), "outcome": credits == nil ? "in_progress" : "completed", "paid_by": "you",
            "credits": credits.map { $0 as Any } ?? NSNull(), "credits_held": held, "model": "gemini-3.8-flash", "calls": 1,
            "input_tokens": input, "cached_tokens": 0, "cache_write_tokens": 0, "output_tokens": output, "searches": 0, "audio_ms": 0,
            "estimated": false, "pending": false, "parts": [] as [Any]]
        let page: [String: Any] = ["days": 2, "activity": NSNull(), "operations": [row], "totals": NSNull(), "activities": NSNull(), "next": NSNull()]
        return try #require(try AIUsagePage.decode(JSONSerialization.data(withJSONObject: page)).operations.first)
    }

    @Test func eachRangeAsksTheServerForEnoughWholeDays() {
        #expect(AIUsageRange.allCases.map(\.title) == ["Day", "Week", "Month", "Year"])
        #expect(AIUsageRange.allCases.map(\.serverDays) == [2, 7, 30, 365])
        #expect(AIUsageRange.day.label == "Last 24 hours" && AIUsageRange.month.label == "Last 30 days")
        #expect(AIUsageRange.day.since(now: Self.now) == Self.now.addingTimeInterval(-86_400))
        #expect(AIUsageRange.week.since(now: Self.now) == nil, "the server's window is the range")
    }

    @Test func theDayIsTheLast24HoursWithItsOwnTotalsAndActivities() throws {
        let rows = [try Self.op(1, minutesAgo: 5, "chat", credits: 3, input: 1_000, output: 200),
                    try Self.op(2, minutesAgo: 60, "figure_explainer", credits: 2),
                    try Self.op(3, minutesAgo: 90, "study", credits: nil, held: 30),
                    try Self.op(4, minutesAgo: 600, "figure_explainer", credits: 2),
                    try Self.op(5, minutesAgo: 1_439, "chat", credits: 1),
                    try Self.op(6, minutesAgo: 1_441, "podcast", credits: 55)]
        let since = try #require(AIUsageRange.day.since(now: Self.now))
        let all = AIUsageWindow.make(rows, since: since, activity: nil)
        #expect(all.rows.map(\.id.uuidString.last) == ["1", "2", "3", "4", "5"], "the podcast is 24 h and a minute ago")
        #expect(all.totals.operations == 5 && all.totals.credits == 8 && all.totals.creditsHeld == 30)
        #expect(all.totals.inputTokens == 1_400 && all.totals.outputTokens == 240)
        // Most credits first, then most requests, then the activity's name; the podcast isn't in the window.
        #expect(all.activities.map(\.activity) == [.chat, .figureExplainer, .study])
        #expect(all.activities.map(\.credits) == [4, 4, 0] && all.activities.map(\.operations) == [2, 2, 1])
        let figures = AIUsageWindow.make(rows, since: since, activity: .figureExplainer)
        #expect(figures.rows.count == 2 && figures.totals.credits == 4 && figures.totals.operations == 2)
        #expect(figures.activities == all.activities, "the chips are the window's, whatever is chosen")
    }

    /// TestFlight 92: a question that didn't finish read "132k in · 10k out", what was set aside for it, not what was used.
    @Test func onlyFinishedRequestsShowTheirTokens() {
        for outcome in [AIUsageOutcome.completed, .stopped, .free] { #expect(outcome.reportsTokens && outcome.unreportedTokens == nil, "\(outcome)") }
        for outcome in [AIUsageOutcome.failed, .notCharged, .inProgress, .checking] { #expect(!outcome.reportsTokens && outcome.unreportedTokens != nil, "\(outcome)") }
        #expect(AIUsageOutcome.failed.label == "Didn’t finish · not charged", "the label stays")
    }

    @Test func theListIsInDaysNewestFirst() throws {
        let rows = [try Self.op(1, minutesAgo: 5), try Self.op(2, minutesAgo: 600), try Self.op(3, minutesAgo: 13 * 60),
                    try Self.op(4, minutesAgo: 3 * 1_440), try Self.op(5, minutesAgo: 3 * 1_440 + 30), try Self.op(6, minutesAgo: 400 * 1_440)]
        let sections = AIUsageFormat.sections(rows, now: Self.now, calendar: Self.calendar)
        #expect(sections.map(\.title) == ["Today", "Yesterday", "Thursday, October 22", "Saturday, September 20, 2025"])
        #expect(sections.map(\.id) == ["2026-10-25", "2026-10-24", "2026-10-22", "2025-09-20"])
        #expect(sections.map { $0.rows.count } == [2, 1, 2, 1])
        #expect(sections.flatMap(\.rows) == rows, "the list's order is kept")
        #expect(AIUsageFormat.sections([], now: Self.now, calendar: Self.calendar).isEmpty)
    }

    // MARK: The way back

    private static func message(_ conversation: UUID, paper: UUID?, reader: Bool, secondsAgo: Double) -> AIUsageHistoryMessage {
        AIUsageHistoryMessage(conversationID: conversation, paper: paper, fromReader: reader, at: now.addingTimeInterval(-secondsAgo))
    }

    @Test func aRequestFindsItsConversation() throws {
        let paper = UUID(), other = UUID()
        let paperChat = UUID(), otherChat = UUID(), general = UUID(), recorded = UUID()
        // The request was made 10 minutes ago and settled 20 s later.
        let op = try Self.op(1, minutesAgo: 10)
        let history = [Self.message(otherChat, paper: other, reader: true, secondsAgo: 605),
                       Self.message(paperChat, paper: paper, reader: true, secondsAgo: 590),
                       Self.message(general, paper: nil, reader: true, secondsAgo: 601),
                       Self.message(paperChat, paper: paper, reader: false, secondsAgo: 575)].sorted { $0.at < $1.at }
        // What this device recorded when it asked wins.
        #expect(AIUsageFormat.conversation(for: op, provenance: AIUsageProvenance(kind: .paper, conversationID: recorded), history: history) == recorded)
        // Otherwise the nearest message, preferring the recorded paper, or no paper for a general chat.
        #expect(AIUsageFormat.conversation(for: op, provenance: AIUsageProvenance(kind: .explain, membershipID: paper.uuidString.lowercased()), history: history) == paperChat)
        #expect(AIUsageFormat.conversation(for: op, provenance: AIUsageProvenance(kind: .paper, documentID: other), history: history) == otherChat)
        #expect(AIUsageFormat.conversation(for: op, provenance: AIUsageProvenance(kind: .general), history: history) == general)
        #expect(AIUsageFormat.conversation(for: op, provenance: nil, history: history) == general, "another device's request: the nearest message (1 s)")
        // Nothing within 30 seconds; not a conversation's activity; the paper's AI Explainer.
        #expect(AIUsageFormat.conversation(for: try Self.op(2, minutesAgo: 30), provenance: nil, history: history) == nil)
        #expect(AIUsageFormat.conversation(for: try Self.op(3, minutesAgo: 10, "figure_explainer"), provenance: nil, history: history) == nil)
        #expect(AIUsageFormat.conversation(for: op, provenance: AIUsageProvenance(kind: .paper, action: "paper_explainer"), history: history) == nil)
        for activity in ["study", "related_papers", "why_it_matters", "add_paper"] {
            #expect(AIUsageFormat.conversation(for: try Self.op(4, minutesAgo: 10, activity), provenance: nil, history: history) != nil, "\(activity)")
        }
    }

    @Test func anExplainerFindsTheExplanationKeptHere() throws {
        let paper = UUID()
        func kept(_ action: String, secondsAgo: Double) -> ExplanationSubject {
            ExplanationSubject(paperID: paper, paperTitle: "DPO", manifestSHA256: String(repeating: "a", count: 64), itemID: "S3.F2", label: "Figure 2",
                               action: action, savedAt: Self.now.addingTimeInterval(-secondsAgo))
        }
        // Made 10 minutes ago, settled 20 s later; kept as it was settled.
        let figure = try Self.op(1, minutesAgo: 10, "figure_explainer")
        let subjects = [kept("equation", secondsAgo: 579), kept("figure", secondsAgo: 579), kept("figure", secondsAgo: 3_000)]
        #expect(AIUsageFormat.explanation(for: figure, provenance: nil, kept: subjects) == subjects[1])
        #expect(AIUsageFormat.explanation(for: try Self.op(2, minutesAgo: 10, "equation_explainer"), provenance: nil, kept: subjects) == subjects[0])
        #expect(AIUsageFormat.explanation(for: try Self.op(3, minutesAgo: 30, "figure_explainer"), provenance: nil, kept: subjects) == nil, "none kept then")
        // The paper's AI Explainer is metered as chat: matched only for a paper request with no conversation.
        let explainer = [kept("paper_explainer", secondsAgo: 579)]
        let chat = try Self.op(4, minutesAgo: 10, "chat")
        #expect(AIUsageFormat.explanation(for: chat, provenance: AIUsageProvenance(kind: .paper), kept: explainer) == explainer[0])
        #expect(AIUsageFormat.explanation(for: chat, provenance: AIUsageProvenance(kind: .general), kept: explainer) == nil)
        #expect(AIUsageFormat.explanation(for: chat, provenance: AIUsageProvenance(kind: .paper, conversationID: UUID()), kept: explainer) == nil)
    }

    @Test func theRequestCarriesItsLinkOnlyOnThisDevice() throws {
        let conversation = UUID()
        let request = try ChatGenerationRequest.make(operationID: UUID(), documentID: UUID(), transcript: [ChatTurnInput(role: .user, text: "Why?")],
                                                     selection: "a passage").linked(conversation: conversation)
        let provenance = AIUsageProvenance(request)
        #expect(provenance.kind == .explain && provenance.conversationID == conversation && provenance.itemID == nil)
        let body = String(decoding: try request.encoded(), as: UTF8.self)
        #expect(!body.contains(conversation.uuidString.lowercased()) && !body.contains(conversation.uuidString), "never sent")
        #expect(request.attaching([]).usageConversationID == conversation, "a figure asked for again keeps its place")
        let item = try ChatGenerationRequest.make(operationID: UUID(), documentID: UUID(), transcript: [ChatTurnInput(role: .user, text: "Figure 2")],
                                                  selection: "caption", action: .figure).linked(item: "S3.F2")
        #expect(AIUsageProvenance(item).itemID == "S3.F2" && AIUsageProvenance(item).action == "figure")
    }

    @Test func olderRecordsStillDecodeAndNewOnesKeepTheirLinks() throws {
        let suite = "ai-usage-range-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = UUID(), old = UUID(), new = UUID(), conversation = UUID(), catalog = UUID()
        // As builds before TestFlight 93 wrote them: the kind, membership and document only.
        let older = "[{\"id\":\"\(old.uuidString)\",\"p\":{\"kind\":\"paper\",\"membershipID\":\"m\"}}]"
        defaults.set(Data(older.utf8), forKey: "gradstep.usage-provenance.v1.test.\(account.uuidString.lowercased())")
        let store = AIUsageProvenanceStore(environment: "test", accountID: account, defaults: { UserDefaults(suiteName: suite)! })
        store.remember(new, AIUsageProvenance(kind: .recommendation, membershipID: "seed", catalogID: catalog, added: ["a", "b"]))
        let all = store.all()
        #expect(all[old] == AIUsageProvenance(kind: .paper, membershipID: "m"))
        #expect(all[new]?.added == ["a", "b"] && all[new]?.catalogID == catalog && all[new]?.kind == .recommendation)
        store.remember(old, AIUsageProvenance(kind: .general, conversationID: conversation))
        #expect(store.all()[old]?.conversationID == conversation)
    }

    @Test func historyIsEveryLiveConversationsTimedMessagesOldestFirst() throws {
        let device = UUID(), kept = UUID(), removed = UUID(), paper = UUID(), base: Int64 = 1_792_929_000_000
        func root(_ id: UUID, document: UUID?) -> AppliedEvent {
            AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .conversation, entityID: id, documentID: document, text: "Chat"))
        }
        func message(_ conversation: UUID, after parent: UUID, _ role: PrivateEvent.Role, at: Int64?) -> AppliedEvent {
            let id = UUID()
            return AppliedEvent(id: id, deviceID: device, payload: PrivateEvent(kind: .message, entityID: id, parents: [parent], conversationID: conversation,
                                                                             text: "x", role: role, status: .complete, createdAt: at))
        }
        var state = PrivateState()
        let keptRoot = root(kept, document: paper), removedRoot = root(removed, document: nil)
        let question = message(kept, after: keptRoot.id, .user, at: base + 1_000)
        let answer = message(kept, after: question.id, .assistant, at: base + 9_000)
        let untimed = message(kept, after: answer.id, .user, at: nil)
        let gone = message(removed, after: removedRoot.id, .user, at: base)
        for event in [keptRoot, removedRoot, question, answer, untimed, gone] { try state.apply(event) }
        try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .tombstone, entityID: removed)))
        let history = state.usageHistory()
        #expect(history.map(\.conversationID) == [kept, kept])
        #expect(history.map(\.fromReader) == [true, false] && history.allSatisfy { $0.paper == paper })
        #expect(history.first?.at == Date(timeIntervalSince1970: Double(base + 1_000) / 1000))
    }
}
