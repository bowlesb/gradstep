import Foundation

// "Related papers" under a Feed paper's details (owner, 2026-10-24: "Async, it could start a search for related papers
// below using a heuristic we come up with"). Computed on the device only: from the interest index's pool fingerprints,
// which every device downloads identically, or, when the index isn't served, from the Feed results already here. The
// opened paper's identifier is never sent anywhere for this. Thresholds and their evidence: docs/architecture/
// PERSONALIZED_FEED.md ("Related papers").

/// What the device knows about a paper (a Feed result, or a record this device read from arXiv).
public struct RelatedPaperFacts: Sendable, Equatable {
    public let sourceID: String
    public let title: String
    public let authors: [String]
    public let topics: [String]
    public init(sourceID: String, title: String, authors: [String], topics: [String]) {
        self.sourceID = InterestPool.key(sourceID); self.title = title; self.authors = authors; self.topics = topics
    }
    public init(_ result: DiscoveryResult) {
        self.init(sourceID: result.sourceID, title: result.title, authors: result.authors, topics: result.topics)
    }
}

/// Why a paper is listed, in a short phrase.
public enum RelatedReason: Sendable, Equatable {
    case veryClose, close, sameAuthor(String), sharesTopic(String)
    public var text: String {
        switch self {
        case .veryClose: "Very close in topic"
        case .close: "Close in topic"
        case .sameAuthor(let name): "Same authors: \(name)"
        case .sharesTopic(let topic): "Shares \(topic)"
        }
    }
}

public struct RelatedPaper: Sendable, Equatable, Identifiable {
    public let sourceID: String
    public let score: Double
    /// Cosine similarity of the fingerprints; nil when ranked from Feed results alone.
    public let similarity: Double?
    public let reason: RelatedReason
    public var id: String { sourceID }
}

public enum RelatedPapers {
    /// Calibrated on the staging pool's 14-day window (8,230 papers, q8; 2026-10-24): pairs at 0.88–0.90 were the same line
    /// of work about 10 times in 12, at 0.86–0.88 about 3 in 12 (6 in 12 when they share a specific topic), and 0.858 is the
    /// 99th percentile of random pairs.
    public struct Settings: Sendable, Equatable {
        /// Shown on closeness alone at or above this ("Close in topic").
        public var closeSimilarity: Float = 0.88
        /// From here up to `closeSimilarity`, shown only with a shared specific topic or a rare shared author.
        public var minimumSimilarity: Float = 0.86
        /// "Very close in topic" at or above this (For you's "Like …" uses 0.90).
        public var veryCloseSimilarity: Float = 0.92
        /// Two or more shared authors admit a paper down to this (a single shared name below 0.86 was mostly another
        /// subject or a namesake).
        public var authorsFloor: Float = 0.84
        /// Added to the score for shared authors.
        public var authorBoost: Double = 0.03
        /// Added per shared specific topic, at most `topicBoostMax`.
        public var topicBoost: Double = 0.01
        public var topicBoostMax: Double = 0.02
        /// A single shared name counts as one person's only when the known papers carry it at most this often (namesakes:
        /// in the window Hao Wang is on 28 papers, Yang Liu on 26).
        public var rareAuthorMaxPapers = 3
        /// At or above this a paper is the same work under another identifier and is left out (no two distinct pool papers
        /// reached 0.98; the one pair at 0.975 was one paper submitted twice).
        public var duplicateSimilarity: Float = 0.97
        /// Nearest papers kept for the second step (metadata, boosts).
        public var candidates = 40
        public var limit = 10
        public init() {}
    }

    // MARK: Fingerprints (the interest index's pool)

