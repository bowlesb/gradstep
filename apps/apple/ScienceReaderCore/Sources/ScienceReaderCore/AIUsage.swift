import Foundation

// Your AI usage (owner, 2026-10-22: "a table of my recent AI token spend for all the different activities … rows ordered
// by time, each row being an activity, and the exact cost"). The reader's own metered operations from `v1_ai_usage`
// (migration 0144), newest first, in credits — the product's unit; Gradstep shows no credit-to-dollar conversion
// (docs/architecture/OPERATIONS_AND_BILLING.md "Your AI usage"). The words match the browser's lib/ai-usage.ts exactly
// (tests/fixtures/ai-usage.json, AIUsageTests).
//
// Paper titles never come from the server. When this device starts an answer it remembers, on this device only, the
// conversation kind and the paper's library identity (`AIUsageProvenanceStore`); the usage screen looks the title up in the
// library here. An operation started on another device shows its activity without a paper.

public enum AIUsageActivity: String, CaseIterable, Sendable, Hashable {
    case chat, figureExplainer = "figure_explainer", equationExplainer = "equation_explainer", study, relatedPapers = "related_papers"
    case whyItMatters = "why_it_matters", addPaper = "add_paper", diagramRepair = "diagram_repair", podcast, recommendations, tags
    case paperLookup = "paper_lookup", webSearch = "web_search", paperOCR = "paper_ocr", diagram, other

    /// The filter chip's name (chat is one chip: paper, general and passage questions alike).
    public var name: String {
        switch self {
        case .chat: "Chat"
        case .figureExplainer: "Figure explainer"
        case .equationExplainer: "Equation explainer"
        case .study: "Study"
        case .relatedPapers: "Related papers"
        case .whyItMatters: "Why it matters"
        case .addPaper: "Add paper"
        case .diagramRepair: "Diagram repair"
        case .podcast: "Podcast"
        case .recommendations: "Recommendations"
        case .tags: "Tags"
        case .paperLookup: "Paper lookup"
        case .webSearch: "Web search"
        case .paperOCR: "PDF conversion"
        case .diagram: "Diagram"
        case .other: "Other"
        }
    }
}

extension AIUsageActivity: Decodable {
    /// A newer server's activity this build doesn't know is shown as Other, not refused.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AIUsageActivity(rawValue: raw) ?? .other
    }
}

public enum AIUsageOutcome: String, Decodable, Sendable {
    case completed, stopped, failed, inProgress = "in_progress", checking, free, notCharged = "not_charged"

    /// A short word beside the credits when the row isn't an ordinary finished charge.
    public var label: String? {
        switch self {
        case .completed: nil
        case .stopped: "Stopped"
        case .failed: "Didn’t finish · not charged"
        case .inProgress: "In progress"
        case .checking: "Being checked"
        case .free: nil // the cost already says Free
        case .notCharged: "Not charged"
        }
    }
    public var isProblem: Bool { self == .failed || self == .checking }
    /// Whether the row's tokens are what the provider reported for a finished request. A request that didn't finish, wasn't
    /// charged, or hasn't been settled carries what was set aside for it (its input estimated from its size, its whole
    /// output allowance), not what was used (TestFlight 92: a failed question read "132k in · 10k out"); those aren't shown.
    public var reportsTokens: Bool { !(self == .failed || self == .notCharged || self == .inProgress || self == .checking) }
    /// Said where the parts' tokens would be, when they aren't shown.
    public var unreportedTokens: String? {
        switch self {
        case .failed, .notCharged: "Its tokens aren’t shown: what was set aside for it isn’t what was used."
        case .inProgress, .checking: "Its tokens are shown once it’s settled."
        default: nil
        }
    }
}

public enum AIUsagePartName: String, Sendable {
    case answer, title, suggestions, studyMap = "study_map", webSearch = "web_search", podcastScript = "podcast_script"
    case podcastReview = "podcast_review", podcastAudio = "podcast_audio", tags, ocr

    public var label: String {
        switch self {
        case .answer: "Answer"
        case .title: "Chat title"
        case .suggestions: "Suggested questions"
        case .studyMap: "Study map"
        case .webSearch: "Web search"
        case .podcastScript: "Script"
        case .podcastReview: "Script check"
        case .podcastAudio: "Audio"
        case .tags: "Tags"
        case .ocr: "PDF conversion"
        }
    }
}

extension AIUsagePartName: Decodable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AIUsagePartName(rawValue: raw) ?? .answer
    }
}

