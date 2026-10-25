import Foundation

// The interest index's term statistics (`gradstep-terms/1`, docs/architecture/INTEREST_INDEX.md §3): every 1–3-gram in
// at least 3 pool papers and at most 10 % of them, with its document frequency and "conceptness" (how much closer the
// phrase's own embedding is to the papers using it than to the whole pool; terms of art pass at ≥ 0.02). The device
// counts phrases in its own papers with the same tokenizer (`InterestPhrases`) and looks them up here: TF-IDF and
// log-odds run on the device, against the public pool's statistics, so no private text leaves it.

public struct InterestTerms: Sendable {
    public let version: Int
    /// Pool papers the frequencies were counted over (N for IDF).
    public let corpusPapers: Int
    /// Σ df over every shipped phrase: the background total log-odds needs.
    public let totalDF: Int
    public let conceptMinimum: Double
    public let stopWords: Set<String>
    /// Phrases sorted bytewise (UTF-8), with their frequencies and conceptness (thousandths).
    private let phrases: [String]
    private let frequencies: [Int32]
    private let concept: [Int8]

    public var count: Int { phrases.count }

    public init(version: Int = 0, corpusPapers: Int, totalDF: Int? = nil, conceptMinimum: Double = 0.02, stopWords: Set<String>,
                entries: [(phrase: String, df: Int, conceptness: Double)]) {
        let sorted = entries.sorted { $0.phrase.utf8.lexicographicallyPrecedes($1.phrase.utf8) }
        self.version = version; self.corpusPapers = corpusPapers; self.conceptMinimum = conceptMinimum; self.stopWords = stopWords
        phrases = sorted.map(\.phrase); frequencies = sorted.map { Int32($0.df) }
        concept = sorted.map { Int8(max(-127, min(127, ($0.conceptness * 1000).rounded()))) }
        self.totalDF = totalDF ?? sorted.reduce(0) { $0 + $1.df }
    }

    /// The terms artifact (`kind: terms`).
    public init(_ artifact: InterestArtifact) throws {
        guard artifact.kind == .terms else { throw InterestArtifactError.header }
        let h = artifact.header
        guard case .number(let n)? = h["corpus_papers"], case .array(let stop)? = h["stop_words"] else { throw InterestArtifactError.header }
        var phrases: [String] = [], frequencies: [Int32] = [], concept: [Int8] = []
        let body = artifact.body
        try body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var at = 0, previous: [UInt8] = []
            while at < bytes.count {
                let shared = Int(bytes[at]); at += 1
                guard shared <= previous.count else { throw InterestArtifactError.truncated }
                var phrase = Array(previous.prefix(shared))
                while at < bytes.count, bytes[at] != 0 { phrase.append(bytes[at]); at += 1 }
                guard at < bytes.count else { throw InterestArtifactError.truncated }
                at += 1
                var df = 0, multiplier = 1, byte: UInt8 = 0x80
                while byte & 0x80 != 0 {
                    guard at < bytes.count, multiplier < 1 << 35 else { throw InterestArtifactError.truncated }
                    byte = bytes[at]; at += 1
                    df += Int(byte & 0x7f) * multiplier; multiplier *= 128
                }
                guard at < bytes.count else { throw InterestArtifactError.truncated }
                concept.append(Int8(bitPattern: bytes[at])); at += 1
                guard let text = String(bytes: phrase, encoding: .utf8) else { throw InterestArtifactError.header }
                phrases.append(text); frequencies.append(Int32(clamping: df))
                previous = phrase
            }
        }
        version = { if case .number(let v)? = h["version"] { Int(v) } else { 0 } }()
        corpusPapers = Int(n)
        totalDF = { if case .number(let t)? = h["total_df"] { Int(t) } else { frequencies.reduce(0) { $0 + Int($1) } } }()
        conceptMinimum = { if case .number(let c)? = h["concept_min"] { c } else { 0.02 } }()
        stopWords = Set(stop.compactMap { if case .string(let s) = $0 { s } else { nil } })
        self.phrases = phrases; self.frequencies = frequencies; self.concept = concept
    }

    /// The phrase's index, by binary search over the sorted phrases.
    public func find(_ phrase: String) -> Int? {
        var low = 0, high = phrases.count
        let key = Array(phrase.utf8)
        while low < high {
            let mid = (low + high) / 2
            let order = Self.compare(phrases[mid], key)
            if order == 0 { return mid }
            if order < 0 { low = mid + 1 } else { high = mid }
        }
        return nil
    }

    private static func compare(_ a: String, _ b: [UInt8]) -> Int {
        var ia = a.utf8.makeIterator(), ib = b.makeIterator()
        while true {
            switch (ia.next(), ib.next()) {
            case (nil, nil): return 0
            case (nil, _): return -1
            case (_, nil): return 1
            case (let x?, let y?): if x != y { return x < y ? -1 : 1 }
            }
        }
    }

    public func phrase(_ index: Int) -> String { phrases[index] }
    public func documentFrequency(_ index: Int) -> Int { Int(frequencies[index]) }
    public func conceptness(_ index: Int) -> Double { Double(concept[index]) / 1000 }
    public func isConcept(_ index: Int) -> Bool { conceptness(index) >= conceptMinimum - 1e-9 }

    /// Sublinear TF-IDF's IDF with the pool as the corpus (scikit-learn's smooth IDF, as terms.py).
    public func idf(_ index: Int) -> Double { log(Double(1 + corpusPapers) / Double(1 + documentFrequency(index))) + 1 }
}

