import Foundation
import ScienceReaderCore

// Paper podcasts: the client half of the v1 contract (docs/architecture/PAPER_PODCASTS.md). The network transport
// talks to the `podcast` Edge function and its single-use `podcast-member` downloads; Simulator/Mac fixture builds
// use `PodcastFixtureTransport` instead (labeled synthetic episodes, zero spend, no network).

protocol PodcastTransport: Sendable {
    func catalog(after: String?, limit: Int) async throws -> PodcastCatalogPage
    func episode(_ releaseID: UUID) async throws -> PodcastEpisode
    func paper(itemID: UUID) async throws -> PodcastPaperLookup
    func quote(itemID: UUID, requestID: UUID) async throws -> PodcastQuoteOutcome
    func start(quoteID: UUID, requestID: UUID, consentVersion: String) async throws -> PodcastJobOutcome
    func status(requestID: UUID) async throws -> PodcastJobOutcome
    func cancel(requestID: UUID) async throws -> PodcastJobOutcome
    func download(_ releaseID: UUID) async throws -> PodcastGrant
    func states(_ releaseIDs: [UUID]) async throws -> [UUID: PodcastReleaseStatus]
    func member(_ member: PodcastMember, progress: @escaping @Sendable (Int) -> Void) async throws -> Data
}

/// The signed-in account's podcast service, bound to that account: a later account's session can't use it.
struct BackendPodcastTransport: PodcastTransport {
    let client: BackendClient
    let accountID: UUID

    private func get<T: Decodable>(_ query: String, _ type: T.Type, limit: Int = 262_144) async throws -> T {
        try JSONDecoder().decode(T.self, from: await client.podcastCall(query, body: nil, accountID: accountID, maximumResponseBytes: limit))
    }
    private func post<T: Decodable>(_ action: String, _ body: [String: Any], _ type: T.Type, limit: Int = 65_536) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try JSONDecoder().decode(T.self, from: await client.podcastCall("action=\(action)", body: data, accountID: accountID, maximumResponseBytes: limit))
    }
    private struct EpisodeBody: Decodable { let episode: PodcastEpisode }
    private struct GrantBody: Decodable { let grant: PodcastGrant }
    private struct StatesBody: Decodable { let states: [String: PodcastReleaseStatus] }

    func catalog(after: String?, limit: Int) async throws -> PodcastCatalogPage {
        var query = "action=catalog&limit=\(max(1, min(50, limit)))"
        if let after, let encoded = after.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { query += "&after=\(encoded)" }
        return try await get(query, PodcastCatalogPage.self, limit: 1_048_576)
    }
    func episode(_ releaseID: UUID) async throws -> PodcastEpisode {
        // A transcript is bounded by the contract (2,000 segments); 2 MiB covers it with room.
        let episode = try await get("action=episode&release_id=\(releaseID.wire)", EpisodeBody.self, limit: 2_097_152).episode
        guard episode.id == releaseID, episode.transcript != nil, episode.chapters != nil else { throw ReaderError.corruptData }
        return episode
    }
    func paper(itemID: UUID) async throws -> PodcastPaperLookup {
        try await get("action=paper&item_id=\(itemID.wire)", PodcastPaperLookup.self)
    }
    func quote(itemID: UUID, requestID: UUID) async throws -> PodcastQuoteOutcome {
        try await post("quote", ["item_id": itemID.wire, "request_id": requestID.wire], PodcastQuoteOutcome.self)
    }
    func start(quoteID: UUID, requestID: UUID, consentVersion: String) async throws -> PodcastJobOutcome {
        try await post("start", ["quote_id": quoteID.wire, "request_id": requestID.wire, "consent_version": consentVersion], PodcastJobOutcome.self)
    }
    func status(requestID: UUID) async throws -> PodcastJobOutcome {
        try await get("action=status&request_id=\(requestID.wire)", PodcastJobOutcome.self)
    }
    func cancel(requestID: UUID) async throws -> PodcastJobOutcome {
        try await post("cancel", ["request_id": requestID.wire], PodcastJobOutcome.self)
    }
    func download(_ releaseID: UUID) async throws -> PodcastGrant {
        try await post("download", ["release_id": releaseID.wire], GrantBody.self).grant
    }
    func states(_ releaseIDs: [UUID]) async throws -> [UUID: PodcastReleaseStatus] {
        guard !releaseIDs.isEmpty else { return [:] }
        let body = try await post("states", ["release_ids": releaseIDs.prefix(100).map(\.wire)], StatesBody.self, limit: 131_072)
        return Dictionary(uniqueKeysWithValues: body.states.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }
    func member(_ member: PodcastMember, progress: @escaping @Sendable (Int) -> Void) async throws -> Data {
        try await client.podcastMember(member, accountID: accountID, progress: progress)
    }
}

extension BackendError {
    /// Finite podcast codes the app explains; anything else reads as a general failure. Prose never comes from the server.
    static let podcastCodes: Set<String> = [
        "podcast_unavailable", "source_unavailable", "source_too_large", "rights_unavailable", "release_unavailable",
        "quote_expired", "quote_unavailable", "consent_required", "request_id_conflict", "job_unavailable",
        "active_generation_limit", "generation_capacity", "platform_paused", "storage_full",
        "podcast_transfer_limit", "podcast_grant_unavailable", "podcast_grant_consumed", "podcast_integrity_failed",
    ]

    /// The reader-facing sentence for a podcast action that the server refused.
    var podcastMessage: String {
        guard case .rejected(let code) = self else { return errorDescription ?? "Listening isn’t available right now." }
        switch code {
        case "podcast_unavailable": return "Listening isn’t available right now. Reading is unaffected."
        case "source_unavailable": return "This paper can’t be made into an episode: its converted text isn’t available."
        case "source_too_large": return "This paper is too long for a five-minute episode. Nothing was charged."
        case "rights_unavailable", "release_unavailable": return "This episode is no longer available."
        case "quote_expired", "quote_unavailable": return "The estimate expired. Get a new estimate to continue."
        case "consent_required": return "Confirm the estimate and providers to create an episode."
        case "active_generation_limit": return "An episode is already being made for your account. Try again when it finishes."
        case "generation_capacity", "platform_paused", "platform_budget_exhausted":
            return "Episode creation is paused right now. Nothing was charged, and reading is unaffected."
        case "storage_full": return "Episode storage is full right now. Nothing was charged."
        case "insufficient_credits": return "Your available credits don’t cover the 150-credit maximum for an episode."
        case "podcast_transfer_limit": return "Episode downloads are limited for this month. Downloaded episodes still play."
        case "podcast_grant_unavailable", "podcast_grant_consumed": return "The download needs to restart. Try again."
        case "podcast_integrity_failed": return "This episode couldn’t be verified. Try downloading it again."
        case "request_rate_limit": return "Too many requests right now. Try again in a minute."
        case "job_unavailable": return "That episode request isn’t available any more."
        default: return "Listening isn’t available right now. Try again later."
        }
    }
}

extension Error {
    var podcastMessage: String {
        if let backend = self as? BackendError { return backend.podcastMessage }
        if self is URLError { return "The connection was interrupted. Downloaded episodes still play." }
        if let reader = self as? ReaderError, reader == .corruptData { return "This episode couldn’t be verified. Try again." }
        return "Listening isn’t available right now. Try again later."
    }
}
