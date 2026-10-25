import Foundation

/// Where a search word was found, strongest first (the order Library ranking weighs them).
public enum SearchMatchField: Int, CaseIterable, Comparable, Sendable {
    case identifier, title, abstract, authors, tags, notes, fullText

    /// What a result's match line says ("100% · title").
    public var label: String {
        switch self {
        case .identifier: "ID"; case .title: "title"; case .abstract: "abstract"; case .authors: "authors"
        case .tags: "tags"; case .notes: "notes"; case .fullText: "full text"
        }
    }

    /// What VoiceOver says ("in the title").
    var spoken: String { self == .identifier ? "the ID" : self == .fullText ? "the full text" : "the \(label)" }

    public init(_ field: FullTextField) {
        switch field {
        case .title: self = .title
        case .authors: self = .authors
        case .tags: self = .tags
        case .abstract: self = .abstract
        case .notes: self = .notes
        case .body: self = .fullText
        }
    }

    public static func < (left: Self, right: Self) -> Bool { left.rawValue < right.rawValue }
}

/// How a search result matched its query: for each of the query's words (a quoted phrase counts as one), the strongest
/// field it was found in. Its percentage is the share of words found, never a similarity score
/// (docs/architecture/NATIVE_LIBRARY_SEARCH.md "Match strength").
public struct SearchMatch: Equatable, Sendable {
    /// Per clause of the query, in order: the strongest field it was found in, or nil.
    public let clauseFields: [SearchMatchField?]

    public init(clauseFields: [SearchMatchField?]) { self.clauseFields = clauseFields }

    public var total: Int { clauseFields.count }
    public var matched: Int { clauseFields.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }
    /// The share of the query's words found, rounded to a whole percent.
    public var percent: Int { total == 0 ? 0 : Int((Double(matched) * 100 / Double(total)).rounded()) }
    /// The fields the words were found in (each word counted at its strongest), strongest first.
    public var fields: [SearchMatchField] { Array(Set(clauseFields.compactMap { $0 })).sorted() }

    /// "100% · title", "67% · title, abstract", "0%".
    public var label: String {
        let fields = fields
        return fields.isEmpty ? "\(percent)%" : "\(percent)% · " + fields.map(\.label).joined(separator: ", ")
    }

    /// "Matches 2 of 3 search words, in the title and the abstract".
    public var spokenLabel: String {
        let places = fields.map(\.spoken)
        let place = places.count <= 1 ? places.first : places.dropLast().joined(separator: ", ") + " and " + places[places.count - 1]
        let count = total == 1 ? (matched == 1 ? "Matches your search word" : "Doesn’t contain your search word")
            : matched == total ? "Matches all \(total) search words" : "Matches \(matched) of \(total) search words"
        return count + (place.map { ", in \($0)" } ?? "")
    }
}

/// What a search result row shows about its match: the strength, the title's matched words, and one line of where
/// else it matched (the paper's text, its abstract or authors) with the matched words marked.
public struct SearchResultMatch: Equatable, Sendable {
    public var match: SearchMatch
    /// UTF-16 ranges of matched words in the title as given.
    public var titleHighlights: [Range<Int>]
    /// A line around the densest match outside the title, or nil.
    public var excerpt: FullTextSnippet?
    /// Where `excerpt` comes from.
    public var excerptField: SearchMatchField?

    public init(match: SearchMatch, titleHighlights: [Range<Int>] = [], excerpt: FullTextSnippet? = nil, excerptField: SearchMatchField? = nil) {
        self.match = match; self.titleHighlights = titleHighlights; self.excerpt = excerpt; self.excerptField = excerptField
    }
}

/// Finds a query's words in short texts that are not in the index (titles, abstracts, ML paper search results) by the
/// index's own rules: the same tokens, plural stemming, compounds, phrases as adjacent words, the word being typed as
/// a prefix. `loose` also equates common English word endings ("learning", "learned", "learn"), for results another
/// search engine chose (arXiv stems words that way).
public enum SearchHighlighter {
    /// One occurrence of a clause: its index in the query and its UTF-16 range in the text.
    public struct Occurrence: Equatable, Sendable {
        public let clause: Int
        public let range: Range<Int>
    }

