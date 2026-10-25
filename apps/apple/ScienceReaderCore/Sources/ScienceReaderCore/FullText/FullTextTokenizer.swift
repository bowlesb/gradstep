import Foundation

/// Words for the on-device full-text index (docs/architecture/NATIVE_LIBRARY_SEARCH.md, "Full-text index").
///
/// A word is a run of letters, digits and combining marks. Case, diacritics and width are folded ("Café" → "cafe",
/// "ﬁne" → "fine"); an apostrophe inside a word is dropped ("don't" → "dont"); a "." or "," between digits stays
/// ("2106.09685", "0.5"); a soft hyphen is ignored. A hyphenated compound ("self-attention") gives each part its own
/// position and also its joined form ("selfattention") at the first part's position, so "self-attention",
/// "self attention" and "selfattention" find each other. A light English plural stemmer runs on plain ASCII letters
/// ("networks" → "network", "studies" → "study", "matches" → "match"). Index and query use the same rules.
///
/// Version 2 (2026-10-25, docs/architecture/GLOBAL_SEARCH.md "Tokenizer v2") reads scientific text: a Greek letter is its
/// name ("α", "ϵ", "\alpha" and "alpha" are all `alpha`; a capital too: "Σ" is `sigma`); ∇ ∂ ∞ ∑ ∏ ∫ are words of their own
/// (`nabla`, `partial`, `infinity`, `sum`, `prod`, `integral`); a LaTeX command (a word right after a backslash) that only
/// lays out or decorates (`\mathrm`, `\top`, `\frac`, `\left`, `\cdot`…) is dropped without taking a position, so
/// "\mathrm{softmax}(QK^\top)" is `softmax qk`; and a word splits where a Greek letter meets a Latin letter or digit
/// ("α̅ₜ" is `alpha t`, "θ2" is `theta 2`).
public enum FullTextTokenizer {
    /// Any change to these rules changes this number; a stored index of another version is rebuilt.
    public static let version = 2
    /// Longer words (base64, hashes, long formulas) are skipped; they still take a position.
    public static let maximumTermBytes = 64
    /// Compounds of more parts than this keep their parts only.
    static let maximumJoinedParts = 6

    public struct Token: Equatable, Sendable {
        /// The folded (and, unless asked otherwise, stemmed) term.
        public let term: String
        /// The word's ordinal in the text; a joined compound shares its first part's.
        public let position: Int
        /// UTF-8 byte offsets of the word (of the whole compound for a joined form) in the input.
        public let start: Int
        public let end: Int
        public let joined: Bool
        /// A name given to a symbol (a Greek letter, ∇, a LaTeX command): never a prefix of a longer word while typing.
        public let mapped: Bool
        init(term: String, position: Int, start: Int, end: Int, joined: Bool, mapped: Bool = false) {
            self.term = term; self.position = position; self.start = start; self.end = end; self.joined = joined; self.mapped = mapped
        }
    }

    // MARK: Symbols (version 2)

