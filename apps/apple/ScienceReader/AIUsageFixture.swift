#if DEBUG && FIXTURE_HOST
import Foundation
import ScienceReaderCore

/// Your AI usage for UI journeys (`--chat-fixture`): the operations this device asked for (from its own usage record,
/// newest first, each a 3-credit Sonnet answer of the activity it recorded), then the shared fixture's kinds of rows (a
/// stopped answer, a failed equation explainer, a Study turn in progress, a podcast, free tags, a figure explainer, a
/// passage question with its parts) minutes ago, then thirty older answers an hour apart from two hours ago, so the list
/// pages and spans two days, and two from 4 and 12 days ago. The server's window (whole UTC days, today included) is
/// applied. `--usage-fixture-empty` has none; `--usage-fixture-fail-once` fails the first read. Never opens a network
/// connection.
extension ChatFixtureTransport: AIUsageSource {
    private static let failedOnce = FixtureFlag()

    func aiUsage(days: Int, activity: AIUsageActivity?, before: AIUsageCursor?, accountID: UUID) async throws -> AIUsagePage {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--usage-fixture-fail-once"), Self.failedOnce.take() { throw ChatTransportError.rejected("transport") }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let since = utc.date(byAdding: .day, value: -(days - 1), to: utc.startOfDay(for: Date()))!
        let all = (arguments.contains("--usage-fixture-empty") ? [] : Self.rows(asked: Self.asked(accountID: accountID)))
            .filter { row in (row["created_at"] as? String).flatMap(AIUsageFormat.date).map { $0 >= since } ?? true }
        let shown = all.filter { activity == nil || $0["activity"] as? String == activity?.rawValue }
        let start = before.flatMap { cursor in shown.firstIndex { $0["id"] as? String == cursor.id.uuidString.lowercased() }.map { $0 + 1 } } ?? 0
        let page = Array(shown.dropFirst(start).prefix(AIUsageFormat.pageSize)), more = shown.count > start + AIUsageFormat.pageSize
        func sum(_ rows: [[String: Any]], _ key: String) -> Int { rows.reduce(0) { $0 + (($1[key] as? Int) ?? 0) } }
        let keys = ["credits", "credits_held", "input_tokens", "cached_tokens", "cache_write_tokens", "output_tokens", "searches", "audio_ms"]
        var totals: [String: Any] = ["operations": shown.count]
        for key in keys { totals[key] = sum(shown, key) }
        var counts: [(String, Int, Int)] = []
        for name in Set(all.compactMap { $0["activity"] as? String }) {
            let rows = all.filter { $0["activity"] as? String == name }
            counts.append((name, rows.count, sum(rows, "credits")))
        }
        counts.sort { ($0.2, $0.1, $1.0) > ($1.2, $1.1, $0.0) }
        let body: [String: Any] = [
            "days": days, "activity": activity?.rawValue ?? NSNull(), "operations": page,
            "totals": start == 0 ? totals : NSNull(),
            "activities": start == 0 ? counts.map { ["activity": $0.0, "operations": $0.1, "credits": $0.2] } : NSNull(),
            "next": more ? ["created_at": page.last!["created_at"]!, "id": page.last!["id"]!] : NSNull(),
        ]
        try await Task.sleep(for: .milliseconds(150))
        return try AIUsagePage.decode(JSONSerialization.data(withJSONObject: body))
    }

