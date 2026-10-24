import Compression
import Foundation

/// A paper's body text as the index saw it, for snippets: UTF-8 in independently compressed 16 KB blocks (a
/// snippet decodes one or two), with tokenizer resume points every 32 words. Kept sealed on disk (`txt-ID.bin`).
struct FullTextBodyText: Sendable {
    static let blockSize = 16_384
    static let checkpointEvery = 32
    private static let magic = Array("GST2".utf8)

    let length: Int
    /// (position, byte offset) pairs, increasing.
    let checkpoints: [(position: Int, offset: Int)]
    private let blocks: [UInt8]
    /// blockCount + 1 offsets into `blocks`; a block stored uncompressed has `stored` set.
    private let blockOffsets: [Int]
    private let stored: [Bool]

    /// The encoded, compressed form of `text` (what `prepare` seals).
    static func encode(_ text: String) -> Data {
        var text = text
        let raw = Array(text.utf8)
        let points = text.withUTF8 { FullTextTokenizer.checkpoints($0, every: checkpointEvery) }
        var out = Data()
        func u32(_ value: Int) { var v = UInt32(value).littleEndian; withUnsafeBytes(of: &v) { out.append(contentsOf: $0) } }
        out.append(contentsOf: magic)
        u32(raw.count); u32(points.count)
        for point in points { u32(point.position); u32(point.offset) }
        var compressed: [UInt8] = [], offsets: [Int] = [0], kinds: [UInt8] = []
        var scratch = [UInt8](repeating: 0, count: blockSize + 1_024)
        raw.withUnsafeBufferPointer { source in
            var start = 0
            while start < raw.count {
                let count = min(blockSize, raw.count - start)
                let written = scratch.withUnsafeMutableBufferPointer { destination in
                    compression_encode_buffer(destination.baseAddress!, destination.count, source.baseAddress! + start, count, nil, COMPRESSION_LZFSE)
                }
                if written > 0 && written < count { compressed.append(contentsOf: scratch[0..<written]); kinds.append(0) }
                else { compressed.append(contentsOf: source[start..<start + count]); kinds.append(1) }
                offsets.append(compressed.count)
                start += count
            }
        }
        u32(kinds.count)
        for offset in offsets { u32(offset) }
        out.append(contentsOf: kinds)
        out.append(contentsOf: compressed)
        return out
    }

    static func decode(_ data: Data) throws -> FullTextBodyText {
        try data.withUnsafeBytes { raw -> FullTextBodyText in
            let bytes = raw.bindMemory(to: UInt8.self)
            var offset = 4
            func u32() throws -> Int {
                guard offset + 4 <= bytes.count else { throw FullTextIndexError.corrupt }
                defer { offset += 4 }
                return Int(UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24)
            }
            guard bytes.count >= 12, Array(bytes[0..<4]) == magic else { throw FullTextIndexError.corrupt }
            let length = try u32(), count = try u32()
            guard count <= bytes.count / 8 else { throw FullTextIndexError.corrupt }
            var points: [(Int, Int)] = []
            points.reserveCapacity(count)
            for _ in 0..<count { points.append((try u32(), try u32())) }
            let blockCount = try u32()
            guard blockCount == (length + blockSize - 1) / blockSize, blockCount <= bytes.count else { throw FullTextIndexError.corrupt }
            var offsets: [Int] = []
            for _ in 0...blockCount { offsets.append(try u32()) }
            guard offset + blockCount <= bytes.count else { throw FullTextIndexError.corrupt }
            let stored = bytes[offset..<offset + blockCount].map { $0 == 1 }
            offset += blockCount
            let blocks = Array(bytes[offset...])
            guard offsets.first == 0, offsets.last == blocks.count, zip(offsets, offsets.dropFirst()).allSatisfy({ $0 <= $1 }),
                  points.allSatisfy({ $0.1 <= length }) else { throw FullTextIndexError.corrupt }
            return FullTextBodyText(length: length, checkpoints: points, blocks: blocks, blockOffsets: offsets, stored: stored)
        }
    }

    private init(length: Int, checkpoints: [(position: Int, offset: Int)], blocks: [UInt8], blockOffsets: [Int], stored: [Bool]) {
        self.length = length; self.checkpoints = checkpoints; self.blocks = blocks; self.blockOffsets = blockOffsets; self.stored = stored
    }

