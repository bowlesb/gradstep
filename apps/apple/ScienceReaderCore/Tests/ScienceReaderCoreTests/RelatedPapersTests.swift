import Foundation
import XCTest
@testable import ScienceReaderCore

/// Related papers on the device (owner, 2026-10-24): closeness of the pool's fingerprints, shared authors only when the
/// name is one person's, a small boost for shared specific topics, never the paper itself, the reader's library or another
/// identifier of the same work; the Feed results alone when the index isn't served. Thresholds: RelatedPapers.Settings.
final class RelatedPapersTests: XCTestCase {
    /// A unit vector at cosine `similarity` to the first basis vector, pointing elsewhere along dimension `axis`.
    private func vector(_ similarity: Float, axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 384)
        v[0] = similarity; v[axis] = (1 - similarity * similarity).squareRoot()
        return v
    }

    private func facts(_ id: String, _ title: String, authors: [String] = [], topics: [String] = []) -> RelatedPaperFacts {
        RelatedPaperFacts(sourceID: id, title: title, authors: authors, topics: topics)
    }

    private let opened = RelatedPaperFacts(sourceID: "2610.00001", title: "Sparse Mixture of Experts Without Load Balancing",
                                           authors: ["Wei Zhang", "Chongkai Gao", "Amir Rahmani"], topics: ["Mixture of experts", "Large language models"])

    private func pool(_ rows: [(String, Float)]) -> InterestPool {
        var ids = ["2610.00001"], vectors = [vector(1, axis: 1)]
        for (i, row) in rows.enumerated() { ids.append(row.0); vectors.append(vector(row.1, axis: 2 + i)) }
        return InterestPool(sourceIDs: ids, vectors: vectors)
    }

    func testClosenessThresholdsAndReasons() throws {
        let pool = pool([("2610.00002", 0.95), ("2610.00003", 0.90), ("2610.00004", 0.87), ("2610.00005", 0.87), ("2610.00006", 0.80)])
        let nearest = try XCTUnwrap(RelatedPapers.nearest(to: "2610.00001", in: pool, excluding: []))
        XCTAssertEqual(nearest.map(\.sourceID), ["2610.00002", "2610.00003", "2610.00004", "2610.00005"], "never itself; nothing below 0.84")
        let known = [
            facts("2610.00002", "Expert Routing at Scale"),
            facts("2610.00003", "Load Balancing Losses Revisited"),
            facts("2610.00004", "Token Dropping in MoE", topics: ["Mixture of experts"]),
            facts("2610.00005", "Something Else at 0.87", topics: ["Large language models"]),
        ]
        let ranked = RelatedPapers.rank(opened: opened, nearest: nearest, facts: Dictionary(uniqueKeysWithValues: known.map { ($0.sourceID, $0) }),
                                        authorPapers: { _ in 1 })
        XCTAssertEqual(ranked.map(\.sourceID), ["2610.00002", "2610.00003", "2610.00004"],
                       "0.86–0.88 only with a shared specific topic (Large language models is generic)")
        XCTAssertEqual(ranked.map(\.reason.text), ["Very close in topic", "Close in topic", "Shares Mixture of experts"])
        XCTAssertEqual(try XCTUnwrap(ranked[2].similarity), 0.87, accuracy: 0.001)
        XCTAssertEqual(ranked[2].score, 0.88, accuracy: 0.001, "+0.01 for one shared specific topic")
    }

    func testNamesakesDoNotBoostAndRareNamesDo() throws {
        let pool = pool([("2610.00010", 0.865), ("2610.00011", 0.865), ("2610.00012", 0.85), ("2610.00013", 0.85)])
        let nearest = try XCTUnwrap(RelatedPapers.nearest(to: "2610.00001", in: pool, excluding: []))
        let known = [
            facts("2610.00010", "Common name only", authors: ["Wei Zhang", "Someone Else"]),
            facts("2610.00011", "Rare name", authors: ["Chongkai Gao"]),
            facts("2610.00012", "Two shared names", authors: ["Chongkai Gao", "Amir Rahmani"]),
            facts("2610.00013", "One rare name, too far", authors: ["Amir Rahmani"]),
        ]
        // "Wei Zhang" is on 12 known papers (namesakes); the others on one or two.
        let counts = ["wei zhang": 12, "chongkai gao": 2, "amir rahmani": 2]
        let ranked = RelatedPapers.rank(opened: opened, nearest: nearest, facts: Dictionary(uniqueKeysWithValues: known.map { ($0.sourceID, $0) }),
                                        authorPapers: { counts[$0] ?? 1 })
        XCTAssertEqual(Set(ranked.map(\.sourceID)), ["2610.00011", "2610.00012"],
                       "a common name admits nothing at 0.865; two shared names admit 0.85; one rare name needs 0.86")
        let rare = try XCTUnwrap(ranked.first { $0.sourceID == "2610.00011" })
        XCTAssertEqual(rare.reason, .sameAuthor("Chongkai Gao"))
        XCTAssertEqual(rare.score, 0.895, accuracy: 0.001, "+0.03 for a shared author")
        XCTAssertFalse(ranked.contains { $0.reason == .sameAuthor("Wei Zhang") })
        // Initials and one-word names never count.
        XCTAssertNil(RelatedPapers.sharedAuthors(["W. Zhang"], ["w zhang": "W. Zhang"], authorPapers: { _ in 1 }, settings: .init()))
        XCTAssertEqual(RelatedPapers.normalizedName("José  García-López"), "jose garcia lopez")
    }

    func testLibraryPapersDuplicatesAndOtherRevisionsAreLeftOut() throws {
        let pool = pool([("2610.00020", 0.99), ("2610.00021", 0.93), ("2610.00022", 0.91), ("2610.00023", 0.90)])
        let nearest = try XCTUnwrap(RelatedPapers.nearest(to: "2610.00001v3", in: pool, excluding: ["2610.00021v2"]))
        XCTAssertFalse(nearest.contains { $0.sourceID == "2610.00020" }, "0.99: the same work under another identifier")
        XCTAssertFalse(nearest.contains { $0.sourceID == "2610.00021" }, "in the reader's library (any version)")
        let known = [facts("2610.00022", "Sparse Mixture of Experts without load balancing"), facts("2610.00023", "Different Title")]
        let ranked = RelatedPapers.rank(opened: opened, nearest: nearest, facts: Dictionary(uniqueKeysWithValues: known.map { ($0.sourceID, $0) }),
                                        authorPapers: { _ in 1 })
        XCTAssertEqual(ranked.map(\.sourceID), ["2610.00023"], "the same title is the same work")
        XCTAssertNil(RelatedPapers.nearest(to: "2501.99999", in: pool, excluding: []), "not in the window: no fingerprint")
    }

    func testCandidatesNearlyIdenticalToEachOtherKeepTheBetterOne() {
        var v1 = [Float](repeating: 0, count: 384), v2 = v1, v3 = v1
        v1[0] = 1
        v2[0] = 0.92; v2[1] = (1 - 0.92 * 0.92).squareRoot()
        v3[0] = 0.915; v3[1] = (1 - 0.915 * 0.915).squareRoot()
        let pool = InterestPool(sourceIDs: ["a.1", "2610.00030", "2610.00031"].map { $0 == "a.1" ? "2610.00001" : $0 }, vectors: [v1, v2, v3])
        let nearest = RelatedPapers.nearest(to: "2610.00001", in: pool, excluding: []) ?? []
        XCTAssertEqual(nearest.map(\.sourceID), ["2610.00030"], "two copies of one work show once")
    }

    func testFallbackFromFeedResults() {
        let candidates = [
            facts("2610.00040", "Shares a specific topic", topics: ["Mixture of experts", "Quantization"]),
            facts("2610.00041", "Shares only a generic topic", topics: ["Large language models"]),
            facts("2610.00042", "Two shared authors", authors: ["Chongkai Gao", "Amir Rahmani"]),
            facts("2610.00043", "One rare name, no topic", authors: ["Chongkai Gao"]),
            facts("2610.00044", "In the library", topics: ["Mixture of experts"]),
            facts("2610.00045", "Namesake and topic", authors: ["Wei Zhang"], topics: ["Mixture of experts"]),
        ]
        let counts = ["wei zhang": 9]
        let ranked = RelatedPapers.rankByMetadata(opened: opened, candidates: candidates + [opened], excluding: ["2610.00044"],
                                                  authorPapers: { counts[$0] ?? 1 })
        XCTAssertEqual(ranked.map(\.sourceID), ["2610.00042", "2610.00045", "2610.00040"])
        XCTAssertEqual(ranked.map(\.reason.text), ["Same authors: Chongkai Gao", "Shares Mixture of experts", "Shares Mixture of experts"],
                       "the namesake's paper is listed for its topic, never as the same author")
        XCTAssertTrue(RelatedPapers.rankByMetadata(opened: opened, candidates: [], excluding: [], authorPapers: { _ in 1 }).isEmpty)
    }

    func testCommonTopicsInTheKnownPapersAreGeneric() {
        let papers = (0 ..< 10).map { facts(String(format: "2610.%05d", 100 + $0), "P\($0)", topics: $0 < 4 ? ["Quantization"] : ["Planning"]) }
        XCTAssertEqual(RelatedPapers.commonTopics(papers), ["quantization", "planning"])
        XCTAssertEqual(RelatedPapers.commonTopics(Array(papers.prefix(5))), [], "too few papers to say")
    }

    /// Ranking a whole window on this machine: 8,000 × 384 (well under 100 ms is the device target).
    func testRankingTheWindowIsFast() throws {
        var generator = SystemRandomNumberGenerator()
        let count = 8_000
        var ids: [String] = [], rows: [[Float]] = []
        for i in 0 ..< count {
            ids.append(String(format: "2610.%05d", i))
            rows.append((0 ..< 384).map { _ in Float.random(in: -1 ... 1, using: &generator) })
        }
        let pool = InterestPool(sourceIDs: ids, vectors: rows)
        let started = Date()
        var total = 0
        for i in 0 ..< 20 { total += RelatedPapers.nearest(to: ids[i * 7], in: pool, excluding: [])?.count ?? 0 }
        let perQuery = Date().timeIntervalSince(started) / 20
        print("related: nearest over \(count) × 384 took \(String(format: "%.2f", perQuery * 1000)) ms per query")
        XCTAssertLessThan(perQuery, 0.1)
        _ = total
    }
}

