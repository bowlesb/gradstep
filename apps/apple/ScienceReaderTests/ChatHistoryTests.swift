import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// All chats as a table (owner request 2026-10-07): which columns fit, ordering, the quick filter and search, the
/// labels, and that a saved question carries its time and can be deleted.
@MainActor
final class ChatHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_187_200)   // 2026-10-05 08:00 UTC, a Monday
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!; calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func summary(_ n: Int, _ title: String, paper: UUID? = nil, messages: Int = 2, started: TimeInterval? = nil,
                         lastUsed: TimeInterval? = nil, arrival: Int = 0, questions: String = "") -> ConversationSummary {
        ConversationSummary(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012ld", n))!, title: title, documentID: paper,
                            messageCount: messages, startedAt: started.map { now - $0 }, lastUsedAt: lastUsed.map { now - $0 },
                            lastArrival: arrival, startArrival: arrival, latestAnswer: nil, questions: questions.isEmpty ? title : questions)
    }

    private let attention = UUID(), dpo = UUID(), removed = UUID()
    private var titles: [UUID: String] { [attention: "Attention Is All You Need", dpo: "Direct Preference Optimization"] }

    private var fixture: [ConversationSummary] {
        [summary(1, "Why scale by √d_k?", paper: attention, messages: 4, started: 7_200, lastUsed: 120, arrival: 10),
         summary(2, "Compare DPO and IPO", messages: 6, started: 90_000, lastUsed: 3_600, arrival: 9),
         summary(3, "Derive the DPO loss", paper: dpo, messages: 2, started: 400_000, lastUsed: 300_000, arrival: 8,
                 questions: "Derive the DPO loss\nWhere does the réference policy enter?"),
         summary(4, "Ablation in Table 4", paper: removed, messages: 2, started: 800_000, lastUsed: 700_000, arrival: 7),
         // History saved before times were recorded: no times, ordered by arrival on this device.
         summary(5, "Warmup with Adam", messages: 3, arrival: 3),
         summary(6, "Notes on RAG evaluation", messages: 1, arrival: 5)]
    }

    private func ids(_ rows: [ChatHistoryRow]) -> [Int] {
        rows.map { Int($0.id.uuidString.suffix(12))! }
    }

    private func query(filter: ChatHistoryFilter = .all, search: String = "", sort: ChatHistorySort = .default) -> [Int] {
        ids(ChatHistoryQuery.rows(fixture, paperTitles: titles, filter: filter, search: search, sort: sort))
    }

    func testOptionalTopicsSearchAndSortUseTheLibraryTagsLocally() {
        let topics = [attention: ["Transformers", "Attention"], dpo: ["Alignment"]]
        let matches = ChatHistoryQuery.rows(fixture, paperTitles: titles, filter: .all, search: "attention transformers",
                                            sort: .default, paperTopics: topics)
        XCTAssertEqual(ids(matches), [1])
        let ascending = ChatHistoryQuery.rows(fixture, paperTitles: titles, filter: .all, search: "",
            sort: .init(field: .topics, ascending: true), paperTopics: topics)
        let descending = ChatHistoryQuery.rows(fixture, paperTitles: titles, filter: .all, search: "",
            sort: .init(field: .topics, ascending: false), paperTopics: topics)
        XCTAssertEqual(Array(ids(ascending).prefix(2)), [3, 1])
        XCTAssertEqual(Array(ids(descending).prefix(2)), [1, 3])
        XCTAssertTrue(ascending.suffix(4).allSatisfy { $0.topics.isEmpty }, "General and removed-paper chats have no invented topics")
        XCTAssertEqual(ascending.first?.topics, ["Alignment"])
    }

    func testAnswerLengthAndKindSortsUseTheCurrentConversation() {
        let a = ConversationSummary(id: UUID(), title: "Long", documentID: attention, messageCount: 2, startedAt: now,
                                    lastUsedAt: now, lastArrival: 1, latestAnswer: "preview", questions: "Long", latestAnswerWords: 1400)
        let b = ConversationSummary(id: UUID(), title: "Short", documentID: nil, messageCount: 8, startedAt: now,
                                    lastUsedAt: now, lastArrival: 2, latestAnswer: "short answer", questions: "Short")
        let rows = ChatHistoryQuery.rows([b, a], paperTitles: titles, filter: .all, search: "",
                                        sort: .init(field: .answerLength, ascending: false))
        XCTAssertEqual(rows.map(\.id), [a.id, b.id])
        XCTAssertEqual(ChatHistoryQuery.sorted(rows, by: .init(field: .kind, ascending: false)).map(\.id), [b.id, a.id])
        XCTAssertEqual(ChatHistoryFormat.words(a.latestAnswerWords), "1.4k words")
        XCTAssertEqual(ChatHistoryFormat.words(0), "—")
        XCTAssertEqual(ChatHistoryFormat.words(1), "1 word")
    }

    /// Opened from a paper, All chats starts on "This paper": that paper's chats only, newest first.
    func testThisPaperFilterShowsOnlyThatPapersChats() {
        XCTAssertEqual(ids(ChatHistoryQuery.rows(fixture, paperTitles: titles, filter: .thisPaper, paperID: attention, search: "", sort: .default)), [1])
        XCTAssertEqual(ids(ChatHistoryQuery.rows(fixture, paperTitles: titles, filter: .thisPaper, paperID: removed, search: "", sort: .default)), [4],
                       "Also a paper no longer in the library")
        XCTAssertEqual(ids(ChatHistoryQuery.rows(fixture, paperTitles: titles, filter: .thisPaper, paperID: nil, search: "", sort: .default)), [],
                       "Without a paper the filter matches nothing (and isn't offered)")
        XCTAssertEqual(ids(ChatHistoryQuery.rows(fixture, paperTitles: titles, filter: .thisPaper, paperID: dpo, search: "réference", sort: .default)), [3])
        XCTAssertEqual(ChatHistoryFilter.thisPaper.title, "This paper")
        XCTAssertEqual(ChatHistoryFilter.allCases.map(\.title), ["All", "Paper chats", "General", "This paper"])
    }

    // MARK: Layout

    func testColumnsFollowTheWidth() {
        func columns(_ width: CGFloat, scale: CGFloat = 1) -> [ChatHistoryField] { ChatTableLayout.visible(width: width, scale: scale).map(\.field) }
        XCTAssertEqual(columns(390 - 32), [.lastUsed], "Phone portrait: the conversation and when it was last used")
        XCTAssertEqual(columns(440 - 32), [.lastUsed], "Pro Max portrait too; the paper is the row's second line")
        XCTAssertEqual(columns(874 - 124 - 32), [.paper, .messages, .started, .lastUsed], "Phone landscape: every column")
        XCTAssertEqual(columns(560), [.paper, .lastUsed], "A narrower sheet adds the paper first")
        XCTAssertEqual(columns(874 - 124 - 32, scale: 1.3), [.paper, .lastUsed], "Larger text needs more room per column")
        XCTAssertEqual(columns(0), [], "Before the first measurement, the conversation alone")
        XCTAssertEqual(ChatTableLayout.columns.last?.field, .lastUsed, "Last used is rightmost on every size")
    }

    // MARK: Ordering

    func testDefaultOrderIsMostRecentlyUsedWithUntimedHistoryLast() {
        XCTAssertEqual(query(), [1, 2, 3, 4, 6, 5], "Newest first; untimed conversations after, latest arrival first")
        XCTAssertEqual(query(sort: ChatHistorySort(field: .lastUsed, ascending: true)), [5, 6, 4, 3, 2, 1], "Reversed exactly")
    }

    func testHeaderTapsReverseOrStartInTheNaturalDirection() {
        let sort = ChatHistorySort.default
        XCTAssertEqual(sort.tapping(.lastUsed), ChatHistorySort(field: .lastUsed, ascending: true))
        XCTAssertEqual(sort.tapping(.messages), ChatHistorySort(field: .messages, ascending: false), "Counts start largest first")
        XCTAssertEqual(sort.tapping(.paper), ChatHistorySort(field: .paper, ascending: true), "Names start A–Z")
        XCTAssertEqual(sort.tapping(.conversation).tapping(.conversation), ChatHistorySort(field: .conversation, ascending: false))
    }

    func testOtherColumnsSortWithRecencyBreakingTies() {
        XCTAssertEqual(query(sort: ChatHistorySort(field: .messages, ascending: false)), [2, 1, 5, 3, 4, 6])
        XCTAssertEqual(query(sort: ChatHistorySort(field: .started, ascending: false)), [1, 2, 3, 4, 6, 5])
        // Papers A–Z, then a paper no longer in the library, then general chats (most recent first among equals).
        XCTAssertEqual(query(sort: ChatHistorySort(field: .paper, ascending: true)), [1, 3, 4, 2, 6, 5])
        XCTAssertEqual(query(sort: ChatHistorySort(field: .conversation, ascending: true)), [4, 2, 3, 6, 5, 1])
    }

    // MARK: Filter and search

    func testQuickFilterSeparatesPaperAndGeneralChats() {
        XCTAssertEqual(query(filter: .paper), [1, 3, 4])
        XCTAssertEqual(query(filter: .general), [2, 6, 5])
    }

    func testSearchMatchesQuestionsAndPaperTitlesIgnoringCaseAndAccents() {
        XCTAssertEqual(query(search: "dpo"), [2, 3])
        XCTAssertEqual(query(search: "attention"), [1], "The paper's title")
        XCTAssertEqual(query(search: "reference policy"), [3], "A follow-up question, every word, accents ignored")
        XCTAssertEqual(query(search: "dpo ipo"), [2])
        XCTAssertEqual(query(search: "general"), [2, 6, 5], "General chats by their kind")
        XCTAssertEqual(query(filter: .paper, search: "dpo"), [3])
        XCTAssertEqual(query(search: "transformer"), [])
    }

    // MARK: Labels

    func testLastUsedReadsAsRelativeTime() {
        func label(_ ago: TimeInterval) -> String { ChatHistoryFormat.lastUsed(now - ago, now: now, calendar: calendar) }
        XCTAssertEqual(label(20), "Just now")
        XCTAssertEqual(label(-30), "Just now", "A clock running ahead")
        XCTAssertEqual(label(5 * 60), "5 min ago")
        XCTAssertEqual(label(2 * 3_600 + 60), "2 h ago")
        XCTAssertEqual(label(9 * 3_600), "Yesterday", "Before midnight is yesterday, not 9 h ago")
        XCTAssertEqual(label(3 * 86_400), "Fri")
        XCTAssertEqual(label(20 * 86_400), "Sep 15")
        XCTAssertEqual(label(400 * 86_400), "Aug 2025")
        XCTAssertEqual(ChatHistoryFormat.lastUsed(nil, now: now, calendar: calendar), "—", "Not recorded (older history)")
        XCTAssertEqual(ChatHistoryFormat.started(now - 3_600, now: now, calendar: calendar), "Today")
        XCTAssertEqual(ChatHistoryFormat.spokenLastUsed(now - 2 * 3_600, now: now, calendar: calendar), "last used 2 hours ago")
        XCTAssertEqual(ChatHistoryFormat.spokenLastUsed(now - 86_400, now: now, calendar: calendar), "last used yesterday")
        XCTAssertNil(ChatHistoryFormat.spokenLastUsed(nil))
        XCTAssertEqual(ChatHistoryFormat.count(shown: 34, total: 34), "34 chats")
        XCTAssertEqual(ChatHistoryFormat.count(shown: 5, total: 34), "5 of 34 chats")
        XCTAssertEqual(ChatHistoryFormat.messages(1), "1 message")
    }

    func testRowsNameWhatTheyAreAbout() {
        let rows = ChatHistoryQuery.rows(fixture, paperTitles: titles, filter: .all, search: "", sort: .default)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { (Int($0.id.uuidString.suffix(12))!, $0) })
        XCTAssertEqual(byID[1]?.contextTitle, "Attention Is All You Need")
        XCTAssertEqual(byID[4]?.contextTitle, "Paper chat", "The paper is no longer in the library")
        XCTAssertEqual(byID[2]?.contextTitle, "General chat")
        let untitled = ChatHistoryRow(summary: summary(9, "  "), paperTitle: nil)
        XCTAssertEqual(untitled.title, "Untitled conversation")
    }

    // MARK: The model

    #if targetEnvironment(simulator)
    /// A saved question carries its time into All chats; deleting it is a durable, encrypted tombstone that survives
    /// reopening, and the visible chat moves to a new one.
    func testSavedQuestionIsListedWithItsTimeAndDeletionIsDurable() async throws {
        var model: ReaderModel? = ReaderModel(configuration: nil)
        try await model!.configureDurableDraftFixture(reset: true)
        model!.newChat(general: true)
        model!.chatInput = "How does attention scale with length?"
        let before = Date(timeIntervalSinceNow: -1)
        await model!.sendMessage()
        let saved = try XCTUnwrap(model!.conversationSummaries.first)
        XCTAssertEqual(model!.conversationSummaries.count, 1)
        XCTAssertEqual(saved.title, "How does attention scale with length?")
        XCTAssertNil(saved.documentID)
        XCTAssertEqual(saved.messageCount, 1)
        let lastUsed = try XCTUnwrap(saved.lastUsedAt)
        XCTAssertTrue(lastUsed >= before && lastUsed <= Date(timeIntervalSinceNow: 1))
        XCTAssertEqual(saved.startedAt, saved.lastUsedAt)
        XCTAssertEqual(model!.activeConversation, saved.id)

        XCTAssertTrue(model!.canDeleteConversations)
        await model!.deleteConversation(saved.id)
        XCTAssertTrue(model!.conversationSummaries.isEmpty)
        XCTAssertNil(model!.activeConversation, "The visible chat became a new chat")
        await model!.flushDrafts()
        model = nil

        let reopened = ReaderModel(configuration: nil)
        try await reopened.configureDurableDraftFixture(reset: false)
        XCTAssertTrue(reopened.conversationSummaries.isEmpty)
        XCTAssertTrue(reopened.privateState.isDeleted(saved.id))
    }

    func testSignedOutReaderCannotDelete() {
        XCTAssertFalse(ReaderModel(configuration: nil).canDeleteConversations)
    }
    #endif
}
