import Foundation
import Observation
import ScienceReaderCore

// The Library's topics on this device (interest index step 3; docs/architecture/INTEREST_INDEX.md "Device layer"):
// - the public map and term statistics come from the interest index (the same bytes for every reader, kept by digest);
// - the library's public fingerprints come from `v1_interest_library_fingerprints`, which answers only for papers the
//   server already knows are in this library (membership-derived; it never acts as an oracle);
// - topics, labels, keywords and weights are computed here and never sent anywhere in plaintext; the reader's names,
//   hidden flags, colours, shown topics and reading levels travel only as end-to-end encrypted events (InterestRegistry).
// Uploaded and device PDFs have no public fingerprint and the app has no on-device gte-small, so they stay out of topics.

/// The Library list filtered to one topic's papers (a chart slice or legend row).
struct LibraryTopicFilter: Equatable {
    let id: Int
    let label: String
    let papers: Set<UUID>
}

/// What a recompute needs from the model, read on the main actor.
struct InterestInputs: Sendable {
    var papers: [InterestLibraryPaper]
    /// This device's reading levels by paper key (0–4).
    var readingLevels: [String: Int]
    var registry: InterestRegistry
    /// The library is fully loaded (not a sign-in's empty first state): only then are shown flags written.
    var complete: Bool
    var now: Date
}

/// The interest model off the main actor (decoding, state updates, labels and keywords take tens of milliseconds to
/// seconds on a large library).
actor InterestEngine {
    private var model: InterestLibraryModel
    let mapVersion: Int
    let mapDigest: String
    let termsDigest: String
    private var keywordCache: [UUID: (signature: String, keywords: [String])] = [:]

    init(map: InterestMap, terms: InterestTerms?, mapDigest: String, termsDigest: String) {
        model = InterestLibraryModel(map: map, terms: terms)
        mapVersion = map.version; self.mapDigest = mapDigest; self.termsDigest = termsDigest
    }

    func setFingerprints(_ values: [InterestFingerprint]) { model.setFingerprints(values) }
    func knownKeys() -> Set<String> { Set(model.fingerprints.keys) }

    func update(_ inputs: InterestInputs) -> InterestLibraryTopics {
        model.update(papers: inputs.papers, registry: inputs.registry, readingLevels: inputs.readingLevels, now: inputs.now)
    }

    /// Keywords for papers whose text or statistics changed since the last pass; `body` reads a paper's full text from the
    /// encrypted full-text index (nil when it has none).
    func keywords(for papers: [InterestLibraryPaper], bodySignature: [UUID: String], body: @Sendable (UUID) -> String?) -> [UUID: [String]] {
        var out: [UUID: [String]] = [:]
        for paper in papers {
            let signature = termsDigest + "|" + (bodySignature[paper.id] ?? "") + "|" + String(paper.title.hashValue) + String(paper.abstract.count)
            if let cached = keywordCache[paper.id], cached.signature == signature { out[paper.id] = cached.keywords; continue }
            let keywords = model.keywords(for: paper.key, title: paper.title, abstract: paper.abstract, body: body(paper.id))
            keywordCache[paper.id] = (signature, keywords)
            out[paper.id] = keywords
        }
        return out
    }
}

/// Keywords the term layer chose per paper, read by `LibraryTags` from any view body.
final class InterestKeywordStore: @unchecked Sendable {
    static let shared = InterestKeywordStore()
    private let lock = NSLock()
    private var values: [UUID: [String]] = [:]
    func keywords(for paper: UUID) -> [String]? { lock.withLock { values[paper] } }
    func replace(_ next: [UUID: [String]]) -> Bool {
        lock.withLock { guard values != next else { return false }; values = next; return true }
    }
}

@MainActor @Observable final class LibraryInterest {
    enum Status: Equatable { case off, loading, ready, notServed, unavailable }
    private(set) var status: Status = .off
    private(set) var topics: InterestLibraryTopics?
    /// The chart's collapsed state, remembered between launches.
    var collapsed = UserDefaults.standard.bool(forKey: "library.topics.collapsed") {
        didSet { UserDefaults.standard.set(collapsed, forKey: "library.topics.collapsed") }
    }
    @ObservationIgnored private(set) var engine: InterestEngine?
    @ObservationIgnored private var engineAccount: UUID?
    /// Papers asked of the server that weren't embedded yet, and when (asked again after 10 minutes).
    @ObservationIgnored private var askedAt: [String: Date] = [:]
    @ObservationIgnored private var notServedUntil: Date?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored var updateTask: Task<Void, Never>?
    @ObservationIgnored var keywordTask: Task<Void, Never>?
    @ObservationIgnored var lastShownWrite: Date?

    /// Forget everything (sign-out, account switch).
    func reset() {
        loadTask?.cancel(); updateTask?.cancel(); keywordTask?.cancel()
        engine = nil; engineAccount = nil; askedAt = [:]; notServedUntil = nil; topics = nil; status = .off
        _ = InterestKeywordStore.shared.replace([:])
    }

    func publish(_ topics: InterestLibraryTopics) { self.topics = topics; status = .ready }

