import CryptoKit
import Foundation
import ScienceReaderCore

/// The person's own arXiv search from this device (docs/architecture/ARXIV_DEVICE_ONLY.md §5.6; owner, 2026-10-15),
/// while the server's `device_search` capability is on. The requests and the order of the results come from the
/// shared paper-search.ts (in JavaScriptCore); every request goes through this device's single paced export API queue
/// (`ArxivMetadataFetcher`: one at a time, 3 s apart, back-off, the 24 h stop after a refusal, the Gradstep
/// User-Agent). Each query's results are kept on this device for 24 hours. It runs only when the person submits a
/// search: nothing is prefetched, and the query never reaches our server.
actor DeviceSearch {
    static let shared = DeviceSearch()
    static let cacheLifetime: TimeInterval = 86_400
    enum Failure: Error, Equatable { case unavailable, paused }

    private let fetcher: ArxivMetadataFetcher
    private let cacheDirectory: URL?
    private let now: @Sendable () -> Date
    private var extractor: SourceMetadataExtractor?
    private var extractorLoaded = false

    init(fetcher: ArxivMetadataFetcher = .shared,
         cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("arxiv-search", isDirectory: true),
         now: @escaping @Sendable () -> Date = Date.init) {
        self.fetcher = fetcher; self.cacheDirectory = cacheDirectory; self.now = now
    }

    /// The same query in other words of case and spacing is the same search.
    static func normalized(_ query: String) -> String {
        query.precomposedStringWithCompatibilityMapping.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private func cacheFile(_ query: String) -> URL? {
        let digest = SHA256.hash(data: Data(Self.normalized(query).utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory?.appendingPathComponent("\(digest).json")
    }
    private struct Stamp: Decodable { let at: Double }

    func search(_ query: String) async throws -> [DiscoveryResult] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        if let file = cacheFile(text), let data = try? Data(contentsOf: file),
           let stamp = try? JSONDecoder().decode(Stamp.self, from: data), now().timeIntervalSince1970 - stamp.at < Self.cacheLifetime,
           let cached = try? JSONDecoder().decode(DiscoveryResponse.self, from: data) { return cached.results }
        if !extractorLoaded { extractor = SourceMetadataExtractor(); extractorLoaded = true }
        guard let extractor, let plan = extractor.searchRequests(text) else { throw Failure.unavailable }
        var answers: [String: String] = [:]
        for request in plan.requests {
            do { answers[request.role] = try await fetcher.query(request.url) }
            catch {
                // The relevance (or ID) answer is the search; the phrase answer only improves the order.
                guard request.role == "relevance" || request.role == "id" else { continue }
                throw (error as? ArxivMetadataFetcher.Failure) == .paused ? Failure.paused : Failure.unavailable
            }
        }
        if let broad = plan.broad, let relevance = answers["relevance"], extractor.searchCount(relevance) < plan.broadBelow,
           let answer = try? await fetcher.query(broad.url) { answers[broad.role] = answer }
        guard let results = extractor.searchResults(text, responses: answers) else { throw Failure.unavailable }
        var stored = Data("{\"at\":\(Int(now().timeIntervalSince1970)),\"results\":".utf8)
        stored.append(results); stored.append(Data("}".utf8))
        guard let response = try? JSONDecoder().decode(DiscoveryResponse.self, from: stored) else { throw Failure.unavailable }
        if let file = cacheFile(text) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? stored.write(to: file, options: [.atomic])
        }
        return response.results
    }
}