    /// The pool papers nearest the opened one, best first: never the paper itself, `excluded` (the reader's library) or a
    /// near-duplicate of the paper or of a better candidate. Nil when the paper isn't in the pool's window.
    public static func nearest(to sourceID: String, in pool: InterestPool, excluding excluded: Set<String>,
                               settings: Settings = Settings()) -> [(sourceID: String, similarity: Float)]? {
        guard let row = pool.row(of: sourceID), let query = pool.vector(of: sourceID) else { return nil }
        let excludedKeys = Set(excluded.map(InterestPool.key))
        let similarity = pool.similarities(to: query)
        let floor = min(settings.authorsFloor, settings.minimumSimilarity)
        var hits: [(row: Int, similarity: Float)] = []
        for (i, s) in similarity.enumerated() where i != row && s >= floor && s < settings.duplicateSimilarity
            && !excludedKeys.contains(pool.sourceIDs[i]) {
            hits.append((i, s))
        }
        hits.sort { $0.similarity == $1.similarity ? $0.row < $1.row : $0.similarity > $1.similarity }
        var kept: [(row: Int, similarity: Float)] = []
        for hit in hits where kept.count < settings.candidates {
            // Another identifier of a better candidate's work (a resubmission, a near-identical companion).
            if kept.contains(where: { pool.similarity($0.row, hit.row) >= settings.duplicateSimilarity }) { continue }
            kept.append(hit)
        }
        return kept.map { (pool.sourceIDs[$0.row], $0.similarity) }
    }

    /// The nearest papers with what the device knows about them, boosted and explained, best first. Papers the device
    /// knows nothing about can't be shown and are left out.
    public static func rank(opened: RelatedPaperFacts, nearest: [(sourceID: String, similarity: Float)],
                            facts: [String: RelatedPaperFacts], authorPapers: (String) -> Int, generic: Set<String> = [],
                            settings: Settings = Settings()) -> [RelatedPaper] {
        let openedAuthors = authorKeys(opened.authors)
        let openedTopics = specificTopicSet(opened.topics, generic: generic)
        var out: [RelatedPaper] = []
        for (id, similarity) in nearest {
            guard let paper = facts[InterestPool.key(id)], paper.sourceID != opened.sourceID,
                  !isSameTitle(paper.title, opened.title) else { continue }
            let shared = specificTopics(paper.topics, generic: generic).filter { openedTopics.contains($0.lowercased()) }
            // Two or more shared names from 0.84; one rare name from 0.86.
            var author: String?
            if let found = sharedAuthors(paper.authors, openedAuthors, authorPapers: authorPapers, settings: settings) {
                if found.count >= 2 ? similarity >= settings.authorsFloor : found.rare && similarity >= settings.minimumSimilarity {
                    author = found.name
                }
            }
            guard similarity >= settings.closeSimilarity || author != nil
                    || (similarity >= settings.minimumSimilarity && !shared.isEmpty) else { continue }
            var score = Double(similarity)
            if author != nil { score += settings.authorBoost }
            score += min(settings.topicBoostMax, settings.topicBoost * Double(shared.count))
            let reason: RelatedReason = if let author { .sameAuthor(author) }
                else if similarity >= settings.veryCloseSimilarity { .veryClose }
                else if let topic = shared.first { .sharesTopic(topic) }
                else { .close }
            out.append(RelatedPaper(sourceID: paper.sourceID, score: score, similarity: Double(similarity), reason: reason))
        }
        return Array(out.sorted { $0.score == $1.score ? $0.sourceID < $1.sourceID : $0.score > $1.score }.prefix(settings.limit))
    }

    // MARK: Without fingerprints (the Feed results on this device)

    /// The Feed results here, ranked by shared specific topics and shared authors. A paper needs a shared specific topic,
    /// or two or more shared authors: with no closeness to check it, one rare name alone was too often a namesake or
    /// another subject in the calibration.
    public static func rankByMetadata(opened: RelatedPaperFacts, candidates: [RelatedPaperFacts], excluding excluded: Set<String>,
                                      authorPapers: (String) -> Int, generic: Set<String> = [], settings: Settings = Settings()) -> [RelatedPaper] {
        let excludedKeys = Set(excluded.map(InterestPool.key))
        let openedAuthors = authorKeys(opened.authors)
        let openedTopics = specificTopicSet(opened.topics, generic: generic)
        var seen: Set<String> = [opened.sourceID]
        var out: [RelatedPaper] = []
        for paper in candidates where !excludedKeys.contains(paper.sourceID) && seen.insert(paper.sourceID).inserted
            && !isSameTitle(paper.title, opened.title) {
            let topics = specificTopics(paper.topics, generic: generic)
            let shared = topics.filter { openedTopics.contains($0.lowercased()) }
            var author: String?
            if let found = sharedAuthors(paper.authors, openedAuthors, authorPapers: authorPapers, settings: settings),
               found.count >= 2 || (found.rare && !shared.isEmpty) {
                author = found.name
            }
            guard author != nil || !shared.isEmpty else { continue }
            // Shared topics as a share of both papers' topics (Jaccard), so one shared topic of two counts for more than one
            // of six; shared authors count for a whole match.
            let union = Set(topics.map { $0.lowercased() }).union(openedTopics).count
            let score = (author != nil ? 1 : 0) + (union > 0 ? Double(shared.count) / Double(union) : 0)
            let reason: RelatedReason = if let author { .sameAuthor(author) } else { .sharesTopic(shared[0]) }
            out.append(RelatedPaper(sourceID: paper.sourceID, score: score, similarity: nil, reason: reason))
        }
        return Array(out.sorted { $0.score == $1.score ? $0.sourceID < $1.sourceID : $0.score > $1.score }.prefix(settings.limit))
    }