/// Token counts as the provider reported them (cache writes are input kept for the next question).
public protocol AIUsageTokens {
    var inputTokens: Int64 { get }
    var cachedTokens: Int64 { get }
    var cacheWriteTokens: Int64 { get }
    var outputTokens: Int64 { get }
    var searches: Int64 { get }
    var audioMs: Int64 { get }
}

public struct AIUsagePart: Decodable, Equatable, Sendable, AIUsageTokens {
    public let part: AIUsagePartName
    public let model: String
    public let calls: Int64
    public let inputTokens, cachedTokens, cacheWriteTokens, outputTokens, searches, audioMs: Int64
    public let estimated: Bool
    public let pending: Bool

    enum CodingKeys: String, CodingKey {
        case part, model, calls, estimated, pending
        case inputTokens = "input_tokens", cachedTokens = "cached_tokens", cacheWriteTokens = "cache_write_tokens", outputTokens = "output_tokens"
        case searches, audioMs = "audio_ms"
    }
}

public struct AIUsageOperation: Decodable, Equatable, Sendable, Identifiable, AIUsageTokens {
    public let id: UUID
    public let createdAt: Date
    public let settledAt: Date?
    public let kind: String
    public let activity: AIUsageActivity
    public let action: String?
    public let ending: String?
    public let outcome: AIUsageOutcome
    /// "you", or "gradstep" for work Gradstep paid for (tags on a paper you added).
    public let paidBy: String
    /// Charged, once settled; nil while it runs.
    public let credits: Int64?
    /// The hold while it runs.
    public let creditsHeld: Int64
    public let model: String?
    public let calls: Int64
    public let inputTokens, cachedTokens, cacheWriteTokens, outputTokens, searches, audioMs: Int64
    public let estimated: Bool
    public let pending: Bool
    public let parts: [AIUsagePart]

    enum CodingKeys: String, CodingKey {
        case id, kind, activity, action, ending, outcome, credits, model, calls, estimated, pending, parts, searches
        case createdAt = "created_at", settledAt = "settled_at", paidBy = "paid_by", creditsHeld = "credits_held"
        case inputTokens = "input_tokens", cachedTokens = "cached_tokens", cacheWriteTokens = "cache_write_tokens", outputTokens = "output_tokens"
        case audioMs = "audio_ms"
    }
}

public struct AIUsageTotals: Decodable, Equatable, Sendable, AIUsageTokens {
    public let operations: Int64
    public let credits: Int64
    public let creditsHeld: Int64
    public let inputTokens, cachedTokens, cacheWriteTokens, outputTokens, searches, audioMs: Int64

    enum CodingKeys: String, CodingKey {
        case operations, credits, searches
        case creditsHeld = "credits_held"
        case inputTokens = "input_tokens", cachedTokens = "cached_tokens", cacheWriteTokens = "cache_write_tokens", outputTokens = "output_tokens"
        case audioMs = "audio_ms"
    }
}

public struct AIUsageActivityCount: Decodable, Equatable, Sendable {
    public let activity: AIUsageActivity
    public let operations: Int64
    public let credits: Int64
}

/// One ring segment and legend row: a named activity, or Other (everything small or past the fourth). `slot` is the
/// colour's place in the chart palette (0–3 by size; nil is Other's neutral): neighbours on the ring are always adjacent
/// slots, the order the palette is validated for (docs/DESIGN.md "Credits by activity").
public struct AIUsageSlice: Equatable, Sendable, Identifiable {
    public let activity: AIUsageActivity?
    public let label: String
    public let credits: Int64
    public let percent: String
    public let slot: Int?
    public let members: [String]
    public var id: String { label }
}

public struct AIUsageCursor: Codable, Equatable, Sendable {
    /// Exactly as the server sent it (microseconds), so the next page starts after this row.
    public let createdAt: String
    public let id: UUID
    enum CodingKeys: String, CodingKey { case createdAt = "created_at", id }
}

public struct AIUsagePage: Decodable, Equatable, Sendable {
    public let days: Int
    public let activity: AIUsageActivity?
    public let operations: [AIUsageOperation]
    /// The whole window (with the activity filter): first page only.
    public let totals: AIUsageTotals?
    /// Every activity in the window (no filter), for the chips: first page only.
    public let activities: [AIUsageActivityCount]?
    public let next: AIUsageCursor?