    /// Greek letters (folded: lower case, variants and math alphabets already mapped by NFKC) by name.
    static let greekNames: [Unicode.Scalar: String] = [
        "α": "alpha", "β": "beta", "γ": "gamma", "δ": "delta", "ε": "epsilon", "ζ": "zeta", "η": "eta", "θ": "theta",
        "ι": "iota", "κ": "kappa", "λ": "lambda", "μ": "mu", "ν": "nu", "ξ": "xi", "ο": "omicron", "π": "pi", "ρ": "rho",
        "σ": "sigma", "ς": "sigma", "τ": "tau", "υ": "upsilon", "φ": "phi", "χ": "chi", "ψ": "psi", "ω": "omega",
    ]
    /// Mathematical operators that are words of their own.
    static let symbolNames: [Unicode.Scalar: String] = [
        "\u{2207}": "nabla", "\u{2202}": "partial", "\u{221E}": "infinity", "\u{2211}": "sum", "\u{220F}": "prod",
        "\u{222B}": "integral", "\u{222C}": "integral", "\u{222E}": "integral",
    ]
    /// LaTeX commands with another name: Greek variants and the operators above, so `\varepsilon`, `ϵ` and "epsilon" agree.
    static let commandNames: [String: String] = [
        "varepsilon": "epsilon", "vartheta": "theta", "varphi": "phi", "varsigma": "sigma", "varpi": "pi", "varrho": "rho",
        "varkappa": "kappa", "infty": "infinity", "int": "integral", "iint": "integral", "iiint": "integral", "oint": "integral",
        "upalpha": "alpha", "upbeta": "beta", "upmu": "mu", "uppi": "pi",
    ]
    /// LaTeX commands that only lay out, space, decorate or relate: dropped (their arguments stay). Named functions and
    /// symbols (`\log`, `\exp`, `\max`, `\nabla`, `\partial`, `\sum`, Greek letters) are kept as words.
    static let layoutCommands: Set<String> = [
        "mathrm", "mathbf", "mathit", "mathcal", "mathbb", "mathsf", "mathtt", "mathfrak", "mathscr", "boldsymbol", "bm",
        "operatorname", "text", "textrm", "textbf", "textit", "textsf", "texttt", "mbox", "emph", "displaystyle", "textstyle",
        "scriptstyle", "left", "right", "middle", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr",
        "frac", "dfrac", "tfrac", "cfrac", "sqrt", "top", "intercal", "quad", "qquad", "cdot", "cdots", "ldots", "dots", "vdots",
        "ddots", "times", "hat", "widehat", "tilde", "widetilde", "bar", "overline", "underline", "vec", "dot", "ddot", "prime",
        "overbrace", "underbrace", "begin", "end", "label", "tag", "nonumber", "notag", "limits", "nolimits", "hspace", "vspace",
        "le", "leq", "ge", "geq", "ne", "neq", "approx", "sim", "simeq", "equiv", "propto", "in", "notin", "subset", "subseteq",
        "to", "rightarrow", "leftarrow", "Rightarrow", "Leftarrow", "leftrightarrow", "mapsto", "mid", "vert", "Vert", "lvert",
        "rvert", "lVert", "rVert", "langle", "rangle", "lfloor", "rfloor", "lceil", "rceil", "odot", "otimes", "oplus", "circ",
        "ast", "star", "pm", "mp", "cdotp", "colon", "coloneqq", "triangleq", "forall", "exists", "land", "lor", "neg",
        "cup", "cap", "setminus", "emptyset", "varnothing", "ll", "gg", "lesssim", "gtrsim", "stackrel", "overset", "underset",
        "substack", "phantom", "hphantom", "vphantom", "mathop", "mathbin", "mathrel", "kern", "mkern", "hbox", "boxed",
    ]

