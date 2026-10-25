import Accelerate
import Foundation

// The interest index's public topic map (`gradstep-map/1`, docs/architecture/INTEREST_INDEX.md §2 and §4): about 20 /
// 70–670 / 250–2,500 nodes, each with its parent, its number of pool papers, its c-TF-IDF terms and a q8 centroid, plus
// retired IDs with their successors. The same bytes for every reader; nothing in it is about the reader.

public struct InterestMap: Sendable {
    public struct Node: Sendable, Equatable {
        public let id: Int
        /// 1 (≈ 20 broad areas), 2, or 3 (leaves).
        public let level: Int
        public let parent: Int?
        /// Pool papers in the node when the map was built (the background the reader's share is compared with).
        public let size: Int
        /// c-TF-IDF terms, best first (public; never a reader's).
        public let terms: [String]
        /// Titles of the papers nearest the centroid (public pool papers).
        public let centralTitles: [String]
        /// The node's name once the map is named (November); nil until then.
        public let name: String?
        public init(id: Int, level: Int, parent: Int?, size: Int, terms: [String] = [], centralTitles: [String] = [], name: String? = nil) {
            self.id = id; self.level = level; self.parent = parent; self.size = size; self.terms = terms
            self.centralTitles = centralTitles; self.name = name
        }
    }

    /// A retired ID and where its papers went (share of its former members per successor).
    public struct Retired: Sendable, Equatable {
        public let id: Int
        public let successors: [Int]
        public let shares: [Double]
        public init(id: Int, successors: [Int], shares: [Double]) { self.id = id; self.successors = successors; self.shares = shares }
    }

    public let version: Int
    public let modelVersion: String?
    public let nodes: [Node]
    public let retired: [Retired]
    /// Unit centroids, row-major, `nodes.count × 384`, in `nodes` order.
    private let centroids: [Float]
    private let index: [Int: Int]
    private let children: [Int: [Int]]
    private let roots: [Int]
    private let retiredIndex: [Int: Retired]

    /// Pool papers behind the map (the sum of the level-1 sizes): the background total for lift.
    public let backgroundTotal: Int

    public init(version: Int, modelVersion: String? = nil, nodes: [Node], centroids rows: [[Float]], retired: [Retired] = []) throws {
        guard rows.count == nodes.count, rows.allSatisfy({ $0.count == InterestQ8.dimension }) else { throw InterestArtifactError.dimension }
        var flat: [Float] = []
        flat.reserveCapacity(rows.count * InterestQ8.dimension)
        for row in rows {
            let norm = row.reduce(0) { $0 + $1 * $1 }.squareRoot()
            flat.append(contentsOf: norm > 0 ? row.map { $0 / norm } : row)
        }
        try self.init(version: version, modelVersion: modelVersion, nodes: nodes, flatCentroids: flat, retired: retired)
    }

