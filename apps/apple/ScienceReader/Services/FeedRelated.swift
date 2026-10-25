import Foundation
import ScienceReaderCore

// Related papers for a Feed paper's details (owner, 2026-10-24), worked out on this device so the server never learns
// which paper was opened:
// 1. The interest index's pool fingerprints (the same public shards every device downloads; InterestIndexClient) give the
//    nearest papers of the 14-day window (RelatedPapers.nearest; Accelerate).
// 2. Titles and authors come from the Feed results this device already has; for the few nearest papers it has none for,
//    one request to arXiv's export API from this device (`id_list`, through its single paced queue), only while device
//    search is on, as the person's own search is. Nothing goes to our server.
// 3. RelatedPapers.rank boosts shared authors and specific topics and explains each pick.
// When the index isn't served to this account (non-staff while serving is `staff`), can't be fetched, or doesn't hold the
// paper (older than the window), the Feed results here are ranked by shared topics and authors instead.

/// One related paper, ready to show.
struct RelatedFeedPaper: Identifiable, Equatable {
    let result: DiscoveryResult
    let reason: RelatedReason
    var id: String { result.sourceID }
}

struct RelatedFeedOutcome: Equatable {
    enum Source: String, Equatable { case index, feed }
    var papers: [RelatedFeedPaper]
    var source: Source
}

/// The index's transport through the reader's session.
struct BackendInterestTransport: InterestIndexTransport {
    let backend: BackendClient
    let accountID: UUID
    func manifest() async throws -> Data {
        do { return try await backend.interestIndexManifest(accountID: accountID) } catch { throw Self.map(error) }
    }
    func artifact(_ ref: InterestManifest.ArtifactRef) async throws -> Data {
        do { return try await backend.interestIndexArtifact(ref.id, bytes: ref.bytes, accountID: accountID) } catch { throw Self.map(error) }
    }
    private static func map(_ error: Error) -> Error {
        if case BackendError.rejected(let code) = error, code == "interest_unavailable" { return InterestIndexError.notServed }
        return error is CancellationError ? error : InterestIndexError.unavailable
    }
}

@MainActor final class FeedRelatedService {
    private var client: (accountID: UUID, client: InterestIndexClient)?
    /// After `notServed`, the index isn't asked again for a while (serving changes rarely).
    private var notServedUntil: Date?
    /// Papers this device read from arXiv for related lists (a session's worth; the fetcher keeps its own pacing).
    private var fetched: [String: DiscoveryResult] = [:]
    private var arxivAsked: Set<String> = []

    static let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("interest-index", isDirectory: true)

    private func indexClient(backend: BackendClient, accountID: UUID) -> InterestIndexClient {
        if let client, client.accountID == accountID { return client.client }
        let made = InterestIndexClient(directory: Self.cacheDirectory, transport: BackendInterestTransport(backend: backend, accountID: accountID))
        client = (accountID, made)
        notServedUntil = nil
        return made
    }

    /// Up to ten related papers for `opened`. `known`: every Feed result this device has seen this session; `library`: the
    /// reader's arXiv identifiers (never shown). `arxiv`: whether this device may read missing titles from arXiv.
    func related(for opened: DiscoveryResult, known: [DiscoveryResult], library: Set<String>, backend: BackendClient?,
                 accountID: UUID?, arxiv: Bool) async -> RelatedFeedOutcome {
        let knownFacts = known.map(RelatedPaperFacts.init)
        let authorCounts = RelatedPapers.authorCounts(knownFacts)
        let generic = RelatedPapers.commonTopics(knownFacts)
        let openedFacts = RelatedPaperFacts(opened)
        if let backend, let accountID, notServedUntil.map({ Date() >= $0 }) ?? true {
            let client = indexClient(backend: backend, accountID: accountID)
            do {
                let pool = try await client.pool()
                let started = Date()
                if let nearest = RelatedPapers.nearest(to: opened.sourceID, in: pool, excluding: library) {
                    let nearestMS = Date().timeIntervalSince(started) * 1000
                    var byID = Dictionary(known.map { (InterestPool.key($0.sourceID), $0) }, uniquingKeysWith: { first, _ in first })
                    for (id, paper) in fetched where byID[id] == nil { byID[id] = paper }
                    // The device reads titles it lacks for the papers that could be shown (closeness ≥ 0.86, or two shared
                    // authors from 0.84 — which needs the names, so the first of those too), at most 20 in one request.
                    if arxiv {
                        let wanted = nearest.prefix(20).map(\.sourceID).filter { byID[$0] == nil && !arxivAsked.contains($0) }
                        if !wanted.isEmpty { await read(wanted, into: &byID) }
                    }
                    let facts = byID.mapValues(RelatedPaperFacts.init)
                    let ranked = RelatedPapers.rank(opened: openedFacts, nearest: nearest, facts: facts,
                                                    authorPapers: { authorCounts[$0] ?? 0 }, generic: generic)
                    let stats = await client.lastStats
                    FeedRelatedLog.record(source: "index", pool: pool.count, nearestMS: nearestMS, shown: ranked.count, stats: stats)
                    return RelatedFeedOutcome(papers: ranked.compactMap { item in byID[item.sourceID].map { RelatedFeedPaper(result: $0, reason: item.reason) } },
                                              source: .index)
                }
            } catch InterestIndexError.notServed {
                notServedUntil = Date().addingTimeInterval(3_600)
            } catch {
                // Unavailable or invalid: the Feed results below.
            }
        }
        let ranked = RelatedPapers.rankByMetadata(opened: openedFacts, candidates: knownFacts, excluding: library,
                                                  authorPapers: { authorCounts[$0] ?? 0 }, generic: generic)
        let byID = Dictionary(known.map { (InterestPool.key($0.sourceID), $0) }, uniquingKeysWith: { first, _ in first })
        return RelatedFeedOutcome(papers: ranked.compactMap { item in byID[item.sourceID].map { RelatedFeedPaper(result: $0, reason: item.reason) } },
                                  source: .feed)
    }

    /// One `id_list` request to arXiv from this device for papers it has no Feed result for.
    private func read(_ ids: [String], into byID: inout [String: DiscoveryResult]) async {
        guard let url = ArxivAtomListing.url(for: ids) else { return }
        arxivAsked.formUnion(ids)
        guard let xml = try? await ArxivMetadataFetcher.shared.query(url) else { arxivAsked.subtract(ids); return }
        for paper in ArxivAtomListing.parse(Data(xml.utf8)) {
            fetched[paper.sourceID] = paper
            if byID[paper.sourceID] == nil { byID[paper.sourceID] = paper }
        }
    }
}

/// Measurements for the developer (never the paper's identifier): pool size, ranking time and download totals.
enum FeedRelatedLog {
    static func record(source: String, pool: Int, nearestMS: Double, shown: Int, stats: InterestIndexFetchStats) {
        SessionTimeline.shared.record("related", ["source": source, "pool": String(pool), "rank_ms": String(format: "%.1f", nearestMS),
                                                  "shown": String(shown), "downloaded": String(stats.bytesDownloaded),
                                                  "download_ms": String(Int(stats.downloadSeconds * 1000)),
                                                  "decode_ms": String(Int(stats.decodeSeconds * 1000))])
    }
}