    /// Which alphabet a word character belongs to, for the Greek | Latin split.
    enum Script: Equatable { case greek, other, mark }
    static func script(_ scalar: Unicode.Scalar) -> Script {
        let v = scalar.value
        if (0x0370...0x03FF).contains(v) || (0x1F00...0x1FFF).contains(v) || (0x1D6A8...0x1D7C9).contains(v) || v == 0x00B5 { return .greek }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return .mark
        default: return .other
        }
    }

    static let greekNameSet = Set(greekNames.values)

    /// The plural stemmer on a folded word (ASCII letters only; anything else unchanged).
    static func stemmed(_ word: String) -> String {
        guard word.utf8.count >= 4, word.utf8.last == 115, word.utf8.allSatisfy({ $0 >= 97 && $0 <= 122 }) else { return word }
        var bytes = Array(word.utf8)
        let count = bytes.withUnsafeMutableBufferPointer { stemmedCount($0) }
        return String(decoding: bytes[0..<count], as: UTF8.self)
    }

    /// A folded word's name when it is one Greek letter.
    static func greekName(_ folded: String) -> String? {
        var scalars = folded.unicodeScalars.makeIterator()
        guard let first = scalars.next(), scalars.next() == nil else { return nil }
        return greekNames[first]
    }

    /// Every token of `text`, in order.
    public static func tokens(_ text: String, stem: Bool = true) -> [Token] {
        var text = text
        return text.withUTF8 { bytes in
            var out: [Token] = []
            scan(bytes, stem: stem) { out.append($0); return true }
            return out
        }
    }

    /// Number of word positions in `text` (its length for ranking).
    public static func positionCount(_ text: String) -> Int {
        var text = text
        return text.withUTF8 { scan($0, stem: false) { _ in true } }
    }

    /// Visits each token from byte `start` (which must be a word start or a separator) with positions counted from
    /// `position`. `visit` returns false to stop. Returns the position after the last word scanned.
    @discardableResult
    /// `terms: false` skips folding (every token's `term` is empty): positions and byte ranges only.
    public static func scan(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int = 0, position: Int = 0, stem: Bool = true, terms: Bool = true,
                            _ visit: (Token) -> Bool) -> Int {
        var scanner = Scanner(bytes: bytes, index: start, position: position, stem: stem, terms: terms)
        while let more = scanner.nextGroup(visit) { if !more { break } }
        return scanner.position
    }

    /// The byte offset of each word group's start whose first position is a multiple of `every` or later than the
    /// previous checkpoint by at least `every`: where a snippet may resume tokenizing without the text before it.
    static func checkpoints(_ bytes: UnsafeBufferPointer<UInt8>, every: Int) -> [(position: Int, offset: Int)] {
        var scanner = Scanner(bytes: bytes, index: 0, position: 0, stem: false)
        var out: [(Int, Int)] = [(0, 0)]
        var next = every
        while true {
            let before = scanner.position
            let offset = scanner.skipToWord()
            guard offset < bytes.count else { break }
            // Never at a LaTeX command: resuming there without its backslash would read it as a word.
            if before >= next && !(offset > 0 && bytes[offset - 1] == 0x5C) { out.append((before, offset)); next = before + every }
            guard scanner.nextGroup({ _ in true }) != nil else { break }
        }
        return out
    }

    // MARK: - Folding and stemming

    /// Folds one word: ASCII by byte, anything else through Unicode compatibility mapping and case/diacritic/width
    /// folding. Returns nil for a word over the length limit or one that folds to nothing.
    static func fold(_ raw: UnsafeBufferPointer<UInt8>, ascii: Bool, stem: Bool) -> String? {
        if ascii {
            guard raw.count <= maximumTermBytes else { return nil }
            return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: raw.count) { buffer in
                var letters = true
                for index in 0..<raw.count {
                    var byte = raw[index]
                    if byte >= 65 && byte <= 90 { byte += 32 }
                    if !(byte >= 97 && byte <= 122) { letters = false }
                    buffer[index] = byte
                }
                let count = stem && letters ? stemmedCount(UnsafeMutableBufferPointer(rebasing: buffer[0..<raw.count])) : raw.count
                return String(decoding: UnsafeBufferPointer(rebasing: buffer[0..<count]), as: UTF8.self)
            }
        }
        let folded = String(decoding: raw, as: UTF8.self).precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var bytes = Array(folded.utf8.filter { $0 != 0x20 })
        guard !bytes.isEmpty, bytes.count <= maximumTermBytes else { return nil }
        if stem, bytes.allSatisfy({ $0 >= 97 && $0 <= 122 }) {
            let count = bytes.withUnsafeMutableBufferPointer { stemmedCount($0) }
            bytes.removeSubrange(count...)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The light plural stemmer on lowercase ASCII letters, in place; returns the new length.
    /// sses → ss; ies → y; ches/shes/xes/zes → drop "es"; s (not ss/us/is) → drop.
    static func stemmedCount(_ word: UnsafeMutableBufferPointer<UInt8>) -> Int {
        let n = word.count
        guard n >= 4, word[n - 1] == 115 /* s */ else { return n }
        func ends(_ suffix: StaticString) -> Bool {
            let count = suffix.utf8CodeUnitCount
            guard n >= count else { return false }
            return suffix.withUTF8Buffer { s in (0..<count).allSatisfy { word[n - count + $0] == s[$0] } }
        }
        if ends("sses") { return n - 2 }
        if ends("ies") { if n >= 5 { word[n - 3] = 121 /* y */; return n - 2 }; return n }
        if ends("ches") || ends("shes") || ends("xes") || ends("zes") { return n - 2 }
        if ends("ss") || ends("us") || ends("is") { return n }
        return n - 1
    }

    // MARK: - Scanner

    struct Scanner {
        let bytes: UnsafeBufferPointer<UInt8>
        var index: Int
        var position: Int
        let stem: Bool
        var terms = true

        /// Advances to the next word character (or a symbol that is a word: ∇, ∂…); returns its offset (or the end).
        mutating func skipToWord() -> Int {
            while index < bytes.count {
                let (scalar, length) = decode(at: index)
                if Self.isWordStart(scalar) || FullTextTokenizer.symbolNames[scalar] != nil { return index }
                index += length
            }
            return index
        }

        static func isASCIILetter(_ byte: UInt8) -> Bool { (byte >= 97 && byte <= 122) || (byte >= 65 && byte <= 90) }

        /// Reused between groups: the folded-input bytes of the current group and its parts' bounds.
        private var raw: [UInt8] = []
        private var parts: [(start: Int, end: Int, rawStart: Int, rawEnd: Int, ascii: Bool)] = []

        init(bytes: UnsafeBufferPointer<UInt8>, index: Int, position: Int, stem: Bool, terms: Bool = true) {
            self.bytes = bytes; self.index = index; self.position = position; self.stem = stem; self.terms = terms
            raw.reserveCapacity(64); parts.reserveCapacity(8)
        }

        /// The tokens of the next word group (a word, or a hyphenated compound), or nil at the end.
        mutating func nextGroup() -> [Token]? {
            var tokens: [Token] = []
            guard nextGroup({ tokens.append($0); return true }) != nil else { return nil }
            return tokens
        }

        /// Visits the next word group's tokens. Returns nil at the end, false when `visit` asked to stop.
        mutating func nextGroup(_ visit: (Token) -> Bool) -> Bool? {
            while true {
                guard skipToWord() < bytes.count else { return nil }
                let groupStart = index
                let (lead, leadLength) = decode(at: index)
                // ∇, ∂, ∞, ∑, ∏, ∫: one word each.
                if let name = FullTextTokenizer.symbolNames[lead] {
                    index += leadLength
                    let at = position
                    position += 1
                    return visit(Token(term: terms ? name : "", position: at, start: groupStart, end: index, joined: false, mapped: true))
                }
                // A LaTeX command: the letters after a backslash. Layout commands are dropped (no token, no position).
                if groupStart > 0, bytes[groupStart - 1] == 0x5C, Self.isASCIILetter(bytes[groupStart]) {
                    var end = groupStart
                    while end < bytes.count && Self.isASCIILetter(bytes[end]) { end += 1 }
                    index = end
                    let slice = UnsafeBufferPointer(rebasing: bytes[groupStart..<end])
                    let name = String(decoding: slice, as: UTF8.self)
                    if FullTextTokenizer.layoutCommands.contains(name) { continue }
                    let at = position
                    position += 1
                    guard terms else { return visit(Token(term: "", position: at, start: groupStart, end: end, joined: false)) }
                    let folded = name.lowercased()
                    if let mapped = FullTextTokenizer.commandNames[name] ?? FullTextTokenizer.commandNames[folded]
                        ?? (FullTextTokenizer.greekNameSet.contains(folded) ? folded : nil) {
                        return visit(Token(term: mapped, position: at, start: groupStart, end: end, joined: false, mapped: true))
                    }
                    guard let term = FullTextTokenizer.fold(slice, ascii: true, stem: stem) else { return true }
                    return visit(Token(term: term, position: at, start: groupStart, end: end, joined: false))
                }
                return wordGroup(groupStart, visit)
            }
        }

        /// A word, or a hyphenated compound, from `groupStart`.
        private mutating func wordGroup(_ groupStart: Int, _ visit: (Token) -> Bool) -> Bool {
            raw.removeAll(keepingCapacity: true); parts.removeAll(keepingCapacity: true)
            var partStart = index, partEnd = index, rawStart = 0, ascii = true
            var previous: Unicode.Scalar = " "
            var hyphenated = false
            // Greek | Latin: a word ends where the alphabet changes ("αt" is two words).
            var script: FullTextTokenizer.Script?
            while index < bytes.count {
                let lead = bytes[index]
                // ASCII letters and digits: the common case.
                if lead < 0x80 {
                    if (lead >= 97 && lead <= 122) || (lead >= 65 && lead <= 90) || (lead >= 48 && lead <= 57) {
                        if script == .greek && raw.count > rawStart { break }
                        script = .other
                        raw.append(lead); index += 1; partEnd = index; previous = Unicode.Scalar(lead); continue
                    }
                }
                let (scalar, length) = decode(at: index)
                if lead >= 0x80, Self.isWordCharacter(scalar) {
                    let kind = FullTextTokenizer.script(scalar)
                    if kind != .mark {
                        if let script, script != kind, raw.count > rawStart { break }
                        script = kind
                    }
                    for offset in 0..<length { raw.append(bytes[index + offset]) }
                    ascii = false; index += length; partEnd = index; previous = scalar
                    continue
                }
                if scalar == "\u{00AD}" { index += length; continue }
                let next = index + length < bytes.count ? decode(at: index + length).0 : " "
                if (scalar == "'" || scalar == "\u{2019}") && previous.properties.isAlphabetic && next.properties.isAlphabetic {
                    index += length; continue
                }
                if (scalar == "." || scalar == ",") && Self.isDigit(previous) && Self.isDigit(next) {
                    raw.append(UInt8(scalar.value)); index += length; previous = scalar; continue
                }
                if (scalar == "-" || scalar == "\u{2010}" || scalar == "\u{2011}") && raw.count > rawStart && Self.isWordStart(next) {
                    parts.append((partStart, partEnd, rawStart, raw.count, ascii))
                    rawStart = raw.count; ascii = true; script = nil
                    index += length; partStart = index; partEnd = index; previous = scalar; hyphenated = true
                    continue
                }
                break
            }
            if raw.count > rawStart { parts.append((partStart, partEnd, rawStart, raw.count, ascii)) }
            let first = position, stem = stem, terms = terms
            let joinable = hyphenated && parts.count >= 2 && parts.count <= FullTextTokenizer.maximumJoinedParts
            let parts = parts, raw = raw
            position = first + parts.count
            return raw.withUnsafeBufferPointer { rawBytes -> Bool in
                // Each part's term (a Greek letter as its name), and unstemmed for the joined form.
                var plain: [String?] = []
                var mapped: [Bool] = []
                if terms {
                    for part in parts {
                        let slice = UnsafeBufferPointer(rebasing: rawBytes[part.rawStart..<part.rawEnd])
                        let folded = FullTextTokenizer.fold(slice, ascii: part.ascii, stem: false)
                        let name = part.ascii ? nil : folded.flatMap(FullTextTokenizer.greekName)
                        plain.append(name ?? folded); mapped.append(name != nil)
                    }
                }
                for (offset, part) in parts.enumerated() {
                    let term: String?
                    if !terms { term = "" }
                    else if mapped[offset] || !stem { term = plain[offset] }
                    else { term = plain[offset].map(FullTextTokenizer.stemmed) }
                    if let term, !visit(Token(term: term, position: first + offset, start: part.start, end: part.end, joined: false,
                                              mapped: terms && mapped[offset])) { return false }
                    if offset == 0 && joinable {
                        let whole: String?
                        if !terms { whole = "" } else if plain.contains(where: { $0 == nil }) { whole = nil } else {
                            let joined = plain.compactMap { $0 }.joined()
                            whole = joined.utf8.count <= FullTextTokenizer.maximumTermBytes ? (stem ? FullTextTokenizer.stemmed(joined) : joined) : nil
                        }
                        if let whole, !visit(Token(term: whole, position: first, start: groupStart, end: parts[parts.count - 1].end, joined: true)) { return false }
                    }
                }
                return true
            }
        }

        func decode(at offset: Int) -> (Unicode.Scalar, Int) {
            let lead = bytes[offset]
            if lead < 0x80 { return (Unicode.Scalar(lead), 1) }
            let length = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
            guard length > 1, offset + length <= bytes.count else { return ("\u{FFFD}", 1) }
            var value = UInt32(lead) & (length == 2 ? 0x1F : length == 3 ? 0x0F : 0x07)
            for index in 1..<length {
                let byte = bytes[offset + index]
                guard byte & 0xC0 == 0x80 else { return ("\u{FFFD}", 1) }
                value = value << 6 | UInt32(byte & 0x3F)
            }
            return (Unicode.Scalar(value) ?? "\u{FFFD}", length)
        }

        static func isDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 48 && scalar.value <= 57 }

        static func isWordStart(_ scalar: Unicode.Scalar) -> Bool {
            if scalar.isASCII {
                let v = scalar.value
                return (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
            }
            let properties = scalar.properties
            return properties.isAlphabetic || properties.numericType != nil
        }

        static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
            if scalar.isASCII { return isWordStart(scalar) }
            if isWordStart(scalar) { return true }
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return true
            default: return false
            }
        }
    }
}

