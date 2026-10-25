import Accelerate
import Foundation

// "Filter + related" for a Library tag (owner, TestFlight 92: "filter++ … try to include a bit more stuff that is related
// even if not tagged necessarily"): the tagged papers, then the library's untagged papers that are very close to them by
// their public fingerprints, or whose title or abstract uses the tag's words as a phrase. Worked out on the device from
// what it already holds (the interest index's library fingerprints and the papers' own metadata); nothing new is sent
// anywhere. Design and measurements: docs/architecture/INTEREST_INDEX.md ("Related papers for a tag").

public enum TagRelated {
    /// A library paper as the rule needs it.
    public struct Paper: Sendable, Equatable {
        /// The caller's row ID.
        public let id: String
        public let title: String
        public let abstract: String
        /// The paper's public fingerprint (unit length); nil for an uploaded PDF, or before its fingerprint arrives.
        public let vector: [Float]?
        public init(id: String, title: String, abstract: String, vector: [Float]?) {
            self.id = id; self.title = title; self.abstract = abstract; self.vector = vector
        }
    }

    /// Why an untagged paper is listed with the tagged ones.
    public struct Reason: Sendable, Equatable {
        /// How many tagged papers its fingerprint is very close to (0 when it joined by its words).
        public let closeTo: Int
        /// The tag as the reason quotes it, when the paper's title or abstract uses its words as a phrase.
        public let mentions: String?
        public init(closeTo: Int, mentions: String?) { self.closeTo = closeTo; self.mentions = mentions }

        /// One quiet line: "Mentions “on-policy distillation”", "Related to 4 tagged papers", or both.
        public var text: String {
            let close = closeTo == 1 ? "related to 1 tagged paper" : "related to \(closeTo) tagged papers"
            switch (mentions, closeTo > 0) {
            case (let phrase?, true): return "Mentions “\(phrase)” · \(close)"
            case (let phrase?, false): return "Mentions “\(phrase)”"
            default: return close.prefix(1).uppercased() + close.dropFirst()
            }
        }
    }

    /// Measured on the owner's library, the public fixture library and 1,000-paper libraries drawn from the staging pool
    /// (docs/architecture/INTEREST_INDEX.md "Related papers for a tag"): a paper close to just one tagged paper was usually
    /// that paper's neighbour in another respect (a video paper's for a distillation tag; another LLM-agent paper in a
    /// library full of them), even at 0.90; close to two or more, it was mostly the tag's subject.
    public struct Settings: Sendable, Equatable {
        /// "Close": the Feed's "Close in topic" (RelatedPapers.Settings.closeSimilarity; pairs at 0.88–0.90 in the staging
        /// pool were the same line of work about 10 times in 12, and 0.858 is the 99th percentile of random pairs).
        public var closeSimilarity: Float = 0.88
        /// A paper close to at least this many tagged papers joins.
        public var closeCount = 2
        /// The words rule is left out for a phrase in more of the pool's papers than this (the term statistics' document
        /// frequency): "real-world" (9.6 % of the staging pool) or "fine-tuning" (6.9 %) in an abstract says little, as the
        /// Feed's related papers ignore topics on more than 5 %.
        public var commonPhraseShare = 0.05
        public init() {}
    }

    /// The untagged `candidates` that join `tag`'s papers, with why. Fingerprints: close to two or more tagged papers.
    /// Words: the tag as a phrase in the title or abstract (a one-word tag only in the title, where a single word says what
    /// the paper is about), unless the phrase is common in the pool (`terms`, when the device has them). A paper without a
    /// fingerprint can join only by its words.
    public static func select(tag: String, tagged: [Paper], candidates: [Paper], terms: InterestTerms? = nil,
                              settings: Settings = Settings()) -> [String: Reason] {
        let phrase = TagPhrase(tag).flatMap { phrase in
            terms.flatMap { phrase.poolShare($0) }.map { $0 <= settings.commonPhraseShare ? phrase : nil } ?? phrase
        }
        let anchors = tagged.compactMap(\.vector).filter { $0.count == InterestQ8.dimension }
        var out: [String: Reason] = [:]
        for paper in candidates {
            var close = 0
            if anchors.count >= settings.closeCount, let vector = paper.vector, vector.count == InterestQ8.dimension {
                for anchor in anchors where similarity(vector, anchor) >= settings.closeSimilarity { close += 1 }
            }
            let near = close >= settings.closeCount
            let mentions = phrase.map { $0.occurs(title: paper.title, abstract: paper.abstract) } ?? false
            guard near || mentions else { continue }
            out[paper.id] = Reason(closeTo: near ? close : 0, mentions: mentions ? phrase?.quoted : nil)
        }
        return out
    }

    /// Cosine similarity of two unit-length fingerprints.
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var result: Float = 0
        a.withUnsafeBufferPointer { x in b.withUnsafeBufferPointer { y in
            vDSP_dotpr(x.baseAddress!, 1, y.baseAddress!, 1, &result, vDSP_Length(a.count))
        } }
        return result
    }
}

