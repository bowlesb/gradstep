import Foundation

/// BM25 per field (its own length normalisation and saturation), weighted and summed per query clause, so a
/// title match outranks any number of body mentions and an abstract match outranks body mentions alone.
public enum FullTextRanking {
    /// Title above tags/authors/abstract above notes above body.
    public static let weights: [Double] = [6.0, 3.0, 3.0, 3.0, 2.0, 1.0]
    static let lengthNormalization: [Double] = [0.3, 0.3, 0.3, 0.5, 0.5, 0.75]
    static let k1 = 1.2
    /// Prefix expansions per slot and segment, most frequent first.
    public static let maximumExpansions = 64
    /// Body matches kept per paper and clause for its snippet.
    static let snippetMatches = 64

    static func idf(documents: Int, frequency: Int) -> Double {
        log(1 + (Double(documents) - Double(frequency) + 0.5) / (Double(frequency) + 0.5))
    }
}

/// One paper's match: which clauses matched (anywhere, and in the body) and its BM25F score.
public struct FullTextHit: Sendable {
    public let group: String
    public var score: Double = 0
    public var clauses: UInt64 = 0
    public var bodyClauses: UInt64 = 0
    /// Where the body matched, for the snippet: a term's postings entry (positions decoded only if a snippet is
    /// made) or a phrase's first position (`length` > 0).
    struct BodyReference: Sendable {
        let segment: Int32
        let at: UInt32
        let count: UInt32
        let length: UInt32
        let clause: UInt8
    }
    var bodyReferences: [BodyReference] = []
    init(group: String) { self.group = group }
}

/// A line of the paper's text around its densest match, with the matched words' ranges (UTF-16 offsets).
public struct FullTextSnippet: Equatable, Sendable {
    public let text: String
    public let highlights: [Range<Int>]
    public init(text: String, highlights: [Range<Int>]) { self.text = text; self.highlights = highlights }
    /// The first highlighted words, as they appear in the paper (what find-in-paper is given).
    public var firstMatch: String? {
        guard let range = highlights.first else { return nil }
        let utf16 = Array(text.utf16)
        guard range.lowerBound >= 0, range.upperBound <= utf16.count else { return nil }
        return String(decoding: utf16[range], as: UTF16.self)
    }
}

/// An immutable view of the index for queries: loaded segments and which of their documents are current. Queries
/// never block indexing; a newer snapshot replaces this one.
public final class FullTextSnapshot: @unchecked Sendable {
    let segments: [FullTextSegment]
    /// Per segment, per document: its paper's slot, or -1 when the document was replaced or removed.
    let docGroup: [[Int32]]
    /// Papers with at least one current document.
    public let groups: [String]
    let groupIndex: [String: Int32]
    /// Positions per paper and field (groups × fields).
    let fieldLengths: [UInt32]
    let averageFieldLengths: [Double]
    let texts: FullTextTextReader?
    public let generation: UInt64

    init(segments: [FullTextSegment], current: (Int, Int) -> Bool, texts: FullTextTextReader?, generation: UInt64) {
        self.segments = segments; self.texts = texts; self.generation = generation
        var groups: [String] = [], index: [String: Int32] = [:]
        var docGroup: [[Int32]] = []
        let fieldCount = FullTextField.allCases.count
        var lengths: [UInt32] = []
        for (s, segment) in segments.enumerated() {
            var map = [Int32](repeating: -1, count: segment.docs.count)
            for (d, doc) in segment.docs.enumerated() where current(s, d) {
                let slot: Int32
                if let known = index[doc.id.group] { slot = known } else {
                    slot = Int32(groups.count); index[doc.id.group] = slot; groups.append(doc.id.group)
                    lengths.append(contentsOf: repeatElement(0, count: fieldCount))
                }
                map[d] = slot
                for field in 0..<fieldCount where doc.lengths[field] > 0 { lengths[Int(slot) * fieldCount + field] = doc.lengths[field] }
            }
            docGroup.append(map)
        }
        var averages = [Double](repeating: 1, count: fieldCount)
        for field in 0..<fieldCount {
            var total = 0.0, count = 0.0
            for slot in 0..<groups.count where lengths[slot * fieldCount + field] > 0 { total += Double(lengths[slot * fieldCount + field]); count += 1 }
            if count > 0 { averages[field] = max(1, total / count) }
        }
        self.groups = groups; self.groupIndex = index; self.docGroup = docGroup
        self.fieldLengths = lengths; self.averageFieldLengths = averages
    }