    /// The text's bytes in `range` (clamped), decoding only the blocks it touches.
    func bytes(_ range: Range<Int>) -> [UInt8] {
        let lower = max(0, range.lowerBound), upper = min(length, range.upperBound)
        guard lower < upper else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(upper - lower)
        var scratch = [UInt8](repeating: 0, count: Self.blockSize)
        for block in (lower / Self.blockSize)...((upper - 1) / Self.blockSize) {
            let blockStart = block * Self.blockSize, blockLength = min(Self.blockSize, length - blockStart)
            let from = max(lower, blockStart) - blockStart, to = min(upper, blockStart + blockLength) - blockStart
            let source = blockOffsets[block]..<blockOffsets[block + 1]
            if stored[block] {
                out.append(contentsOf: blocks[source.lowerBound + from..<source.lowerBound + to])
                continue
            }
            let decoded = scratch.withUnsafeMutableBufferPointer { destination in
                blocks.withUnsafeBufferPointer { compressed in
                    compression_decode_buffer(destination.baseAddress!, blockLength, compressed.baseAddress! + source.lowerBound, source.count, nil, COMPRESSION_LZFSE)
                }
            }
            guard decoded == blockLength else { return [] }
            out.append(contentsOf: scratch[from..<to])
        }
        return out
    }

    /// Text around positions `firstMatch`…`lastMatch`, the `highlighted` positions marked.
    func snippet(firstMatch: UInt32, lastMatch: UInt32, highlighted: Set<UInt32>, length budget: Int) -> FullTextSnippet? {
        // Resume a few words before the match, at the checkpoint before that.
        let lead = Int(firstMatch) >= 6 ? Int(firstMatch) - 6 : 0
        var low = 0, high = checkpoints.count
        while low < high { let middle = (low + high) / 2; if checkpoints[middle].position <= lead { low = middle + 1 } else { high = middle } }
        let checkpoint = checkpoints[max(0, low - 1)]
        // 32 words to the lead, a dozen matched, 40 after: a few KB at most; more only for very long words.
        let base = checkpoint.offset
        let window = bytes(base..<(base + 6_144))
        guard !window.isEmpty else { return nil }
        var words: [(position: Int, start: Int, end: Int)] = []
        window.withUnsafeBufferPointer { buffer in
            FullTextTokenizer.scan(buffer, position: checkpoint.position, terms: false) { token in
                guard !token.joined else { return true }
                if token.position >= lead { words.append((token.position, token.start, token.end)) }
                return token.position <= Int(lastMatch) + 40
            }
        }
        guard let firstWord = words.first(where: { $0.position == Int(firstMatch) }) else { return nil }
        // Start up to ~40 bytes before the match, at a word; end at a word near the length budget.
        let start = words.first(where: { $0.start >= firstWord.start - 40 && $0.position <= Int(firstMatch) })?.start ?? firstWord.start
        let lastWord = words.last(where: { $0.position == Int(lastMatch) }) ?? firstWord
        var end = lastWord.end
        for word in words where word.position > Int(lastMatch) {
            if word.end - start > budget * 5 / 4 { break }
            end = word.end
            if word.end - start >= budget { break }
        }
        // Pieces between highlights, whitespace collapsed; ranges in UTF-16.
        var text = base + start > 0 ? "…" : ""
        var lastIsSpace = true
        func append(_ from: Int, _ to: Int) {
            guard to > from else { return }
            for character in String(decoding: window[from..<to], as: UTF8.self) {
                if character.isWhitespace { if !lastIsSpace { text.append(" "); lastIsSpace = true } }
                else { text.append(character); lastIsSpace = false }
            }
        }
        var highlights: [Range<Int>] = []
        var cursor = start, index = 0
        let inside = words.filter { $0.start >= start && $0.end <= end }
        while index < inside.count {
            let word = inside[index]
            guard highlighted.contains(UInt32(word.position)) else { index += 1; continue }
            // A run of highlighted consecutive words (a phrase) is one highlight.
            var last = index
            while last + 1 < inside.count && highlighted.contains(UInt32(inside[last + 1].position)) && inside[last + 1].position == inside[last].position + 1 { last += 1 }
            append(cursor, word.start)
            let from = text.utf16.count
            append(word.start, inside[last].end)
            highlights.append(from..<text.utf16.count)
            cursor = inside[last].end
            index = last + 1
        }
        append(cursor, end)
        if text.hasSuffix(" ") { text.removeLast() }
        if base + end < length { text += "…" }
        return highlights.isEmpty ? nil : FullTextSnippet(text: text, highlights: highlights)
    }
}
