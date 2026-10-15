import XCTest
import ScienceReaderCore
@testable import ScienceReader

/// Device-read paper metadata (docs/architecture/ARXIV_DEVICE_ONLY.md §5.3, §5.9): the shared extractor in JavaScriptCore,
/// one report per import and version, and the export API fallback's pacing, refusal pause, cache and identification.
final class SourceMetadataReporterTests: XCTestCase {
    private let html = """
    <!DOCTYPE html><html><head><title>Fallback</title></head><body>
    <div class="ltx_page_header"><a id="license-tr" href="#">License: CC BY 4.0</a><div id="watermark-tr">arXiv:2305.18290v3 [cs.LG] 29 Jul 2024</div></div>
    <article class="ltx_document"><h1 class="ltx_title ltx_title_document">Direct Preference Optimization</h1>
    <div class="ltx_authors"><span class="ltx_creator ltx_role_author"><span class="ltx_personname">Rafael Rafailov<sup>1</sup></span></span>
    <span class="ltx_creator ltx_role_author"><span class="ltx_personname">Chelsea Finn<br>Stanford</span></span></div>
    <div class="ltx_abstract"><p class="ltx_p">A simple classification loss.</p></div></article></body></html>
    """
    private let atom = """
    <?xml version='1.0' encoding='UTF-8'?><feed xmlns:arxiv="http://arxiv.org/schemas/atom" xmlns="http://www.w3.org/2005/Atom">
    <entry><id>http://arxiv.org/abs/2305.18290v3</id><title>Direct Preference Optimization</title><updated>2024-07-29T22:26:36Z</updated>
    <summary>A simple classification loss.</summary><category term="cs.LG" scheme="http://arxiv.org/schemas/atom"/><arxiv:primary_category term="cs.LG"/>
    <author><name>Rafael Rafailov</name></author></entry></feed>
    """

