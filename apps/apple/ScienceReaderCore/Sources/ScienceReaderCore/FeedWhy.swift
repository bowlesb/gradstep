import Foundation

// Why For you suggests a paper, as the Feed presents it (owner, 2026-10-24: "Let's try having a column in Table for the
// reason and having grouped lists in list view"; docs/architecture/PERSONALIZED_FEED.md › Client presentation). Pure
// presentation over the server's ranked list: groups keep the server's order inside them.

/// The groups reasons fall into, in the order the Feed shows them: the reader's tags, papers like theirs, their
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

    /// The List's section header (a tag's section is named after the tag instead).
    public var title: String {
        switch self {
        case .tag: "Your tags"
        case .like: "Like papers you added"
        case .author: "From authors you read"
        case .popular: "Popular this week"
        case .category: "By category"
        case .explore: "Something different"
        case .other: "More for you"
        }
    }

    /// An SF Symbol for the group (the Why column and the List's headers).
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
    /// "Popular ▲ 48", "Readers are adding", "Category: cs.CL", "Explore". The full sentence is `text`.
    public var shortLabel: String {
        switch kind {
        case "tag": return "Your tag: \(label)"
        case "added", "more_like": return "Like: \(FeedWhy.shortTitle(label, limit: 28))"
        case "author": return "Author: \(label)"
        // Upvotes on Hugging Face Papers (the server's "Popular on Hugging Face Papers"), in the Popularity column's ▲.
        case "trending": return Int(label).map { "Popular ▲ \($0)" } ?? "Popular"
        // Added by several readers this week.
        case "popular": return "Readers are adding"
        case "category": return label.isEmpty ? "Category" : "Category: \(label)"
        case "explore": return "Explore"
        default: return text
        }
    }
}

/// One section of the Feed's List: a tag (named after it), several tags with one paper each ("Your tags"), or a group.
public struct FeedSection: Identifiable, Equatable, Sendable {
    public let group: FeedWhyGroup
    /// The tag a tag section stands for; nil for the merged "Your tags" and every other group.
    public let tag: String?
    public let results: [DiscoveryResult]

    public var id: String { tag.map { "tag.\($0.lowercased())" } ?? "\(group)" }
    public var title: String { tag ?? group.title }
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

    /// The Feed's List in sections by why each paper is suggested, or nil when there would be one section (every
    /// paper has the same kind of reason, or none: category chips) and the List shows no headers.
    ///
    /// Order: one section per tag (the order the server ranked their first papers), then like papers you added, from
    /// authors you read, popular this week, by category, something different. Within a section, the server's order.
    /// Tags with one paper each are merged into one "Your tags" section after the others when there are two or more of
    /// them (a run of one-paper headers reads worse than a list); a single one keeps its name.
    public static func sections(_ results: [DiscoveryResult]) -> [FeedSection]? {
        var tags: [String] = [], byTag: [String: [DiscoveryResult]] = [:], names: [String: String] = [:]
        var groups: [FeedWhyGroup: [DiscoveryResult]] = [:]
        for result in results {
            let group = result.reason?.group ?? .other
            if group == .tag, let label = result.reason?.label {
                let key = label.lowercased()
                if byTag[key] == nil { tags.append(key); names[key] = label }
                byTag[key, default: []].append(result)
            } else {
                groups[group, default: []].append(result)
            }
        }
        var sections: [FeedSection] = []
        let single = tags.filter { byTag[$0]?.count == 1 }
        let merge = single.count >= 2
        for key in tags where !(merge && single.contains(key)) {
            sections.append(FeedSection(group: .tag, tag: names[key], results: byTag[key] ?? []))
        }
        // `single` is in the server's order of first appearance, one paper each.
        if merge { sections.append(FeedSection(group: .tag, tag: nil, results: single.compactMap { byTag[$0]?.first })) }
        for group in FeedWhyGroup.allCases where group != .tag {
            if let list = groups[group], !list.isEmpty { sections.append(FeedSection(group: group, tag: nil, results: list)) }
        }
        return sections.count > 1 ? sections : nil
    }

    /// A row's why line inside its section: what the header doesn't already say, or nil when it says it all (a tag's
    /// own section). "Like “Muffin…”", "By Tri Dao", "Added by several readers", "Robotics".
    public static func line(_ reason: FeedReason, in section: FeedSection) -> String? {
        switch reason.kind {
        case "tag": return section.tag == nil ? reason.label : nil
        case "added": return "Like “\(shortTitle(reason.label, limit: 60))”"
        case "more_like": return "More like “\(shortTitle(reason.label, limit: 60))”"
        case "author": return "By \(reason.label)"
        case "popular": return "Added by several readers"
        case "trending": return "On Hugging Face Papers"
        case "category": return dropping("New in ", from: reason.text)
        case "explore": return dropping("Something different: ", from: reason.text)
        default: return reason.text
        }
    }

    /// The Table's Why order: rows grouped as the List's sections are (tags together, then like papers, authors,
    /// popular, category, explore; no reason last), the server's order within each. Reversed, the groups reverse and
    /// rows without a reason stay last.
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

    private static func dropping(_ prefix: String, from text: String) -> String {
        text.hasPrefix(prefix) && text.count > prefix.count ? String(text.dropFirst(prefix.count)) : text
    }
}
