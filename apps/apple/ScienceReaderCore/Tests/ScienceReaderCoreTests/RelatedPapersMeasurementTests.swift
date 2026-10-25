import Foundation
import XCTest
@testable import ScienceReaderCore

/// Opt-in measurement on real interest index shards (docs/architecture/PERSONALIZED_FEED.md "Related papers"): set
/// `INTEREST_MEASURE_DIR` to a folder holding the window's `*.gsi` shards (as downloaded from `interest-index`) and,
/// optionally, `facts.json` (`[{source_id, title, authors, topics}]`) to print example lists. Skipped otherwise.
final class RelatedPapersMeasurementTests: XCTestCase {
    private struct Fact: Decodable { let source_id: String; let title: String; let authors: [String]; let topics: [String] }

    func testRealWindowDecodeAndRankTimes() throws {
        guard let path = ProcessInfo.processInfo.environment["INTEREST_MEASURE_DIR"], !path.isEmpty else {
            throw XCTSkip("set INTEREST_MEASURE_DIR to measure on real shards")
        }
        let folder = URL(fileURLWithPath: path)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "gsi" }
        XCTAssertFalse(files.isEmpty)
        var started = Date()
        let shards = try files.map { try InterestShard(InterestArtifact(gzipped: Data(contentsOf: $0))) }
        let pool = InterestPool(shards: shards)
        let decode = Date().timeIntervalSince(started)
        let bytes = try files.reduce(0) { $0 + (try Data(contentsOf: $1)).count }

        let queries = Array(pool.sourceIDs.enumerated().filter { $0.offset % 41 == 0 }.map(\.element).prefix(200))
        started = Date()
        var lists: [String: [(sourceID: String, similarity: Float)]] = [:]
        for id in queries { lists[id] = RelatedPapers.nearest(to: id, in: pool, excluding: []) }
        let perQuery = Date().timeIntervalSince(started) / Double(queries.count)
        print(String(format: "related-measure: %d shards, %d bytes, %d papers; decode %.0f ms; nearest %.2f ms per query (%d queries)",
                     files.count, bytes, pool.count, decode * 1000, perQuery * 1000, queries.count))
        XCTAssertLessThan(perQuery, 0.1)

        let factsURL = folder.appendingPathComponent("facts.json")
        guard let data = try? Data(contentsOf: factsURL) else { return }
        let facts = try JSONDecoder().decode([Fact].self, from: data)
        let known = Dictionary(facts.map { (InterestPool.key($0.source_id), RelatedPaperFacts(sourceID: $0.source_id, title: $0.title, authors: $0.authors, topics: $0.topics)) },
                               uniquingKeysWith: { a, _ in a })
        let windowFacts = pool.sourceIDs.compactMap { known[$0] }
        let counts = RelatedPapers.authorCounts(windowFacts)
        var shown: [Int] = [], reasons: [String: Int] = [:]
        for (i, id) in queries.enumerated() {
            guard let opened = known[id], let nearest = lists[id] else { continue }
            let ranked = RelatedPapers.rank(opened: opened, nearest: nearest, facts: known, authorPapers: { counts[$0] ?? 0 })
            shown.append(ranked.count)
            for item in ranked { reasons[String(item.reason.text.prefix(while: { $0 != ":" })), default: 0] += 1 }
            if i < 6 {
                print("related-example: \(opened.title)")
                for item in ranked.prefix(5) {
                    print(String(format: "  %.3f  %@  — %@", item.similarity ?? 0, item.reason.text, known[item.sourceID]?.title ?? "?"))
                }
            }
        }
        let sorted = shown.sorted()
        print("related-measure: shown per paper median \(sorted[sorted.count / 2]), none \(shown.filter { $0 == 0 }.count) of \(shown.count), under 3 \(shown.filter { $0 < 3 }.count); reasons \(reasons.sorted { $0.key < $1.key })")
    }
}