    private func source() throws -> ArxivReaderSource { try ArxivReaderSource(sourceID: "2305.18290", revision: 3) }
    private func object(_ data: Data?) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any]) }

    func testTheSharedExtractorReadsThePageAndTheAtomAnswer() throws {
        let extractor = try XCTUnwrap(SourceMetadataExtractor())
        let page = try object(extractor.extract(html: Data(html.utf8), source: source()))
        XCTAssertEqual(page["format"] as? String, "arxiv-source-metadata-v1")
        XCTAssertEqual(page["origin"] as? String, "arxiv_html")
        XCTAssertEqual(page["title"] as? String, "Direct Preference Optimization")
        XCTAssertEqual(page["authors"] as? [String], ["Rafael Rafailov", "Chelsea Finn"])
        XCTAssertEqual(page["license_uri"] as? String, "https://creativecommons.org/licenses/by/4.0/")
        XCTAssertEqual(page["version_date"] as? String, "2024-07-29")
        // Another version's page gives nothing.
        XCTAssertNil(extractor.extract(html: Data(html.utf8), source: try ArxivReaderSource(sourceID: "2305.18290", revision: 2)))
        let api = try object(extractor.fromAtom(atom, source: source()))
        XCTAssertEqual(api["origin"] as? String, "arxiv_api")
        XCTAssertEqual(api["categories"] as? [String], ["cs.LG"])
        XCTAssertTrue(api["license_uri"] is NSNull)
    }

    func testEachImportAndVersionIsReportedOnceAndAFailedSendIsTriedAgain() async throws {
        let sent = SentRecorder()
        let reporter = SourceMetadataReporter { importID, metadata, revision in try await sent.record(importID, metadata, revision) }
        let importID = UUID()
        await sent.fail(next: true)
        var reported = await reporter.report(html: Data(html.utf8), source: try source(), importID: importID)
        XCTAssertFalse(reported, "the server refused; nothing is remembered")
        reported = await reporter.report(html: Data(html.utf8), source: try source(), importID: importID)
        XCTAssertTrue(reported)
        reported = await reporter.report(html: Data(html.utf8), source: try source(), importID: importID)
        XCTAssertFalse(reported, "already sent for this import and version")
        let calls = await sent.calls
        XCTAssertEqual(calls.count, 2); XCTAssertEqual(calls.last?.revision, 3); XCTAssertEqual(calls.last?.importID, importID)
    }

    func testTheExportAPIFallbackIsPacedNamedCachedAndPausedForADayAfterARefusal() async throws {
        let suite = "arxiv.metadata.test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        ArxivAPIFixture.reset([(200, atom), (403, ""), (200, atom)])
        ArxivMetadataFetcher.fixtureProtocolClasses = [ArxivAPIFixture.self]
        defer { ArxivMetadataFetcher.fixtureProtocolClasses = nil }
        let fetcher = ArxivMetadataFetcher(defaultsSuite: suite, cacheDirectory: cache, now: { clock.now }, sleep: { clock.advance($0) })

        let first = try await fetcher.atom(for: try source())
        XCTAssertTrue(first.contains("<feed"))
        XCTAssertEqual(ArxivAPIFixture.requests.count, 1)
        let request = try XCTUnwrap(ArxivAPIFixture.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://export.arxiv.org/api/query?id_list=2305.18290v3&max_results=1")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Gradstep/") == true)
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("mailto:hello@gradstep.ai") == true)
        // A version's record never changes: the second time comes from the cache.
        _ = try await fetcher.atom(for: try source())
        XCTAssertEqual(ArxivAPIFixture.requests.count, 1)
        // The next paper waits its 3 s; arXiv refuses; the device stops asking for a day, even after a relaunch.
        let other = try ArxivReaderSource(sourceID: "2306.00001", revision: 1)
        do { _ = try await fetcher.atom(for: other); XCTFail("refused") } catch { XCTAssertEqual(error as? ArxivMetadataFetcher.Failure, .paused) }
        XCTAssertEqual(clock.slept, [3])
        let relaunched = ArxivMetadataFetcher(defaultsSuite: suite, cacheDirectory: cache, now: { clock.now }, sleep: { clock.advance($0) })
        do { _ = try await relaunched.atom(for: other); XCTFail("still paused") } catch { XCTAssertEqual(error as? ArxivMetadataFetcher.Failure, .paused) }
        XCTAssertEqual(ArxivAPIFixture.requests.count, 2, "no request while paused")
        clock.advance(86_401)
        _ = try await relaunched.atom(for: other)
        XCTAssertEqual(ArxivAPIFixture.requests.count, 3)
    }

    /// One refusal stops the whole device: after the export API's 403 the reader asks arXiv for nothing, and the reader's
    /// own 403 stops the export API (owner, 2026-10-15: stop 24 h after a 403).
    @MainActor
    func testARefusalStopsEveryArxivRequestFromTheDevice() async throws {
        let suite = "arxiv.metadata.test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        ArxivAPIFixture.reset([(403, "")])
        ArxivMetadataFetcher.fixtureProtocolClasses = [ArxivAPIFixture.self]
        ArxivHTMLReader.fixtureProtocolClasses = [ArxivAPIFixture.self]
        ArxivHTMLReader.refusalSuite = suite
        defer { ArxivMetadataFetcher.fixtureProtocolClasses = nil; ArxivHTMLReader.fixtureProtocolClasses = nil; ArxivHTMLReader.refusalSuite = nil }
        let fetcher = ArxivMetadataFetcher(defaultsSuite: suite, cacheDirectory: cache, sleep: { _ in })
        do { _ = try await fetcher.atom(for: try source()); XCTFail("refused") } catch { XCTAssertEqual(error as? ArxivMetadataFetcher.Failure, .paused) }
        do { _ = try await ArxivHTMLReader().prepare(try source()); XCTFail("the reader must not ask") }
        catch { guard case ArxivHTMLError.refused = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(ArxivAPIFixture.requests.map { $0.url?.host }, ["export.arxiv.org"], "nothing after the refusal")

        // The other way round: the reader's 403 pauses the export API.
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        ArxivAPIFixture.reset([(403, "")])
        do { _ = try await ArxivHTMLReader().prepare(try ArxivReaderSource(sourceID: "2306.00002", revision: 1)); XCTFail("refused") }
        catch { guard case ArxivHTMLError.refused = error else { return XCTFail("\(error)") } }
        let other = ArxivMetadataFetcher(defaultsSuite: suite, cacheDirectory: cache, sleep: { _ in })
        do { _ = try await other.atom(for: try ArxivReaderSource(sourceID: "2306.00003", revision: 1)); XCTFail("paused") }
        catch { XCTAssertEqual(error as? ArxivMetadataFetcher.Failure, .paused) }
        XCTAssertEqual(ArxivAPIFixture.requests.map { $0.url?.host }, ["arxiv.org"])
        // The reader's own request names the app too.
        XCTAssertTrue(ArxivAPIFixture.requests.first?.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Gradstep/") == true)
    }
}

private actor SentRecorder {
    private(set) var calls: [(importID: UUID, metadata: Data, revision: Int)] = []
    private var failNext = false
    func fail(next: Bool) { failNext = next }
    func record(_ importID: UUID, _ metadata: Data, _ revision: Int) throws {
        calls.append((importID, metadata, revision))
        if failNext { failNext = false; throw URLError(.badServerResponse) }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private(set) var slept: [TimeInterval] = []
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds); slept.append(seconds) } }
}

/// Answers export.arxiv.org and arxiv.org in-process; records each request.
final class ArxivAPIFixture: URLProtocol {
    nonisolated(unsafe) static var responses: [(Int, String)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static func reset(_ answers: [(Int, String)]) { responses = answers; requests = [] }
    override class func canInit(with request: URLRequest) -> Bool { ["export.arxiv.org", "arxiv.org"].contains(request.url?.host) }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let (status, body) = Self.responses.isEmpty ? (500, "") : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/atom+xml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