/// The term statistics' tokenizer (scikit-learn `CountVectorizer` as `terms.py` and the server's `ngrams.ts` use it):
/// lowercase; tokens match `(?u)\b[a-zA-Z][a-zA-Z0-9\-]+\b` with Python's Unicode word boundaries; stop words are
/// removed before 1–3-grams are formed. tests/fixtures/interest/ngrams.json pins it against scikit-learn.
public enum InterestPhrases {
    /// A paper's metadata text: the title counts twice.
    public static func documentText(title: String, abstract: String) -> String { "\(title). \(title). \(abstract)" }

    /// Tokens after lowercasing and stop-word removal.
    public static func tokens(_ text: String, stopWords: Set<String>) -> [String] {
        let scalars = Array(text.lowercased().unicodeScalars)
        var out: [String] = []
        // Python's Unicode `\w`: letters, numbers and the underscore ([\p{L}\p{N}_], as ngrams.ts).
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < scalars.count else { return false }
            let s = scalars[i]
            if s.isASCII { return (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") || (s >= "0" && s <= "9") || s == "_" }
            switch s.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber: return true
            default: return false
            }
        }
        func boundary(_ i: Int) -> Bool { isWord(i - 1) != isWord(i) }
        func isHead(_ s: Unicode.Scalar) -> Bool { (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") }
        func isTail(_ s: Unicode.Scalar) -> Bool { isHead(s) || (s >= "0" && s <= "9") || s == "-" }
        var i = 0
        while i < scalars.count {
            guard isHead(scalars[i]), boundary(i) else { i += 1; continue }
            var j = i + 1
            while j < scalars.count, isTail(scalars[j]) { j += 1 }
            // Greedy, then back off to the longest end at a word boundary (at least two characters).
            var end = j, matched = false
            while end >= i + 2 {
                if boundary(end) { matched = true; break }
                end -= 1
            }
            if matched {
                let token = String(String.UnicodeScalarView(scalars[i ..< end]))
                if !stopWords.contains(token) { out.append(token) }
                i = end
            } else {
                i += 1
            }
        }
        return out
    }

    /// Every 1–3-gram of a token list, with repeats (scikit-learn's order: unigrams, then bigrams, then trigrams).
    public static func ngrams(_ words: [String]) -> [String] {
        var out = words
        for n in 2...3 where words.count >= n {
            for i in 0 ... words.count - n { out.append(words[i ..< i + n].joined(separator: " ")) }
        }
        return out
    }

    /// Occurrences of every phrase the term statistics hold, by phrase index.
    public static func counts(_ text: String, terms: InterestTerms) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for gram in ngrams(tokens(text, stopWords: terms.stopWords)) {
            if let t = terms.find(gram) { out[t, default: 0] += 1 }
        }
        return out
    }
}
