import Foundation

// The reader's library topics on the device (step 3): the papers with public fingerprints go into the interest state,
// the topic rule chooses topics, the term layer labels them, and the synced registry adds the reader's names, hidden
// flags and colours. Everything here is a pure function of (library, public map and term statistics, registry), so
// every device that holds the same inputs shows the same topics. Step 4 (For you in topic sections) reads `topics`
// (node IDs, papers and `centroid(of:)`) from here; nothing else needs to change for it.

/// A library paper as the topics need it.
public struct InterestLibraryPaper: Sendable, Equatable {
    /// The library row's paper ID (what the list filters by).
    public let id: UUID
    /// Public identifier key (`InterestPool.key`); nil for an uploaded or device PDF (no public fingerprint).
    public let key: String?
    public let title: String
    public let abstract: String
    public let weight: InterestWeights.Inputs
    public init(id: UUID, key: String?, title: String, abstract: String, weight: InterestWeights.Inputs) {
        self.id = id; self.key = key.map(InterestPool.key); self.title = title; self.abstract = abstract; self.weight = weight
    }
}

/// A public fingerprint from `v1_interest_library_fingerprints`.
public struct InterestFingerprint: Sendable, Equatable {
    public let key: String
    public let vector: [Float]
    public let leafID: Int?
    /// The server's top terms for the paper (title and abstract, re-ranked by phrase embeddings).
    public let terms: [String]
    /// The map version `leafID` belongs to.
    public let mapVersion: Int?
    public init(key: String, vector: [Float], leafID: Int?, terms: [String] = [], mapVersion: Int? = nil) {
        self.key = InterestPool.key(key); self.vector = vector; self.leafID = leafID; self.terms = terms; self.mapVersion = mapVersion
    }
}

public struct InterestTopicSlice: Sendable, Equatable, Identifiable {
    public static let otherID = -1
    /// The map node ID (`otherID` for Other).
    public let id: Int
    /// What the chart says: the reader's name, else the computed label.
    public let label: String
    /// The computed label (title-cased terms), shown under a renamed topic and used when the name is cleared.
    public let computedLabel: String
    public let renamed: Bool
    public let papers: [UUID]
    public let share: Double
    /// Palette slot: the reader's colour, else by size (largest first).
    public let colour: Int?
    public let hidden: Bool
    /// The phrases behind the label (lowercase), best first.
    public let terms: [String]
    public var count: Int { papers.count }
    public var isOther: Bool { id == Self.otherID }
}

public struct InterestLibraryTopics: Sendable, Equatable {
    /// Shown topics, largest first.
    public let topics: [InterestTopicSlice]
    /// Topics the reader hid (their papers count in Other).
    public let hidden: [InterestTopicSlice]
    /// Papers in no shown topic (outside every topic, or in a hidden one); nil when there are none.
    public let other: InterestTopicSlice?
    /// "Other" described by area ("Control, Robot (2)").
    public let otherGroups: [(label: String, count: Int)]
    /// Two papers in a small, high-lift leaf: named, not drawn.
    public let emerging: [(label: String, count: Int)]
    /// Papers in the computation (with a public fingerprint).
    public let indexed: Int
    /// Arxiv papers whose fingerprint isn't there yet (just added).
    public let pending: Int
    /// Uploaded or device PDFs: no public fingerprint, so not in topics yet.
    public let uploads: Int
    /// The selection the registry's shown flags follow (hysteresis).
    public let shownIDs: Set<Int>

    public static func == (a: Self, b: Self) -> Bool {
        a.topics == b.topics && a.hidden == b.hidden && a.other == b.other && a.indexed == b.indexed && a.pending == b.pending
            && a.uploads == b.uploads && a.shownIDs == b.shownIDs && a.otherGroups.map(\.label) == b.otherGroups.map(\.label)
            && a.otherGroups.map(\.count) == b.otherGroups.map(\.count) && a.emerging.map(\.label) == b.emerging.map(\.label)
    }

