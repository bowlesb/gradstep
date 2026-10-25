import Foundation

// Your AI usage by range and by day (owner, TestFlight 92: "What's missing here is a view last day, last week, last month.
// We could have a pie chart, and lists in chronological order broken up"), and each row's way back to what it was for
// ("Don't see why we couldn't have a link here to the original resource in context?"). Pure: the screen is
// AIUsageView.swift; the server's window and pages are `v1_ai_usage` (migration 0144), unchanged.

/// The screen's one range control: it drives the totals line, the ring and the list.
public enum AIUsageRange: String, CaseIterable, Sendable, Hashable {
    case day, week, month, year

    /// The segment's word.
    public var title: String {
        switch self { case .day: "Day"; case .week: "Week"; case .month: "Month"; case .year: "Year" }
    }

    /// What the totals and the list cover.
    public var label: String {
        switch self { case .day: "Last 24 hours"; case .week: "Last 7 days"; case .month: "Last 30 days"; case .year: "Last 12 months" }
    }

    /// The server's window: whole UTC days, today included (`p_days`). The day asks for two, which always holds the last
    /// 24 hours wherever the reader is, and keeps those on this device (`AIUsageWindow`).
    public var serverDays: Int {
        switch self { case .day: 2; case .week: 7; case .month: 30; case .year: 365 }
    }

    /// The start of the day's own window (24 hours before `now`); nil when the server's window is the range.
    public func since(now: Date) -> Date? { self == .day ? now.addingTimeInterval(-86_400) : nil }
}

/// The last 24 hours, worked out on this device from the server's rows of its two-day window, as the server works out its
/// own windows: totals over the rows (the activity applied), and every activity in the window with its requests and
/// credits, most credits first (then most requests, then the activity's wire name), for the chips and the ring.
public struct AIUsageWindow: Equatable, Sendable {
    public let rows: [AIUsageOperation]
    public let totals: AIUsageTotals
    public let activities: [AIUsageActivityCount]

    /// `all`: every row of the server's window, any activity, newest first.
    public static func make(_ all: [AIUsageOperation], since: Date, activity: AIUsageActivity?) -> AIUsageWindow {
        let inWindow = all.filter { $0.createdAt >= since }
        let shown = inWindow.filter { activity == nil || $0.activity == activity }
        var counts: [AIUsageActivity: (Int64, Int64)] = [:]
        for op in inWindow {
            let now = counts[op.activity] ?? (0, 0)
            counts[op.activity] = (now.0 + 1, now.1 + (op.credits ?? 0))
        }
        let activities = counts.map { AIUsageActivityCount(activity: $0.key, operations: $0.value.0, credits: $0.value.1) }
            .sorted { (a: AIUsageActivityCount, b: AIUsageActivityCount) -> Bool in
                if a.credits != b.credits { return a.credits > b.credits }
                if a.operations != b.operations { return a.operations > b.operations }
                return a.activity.rawValue < b.activity.rawValue
            }
        func sum(_ value: (AIUsageOperation) -> Int64) -> Int64 { shown.reduce(0) { $0 + value($1) } }
        let totals = AIUsageTotals(operations: Int64(shown.count), credits: sum { $0.credits ?? 0 }, creditsHeld: sum(\.creditsHeld),
                                   inputTokens: sum(\.inputTokens), cachedTokens: sum(\.cachedTokens), cacheWriteTokens: sum(\.cacheWriteTokens),
                                   outputTokens: sum(\.outputTokens), searches: sum(\.searches), audioMs: sum(\.audioMs))
        return AIUsageWindow(rows: shown, totals: totals, activities: activities)
    }
}

/// One day of the list, newest first: "Today", "Yesterday", then the date.
public struct AIUsageSection: Equatable, Sendable, Identifiable {
    /// The day, `yyyy-MM-dd` in the reader's calendar.
    public let id: String
    public let title: String
    public let rows: [AIUsageOperation]
}

extension AIUsageFormat {
    /// The rows (newest first) as days in the reader's own calendar and time zone, newest first, each keeping the list's order.
    public static func sections(_ rows: [AIUsageOperation], now: Date = Date(), calendar: Calendar = .current) -> [AIUsageSection] {
        var out: [AIUsageSection] = [], current: [AIUsageOperation] = [], key: String?
        func flush() {
            if let key, let first = current.first { out.append(AIUsageSection(id: key, title: dayTitle(first.createdAt, now: now, calendar: calendar), rows: current)) }
            current = []
        }
        for op in rows {
            let parts = calendar.dateComponents([.year, .month, .day], from: op.createdAt)
            let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            if day != key { flush(); key = day }
            current.append(op)
        }
        flush()
        return out
    }

    /// A section's heading: "Today", "Yesterday", "Thursday, October 23", and the year when it isn't this one.
    public static func dayTitle(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.wide).month(.wide).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return date.formatted(style)
    }
}

// MARK: A row's way back (owner, TestFlight 92)

/// One message of the reader's own history, as the link back needs it: its conversation, that conversation's paper (its
/// library membership, or a legacy document), who wrote it and when (its author device's clock).
public struct AIUsageHistoryMessage: Equatable, Sendable {
    public let conversationID: UUID
    public let paper: UUID?
    public let fromReader: Bool
    public let at: Date
    public init(conversationID: UUID, paper: UUID?, fromReader: Bool, at: Date) {
        self.conversationID = conversationID; self.paper = paper; self.fromReader = fromReader; self.at = at
    }
}