    // MARK: Pieces

    /// Areas ("Machine learning", "Computer vision"…) and the topics on more than 5 % of the pool's window (measured
    /// 2026-10-24: Large language models 33 %, Reasoning 13 %, Evaluation 10 %, AI agents 9 %, Fine-tuning 9 %,
    /// Vision-language models 9 %, Transformers 7.5 %) say little about closeness.
    public static let genericTopics: Set<String> = Set(TagVocabulary.tags.filter { $0.kind == .area }.map { $0.name.lowercased() })
        .union(["large language models", "reasoning", "evaluation", "ai agents", "fine-tuning", "vision-language models", "transformers"])

    /// Topics that aren't generic, in order; `generic` adds the topics most of the known papers have.
    static func specificTopics(_ topics: [String], generic: Set<String>) -> [String] {
        topics.filter { !genericTopics.contains($0.lowercased()) && !generic.contains($0.lowercased()) }
    }
    static func specificTopicSet(_ topics: [String], generic: Set<String>) -> Set<String> {
        Set(specificTopics(topics, generic: generic).map { $0.lowercased() })
    }

    /// Topics on more than `share` of the known papers (at least `minimum` papers known): too common here to say much.
    public static func commonTopics(_ papers: [RelatedPaperFacts], share: Double = 0.3, minimum: Int = 10) -> Set<String> {
        guard papers.count >= minimum else { return [] }
        var counts: [String: Int] = [:]
        for paper in papers { for topic in Set(paper.topics.map { $0.lowercased() }) { counts[topic, default: 0] += 1 } }
        return Set(counts.filter { Double($0.value) > share * Double(papers.count) }.keys)
    }

    /// How many of the known papers carry each name (normalised): the namesake check.
    public static func authorCounts(_ papers: [RelatedPaperFacts]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for paper in papers { for name in Set(paper.authors.map(normalizedName)) where !name.isEmpty { counts[name, default: 0] += 1 } }
        return counts
    }

    private static func authorKeys(_ authors: [String]) -> [String: String] {
        Dictionary(authors.map { (normalizedName($0), $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The names `authors` shares with the opened paper: how many, the rarest (as the opened paper writes it) and whether it
    /// is rare among the known papers (one person, not namesakes). Nil when none is shared. A one-word or initial-only
    /// name ("Wang", "J. Li") never counts: it can't tell people apart.
    static func sharedAuthors(_ authors: [String], _ opened: [String: String], authorPapers: (String) -> Int,
                              settings: Settings) -> (name: String, count: Int, rare: Bool)? {
        var names: [(name: String, key: String)] = []
        for author in authors {
            let key = normalizedName(author)
            guard !key.isEmpty, let name = opened[key], !names.contains(where: { $0.key == key }) else { continue }
            let parts = key.split(separator: " ")
            guard parts.count >= 2, parts.contains(where: { $0.count >= 3 }), parts[0].count >= 2, parts[parts.count - 1].count >= 2 else { continue }
            names.append((name, key))
        }
        guard let rarest = names.min(by: { authorPapers($0.key) < authorPapers($1.key) }) else { return nil }
        return (rarest.name, names.count, authorPapers(rarest.key) <= settings.rareAuthorMaxPapers)
    }

    /// Lower case, diacritics folded, punctuation dropped, single spaces: "José  García-López" → "jose garcia lopez".
    public static func normalizedName(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return String(folded.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// The same title in other words of case and spacing (another identifier of the same work).
    static func isSameTitle(_ a: String, _ b: String) -> Bool { normalizedName(a) == normalizedName(b) }
}
