import Foundation

/// Queries the everything index (docs/architecture/GLOBAL_SEARCH.md "Ranking"): BM25F with the Library's field weights
/// within a kind, then × 1.3 when the query's words are adjacent (as a phrase, even unquoted), × 1.3 for the reader's
/// own questions over answers, × up to 1.2 for recency (linear over 90 days). Results are grouped (Chats, Explanations,
/// Snippets, Diagrams), never one mixed list: scores of different corpora are not comparable, and a fixed order keeps
/// rows from jumping between keystrokes.
public enum EverythingSearch {
    public static let phraseBoost = 1.3
    public static let readerBoost = 1.3
    public static let recencyBoost = 0.2
    public static let recencyWindow: TimeInterval = 90 * 86_400

    public struct Options: Sendable, Equatable {
        /// Only items about this paper ("In this paper").
        public var paperID: UUID?
        /// Only these groups (a chip); nil is every group.
        public var groups: Set<SearchGroup>?
        /// One row per conversation (and per collection) with the number of its other matches: the All view.
        public var collapse: Bool
        /// Items matching only some of the query's words, most words first ("Results with some of your words").
        public var partial: Bool
        public var now: Date
        public init(paperID: UUID? = nil, groups: Set<SearchGroup>? = nil, collapse: Bool = true, partial: Bool = false, now: Date = Date()) {
            self.paperID = paperID; self.groups = groups; self.collapse = collapse; self.partial = partial; self.now = now
        }
    }

    /// One result: an item, its score, how it matched, and (collapsed) how many more of its container's items matched.
    public struct Hit: Sendable, Equatable, Identifiable {
        public let info: SearchItemInfo
        public let score: Double
        /// The query's clauses it holds, and how many clauses the query has.
        public let clauses: UInt64
        public let clauseCount: Int
        /// Per field (`FullTextField` order), the query's clauses found there: which field the row's excerpt comes from.
        public var fieldClauses: [UInt64] = []
        /// Other matching items in the same conversation or collection (the All view's "+3 more in this chat").
        public var more: Int = 0
        /// Its conversation or collection.
        var collapseKey: UUID?
        public var id: String { info.group }
        public var matched: Int { clauses.nonzeroBitCount }

        /// Per clause, the strongest field it was found in (made for rows shown, not every hit).
        public var match: SearchMatch {
            SearchMatch(clauseFields: (0..<clauseCount).map { clause -> SearchMatchField? in
                guard clause < 64 else { return nil }
                let bit: UInt64 = 1 << UInt64(clause)
                return fieldClauses.indices.filter { fieldClauses[$0] & bit != 0 }
                    .compactMap { FullTextField(rawValue: $0).map(SearchMatchField.init) }.min()
            })
        }
    }

    public struct Group: Sendable, Equatable {
        public let group: SearchGroup
        /// Rows in order (collapsed in the All view).
        public let hits: [Hit]
        /// Every matching item.
        public let total: Int
        /// Distinct conversations (Chats) or collections (Snippets) among them.
        public let containers: Int
    }

