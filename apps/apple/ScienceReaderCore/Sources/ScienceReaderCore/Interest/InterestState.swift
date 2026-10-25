import Foundation

// The reader's interest state on the device (step 3, docs/architecture/INTEREST_INDEX.md "Device layer"): for every map
// node, how many of the reader's papers fall in it, their weighted mass and the weighted sum of their fingerprints
// (BIRCH-style, so adding or removing a paper is an exact O(depth × 384) update). Weights and vectors are held as
// integers (weight in 1/4096, vector components in 1/32768), so sums are exact in any order: two devices that hold the
// same papers hold the same state, whatever order the papers arrived in. Nothing here leaves the device.

/// One library paper as the interest index sees it: its public fingerprint, its leaf in the map and its weight.
public struct InterestPaper: Sendable, Equatable {
    /// The paper's key (`InterestPool.key`: an arXiv identifier without its version, or `openalex:…`).
    public let key: String
    /// Unit-length fingerprint (gte-small, from the q8 the server sends).
    public let vector: [Float]
    /// The leaf the server assigned for the current map version; nil when the device must descend the map itself.
    public let leafID: Int?
    /// The paper's weight (`InterestWeights.weight`).
    public let weight: Double

    public init(key: String, vector: [Float], leafID: Int?, weight: Double) {
        precondition(vector.count == InterestQ8.dimension)
        self.key = InterestPool.key(key); self.vector = vector; self.leafID = leafID; self.weight = weight
    }
}

public struct InterestState: Sendable, Equatable {
    public static let weightScale: Double = 4096
    public static let vectorScale: Double = 32768

    public struct NodeStats: Sendable, Equatable {
        public internal(set) var count = 0
        /// Σ weight, in 1/4096.
        public internal(set) var massUnits: Int64 = 0
        /// Σ weight × vector, per dimension, in 1/4096 × 1/32768.
        public internal(set) var sum = [Int64](repeating: 0, count: InterestQ8.dimension)
        public var mass: Double { Double(massUnits) / InterestState.weightScale }
        /// The node's weighted centroid of the reader's papers (unit length), or nil when empty.
        public var centroid: [Float]? {
            let norm = sum.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
            guard norm > 0 else { return nil }
            return sum.map { Float(Double($0) / norm) }
        }
    }

    struct Entry: Sendable, Equatable {
        let path: [Int]
        let weightUnits: Int64
        let quantized: [Int32]
        let vector: [Float]
        let weight: Double
    }

    public let mapVersion: Int
    private(set) var entries: [String: Entry] = [:]
    public private(set) var stats: [Int: NodeStats] = [:]
    public private(set) var members: [Int: Set<String>] = [:]
    public private(set) var totalUnits: Int64 = 0

    public init(mapVersion: Int) { self.mapVersion = mapVersion }

    public var paperCount: Int { entries.count }
    public var totalMass: Double { Double(totalUnits) / Self.weightScale }
    public var keys: [String] { entries.keys.sorted() }
    public func contains(_ key: String) -> Bool { entries[InterestPool.key(key)] != nil }
    public func vector(of key: String) -> [Float]? { entries[InterestPool.key(key)]?.vector }
    public func weight(of key: String) -> Double? { entries[InterestPool.key(key)]?.weight }
    public func weightUnits(of key: String) -> Int64? { entries[InterestPool.key(key)]?.weightUnits }
    /// The paper's leaf, level-2 node and level-1 node.
    public func path(of key: String) -> [Int]? { entries[InterestPool.key(key)]?.path }

    public static func units(_ weight: Double) -> Int64 { Int64((max(0, weight) * weightScale).rounded()) }

    /// Adds a paper (or replaces it when its key is already held). False when the map has no leaf for it.
    @discardableResult
    public mutating func add(_ paper: InterestPaper, map: InterestMap) -> Bool {
        remove(paper.key)
        guard let leaf = paper.leafID.flatMap({ map.node($0)?.level == 3 ? $0 : nil }) ?? map.descend(paper.vector) else { return false }
        let path = map.path(from: leaf)
        let units = Self.units(paper.weight)
        let quantized = paper.vector.map { Int32((Double($0) * Self.vectorScale).rounded()) }
        let entry = Entry(path: path, weightUnits: units, quantized: quantized, vector: paper.vector, weight: paper.weight)
        entries[paper.key] = entry
        totalUnits += units
        for node in path {
            var s = stats[node] ?? NodeStats()
            s.count += 1; s.massUnits += units
            for i in 0 ..< InterestQ8.dimension { s.sum[i] += units * Int64(quantized[i]) }
            stats[node] = s
            members[node, default: []].insert(paper.key)
        }
        return true
    }

    /// Removes a paper; the exact inverse of `add`.
    public mutating func remove(_ key: String) {
        let key = InterestPool.key(key)
        guard let entry = entries.removeValue(forKey: key) else { return }
        totalUnits -= entry.weightUnits
        for node in entry.path {
            guard var s = stats[node] else { continue }
            s.count -= 1; s.massUnits -= entry.weightUnits
            for i in 0 ..< InterestQ8.dimension { s.sum[i] -= entry.weightUnits * Int64(entry.quantized[i]) }
            if s.count == 0 { stats[node] = nil; members[node] = nil } else { stats[node] = s; members[node]?.remove(key) }
        }
    }

