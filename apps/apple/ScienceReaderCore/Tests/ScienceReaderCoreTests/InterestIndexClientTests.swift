import CryptoKit
import Foundation
import XCTest
@testable import ScienceReaderCore

/// The interest index's device client (docs/architecture/INTEREST_INDEX.md §4): the artifact format as the server's own
/// codec writes it (`interest-shard-v1.gsi` was made by supabase/functions/_shared/interest/codec.ts), q8 decoding, the
/// disk cache with checksum checks, refresh and pruning when the manifest changes, and "not served".
final class InterestIndexClientTests: XCTestCase {
    private func fixture() throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "interest-shard-v1", withExtension: "gsi")))
    }
    private static let fixtureSHA = "f3493042c523d032b28a602ffb69eeb12c2c543ac806eacc45e484f57fd1b994"

    func testShardFromTheServersCodec() throws {
        let data = try fixture()
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), Self.fixtureSHA)
        let artifact = try InterestArtifact(gzipped: data)
        XCTAssertEqual(artifact.kind, .shard)
        XCTAssertEqual(artifact.header["model_version"], .string("gte-small@17e1f34/onnx-fp32@5927d17/mean-l2/v1"))
        let shard = try InterestShard(artifact)
        XCTAssertEqual(shard.papers.map(\.sourceID), ["2610.01234", "2610.02287", "hep-th/9901001"])
        XCTAssertEqual(shard.papers.map(\.announcedDay), [20746, 20747, 20748], "2026-10-20… as days since 1970")
        // q8: scale (max |x| / 127) then signed bytes; the codec wrote 127, 64, 0, 1 first.
        let offset = shard.papers[0].offset
        XCTAssertEqual(shard.body.loadLE(UInt32.self, at: offset), Float(0.0070191845297813416).bitPattern)
        XCTAssertEqual(Array(shard.body[offset + 4 ..< offset + 8]).map { Int8(bitPattern: $0) }, [127, 64, 0, 1])
        let raw = InterestQ8.decode(shard.body, at: offset, normalize: false)
        XCTAssertEqual(raw[0], 127 * 0.0070191845, accuracy: 1e-6)
        XCTAssertEqual(raw[1], 64 * 0.0070191845, accuracy: 1e-6)
        // Against the float vector the server quantised: cos ≥ 0.9998.
        let original: [Float] = [0.8914364269458848, 0.44974983550435593, -0.0017918320139615775, 0.004479580034903944]
        let unit = InterestQ8.decode(shard.body, at: offset)
        XCTAssertEqual(unit.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-5)
        for i in 0 ..< 2 { XCTAssertEqual(unit[i], original[i], accuracy: 0.005) }
    }

    func testRejectsDamagedArtifacts() throws {
        var data = try fixture()
        XCTAssertThrowsError(try InterestArtifact(gzipped: Data("not gzip at all, really not".utf8))) { XCTAssertEqual($0 as? InterestArtifactError, .gzip) }
        XCTAssertThrowsError(try InterestArtifact(gzipped: data.prefix(data.count - 12)))
        data[data.count - 9] ^= 0xff // the CRC-32 in the gzip trailer
        XCTAssertThrowsError(try InterestArtifact(gzipped: data))
    }

    func testPoolDecodesShardsAndKeepsTheLaterFingerprint() throws {
        let shard = try InterestShard(InterestArtifact(gzipped: fixture()))
        let pool = InterestPool(shards: [shard, shard], modelVersion: "m")
        XCTAssertEqual(pool.count, 3, "a paper listed twice is one paper")
        XCTAssertEqual(pool.row(of: "2610.01234v2"), 0, "a version suffix finds the paper")
        let sims = pool.similarities(to: try XCTUnwrap(pool.vector(of: "2610.01234")))
        XCTAssertEqual(sims[0], 1, accuracy: 1e-5)
        XCTAssertLessThan(sims[2], sims[1], "paper 1 shares a dimension with paper 0; paper 2 doesn't")
    }

    // MARK: The client

    private final class Server: InterestIndexTransport, @unchecked Sendable {
        let lock = NSLock()
        var manifestBody: Data
        var artifacts: [UUID: Data]
        var refuse: InterestIndexError?
        var manifestCalls = 0, artifactCalls = 0
        init(manifest: Data, artifacts: [UUID: Data]) { manifestBody = manifest; self.artifacts = artifacts }
        func manifest() async throws -> Data {
            try lock.withLock {
                manifestCalls += 1
                if let refuse { throw refuse }
                return manifestBody
            }
        }
        func artifact(_ ref: InterestManifest.ArtifactRef) async throws -> Data {
            try lock.withLock {
                artifactCalls += 1
                if let refuse { throw refuse }
                guard let data = artifacts[ref.id] else { throw InterestIndexError.unavailable }
                return data
            }
        }
    }

    private func manifest(shards: [(UUID, Data)]) -> Data {
        let list = shards.map { id, data in
            ["id": id.uuidString.lowercased(), "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
             "bytes": data.count, "papers": 3, "fp_seq_from": 1, "fp_seq_to": 3, "oldest_on": "2026-10-20", "newest_on": "2026-10-22"] as [String: Any]
        }
        let body: [String: Any] = ["format": 1, "model": ["version": "gte-small@17e1f34/onnx-fp32@5927d17/mean-l2/v1", "dim": 384,
                                                         "text_recipe": "x", "q8": "f32le scale + 384 x i8"],
                                   "window_days": 14, "map": NSNull(), "terms": NSNull(), "shards": list]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("interest-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDownloadsOnceKeepsOnDiskAndChecksTheDigest() async throws {
        let data = try fixture(), id = UUID()
        let server = Server(manifest: manifest(shards: [(id, data)]), artifacts: [id: data])
        let directory = temporaryDirectory()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let now: @Sendable () -> Date = { [clock] in clock }
        let client = InterestIndexClient(directory: directory, transport: server, now: now)
        let pool = try await client.pool()
        XCTAssertEqual(pool.count, 3)
        var stats = await client.lastStats
        XCTAssertEqual(stats.artifactsDownloaded, 1); XCTAssertEqual(stats.bytesDownloaded, data.count)
        _ = try await client.pool()
        XCTAssertEqual(server.manifestCalls, 1, "the manifest is kept for its lifetime"); XCTAssertEqual(server.artifactCalls, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(Self.fixtureSHA).gsi").path))

        // A new launch: the artifact comes from disk (and the manifest, still fresh by its file's date, isn't fetched).
        clock = Date()
        let again = InterestIndexClient(directory: directory, transport: server, now: { Date() })
        _ = try await again.pool()
        stats = await again.lastStats
        XCTAssertEqual(stats.artifactsFromCache, 1); XCTAssertEqual(server.artifactCalls, 1)

        // A damaged file on disk is fetched again; bytes that don't match the manifest are refused.
        try Data("tampered".utf8).write(to: directory.appendingPathComponent("\(Self.fixtureSHA).gsi"))
        let third = InterestIndexClient(directory: directory, transport: server, now: { Date() })
        _ = try await third.pool()
        XCTAssertEqual(server.artifactCalls, 2)
        server.artifacts[id] = Data("x".utf8) + data.dropFirst()
        try FileManager.default.removeItem(at: directory.appendingPathComponent("\(Self.fixtureSHA).gsi"))
        let fourth = InterestIndexClient(directory: directory, transport: server, now: { Date() })
        do { _ = try await fourth.pool(); XCTFail("integrity") } catch { XCTAssertEqual(error as? InterestIndexError, .integrity) }
    }

    func testRefreshesWhenTheManifestChangesAndPrunesOldShards() async throws {
        let data = try fixture(), first = UUID(), second = UUID()
        // A second, different artifact: the same papers in another gzip (another digest).
        let other = try XCTUnwrap(regzip(data))
        let server = Server(manifest: manifest(shards: [(first, data)]), artifacts: [first: data, second: other])
        let directory = temporaryDirectory()
        let clock = Clock()
        let client = InterestIndexClient(directory: directory, transport: server, now: { clock.now })
        _ = try await client.pool()
        server.manifestBody = manifest(shards: [(second, other)])
        clock.advance(601)
        _ = try await client.pool()
        XCTAssertEqual(server.manifestCalls, 2, "read again after ten minutes")
        XCTAssertEqual(server.artifactCalls, 2, "the new shard downloaded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(Self.fixtureSHA).gsi").path),
                       "a shard the manifest no longer lists is removed")

        // The server unreachable: the kept manifest and artifacts still answer.
        server.refuse = .unavailable
        clock.advance(601)
        let pool = try await client.pool()
        XCTAssertEqual(pool.count, 3)
    }

    func testNotServedClearsWhatWasKept() async throws {
        let data = try fixture(), id = UUID()
        let server = Server(manifest: manifest(shards: [(id, data)]), artifacts: [id: data])
        let directory = temporaryDirectory()
        let clock = Clock()
        let client = InterestIndexClient(directory: directory, transport: server, now: { clock.now })
        _ = try await client.pool()
        server.refuse = .notServed
        clock.advance(601)
        do { _ = try await client.pool(); XCTFail("not served") } catch { XCTAssertEqual(error as? InterestIndexError, .notServed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "nothing kept for an account that isn't served")
    }

    func testManifestBounds() throws {
        XCTAssertThrowsError(try InterestManifest.decode(Data(#"{"format":2,"model":{"version":"x","dim":384},"shards":[]}"#.utf8)))
        XCTAssertThrowsError(try InterestManifest.decode(Data(#"{"format":1,"model":{"version":"x","dim":768},"shards":[]}"#.utf8)))
        XCTAssertThrowsError(try InterestManifest.decode(Data(#"{"format":1,"model":{"version":"x","dim":384},"shards":[{"id":"6f1c6b8e-8a8e-4c55-9a43-1f2b3c4d5e6f","sha256":"ABC","bytes":3}]}"#.utf8)))
        XCTAssertNoThrow(try InterestManifest.decode(manifest(shards: [(UUID(), Data("abc".utf8))])))
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 2_000_000_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    /// The same contents gzipped again with another header time (another digest).
    private func regzip(_ data: Data) -> Data? {
        var copy = data
        copy[4] ^= 0x01 // gzip MTIME: not covered by the CRC
        return copy
    }
}