    /// Every group with a match, in `SearchGroup` order.
    public static func search(_ snapshot: EverythingSnapshot, query: FullTextQuery, options: Options = Options(),
                              isCancelled: () -> Bool = { false }) -> [Group] {
        guard !query.isEmpty, snapshot.count > 0 else { return [] }
        let hits = snapshot.index.searchSlots(query, isCancelled: isCancelled)
        guard !isCancelled(), !hits.isEmpty else { return [] }
        let count = query.clauses.count
        let all: UInt64 = count >= 64 ? .max : (1 << UInt64(count)) - 1
        // Adjacent words: the query's unquoted words as one phrase (only when there are two or more).
        var adjacent: [Bool] = []
        let words = query.clauses.filter { !$0.phrase }.map(\.text)
        if words.count >= 2 && words.count == count {
            let phrase = FullTextQuery("\"" + words.joined(separator: " ") + "\"")
            if phrase.clauses.count == 1 { adjacent = snapshot.index.searchSlots(phrase, isCancelled: isCancelled).map { $0 != nil } }
        }
        // Plain keys per group, sorted; hits are made after (sorting large values costs more than ranking them).
        struct Key { let slot: Int32; let score: Double; let matched: Int; let date: Double }
        var keys = [[Key]](repeating: [], count: SearchGroup.allCases.count)
        let now = options.now.timeIntervalSince1970
        for slot in hits.indices {
            guard let hit = hits[slot], let info = snapshot.slotInfos[slot] else { continue }
            let group = info.kind.group
            if let wanted = options.groups, !wanted.contains(group) { continue }
            if let paper = options.paperID, info.paperID != paper { continue }
            let matched = (hit.clauses & all).nonzeroBitCount
            guard options.partial ? matched > 0 : hit.clauses & all == all else { continue }
            var score = hit.score
            if adjacent.indices.contains(slot), adjacent[slot] { score *= phraseBoost }
            if info.byReader { score *= readerBoost }
            let date = snapshot.slotDates[slot]
            if date.isFinite { score *= 1 + recencyBoost * max(0, 1 - max(0, now - date) / recencyWindow) }
            if options.partial { score *= Double(matched) / Double(count) }
            keys[SearchGroup.allCases.firstIndex(of: group)!].append(Key(slot: Int32(slot), score: score, matched: matched, date: date))
        }
        var out: [Group] = []
        for (position, group) in SearchGroup.allCases.enumerated() {
            guard !keys[position].isEmpty else { continue }
            var list = keys[position]
            list.sort { a, b in
                if a.matched != b.matched { return a.matched > b.matched }
                if a.score != b.score { return a.score > b.score }
                if a.date != b.date { return a.date > b.date }
                return a.slot < b.slot
            }
            var rows = list.map { key -> Hit in
                let slot = Int(key.slot), hit = hits[slot]!
                return Hit(info: snapshot.slotInfos[slot]!, score: key.score, clauses: hit.clauses & all, clauseCount: count,
                           fieldClauses: hit.fieldClauses, collapseKey: snapshot.slotKeys[slot])
            }
            let total = rows.count
            let containers = Set(rows.lazy.compactMap(\.collapseKey)).count
            if options.collapse && (group == .chats || group == .snippets) { rows = collapsed(rows) }
            out.append(Group(group: group, hits: rows, total: total, containers: containers))
        }
        return out
    }

    /// One row per conversation or collection: the conversation (or collection) itself when its title matched, else its
    /// best message (snippet); `more` counts the others. Rows keep the order of their best item.
    static func collapsed(_ hits: [Hit]) -> [Hit] {
        var rows: [Hit] = []
        var rowOf: [UUID: Int] = [:]
        var counts: [UUID: Int] = [:]
        var containerRows: [UUID: Hit] = [:]
        for hit in hits {
            guard let key = hit.collapseKey else { rows.append(hit); continue }
            counts[key, default: 0] += 1
            if hit.info.kind == .conversation || hit.info.kind == .collection { containerRows[key] = hit }
            if rowOf[key] == nil { rowOf[key] = rows.count; rows.append(hit) }
        }
        for (key, index) in rowOf {
            var row = rows[index]
            if let own = containerRows[key], own.id != row.id {
                // The conversation's own row takes its best item's place in the order.
                row = Hit(info: own.info, score: max(own.score, row.score), clauses: own.clauses, clauseCount: own.clauseCount,
                          fieldClauses: own.fieldClauses, collapseKey: own.collapseKey)
            }
            row.more = (counts[key] ?? 1) - 1
            rows[index] = row
        }
        return rows
    }

    // MARK: Rows

