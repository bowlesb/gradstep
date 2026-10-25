import CryptoKit
import Foundation

// The device's copy of the interest index (docs/architecture/INTEREST_INDEX.md §4–5). Every device downloads the same
// public artifacts — the manifest, the map, term statistics and the Feed pool's fingerprint shards — so the server learns
// only that the feature is used, never which paper a device scores, ranks or opens. Artifacts are immutable and
// content-addressed: each is cached on disk under its SHA-256, checked before use, fetched once, and removed when the
// manifest no longer lists it. The manifest is read again after `manifestLifetime` (the server's `max-age=600`).
// Related papers use the shards today; step 3 (the device layer) reuses `artifact(_:)` for the map and terms.

/// The manifest (`GET functions/v1/interest-index`).
public struct InterestManifest: Codable, Sendable, Equatable {
    public struct ArtifactRef: Codable, Sendable, Equatable, Hashable {
        public let id: UUID
        public let sha256: String
        public let bytes: Int
        public init(id: UUID, sha256: String, bytes: Int) { self.id = id; self.sha256 = sha256; self.bytes = bytes }
    }
    public struct Model: Codable, Sendable, Equatable {
        public let version: String
        public let dim: Int
    }
    public struct Versioned: Codable, Sendable, Equatable {
        public let version: Int
        public let artifact: ArtifactRef
    }
    public struct Shard: Codable, Sendable, Equatable {
        public let id: UUID
        public let sha256: String
        public let bytes: Int
        public let papers: Int?
        public let oldestOn: String?
        public let newestOn: String?
        public var artifact: ArtifactRef { ArtifactRef(id: id, sha256: sha256, bytes: bytes) }
        private enum CodingKeys: String, CodingKey { case id, sha256, bytes, papers, oldestOn = "oldest_on", newestOn = "newest_on" }
    }
    public let format: Int
    public let model: Model
    public let windowDays: Int?
    public let map: Versioned?
    public let terms: Versioned?
    public let shards: [Shard]
    private enum CodingKeys: String, CodingKey { case format, model, map, terms, shards, windowDays = "window_days" }

    /// Every artifact the manifest lists.
    public var artifacts: [ArtifactRef] { [map?.artifact, terms?.artifact].compactMap { $0 } + shards.map(\.artifact) }
    public var shardBytes: Int { shards.reduce(0) { $0 + $1.bytes } }

    static let maximumBytes = 262_144
    static let maximumArtifactBytes = 16 * 1_048_576

    /// Decodes and checks the manifest's own bounds (format 1, 384 dimensions, lower-case hex digests, sane sizes).
    public static func decode(_ data: Data) throws -> InterestManifest {
        guard data.count <= maximumBytes else { throw InterestIndexError.invalid }
        let manifest: InterestManifest
        do { manifest = try JSONDecoder().decode(InterestManifest.self, from: data) } catch { throw InterestIndexError.invalid }
        guard manifest.format == 1, manifest.model.dim == InterestQ8.dimension, manifest.shards.count <= 400,
              manifest.artifacts.allSatisfy({ $0.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
                  && (1 ... maximumArtifactBytes).contains($0.bytes) }) else { throw InterestIndexError.invalid }
        return manifest
    }
}

public enum InterestIndexError: Error, Equatable {
    /// The server doesn't serve the index to this account (`404 interest_unavailable`: not staff while serving is `staff`).
    case notServed
    /// The network or the service failed; try later.
    case unavailable
    /// An artifact's bytes don't match the manifest's SHA-256 or size.
    case integrity
    /// The manifest or an artifact isn't in a format this build reads.
    case invalid
}

/// How the client reaches the server (the app's `BackendClient`, with the reader's session). Map a
/// `404 interest_unavailable` to `InterestIndexError.notServed`.
public protocol InterestIndexTransport: Sendable {
    func manifest() async throws -> Data
    func artifact(_ ref: InterestManifest.ArtifactRef) async throws -> Data
}

/// What a download did, for measurements (sizes in bytes, times in seconds).
public struct InterestIndexFetchStats: Sendable, Equatable {
    public var manifestFetched = false
    public var artifactsDownloaded = 0
    public var bytesDownloaded = 0
    public var artifactsFromCache = 0
    public var downloadSeconds: Double = 0
    public var decodeSeconds: Double = 0
}

