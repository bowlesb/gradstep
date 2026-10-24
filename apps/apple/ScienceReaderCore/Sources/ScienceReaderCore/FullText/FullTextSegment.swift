import Foundation

/// Fields a document may have, in their position order. Ranking weighs them differently (`FullTextRanking`).
public enum FullTextField: Int, CaseIterable, Sendable {
    case title, authors, tags, abstract, notes, body
}

/// A library paper is two documents: its metadata (small, changes with tags and notes) and its body (large, changes
/// only with its reading). Both share the paper's `group`; search and ranking work per group.
public enum FullTextPart: UInt8, Sendable, Codable {
    case metadata = 0, body = 1
}

public struct FullTextDocumentID: Hashable, Sendable, Codable {
    public let group: String
    public let part: FullTextPart
    public init(group: String, part: FullTextPart) { self.group = group; self.part = part }
}

/// What to index: a document's fields and the caller's fingerprint of them (unchanged fingerprint, no reindex).
public struct FullTextDocument: Sendable {
    public let id: FullTextDocumentID
    public let fingerprint: String
    public let fields: [FullTextField: String]
    public init(id: FullTextDocumentID, fingerprint: String, fields: [FullTextField: String]) {
        self.id = id; self.fingerprint = fingerprint; self.fields = fields
    }
}

/// One immutable inverted index over a few documents: a sorted term dictionary and, per term, its postings
/// (document, frequency, positions; delta and variable-length encoded). Fields are consecutive position ranges of a
/// document, two positions apart so a phrase never spans two fields.
final class FullTextSegment: @unchecked Sendable {
    struct Doc: Equatable {
        let id: FullTextDocumentID
        /// Per field (FullTextField order): first position and number of positions.
        let starts: [UInt32]
        let lengths: [UInt32]
        func field(at position: UInt32) -> FullTextField {
            var field = FullTextField.title
            for candidate in FullTextField.allCases where lengths[candidate.rawValue] > 0 && position >= starts[candidate.rawValue] { field = candidate }
            return field
        }
    }

    static let magic: [UInt8] = Array("GSF1".utf8)
    static let fieldGap: UInt32 = 2

    let docs: [Doc]
    /// termCount + 1 offsets into `termBytes` and `postings`.
    let termOffsets: [UInt32]
    let postingOffsets: [UInt32]
    let documentFrequencies: [UInt32]
    let termBytes: [UInt8]
    let postings: [UInt8]
    var termCount: Int { documentFrequencies.count }
    var byteCount: Int { termBytes.count + postings.count + termOffsets.count * 8 + documentFrequencies.count * 4 }

    init(docs: [Doc], termOffsets: [UInt32], postingOffsets: [UInt32], documentFrequencies: [UInt32], termBytes: [UInt8], postings: [UInt8]) {
        self.docs = docs; self.termOffsets = termOffsets; self.postingOffsets = postingOffsets
        self.documentFrequencies = documentFrequencies; self.termBytes = termBytes; self.postings = postings
    }

    // MARK: Lookup

    func term(_ index: Int) -> String {
        termBytes.withUnsafeBufferPointer { String(decoding: UnsafeBufferPointer(rebasing: $0[Int(termOffsets[index])..<Int(termOffsets[index + 1])]), as: UTF8.self) }
    }

    /// Byte order of the term at `index` against `key`.
    private func compare(_ index: Int, _ key: UnsafeBufferPointer<UInt8>, prefixOnly: Bool = false) -> Int {
        let start = Int(termOffsets[index]), end = Int(termOffsets[index + 1])
        return termBytes.withUnsafeBufferPointer { bytes in
            let length = end - start, common = min(length, key.count)
            let order = common == 0 ? 0 : memcmp(bytes.baseAddress! + start, key.baseAddress!, common)
            if order != 0 { return Int(order) }
            if prefixOnly && length >= key.count { return 0 }
            return length - key.count
        }
    }

    /// First term index not ordered before `key`.
    private func lowerBound(_ key: UnsafeBufferPointer<UInt8>) -> Int {
        var low = 0, high = termCount
        while low < high {
            let middle = (low + high) / 2
            if compare(middle, key) < 0 { low = middle + 1 } else { high = middle }
        }
        return low
    }

    func find(_ term: String) -> Int? {
        var term = term
        return term.withUTF8 { key in
            let index = lowerBound(key)
            return index < termCount && compare(index, key) == 0 ? index : nil
        }
    }

