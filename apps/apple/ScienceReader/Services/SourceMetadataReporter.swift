import Foundation
import JavaScriptCore
import ScienceReaderCore

// Device-read paper metadata (docs/architecture/ARXIV_DEVICE_ONLY.md §5.2–5.3, §5.9). Owner direction, 2026-10-15: our
// servers never contact arXiv; this device reads a paper's title, authors, abstract, licence and version date from the
// arXiv HTML it already downloaded to prepare the paper (zero extra requests), or, for a paper without HTML, from one
// paced request to the export API, and sends that to the server for its own import. Everything here runs only while
// the server's `source_metadata` capability is on.

/// The shared TypeScript extractor (arxiv-source-metadata.js; the same code the browser runs and the server's tests
/// check) in JavaScriptCore. No DOM, no network: it parses the bytes it is given.
final class SourceMetadataExtractor {
    private let context: JSContext
    private let module: JSValue

    init?() {
        guard let url = Bundle.main.url(forResource: "arxiv-source-metadata", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8), let context = JSContext() else { return nil }
        context.exceptionHandler = { _, _ in }
        context.evaluateScript(script)
        guard let module = context.objectForKeyedSubscript("GradstepSourceMetadata"), module.isObject, context.exception == nil else { return nil }
        self.context = context; self.module = module
    }

    /// The record read from a paper's arXiv HTML, as the contract's JSON, or nil.
    func extract(html: Data, source: ArxivReaderSource) -> Data? { call("extract", String(decoding: html, as: UTF8.self), source) }
    /// The record from the export API's Atom answer for exactly this version, or nil.
    func fromAtom(_ xml: String, source: ArxivReaderSource) -> Data? { call("fromAtom", xml, source) }

    private func call(_ method: String, _ text: String, _ source: ArxivReaderSource) -> Data? {
        context.exception = nil
        guard let result = module.invokeMethod(method, withArguments: [text, source.sourceID, source.revision]),
              context.exception == nil, let json = result.toString(), json != "null", json.utf8.count <= 30_000 else { return nil }
        return Data(json.utf8)
    }
}

/// The export API for a paper without HTML: one request at a time from this device, at least 3 s apart, Retry-After
/// honoured, a day's pause after a refusal (403) shared with the reader's own requests (`ArxivDeviceRefusal`), each
/// answer cached (a version's record never changes), and the app named in the User-Agent. Only for a paper this
/// account added, only when the person opens or downloads it on this device, only while the capability is on.
actor ArxivMetadataFetcher {
    static let shared = ArxivMetadataFetcher()
    enum Failure: Error, Equatable { case paused, notFound, unavailable, invalid }

    static var userAgent: String { ArxivAcquisitionPolicy.userAgent }
    #if DEBUG
    /// Tests only: protocols that answer in-process (nothing leaves the process).
    nonisolated(unsafe) static var fixtureProtocolClasses: [AnyClass]?
    #endif

    private let defaults: UserDefaults
    private let refusal: ArxivDeviceRefusal
    private let cacheDirectory: URL?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var pacer: ArxivRequestPacer
    private var busy = false
    private static let pacerKey = "arxiv.metadata.pacer"

    /// `defaultsSuite`: where the pacing survives a relaunch (tests pass their own suite).
    init(defaultsSuite: String? = nil,
         cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("arxiv-metadata", isDirectory: true),
         now: @escaping @Sendable () -> Date = Date.init,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        let defaults = defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.defaults = defaults; self.refusal = ArxivDeviceRefusal(suite: defaultsSuite)
        self.cacheDirectory = cacheDirectory; self.now = now; self.sleep = sleep
        pacer = defaults.data(forKey: Self.pacerKey).flatMap { try? JSONDecoder().decode(ArxivRequestPacer.self, from: $0) } ?? ArxivRequestPacer()
    }

    static func url(for source: ArxivReaderSource) -> URL {
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [URLQueryItem(name: "id_list", value: "\(source.sourceID)v\(source.revision)"), URLQueryItem(name: "max_results", value: "1")]
        return components.url!
    }
    private func cacheFile(_ source: ArxivReaderSource) -> URL? {
        cacheDirectory?.appendingPathComponent("\(source.sourceID.replacingOccurrences(of: "/", with: "_"))v\(source.revision).xml")
    }

    /// The Atom answer for exactly this version.
    func atom(for source: ArxivReaderSource) async throws -> String {
        if let file = cacheFile(source), let cached = try? String(contentsOf: file, encoding: .utf8) { return cached }
        // One connection at a time from this device.
        while busy { try await sleep(0.2) }
        busy = true
        defer { busy = false }
        let start = now()
        guard refusal.until(now: start) == nil, let scheduled = pacer.reserve(now: start) else { save(); throw Failure.paused }
        save()
        if scheduled > start { try await sleep(scheduled.timeIntervalSince(start)) }
        try Task.checkCancellation()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        #if DEBUG
        if let protocols = Self.fixtureProtocolClasses { config.protocolClasses = protocols }
        #endif
        let session = URLSession(configuration: config, delegate: MetadataNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: Self.url(for: source), cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw Failure.unavailable }
        guard let http = response as? HTTPURLResponse else { throw Failure.invalid }
        pacer.record(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init), now: now())
        save()
        if http.statusCode == 403 { refusal.record(now: now()) }
        switch http.statusCode {
        case 200: break
        case 403, 429, 503: throw Failure.paused
        case 404: throw Failure.notFound
        default: throw Failure.unavailable
        }
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8), text.contains("<feed") else { throw Failure.invalid }
        if let file = cacheFile(source) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: file, options: [.atomic])
        }
        return text
    }

    private func save() { if let data = try? JSONEncoder().encode(pacer) { defaults.set(data, forKey: Self.pacerKey) } }
}

private final class MetadataNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Sends what this device read about a paper to the server, once per import and version.
actor SourceMetadataReporter {
    typealias Submit = @Sendable (_ importID: UUID, _ metadata: Data, _ revision: Int) async throws -> Void
    private let submit: Submit
    private var sent: Set<String> = []
    private var extractor: SourceMetadataExtractor?
    private var extractorLoaded = false

    init(submit: @escaping Submit) { self.submit = submit }

    private func loadExtractor() -> SourceMetadataExtractor? {
        if !extractorLoaded { extractor = SourceMetadataExtractor(); extractorLoaded = true }
        return extractor
    }
    private func key(_ importID: UUID, _ source: ArxivReaderSource) -> String { "\(importID.uuidString)|\(source.sourceID)v\(source.revision)" }

    /// After the device downloaded the paper's HTML to prepare it. True when a record was sent.
    @discardableResult
    func report(html: Data, source: ArxivReaderSource, importID: UUID) async -> Bool {
        let key = key(importID, source)
        guard !sent.contains(key), let metadata = loadExtractor()?.extract(html: html, source: source) else { return false }
        return await send(metadata, key: key, importID: importID, revision: source.revision)
    }

    /// A paper without HTML: one paced request to the export API, then the same record.
    @discardableResult
    func reportWithoutHTML(source: ArxivReaderSource, importID: UUID, fetcher: ArxivMetadataFetcher = .shared) async -> Bool {
        let key = key(importID, source)
        guard !sent.contains(key), let atom = try? await fetcher.atom(for: source),
              let metadata = loadExtractor()?.fromAtom(atom, source: source) else { return false }
        return await send(metadata, key: key, importID: importID, revision: source.revision)
    }

    private func send(_ metadata: Data, key: String, importID: UUID, revision: Int) async -> Bool {
        do { try await submit(importID, metadata, revision); sent.insert(key); return true }
        catch { return false }
    }
}