    /// Brings the state to exactly `papers`: removes what left, adds what is new or changed (weight, leaf).
    public mutating func sync(_ papers: [InterestPaper], map: InterestMap) {
        let wanted = Dictionary(papers.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        for key in entries.keys where wanted[key] == nil { remove(key) }
        for (key, paper) in wanted {
            if let held = entries[key], held.weight == paper.weight, held.vector == paper.vector,
               paper.leafID == nil || held.path.first == paper.leafID { continue }
            add(paper, map: map)
        }
    }

    /// Lift of a node: the reader's weighted share in it over the pool's share (∞ when the pool has none there).
    public func lift(of node: InterestMap.Node, map: InterestMap) -> Double {
        guard let s = stats[node.id], totalUnits > 0 else { return 0 }
        let userShare = Double(s.massUnits) / Double(totalUnits)
        guard node.size > 0, map.backgroundTotal > 0 else { return .infinity }
        return userShare / (Double(node.size) / Double(map.backgroundTotal))
    }

    /// Cosine of two held papers, in a fixed scalar order (the same result on every device).
    public func cosine(_ a: String, _ b: String) -> Double {
        guard let x = entries[a]?.vector, let y = entries[b]?.vector else { return -1 }
        return Self.dot(x, y)
    }

    static func dot(_ x: [Float], _ y: [Float]) -> Double {
        var s = 0.0
        for i in 0 ..< min(x.count, y.count) { s += Double(x[i]) * Double(y[i]) }
        return s
    }

    /// The weighted centroid of some held papers (unit length; exact integer sums).
    public func centroid(of keys: [String]) -> [Float]? {
        var sum = [Int64](repeating: 0, count: InterestQ8.dimension)
        for key in keys {
            guard let e = entries[InterestPool.key(key)] else { continue }
            for i in 0 ..< InterestQ8.dimension { sum[i] += e.weightUnits * Int64(e.quantized[i]) }
        }
        let norm = sum.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        guard norm > 0 else { return nil }
        return sum.map { Float(Double($0) / norm) }
    }
}

/// A library paper's weight (owner decisions, 2026-10-24): the Feed's age fade, archive × 0.5, the reader's own tags
/// × 1.5, and, on the reader's devices only, how far they read it, whether they kept snippets from it and whether they
/// chatted about it. `now` is the start of the UTC day, so devices computing on the same day agree.
public enum InterestWeights {
    public struct Inputs: Sendable, Equatable {
        public var addedAt: Date?
        public var archived: Bool
        public var hasOwnTags: Bool
        /// 0–4: how far the paper was read on any of the reader's devices (`readingLevel(progress:)`).
        public var readingLevel: Int
        public var snippets: Int
        public var chats: Int
        public init(addedAt: Date?, archived: Bool = false, hasOwnTags: Bool = false, readingLevel: Int = 0, snippets: Int = 0, chats: Int = 0) {
            self.addedAt = addedAt; self.archived = archived; self.hasOwnTags = hasOwnTags
            self.readingLevel = readingLevel; self.snippets = snippets; self.chats = chats
        }
    }

    /// Age fade (PERSONALIZED_FEED.md): 0.4 + 0.6 · e^(−age / 120 days).
    public static let fadeDays = 120.0
    public static let archivedFactor = 0.5
    public static let ownTagsFactor = 1.5
    /// Device-only signals add up to + 0.25 each (reading in quarters of it), so a paper read through, snipped and
    /// discussed weighs 1.75× one only added.
    public static let readingStep = 0.0625
    public static let snippetsBonus = 0.25
    public static let chatsBonus = 0.25

    public static func weight(_ inputs: Inputs, now: Date) -> Double {
        let day = startOfUTCDay(now)
        let age = inputs.addedAt.map { max(0, day.timeIntervalSince(startOfUTCDay($0)) / 86_400) } ?? 0
        var w = (inputs.archived ? archivedFactor : 1) * (0.4 + 0.6 * exp(-age / fadeDays))
        if inputs.hasOwnTags { w *= ownTagsFactor }
        let device = 1 + readingStep * Double(max(0, min(4, inputs.readingLevel)))
            + (inputs.snippets > 0 ? snippetsBonus : 0) + (inputs.chats > 0 ? chatsBonus : 0)
        return w * device
    }

    /// Reading progress (0…1 through the paper) as a level: < 10 % → 0, then 1 (10 %), 2 (35 %), 3 (60 %), 4 (90 %).
    public static func readingLevel(progress: Double?) -> Int {
        guard let p = progress, p.isFinite else { return 0 }
        if p >= 0.9 { return 4 }
        if p >= 0.6 { return 3 }
        if p >= 0.35 { return 2 }
        if p >= 0.1 { return 1 }
        return 0
    }

    public static func startOfUTCDay(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 86_400).rounded(.down) * 86_400)
    }
}