/// arXiv's export API answer for an `id_list` query, read on the device for related papers it has no Feed result for.
final class ArxivAtomListingTests: XCTestCase {
    func testReadsEntries() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:arxiv="http://arxiv.org/schemas/atom">
          <title>arXiv Query</title>
          <entry>
            <id>http://arxiv.org/abs/2610.01234v2</id>
            <published>2026-10-20T17:59:59Z</published>
            <title>Sparse   Mixture-of-Experts
              Scaling</title>
            <summary>  We show that expert routing works.  </summary>
            <author><name>Mei Lin</name></author>
            <author><name>Jonas Weber</name><arxiv:affiliation>X</arxiv:affiliation></author>
            <arxiv:primary_category term="cs.LG" scheme="http://arxiv.org/schemas/atom"/>
            <category term="cs.LG" scheme="http://arxiv.org/schemas/atom"/>
            <category term="cs.CL" scheme="http://arxiv.org/schemas/atom"/>
          </entry>
          <entry>
            <id>http://arxiv.org/api/errors#incorrect_id_format_for_x</id>
            <title>Error</title>
          </entry>
        </feed>
        """
        let results = ArxivAtomListing.parse(Data(xml.utf8))
        XCTAssertEqual(results.count, 1)
        let paper = results[0]
        XCTAssertEqual(paper.sourceID, "2610.01234"); XCTAssertEqual(paper.revision, 2)
        XCTAssertEqual(paper.title, "Sparse Mixture-of-Experts Scaling")
        XCTAssertEqual(paper.authors, ["Mei Lin", "Jonas Weber"])
        XCTAssertEqual(paper.abstract, "We show that expert routing works.")
        XCTAssertEqual(paper.year, 2026)
        XCTAssertEqual(paper.categories, ["cs.LG", "cs.CL"])
        XCTAssertNil(paper.reason); XCTAssertNil(paper.upvotes)
    }

    func testRefusesDocumentTypesAndBuildsTheQuery() {
        XCTAssertTrue(ArxivAtomListing.parse(Data("<!DOCTYPE feed [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><feed>&x;</feed>".utf8)).isEmpty)
        XCTAssertEqual(ArxivAtomListing.url(for: ["2610.01234v3", "hep-th/9901001"])?.absoluteString,
                       "https://export.arxiv.org/api/query?id_list=2610.01234,hep-th/9901001&max_results=2")
        XCTAssertNil(ArxivAtomListing.url(for: ["not an id"]))
        XCTAssertNil(ArxivAtomListing.url(for: []))
    }
}