/// A tag's words as a phrase in a paper's text: case, diacritics and width folded; hyphens and other punctuation
/// separate words, so "On-policy distillation" meets "on policy distillation" and "On-Policy Distillation"; the last word
/// also as its plural or singular ("model" and "models", "strategy" and "strategies").
public struct TagPhrase: Sendable, Equatable {
    public let words: [String]
    /// The last word's forms.
    let lastForms: Set<String>
    /// The tag as the reason quotes it: lower case, unless its first word is an acronym ("KV cache", "LoRA adapters").
    public let quoted: String

    /// The tag's share of the pool's papers by the term statistics (their tokenizer: stop words dropped, hyphenated words
    /// kept whole), or nil when the statistics don't list it (in fewer than 3 pool papers, more than 10 %, or longer than
    /// three words).
    public func poolShare(_ terms: InterestTerms) -> Double? {
        guard terms.corpusPapers > 0 else { return nil }
        let tokens = InterestPhrases.tokens(source, stopWords: terms.stopWords)
        guard !tokens.isEmpty, tokens.count <= 3, let index = terms.find(tokens.joined(separator: " ")) else { return nil }
        return Double(terms.documentFrequency(index)) / Double(terms.corpusPapers)
    }

    /// The tag as given (trimmed).
    let source: String
    /// The word looked for before a text is split (`mightOccur`).
    let probe: String

    /// Nil for a tag the text rule can't use: generic ("Machine learning", "Reasoning", the Feed's most common topics such
    /// as "Fine-tuning"), or one word under three letters.
    public init?(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = Self.words(trimmed).map(String.init)
        guard let last = words.last, PaperKeywords.distinctive(trimmed), !RelatedPapers.genericTopics.contains(trimmed.lowercased()),
              words.count > 1 || last.count >= 3 else { return nil }
        source = trimmed
        self.words = words
        lastForms = Self.forms(last)
        let sorted = lastForms.sorted()
        var stem = sorted.first ?? last
        for form in sorted.dropFirst() { while !form.hasPrefix(stem) { stem.removeLast() } }
        probe = (words.dropLast() + [stem]).max { $0.count < $1.count } ?? stem
        quoted = Self.lowercasedKeepingAcronyms(trimmed)
    }

    public var isSingleWord: Bool { words.count == 1 }

    /// In the title; a phrase of two or more words also in the abstract.
    public func occurs(title: String, abstract: String) -> Bool {
        if mightOccur(in: title), occurs(in: Self.words(title)) { return true }
        return !isSingleWord && mightOccur(in: abstract) && occurs(in: Self.words(abstract))
    }

    /// A quick look before the text is split into words: its longest word (the last one without its ending) appears.
    private func mightOccur(in text: String) -> Bool {
        text.range(of: probe, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }

    public func occurs(in text: [Substring]) -> Bool {
        let n = words.count
        guard text.count >= n else { return false }
        for start in 0 ... text.count - n {
            var matched = true
            for offset in 0 ..< n - 1 where text[start + offset] != words[offset] { matched = false; break }
            if matched, lastForms.contains(String(text[start + n - 1])) { return true }
        }
        return false
    }

    /// Lower case, except the words with two or more capitals ("KV", "LLM", "LoRA", "ActionOPD"): "Multi-Agent" →
    /// "multi-agent", "LLM-Based" → "LLM-based".
    static func lowercasedKeepingAcronyms(_ text: String) -> String {
        var out = "", piece = ""
        func flush() { out += piece.filter(\.isUppercase).count >= 2 ? piece : piece.lowercased(); piece = "" }
        for character in text {
            if character.isLetter || character.isNumber { piece.append(character) } else { flush(); out.append(character) }
        }
        flush()
        return out
    }

    /// A word and its plural or singular, by the common English endings (a wrong guess only adds a form no text uses).
    static func forms(_ word: String) -> Set<String> {
        var forms: Set<String> = [word]
        let long = word.count > 3
        if long, word.hasSuffix("ies") { forms.insert(String(word.dropLast(3)) + "y") }
        else if long, ["sses", "ches", "shes", "xes"].contains(where: word.hasSuffix) { forms.insert(String(word.dropLast(2))) }
        else if long, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") { forms.insert(String(word.dropLast())) }
        else if word.count > 2, word.hasSuffix("y"), let before = word.dropLast().last, !"aeiou".contains(before) { forms.insert(String(word.dropLast()) + "ies") }
        else if ["s", "x", "ch", "sh"].contains(where: word.hasSuffix) { forms.insert(word + "es") }
        else if word.last?.isLetter == true { forms.insert(word + "s") }
        return forms
    }

    /// Lower-case, folded letter and number runs.
    public static func words(_ text: String) -> [Substring] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }
}