    public var all: [InterestTopicSlice] { topics + (other.map { [$0] } ?? []) }
    public func slice(_ id: Int) -> InterestTopicSlice? { (topics + hidden).first { $0.id == id } ?? (id == InterestTopicSlice.otherID ? other : nil) }
}

/// Keeps the interest state, the label index and the selection up to date as the library changes.
public struct InterestLibraryModel: Sendable {
    public let map: InterestMap
    public let terms: InterestTerms?
    public private(set) var state: InterestState
    public private(set) var text = InterestTextIndex()
    public private(set) var fingerprints: [String: InterestFingerprint] = [:]
    private var labelCache: [Int: (papers: [String], weights: [Int64], excluded: Set<String>, terms: [String])] = [:]
    public var settings = InterestTopicRule.Settings()

    public init(map: InterestMap, terms: InterestTerms?) {
        self.map = map; self.terms = terms; state = InterestState(mapVersion: map.version)
    }

    public mutating func setFingerprints(_ values: [InterestFingerprint]) {
        for value in values { fingerprints[value.key] = value }
    }

    /// Recomputes the state for `papers` (exact incremental updates), then the topics.
    public mutating func update(papers: [InterestLibraryPaper], registry: InterestRegistry, readingLevels: [String: Int] = [:],
                                now: Date) -> InterestLibraryTopics {
        var inputs: [InterestPaper] = []
        var idsByKey: [String: [UUID]] = [:]
        var pending = 0, uploads = 0
        var metadata: [String: (title: String, abstract: String)] = [:]
        for paper in papers {
            guard let key = paper.key else { uploads += 1; continue }
            idsByKey[key, default: []].append(paper.id)
            guard idsByKey[key]!.count == 1 else { continue }
            guard let fp = fingerprints[key] else { pending += 1; continue }
            var weight = paper.weight
            weight.readingLevel = max(weight.readingLevel, readingLevels[key] ?? 0, registry.readingLevel(key))
            inputs.append(InterestPaper(key: key, vector: fp.vector, leafID: fp.mapVersion == map.version ? fp.leafID : nil,
                                        weight: InterestWeights.weight(weight, now: now)))
            metadata[key] = (paper.title, paper.abstract)
        }
        state.sync(inputs, map: map)
        if let terms {
            for key in text.phrasesByPaper.keys where metadata[key] == nil { text.remove(key) }
            for (key, m) in metadata where text.phrasesByPaper[key] == nil { text.set(key, title: m.title, abstract: m.abstract, terms: terms) }
        }
        let selection = InterestTopicRule.select(state: state, map: map, established: registry.shownIDs(map: map), settings: settings)
        return present(selection, idsByKey: idsByKey, registry: registry, pending: pending, uploads: uploads)
    }

    /// The topic's label terms (lowercase phrases), computed once per (papers, weights, phrases taken by larger topics).
    /// The server's own terms for the topic's papers (KeyBERT with real phrase embeddings) are preferred.
    mutating func labelTerms(_ topic: InterestTopic, excluded: Set<String>) -> [String] {
        let weights = topic.papers.map { state.weightUnits(of: $0) ?? 0 }
        if let cached = labelCache[topic.id], cached.papers == topic.papers, cached.weights == weights, cached.excluded == excluded {
            return cached.terms
        }
        var phrases: [String] = []
        if let terms {
            let endorsed = Set(topic.papers.flatMap { fingerprints[$0]?.terms ?? [] }.map { $0.lowercased() })
            phrases = InterestLabels.topicTerms(papers: topic.papers, state: state, text: text, terms: terms,
                                                endorsed: endorsed, excluded: excluded).map(terms.phrase)
        }
        if phrases.isEmpty, let node = map.node(topic.id) {
            // No statistics yet, or nothing passed: the map's name, else its own terms (public c-TF-IDF).
            phrases = node.name.map { [$0] } ?? Array(node.terms.filter { !InterestLabels.isGeneric($0) }.prefix(2))
        }
        labelCache[topic.id] = (topic.papers, weights, excluded, phrases)
        return phrases
    }

