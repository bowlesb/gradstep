import XCTest
import ScienceReaderCore
@testable import ScienceReader

/// The person's search from this device (docs/architecture/ARXIV_DEVICE_ONLY.md §5.6): arXiv's API through the device's
/// single paced queue, the shared order (paper-search.ts in JavaScriptCore), a day's cache per query, and the refusal
/// stop. Answers recorded by scripts/search-eval.mjs (tests/backend/fixtures/search); nothing leaves the process.
final class DeviceSearchTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("tests/backend/fixtures/search/\(name)"), encoding: .utf8)
    }
    private struct Setup { let search: DeviceSearch; let clock: SearchClock; let suite: String; let folders: [URL] }
    private func setup(_ answers: [(Int, String)]) -> Setup {
        let suite = "arxiv.search.test.\(UUID().uuidString)"
        let folders = [FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)]
        let clock = SearchClock(Date(timeIntervalSince1970: 1_800_000_000))
        ArxivAPIFixture.reset(answers)
        ArxivMetadataFetcher.fixtureProtocolClasses = [ArxivAPIFixture.self]
        let fetcher = ArxivMetadataFetcher(defaultsSuite: suite, cacheDirectory: folders[0], now: { clock.now }, sleep: { clock.advance($0) })
        return Setup(search: DeviceSearch(fetcher: fetcher, cacheDirectory: folders[1], now: { clock.now }), clock: clock, suite: suite, folders: folders)
    }
    private func tearDown(_ setup: Setup) {
        ArxivMetadataFetcher.fixtureProtocolClasses = nil
        UserDefaults(suiteName: setup.suite)?.removePersistentDomain(forName: setup.suite)
        for folder in setup.folders { try? FileManager.default.removeItem(at: folder) }
    }

    func testASearchAsksArxivPacedAndNamedOrdersTheOriginalFirstAndIsKeptForADay() async throws {
        let s = setup([(200, try fixture("arxiv-dpo-relevance.xml")), (200, try fixture("arxiv-dpo-phrase.xml")),
                       (200, try fixture("arxiv-dpo-relevance.xml")), (200, try fixture("arxiv-dpo-phrase.xml"))])
        defer { tearDown(s) }
        let results = try await s.search.search("direct preference optimization")
        XCTAssertEqual(results.first?.sourceID, "2305.18290")
        XCTAssertEqual(results.first?.revision, 3)
        XCTAssertFalse(results.first?.topics.isEmpty ?? true)
        XCTAssertEqual(ArxivAPIFixture.requests.count, 2)
        for request in ArxivAPIFixture.requests {
            XCTAssertEqual(request.url?.host, "export.arxiv.org")
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Gradstep/") == true)
        }
        XCTAssertTrue(ArxivAPIFixture.requests[0].url?.absoluteString.contains("sortBy=relevance") == true)
        XCTAssertTrue(ArxivAPIFixture.requests[1].url?.absoluteString.contains("sortBy=submittedDate") == true)
        XCTAssertEqual(s.clock.slept, [3], "the second request waits its 3 s")
        // The same search in other case and spacing comes from this device's cache.
        let again = try await s.search.search("  Direct Preference   Optimization ")
        XCTAssertEqual(again.map(\.sourceID), results.map(\.sourceID))
        XCTAssertEqual(ArxivAPIFixture.requests.count, 2)
        // A day later it is asked again.
        s.clock.advance(86_401)
        _ = try await s.search.search("direct preference optimization")
        XCTAssertEqual(ArxivAPIFixture.requests.count, 4)
    }

    func testAShortAnswerAlsoAsksForAnyWordAndAnIDIsOneRequest() async throws {
        let s = setup([(200, try fixture("arxiv-misspelling-relevance.xml")), (200, try fixture("arxiv-misspelling-phrase.xml")),
                       (200, try fixture("arxiv-misspelling-broad.xml")), (200, try fixture("arxiv-id-id.xml"))])
        defer { tearDown(s) }
        let results = try await s.search.search("difusion model distilation")
        XCTAssertEqual(ArxivAPIFixture.requests.count, 3)
        XCTAssertTrue(ArxivAPIFixture.requests[2].url?.absoluteString.contains("+OR+") == true)
        XCTAssertFalse(results.isEmpty)
        let id = try await s.search.search("https://arxiv.org/abs/2305.18290")
        XCTAssertEqual(id.map(\.sourceID), ["2305.18290"])
        XCTAssertEqual(ArxivAPIFixture.requests.count, 4)
        XCTAssertTrue(ArxivAPIFixture.requests[3].url?.absoluteString.contains("id_list=2305.18290") == true)
    }

    func testAfterARefusalTheDeviceDoesNotSearchArxivAndSaysSo() async throws {
        let s = setup([(403, "")])
        defer { tearDown(s) }
        do { _ = try await s.search.search("speculative decoding"); XCTFail("refused") }
        catch { XCTAssertEqual(error as? DeviceSearch.Failure, .paused) }
        do { _ = try await s.search.search("kv cache compression"); XCTFail("still refused") }
        catch { XCTAssertEqual(error as? DeviceSearch.Failure, .paused) }
        XCTAssertEqual(ArxivAPIFixture.requests.count, 1, "nothing after the refusal")
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
