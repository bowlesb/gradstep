import Foundation
import XCTest
@testable import ScienceReaderCore

final class DiscoveryTests: XCTestCase {
    private func decode(_ fields: [String: Any]) throws -> DiscoveryResponse {
        var row: [String: Any] = ["source_id": "2305.18290", "revision": 3, "title": "DPO", "authors": [], "categories": []]
        row.merge(fields) { _, new in new }
        return try JSONDecoder().decode(DiscoveryResponse.self, from: JSONSerialization.data(withJSONObject: ["results": [row]]))
    }

    func testFullAbstractPreservesTheEndingBeyondTheLegacyPreview() throws {
        let full = String(repeating: "Grounded result. ", count: 200) + "The final limitation."
        let result = try XCTUnwrap(decode(["abstract": String(full.prefix(700)), "full_abstract": full, "abstract_truncated": false]).results.first)
        XCTAssertEqual(result.abstract, full)
        XCTAssertFalse(result.abstractTruncated)
        let old = try XCTUnwrap(decode(["abstract": String(full.prefix(700))]).results.first)
        XCTAssertTrue(old.abstractTruncated, "An older server's preview must not pretend to be the full abstract")
    }

    func testAbstractBoundsAndExplicitExcerptSurviveDecoding() throws {
        let maximum = String(repeating: "λ", count: 24_000)
        let excerpt = try XCTUnwrap(decode(["abstract": "Preview", "full_abstract": maximum, "abstract_truncated": true]).results.first)
        XCTAssertTrue(excerpt.abstractTruncated)
        XCTAssertEqual(excerpt.abstract, maximum)
        XCTAssertTrue(try decode(["full_abstract": maximum + "x"]).results.isEmpty)
        XCTAssertTrue(try decode(["abstract": String(repeating: "x", count: 2_001)]).results.isEmpty)
    }

    /// Feed topics and popularity (migration 048): extras decode when present, are dropped when malformed, and never
    /// cost the paper.
    func testTopicsUpvotesAndReasonDecodeLeniently() throws {
        let result = try XCTUnwrap(decode(["topics": ["State space models", "Tokenization"], "upvotes": 162,
                                           "reason": ["kind": "trending", "label": "162", "text": "Popular on Hugging Face Papers"]]).results.first)
        XCTAssertEqual(result.topics, ["State space models", "Tokenization"])
        XCTAssertEqual(result.upvotes, 162)
        XCTAssertEqual(result.reason?.text, "Popular on Hugging Face Papers")
        XCTAssertEqual(result.reason?.kind, "trending")
        let plain = try XCTUnwrap(decode([:]).results.first)
        XCTAssertEqual(plain.topics, [])
        XCTAssertNil(plain.upvotes, "an older server: unknown, not zero")
        XCTAssertNil(plain.reason)
        let odd = try XCTUnwrap(decode(["topics": "Tokenization", "upvotes": -4, "reason": ["kind": "Bad Kind!", "label": "", "text": "x"]]).results.first)
        XCTAssertEqual(odd.topics, [])
        XCTAssertNil(odd.upvotes)
        XCTAssertNil(odd.reason)
        XCTAssertNil(try decode(["upvotes": 2_000_000]).results.first?.upvotes)
        XCTAssertNil(try decode(["upvotes": NSNull()]).results.first?.upvotes)
        let long = try XCTUnwrap(decode(["topics": [String(repeating: "x", count: 41), "", "Tokenization"]]).results.first)
        XCTAssertEqual(long.topics, ["Tokenization"])
    }

    func testFeedInfoCarriesForYouAndTheReadersTopicChips() throws {
        let body: [String: Any] = ["results": [], "feed": ["for_you": true, "cold_start": false, "ranking": "feed-heuristic-v2", "topics": [
            ["name": "RL for reasoning", "kind": "combined", "papers": 120], ["name": "Tokenization", "kind": "topic", "papers": 30],
            ["name": " padded", "kind": "topic"], ["name": "tokenization", "kind": "own"], ["kind": "topic"]]]]
        let response = try JSONDecoder().decode(DiscoveryResponse.self, from: JSONSerialization.data(withJSONObject: body))
        let feed = try XCTUnwrap(response.feed)
        XCTAssertTrue(feed.forYou)
        XCTAssertEqual(feed.topics.map(\.name), ["RL for reasoning", "Tokenization"], "invalid and repeated chips are skipped")
        XCTAssertEqual(feed.topics.first?.papers, 120)
        let topic = try JSONDecoder().decode(DiscoveryResponse.self, from: Data(#"{"results":[],"feed":{"for_you":true,"topic":{"name":"Tokenization","kind":"topic"}}}"#.utf8))
        XCTAssertEqual(topic.feed?.topic?.name, "Tokenization")
        XCTAssertEqual(topic.feed?.topics, [])
        XCTAssertNil(try JSONDecoder().decode(DiscoveryResponse.self, from: Data(#"{"results":[]}"#.utf8)).feed)
        XCTAssertEqual(try JSONDecoder().decode(DiscoveryResponse.self, from: Data(#"{"results":[],"feed":{"for_you":true}}"#.utf8)).feed,
                       FeedInfo(forYou: true))
    }
}
