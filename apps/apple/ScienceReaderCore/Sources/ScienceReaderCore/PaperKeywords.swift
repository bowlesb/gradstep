import Foundation

/// Deterministic device keywords. Category labels are not evidence that a paper is about a specific method.
public enum PaperKeywords {
    public static func allowed(_ name: String) -> Bool {
        !["artificial intelligence", "machine learning", "ai", "ml", "statistical ml"].contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    /// Specific enough to tell this paper from others (owner, builds 70 and 75): not AI/ML and not one of the generic
    /// keywords such as LLM, Large language models, Reasoning or Evaluation. Derived keywords and catalog tags use it;
    /// a tag the reader typed only has to be `allowed`.
    public static func distinctive(_ name: String) -> Bool {
        allowed(name) && !TagVocabulary.generic.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    /// Library rows, filters, the reader's header and the tag editor ask for the same papers' keywords over and over
    /// (view bodies): a title/abstract pair is derived once. Bounded; derivation is pure, so nothing to invalidate.
    private static let memo = KeywordMemo()

    public static func derive(title: String, abstract: String, text: String = "") -> [String] {
        guard text.isEmpty else { return compute(title: title, abstract: abstract, text: text) }
        let key = title + "\u{1F}" + abstract
        if let known = memo.value(for: key) { return known }
        let derived = compute(title: title, abstract: abstract, text: "")
        memo.store(derived, for: key)
        return derived
    }

    /// The vocabulary's topic terms as lowercase word sequences, with the singular of a plural last word.
    private static let terms: [(name: String, words: [Substring], singular: [Substring])] =
        TagVocabulary.tags.filter { $0.kind == .topic && distinctive($0.name) }.map { tag in
            let words = words(tag.name)
            var singular = words
            if let last = singular.last, last.hasSuffix("s") { singular[singular.count - 1] = last.dropLast() }
            return (tag.name, words, singular)
        }

    /// Lowercase letter/number runs; a hyphen separates words.
    private static func words(_ text: String) -> [Substring] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }

    /// Whole-word phrase lookup: the same matches as searching " a b " in the space-joined words, without scanning
    /// the text once per vocabulary term (~5 ms a paper, NATIVE_REVIEW_20261021 C2).
    private struct WordIndex {
        let words: [Substring]
        let starts: [Substring: [Int]]
        init(_ text: String) {
            words = PaperKeywords.words(text)
            var starts: [Substring: [Int]] = [:]
            for (index, word) in words.enumerated() { starts[word, default: []].append(index) }
            self.starts = starts
        }
        func contains(_ phrase: [Substring]) -> Bool {
            guard let first = phrase.first, !first.isEmpty, let positions = starts[first] else { return false }
            return positions.contains { start in
                start + phrase.count <= words.count && (1..<phrase.count).allSatisfy { words[start + $0] == phrase[$0] }
            }
        }
    }

    private static func compute(title: String, abstract: String, text: String) -> [String] {
        let heading = WordIndex(title), summary = WordIndex(abstract), body = WordIndex(String(text.prefix(500_000)))
        var ranked: [(String, Int)] = terms.compactMap { term in
            func has(_ value: WordIndex) -> Bool { value.contains(term.words) || value.contains(term.singular) }
            let score = (has(heading) ? 20 : 0) + (has(summary) ? 8 : 0) + (has(body) ? 1 : 0)
            return score > 0 ? (term.name, score) : nil
        }
        // A named method/dataset from the title is useful even when newer than our vocabulary.
        for raw in title.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }) {
            let word = String(raw)
            if word.count >= 3 && word.count <= 32 && word.filter(\.isUppercase).count >= 2 && distinctive(word) {
                ranked.append((word, 25))
            }
        }
        var seen = Set<String>()
        return ranked.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.compactMap {
            seen.insert($0.0.lowercased()).inserted ? $0.0 : nil
        }.prefix(6).map { $0 }
    }
}

/// Derived keywords by title and abstract, from any thread. Bounded: cleared when full.
final class KeywordMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String]] = [:]
    func value(for key: String) -> [String]? { lock.withLock { values[key] } }
    func store(_ value: [String], for key: String) {
        lock.withLock {
            if values.count >= 4_096 { values.removeAll(keepingCapacity: true) }
            values[key] = value
        }
    }
}

/// A bounded, disposable in-memory index. No paper text is written beside the encrypted bundle.
/// Terms, not snippets, are kept; each paper is independently removable.
public struct DevicePaperTextIndex: Sendable {
    public struct Entry: Sendable {
        public let digest: String
        public let terms: [String]
        public init(digest: String, text: String) {
            self.digest = digest
            var seen = Set<String>(), result: [String] = []
            // A stateful filter cannot be a lazy Collection: prefix/map may traverse it more than once.
            for word in String(text.prefix(500_000)).lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                guard word.count > 1, word.count <= 80 else { continue }
                let term = String(word)
                if seen.insert(term).inserted { result.append(term); if result.count == 10_000 { break } }
            }
            terms = result
        }
    }
    public private(set) var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    public init() {}
    public mutating func insert(_ entry: Entry, for id: UUID) {
        remove(id); entries[id] = entry; order.append(id)
        while order.count > 200 { remove(order[0]) }
    }
    public mutating func remove(_ id: UUID) { entries[id] = nil; order.removeAll { $0 == id } }
    public mutating func retain(_ ids: Set<UUID>) { for id in Array(entries.keys) where !ids.contains(id) { remove(id) } }
}
