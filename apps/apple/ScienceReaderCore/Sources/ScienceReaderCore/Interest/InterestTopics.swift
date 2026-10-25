import Foundation

// Choosing the reader's topics from the interest state (step 2's specificity-first rule, tools/interest-eval/
// topic_rule2.py, with step 3's hysteresis). Deepest node first: a node becomes a topic once at least 3 of the reader's
// papers in it are not already claimed by a narrower topic (2 for a topic the reader already had: a topic appears at 3
// and leaves below 2); unclaimed papers rise to the parent; a level-1 node keeps its rest as a broad topic only when
// enough remain. A paper outside every topic joins the topic holding its nearest paper when their cosine is at least
// 0.86; what is left is "Other", grouped by level-1 node. Two papers in a small leaf with lift ≥ 8 are "emerging".
// Pure and deterministic: the same papers, map and registry give the same topics on every device.

public struct InterestTopic: Sendable, Equatable, Identifiable {
    /// The map node's ID: the topic's identity (synced names, hidden flags and colours are keyed by it).
    public let id: Int
    public let level: Int
    /// The papers the topic holds (claimed, then folded), sorted by key.
    public let papers: [String]
    /// How many of `papers` joined by closeness (fold) rather than by the map.
    public let folded: Int
    /// Σ weight of `papers` ÷ Σ weight of the library papers in the index.
    public let share: Double
    public let lift: Double
    /// True when a deeper topic took some of the node's papers (a broad "rest" topic).
    public let residual: Bool
    /// Pool papers in the node.
    public let nodePapers: Int
    public var paperCount: Int { papers.count }
}

public struct InterestTopicSelection: Sendable, Equatable {
    public struct OtherGroup: Sendable, Equatable {
        /// The level-1 node the papers fall under.
        public let node: Int
        public let papers: [String]
    }
    public struct Emerging: Sendable, Equatable {
        public let node: Int
        public let papers: [String]
        public let lift: Double
        public let nodePapers: Int
    }
    /// Largest share first (ties: node ID).
    public let topics: [InterestTopic]
    public let other: [String]
    public let otherShare: Double
    public let otherGroups: [OtherGroup]
    public let emerging: [Emerging]
    /// Node IDs that are topics now; the next selection keeps them while they hold 2 papers (hysteresis).
    public var topicIDs: Set<Int> { Set(topics.map(\.id)) }
}

public enum InterestTopicRule {
    public struct Settings: Sendable, Equatable {
        /// A topic appears at this many unclaimed papers.
        public var appear = 3
        /// A topic the reader already has stays while it holds this many.
        public var keep = 2
        /// An outside paper joins the topic of its nearest paper at this cosine (gte-small).
        public var foldCosine = 0.86
        public var emergingPapers = 2
        public var emergingLift = 8.0
        public init() {}
    }

    /// `established`: node IDs the reader already has as topics (the synced registry's, followed to live IDs).
    public static func select(state: InterestState, map: InterestMap, established: Set<Int> = [], settings: Settings = Settings()) -> InterestTopicSelection {
        var claimed = Set<String>()
        var chosen: [(node: InterestMap.Node, papers: [String], residual: Bool, lift: Double)] = []
        for level in [3, 2, 1] {
            var nodes: [(node: InterestMap.Node, lift: Double)] = []
            for node in map.nodes where node.level == level && (state.stats[node.id]?.count ?? 0) > 0 {
                nodes.append((node, state.lift(of: node, map: map)))
            }
            nodes.sort { (a, b) -> Bool in a.lift == b.lift ? a.node.id < b.node.id : a.lift > b.lift }
            for (node, lift) in nodes {
                let mine = state.members[node.id] ?? []
                let free = mine.filter { !claimed.contains($0) }.sorted()
                let needed = established.contains(node.id) ? settings.keep : settings.appear
                guard free.count >= needed else { continue }
                chosen.append((node, free, free.count < mine.count, lift))
                claimed.formUnion(free)
            }
        }
        // Fold: an outside paper joins the topic holding its nearest paper, when close enough (first topic on a tie).
        var folded: [Int: [String]] = [:]
        var other: [String] = []
        for key in state.keys where !claimed.contains(key) {
            var best: Int?, bestCos = -Double.infinity
            for (i, topic) in chosen.enumerated() {
                let c = topic.papers.reduce(-Double.infinity) { max($0, state.cosine(key, $1)) }
                if c > bestCos { bestCos = c; best = i }
            }
            if let best, bestCos >= settings.foldCosine { folded[best, default: []].append(key) } else { other.append(key) }
        }
        let total = Double(state.totalUnits)
        func share(_ keys: [String]) -> Double {
            guard total > 0 else { return 0 }
            return Double(keys.reduce(Int64(0)) { $0 + (state.weightUnits(of: $1) ?? 0) }) / total
        }
        var topics: [InterestTopic] = []
        for (i, t) in chosen.enumerated() {
            let extra: [String] = folded[i] ?? []
            let papers: [String] = (t.papers + extra).sorted()
            topics.append(InterestTopic(id: t.node.id, level: t.node.level, papers: papers, folded: extra.count,
                                        share: share(papers), lift: t.lift, residual: t.residual, nodePapers: t.node.size))
        }
        topics.sort { (a: InterestTopic, b: InterestTopic) -> Bool in a.share == b.share ? a.id < b.id : a.share > b.share }
        // Emerging: small, high-lift leaves holding two papers outside the map's topics (outside or folded).
        let outside = Set(other).union(folded.values.flatMap { $0 })
        var emerging: [InterestTopicSelection.Emerging] = []
        for node in map.nodes where node.level == 3 {
            let lift = state.lift(of: node, map: map)
            let papers: [String] = (state.members[node.id] ?? []).filter { outside.contains($0) }.sorted()
            guard lift >= settings.emergingLift, papers.count >= settings.emergingPapers else { continue }
            emerging.append(.init(node: node.id, papers: papers, lift: lift, nodePapers: node.size))
        }
        emerging.sort { (a, b) -> Bool in a.lift == b.lift ? a.node < b.node : a.lift > b.lift }
        let otherSet = Set(other)
        var groups: [InterestTopicSelection.OtherGroup] = []
        for id in map.levelOneIDs {
            let papers: [String] = (state.members[id] ?? []).filter { otherSet.contains($0) }.sorted()
            if !papers.isEmpty { groups.append(.init(node: id, papers: papers)) }
        }
        groups.sort { (a, b) -> Bool in a.papers.count == b.papers.count ? a.node < b.node : a.papers.count > b.papers.count }
        return InterestTopicSelection(topics: topics, other: other.sorted(), otherShare: share(other), otherGroups: groups, emerging: emerging)
    }
}