    /// Term indexes beginning with `prefix`.
    func prefixRange(_ prefix: String) -> Range<Int> {
        var prefix = prefix
        return prefix.withUTF8 { key in
            let start = lowerBound(key)
            var end = start
            // Exponential then binary search for the end of the run.
            var step = 1
            while end + step <= termCount && compare(end + step - 1, key, prefixOnly: true) == 0 { end += step; step *= 2 }
            var low = end, high = min(termCount, end + step)
            while low < high {
                let middle = (low + high) / 2
                if compare(middle, key, prefixOnly: true) == 0 { low = middle + 1 } else { high = middle }
            }
            return start..<low
        }
    }

    /// Visits each posting of term `index`: document, frequency and the offset of its positions in `postings`.
    @inline(__always)
    func forEachPosting(_ index: Int, _ visit: (_ doc: Int, _ frequency: Int, _ positionsAt: Int) -> Void) {
        postings.withUnsafeBufferPointer { bytes in
            var offset = Int(postingOffsets[index])
            let end = Int(postingOffsets[index + 1])
            var doc = 0
            while offset < end {
                doc += Int(VarInt.read(bytes, &offset))
                let frequency = Int(VarInt.read(bytes, &offset))
                visit(doc, frequency, offset)
                VarInt.skip(bytes, &offset, count: frequency)
            }
        }
    }

    /// Decodes `frequency` positions starting at `offset`.
    @inline(__always)
    func positions(at offset: Int, frequency: Int, into out: inout [UInt32]) {
        postings.withUnsafeBufferPointer { bytes in
            var offset = offset, position: UInt32 = 0
            for _ in 0..<frequency {
                position &+= UInt32(truncatingIfNeeded: VarInt.read(bytes, &offset))
                out.append(position)
            }
        }
    }

    // MARK: Building

    /// Indexes documents into a new segment. `positions(of:)` of a body document gives the token positions the text
    /// store's checkpoints refer to (fields before the body are empty in a body document, so they start at 0).
    static func build(_ documents: [FullTextDocument]) -> FullTextSegment {
        var termIDs: [String: Int32] = [:]
        var terms: [String] = []
        var builders: [PostingList] = []
        var docs: [Doc] = []
        docs.reserveCapacity(documents.count)
        var pairs: [UInt64] = []
        for (docIndex, document) in documents.enumerated() {
            pairs.removeAll(keepingCapacity: true)
            var starts = [UInt32](repeating: 0, count: FullTextField.allCases.count)
            var lengths = starts
            var next: UInt32 = 0
            for field in FullTextField.allCases {
                starts[field.rawValue] = next
                guard var fieldText = document.fields[field], !fieldText.isEmpty else { continue }
                let base = Int(next)
                let end = fieldText.withUTF8 { bytes in
                    FullTextTokenizer.scan(bytes, position: base) { token in
                        let id: Int32
                        if let known = termIDs[token.term] { id = known } else {
                            id = Int32(terms.count); termIDs[token.term] = id; terms.append(token.term); builders.append(PostingList())
                        }
                        pairs.append(UInt64(UInt32(bitPattern: id)) << 32 | UInt64(UInt32(token.position)))
                        return true
                    }
                }
                lengths[field.rawValue] = UInt32(end - base)
                next = UInt32(end) + (end > base ? fieldGap : 0)
            }
            docs.append(Doc(id: document.id, starts: starts, lengths: lengths))
            pairs.sort()
            var index = 0
            while index < pairs.count {
                let id = Int(pairs[index] >> 32)
                var end = index
                while end < pairs.count && Int(pairs[end] >> 32) == id { end += 1 }
                builders[id].append(doc: docIndex, positions: pairs[index..<end].lazy.map { UInt32(truncatingIfNeeded: $0) })
                index = end
            }
        }
        let order = terms.indices.sorted { terms[$0].utf8.lexicographicallyPrecedes(terms[$1].utf8) }
        var termOffsets: [UInt32] = [0], postingOffsets: [UInt32] = [0], frequencies: [UInt32] = []
        var termBytes: [UInt8] = [], postings: [UInt8] = []
        termOffsets.reserveCapacity(order.count + 1); postingOffsets.reserveCapacity(order.count + 1); frequencies.reserveCapacity(order.count)
        for id in order {
            termBytes.append(contentsOf: terms[id].utf8); termOffsets.append(UInt32(termBytes.count))
            postings.append(contentsOf: builders[id].bytes); postingOffsets.append(UInt32(postings.count))
            frequencies.append(builders[id].documents)
        }
        return FullTextSegment(docs: docs, termOffsets: termOffsets, postingOffsets: postingOffsets,
                               documentFrequencies: frequencies, termBytes: termBytes, postings: postings)
    }

