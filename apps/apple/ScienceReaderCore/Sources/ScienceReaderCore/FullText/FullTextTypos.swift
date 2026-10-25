import Foundation

/// A word that matches nothing may be a typo (docs/architecture/GLOBAL_SEARCH.md "Typos"): the indexed words within one
/// edit of it (two from eight letters; none under four), an edit being an insertion, a deletion, a substitution or two
/// neighbouring letters swapped. Run only when a word found nothing, over every index's dictionary.
public enum FullTextTypos {
    /// Shorter words are never corrected: one edit away from a short word is too many other words.
    public static let minimumLength = 4

    /// Edits allowed for a word of `length` letters.
    public static func allowedDistance(_ length: Int) -> Int { length < minimumLength ? 0 : length >= 8 ? 2 : 1 }

    /// The correction for `word` (as typed): the closest indexed word, the one in most documents among equally close ones,
    /// then the first alphabetically. Nil when none is close enough, or the word is itself indexed.
    public static func correction(for word: String, in snapshots: [FullTextSnapshot]) -> String? {
        let folded = FullTextTokenizer.tokens(word, stem: false).filter { !$0.joined }
        guard folded.count == 1, !folded[0].mapped else { return nil }
        let plain = folded[0].term
        let stemmed = FullTextTokenizer.stemmed(plain)
        let limit = allowedDistance(plain.count)
        guard limit > 0 else { return nil }
        var candidates: [String: (distance: Int, documents: Int)] = [:]
        let key = Array(plain.utf8)
        var rows = Rows(capacity: key.count + limit + 1)
        for snapshot in snapshots {
            if snapshot.containsTerm(stemmed) || snapshot.containsTerm(plain) { return nil }
            snapshot.forEachTerm(lengths: max(1, key.count - limit)...(key.count + limit)) { term, documents in
                guard let distance = distance(key, term, limit: limit, rows: &rows) else { return }
                let text = String(decoding: term, as: UTF8.self)
                let known = candidates[text]
                candidates[text] = (min(distance, known?.distance ?? .max), (known?.documents ?? 0) + documents)
            }
        }
        return candidates.min { a, b in
            if a.value.distance != b.value.distance { return a.value.distance < b.value.distance }
            if a.value.documents != b.value.documents { return a.value.documents > b.value.documents }
            return a.key < b.key
        }?.key
    }

    /// Three rows of the dynamic programme, reused for every term.
    struct Rows {
        var previous2: [Int], previous: [Int], current: [Int]
        init(capacity: Int) { previous2 = Array(repeating: 0, count: capacity + 1); previous = previous2; current = previous2 }
    }

    /// Optimal string alignment distance between `a` and `b` (bytes), or nil when it is over `limit`.
    static func distance(_ a: [UInt8], _ b: UnsafeBufferPointer<UInt8>, limit: Int) -> Int? {
        var rows = Rows(capacity: max(a.count, b.count) + 1)
        return distance(a, b, limit: limit, rows: &rows)
    }

    static func distance(_ a: [UInt8], _ b: UnsafeBufferPointer<UInt8>, limit: Int, rows: inout Rows) -> Int? {
        let n = a.count, m = b.count
        guard abs(n - m) <= limit else { return nil }
        if n == 0 { return m <= limit ? m : nil }
        if m == 0 { return n <= limit ? n : nil }
        if rows.current.count < m + 1 { rows = Rows(capacity: m + 1) }
        // A row whose minimum passes the limit ends it.
        // Moved out of `rows` (not copied), so writing them never copies.
        var previous2: [Int] = [], previous: [Int] = [], current: [Int] = []
        swap(&previous2, &rows.previous2); swap(&previous, &rows.previous); swap(&current, &rows.current)
        defer { swap(&previous2, &rows.previous2); swap(&previous, &rows.previous); swap(&current, &rows.current) }
        for j in 0...m { previous[j] = j }
        for i in 1...n {
            current[0] = i
            var rowMinimum = i
            for j in 1...m {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { value = min(value, previous2[j - 2] + 1) }
                current[j] = value
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > limit { return nil }
            swap(&previous2, &previous)
            swap(&previous, &current)
        }
        return previous[m] <= limit ? previous[m] : nil
    }
}

extension FullTextSnapshot {
    /// Whether any current document has `term` (exactly as the tokenizer makes it).
    public func containsTerm(_ term: String) -> Bool {
        for (s, segment) in segments.enumerated() {
            guard let index = segment.find(term) else { continue }
            var found = false
            segment.forEachPosting(index) { doc, _, _ in if !found && docGroup[s][doc] >= 0 { found = true } }
            if found { return true }
        }
        return false
    }

    /// Every indexed term whose length in bytes is in `lengths`, with the documents holding it in its segment.
    func forEachTerm(lengths: ClosedRange<Int>, _ visit: (UnsafeBufferPointer<UInt8>, Int) -> Void) {
        for segment in segments {
            segment.termBytes.withUnsafeBufferPointer { bytes in
                for index in 0..<segment.termCount {
                    let start = Int(segment.termOffsets[index]), end = Int(segment.termOffsets[index + 1])
                    guard lengths.contains(end - start) else { continue }
                    visit(UnsafeBufferPointer(rebasing: bytes[start..<end]), Int(segment.documentFrequencies[index]))
                }
            }
        }
    }
}