    /// How a row shows its match: the title's matched words and one excerpt from wherever else it matched: the field
    /// the index found the most of the words the title doesn't show in (notes, then the text, then tags). One excerpt
    /// a row: an excerpt reads its whole field (about 0.3 ms for a long answer).
    public static func display(_ item: SearchItem, title: String, query: FullTextQuery, match: SearchMatch, fieldClauses: [UInt64] = []) -> SearchResultMatch {
        var result = SearchResultMatch(match: match, titleHighlights: SearchHighlighter.highlights(query, in: title))
        let inTitle = SearchHighlighter.clauses(query, in: title)
        var titleBits: UInt64 = 0
        for clause in inTitle where clause < 64 { titleBits |= 1 << UInt64(clause) }
        let candidates: [(SearchMatchField, FullTextField, String)] = [(.notes, .notes, item.notes), (.fullText, .body, item.body),
                                                                       (.tags, .tags, item.tags), (.title, .title, item.title)]
        // Fields in order of how many new words the index found there (all of them when it isn't known).
        let ranked = candidates.filter { !$0.2.isEmpty }.map { candidate -> (Int, (SearchMatchField, FullTextField, String)) in
            let bits = fieldClauses.indices.contains(candidate.1.rawValue) ? fieldClauses[candidate.1.rawValue] : .max
            return ((bits & ~titleBits).nonzeroBitCount, candidate)
        }.sorted { $0.0 > $1.0 }
        for (found, candidate) in ranked where found > 0 || fieldClauses.isEmpty {
            guard let excerpt = SearchHighlighter.excerpt(query, in: candidate.2) else { continue }
            if SearchHighlighter.clauses(query, in: excerpt.text).subtracting(inTitle).isEmpty && !inTitle.isEmpty { continue }
            result.excerpt = excerpt; result.excerptField = candidate.0
            return result
        }
        if inTitle.isEmpty, let text = [item.body, item.notes].first(where: { !$0.isEmpty }) {
            // Nothing to mark (a typed word's longer forms): the start of its text.
            result.excerpt = FullTextSnippet(text: String(SearchHighlighter.normalized(text).prefix(160)), highlights: [])
        }
        return result
    }
}

/// Searching what is kept in memory, not indexed (docs/architecture/GLOBAL_SEARCH.md "In memory"): Settings rows, tags,
/// the Feed's current page, and the open paper's passages.
public enum MemorySearch {
    /// Every word of `query` begins a word of `texts` (each word a prefix, as typed); the title's matched words. Settings
    /// rows and tags match this way, never from explanatory text alone.
    public static func prefixMatch(_ query: String, in texts: [String]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return false }
        return words.allSatisfy { word in
            let clause = FullTextQuery(word)
            return !clause.isEmpty && texts.contains { !SearchHighlighter.clauses(clause, in: $0).isEmpty }
        }
    }

    /// The query's words in `text` (each a prefix), for marking a Settings row's or tag's title.
    public static func prefixHighlights(_ query: String, in text: String) -> [Range<Int>] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var ranges: [Range<Int>] = []
        for word in words { ranges += SearchHighlighter.highlights(FullTextQuery(word), in: text) }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// A text's match when every clause is in one of `fields` (each at its strongest), else nil.
    public static func match(_ query: FullTextQuery, fields: [(SearchMatchField, String)], partial: Bool = false) -> SearchMatch? {
        let match = SearchHighlighter.evaluate(query, fields: fields)
        return (partial ? match.matched > 0 : match.matched == match.total) ? match : nil
    }

    /// A passage of the open paper: its block, the heading it is under, and the words around the match.
    public struct Passage: Sendable, Equatable, Identifiable {
        public let blockID: String
        public let section: String?
        public let excerpt: FullTextSnippet
        public var id: String { blockID }
    }

    /// The blocks of a reading that hold every clause, in reading order (at most `limit`).
    public static func passages(_ query: FullTextQuery, in index: ReaderBundleIndex, limit: Int = 200, isCancelled: () -> Bool = { false }) -> (passages: [Passage], total: Int) {
        guard !query.isEmpty else { return ([], 0) }
        let headings = Dictionary(index.headings.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var section: String?
        var out: [Passage] = []
        var total = 0
        let all = Set(0..<query.clauses.count)
        for block in index.blocks {
            if isCancelled() { break }
            if let title = headings[block.id] { section = title; continue }
            guard !block.text.isEmpty else { continue }
            let text = block.kind == "equation" ? SearchText.math(block.text) : block.text
            guard SearchHighlighter.clauses(query, in: text) == all else { continue }
            total += 1
            if out.count < limit, let excerpt = SearchHighlighter.excerpt(query, in: text) {
                out.append(Passage(blockID: block.id, section: section, excerpt: excerpt))
            }
        }
        return (out, total)
    }
}