    public var documentCount: Int { groups.count }

    // MARK: Statistics (the interest index's TF-IDF and, later, semantic search reuse these)

    /// Papers containing `term` (a folded, stemmed term as `FullTextTokenizer` makes it), in any field.
    public func documentFrequency(_ term: String) -> Int {
        var seen = Set<Int32>()
        for (s, segment) in segments.enumerated() {
            guard let index = segment.find(term) else { continue }
            segment.forEachPosting(index) { doc, _, _ in let g = docGroup[s][doc]; if g >= 0 { seen.insert(g) } }
        }
        return seen.count
    }

    /// Every term in `fields` of one paper with its number of occurrences there.
    public func termFrequencies(group: String, fields: Set<FullTextField> = Set(FullTextField.allCases)) -> [String: Int] {
        guard let slot = groupIndex[group] else { return [:] }
        var out: [String: Int] = [:]
        var positions: [UInt32] = []
        for (s, segment) in segments.enumerated() {
            let docs = segment.docs.indices.filter { docGroup[s][$0] == slot }
            guard !docs.isEmpty else { continue }
            for term in 0..<segment.termCount {
                var count = 0
                segment.forEachPosting(term) { doc, frequency, at in
                    guard docs.contains(doc) else { return }
                    let info = segment.docs[doc]
                    if fields.count == FullTextField.allCases.count { count += frequency; return }
                    positions.removeAll(keepingCapacity: true)
                    segment.positions(at: at, frequency: frequency, into: &positions)
                    count += positions.reduce(0) { $0 + (fields.contains(info.field(at: $1)) ? 1 : 0) }
                }
                if count > 0 { out[segment.term(term), default: 0] += count }
            }
        }
        return out
    }

    /// Document frequency of every term in the index (papers per term).
    public func documentFrequencies() -> [String: Int] {
        var out: [String: Set<Int32>] = [:]
        for (s, segment) in segments.enumerated() {
            for term in 0..<segment.termCount {
                var papers = Set<Int32>()
                segment.forEachPosting(term) { doc, _, _ in let g = docGroup[s][doc]; if g >= 0 { papers.insert(g) } }
                if !papers.isEmpty { out[segment.term(term), default: []].formUnion(papers) }
            }
        }
        return out.mapValues(\.count)
    }

    // MARK: Search

