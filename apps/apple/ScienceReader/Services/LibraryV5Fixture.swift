#if DEBUG && FIXTURE_HOST && !OFFLINE_RESOURCE_MEASUREMENTS
import CryptoKit
import Foundation
import ScienceReaderCore

/// `--library-v5-fixture`: a signed-in, activated account whose server advertises the
/// upload-capable (full-v5) library, so library writes go through the epoch-bound v5
/// commands (migration 042). Local scripted HTTP only: no DNS request, hosted account,
/// provider or private-history content. Each launch starts from an empty fixture store.
enum LibraryV5Fixture {
    static let environment = "library-v5-workflow-v1"
    static let host = "library-v5-workflow.invalid"
    static let accountID = UUID(uuidString: "fbbbbbbb-0000-4000-8000-000000000001")!
    static let datasetEpoch = UUID(uuidString: "5e5e5e5e-0000-4000-8000-000000000005")!
    static let accessToken = "library-v5-fixture-access"

    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--library-v5-fixture") }

    enum Failure: Error { case disabled, invalidRequest }

    static func makeBackend() throws -> (configuration: BackendConfiguration, client: BackendClient) {
        guard isEnabled else { throw Failure.disabled }
        // Exact synthetic names only; unrelated account keys and stores are untouched.
        for name in [environment + ".auth-session", "\(environment).\(accountID.wire).device-keys",
                     "\(environment).\(accountID.wire).support-outbox-key"] { try KeychainVault.delete(name) }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try? FileManager.default.removeItem(at: base.appendingPathComponent(environment, isDirectory: true))

        var device = LocalDevice.create(accountID: accountID)
        let bundle = KeyBundle.generate(accountID: accountID)
        device.bundle = bundle
        let publicKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: device.privateKey).publicKey.rawRepresentation
        let envelope = try ReaderCrypto.wrapForDevice(bundle, deviceID: device.deviceID, recipientPublicKey: publicKey,
                                                      challenge: device.challenge)
        LibraryV5FixtureServer.shared.reset(keyState: ["epoch": bundle.epoch, "recovery_package": "\\x",
                                                       "device_envelope": DeviceKeys.hex(envelope)])
        let session = AuthSession(access_token: accessToken, refresh_token: "library-v5-fixture-refresh",
                                  expires_at: Date().timeIntervalSince1970 + 86_400,
                                  user: .init(id: accountID, email: "library-v5@example.invalid"))
        try KeychainVault.write(ReaderCrypto.encode(session), name: environment + ".auth-session")
        try KeychainVault.write(ReaderCrypto.encode(device), name: "\(environment).\(accountID.wire).device-keys")

        let settings = URLSessionConfiguration.ephemeral
        // Admits every request so an unexpected destination fails here, never on the network.
        settings.protocolClasses = [LibraryV5FixtureProtocol.self]
        settings.urlCache = nil; settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil
        settings.httpShouldSetCookies = false; settings.waitsForConnectivity = false
        let configuration = BackendConfiguration(url: URL(string: "https://" + host)!, anonKey: "library-v5-fixture-anon",
                                                 environment: environment)
        return (configuration, try BackendClient(configuration: configuration, network: URLSession(configuration: settings)))
    }
}

/// The server side of the fixture: one saved paper, the Feed's four papers, and an
/// upload-capable library whose commands must name its dataset epoch.
final class LibraryV5FixtureServer: @unchecked Sendable {
    static let shared = LibraryV5FixtureServer()
    private let lock = NSLock()
    private var keyState: [String: Any] = [:]
    private var cursor = 1
    private var current: [String: [String: Any]] = [:]
    private var journal: [(Int, [[String: Any]])] = []
    private var receipts: [String: (body: Data, reply: [String: Any])] = [:]
    private let ids = (item: UUID(uuidString: "fbbbbbbb-0000-4000-8000-0000000000a1")!, document: UUID(uuidString: "fbbbbbbb-0000-4000-8000-0000000000a2")!,
                       approval: UUID(uuidString: "fbbbbbbb-0000-4000-8000-0000000000a3")!, version: UUID(uuidString: "fbbbbbbb-0000-4000-8000-0000000000a4")!,
                       metadata: UUID(uuidString: "fbbbbbbb-0000-4000-8000-0000000000a5")!, object: UUID(uuidString: "fbbbbbbb-0000-4000-8000-0000000000a6")!,
                       artifact: UUID(uuidString: "fbbbbbbb-0000-4000-8000-0000000000a7")!)

