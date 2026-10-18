import Foundation

/// Deterministic device keywords. Category labels are not evidence that a paper is about a specific method.
public enum PaperKeywords {
    public static func allowed(_ name: String) -> Bool {
        !["artificial intelligence", "machine learning", "ai", "ml", "statistical ml"].contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    public static func derive(title: String, abstract: String, text: String = "") -> [String] {
        func normalized(_ s: String) -> String { " " + s.lowercased().replacingOccurrences(of: "-", with: " ").split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ") + " " }
        let heading = normalized(title), summary = normalized(abstract), body = normalized(String(text.prefix(500_000)))
        var ranked: [(String, Int)] = TagVocabulary.tags.filter { $0.kind == .topic && allowed($0.name) }.compactMap { tag in
            let term = normalized(tag.name)
            let singular = term.hasSuffix("s ") ? String(term.dropLast(2)) + " " : term
            func has(_ value: String) -> Bool { value.contains(term) || value.contains(singular) }
            let score = (has(heading) ? 20 : 0) + (has(summary) ? 8 : 0) + (has(body) ? 1 : 0)
            return score > 0 ? (tag.name, score) : nil
        }
        // A named method/dataset from the title is useful even when newer than our vocabulary.
        for raw in title.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }) {
            let word = String(raw)
            if word.count >= 3 && word.count <= 32 && word.filter(\.isUppercase).count >= 2 && allowed(word) {
                ranked.append((word, 25))
            }
        }
        var seen = Set<String>()
        return ranked.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.compactMap {
            seen.insert($0.0.lowercased()).inserted ? $0.0 : nil
        }.prefix(6).map { $0 }
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
