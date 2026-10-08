import Foundation
import ScienceReaderCore

// All chats as a table (owner request 2026-10-07: "a nice table … sort them based on last used"). Pure functions over
// the device's conversation summaries, so ordering, filtering and labels are tested without the UI. Everything is
// computed locally from decrypted history; nothing here leaves the device.

/// Which conversations show: the quick filter under the search field.
enum ChatHistoryFilter: String, CaseIterable, Identifiable, Sendable {
    /// `thisPaper`: the chats about the paper All chats was opened from (offered only then).
    case all, paper, general, thisPaper
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .paper: "Paper chats"
        case .general: "General"
        case .thisPaper: "This paper"
        }
    }
}

/// A sortable column.
enum ChatHistoryField: String, CaseIterable, Sendable {
    case conversation, paper, lastUsed, started, messages, kind, answerLength, topics

    var title: String {
        switch self {
        case .conversation: "Conversation"
        case .paper: "Paper"
        case .lastUsed: "Last used"
        case .started: "Started"
        case .messages: "Messages"
        case .kind: "Kind"
        case .answerLength: "Answer length"
        case .topics: "Topics"
        }
    }

    /// What the column chooser says about it.
    var explanation: String {
        switch self {
        case .conversation: "The chat’s title (its topic, or the first question)"
        case .paper: "The paper it is about, or General"
        case .lastUsed: "When you last asked or got an answer"
        case .started: "When the conversation began"
        case .messages: "Questions and answers"
        case .kind: "Paper chat or general chat"
        case .answerLength: "Words in the newest answer"
        case .topics: "The paper’s tags in your library"
        }
    }

    /// The first direction when a header is tapped: names A–Z (paper chats before general ones), times and counts
    /// newest/largest first.
    var ascendingFirst: Bool { self == .conversation || self == .paper || self == .kind || self == .topics }
}

struct ChatHistorySort: Equatable, Sendable {
    var field: ChatHistoryField
    var ascending: Bool

    static let `default` = ChatHistorySort(field: .lastUsed, ascending: false)

    /// A header tap: the current column reverses; another column starts in its natural direction.
    func tapping(_ field: ChatHistoryField) -> ChatHistorySort {
        field == self.field ? ChatHistorySort(field: field, ascending: !ascending) : ChatHistorySort(field: field, ascending: field.ascendingFirst)
    }
}

/// One table row: a conversation and the paper it is about.
struct ChatHistoryRow: Identifiable, Equatable, Sendable {
    let summary: ConversationSummary
    /// The paper's title when it is in the library; nil for a general chat or a paper no longer in the library.
    let paperTitle: String?
    let topics: [String]
    /// The title shown: a selection action's short form ("Explain · Attention(Q, K, V)…", `ChatTitle`) or the question.
    let title: String
    var id: UUID { summary.id }
    var isPaperChat: Bool { summary.documentID != nil }

    init(summary: ConversationSummary, paperTitle: String?, topics: [String] = []) {
        self.summary = summary; self.paperTitle = paperTitle; self.topics = topics
        let display = ChatTitle.display(summary)
        title = display.isEmpty ? "Untitled conversation" : display
    }

    /// "Attention Is All You Need", "Paper chat" (the paper isn't in the library) or "General chat".
    var contextTitle: String { paperTitle ?? (isPaperChat ? "Paper chat" : "General chat") }
}

enum ChatHistoryQuery {
    /// The rows to show: filtered by the quick filter and the search (every word must match the questions or the
    /// paper's title, ignoring case and accents), then sorted.
    static func rows(_ summaries: [ConversationSummary], paperTitles: [UUID: String], filter: ChatHistoryFilter,
                     paperID: UUID? = nil, search: String, sort: ChatHistorySort, paperTopics: [UUID: [String]] = [:]) -> [ChatHistoryRow] {
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        let rows = summaries.lazy
            .filter { summary in
                switch filter {
                case .all: true
                case .paper: summary.documentID != nil
                case .general: summary.documentID == nil
                case .thisPaper: paperID != nil && summary.documentID == paperID
                }
            }
            .map { ChatHistoryRow(summary: $0, paperTitle: $0.documentID.flatMap { paperTitles[$0] },
                                 topics: $0.documentID.flatMap { paperTopics[$0] } ?? []) }
            .filter { row in terms.allSatisfy { matches(row, $0) } }
        return sorted(Array(rows), by: sort)
    }

    static func matches(_ row: ChatHistoryRow, _ term: String) -> Bool {
        row.summary.title.localizedStandardContains(term) || row.title.localizedStandardContains(term)
            || row.summary.questions.localizedStandardContains(term) || row.contextTitle.localizedStandardContains(term)
            || row.topics.contains { $0.localizedStandardContains(term) }
    }