    nonisolated(unsafe) static let feed: [[String: Any]] = [
        ["source_id": "2610.01234", "revision": 1, "title": "Sparse Mixture-of-Experts Scaling Without Load-Balancing Losses",
         "authors": ["Mei Lin", "Jonas Weber", "Ana Costa", "Rahul Iyer"], "year": 2026, "categories": ["cs.LG", "cs.CL"],
         "abstract": "We show that expert routing with a learned temperature removes the need for auxiliary load-balancing losses."],
        ["source_id": "2610.02287", "revision": 2, "title": "Test-Time Training for Long-Context Language Models",
         "authors": ["Sara Okafor", "Peter Lindqvist"], "year": 2026, "categories": ["cs.CL"],
         "abstract": "A lightweight inner loop adapts attention projections on the prompt itself."]]

    func reset(keyState: [String: Any]) {
        lock.withLock {
            self.keyState = keyState; cursor = 1; journal = []; receipts = [:]
            let item: [String: Any] = ["kind": "item", "id": ids.item.wire, "document_id": ids.document.wire, "created_seq": 1, "state_seq": 1,
                "membership_revision": 1, "visible": true, "added_at": "2026-10-07T10:00:00Z", "last_remove_seq": 0,
                "approval_id": ids.approval.wire, "version_id": ids.version.wire, "metadata_id": ids.metadata.wire, "source": "arxiv",
                "source_id": "1706.03762", "source_revision": 7,
                "metadata": ["title": "Attention Is All You Need", "authors": ["Ashish Vaswani", "Noam Shazeer"], "abstract": NSNull(),
                             "published_at": "2017-06-12", "updated_at": "2023-08-02", "categories": ["cs.CL", "cs.LG"], "venue": NSNull()],
                "metadata_recorded_at": "2026-10-07T10:00:00Z", "source_url": "https://arxiv.org/abs/1706.03762v7",
                "scope": "shared_catalog", "page_count": 15, "original_object_id": ids.object.wire, "artifact_id": ids.artifact.wire,
                "readiness": "converted_ready", "original_availability": "available", "render_availability": "available",
                "original_availability_revision": 1, "render_availability_revision": 1]
            current = [ids.item.wire: item]
            journal = [(1, [item])]
        }
    }

    /// Answers one request; nil means the fixture refuses it.
    func respond(path: String, query: String?, body: Data) -> (status: Int, object: Any)? {
        lock.withLock {
            if path == "/functions/v1/discover" { return (200, ["results": Self.feed]) }
            guard path.hasPrefix("/rest/v1/rpc/") else { return path == "/auth/v1/logout" ? (200, [String: Any]()) : nil }
            let input = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            switch String(path.dropFirst("/rest/v1/rpc/".count)) {
            case "v1_key_state": return (200, keyState)
            case "v2_pull_events":
                return (200, ["events": [Any](), "next_cursor": input["p_after"] as? Int ?? 0, "has_more": false])
            case "v1_acknowledge_cursor": return (204, NSNull())
            case "v1_reader_capabilities":
                return (200, ["format": 1, "account_id": LibraryV5Fixture.accountID.wire,
                    "library": ["endpoint_family": "full-v5", "wire_format": 2, "source_level": 4, "dataset_epoch": LibraryV5Fixture.datasetEpoch.wire],
                    "descriptors": ["format": 1, "maximum_batch": 24],
                    "uploads": ["protocol": "upload-chunks-v1", "enabled": false, "chunk_bytes": 4_194_304,
                                "maximum_bytes": 67_108_864, "maximum_parts": 16, "part_attempts": 2]])
            case "v5_library_page": return (200, baseline())
            case "v5_library_changes":
                guard input["p_dataset_epoch"] as? String == LibraryV5Fixture.datasetEpoch.wire else { return resync() }
                let after = input["p_after"] as? Int ?? 0, through = input["p_through"] as? Int ?? cursor
                return (200, ["format": 2, "account_id": LibraryV5Fixture.accountID.wire, "through": through, "retained_after": 0,
                              "changes": journal.filter { $0.0 > after && $0.0 <= through }.map { ["seq": $0.0, "entries": $0.1] as [String: Any] },
                              "next_cursor": through, "has_more": false, "dataset_epoch": LibraryV5Fixture.datasetEpoch.wire])
            case "v5_begin_import":
                guard input["p_dataset_epoch"] as? String == LibraryV5Fixture.datasetEpoch.wire else { return resync() }
                return beginImport(input, body: body)
            case "v2_begin_import", "v2_set_library_item", "v2_cancel_import", "v2_retry_import", "v2_set_item_archived", "v2_set_item_tags":
                // An upload-capable reader must never fall back to the dataset-less v2 commands.
                return nil
            default: return (200, [Any]())
            }
        }
    }

