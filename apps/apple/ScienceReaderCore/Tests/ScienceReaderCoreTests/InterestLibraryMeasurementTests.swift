import Foundation
import XCTest
@testable import ScienceReaderCore

/// Opt-in: a real library's topics on the published map and term statistics (docs/architecture/INTEREST_INDEX.md
/// "Device layer"). Set `INTEREST_DEVICE_DIR` to a folder holding `map.gsi`, `terms.gsi` and `fingerprints.json`
/// (tools/interest-eval/fetch_device_inputs.py) and `library.json` (`[{source_id, title, abstract, added_at, archived}]`;
/// fetch_data.py's libraries.json with `INTEREST_LIBRARY=owner`). Prints the topics, labels, timings and a few keywords;
/// never committed, never run by default.
final class InterestLibraryMeasurementTests: XCTestCase {
    private struct Row: Decodable { let source_id: String; let title: String?; let abstract: String?; let added_at: String?; let archived: Bool? }
    private struct FP: Decodable { let q8: String; let leaf_id: Int?; let leaf_map_version: Int?; let terms: [String]? }

    func testRealLibraryTopics() throws {
        guard let path = ProcessInfo.processInfo.environment["INTEREST_DEVICE_DIR"], !path.isEmpty else {
            throw XCTSkip("set INTEREST_DEVICE_DIR to compute a real library's topics")
        }
        let folder = URL(fileURLWithPath: path)
        var started = Date()
        let map = try InterestMap(InterestArtifact(gzipped: Data(contentsOf: folder.appendingPathComponent("map.gsi"))))
        let terms = try InterestTerms(InterestArtifact(gzipped: Data(contentsOf: folder.appendingPathComponent("terms.gsi"))))
        let decode = Date().timeIntervalSince(started)
        let fps = try JSONDecoder().decode([String: FP].self, from: Data(contentsOf: folder.appendingPathComponent("fingerprints.json")))
        let libraryData = try Data(contentsOf: folder.appendingPathComponent("library.json"))
        let rows: [Row]
        if let label = ProcessInfo.processInfo.environment["INTEREST_LIBRARY"], !label.isEmpty {
            rows = try JSONDecoder().decode([String: [Row]].self, from: libraryData)[label] ?? []
        } else {
            rows = try JSONDecoder().decode([Row].self, from: libraryData)
        }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ s: String?) -> Date? {
            guard let s, !s.isEmpty else { return nil }
            let normal = s.replacingOccurrences(of: " ", with: "T")
            return iso.date(from: normal) ?? plain.date(from: normal) ?? plain.date(from: String(normal.prefix(19)) + "Z")
        }
        var model = InterestLibraryModel(map: map, terms: terms)
        model.setFingerprints(fps.map { key, fp in
            InterestFingerprint(key: key, vector: InterestQ8.decode(Data(base64Encoded: fp.q8, options: .ignoreUnknownCharacters)!), leafID: fp.leaf_id, terms: fp.terms ?? [],
                                mapVersion: fp.leaf_map_version)
        })
        var seen = Set<String>()
        let papers = rows.filter { seen.insert($0.source_id).inserted }.map { r in
            InterestLibraryPaper(id: UUID(), key: r.source_id.hasPrefix("upload:") ? nil : r.source_id, title: r.title ?? "",
                                 abstract: r.abstract ?? "", weight: .init(addedAt: date(r.added_at), archived: r.archived ?? false))
        }
        let now = papers.compactMap(\.weight.addedAt).max() ?? Date()
        started = Date()
        let topics = model.update(papers: papers, registry: InterestRegistry(), now: now)
        let first = Date().timeIntervalSince(started)
        started = Date()
        _ = model.update(papers: papers, registry: InterestRegistry(), now: now)
        let again = Date().timeIntervalSince(started)
        print(String(format: "interest-measure: map %d nodes, %d phrases, decode %.0f ms; %d papers (%d indexed, %d pending, %d uploads); first %.0f ms, again %.1f ms",
                     map.nodes.count, terms.count, decode * 1000, papers.count, topics.indexed, topics.pending, topics.uploads, first * 1000, again * 1000))
        let titles = Dictionary(rows.map { (InterestPool.key($0.source_id), $0.title ?? "") }, uniquingKeysWith: { a, _ in a })
        let byID = Dictionary(zip(papers.map(\.id), papers.map { $0.key ?? "" }), uniquingKeysWith: { a, _ in a })
        for slice in topics.topics {
            let node = map.node(slice.id)
            print(String(format: "interest-measure: %5.1f%%  %2d  L%d  %@   [map: %@]", slice.share * 100, slice.count, node?.level ?? 0,
                         slice.label + " {" + slice.terms.joined(separator: "|") + "}", (node?.terms.prefix(3) ?? []).joined(separator: " · ")))
            for id in slice.papers.prefix(6) { print("interest-measure:          · \(titles[byID[id] ?? ""]?.prefix(80) ?? "")") }
        }
        if let other = topics.other {
            print(String(format: "interest-measure: %5.1f%%  %2d  Other: %@", other.share * 100, other.count,
                         topics.otherGroups.map { "\($0.label) (\($0.count))" }.joined(separator: "; ")))
        }
        print("interest-measure: emerging: " + topics.emerging.map { "\($0.label) (\($0.count))" }.joined(separator: "; "))
        started = Date()
        for p in papers.prefix(8) {
            let keywords = model.keywords(for: p.key, title: p.title, abstract: p.abstract)
            print("interest-measure: keywords \(p.title.prefix(60)) → \(keywords.joined(separator: ", "))")
        }
        print(String(format: "interest-measure: keywords %.1f ms per paper (title and abstract)", Date().timeIntervalSince(started) * 1000 / 8))
        XCTAssertGreaterThan(topics.topics.count, 0)
    }
}