public actor InterestIndexClient {
    public static let manifestLifetime: TimeInterval = 600

    private let directory: URL
    private let transport: any InterestIndexTransport
    private let now: @Sendable () -> Date
    private var manifestCache: (manifest: InterestManifest, fetchedAt: Date)?
    private var poolCache: (key: [String], pool: InterestPool)?
    private var poolTask: (key: [String], task: Task<InterestPool, Error>)?
    public private(set) var lastStats = InterestIndexFetchStats()

    /// `directory`: where the manifest and artifacts are kept (Caches; the bytes are public and can be fetched again).
    public init(directory: URL, transport: any InterestIndexTransport, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory; self.transport = transport; self.now = now
    }

    private var manifestFile: URL { directory.appendingPathComponent("manifest.json") }
    private func artifactFile(_ ref: InterestManifest.ArtifactRef) -> URL { directory.appendingPathComponent("\(ref.sha256).gsi") }

    /// The current manifest: the one in memory or on disk while it is younger than `manifestLifetime`, else the server's.
    /// When the server can't be reached, an older manifest whose artifacts are all on disk still answers.
    public func manifest(refresh: Bool = false) async throws -> InterestManifest {
        if !refresh, let cached = manifestCache, now().timeIntervalSince(cached.fetchedAt) < Self.manifestLifetime { return cached.manifest }
        if !refresh, manifestCache == nil, let stored = storedManifest(), now().timeIntervalSince(stored.fetchedAt) < Self.manifestLifetime {
            manifestCache = stored; return stored.manifest
        }
        do {
            let data = try await transport.manifest()
            let manifest = try InterestManifest.decode(data)
            manifestCache = (manifest, now())
            lastStats.manifestFetched = true
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: manifestFile, options: [.atomic])
            prune(keeping: manifest)
            return manifest
        } catch InterestIndexError.notServed {
            // Not served (any more): nothing kept here may be used.
            manifestCache = nil; poolCache = nil
            try? FileManager.default.removeItem(at: directory)
            throw InterestIndexError.notServed
        } catch {
            if let stale = manifestCache ?? storedManifest(), stale.manifest.artifacts.allSatisfy({ FileManager.default.fileExists(atPath: artifactFile($0).path) }) {
                manifestCache = stale; return stale.manifest
            }
            throw (error as? InterestIndexError) ?? .unavailable
        }
    }

    private func storedManifest() -> (manifest: InterestManifest, fetchedAt: Date)? {
        guard let data = try? Data(contentsOf: manifestFile), let manifest = try? InterestManifest.decode(data),
              let modified = (try? FileManager.default.attributesOfItem(atPath: manifestFile.path))?[.modificationDate] as? Date else { return nil }
        return (manifest, modified)
    }

    /// One artifact's bytes, checked against its SHA-256 and size: from disk when kept, else downloaded once and kept.
    public func artifactBytes(_ ref: InterestManifest.ArtifactRef) async throws -> Data {
        let file = artifactFile(ref)
        if let data = try? Data(contentsOf: file) {
            if Self.matches(data, ref) { lastStats.artifactsFromCache += 1; return data }
            try? FileManager.default.removeItem(at: file)
        }
        let started = Date()
        let data = try await transport.artifact(ref)
        lastStats.downloadSeconds += Date().timeIntervalSince(started)
        guard Self.matches(data, ref) else { throw InterestIndexError.integrity }
        lastStats.artifactsDownloaded += 1; lastStats.bytesDownloaded += data.count
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic])
        return data
    }

    /// One artifact, decoded (map and terms for step 3; shards for the pool).
    public func artifact(_ ref: InterestManifest.ArtifactRef) async throws -> InterestArtifact {
        let data = try await artifactBytes(ref)
        do { return try InterestArtifact(gzipped: data) } catch { throw InterestIndexError.invalid }
    }

    /// The Feed pool's fingerprints for the manifest's window, decoded once per set of shards.
    public func pool() async throws -> InterestPool {
        let manifest = try await manifest()
        let key = manifest.shards.map(\.sha256)
        if let cached = poolCache, cached.key == key { return cached.pool }
        if let running = poolTask, running.key == key { return try await running.task.value }
        lastStats = InterestIndexFetchStats(manifestFetched: lastStats.manifestFetched)
        let task = Task<InterestPool, Error> {
            var shards: [InterestShard] = []
            for shard in manifest.shards {
                let artifact = try await self.artifact(shard.artifact)
                do { shards.append(try InterestShard(artifact)) } catch { throw InterestIndexError.invalid }
            }
            let started = Date()
            let pool = InterestPool(shards: shards, modelVersion: manifest.model.version)
            await self.addDecodeTime(Date().timeIntervalSince(started))
            return pool
        }
        poolTask = (key, task)
        defer { if poolTask?.key == key { poolTask = nil } }
        let pool = try await task.value
        poolCache = (key, pool)
        return pool
    }

    private func addDecodeTime(_ seconds: Double) { lastStats.decodeSeconds += seconds }

    /// Removes kept artifacts the manifest no longer lists (a shard that left the window, an old map).
    private func prune(keeping manifest: InterestManifest) {
        let wanted = Set(manifest.artifacts.map { "\($0.sha256).gsi" })
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in files where name.hasSuffix(".gsi") && !wanted.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func matches(_ data: Data, _ ref: InterestManifest.ArtifactRef) -> Bool {
        data.count == ref.bytes && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == ref.sha256
    }
}