    mutating func present(_ selection: InterestTopicSelection, idsByKey: [String: [UUID]], registry: InterestRegistry,
                          pending: Int, uploads: Int) -> InterestLibraryTopics {
        func ids(_ keys: [String]) -> [UUID] { keys.flatMap { idsByKey[$0] ?? [] }.sorted { $0.wire < $1.wire } }
        var shown: [InterestTopicSlice] = [], hidden: [InterestTopicSlice] = []
        var bySize = 0
        var used = Set<String>(), taken = Set<String>()
        for topic in selection.topics {
            let phrases = labelTerms(topic, excluded: taken)
            taken.formUnion(phrases)
            var computed = InterestLabels.label(phrases) ?? "Topic"
            if !used.insert(computed.lowercased()).inserted { computed += " (\(topic.paperCount))" }
            let user = registry.topic(topic.id, map: map)
            let isHidden = user?.hidden ?? false
            let colour = user?.colour ?? (isHidden ? nil : bySize)
            if !isHidden { bySize += 1 }
            let slice = InterestTopicSlice(id: topic.id, label: user?.name ?? computed, computedLabel: computed, renamed: user?.name != nil,
                                           papers: ids(topic.papers), share: topic.share, colour: colour, hidden: isHidden, terms: phrases)
            if isHidden { hidden.append(slice) } else { shown.append(slice) }
        }
        let otherKeys = selection.other + hidden.flatMap { slice in selection.topics.first { $0.id == slice.id }?.papers ?? [] }
        let otherShare = selection.otherShare + hidden.reduce(0) { $0 + $1.share }
        let other = otherKeys.isEmpty ? nil : InterestTopicSlice(id: InterestTopicSlice.otherID, label: "Other", computedLabel: "Other",
            renamed: false, papers: ids(otherKeys), share: otherShare, colour: nil, hidden: false, terms: [])
        let groups = selection.otherGroups.map { group -> (String, Int) in
            let terms = map.node(group.node).map { $0.name.map { [$0] } ?? Array($0.terms.prefix(2)) } ?? []
            return (InterestLabels.label(terms.filter { !InterestLabels.isGeneric($0) }) ?? "Unlabelled", group.papers.count)
        }
        let emerging = selection.emerging.map { e -> (String, Int) in
            let terms = map.node(e.node).map { $0.name.map { [$0] } ?? Array($0.terms.prefix(2)) } ?? []
            return (InterestLabels.label(terms.filter { !InterestLabels.isGeneric($0) }) ?? "Emerging", e.papers.count)
        }
        return InterestLibraryTopics(topics: shown, hidden: hidden, other: other, otherGroups: groups, emerging: emerging,
                                     indexed: state.paperCount, pending: pending, uploads: uploads, shownIDs: selection.topicIDs)
    }

    /// A paper's keywords (sentence case), from its metadata and, when given, its full text.
    public func keywords(for key: String?, title: String, abstract: String, body: String? = nil, k: Int = 5) -> [String] {
        guard let terms else { return [] }
        var text = InterestPhrases.documentText(title: title, abstract: abstract)
        if let body, !body.isEmpty { text += "\n" + body }
        let counts = InterestPhrases.counts(text, terms: terms)
        let key = key.map(InterestPool.key) ?? ""
        let endorsed = Set((fingerprints[key]?.terms ?? []).map { $0.lowercased() })
        return InterestLabels.paperTerms(key, counts: counts, state: state, text: self.text, terms: terms, k: k, endorsed: endorsed)
            .map { InterestLabels.sentenceCase(terms.phrase($0)) }
    }

    /// The weighted centroid of a topic's papers (step 4's section anchor).
    public func centroid(of topic: InterestTopic) -> [Float]? { state.centroid(of: topic.papers) }
}