    /// Whitespace runs as one space, trimmed: what excerpts and highlights refer to.
    public static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Every occurrence of the query's clauses in `text` (as given), in text order.
    public static func occurrences(_ query: FullTextQuery, in text: String, loose: Bool = false) -> [Occurrence] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        let stemmed = FullTextTokenizer.tokens(text, stem: true), plain = FullTextTokenizer.tokens(text, stem: false)
        guard stemmed.count == plain.count, !stemmed.isEmpty else { return [] }
        let utf16 = utf16Offsets(text)
        let parts = stemmed.indices.filter { !stemmed[$0].joined }
        var out: [Occurrence] = []
        for (clauseIndex, clause) in query.clauses.enumerated() {
            for sequence in clause.sequences where !sequence.isEmpty {
                if sequence.count == 1 {
                    for index in stemmed.indices where matches(sequence[0], stemmed[index].term, plain[index].term, loose: loose) {
                        out.append(Occurrence(clause: clauseIndex, range: utf16[stemmed[index].start]..<utf16[stemmed[index].end]))
                    }
                    continue
                }
                guard parts.count >= sequence.count else { continue }
                starts: for start in 0...(parts.count - sequence.count) {
                    for (offset, slot) in sequence.enumerated() {
                        let index = parts[start + offset]
                        if stemmed[index].position != stemmed[parts[start]].position + offset { continue starts }
                        if !matches(slot, stemmed[index].term, plain[index].term, loose: loose) { continue starts }
                    }
                    let first = stemmed[parts[start]], last = stemmed[parts[start + sequence.count - 1]]
                    out.append(Occurrence(clause: clauseIndex, range: utf16[first.start]..<utf16[last.end]))
                }
            }
        }
        return out.sorted { $0.range.lowerBound == $1.range.lowerBound ? $0.range.count > $1.range.count : $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The clauses of the query found in `text`.
    public static func clauses(_ query: FullTextQuery, in text: String, loose: Bool = false) -> Set<Int> {
        Set(occurrences(query, in: text, loose: loose).map(\.clause))
    }

    /// Matched ranges in `text` (as given), overlapping ones merged.
    public static func highlights(_ query: FullTextQuery, in text: String, loose: Bool = false) -> [Range<Int>] {
        merged(occurrences(query, in: text, loose: loose).map(\.range))
    }

    /// `text` with whitespace collapsed and every match marked.
    public static func highlighted(_ query: FullTextQuery, in text: String, loose: Bool = false) -> FullTextSnippet {
        let text = normalized(text)
        return FullTextSnippet(text: text, highlights: highlights(query, in: text, loose: loose))
    }

    /// About `length` characters of `text` (whitespace collapsed) around its densest cluster of matches (most distinct
    /// clauses within `window` characters, then most matches), cut at words with "…" at cut ends; from the start
    /// when the cluster is near it. Nil when nothing matches.
    public static func excerpt(_ query: FullTextQuery, in text: String, length: Int = 160, loose: Bool = false) -> FullTextSnippet? {
        let text = normalized(text)
        let found = occurrences(query, in: text, loose: loose)
        guard !found.isEmpty else { return nil }
        let units = Array(text.utf16)
        let window = max(40, length * 2 / 3)
        var best = (start: 0, end: 0, score: -1), end = 0
        for start in found.indices {
            if end < start { end = start }
            while end + 1 < found.count && found[end + 1].range.upperBound <= found[start].range.lowerBound + window { end += 1 }
            let score = Set(found[start...end].map(\.clause)).count * 1_000 + (end - start + 1)
            if score > best.score { best = (start, end, score) }
        }
        let first = found[best.start].range.lowerBound
        // Start about 40 characters before the cluster, at a word; from the beginning when that is close.
        var from = max(0, first - 40)
        if from <= 60 { from = 0 } else { while from < first && units[from - 1] != 0x20 { from += 1 } }
        var to = min(units.count, from + length)
        if to < units.count { while to > max(found[best.end].range.upperBound, from + 1) && units[to] != 0x20 { to -= 1 } }
        to = max(to, min(units.count, found[best.end].range.upperBound))
        let lead = from > 0 ? "…" : "", trail = to < units.count ? "…" : ""
        let body = String(decoding: units[from..<to], as: UTF16.self).trimmingCharacters(in: .whitespaces)
        let shift = lead.utf16.count - from
        let highlights = merged(found.map(\.range).filter { $0.lowerBound >= from && $0.upperBound <= to })
            .map { ($0.lowerBound + shift)..<($0.upperBound + shift) }
        return highlights.isEmpty ? nil : FullTextSnippet(text: lead + body + trail, highlights: highlights)
    }

    /// The match of texts outside the index (an ML paper search result): each clause at the strongest field whose
    /// text contains it.
    public static func evaluate(_ query: FullTextQuery, fields: [(SearchMatchField, String)], loose: Bool = false) -> SearchMatch {
        var best = [SearchMatchField?](repeating: nil, count: query.clauses.count)
        for (field, text) in fields.sorted(by: { $0.0 < $1.0 }) where !text.isEmpty {
            let pending = best.indices.filter { best[$0] == nil }
            guard !pending.isEmpty else { break }
            let found = field == .identifier ? identifierClauses(query, in: text) : clauses(query, in: text, loose: loose)
            for clause in pending where found.contains(clause) { best[clause] = field }
        }
        return SearchMatch(clauseFields: best)
    }

    /// An identifier matches a clause that names it (with or without a version or "arXiv:" before it).
    static func identifierClauses(_ query: FullTextQuery, in identifier: String) -> Set<Int> {
        let id = identifier.lowercased()
        var out = Set<Int>()
        for (index, clause) in query.clauses.enumerated() {
            var text = clause.text.lowercased()
            if text.hasPrefix("arxiv:") { text.removeFirst(6) }
            if let version = text.range(of: #"v\d+$"#, options: .regularExpression) { text.removeSubrange(version) }
            if !text.isEmpty && (text == id || text.hasSuffix("/" + id)) { out.insert(index) }
        }
        return out
    }

    // MARK: Helpers

    private static func matches(_ slot: FullTextQuery.Slot, _ term: String, _ plain: String, loose: Bool) -> Bool {
        if slot.terms.contains(term) { return true }
        if let prefix = slot.prefix, term.hasPrefix(prefix) || plain.hasPrefix(prefix) { return true }
        if loose { let ending = looseStem(term); return slot.terms.contains { looseStem($0) == ending } }
        return false
    }

    /// A word without a common English ending, for loose matching: "learning", "learned", "learner", "learn" → "learn";
    /// "optimized", "optimizing", "optimize" → "optimiz". Only ASCII words longer than four letters lose an ending.
    static func looseStem(_ word: String) -> String {
        guard word.utf8.allSatisfy({ $0 >= 97 && $0 <= 122 }) else { return word }
        for ending in ["ing", "ed", "er", "ly", "e"] where word.count - ending.count >= 4 && word.hasSuffix(ending) {
            return String(word.dropLast(ending.count))
        }
        return word
    }

    /// For each UTF-8 offset at a scalar boundary of `text`, its UTF-16 offset (other offsets are never asked for).
    private static func utf16Offsets(_ text: String) -> [Int] {
        var out = [Int](repeating: 0, count: text.utf8.count + 1)
        var utf8 = 0, utf16 = 0
        for scalar in text.unicodeScalars {
            out[utf8] = utf16
            let length = UTF8.width(scalar)
            for offset in 1..<max(1, length) { out[utf8 + offset] = utf16 }
            utf8 += length; utf16 += UTF16.width(scalar)
        }
        out[utf8] = utf16
        return out
    }

    private static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, range.lowerBound <= last.upperBound { out[out.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound) }
            else { out.append(range) }
        }
        return out
    }
}