    private func resync() -> (Int, Any) { (400, ["code": "P0001", "message": "library_resync_required"]) }

    private func baseline() -> [String: Any] {
        let entries = current.values.sorted { ($0["created_seq"] as! Int, $0["id"] as! String) < ($1["created_seq"] as! Int, $1["id"] as! String) }
        var page: [String: Any] = ["format": 2, "account_id": LibraryV5Fixture.accountID.wire, "baseline_cursor": cursor, "retained_after": 0,
                                   "entries": entries, "has_more": false, "dataset_epoch": LibraryV5Fixture.datasetEpoch.wire]
        page["next_cursor"] = entries.last.map {
            ["format": 2, "account_id": LibraryV5Fixture.accountID.wire, "through": cursor, "created_seq": $0["created_seq"]!,
             "id": $0["id"]!, "kind": $0["kind"]!, "read_level": 4, "dataset_epoch": LibraryV5Fixture.datasetEpoch.wire] as [String: Any]
        } ?? NSNull()
        return page
    }

    /// As 042 + 010: a receipt at the accepted sequence, and (as a quick worker would) the
    /// paper's details recorded in the next batch, so the Library shows its title.
    private func beginImport(_ input: [String: Any], body: Data) -> (Int, Any) {
        guard let operation = input["p_operation_id"] as? String, let source = input["p_source_id"] as? String,
              let observed = input["p_observed_cursor"] as? Int, observed <= cursor else {
            return (400, ["code": "P0001", "message": "invalid_library_cursor"])
        }
        if let stored = receipts[operation] {
            guard stored.body == body else { return (400, ["code": "P0001", "message": "operation_id_conflict"]) }
            var reply = stored.reply; reply["replayed"] = true
            return (200, reply)
        }
        let accepted = cursor + 1
        var entry: [String: Any] = ["kind": "import", "id": operation, "created_seq": accepted, "state_seq": accepted, "intent_revision": 1,
            "visible": true, "phase": "accepted", "source": "arxiv", "source_id": source, "requested_revision": input["p_requested_revision"] ?? NSNull(),
            "source_revision": NSNull(), "metadata_id": NSNull(), "version_id": NSNull(), "metadata": NSNull(), "metadata_recorded_at": NSNull(),
            "source_url": "https://arxiv.org/abs/\(source)", "document_id": NSNull(), "library_item_id": NSNull(),
            "error_code": NSNull(), "retryable": false]
        journal.append((accepted, [entry]))
        if let paper = Self.feed.first(where: { $0["source_id"] as? String == source }) {
            entry["state_seq"] = accepted + 1; entry["phase"] = "acquiring"; entry["source_revision"] = 1
            entry["metadata_id"] = UUID().wire; entry["version_id"] = UUID().wire
            entry["metadata"] = ["title": paper["title"]!, "authors": paper["authors"]!, "categories": paper["categories"]!,
                                 "published_at": "2026-10-06"] as [String: Any]
            entry["metadata_recorded_at"] = "2026-10-07T10:05:00Z"; entry["source_url"] = "https://arxiv.org/abs/\(source)v1"
            journal.append((accepted + 1, [entry]))
            cursor = accepted + 1
        } else { cursor = accepted }
        current[operation] = entry
        let reply: [String: Any] = ["result": ["status": "applied", "kind": "import", "id": operation, "seq": accepted, "revision": 1],
                                    "replayed": false, "entry": entry, "dataset_epoch": LibraryV5Fixture.datasetEpoch.wire]
        receipts[operation] = (body, reply)
        return (200, reply)
    }
}

private final class LibraryV5FixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard LibraryV5Fixture.isEnabled, let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == LibraryV5Fixture.host,
              request.value(forHTTPHeaderField: "Authorization") == "Bearer \(LibraryV5Fixture.accessToken)",
              let answer = LibraryV5FixtureServer.shared.respond(path: components.path, query: components.query, body: Self.body(request)),
              let data = answer.object is NSNull ? Data() : try? JSONSerialization.data(withJSONObject: answer.object, options: [.sortedKeys]),
              let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json", "Content-Length": String(data.count)])
        else {
            // Never emit a captured URL, body or token.
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }

    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
#endif
