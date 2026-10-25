import Accelerate
import Foundation

/// The Feed pool's fingerprints in memory: every shard of the manifest's window, decoded once into one contiguous,
/// L2-normalised float matrix (papers × 384), so a similarity search is one matrix–vector product (Accelerate). About
/// 8k papers × 384 × 4 B ≈ 12 MB. The same for every reader; nothing in it is about the reader.
public final class InterestPool: @unchecked Sendable {
    public let sourceIDs: [String]
    /// Days since 1970-01-01 (UTC), per paper.
    public let announcedDays: [Int]
    /// The manifest's model version the fingerprints were made with.
    public let modelVersion: String?
    /// Row-major, `count × dimension`, each row unit length. Immutable after init.
    private let vectors: [Float]
    private let index: [String: Int]
    public var count: Int { sourceIDs.count }
    public static let dimension = InterestQ8.dimension

    /// The shards in order; a paper that appears twice keeps its later fingerprint (a revised abstract is re-embedded).
    public init(shards: [InterestShard], modelVersion: String? = nil) {
        var latest: [String: (shard: Int, paper: Int)] = [:]
        var order: [String] = []
        for (s, shard) in shards.enumerated() {
            for (p, paper) in shard.papers.enumerated() {
                if latest[paper.sourceID] == nil { order.append(paper.sourceID) }
                latest[paper.sourceID] = (s, p)
            }
        }
        let dimension = Self.dimension
        var vectors = [Float](repeating: 0, count: order.count * dimension)
        var days = [Int](repeating: 0, count: order.count)
        var index: [String: Int] = [:]
        index.reserveCapacity(order.count)
        vectors.withUnsafeMutableBufferPointer { out in
            for (row, id) in order.enumerated() {
                let at = latest[id]!
                let paper = shards[at.shard].papers[at.paper]
                InterestQ8.decode(shards[at.shard].body, at: paper.offset, into: out.baseAddress! + row * dimension)
                days[row] = paper.announcedDay
                index[id] = row
            }
        }
        sourceIDs = order; announcedDays = days; self.vectors = vectors; self.index = index; self.modelVersion = modelVersion
    }

    /// Tests and tools: rows given directly (each is normalised here).
    public init(sourceIDs: [String], vectors rows: [[Float]], announcedDays: [Int]? = nil, modelVersion: String? = nil) {
        precondition(rows.count == sourceIDs.count && rows.allSatisfy { $0.count == Self.dimension })
        var flat: [Float] = []
        flat.reserveCapacity(rows.count * Self.dimension)
        for row in rows {
            let norm = row.reduce(0) { $0 + $1 * $1 }.squareRoot()
            flat.append(contentsOf: norm > 0 ? row.map { $0 / norm } : row)
        }
        self.sourceIDs = sourceIDs; vectors = flat
        self.announcedDays = announcedDays ?? Array(repeating: 0, count: sourceIDs.count)
        index = Dictionary(sourceIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { _, last in last })
        self.modelVersion = modelVersion
    }

    public func row(of sourceID: String) -> Int? { index[Self.key(sourceID)] }
    public func contains(_ sourceID: String) -> Bool { row(of: sourceID) != nil }

    /// A paper's fingerprint (unit length), or nil when it isn't in the window.
    public func vector(of sourceID: String) -> [Float]? {
        guard let row = row(of: sourceID) else { return nil }
        return Array(vectors[row * Self.dimension ..< (row + 1) * Self.dimension])
    }

    /// Cosine similarity of every paper in the pool to `query` (unit length): one matrix–vector product.
    public func similarities(to query: [Float]) -> [Float] {
        precondition(query.count == Self.dimension)
        var out = [Float](repeating: 0, count: count)
        guard count > 0 else { return out }
        vectors.withUnsafeBufferPointer { matrix in
            query.withUnsafeBufferPointer { q in
                out.withUnsafeMutableBufferPointer { y in
                    // (count × 384) · (384 × 1)
                    vDSP_mmul(matrix.baseAddress!, 1, q.baseAddress!, 1, y.baseAddress!, 1,
                              vDSP_Length(count), 1, vDSP_Length(Self.dimension))
                }
            }
        }
        return out
    }

    /// Cosine similarity of two papers in the pool.
    public func similarity(_ a: Int, _ b: Int) -> Float {
        vectors.withUnsafeBufferPointer { m in
            var result: Float = 0
            vDSP_dotpr(m.baseAddress! + a * Self.dimension, 1, m.baseAddress! + b * Self.dimension, 1, &result, vDSP_Length(Self.dimension))
            return result
        }
    }

    /// The identifier without a version suffix ("2610.01234v2" → "2610.01234"): shards carry the bare identifier.
    public static func key(_ sourceID: String) -> String {
        guard let v = sourceID.range(of: #"v\d+$"#, options: .regularExpression) else { return sourceID }
        return String(sourceID[..<v.lowerBound])
    }
}