    /// A total order: the chosen column, then most recently used, then a stable identity.
    static func sorted(_ rows: [ChatHistoryRow], by sort: ChatHistorySort) -> [ChatHistoryRow] {
        rows.sorted { a, b in
            if sort.field == .topics, a.topics.isEmpty != b.topics.isEmpty { return !a.topics.isEmpty }
            let order = compare(a, b, sort.field)
            if order != .orderedSame { return sort.ascending ? order == .orderedAscending : order == .orderedDescending }
            let recency = compare(a, b, .lastUsed)
            if recency != .orderedSame { return recency == .orderedDescending }
            return a.id.wire < b.id.wire
        }
    }

    /// Ascending comparison of one column. Unknown times count as older than any recorded time (they predate
    /// recorded times), and among themselves follow this device's history order.
    static func compare(_ a: ChatHistoryRow, _ b: ChatHistoryRow, _ field: ChatHistoryField) -> ComparisonResult {
        switch field {
        case .conversation:
            return a.title.localizedStandardCompare(b.title)
        case .paper:
            // Papers by title, then paper chats whose paper isn't in the library, then general chats.
            let rank = { (row: ChatHistoryRow) in row.paperTitle != nil ? 0 : (row.isPaperChat ? 1 : 2) }
            if rank(a) != rank(b) { return rank(a) < rank(b) ? .orderedAscending : .orderedDescending }
            return a.contextTitle.localizedStandardCompare(b.contextTitle)
        case .lastUsed:
            return compareTimes(a.summary.lastUsedAt, a.summary.lastArrival, b.summary.lastUsedAt, b.summary.lastArrival)
        case .started:
            return compareTimes(a.summary.startedAt, a.summary.startArrival, b.summary.startedAt, b.summary.startArrival)
        case .messages:
            return a.summary.messageCount == b.summary.messageCount ? .orderedSame
                : (a.summary.messageCount < b.summary.messageCount ? .orderedAscending : .orderedDescending)
        case .kind:
            return a.isPaperChat == b.isPaperChat ? .orderedSame : (a.isPaperChat ? .orderedAscending : .orderedDescending)
        case .answerLength:
            let x = a.summary.latestAnswerWords, y = b.summary.latestAnswerWords
            return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        case .topics:
            return a.topics.joined(separator: ", ").localizedStandardCompare(b.topics.joined(separator: ", "))
        }
    }

    private static func compareTimes(_ a: Date?, _ aArrival: Int, _ b: Date?, _ bArrival: Int) -> ComparisonResult {
        switch (a, b) {
        case let (a?, b?) where a != b: return a < b ? .orderedAscending : .orderedDescending
        case (nil, _?): return .orderedAscending
        case (_?, nil): return .orderedDescending
        default: return aArrival == bArrival ? .orderedSame : (aArrival < bArrival ? .orderedAscending : .orderedDescending)
        }
    }
}

enum ChatHistoryFormat {
    /// "Just now", "5 min ago", "2 h ago" today; then as the Library's dates: "Yesterday", "Mon", "Oct 3", "Sep 2025".
    /// "—" when the time wasn't recorded (history saved before 2026-10-07).
    static func lastUsed(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "—" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }   // a clock running ahead counts as now
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3_600)) h ago" }
        return LibraryFormat.relativeDay(date, now: now, calendar: calendar)
    }

    /// Days only: "Today", "Yesterday", "Mon", "Oct 3", "Sep 2025"; "—" when unknown.
    static func started(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        date.map { LibraryFormat.relativeDay($0, now: now, calendar: calendar) } ?? "—"
    }

    /// For VoiceOver: "last used 2 hours ago", "last used yesterday", "last used Oct 3".
    static func spokenLastUsed(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "used just now" }
        if seconds < 3_600 { let minutes = Int(seconds / 60); return "last used \(minutes) minute\(minutes == 1 ? "" : "s") ago" }
        if calendar.isDate(date, inSameDayAs: now) { let hours = Int(seconds / 3_600); return "last used \(hours) hour\(hours == 1 ? "" : "s") ago" }
        return "last used " + LibraryFormat.relativeDayInSentence(date, now: now, calendar: calendar)
    }

    static func messages(_ count: Int) -> String { count == 1 ? "1 message" : "\(count) messages" }

    /// An answer's length: "320 words", "1.2k words"; "—" when nothing was answered.
    static func words(_ count: Int) -> String {
        switch count {
        case ..<1: "—"
        case 1: "1 word"
        case ..<1_000: "\(count) words"
        default: String(format: "%.1fk words", Double(count) / 1_000)
        }
    }

    /// The count beside the filter: "34 chats", or "5 of 34 chats" while filtering.
    static func count(shown: Int, total: Int) -> String {
        let noun = total == 1 ? "chat" : "chats"
        return shown == total ? "\(total) \(noun)" : "\(shown) of \(total) \(noun)"
    }
}