/// A parsed search: words and quoted phrases, every one required (AND). The last word, while it is still being typed
/// (no space after it), also matches longer words it begins ("transfo" → "transformer").
public struct FullTextQuery: Equatable, Sendable {
    /// One position of a sequence: any of these exact terms, or any indexed term starting with `prefix`.
    public struct Slot: Equatable, Sendable {
        public var terms: [String]
        public var prefix: String?
    }
    /// One required part of the query. It matches a document when any of its sequences does (a sequence of one slot
    /// is a word; longer ones are phrases). `text` is what the reader typed, for metadata substring matching.
    public struct Clause: Equatable, Sendable {
        public let text: String
        public let sequences: [[Slot]]
        public let phrase: Bool
    }
    public static let maximumClauses = 16
    /// A prefix shorter than this matches only the exact word.
    public static let minimumPrefixBytes = 2

    public let clauses: [Clause]
    public var isEmpty: Bool { clauses.isEmpty }

    public init(_ query: String) {
        var clauses: [Clause] = []
        var segment = "", quoted = false
        func flush(closed: Bool, last: Bool) {
            if quoted { Self.addPhrase(segment, prefix: last && !closed, to: &clauses) }
            else { Self.addWords(segment, prefixLast: last, to: &clauses) }
            segment = ""
        }
        let characters = Array(query)
        for (offset, character) in characters.enumerated() {
            if character == "\"" || character == "\u{201C}" || character == "\u{201D}" {
                flush(closed: true, last: false)
                quoted.toggle()
            } else { segment.append(character) }
            _ = offset
        }
        let endsOpen = characters.last.map { !$0.isWhitespace && $0 != "\"" && $0 != "\u{201C}" && $0 != "\u{201D}" } ?? false
        flush(closed: false, last: endsOpen)
        self.clauses = Array(clauses.prefix(Self.maximumClauses))
    }

