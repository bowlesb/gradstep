import Foundation
import XCTest
@testable import ScienceReaderCore

final class RecommendationsTests: XCTestCase {
    func testStreamEventsDecodeAcrossAnyChunkingAndIgnoreUnknownLines() throws {
        let paper = #"{"source_id":"2410.00001","revision":1,"title":"Generative retrieval with learned codes","authors":["E. Five"],"year":2026,"reason":"Same task; learns the codes","status":"added","import_id":"0F7A1F2E-1111-4222-8333-444455556666"}"#
        let stream = ": open\n\ndata: {\"type\":\"status\",\"phase\":\"searching\"}\n\n: ping\n\n"
            + "data: {\"type\":\"status\",\"phase\":\"choosing\",\"candidates\":34}\r\n\r\n"
            + "data: {\"type\":\"paper\",\"ordinal\":1,\"paper\":\(paper)}\n\n"
            + "event: other\ndata: {\"type\":\"future\",\"x\":1}\n\n"
            + "data: {\"type\":\"done\",\"added\":1,\"requested\":3,\"credits\":1,\"charged\":true}\n\n"
        let expected: [RecommendEvent] = [.searching, .choosing(candidates: 34),
            .paper(ordinal: 1, RecommendedPaper(sourceID: "2410.00001", revision: 1, title: "Generative retrieval with learned codes",
                authors: ["E. Five"], year: 2026, reason: "Same task; learns the codes", status: .added,
                importID: UUID(uuidString: "0F7A1F2E-1111-4222-8333-444455556666"))),
            .done(RecommendDone(added: 1, requested: 3, credits: 1, charged: true, reason: nil))]
        for size in [1, 5, 64, 10_000] {
            var parser = RecommendSSEParser(), events: [RecommendEvent] = []
            let bytes = Array(stream.utf8)
            for start in stride(from: 0, to: bytes.count, by: size) { events += try parser.consume(bytes[start..<min(start + size, bytes.count)]) }
            events += try parser.finish()
            XCTAssertEqual(events, expected, "chunk \(size)")
        }
        var parser = RecommendSSEParser()
        XCTAssertEqual(try parser.consume(Array("data: {\"type\":\"error\",\"code\":\"daily_limit\",\"charged\":false,\"retry_after\":60}".utf8)), [])
        XCTAssertEqual(try parser.finish(), [.failed(RecommendFailure(code: "daily_limit", retryAfter: 60))], "a last line without a newline")
        let none = try XCTUnwrap(RecommendSSEParser.decode(Data(#"{"type":"done","added":0,"requested":3,"credits":0,"charged":false,"reason":"none_related"}"#.utf8)))
        XCTAssertEqual(none, .done(RecommendDone(added: 0, requested: 3, credits: 0, charged: false, reason: "none_related")))
        let present = try XCTUnwrap(RecommendSSEParser.decode(Data(#"{"type":"paper","ordinal":2,"paper":{"source_id":"2410.00002","title":"T","authors":[],"reason":"R","status":"present","import_id":null}}"#.utf8)))
        guard case .paper(_, let p) = present else { return XCTFail() }
        XCTAssertEqual(p.status, .present); XCTAssertNil(p.importID); XCTAssertNil(p.year)
        XCTAssertThrowsError(try RecommendSSEParser.decode(Data("not json".utf8)))
        var long = RecommendSSEParser()
        XCTAssertThrowsError(try long.consume(Array(repeating: UInt8(ascii: "a"), count: RecommendSSEParser.maximumLineBytes + 1)))
    }

    func testRequestBodyKeepsOnlyWhatTheServerAccepts() throws {
        let id = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000143")!
        let paper = try XCTUnwrap(RecommendRequestBody.make(operationID: id, count: 3, scope: .paper, seeds: [
            (sourceID: "2401.00001", keywords: ["  Generative   retrieval ", "generative retrieval", "x", "Mixture-of-Experts (MoE)",
                                               "title:\"x\" OR *", String(repeating: "a", count: 61), "Dense retrieval", "Reranking", "Index", "Codes", "More"])]))
        XCTAssertEqual(paper.seeds, [.init(sourceID: "2401.00001", keywords: ["Generative retrieval", "Mixture-of-Experts (MoE)", "Dense retrieval", "Reranking", "Index", "Codes"])])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(paper)) as? [String: Any])
        XCTAssertEqual(json["operation_id"] as? String, "bbbbbbbb-0000-4000-8000-000000000143")
        XCTAssertEqual(json["scope"] as? String, "paper"); XCTAssertEqual(json["count"] as? Int, 3)
        XCTAssertEqual(Set(json.keys), ["operation_id", "count", "scope", "seeds"])
        XCTAssertNil(RecommendRequestBody.make(operationID: id, count: 2, scope: .paper, seeds: [(sourceID: "2401.00001", keywords: [])]))
        XCTAssertNil(RecommendRequestBody.make(operationID: id, count: 3, scope: .paper, seeds: [(sourceID: "local:abc", keywords: [])]))
        XCTAssertEqual(RecommendRequestBody.make(operationID: id, count: 1, scope: .paper, seeds: [(sourceID: "openalex:W2963403868", keywords: [])])?.seeds.count, 1)
        let catalog = try XCTUnwrap(RecommendRequestBody.make(operationID: id, count: 5, scope: .catalog,
            seeds: (0..<12).map { (sourceID: String(format: "2401.%05d", $0), keywords: ["One keyword", "Two keyword", "Three keyword", "Four keyword"]) }
                + [(sourceID: "upload:x", keywords: [])]))
        XCTAssertEqual(catalog.seeds.count, 8); XCTAssertEqual(catalog.seeds[0].keywords.count, 3, "three per catalog seed")
        XCTAssertTrue(Recommendations.isEligibleSourceID("hep-th/9711200"))
        XCTAssertFalse(Recommendations.isEligibleSourceID("https://arxiv.org/abs/2401.00001"))
    }

    func testCatalogSeedsAreTheNewestEligiblePapers() {
        struct Row { let source: String?; let added: Date? }
        let now = Date()
        let rows = (0..<10).map { Row(source: String(format: "2401.%05d", $0), added: now - Double($0) * 3600) }
            + [Row(source: "local:pdf", added: now + 100), Row(source: nil, added: now + 200), Row(source: "2402.00001", added: nil)]
        let seeds = Recommendations.catalogSeeds(rows, sourceID: \.source, addedAt: \.added)
        XCTAssertEqual(seeds.map(\.source), (0..<8).map { String(format: "2401.%05d", $0) })
    }

    func testMessagesNameTheOutcome() {
        XCTAssertEqual(Recommendations.message(for: "daily_limit"), "You’ve asked for recommendations 20 times today. Try again tomorrow.")
        XCTAssertEqual(Recommendations.message(for: "insufficient_credits"), "You’re out of AI credits.")
        XCTAssertTrue(Recommendations.message(for: "anything").hasSuffix("Nothing was charged."))
    }
}
