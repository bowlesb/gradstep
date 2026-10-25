import Foundation

// Why For you suggests a paper, as the Feed presents it (owner, 2026-10-24: "Let's try having a column in Table for the
// reason and having grouped lists in list view"; docs/architecture/PERSONALIZED_FEED.md › Client presentation). Pure
// presentation over the server's ranked list: groups keep the server's order inside them. The List's group headings
// went after TestFlight 92 (owner: "Like papers you added not needed": each card already says why); its order stayed.

/// The groups reasons fall into, in the order the Feed lists them: the reader's tags, papers like theirs, their
/// authors, what is popular, a category, then something different.
public enum FeedWhyGroup: Int, CaseIterable, Comparable, Sendable {
    case tag, like, author, popular, category, explore, other

    public init(kind: String) {
        switch kind {
        case "tag": self = .tag
        case "added", "more_like": self = .like
        case "author": self = .author
        case "popular", "trending": self = .popular
        case "category": self = .category
        case "explore": self = .explore
        default: self = .other
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// An SF Symbol for the group (the Why column).
    public var symbol: String {
        switch self {
        case .tag: "tag"
        case .like: "books.vertical"
        case .author: "person"
        case .popular: "arrow.up.right"
        case .category: "square.grid.2x2"
        case .explore: "binoculars"
        case .other: "sparkles"
        }
    }
}

extension FeedReason {
    public var group: FeedWhyGroup { FeedWhyGroup(kind: kind) }

    /// The Why column's short label: "Your tag: RLHF", "Like: Muffin – A Shared Memory…", "Author: Tri Dao",
    /// "Popular: 48 upvotes", "Readers are adding", "New in Machine learning", "Explore". The full sentence is `text`.
    /// Owner, TestFlight 91: "Category: cs.LG" ("What does that even mean category CSLG?") and "Popular ▲ 232" made no
    /// sense, so a category is named as the List names it and popularity says it counts upvotes.
    public var shortLabel: String {
        switch kind {
        case "tag": return "Your tag: \(label)"
        case "added", "more_like": return "Like: \(FeedWhy.shortTitle(label, limit: 28))"
        case "author": return "Author: \(label)"
        // Upvotes on Hugging Face Papers (the server's "Popular on Hugging Face Papers"), the Upvotes column's ▲.
        case "trending": return Int(label).map { "Popular: \($0) \($0 == 1 ? "upvote" : "upvotes")" } ?? "Popular"
        // Added by several readers this week.
        case "popular": return "Readers are adding"
        case "category": return "New in \(FeedWhy.categoryName(self) ?? "a field you read")"
        case "explore": return "Explore"
        default: return text
        }
    }
}

public enum FeedWhy {
    /// A title shortened at a word to at most `limit` characters, with "…" (the server's `short`).
    public static func shortTitle(_ title: String, limit: Int) -> String {
        let clean = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard clean.count > limit else { return clean }
        let cut = String(clean.prefix(limit - 1))
        let space = cut.lastIndex(of: " ").map { cut.distance(from: cut.startIndex, to: $0) } ?? 0
        let keep = max(space, limit - 12)
        return String(cut.prefix(keep)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The order by why: the List's order, and the Table's Why sort. Rows grouped (each tag's papers together, the tags
    /// in the order the server ranked their first paper, then like papers, authors, popular, category, explore; no reason
    /// last), the server's order within each. Reversed, the groups reverse and rows without a reason stay last.
    public static func ordered(_ results: [DiscoveryResult], ascending: Bool = true) -> [DiscoveryResult] {
        var firstTag: [String: Int] = [:]
        for (index, result) in results.enumerated() where result.reason?.group == .tag {
            let key = result.reason!.label.lowercased()
            if firstTag[key] == nil { firstTag[key] = index }
        }
        func rank(_ result: DiscoveryResult) -> (Int, Int)? {
            guard let reason = result.reason else { return nil }
            return (reason.group.rawValue, reason.group == .tag ? firstTag[reason.label.lowercased()] ?? 0 : 0)
        }
        return results.enumerated().sorted { a, b in
            switch (rank(a.element), rank(b.element)) {
            case let (x?, y?) where x != y: return ascending ? x < y : x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// A category reason's field as readers know it: the server's own name ("New in Machine learning"), else the app's
    /// name for the arXiv code (`TagVocabulary`), else the code; nil when there is none.
    public static func categoryName(_ reason: FeedReason) -> String? {
        let prefix = "New in "
        if reason.text.hasPrefix(prefix) {
            let named = reason.text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if !named.isEmpty { return named }
        }
        let code = reason.label.trimmingCharacters(in: .whitespaces)
        if code.isEmpty { return nil }
        return TagVocabulary.name(forCategory: code) ?? code
    }

    /// The ⓘ beside the Table's Why header (owner, TestFlight 91: "If I click on why… maybe have like a little info icon
    /// that says what that even means… you press it and then it shows you a pop-up"): what each label means, and the
    /// Upvotes column's ▲.
    public static let info = """
        Why For you suggests each paper:
        • Your tag: it fits one of your tags.
        • Like: it is close to a paper you added.
        • Author: by an author you read.
        • Popular: upvoted on Hugging Face Papers. ▲ is the number of upvotes, also in the Upvotes column.
        • Readers are adding: several readers added it this week.
        • New in: new in an arXiv field you read.
        • Explore: now and then, something different.
        """

    /// Feed ⋯ › About For you: what each card's why line means, in the List's order. It replaces the ⓘs of the List's
    /// group headings, which went with them (owner, TestFlight 92: "Like papers you added not needed"; JUDGMENT_LOG 30).
    public static let aboutForYou = """
        For you suggests new papers from what you read, grouped by why, and says why under each:
        • In your tag: it fits one of your tags.
        • Like “…” or Because you added “…”: it is close to a paper you added. More like “…”: close to one you asked to \
        see more like.
        • By …: an author in your library, or of a paper you liked.
        • Popular on Hugging Face Papers: upvoted there (▲ is the number of upvotes). Added by several readers: this week.
        • New in …: new in an arXiv field you read.
        • Something different: now and then, from outside your fields, so the Feed doesn't narrow.
        """
}