    /// The cloud operations this device recorded for the account, whatever the fixture host's environment is called.
    private static func asked(accountID: UUID) -> [(UUID, AIUsageProvenance)] {
        let suffix = "." + accountID.uuidString.lowercased()
        let environments = UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("gradstep.usage-provenance.v1.") && $0.hasSuffix(suffix) }
            .map { String($0.dropFirst("gradstep.usage-provenance.v1.".count).dropLast(suffix.count)) }
        return environments.flatMap { AIUsageProvenanceStore(environment: $0, accountID: accountID).all().map { ($0.key, $0.value) } }
            .sorted { $0.0.uuidString < $1.0.uuidString }
    }

    private static func part(_ part: String, _ model: String, input: Int = 0, cached: Int = 0, write: Int = 0, output: Int = 0, searches: Int = 0,
                             audio: Int = 0, estimated: Bool = false, pending: Bool = false) -> [String: Any] {
        ["part": part, "model": model, "calls": 1, "input_tokens": input, "cached_tokens": cached, "cache_write_tokens": write, "output_tokens": output,
         "searches": searches, "audio_ms": audio, "estimated": estimated, "pending": pending]
    }

    private static func op(_ id: String, minutesAgo: Double, kind: String = "chat", activity: String, outcome: String = "completed", paidBy: String = "you",
                           credits: Int?, held: Int = 0, model: String, parts: [[String: Any]]) -> [String: Any] {
        let created = Date().addingTimeInterval(-minutesAgo * 60)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var row: [String: Any] = ["id": id, "created_at": iso.string(from: created), "settled_at": credits == nil ? NSNull() : iso.string(from: created.addingTimeInterval(12)),
            "kind": kind, "activity": activity, "action": NSNull(), "ending": NSNull(), "outcome": outcome, "paid_by": paidBy,
            "credits": credits.map { $0 as Any } ?? NSNull(), "credits_held": held, "model": model, "calls": parts.count,
            "estimated": parts.contains { $0["estimated"] as? Bool == true }, "pending": parts.contains { $0["pending"] as? Bool == true }, "parts": parts]
        for key in ["input_tokens", "cached_tokens", "cache_write_tokens", "output_tokens", "searches", "audio_ms"] {
            row[key] = parts.reduce(0) { $0 + (($1[key] as? Int) ?? 0) }
        }
        return row
    }

    /// The activity the server would name for what this device recorded.
    private static func activity(_ provenance: AIUsageProvenance) -> String {
        if provenance.kind == .recommendation { return "recommendations" }
        switch provenance.action.flatMap(ChatAction.init(rawValue:)) {
        case .figure?, .figureSimpler?: return "figure_explainer"
        case .equation?, .equationBackground?: return "equation_explainer"
        case .study?: return "study"
        case .related?: return "related_papers"
        case .relevance?: return "why_it_matters"
        default: return "chat"
        }
    }

    private static func rows(asked: [(UUID, AIUsageProvenance)]) -> [[String: Any]] {
        let sonnet = "anthropic/claude-sonnet-5.5", haiku = "anthropic/claude-haiku-5.5", p = "14400000-0000-4000-8001-"
        let mine = asked.map { id, provenance in
            op(id.uuidString.lowercased(), minutesAgo: 0, kind: provenance.kind == .recommendation ? "recommend" : "chat",
               activity: Self.activity(provenance), credits: 3, model: sonnet,
               parts: [part("answer", sonnet, input: 2_400, cached: 18_000, output: 420), part("title", haiku, input: 200, output: 9)])
        }
        let shared = [
            op(p + "00000000000b", minutesAgo: 1, activity: "chat", credits: 2, model: sonnet, parts: [part("answer", sonnet, input: 777, output: 77)]),
            op(p + "000000000007", minutesAgo: 2, kind: "metadata", activity: "tags", outcome: "free", paidBy: "gradstep", credits: 0, model: haiku,
               parts: [part("tags", haiku, input: 1_500, output: 60)]),
            op(p + "000000000006", minutesAgo: 3, kind: "podcast", activity: "podcast", credits: 55, model: sonnet,
               parts: [part("podcast_script", sonnet, input: 30_000, output: 5_000), part("podcast_review", sonnet, input: 8_000, output: 600),
                       part("podcast_audio", "gemini-3.8-flash-tts", input: 4_000, output: 60_000, audio: 300_000)]),
            op(p + "000000000005", minutesAgo: 4, activity: "study", outcome: "in_progress", credits: nil, held: 30, model: sonnet,
               parts: [part("answer", sonnet, pending: true)]),
            op(p + "000000000004", minutesAgo: 5, activity: "equation_explainer", outcome: "failed", credits: 0, model: "deepseek/deepseek-v4.1-flash-1017",
               parts: [part("answer", "deepseek/deepseek-v4.1-flash-1017")]),
            op(p + "000000000003", minutesAgo: 6, activity: "chat", outcome: "stopped", credits: 1, model: "gemini-3.8-flash",
               parts: [part("answer", "gemini-3.8-flash", input: 5_000, output: 300, estimated: true)]),
            op(p + "000000000002", minutesAgo: 7, activity: "figure_explainer", credits: 3, model: sonnet,
               parts: [part("answer", sonnet, input: 3_000, cached: 40_000, output: 1_200)]),
            op(p + "000000000001", minutesAgo: 8, activity: "chat", credits: 4, model: sonnet,
               parts: [part("answer", sonnet, input: 900, cached: 20_000, write: 100, output: 700), part("suggestions", haiku, input: 400, output: 40),
                       part("title", haiku, input: 200, output: 10), part("web_search", "search-basic", searches: 1)]),
        ]
        let older = (0..<30).map { n in
            op(String(format: "14400000-0000-4000-8003-%012d", n), minutesAgo: Double(120 + 60 * n), activity: "chat", credits: 2, model: sonnet,
               parts: [part("answer", sonnet, input: 1_200, cached: 15_000, output: 500)])
        } + [
            op("14400000-0000-4000-8004-000000000001", minutesAgo: 4 * 1_440, activity: "related_papers", credits: 4, model: sonnet,
               parts: [part("answer", sonnet, input: 2_000, cached: 18_000, output: 900), part("web_search", "search-basic", searches: 2)]),
            op("14400000-0000-4000-8004-000000000002", minutesAgo: 12 * 1_440, activity: "why_it_matters", credits: 2, model: sonnet,
               parts: [part("answer", sonnet, input: 1_500, cached: 16_000, output: 400)]),
        ]
        // This device's own questions are the newest: shown first.
        return mine.map { var row = $0; row["created_at"] = ISO8601DateFormatter().string(from: Date()); return row } + shared + older
    }
}

/// A one-time switch shared across the fixture transport's copies.
final class FixtureFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var spent = false
    /// True the first time only.
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if spent { return false }; spent = true; return true }
}
#endif