    /// Papers matching at least one clause, by paper. A paper matches the query when every clause bit is set
    /// (callers may also accept a clause through metadata substring matching).
    public func search(_ query: FullTextQuery, isCancelled: () -> Bool = { false }) -> [String: FullTextHit] {
        let fieldCount = FullTextField.allCases.count, groupCount = groups.count
        guard groupCount > 0, !query.clauses.isEmpty else { return [:] }
        var hits = [FullTextHit?](repeating: nil, count: groupCount)
        var references = [[FullTextHit.BodyReference]](repeating: [], count: groupCount)
        var frequencies = [Float](repeating: 0, count: groupCount * fieldCount)
        var isTouched = [Bool](repeating: false, count: groupCount)
        var touched: [Int32] = []
        var positions: [UInt32] = []
        for (clauseIndex, clause) in query.clauses.enumerated() {
            if isCancelled() { return [:] }
            for slot in touched { isTouched[Int(slot)] = false; for field in 0..<fieldCount { frequencies[Int(slot) * fieldCount + field] = 0 } }
            touched.removeAll(keepingCapacity: true)
            let clauseTag = UInt8(clauseIndex)
            for sequence in clause.sequences where !sequence.isEmpty {
                for (s, segment) in segments.enumerated() {
                    let slots = sequence.map { resolve($0, in: segment) }
                    guard slots.allSatisfy({ !$0.isEmpty }) else { continue }
                    let groupsOfDocs = docGroup[s]
                    if slots.count == 1 {
                        for term in slots[0] {
                            segment.forEachPosting(term) { doc, frequency, at in
                                let slot = groupsOfDocs[doc]
                                guard slot >= 0 else { return }
                                if !isTouched[Int(slot)] { isTouched[Int(slot)] = true; touched.append(slot) }
                                let info = segment.docs[doc]
                                if info.id.part == .body {
                                    // Positions are decoded later, only for the papers that get a snippet.
                                    frequencies[Int(slot) * fieldCount + FullTextField.body.rawValue] += Float(frequency)
                                    references[Int(slot)].append(.init(segment: Int32(s), at: UInt32(at), count: UInt32(frequency), length: 0, clause: clauseTag))
                                } else {
                                    positions.removeAll(keepingCapacity: true)
                                    segment.positions(at: at, frequency: frequency, into: &positions)
                                    for position in positions { frequencies[Int(slot) * fieldCount + info.field(at: position).rawValue] += 1 }
                                }
                            }
                        }
                    } else {
                        phrase(slots, in: segment, segmentIndex: s) { slot, doc, start in
                            if !isTouched[Int(slot)] { isTouched[Int(slot)] = true; touched.append(slot) }
                            let info = segment.docs[doc]
                            let field = info.id.part == .body ? FullTextField.body : info.field(at: start)
                            frequencies[Int(slot) * fieldCount + field.rawValue] += 1
                            if field == .body, references[Int(slot)].count < 4 * FullTextRanking.snippetMatches {
                                references[Int(slot)].append(.init(segment: Int32(s), at: start, count: 1, length: UInt32(slots.count), clause: clauseTag))
                            }
                        }
                    }
                }
            }
            guard !touched.isEmpty else { continue }
            let idf = FullTextRanking.idf(documents: groupCount, frequency: touched.count)
            for slot in touched {
                var score = 0.0
                let at = Int(slot) * fieldCount
                for field in 0..<fieldCount where frequencies[at + field] > 0 {
                    let b = FullTextRanking.lengthNormalization[field]
                    let length = Double(max(1, fieldLengths[at + field]))
                    let normalized = Double(frequencies[at + field]) / (1 - b + b * length / averageFieldLengths[field])
                    score += FullTextRanking.weights[field] * normalized * (FullTextRanking.k1 + 1) / (normalized + FullTextRanking.k1)
                }
                var hit = hits[Int(slot)] ?? FullTextHit(group: groups[Int(slot)])
                hit.score += idf * score
                hit.clauses |= 1 << UInt64(clauseIndex)
                if frequencies[at + FullTextField.body.rawValue] > 0 { hit.bodyClauses |= 1 << UInt64(clauseIndex) }
                hits[Int(slot)] = hit
            }
        }
        var out: [String: FullTextHit] = [:]
        for (slot, hit) in hits.enumerated() {
            guard var hit else { continue }
            hit.bodyReferences = references[slot]
            out[hit.group] = hit
        }
        return out
    }

    /// The term indexes a slot matches in one segment: its exact terms and up to `maximumExpansions` of the most
    /// frequent terms starting with its prefix.
    private func resolve(_ slot: FullTextQuery.Slot, in segment: FullTextSegment) -> [Int] {
        var out = slot.terms.compactMap { segment.find($0) }
        if let prefix = slot.prefix {
            let range = segment.prefixRange(prefix)
            if range.count <= FullTextRanking.maximumExpansions { out.append(contentsOf: range) }
            else {
                let top = range.sorted { segment.documentFrequencies[$0] > segment.documentFrequencies[$1] }.prefix(FullTextRanking.maximumExpansions)
                out.append(contentsOf: top)
            }
        }
        return out.count > 1 ? Array(Set(out)).sorted() : out
    }

    /// Visits each phrase occurrence (its first position) in current documents of a segment: a merge join of the
    /// slots' postings in document order, then of their positions.
    private func phrase(_ slots: [[Int]], in segment: FullTextSegment, segmentIndex s: Int, _ visit: (Int32, Int, UInt32) -> Void) {
        segment.postings.withUnsafeBufferPointer { bytes in
            var cursors: [[PostingCursor]] = slots.map { terms in
                terms.map { PostingCursor(bytes: bytes, offset: Int(segment.postingOffsets[$0]), end: Int(segment.postingOffsets[$0 + 1])) }
            }
            var buffers = [[UInt32]](repeating: [], count: slots.count)
            var indexes = [Int](repeating: 0, count: slots.count)
            func slotDoc(_ slot: Int) -> Int { cursors[slot].reduce(Int.max) { min($0, $1.doc) } }
            while true {
                var target = 0
                for slot in cursors.indices { target = max(target, slotDoc(slot)) }
                if target == Int.max { return }
                var aligned = true
                for slot in cursors.indices {
                    for term in cursors[slot].indices { cursors[slot][term].advance(to: target) }
                    if slotDoc(slot) != target { aligned = false }
                }
                guard aligned else { continue }
                let group = docGroup[s][target]
                if group >= 0 {
                    for slot in cursors.indices {
                        buffers[slot].removeAll(keepingCapacity: true)
                        var several = false
                        for cursor in cursors[slot] where cursor.doc == target {
                            if !buffers[slot].isEmpty { several = true }
                            cursor.positions(into: &buffers[slot])
                        }
                        if several { buffers[slot].sort() }
                        indexes[slot] = 0
                    }
                    occurrences: for start in buffers[0] {
                        for slot in 1..<buffers.count {
                            let wanted = start + UInt32(slot)
                            while indexes[slot] < buffers[slot].count && buffers[slot][indexes[slot]] < wanted { indexes[slot] += 1 }
                            if indexes[slot] >= buffers[slot].count { break occurrences }
                            if buffers[slot][indexes[slot]] != wanted { continue occurrences }
                        }
                        visit(group, target, start)
                    }
                }
                for slot in cursors.indices {
                    for term in cursors[slot].indices where cursors[slot][term].doc == target { cursors[slot][term].next() }
                }
            }
        }
    }

