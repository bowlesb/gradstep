import CryptoKit
import Foundation
import ScienceReaderCore

/// The person's own arXiv search from this device (docs/architecture/ARXIV_DEVICE_ONLY.md §5.6; owner, 2026-10-15),
/// while the server's `device_search` capability is on. The requests and the order of the results come from the
/// shared paper-search.ts (in JavaScriptCore). arXiv requests go through this device's single paced export API queue
/// (`ArxivMetadataFetcher`: one at a time, 3 s apart, back-off, the 24 h stop after a refusal, the Gradstep
/// User-Agent); DataCite answers the most cited matches and, when arXiv finds fewer than five papers, near spellings
/// (arXiv's API has none). Each query's results are kept on this device for 24 hours: sealed with the account's
/// local-store key (`SealedCacheFiles`, docs/architecture/GLOBAL_SEARCH.md "ML paper search cache"; before 2026-10-25
/// they were plaintext JSON), or in memory only while signed out; sign-out removes them. It runs only when the person
/// submits a search: nothing is prefetched, and the query never reaches our server.
actor DeviceSearch {
    static let shared = DeviceSearch()
    static let cacheLifetime: TimeInterval = 86_400
    enum Failure: Error, Equatable { case unavailable, paused }

    private let fetcher: ArxivMetadataFetcher
    private let dataCite: DataCiteSearchClient
    private let now: @Sendable () -> Date
    private var extractor: SourceMetadataExtractor?
    private var extractorLoaded = false
    /// The signed-in account's sealed cache (set at activation), and this run's answers while there is none.
    private nonisolated let caches = CacheSlot()
    private var memory: [String: Data] = [:]

    init(fetcher: ArxivMetadataFetcher = .shared, dataCite: DataCiteSearchClient = DataCiteSearchClient(),
         cache: SealedCacheFiles? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.fetcher = fetcher; self.dataCite = dataCite; self.now = now
        caches.set(cache)
    }

    /// Activation: this account's sealed cache. Results an earlier build left in plaintext are removed.
    nonisolated func configure(cache: SealedCacheFiles?) {
        caches.set(cache)
        Self.removePlaintextCache()
    }

    /// Sign-out: every cached result goes (the sealed files and this run's), so the next person sees no trace.
    nonisolated func signedOut() {
        caches.take()?.removeAll()
        Self.removePlaintextCache()
        Task { await self.forgetMemory() }
    }

    private func forgetMemory() { memory = [:] }

    /// `Caches/arxiv-search/<sha256>.json`, written in plaintext before 2026-10-25.
    static func removePlaintextCache() {
        guard let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("arxiv-search", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" { try? FileManager.default.removeItem(at: file) }
    }

    /// The same query in other words of case and spacing is the same search.
    static func normalized(_ query: String) -> String {
        query.precomposedStringWithCompatibilityMapping.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    /// A query's cache name: a digest, so not even the file's name says what was searched.
    static func cacheName(_ query: String) -> String {
        SHA256.hash(data: Data(normalized(query).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func cached(_ name: String) -> Data? { caches.get()?.read(name) ?? memory[name] }
    private func keep(_ data: Data, as name: String) {
        if let cache = caches.get() { try? cache.write(data, as: name) } else { memory[name] = data }
    }
    private struct Stamp: Decodable { let at: Double }

    private func answer(_ request: SourceMetadataExtractor.SearchPlan.Request) async throws -> String {
        if request.source == "datacite" { return try await dataCite.get(request.url) }
        return try await fetcher.query(request.url)
    }

    func search(_ query: String) async throws -> [DiscoveryResult] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let name = Self.cacheName(text)
        if let data = cached(name),
           let stamp = try? JSONDecoder().decode(Stamp.self, from: data), now().timeIntervalSince1970 - stamp.at < Self.cacheLifetime,
           let cached = try? JSONDecoder().decode(DiscoveryResponse.self, from: data) { return cached.results }
        if !extractorLoaded { extractor = SourceMetadataExtractor(); extractorLoaded = true }
        guard let extractor, let plan = extractor.searchRequests(text) else { throw Failure.unavailable }
        var answers: [String: String] = [:]
        for request in plan.requests {
            do { answers[request.role] = try await answer(request) }
            catch {
                // The relevance (or ID) answer is the search; the others only improve the order.
                guard request.role == "relevance" || request.role == "id" else { continue }
                throw (error as? ArxivMetadataFetcher.Failure) == .paused ? Failure.paused : Failure.unavailable
            }
        }
        if let broad = plan.broad, let relevance = answers["relevance"], extractor.searchCount(relevance) < plan.broadBelow,
           let more = try? await answer(broad) { answers[broad.role] = more }
        guard let results = extractor.searchResults(text, responses: answers) else { throw Failure.unavailable }
        var stored = Data("{\"at\":\(Int(now().timeIntervalSince1970)),\"results\":".utf8)
        stored.append(results); stored.append(Data("}".utf8))
        guard let response = try? JSONDecoder().decode(DiscoveryResponse.self, from: stored) else { throw Failure.unavailable }
        keep(stored, as: name)
        return response.results
    }
}

/// DataCite's search, for the device search's most cited matches and near spellings: only `https://api.datacite.org/dois`,
/// the app named in the User-Agent, bounded, no redirects. DataCite isn't arXiv, so it isn't paced with arXiv.
struct DataCiteSearchClient: Sendable {
    #if DEBUG
    /// Tests only: protocols that answer in-process (nothing leaves the process).
    nonisolated(unsafe) static var fixtureProtocolClasses: [AnyClass]?
    #endif
    static let maximumBytes = 2_097_152

    func get(_ url: URL) async throws -> String {
        guard url.scheme == "https", url.host == "api.datacite.org", url.path.hasPrefix("/dois"), url.user == nil, url.port == nil else {
            throw DeviceSearch.Failure.unavailable
        }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
        #if DEBUG
        if let protocols = Self.fixtureProtocolClasses { config.protocolClasses = protocols }
        #if DEBUG && FIXTURE_HOST
        BackendFaultProtocol.install(in: config)
        #endif
        #endif
        let session = URLSession(configuration: config, delegate: SearchNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(ArxivAcquisitionPolicy.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw DeviceSearch.Failure.unavailable }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= Self.maximumBytes,
              let text = String(data: data, encoding: .utf8) else { throw DeviceSearch.Failure.unavailable }
        return text
    }
}

/// The sealed cache an activation hands the search (read from the search's actor, set from the main actor).
final class CacheSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SealedCacheFiles?
    func set(_ cache: SealedCacheFiles?) { lock.withLock { value = cache } }
    func get() -> SealedCacheFiles? { lock.withLock { value } }
    func take() -> SealedCacheFiles? { lock.withLock { defer { value = nil }; return value } }
}

private final class SearchNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