    private static func addWords(_ text: String, prefixLast: Bool, to clauses: inout [Clause]) {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        for (index, word) in words.enumerated() {
            let prefix = prefixLast && index == words.count - 1
            clauses.append(Clause(text: word, sequences: sequences(word, prefix: prefix, phrase: false), phrase: false))
        }
    }

    private static func addPhrase(_ text: String, prefix: Bool, to clauses: inout [Clause]) {
        let trimmed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !trimmed.isEmpty else { return }
        clauses.append(Clause(text: trimmed, sequences: sequences(trimmed, prefix: prefix, phrase: true), phrase: true))
    }

    /// The word's parts in order as one sequence, and its joined compound as another; a phrase keeps parts only.
    private static func sequences(_ text: String, prefix: Bool, phrase: Bool) -> [[Slot]] {
        let stemmed = FullTextTokenizer.tokens(text, stem: true)
        let plain = FullTextTokenizer.tokens(text, stem: false)
        guard stemmed.count == plain.count else { return [] }
        let partIndexes = stemmed.indices.filter { !stemmed[$0].joined }
        var result: [[Slot]] = []
        if !partIndexes.isEmpty {
            var slots = partIndexes.map { Slot(terms: [stemmed[$0].term], prefix: nil) }
            // A symbol's name (α as `alpha`) is the whole word, never the start of a longer one.
            if prefix, let last = partIndexes.last, !stemmed[last].mapped, plain[last].term.utf8.count >= minimumPrefixBytes { slots[slots.count - 1].prefix = plain[last].term }
            // Positions skipped by an over-long word break a phrase there; keep the sequence contiguous by
            // requiring consecutive positions only between kept parts.
            result.append(slots)
        }
        if !phrase, let joined = stemmed.indices.first(where: { stemmed[$0].joined }) {
            var slot = Slot(terms: [stemmed[joined].term], prefix: nil)
            if prefix, plain[joined].term.utf8.count >= minimumPrefixBytes { slot.prefix = plain[joined].term }
            result.append([slot])
        }
        return result
    }
}