extension AIUsageFormat {
    /// Activities whose answer is a turn of a conversation.
    public static let conversationActivities: Set<AIUsageActivity> = [.chat, .study, .relatedPapers, .whyItMatters, .addPaper]
    /// How far a message's time may be from its request's: device clocks and the server's differ by seconds; a question is
    /// written as it is sent and an answer as it ends (as the request is settled). Short, so another chat's messages a
    /// minute away are never taken for it.
    public static let historyTolerance: TimeInterval = 30

    /// The conversation a request answered: the one this device recorded when it asked, else (an older request, or one
    /// asked on another device; history syncs) the conversation with a message nearest the request — the reader's question
    /// as it was sent, or the answer as it was settled — within `historyTolerance`, preferring the paper (or no paper) the
    /// device recorded. Nil for other activities, the paper's AI Explainer, and when nothing is that close. `history` is
    /// sorted by time (`PrivateState.usageHistory`).
    public static func conversation(for op: AIUsageOperation, provenance: AIUsageProvenance?, history: [AIUsageHistoryMessage]) -> UUID? {
        guard conversationActivities.contains(op.activity), provenance?.action != ChatAction.paperExplainer.rawValue else { return nil }
        if let recorded = provenance?.conversationID { return recorded }
        let answered = op.settledAt ?? op.createdAt
        let earliest = min(op.createdAt, answered).addingTimeInterval(-historyTolerance), latest = max(op.createdAt, answered).addingTimeInterval(historyTolerance)
        var low = 0, high = history.count
        while low < high { let middle = (low + high) / 2; if history[middle].at < earliest { low = middle + 1 } else { high = middle } }
        var near: [(message: AIUsageHistoryMessage, distance: TimeInterval)] = []
        for message in history[low...] {
            if message.at > latest { break }
            let distance = message.fromReader ? abs(message.at.timeIntervalSince(op.createdAt)) : abs(message.at.timeIntervalSince(answered))
            if distance <= historyTolerance { near.append((message, distance)) }
        }
        guard !near.isEmpty else { return nil }
        let papers = Set([provenance?.membershipID.flatMap(UUID.init(uuidString:)), provenance?.documentID].compactMap { $0 })
        let preferred: [(message: AIUsageHistoryMessage, distance: TimeInterval)]
        switch provenance?.kind {
        case nil, .recommendation?: preferred = near
        case .general?: preferred = near.filter { $0.message.paper == nil }
        case .paper?, .explain?:
            let same = near.filter { $0.message.paper.map(papers.contains) == true }
            preferred = same.isEmpty ? near.filter { $0.message.paper != nil } : same
        }
        return preferred.min { $0.distance != $1.distance ? $0.distance < $1.distance : $0.message.conversationID.uuidString < $1.message.conversationID.uuidString }?
            .message.conversationID
    }

    /// For an explainer request this device recorded before it kept the item's id (or whose record is gone): the explanation
    /// kept here that it wrote — the same kind, saved as the request was settled. The paper's AI Explainer is metered as
    /// chat, so only a paper request with no conversation is matched to one.
    public static func explanation(for op: AIUsageOperation, provenance: AIUsageProvenance?, kept: [ExplanationSubject]) -> ExplanationSubject? {
        let actions: Set<String>
        switch op.activity {
        case .figureExplainer: actions = [ChatAction.figure.rawValue, ChatAction.figureSimpler.rawValue]
        case .equationExplainer: actions = [ChatAction.equation.rawValue, ChatAction.equationBackground.rawValue]
        case .chat where provenance?.kind == .paper && provenance?.conversationID == nil: actions = [ChatAction.paperExplainer.rawValue]
        default: return nil
        }
        let answered = op.settledAt ?? op.createdAt
        let from = op.createdAt.addingTimeInterval(-5), to = answered.addingTimeInterval(historyTolerance)
        return kept.filter { actions.contains($0.action) && $0.savedAt >= from && $0.savedAt <= to }
            .min { abs($0.savedAt.timeIntervalSince(answered)) < abs($1.savedAt.timeIntervalSince(answered)) }
    }
}

extension PrivateState {
    /// Every saved, undeleted conversation's timed messages, oldest first, for the link back (`AIUsageFormat.conversation`).
    /// Messages written before events carried times are left out.
    public func usageHistory() -> [AIUsageHistoryMessage] {
        let live = Dictionary(conversationSummaries().map { ($0.id, $0.documentID) }, uniquingKeysWith: { first, _ in first })
        var deleted = Set<UUID>()
        for event in events.values where event.payload.kind == .tombstone { deleted.insert(event.payload.entityID) }
        return events.values.compactMap { event -> AIUsageHistoryMessage? in
            let payload = event.payload
            guard payload.kind == .message, let conversation = payload.conversationID, let paper = live[conversation],
                  !deleted.contains(payload.entityID), let at = payload.createdDate else { return nil }
            return AIUsageHistoryMessage(conversationID: conversation, paper: paper, fromReader: payload.role == .user, at: at)
        }.sorted { $0.at < $1.at }
    }
}
