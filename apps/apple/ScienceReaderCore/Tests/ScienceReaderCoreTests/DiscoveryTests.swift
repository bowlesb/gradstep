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
}