    struct PostingList {
        var bytes: [UInt8] = []
        var documents: UInt32 = 0
        var lastDoc = 0
        mutating func append<Positions: Sequence>(doc: Int, positions: Positions) where Positions.Element == UInt32 {
            let list = Array(positions)
            VarInt.write(UInt64(doc - lastDoc), to: &bytes)
            VarInt.write(UInt64(list.count), to: &bytes)
            var previous: UInt32 = 0
            for position in list { VarInt.write(UInt64(position - previous), to: &bytes); previous = position }
            lastDoc = doc; documents += 1
        }
    }

    /// The live documents of `segments` (in order) in one segment. `live(segment, doc)` says which survive.
    /// Returns the new segment and, per input segment, each old document's new index (nil when dropped).
    static func merge(_ segments: [FullTextSegment], live: (Int, Int) -> Bool) -> (FullTextSegment, [[Int?]]) {
        var mapping: [[Int?]] = []
        var docs: [Doc] = []
        for (s, segment) in segments.enumerated() {
            var map: [Int?] = []
            map.reserveCapacity(segment.docs.count)
            for (d, doc) in segment.docs.enumerated() {
                if live(s, d) { map.append(docs.count); docs.append(doc) } else { map.append(nil) }
            }
            mapping.append(map)
        }
        var cursors = [Int](repeating: 0, count: segments.count)
        var termOffsets: [UInt32] = [0], postingOffsets: [UInt32] = [0], frequencies: [UInt32] = []
        var termBytes: [UInt8] = [], postings: [UInt8] = []
        while true {
            // The smallest current term across segments (few segments: a linear scan).
            var smallest: Int?
            for s in segments.indices where cursors[s] < segments[s].termCount {
                guard let current = smallest else { smallest = s; continue }
                if segments[s].termOrder(cursors[s], against: segments[current], cursors[current]) < 0 { smallest = s }
            }
            guard let first = smallest else { break }
            let termStart = Int(segments[first].termOffsets[cursors[first]]), termEnd = Int(segments[first].termOffsets[cursors[first] + 1])
            let before = postings.count
            var documents: UInt32 = 0, lastDoc = 0
            var participants: [Int] = []
            for s in segments.indices where cursors[s] < segments[s].termCount &&
                (s == first || segments[s].termOrder(cursors[s], against: segments[first], cursors[first]) == 0) {
                participants.append(s)
            }
            for s in participants {
                let segment = segments[s], map = mapping[s]
                segment.postings.withUnsafeBufferPointer { bytes in
                    var offset = Int(segment.postingOffsets[cursors[s]])
                    let end = Int(segment.postingOffsets[cursors[s] + 1])
                    var doc = 0
                    while offset < end {
                        doc += Int(VarInt.read(bytes, &offset))
                        let frequency = VarInt.read(bytes, &offset)
                        let positionsStart = offset
                        VarInt.skip(bytes, &offset, count: Int(frequency))
                        guard let newDoc = map[doc] else { continue }
                        VarInt.write(UInt64(newDoc - lastDoc), to: &postings)
                        VarInt.write(frequency, to: &postings)
                        postings.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[positionsStart..<offset]))
                        lastDoc = newDoc; documents += 1
                    }
                }
                cursors[s] += 1
            }
            guard documents > 0 else { postings.removeSubrange(before...); continue }
            termBytes.append(contentsOf: segments[first].termBytes[termStart..<termEnd])
            termOffsets.append(UInt32(termBytes.count)); postingOffsets.append(UInt32(postings.count)); frequencies.append(documents)
        }
        return (FullTextSegment(docs: docs, termOffsets: termOffsets, postingOffsets: postingOffsets,
                                documentFrequencies: frequencies, termBytes: termBytes, postings: postings), mapping)
    }

    private func termOrder(_ index: Int, against other: FullTextSegment, _ otherIndex: Int) -> Int {
        let start = Int(termOffsets[index]), end = Int(termOffsets[index + 1])
        let otherStart = Int(other.termOffsets[otherIndex]), otherEnd = Int(other.termOffsets[otherIndex + 1])
        return termBytes.withUnsafeBufferPointer { a in
            other.termBytes.withUnsafeBufferPointer { b in
                let length = end - start, otherLength = otherEnd - otherStart, common = min(length, otherLength)
                let order = common == 0 ? 0 : Int(memcmp(a.baseAddress! + start, b.baseAddress! + otherStart, common))
                return order != 0 ? order : length - otherLength
            }
        }
    }

    // MARK: Encoding

    func encoded() -> Data {
        var out = Data()
        out.reserveCapacity(byteCount + docs.count * 64 + 64)
        out.append(contentsOf: Self.magic)
        func u32(_ value: Int) { var v = UInt32(value).littleEndian; withUnsafeBytes(of: &v) { out.append(contentsOf: $0) } }
        func array(_ values: [UInt32]) { values.withUnsafeBufferPointer { buffer in
            #if _endian(little)
            out.append(UnsafeBufferPointer(start: UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: UInt8.self), count: buffer.count * 4))
            #else
            for value in buffer { u32(Int(value)) }
            #endif
        } }
        u32(docs.count); u32(termCount); u32(termBytes.count); u32(postings.count)
        for doc in docs {
            let key = Array(doc.id.group.utf8)
            u32(key.count); out.append(contentsOf: key); out.append(doc.id.part.rawValue)
            array(doc.starts); array(doc.lengths)
        }
        array(termOffsets); array(postingOffsets); array(documentFrequencies)
        out.append(contentsOf: termBytes); out.append(contentsOf: postings)
        return out
    }

    static func decode(_ data: Data) throws -> FullTextSegment {
        try data.withUnsafeBytes { raw -> FullTextSegment in
            let bytes = raw.bindMemory(to: UInt8.self)
            var offset = 0
            func need(_ count: Int) throws { guard count >= 0, offset + count <= bytes.count else { throw FullTextIndexError.corrupt } }
            func u32() throws -> Int {
                try need(4)
                let value = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
                offset += 4
                return Int(value)
            }
            func array(_ count: Int) throws -> [UInt32] {
                try need(count * 4)
                var out = [UInt32](repeating: 0, count: count)
                out.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + count * 4])) }
                #if !_endian(little)
                for index in out.indices { out[index] = UInt32(littleEndian: out[index]) }
                #endif
                offset += count * 4
                return out
            }
            try need(4)
            guard Array(bytes[0..<4]) == magic else { throw FullTextIndexError.corrupt }
            offset = 4
            let docCount = try u32(), termCount = try u32(), termByteCount = try u32(), postingByteCount = try u32()
            guard docCount <= 1_000_000, termCount <= 50_000_000 else { throw FullTextIndexError.corrupt }
            let fieldCount = FullTextField.allCases.count
            var docs: [Doc] = []
            docs.reserveCapacity(docCount)
            for _ in 0..<docCount {
                let keyLength = try u32()
                try need(keyLength + 1)
                let group = String(decoding: UnsafeBufferPointer(rebasing: bytes[offset..<offset + keyLength]), as: UTF8.self)
                offset += keyLength
                guard let part = FullTextPart(rawValue: bytes[offset]) else { throw FullTextIndexError.corrupt }
                offset += 1
                docs.append(Doc(id: FullTextDocumentID(group: group, part: part), starts: try array(fieldCount), lengths: try array(fieldCount)))
            }
            let termOffsets = try array(termCount + 1), postingOffsets = try array(termCount + 1), frequencies = try array(termCount)
            try need(termByteCount + postingByteCount)
            let termBytes = Array(bytes[offset..<offset + termByteCount]); offset += termByteCount
            let postings = Array(bytes[offset..<offset + postingByteCount]); offset += postingByteCount
            guard offset == bytes.count, termOffsets.first == 0, postingOffsets.first == 0,
                  Int(termOffsets[termCount]) == termByteCount, Int(postingOffsets[termCount]) == postingByteCount,
                  zip(termOffsets, termOffsets.dropFirst()).allSatisfy({ $0 <= $1 }),
                  zip(postingOffsets, postingOffsets.dropFirst()).allSatisfy({ $0 <= $1 }) else { throw FullTextIndexError.corrupt }
            return FullTextSegment(docs: docs, termOffsets: termOffsets, postingOffsets: postingOffsets,
                                   documentFrequencies: frequencies, termBytes: termBytes, postings: postings)
        }
    }
}

enum VarInt {
    @inline(__always)
    static func write(_ value: UInt64, to out: inout [UInt8]) {
        var value = value
        while value >= 0x80 { out.append(UInt8(truncatingIfNeeded: value) | 0x80); value >>= 7 }
        out.append(UInt8(value))
    }

    /// Reads one value; a truncated or over-long value ends the buffer (the caller's bounds stop it).
    @inline(__always)
    static func read(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: inout Int) -> UInt64 {
        var value: UInt64 = 0, shift: UInt64 = 0
        while offset < bytes.count {
            let byte = bytes[offset]; offset += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return value }
            shift += 7
            if shift > 63 { break }
        }
        return value
    }

    @inline(__always)
    static func skip(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: inout Int, count: Int) {
        var remaining = count
        while remaining > 0 && offset < bytes.count {
            if bytes[offset] < 0x80 { remaining -= 1 }
            offset += 1
        }
    }
}

public enum FullTextIndexError: Error, Equatable, Sendable {
    case corrupt, closed, storageUnavailable, invalidKey
}