    /// Sets up the engine from the index's map and term statistics (once per account and map/terms version), then
    /// fetches public fingerprints for library papers it doesn't know yet.
    func prepare(client: InterestIndexClient, backend: BackendClient, accountID: UUID, keys: Set<String>) async -> Bool {
        if let until = notServedUntil, Date() < until { status = .notServed; return false }
        do {
            let manifest = try await client.manifest()
            guard let mapRef = manifest.map?.artifact, let termsRef = manifest.terms?.artifact else { status = .unavailable; return false }
            if engine == nil || engineAccount != accountID || engine?.mapDigest != mapRef.sha256 || engine?.termsDigest != termsRef.sha256 {
                if engine == nil { status = .loading }
                let mapArtifact = try await client.artifact(mapRef), termsArtifact = try await client.artifact(termsRef)
                let built = try await Task.detached(priority: .utility) {
                    (try InterestMap(mapArtifact), try InterestTerms(termsArtifact))
                }.value
                engine = InterestEngine(map: built.0, terms: built.1, mapDigest: mapRef.sha256, termsDigest: termsRef.sha256)
                engineAccount = accountID; askedAt = [:]
                try await fetchFingerprints(backend: backend, accountID: accountID, keys: nil, mapVersion: built.0.version)
            }
            guard let engine else { return false }
            let known = await engine.knownKeys()
            let now = Date()
            let missing = keys.subtracting(known).filter { askedAt[$0].map { now.timeIntervalSince($0) > 600 } ?? true }.sorted()
            if !missing.isEmpty {
                try await fetchFingerprints(backend: backend, accountID: accountID, keys: Array(missing.prefix(500)), mapVersion: engine.mapVersion)
            }
            return true
        } catch InterestIndexError.notServed {
            notServedUntil = Date().addingTimeInterval(3_600); status = .notServed; topics = nil; return false
        } catch BackendError.rejected(let code) where code == "interest_unavailable" {
            notServedUntil = Date().addingTimeInterval(3_600); status = .notServed; topics = nil; return false
        } catch {
            if engine == nil { status = .unavailable }
            return engine != nil
        }
    }

    private struct FingerprintsPage: Decodable, Sendable {
        struct Item: Decodable, Sendable { let source_id: String; let q8: String?; let leaf_id: Int?; let terms: [String]?; let pending: Bool? }
        let map_version: Int?
        let items: [Item]
        let next: String?
    }
    private struct FingerprintsParams: Encodable, Sendable { let p_source_ids: [String]?; let p_after: String?; let p_limit: Int }

    /// `keys` nil: every public paper of the library, by pages of 500 (the server derives the set from membership).
    private func fetchFingerprints(backend: BackendClient, accountID: UUID, keys: [String]?, mapVersion: Int) async throws {
        var after: String?
        var fetched: [InterestFingerprint] = []
        repeat {
            let page: FingerprintsPage = try await backend.rpc("v1_interest_library_fingerprints",
                params: FingerprintsParams(p_source_ids: keys, p_after: after, p_limit: 500), accountID: accountID)
            for item in page.items {
                askedAt[InterestPool.key(item.source_id)] = Date()
                guard item.pending != true, let q8 = item.q8, let data = Data(base64Encoded: q8, options: .ignoreUnknownCharacters),
                      data.count == InterestQ8.bytes else { continue }
                fetched.append(InterestFingerprint(key: item.source_id, vector: InterestQ8.decode(data), leafID: item.leaf_id,
                                                   terms: item.terms ?? [], mapVersion: page.map_version))
            }
            after = page.next
        } while after != nil && keys == nil && !Task.isCancelled
        for key in keys ?? [] where askedAt[InterestPool.key(key)] == nil { askedAt[InterestPool.key(key)] = Date() }
        await engine?.setFingerprints(fetched)
    }

    #if DEBUG && FIXTURE_HOST
    /// UI fixtures: the map, trimmed term statistics and public fingerprints from the ScienceReaderCore test fixtures
    /// (`INTEREST_FIXTURE_DIR`), no network.
    func prepareFixture(directory: URL) async -> Bool {
        if engine != nil { return true }
        do {
            let map = try InterestMap(InterestArtifact(gzipped: Data(contentsOf: directory.appendingPathComponent("interest-map-v1.gsi"))))
            let terms = try InterestTerms(InterestArtifact(gzipped: Data(contentsOf: directory.appendingPathComponent("interest-terms-fixture.gsi"))))
            let engine = InterestEngine(map: map, terms: terms, mapDigest: "fixture", termsDigest: "fixture")
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("interest-library-v1.json"))) as? [String: Any]
            let papers = fixture?["papers"] as? [[String: Any]] ?? []
            await engine.setFingerprints(papers.compactMap { p in
                guard let key = p["key"] as? String, let q8 = (p["q8"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
                return InterestFingerprint(key: key, vector: InterestQ8.decode(q8), leafID: p["leaf"] as? Int,
                                           terms: p["server_terms"] as? [String] ?? [], mapVersion: p["leaf_map_version"] as? Int)
            })
            self.engine = engine
            return true
        } catch {
            status = .unavailable
            return false
        }
    }
    #endif
}