    /// The server's JSON, with its timestamps (microseconds, `+00:00`).
    public static func decode(_ data: Data) throws -> AIUsagePage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = AIUsageFormat.date(text) else {
                throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "timestamp")
            }
            return date
        }
        let page = try decoder.decode(AIUsagePage.self, from: data)
        guard page.operations.count <= 50, page.operations.allSatisfy({ $0.parts.count <= 32 && $0.creditsHeld >= 0 && ($0.credits ?? 0) >= 0 })
        else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bounds")) }
        return page
    }
}

/// What this device knew when it started an answer: the conversation kind and the paper's library identity, never its title;
/// and, for the row's link back (owner, TestFlight 92: "a link here to the original resource in context"), the conversation
/// the answer went into, or the explainer's subject (the paper revision's bundle and the equation's or figure's id in it),
/// or a recommendation's catalog and the library entries it added. Ids only; older entries decode without them.
public struct AIUsageProvenance: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case paper, general, explain, recommendation }
    public let kind: Kind
    /// The library membership (import) the local paper context named; a recommendation's seed paper.
    public let membershipID: String?
    /// The paper's document, for a server-side paper.
    public let documentID: UUID?
    /// The conversation the answer went into (chat, Explain in Chat, Study, Related papers, Why it matters, Add paper).
    public var conversationID: UUID?
    /// The chat action (`figure`, `equation`, `paper_explainer`, …) and the item it explains: the equation's or figure's id
    /// in the paper's bundle, "paper" for the paper's AI Explainer.
    public var action: String?
    public var itemID: String?
    /// Recommendations: the catalog the papers were filed in, and the library entries (memberships) added.
    public var catalogID: UUID?
    public var added: [String]?

    public init(kind: Kind, membershipID: String? = nil, documentID: UUID? = nil, conversationID: UUID? = nil, action: String? = nil,
                itemID: String? = nil, catalogID: UUID? = nil, added: [String]? = nil) {
        self.kind = kind; self.membershipID = membershipID; self.documentID = documentID; self.conversationID = conversationID
        self.action = action; self.itemID = itemID; self.catalogID = catalogID; self.added = added
    }

    /// A question started from a passage (Explain in Chat and the other selection questions) is "explain"; the selection
    /// actions with their own activity (Why it matters, Related papers, Study, the explainers) keep "paper".
    public init(_ request: ChatGenerationRequest) {
        let paper = request.documentID != nil || request.localContext != nil
        kind = !paper ? .general : (request.selection != nil && request.action == nil ? .explain : .paper)
        membershipID = request.localContext?.membershipID
        documentID = request.documentID
        conversationID = request.usageConversationID
        action = request.action?.rawValue
        itemID = request.usageItemID
        catalogID = nil; added = nil
    }
}

/// The remembered operations of one account on this device, newest kept (bounded); a per-device convenience in
/// UserDefaults, never synced. Holds operation ids, the kind and the library's own ids only.
public struct AIUsageProvenanceStore: Sendable {
    public static let limit = 2_000
    let key: String
    let limit: Int
    let defaults: @Sendable () -> UserDefaults

    public init(environment: String, accountID: UUID, limit: Int = Self.limit, defaults: @escaping @Sendable () -> UserDefaults = { .standard }) {
        key = "gradstep.usage-provenance.v1.\(environment).\(accountID.uuidString.lowercased())"
        self.limit = limit; self.defaults = defaults
    }

    private struct Entry: Codable { let id: UUID; let p: AIUsageProvenance }

    public func all() -> [UUID: AIUsageProvenance] {
        guard let data = defaults().data(forKey: key), let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.id, $0.p) }, uniquingKeysWith: { _, last in last })
    }

    public func remember(_ operationID: UUID, _ provenance: AIUsageProvenance) {
        var list = (defaults().data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }) ?? []
        list.removeAll { $0.id == operationID }
        list.append(Entry(id: operationID, p: provenance))
        if list.count > limit { list.removeFirst(list.count - limit) }
        if let data = try? JSONEncoder().encode(list) { defaults().set(data, forKey: key) }
    }

    public func forget() { defaults().removeObject(forKey: key) }
}

/// The words (the same in the browser's lib/ai-usage.ts; tests/fixtures/ai-usage.json).
public enum AIUsageFormat {
    public static let periods = [7, 30, 90, 365]
    public static let pageSize = 25

    /// The row's activity: chat is named for what this device knew when it started it.
    public static func activityLabel(_ activity: AIUsageActivity, provenance: AIUsageProvenance?) -> String {
        guard activity == .chat, let provenance else { return activity.name }
        // The paper's AI Explainer is metered as chat (it is a chat action without a conversation).
        if provenance.action == ChatAction.paperExplainer.rawValue { return "AI Explainer" }
        switch provenance.kind {
        case .explain: return "Explain in Chat"
        case .paper: return "Paper chat"
        case .general: return "General chat"
        case .recommendation: return activity.name
        }
    }

