import Foundation

/// This month's free AI as `v1_credit_balance` reports it (`free`, migration 0150; docs/PRICING_HOW_IT_WORKS.md): null
/// for accounts not on the free tier. The top-level `available` already leaves out free credits that cannot pay now.
public struct FreeAI: Decodable, Equatable, Sendable {
    /// Why free AI cannot pay right now. Unknown server values decode as nil (shown as the generic credits message).
    public enum Reason: String, Sendable { case used, daily, account, pool, paused }

    public let monthly: Int64
    public let available: Int64
    public let usable: Bool
    public let reason: Reason?
    public let resumesAt: Date?
    public let daily: Int64?

    public init(monthly: Int64, available: Int64, usable: Bool, reason: Reason? = nil, resumesAt: Date? = nil, daily: Int64? = 20) {
        self.monthly = monthly; self.available = available; self.usable = usable; self.reason = reason
        self.resumesAt = resumesAt; self.daily = daily
    }

    enum CodingKeys: String, CodingKey { case monthly, available, usable, reason, resumesAt = "resumes_at", daily }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        monthly = try c.decode(Int64.self, forKey: .monthly)
        available = try c.decode(Int64.self, forKey: .available)
        usable = try c.decode(Bool.self, forKey: .usable)
        reason = try c.decodeIfPresent(String.self, forKey: .reason).flatMap(Reason.init(rawValue:))
        daily = try c.decodeIfPresent(Int64.self, forKey: .daily)
        // Postgres timestamps may carry fractional seconds; whole seconds are enough here.
        resumesAt = try c.decodeIfPresent(String.self, forKey: .resumesAt).flatMap { value in
            ISO8601DateFormatter().date(from: value.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
        }
    }
}

/// The reader-facing wording for free AI (same text on the browser; docs/PRICING_HOW_IT_WORKS.md).
public enum FreeAIText {
    /// Settings › AI credits › Plan ⓘ: how pricing works, readable in about 20 seconds.
    public static let planInfo = "Reading papers is always free. AI uses credits.\n\nFree: 50 credits a month (about 15 answers) with the fast models, while this month’s free AI lasts.\nPlus: 600 credits a month (about 200 answers), every model.\nPro: 2,000 credits a month (about 650 answers), every model.\nCredit packs: 300 or 700 credits that never expire.\n\nPlan credits renew each month and don’t carry over. Prices are shown in Get credits."

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = format
        return f
    }
    /// "November 1" (UTC: free AI comes back at 00:00 UTC on the 1st).
    public static func day(_ date: Date) -> String { formatter("MMMM d").string(from: date) }
    /// "Nov 1", for the Settings row.
    public static func shortDay(_ date: Date) -> String { formatter("MMM d").string(from: date) }

    /// The message for a refused request (`insufficient_credits`) when free AI explains it; nil keeps the generic message.
    public static func message(reason: FreeAI.Reason?, resumesAt: Date?, premiumModel: Bool) -> String? {
        let back = resumesAt.map { "It comes back on \(day($0))." } ?? "It comes back at the start of next month."
        switch reason {
        case .pool: return "This month’s free AI has all been used. \(back) Reading is unaffected, and a plan or credit pack works right away."
        case .used, .account: return "You’ve used this month’s free AI. \(back) Reading is unaffected, and a plan or credit pack works right away."
        case .daily: return "You’ve used today’s free AI. More tomorrow, or a plan or credit pack works right away."
        case .paused: return "Free AI is paused for now. Reading is unaffected, and a plan or credit pack works right away."
        case nil: return premiumModel ? premium : nil
        }
    }
    public static let premium = "Free AI covers the fast models (Gemini Flash, DeepSeek and Haiku). Choose one in AI options, or get credits for Sonnet and Opus."

    /// From the balance: a usable allowance explains only a premium model; an unusable one its reason (unknown → generic).
    public static func message(for free: FreeAI?, premiumModel: Bool) -> String? {
        guard let free else { return nil }
        if free.usable { return premiumModel ? premium : nil }
        guard let reason = free.reason else { return nil }
        return message(reason: reason, resumesAt: free.resumesAt, premiumModel: premiumModel)
    }

    /// Settings › "Free AI this month".
    public static func settingsValue(_ free: FreeAI) -> String {
        if free.usable { return "\(free.available.formatted()) of \(free.monthly.formatted()) left" }
        switch free.reason {
        case .pool, .used, .account: return free.resumesAt.map { "Used up · back \(shortDay($0))" } ?? "Used up"
        case .daily: return "Back tomorrow"
        case .paused: return "Paused"
        case nil: return "Unavailable"
        }
    }
}