    init(version: Int, modelVersion: String?, nodes: [Node], flatCentroids: [Float], retired: [Retired]) throws {
        var index: [Int: Int] = [:], children: [Int: [Int]] = [:], roots: [Int] = []
        for (i, node) in nodes.enumerated() {
            guard (1...3).contains(node.level), node.size >= 0, index[node.id] == nil else { throw InterestArtifactError.header }
            index[node.id] = i
        }
        for node in nodes {
            if let parent = node.parent {
                guard let p = index[parent], nodes[p].level == node.level - 1 else { throw InterestArtifactError.header }
                children[parent, default: []].append(node.id)
            } else {
                guard node.level == 1 else { throw InterestArtifactError.header }
                roots.append(node.id)
            }
        }
        self.version = version; self.modelVersion = modelVersion; self.nodes = nodes; self.retired = retired
        self.centroids = flatCentroids; self.index = index; self.children = children; self.roots = roots
        retiredIndex = Dictionary(retired.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        backgroundTotal = nodes.filter { $0.level == 1 }.reduce(0) { $0 + $1.size }
    }

    /// The map artifact (`kind: map`): nodes in the header, q8 centroids in the body in header order.
    public init(_ artifact: InterestArtifact) throws {
        guard artifact.kind == .map, case .array(let rawNodes)? = artifact.header["nodes"] else { throw InterestArtifactError.header }
        guard artifact.body.count == rawNodes.count * InterestQ8.bytes else { throw InterestArtifactError.truncated }
        var nodes: [Node] = []
        nodes.reserveCapacity(rawNodes.count)
        for raw in rawNodes {
            guard case .object(let o) = raw, case .number(let id)? = o["id"], case .number(let level)? = o["level"],
                  case .number(let size)? = o["size"] else { throw InterestArtifactError.header }
            var parent: Int?
            if case .number(let p)? = o["parent"] { parent = Int(p) }
            let terms: [String] = { if case .array(let a)? = o["terms"] { return a.compactMap { if case .string(let s) = $0 { s } else { nil } } }; return [] }()
            let central: [String] = {
                guard case .array(let a)? = o["central"] else { return [] }
                return a.compactMap { if case .object(let c) = $0, case .string(let t)? = c["title"] { t } else { nil } }
            }()
            var name: String?
            if case .string(let n)? = o["name"] { name = n }
            nodes.append(Node(id: Int(id), level: Int(level), parent: parent, size: Int(size), terms: terms, centralTitles: central, name: name))
        }
        var retired: [Retired] = []
        if case .array(let rawRetired)? = artifact.header["retired"] {
            for raw in rawRetired {
                guard case .object(let o) = raw, case .number(let id)? = o["id"] else { continue }
                let successors: [Int] = { if case .array(let a)? = o["successors"] { return a.compactMap { if case .number(let n) = $0 { Int(n) } else { nil } } }; return [] }()
                let shares: [Double] = { if case .array(let a)? = o["shares"] { return a.compactMap { if case .number(let n) = $0 { n } else { nil } } }; return [] }()
                retired.append(Retired(id: Int(id), successors: successors, shares: shares))
            }
        }
        var flat = [Float](repeating: 0, count: nodes.count * InterestQ8.dimension)
        flat.withUnsafeMutableBufferPointer { out in
            for i in nodes.indices { InterestQ8.decode(artifact.body, at: i * InterestQ8.bytes, into: out.baseAddress! + i * InterestQ8.dimension) }
        }
        var version = 0
        if case .number(let v)? = artifact.header["version"] { version = Int(v) }
        var model: String?
        if case .string(let m)? = artifact.header["model_version"] { model = m }
        try self.init(version: version, modelVersion: model, nodes: nodes, flatCentroids: flat, retired: retired)
    }

    public func node(_ id: Int) -> Node? { index[id].map { nodes[$0] } }
    public func children(of id: Int) -> [Int] { children[id] ?? [] }
    public var levelOneIDs: [Int] { roots }

    /// The node and its ancestors, deepest first (leaf, level 2, level 1).
    public func path(from id: Int) -> [Int] {
        var out: [Int] = [], current: Int? = id, guardCount = 0
        while let c = current, let n = node(c), guardCount < 4 { out.append(c); current = n.parent; guardCount += 1 }
        return out
    }

    /// The level-1 node above `id`.
    public func top(of id: Int) -> Int? { path(from: id).last }

    /// The leaf a fingerprint (unit length) descends to: nearest level-1 centroid, then its nearest child, then the
    /// nearest leaf under that (the server's canonical membership rule).
    public func descend(_ vector: [Float]) -> Int? {
        precondition(vector.count == InterestQ8.dimension)
        var candidates = roots, chosen: Int?
        while !candidates.isEmpty {
            var best = -Float.infinity, bestID = candidates[0]
            for id in candidates {
                let s = similarity(of: id, to: vector)
                if s > best || (s == best && id < bestID) { best = s; bestID = id }
            }
            chosen = bestID
            candidates = children(of: bestID)
        }
        return chosen
    }

    /// Cosine of a node's centroid and a unit vector.
    public func similarity(of id: Int, to vector: [Float]) -> Float {
        guard let i = index[id] else { return -1 }
        return centroids.withUnsafeBufferPointer { m in
            vector.withUnsafeBufferPointer { v in
                var result: Float = 0
                vDSP_dotpr(m.baseAddress! + i * InterestQ8.dimension, 1, v.baseAddress!, 1, &result, vDSP_Length(InterestQ8.dimension))
                return result
            }
        }
    }

    public func centroid(of id: Int) -> [Float]? {
        guard let i = index[id] else { return nil }
        return Array(centroids[i * InterestQ8.dimension ..< (i + 1) * InterestQ8.dimension])
    }

    /// A topic ID from an older map, followed to the live node that took most of its papers (successor chains are kept
    /// for 26 versions). Nil when neither the ID nor any successor is in this map.
    public func live(_ id: Int) -> Int? {
        var current = id, visited = Set<Int>()
        while index[current] == nil {
            guard visited.insert(current).inserted, let retired = retiredIndex[current], !retired.successors.isEmpty else { return nil }
            var best = 0
            for i in retired.successors.indices where i < retired.shares.count {
                let s = retired.shares[i], b = best < retired.shares.count ? retired.shares[best] : -1
                if s > b || (s == b && retired.successors[i] < retired.successors[best]) { best = i }
            }
            current = retired.successors[best]
        }
        return current
    }
}