    // MARK: Snippets

    /// About this many characters of text around the densest body match.
    public static let snippetLength = 160

    /// The paper's body around its densest cluster of matches (most distinct clauses within a dozen words, then most
    /// matches), or nil when the hit has no body match or its text is unavailable.
    public func snippet(for hit: FullTextHit) -> FullTextSnippet? {
        guard !hit.bodyReferences.isEmpty, let text = texts?.body(group: hit.group) else { return nil }
        var matches: [(position: UInt32, length: UInt32, clause: UInt8)] = []
        var positions: [UInt32] = []
        for reference in hit.bodyReferences {
            if reference.length > 0 { matches.append((reference.at, reference.length, reference.clause)); continue }
            guard segments.indices.contains(Int(reference.segment)) else { continue }
            positions.removeAll(keepingCapacity: true)
            segments[Int(reference.segment)].positions(at: Int(reference.at), frequency: Int(min(reference.count, UInt32(FullTextRanking.snippetMatches))), into: &positions)
            for position in positions { matches.append((position, 1, reference.clause)) }
        }
        guard !matches.isEmpty else { return nil }
        matches.sort { $0.position < $1.position }
        var best = (start: 0, end: 0, score: -1)
        var end = 0
        for start in matches.indices {
            if end < start { end = start }
            while end + 1 < matches.count && matches[end + 1].position <= matches[start].position + 12 { end += 1 }
            var clauses: UInt64 = 0
            for index in start...end { clauses |= 1 << UInt64(matches[index].clause) }
            let score = clauses.nonzeroBitCount * 1_000 + (end - start + 1)
            if score > best.score { best = (start, end, score) }
        }
        let window = matches[best.start...best.end]
        var highlighted = Set<UInt32>()
        for match in window { for offset in 0..<max(1, match.length) { highlighted.insert(match.position + offset) } }
        guard let firstPosition = window.first?.position, let lastPosition = window.map({ $0.position + max(1, $0.length) - 1 }).max() else { return nil }
        return text.snippet(firstMatch: firstPosition, lastMatch: lastPosition, highlighted: highlighted, length: Self.snippetLength)
    }
}

/// Reads one term's postings in document order.
struct PostingCursor {
    let bytes: UnsafeBufferPointer<UInt8>
    var offset: Int
    let end: Int
    private(set) var doc = Int.max
    private(set) var frequency = 0
    private(set) var positionsAt = 0
    private var base = 0

    init(bytes: UnsafeBufferPointer<UInt8>, offset: Int, end: Int) {
        self.bytes = bytes; self.offset = offset; self.end = end
        next()
    }

    mutating func next() {
        guard offset < end else { doc = Int.max; return }
        base += Int(VarInt.read(bytes, &offset))
        doc = base
        frequency = Int(VarInt.read(bytes, &offset))
        positionsAt = offset
        VarInt.skip(bytes, &offset, count: frequency)
    }

    mutating func advance(to target: Int) { while doc < target { next() } }

    func positions(into out: inout [UInt32]) {
        var offset = positionsAt, position: UInt32 = 0
        for _ in 0..<frequency {
            position &+= UInt32(truncatingIfNeeded: VarInt.read(bytes, &offset))
            out.append(position)
        }
    }
}

