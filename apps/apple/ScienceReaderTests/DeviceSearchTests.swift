import XCTest
import ScienceReaderCore
@testable import ScienceReader

/// The person's search from this device (docs/architecture/ARXIV_DEVICE_ONLY.md §5.6): arXiv's API through the device's
/// single paced queue, DataCite for the most cited matches and for near spellings when arXiv finds fewer than five
/// (tuning 1, §5.6.1), the shared order (paper-search.ts in JavaScriptCore), a day's cache per query, and the refusal
/// stop. Answers recorded by scripts/search-eval.mjs (tests/backend/fixtures/search); nothing leaves the process.
final class DeviceSearchTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("tests/backend/fixtures/search/\(name)"), encoding: .utf8)
    }
    private struct Setup { let search: DeviceSearch; let clock: SearchClock; let suite: String; let folders: [URL] }
    private func setup(_ answers: [(Int, String)], dataCite: [String: String] = [:]) -> Setup {
        let suite = "arxiv.search.test.\(UUID().uuidString)"
        let folders = [FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)]
        let clock = SearchClock(Date(timeIntervalSince1970: 1_800_000_000))
        ArxivAPIFixture.reset(answers)
        DataCiteFixture.reset(dataCite)
        ArxivMetadataFetcher.fixtureProtocolClasses = [ArxivAPIFixture.self]
        DataCiteSearchClient.fixtureProtocolClasses = [DataCiteFixture.self]
        let fetcher = ArxivMetadataFetcher(defaultsSuite: suite, cacheDirectory: folders[0], now: { clock.now }, sleep: { clock.advance($0) })
        let cache = try? SealedCacheFiles(directory: folders[1], accountID: UUID(), localKey: Data(repeating: 9, count: 32), namespace: "arxiv-search")
        return Setup(search: DeviceSearch(fetcher: fetcher, cache: cache, now: { clock.now }), clock: clock, suite: suite, folders: folders)
    }
    private func tearDown(_ setup: Setup) {
        ArxivMetadataFetcher.fixtureProtocolClasses = nil
        DataCiteSearchClient.fixtureProtocolClasses = nil
        UserDefaults(suiteName: setup.suite)?.removePersistentDomain(forName: setup.suite)
        for folder in setup.folders { try? FileManager.default.removeItem(at: folder) }
    }

    func testASearchAsksArxivPacedAndNamedOrdersTheOriginalFirstAndIsKeptForADay() async throws {
        let s = setup([(200, try fixture("arxiv-dpo-relevance.xml")), (200, try fixture("arxiv-dpo-phrase.xml")),
                       (200, try fixture("arxiv-dpo-relevance.xml")), (200, try fixture("arxiv-dpo-phrase.xml"))], dataCite: ["cited": #"{"data":[]}"#])
        defer { tearDown(s) }
        let results = try await s.search.search("direct preference optimization")
        XCTAssertEqual(results.first?.sourceID, "2305.18290")
        XCTAssertEqual(results.first?.revision, 3)
        XCTAssertFalse(results.first?.topics.isEmpty ?? true)
        XCTAssertEqual(ArxivAPIFixture.requests.count, 2)
        for request in ArxivAPIFixture.requests + DataCiteFixture.requests {
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Gradstep/") == true)
        }
        XCTAssertTrue(ArxivAPIFixture.requests[0].url?.absoluteString.contains("sortBy=relevance") == true)
        XCTAssertTrue(ArxivAPIFixture.requests[1].url?.absoluteString.contains("sortBy=submittedDate") == true)
        // DataCite's most cited matches, not through the arXiv queue.
        XCTAssertEqual(DataCiteFixture.requests.map { $0.url?.host }, ["api.datacite.org"])
        XCTAssertTrue(DataCiteFixture.requests[0].url?.absoluteString.contains("sort=-citation-count") == true)
        XCTAssertEqual(s.clock.slept, [3], "the second arXiv request waits its 3 s")
        // The same search in other case and spacing comes from this device's cache.
        let again = try await s.search.search("  Direct Preference   Optimization ")
        XCTAssertEqual(again.map(\.sourceID), results.map(\.sourceID))
        XCTAssertEqual(ArxivAPIFixture.requests.count, 2)
        // Kept sealed (GLOBAL_SEARCH.md "ML paper search cache"): no file holds the results or the words.
        let files = try FileManager.default.contentsOfDirectory(at: s.folders[1], includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.pathExtension, "sealed")
        let bytes = try Data(contentsOf: files[0])
        for word in ["2305.18290", "Direct Preference", "results"] { XCTAssertNil(bytes.range(of: Data(word.utf8)), word) }
        // A day later it is asked again.
        s.clock.advance(86_401)
        _ = try await s.search.search("direct preference optimization")
        XCTAssertEqual(ArxivAPIFixture.requests.count, 4)
        // Sign-out removes them.
        s.search.signedOut()
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.folders[1].path))
    }

    /// Tuning 1: arXiv finds nothing for a misspelling, so the device asks DataCite's near spellings (arXiv has none).
    func testAShortAnswerAsksDataCiteForNearSpellingsAndAnIDIsOneRequest() async throws {
        let s = setup([(200, try fixture("arxiv-misspelling-relevance.xml")), (200, try fixture("arxiv-misspelling-phrase.xml")), (200, try fixture("arxiv-id-id.xml"))],
                      dataCite: ["cited": #"{"data":[]}"#, "broad": try fixture("datacite-misspelling-broad.json")])
        defer { tearDown(s) }
        let results = try await s.search.search("difusion model distilation")
        XCTAssertEqual(ArxivAPIFixture.requests.count, 2, "no any-word request to arXiv")
        XCTAssertEqual(DataCiteFixture.requests.count, 2)
        XCTAssertTrue(DataCiteFixture.requests[1].url?.absoluteString.contains("difusion~1") == true || DataCiteFixture.requests[1].url?.absoluteString.contains("difusion%7E1") == true)
        XCTAssertTrue(results.prefix(3).allSatisfy { $0.title.localizedCaseInsensitiveContains("distill") && $0.title.localizedCaseInsensitiveContains("diffusion") })
        let id = try await s.search.search("https://arxiv.org/abs/2305.18290")
        XCTAssertEqual(id.map(\.sourceID), ["2305.18290"])
        XCTAssertEqual(ArxivAPIFixture.requests.count, 3)
        XCTAssertEqual(DataCiteFixture.requests.count, 2, "an ID is arXiv alone")
    }

    /// Tuning 2 (rule 6): a landmark the word matching missed joins from DataCite's most cited matches.
    func testAWellKnownPaperTheWordsMissedJoinsFromTheMostCited() async throws {
        let s = setup([(200, try fixture("vit-arxiv-relevance.xml")), (200, try fixture("vit-arxiv-phrase.xml"))], dataCite: ["cited": try fixture("vit-datacite-cited.json")])
        defer { tearDown(s) }
        let results = try await s.search.search("vision transformer")
        XCTAssertTrue(results.prefix(2).contains { $0.sourceID == "2010.11929" }, results.prefix(3).map(\.title).joined(separator: " | "))
    }

    func testAfterARefusalTheDeviceDoesNotSearchArxivAndSaysSo() async throws {
        let s = setup([(403, "")])
        defer { tearDown(s) }
        do { _ = try await s.search.search("speculative decoding"); XCTFail("refused") }
        catch { XCTAssertEqual(error as? DeviceSearch.Failure, .paused) }
        do { _ = try await s.search.search("kv cache compression"); XCTFail("still refused") }
        catch { XCTAssertEqual(error as? DeviceSearch.Failure, .paused) }
        XCTAssertEqual(ArxivAPIFixture.requests.count, 1, "nothing after the refusal")
        XCTAssertEqual(DataCiteFixture.requests.count, 0)
        XCTAssertNotNil(ArxivDeviceRefusal(suite: s.suite).until(now: s.clock.now))
    }

    func testAFailedAnswerIsAFailureNeverAnEmptyList() async throws {
        let s = setup([(500, "")])
        defer { tearDown(s) }
        do { _ = try await s.search.search("speculative decoding"); XCTFail("failed") }
        catch { XCTAssertEqual(error as? DeviceSearch.Failure, .unavailable) }
        let empty = try await s.search.search("   ")
        XCTAssertEqual(empty, [])
    }
}

private final class SearchClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private(set) var slept: [TimeInterval] = []
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds); slept.append(seconds) } }
}

/// Answers api.datacite.org in-process: the most cited matches (`sort=-citation-count`), near spellings (`~1`), else
/// relevance; records each request.
final class DataCiteFixture: URLProtocol {
    nonisolated(unsafe) static var answers: [String: String] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static func reset(_ byRole: [String: String]) { answers = byRole; requests = [] }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.datacite.org" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let url = request.url?.absoluteString.removingPercentEncoding ?? ""
        let role = url.contains("sort=-citation-count") ? "cited" : url.contains("~1") ? "broad" : "relevance"
        let body = Self.answers[role] ?? #"{"data":[]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/vnd.api+json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