    /// Whole numbers with thousands separators, the same on every device (the fixture is exact).
    public static func grouped(_ n: Int64) -> String {
        let digits = String(abs(n))
        var out = ""
        for (index, character) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return n < 0 ? "-" + out : out
    }

    /// The row's cost, exactly: credits charged, the hold while it runs, or Free.
    public static func creditsText(outcome: AIUsageOutcome, credits: Int64?, held: Int64) -> String {
        switch outcome {
        case .inProgress, .checking: return "Up to \(grouped(held))"
        case .free: return "Free"
        default:
            let n = credits ?? 0
            return "\(grouped(n)) \(n == 1 ? "credit" : "credits")"
        }
    }
    public static func creditsText(_ op: AIUsageOperation) -> String { creditsText(outcome: op.outcome, credits: op.credits, held: op.creditsHeld) }

    // MARK: Credits by activity (owner, build 82: "a pie chart summarizing the cost types and their cost")

    /// At most four named segments, each at least 4% of the period's credits; the rest is one Other.
    public static let sliceNamed = 4, sliceMinShare = 0.04

    /// The ring for the All view, or [] when there is nothing to compare (no credits, or one activity holds them all).
    public static func slices(_ activities: [AIUsageActivityCount]) -> [AIUsageSlice] {
        let charged = activities.filter { $0.credits > 0 }.sorted {
            $0.credits != $1.credits ? $0.credits > $1.credits : $0.activity.name.localizedCaseInsensitiveCompare($1.activity.name) == .orderedAscending
        }
        let total = charged.reduce(Int64(0)) { $0 + $1.credits }
        guard total > 0, charged.count >= 2 else { return [] }
        var named: [AIUsageActivityCount] = [], rest: [AIUsageActivityCount] = []
        for (index, item) in charged.enumerated() {
            if index < sliceNamed, Double(item.credits) >= Double(total) * sliceMinShare, item.activity != .other { named.append(item) } else { rest.append(item) }
        }
        var out = named.enumerated().map { index, item in
            AIUsageSlice(activity: item.activity, label: item.activity.name, credits: item.credits, percent: percentText(item.credits, of: total),
                         slot: index, members: [])
        }
        if !rest.isEmpty {
            let credits = rest.reduce(Int64(0)) { $0 + $1.credits }
            out.append(AIUsageSlice(activity: nil, label: "Other", credits: credits, percent: percentText(credits, of: total), slot: nil,
                                    members: rest.filter { $0.activity != .other }.map(\.activity.name)))
        }
        return out.count < 2 ? [] : out
    }

    /// A share in whole percent, half up ("<1%" for a sliver, ">99%" beside one), integer arithmetic so every device
    /// writes the same.
    public static func percentText(_ part: Int64, of total: Int64) -> String {
        let n = (part * 200 + total) / (total * 2)
        return n < 1 ? "<1%" : n >= 100 && part < total ? ">99%" : "\(n)%"
    }

    /// The chart in words (its accessibility label): "Credits by activity: Podcast 55 credits, 85%; Chat 7 credits, 11%; …".
    public static func slicesSummary(_ slices: [AIUsageSlice]) -> String {
        "Credits by activity: " + slices.map { s in
            "\(s.label) \(grouped(s.credits)) \(s.credits == 1 ? "credit" : "credits"), \(s.percent)"
                + (s.members.isEmpty ? "" : " (\(s.members.joined(separator: ", ")))")
        }.joined(separator: "; ")
    }

    /// 950 → "950", 1,500 → "1.5k", 20,000 → "20k", 1,250,000 → "1.3M" (JavaScript's Math.round: halves up).
    public static func compact(_ n: Int64) -> String {
        if n < 1_000 { return String(n) }
        let (value, unit): (Double, String) = n < 999_500 ? (Double(n) / 1_000, "k") : (Double(n) / 1_000_000, "M")
        if value < 10 {
            let tenths = (value * 10 + 0.5).rounded(.down) / 10
            return tenths == tenths.rounded(.down) ? "\(Int(tenths))\(unit)" : "\(tenths)\(unit)"
        }
        return "\(Int((value + 0.5).rounded(.down)))\(unit)"
    }

    public static func audioText(_ ms: Int64) -> String {
        let seconds = Int64((Double(ms) / 1000 + 0.5).rounded(.down))
        return seconds < 60 ? "\(seconds) s audio" : "\(Int64((Double(seconds) / 60 + 0.5).rounded(.down))) min audio"
    }

    /// Tokens used, short ("1.6k in · 20k cached · 750 out · 1 search · 5 min audio") or exact; "≈" when Gradstep's
    /// estimate stands in for an unreported usage; "—" when nothing has been reported yet.
    public static func tokensText(_ t: some AIUsageTokens, estimated: Bool, exact: Bool = false) -> String {
        let number: (Int64) -> String = { exact ? grouped($0) : compact($0) }
        var pieces: [String] = []
        let input = t.inputTokens + t.cacheWriteTokens
        if input != 0 || t.outputTokens != 0 || t.cachedTokens != 0 {
            pieces.append("\(number(input)) in")
            if t.cachedTokens != 0 { pieces.append("\(number(t.cachedTokens)) cached") }
            pieces.append("\(number(t.outputTokens)) out")
        }
        if t.searches != 0 { pieces.append("\(grouped(t.searches)) \(t.searches == 1 ? "search" : "searches")") }
        if t.audioMs != 0 { pieces.append(audioText(t.audioMs)) }
        guard !pieces.isEmpty else { return "—" }
        return (estimated ? "≈ " : "") + pieces.joined(separator: " · ")
    }

    private static let modelWords: [String: String] = [
        "claude": "Claude", "sonnet": "Sonnet", "haiku": "Haiku", "opus": "Opus", "gemini": "Gemini", "flash": "Flash", "pro": "Pro", "lite": "Lite",
        "deepseek": "DeepSeek", "tts": "TTS", "gpt": "GPT", "mini": "mini", "chat": "Chat",
    ]
    /// A model as readers know it: "anthropic/claude-sonnet-5.5" → "Claude Sonnet 5.5", "search-basic" → "Tavily search".
    public static func modelLabel(_ model: String?) -> String {
        guard let model, !model.isEmpty else { return "—" }
        if model.hasPrefix("search-") { return "Tavily search" }
        let name = model.split(separator: "/").last.map(String.init) ?? model
        let words = name.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
            .filter { !($0.count == 4 && $0.allSatisfy(\.isNumber)) }
        var out: [String] = []
        let isVersion = { (w: String) in !w.isEmpty && w.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) } }
        for word in words {
            if word.allSatisfy(\.isNumber), let last = out.last, isVersion(last) { out[out.count - 1] = "\(last).\(word)"; continue }
            if let known = modelWords[word.lowercased()] { out.append(known) }
            else if let first = word.first, first == "v" || first == "V", word.dropFirst().first?.isNumber == true { out.append(word.uppercased()) }
            else if word.first?.isNumber == true { out.append(word) }
            else { out.append(word.prefix(1).uppercased() + word.dropFirst()) }
        }
        return out.isEmpty ? model : out.joined(separator: " ")
    }

    public static func periodLabel(_ days: Int) -> String { days == 365 ? "Last 12 months" : "Last \(days) days" }

    /// Totals for the period: "63 credits · 8 requests · 186k tokens · 30 held".
    public static func totalsText(_ t: AIUsageTotals) -> String {
        let used = t.inputTokens + t.cacheWriteTokens + t.cachedTokens + t.outputTokens
        var pieces = ["\(grouped(t.credits)) \(t.credits == 1 ? "credit" : "credits")", "\(grouped(t.operations)) \(t.operations == 1 ? "request" : "requests")"]
        if used != 0 { pieces.append("\(compact(used)) tokens") }
        if t.creditsHeld != 0 { pieces.append("\(grouped(t.creditsHeld)) held") }
        return pieces.joined(separator: " · ")
    }

    /// The ⓘ beside the totals: what affects cost (the same words in the browser).
    public static let info = "What a request costs depends on how much the model reads and writes. A paper chat sends the paper with each question; "
        + "questions soon after reuse a cached copy, which costs much less. Longer conversations, longer answers, higher effort and larger models cost "
        + "more; web searches, the chat’s title and its suggested questions are small extra calls inside the same request. Credits are settled from the "
        + "tokens the provider reports: a stopped answer is charged for the part written, and one that fails isn’t charged. Paper titles come from "
        + "this device’s library and never leave it."

    /// The server's timestamps: ISO 8601 with or without fractional seconds.
    public static func date(_ text: String) -> Date? {
        // PostgreSQL sends microseconds; the formatter reads milliseconds.
        let text = text.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
