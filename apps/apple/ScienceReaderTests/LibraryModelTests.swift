import CryptoKit
import Foundation
import Observation
import PDFKit
import ScienceReaderCore
import SQLite3
import SwiftUI
import XCTest
@testable import ScienceReader

/// Catch every request, including unexpected hosts. No fallback to a live network, provider or paper server.
private final class ImportAcceptanceProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var type: String
        var body: Data
        var delay: TimeInterval = 0
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var captured: [String] = []
    static var requests: [String] { lock.withLock { captured } }
    static func put(_ url: String, _ reply: Reply) { lock.withLock { replies[url] = reply } }
    static func reset() { lock.withLock { replies = [:]; captured = [] } }
    static func denyAll() { lock.withLock { replies = [:] } }
    private let state = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock { Self.captured.append(request.url!.absoluteString); return Self.replies[request.url!.absoluteString] }
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            state.withLock {
                guard !stopped else { return }
                let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                    headerFields: ["Content-Type": reply.type, "Content-Length": String(reply.body.count)])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: reply.body); client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    override func stopLoading() { state.withLock { stopped = true } }
}

private final class LibraryModelServer: @unchecked Sendable {
    enum CommandStep { case loseAcknowledgement, hold(XCTestExpectation) }
    struct CapturedCommand { let endpoint: String; let body: Data }
    let account = UUID(), itemID = UUID(), documentID = UUID(), importID = UUID()
    let artifactID = UUID(), metadataID = UUID(), versionID = UUID(), approvalID = UUID(), objectID = UUID()
    let device: LocalDevice?
    private let lock = NSLock()
    private var next: (Data, Int)?
    private var failBaseline = false
    private var keyState: Data?
    private var commandSteps: [CommandStep] = []
    private var capturedCommands: [CapturedCommand] = []
    private var receipts: [UUID: (body: Data, value: [String: Any])] = [:]
    private var changedEntries: [String: [String: Any]] = [:]
    private var libraryChanges: [(Int, [[String: Any]])] = []
    private var cursor = 2
    private var heldCommand: (StubProtocol, Data)?
    private var holdChanges: XCTestExpectation?
    private var heldChanges: (StubProtocol, Data)?
    private var privateEvents: [[String: Any]] = []
    private var privateCalls: [String] = []
    private var endpoints: [String] = []
    func requestedEndpoints() -> [String] { lock.withLock { endpoints } }
    /// The catalog's topic tags on the item entry (migration 030); none by default (no `tags` key).
    var catalogTags: [String] = []
    var metadataTitle = "A paper about equation handling"

    /// The baseline import failed to download (retryable), with its paper's details known.
    private let pendingFailed: Bool
    /// An upload-capable (full-v5) server's dataset epoch; nil models a legacy (v3) server.
    private var epoch: UUID?
    /// Capability answers still naming the previous epoch after a rotation (a read racing a restore).
    private var staleCapabilities = 0
    private var previousEpoch: UUID?
    private var capturedPages: [(endpoint: String, epoch: String?)] = []
    private var v5CommandsAvailable = true

    init(activated: Bool = false, pendingFailed: Bool = false, uploadEpoch: UUID? = nil) {
        self.pendingFailed = pendingFailed; self.epoch = uploadEpoch
        if activated {
            var device = LocalDevice.create(accountID: account)
            device.bundle = KeyBundle.generate(accountID: account)
            self.device = device
        } else { device = nil }
    }
    func installDeviceEnvelope() throws {
        guard let device, let bundle = device.bundle else { return }
        let publicKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: device.privateKey).publicKey.rawRepresentation
        let envelope = try ReaderCrypto.wrapForDevice(bundle, deviceID: device.deviceID,
            recipientPublicKey: publicKey, challenge: device.challenge)
        lock.withLock {
            keyState = bytes(["epoch": bundle.epoch, "recovery_package": "\\x", "device_envelope": DeviceKeys.hex(envelope)])
        }
    }
    func failInitial() { lock.withLock { failBaseline = true } }
    func deliver(_ data: Data, status: Int = 200) { lock.withLock { next = (data, status) } }
    func enqueueCommand(_ step: CommandStep) { lock.withLock { commandSteps.append(step) } }
    func holdNextChanges(_ expectation: XCTestExpectation) { lock.withLock { holdChanges = expectation } }
    func commands() -> [CapturedCommand] { lock.withLock { capturedCommands } }
    func setV5CommandsAvailable(_ available: Bool) { lock.withLock { v5CommandsAvailable = available } }
    func pages() -> [(endpoint: String, epoch: String?)] { lock.withLock { capturedPages } }
    var currentEpoch: UUID? { lock.withLock { epoch } }
    /// Restore quarantine: a new dataset identity. The next `stale` capability reads still name the old one.
    func rotateEpoch(stale: Int = 0) {
        lock.withLock { previousEpoch = epoch; epoch = UUID(); staleCapabilities = stale }
    }
    func privateRequests() -> [String] { lock.withLock { privateCalls } }
    func releaseCommand() {
        lock.withLock {
            if let (request, data) = heldCommand { heldCommand = nil; request.respond(data) }
        }
    }
    func releaseChanges() {
        lock.withLock {
            if let (request, data) = heldChanges { heldChanges = nil; request.respond(data) }
        }
    }
    func releaseAll() { releaseCommand(); releaseChanges() }
    func handle(_ request: StubProtocol) {
        lock.withLock {
            endpoints.append(request.request.url!.path)
            switch request.request.url!.lastPathComponent {
            case "v1_reader_capabilities":
                if var advertised = epoch {
                    if staleCapabilities > 0, let previousEpoch { staleCapabilities -= 1; advertised = previousEpoch }
                    request.respond(bytes(["format": 1, "account_id": account.wire,
                        "library": ["endpoint_family": "full-v5", "wire_format": 2, "source_level": 4, "dataset_epoch": advertised.wire],
                        "descriptors": ["format": 1, "maximum_batch": 24],
                        "uploads": ["protocol": "upload-chunks-v1", "enabled": false, "chunk_bytes": 4_194_304,
                                    "maximum_bytes": 67_108_864, "maximum_parts": 16, "part_attempts": 2]]))
                } else {
                    request.respond(Data(#"{"code":"PGRST202","message":"Could not find the function public.v1_reader_capabilities without parameters in the schema cache"}"#.utf8), status: 404)
                }
            case "v3_library_page" where epoch == nil, "v5_library_page" where epoch != nil:
                capturedPages.append((request.request.url!.lastPathComponent, nil))
                if failBaseline { failBaseline = false; request.respond(Data("{}".utf8), status: 503) }
                else { request.respond(baseline()) }
            case "v3_library_changes" where epoch == nil, "v5_library_changes" where epoch != nil:
                let body = fields(request.request)
                capturedPages.append((request.request.url!.lastPathComponent, body["p_dataset_epoch"] as? String))
                if let epoch, body["p_dataset_epoch"] as? String != epoch.wire { resync(request); return }
                let after = body["p_after"] as? Int ?? 0, through = body["p_through"] as? Int ?? cursor
                let rows = libraryChanges.filter { $0.0 > after && $0.0 <= through }
                var page: [String: Any] = ["format": 2, "account_id": account.wire, "through": through, "retained_after": 0,
                    "changes": rows.map { ["seq": $0.0, "entries": $0.1] as [String: Any] }, "next_cursor": through, "has_more": false]
                if let epoch { page["dataset_epoch"] = epoch.wire }
                let current = bytes(page)
                let response = next ?? (current, 200); next = nil
                if let arrival = holdChanges {
                    holdChanges = nil; heldChanges = (request, response.0); arrival.fulfill()
                } else { request.respond(response.0, status: response.1) }
            case "v2_begin_import", "v2_cancel_import", "v2_retry_import", "v2_set_library_item", "v2_set_item_tags", "v2_set_item_archived": handleCommand(request)
            case "v5_begin_import", "v5_cancel_import", "v5_retry_import", "v5_set_library_item", "v5_set_item_tags", "v5_set_item_archived":
                // Migration 042: the v2 command plus its observed dataset, checked in the same transaction.
                guard let epoch else { request.respond(Data("{}".utf8), status: 404); return }
                guard v5CommandsAvailable else {
                    capturedCommands.append(.init(endpoint: request.request.url!.lastPathComponent, body: body(request.request)))
                    request.respond(bytes(["code": "PGRST202", "message": "Could not find the function in the schema cache"]), status: 404)
                    return
                }
                guard fields(request.request)["p_dataset_epoch"] as? String == epoch.wire else {
                    capturedCommands.append(.init(endpoint: request.request.url!.lastPathComponent, body: body(request.request)))
                    resync(request); return
                }
                handleCommand(request)
            case "v1_key_state":
                privateCalls.append("key_state"); request.respond(keyState ?? Data("null".utf8))
            case "v3_pull_events":
                privateCalls.append("pull")
                let after = fields(request.request)["p_after"] as? Int ?? 0
                let rows = privateEvents.filter { ($0["cursor"] as? Int ?? 0) > after }
                request.respond(bytes(["events": rows, "next_cursor": rows.last?["cursor"] ?? after, "has_more": false]))
            case "v1_append_event":
                privateCalls.append("append")
                let body = fields(request.request)
                if let existing = privateEvents.first(where: { $0["id"] as? String == body["p_id"] as? String }) {
                    request.respond(bytes(existing["cursor"]!))
                } else if let encoded = body["p_ciphertext"] as? String, let ciphertext = try? DeviceKeys.bytea(encoded) {
                    let sequence = privateEvents.count + 1
                    privateEvents.append(["id": body["p_id"]!, "device_id": body["p_device_id"]!, "cursor": sequence,
                        "epoch": body["p_epoch"]!, "format": body["p_format"]!, "ciphertext": encoded,
                        "ciphertext_sha256": DeviceKeys.hex(Data(SHA256.hash(data: ciphertext)))])
                    request.respond(bytes(sequence))
                } else { request.respond(Data("{}".utf8), status: 400) }
            case "v1_acknowledge_cursor": privateCalls.append("ack"); request.respond(Data(), status: 204)
            case "v5_set_source_details":
                // Captured and left unconfirmed (a busy server), so the change stays pending.
                capturedCommands.append(.init(endpoint: request.request.url!.lastPathComponent, body: body(request.request)))
                request.respond(Data("{}".utf8), status: 503)
            case "logout": request.respond(Data("{}".utf8))
            default: request.respond(Data("[]".utf8))
            }
        }
    }
    private func bytes(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) }
    private func body(_ request: URLRequest) -> Data {
        if let bytes = request.httpBody { return bytes }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4_096), bytes = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
        }
        return bytes
    }
    private func fields(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body(request))) as? [String: Any] ?? [:]
    }
    private func resync(_ request: StubProtocol) {
        request.respond(bytes(["code": "P0001", "message": "library_resync_required"]), status: 400)
    }
    private func handleCommand(_ request: StubProtocol) {
        let sent = request.request.url!.lastPathComponent, data = body(request.request)
        let endpoint = sent.replacingOccurrences(of: "v5_", with: "v2_")
        capturedCommands.append(.init(endpoint: sent, body: data))
        guard let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let operation = (input["p_operation_id"] as? String).flatMap(UUID.init(uuidString:)) else {
            request.respond(Data("{}".utf8), status: 400); return
        }
        let response: Data
        if let stored = receipts[operation] {
            guard stored.body == data else {
                request.respond(bytes(["code": "P0001", "message": "operation_id_conflict"]), status: 400); return
            }
            var reply = stored.value; reply["replayed"] = true; response = bytes(reply)
        } else {
            let entry: [String: Any], revision: Int
            cursor += 1
            switch endpoint {
            case "v2_begin_import":
                let source = input["p_source_id"] as? String ?? "invalid"
                let reference = source + ((input["p_requested_revision"] as? Int).map { "v\($0)" } ?? "")
                revision = 1
                entry = ["kind": "import", "id": operation.wire, "created_seq": cursor, "state_seq": cursor,
                    "intent_revision": 1, "visible": true, "phase": "accepted", "source": "arxiv", "source_id": source,
                    "requested_revision": input["p_requested_revision"] ?? NSNull(), "source_revision": NSNull(),
                    "metadata_id": NSNull(), "version_id": NSNull(), "metadata": NSNull(), "metadata_recorded_at": NSNull(),
                    "source_url": "https://arxiv.org/abs/\(reference)", "document_id": NSNull(), "library_item_id": NSNull(),
                    "error_code": NSNull(), "retryable": false]
            case "v2_cancel_import":
                guard let id = input["p_import_id"] as? String,
                      var row = changedEntries[id] ?? (id == importID.wire ? pending() : nil),
                      row["intent_revision"] as? Int == input["p_expected_revision"] as? Int else {
                    request.respond(Data("{}".utf8), status: 409); return
                }
                revision = (row["intent_revision"] as! Int) + 1
                row["intent_revision"] = revision; row["state_seq"] = cursor; row["visible"] = false; row["phase"] = "cancelled"
                entry = row
            case "v2_retry_import":
                // As the server does: a failed, retryable import with known details resumes as acquiring.
                guard let id = input["p_import_id"] as? String,
                      var row = changedEntries[id] ?? (id == importID.wire ? pending() : nil),
                      row["phase"] as? String == "failed", row["retryable"] as? Bool == true,
                      row["intent_revision"] as? Int == input["p_expected_revision"] as? Int else {
                    request.respond(Data("{}".utf8), status: 409); return
                }
                revision = (row["intent_revision"] as! Int) + 1
                row["intent_revision"] = revision; row["state_seq"] = cursor; row["phase"] = "acquiring"
                row["error_code"] = NSNull(); row["retryable"] = false
                entry = row
            case "v2_set_library_item":
                var row = changedEntries[itemID.wire] ?? item()
                guard input["p_document_id"] as? String == documentID.wire, input["p_present"] as? Bool == false,
                      input["p_expected_revision"] as? Int == row["membership_revision"] as? Int else {
                    request.respond(Data("{}".utf8), status: 409); return
                }
                revision = (row["membership_revision"] as! Int) + 1
                row["membership_revision"] = revision; row["state_seq"] = cursor
                row["visible"] = false; row["last_remove_seq"] = cursor
                row.removeValue(forKey: "user_tags"); row.removeValue(forKey: "hidden_tags")
                entry = row
            case "v2_set_item_tags":
                var row = changedEntries[itemID.wire] ?? item()
                guard input["p_document_id"] as? String == documentID.wire,
                      input["p_expected_revision"] as? Int == row["membership_revision"] as? Int,
                      let own = input["p_tags"] as? [String], let hidden = input["p_hidden_tags"] as? [String] else {
                    request.respond(Data("{}".utf8), status: 409); return
                }
                revision = (row["membership_revision"] as! Int) + 1
                row["membership_revision"] = revision; row["state_seq"] = cursor
                row["user_tags"] = own; row["hidden_tags"] = hidden
                entry = row
            case "v2_set_item_archived":
                var row = changedEntries[itemID.wire] ?? item()
                guard input["p_document_id"] as? String == documentID.wire,
                      input["p_expected_revision"] as? Int == row["membership_revision"] as? Int,
                      let archived = input["p_archived"] as? Bool else {
                    request.respond(Data("{}".utf8), status: 409); return
                }
                revision = (row["membership_revision"] as! Int) + 1
                row["membership_revision"] = revision; row["state_seq"] = cursor; row["archived"] = archived
                entry = row
            default: request.respond(Data("{}".utf8), status: 404); return
            }
            changedEntries[entry["id"] as! String] = entry
            libraryChanges.append((cursor, [entry]))
            var value: [String: Any] = ["result": ["status": "applied", "kind": entry["kind"]!, "id": entry["id"]!,
                "seq": cursor, "revision": revision], "entry": entry, "replayed": false]
            if sent.hasPrefix("v5_"), let epoch { value["dataset_epoch"] = epoch.wire }
            receipts[operation] = (data, value); response = bytes(value)
        }
        let step = commandSteps.isEmpty ? nil : commandSteps.removeFirst()
        switch step {
        case .loseAcknowledgement: request.respond(Data("{}".utf8), status: 503)
        case .hold(let arrival): heldCommand = (request, response); arrival.fulfill()
        case nil: request.respond(response)
        }
    }
    private var metadata: [String: Any] {
        ["title": metadataTitle, "authors": ["Ada Researcher"], "abstract": "A bounded test of library transitions.",
         "published_at": "2024-04-03", "updated_at": "2024-05-02", "categories": ["cs.LG", "stat.ML"], "venue": NSNull()]
    }
    func item(state: Int = 1, visible: Bool = true, available: Bool = true) -> [String: Any] {
        var row = itemRow(state: state, visible: visible, available: available)
        if visible && !catalogTags.isEmpty { row["tags"] = catalogTags }
        return row
    }
    private func itemRow(state: Int, visible: Bool, available: Bool) -> [String: Any] {
        ["kind": "item", "id": itemID.wire, "document_id": documentID.wire, "created_seq": 1, "state_seq": state,
         "membership_revision": visible ? 1 : 2, "visible": visible, "added_at": "2026-10-03T10:00:00Z", "last_remove_seq": visible ? 0 : state,
         "approval_id": approvalID.wire, "version_id": versionID.wire, "metadata_id": metadataID.wire, "source": "arxiv",
         "source_id": "2404.00001", "source_revision": 1, "metadata": metadata, "metadata_recorded_at": "2026-10-03T10:00:00Z",
         "source_url": "https://arxiv.org/abs/2404.00001v1", "scope": "shared_catalog", "page_count": 10,
         "original_object_id": objectID.wire, "artifact_id": artifactID.wire, "readiness": available ? "converted_ready" : "unavailable",
         "original_availability": "available", "render_availability": available ? "available" : "quarantined",
         "original_availability_revision": 1, "render_availability_revision": available ? 1 : 2]
    }
    func pending(state: Int = 2, resolved: Bool = false, sourceOnly: Bool = false) -> [String: Any] {
        if pendingFailed, !resolved, !sourceOnly {
            var row = pending(state: state, sourceOnly: true)
            row["phase"] = "failed"; row["error_code"] = "download_failed"; row["retryable"] = true
            return row
        }
        let pinned = resolved || sourceOnly
        return ["kind": "import", "id": importID.wire, "created_seq": 2, "state_seq": state, "intent_revision": 1,
                "visible": !resolved, "phase": resolved ? "ready" : (sourceOnly ? "source_only" : "accepted"),
                "source": "arxiv", "source_id": "2404.00001", "requested_revision": NSNull(),
                "source_revision": pinned ? (1 as Any) : NSNull(), "metadata_id": pinned ? (metadataID.wire as Any) : NSNull(),
                "version_id": pinned ? (versionID.wire as Any) : NSNull(), "metadata": pinned ? (metadata as Any) : NSNull(),
                "metadata_recorded_at": pinned ? ("2026-10-03T10:00:00Z" as Any) : NSNull(),
                "source_url": pinned ? "https://arxiv.org/abs/2404.00001v1" : "https://arxiv.org/abs/2404.00001",
                "document_id": resolved ? (documentID.wire as Any) : NSNull(), "library_item_id": resolved ? (itemID.wire as Any) : NSNull(),
                "error_code": sourceOnly ? ("license_unverified" as Any) : NSNull(), "retryable": false]
    }
    func baseline() -> Data {
        var byID = [itemID.wire: item(), importID.wire: pending()]
        byID.merge(changedEntries) { _, next in next }
        let entries = byID.values.sorted { ($0["created_seq"] as! Int) < ($1["created_seq"] as! Int) }
        let last = entries.last!
        var next: [String: Any] = ["format": 2, "account_id": account.wire, "through": cursor,
                                   "created_seq": last["created_seq"]!, "id": last["id"]!, "kind": last["kind"]!]
        var page: [String: Any] = ["format": 2, "account_id": account.wire, "baseline_cursor": cursor, "retained_after": 0,
                                   "entries": entries, "has_more": false]
        if let epoch { next["read_level"] = 4; next["dataset_epoch"] = epoch.wire; page["dataset_epoch"] = epoch.wire }
        page["next_cursor"] = next
        return bytes(page)
    }
    func changes(_ rows: [[String: Any]], through: Int) -> Data {
        var page: [String: Any] = ["format": 2, "account_id": account.wire, "through": through, "retained_after": 0,
               "changes": rows.isEmpty ? [] : [["seq": through, "entries": rows]], "next_cursor": through, "has_more": false]
        // An upload-capable server names its dataset on every page, as the live changes route does.
        if let epoch = lock.withLock({ epoch }) { page["dataset_epoch"] = epoch.wire }
        return bytes(page)
    }
}

@MainActor
private final class LibraryModelObservation {
    let ready: XCTestExpectation
    private let condition: @MainActor () -> Bool
    private var stopped = false
    init(_ description: String, condition: @escaping @MainActor () -> Bool) {
        ready = XCTestExpectation(description: description); self.condition = condition
    }
    func observe() {
        guard !stopped else { return }
        let complete = withObservationTracking { condition() } onChange: {
            Task { @MainActor [weak self] in self?.observe() }
        }
        if complete { stopped = true; ready.fulfill() }
    }
    func stop() { stopped = true }
}

@MainActor
private final class LibraryPresentationObservation: NSObject {
    let ready: XCTestExpectation
    private let condition: @MainActor () -> Bool
    private var displayLink: CADisplayLink?
    init(_ description: String, condition: @escaping @MainActor () -> Bool) {
        ready = XCTestExpectation(description: description); self.condition = condition
    }
    func start() {
        let link = CADisplayLink(target: self, selector: #selector(frame))
        displayLink = link; link.add(to: .main, forMode: .common)
    }
    @objc private func frame() {
        if condition() { stop(); ready.fulfill() }
    }
    func stop() { displayLink?.invalidate(); displayLink = nil }
}

@MainActor
final class LibraryModelTests: XCTestCase {
    private enum FixtureError: Error { case timedOut, importFailed, sqlite(Int32) }

    private func fixture(_ server: LibraryModelServer) throws -> Fixture {
        let fixture = try Fixture(server)
        addTeardownBlock { await fixture.close() }
        return fixture
    }

    private func observe(_ description: String, _ condition: @escaping @MainActor () -> Bool) async throws {
        let observation = LibraryModelObservation(description, condition: condition)
        observation.observe()
        await fulfillment(of: [observation.ready], timeout: 5)
        observation.stop()
        guard condition() else { throw FixtureError.timedOut }
    }

    private func window(for model: ReaderModel) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(rootView: LibraryView(model: model))
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
        }
        return window
    }

    func testCatalogNamesDefaultsMovesAndRelaunchKeepTheSamePapers() async throws {
        let server = LibraryModelServer(activated: true), fixture = try fixture(server), model = fixture.model
        await model.start()
        let paper = try XCTUnwrap(model.papers.first), original = model.currentCatalog.id
        let research = try await model.createCatalog("Research")
        try await model.renameCatalog(original, name: "Reading")
        try await model.movePaper(paper, toCatalog: research)
        try await model.makeDefaultCatalog(research)
        XCTAssertEqual(model.catalogCount(research), 1)
        model.selectCatalog(original); await model.waitForLibrarySearch()
        XCTAssertFalse(model.libraryRows.contains { $0.id == "paper/\(paper.id.wire)" })
        try await fixture.relaunch()
        let reopened = fixture.model
        XCTAssertEqual(reopened.currentCatalog.id, research)
        XCTAssertEqual(reopened.libraryCatalogs.catalog(original)?.name, "Reading")
        XCTAssertEqual(reopened.libraryCatalogs.catalogID(for: reopened.catalogKey(paper)), research)
        XCTAssertTrue(reopened.papers.contains { $0.id == paper.id })
        try await reopened.retireCatalog(research, movingTo: original, newName: nil)
        XCTAssertEqual(reopened.currentCatalog.id, original)
        XCTAssertEqual(reopened.libraryCatalogs.catalogID(for: reopened.catalogKey(paper)), original)
        XCTAssertTrue(server.commands().isEmpty, "Moving a catalog never removes or reimports its papers")
    }

    func testCatalogDeletionToANewNamePreservesPapersAndCanRemoveEmptyFinalCatalog() async throws {
        let server = LibraryModelServer(activated: true), fixture = try fixture(server), model = fixture.model
        await model.start()
        let old = model.currentCatalog.id, before = model.papers.map(\.id)
        try await model.retireCatalog(old, movingTo: nil, newName: "All research")
        XCTAssertEqual(model.libraryCatalogs.catalogs.count, 1)
        XCTAssertEqual(model.currentCatalog.name, "All research")
        XCTAssertEqual(model.papers.map(\.id), before)
        let empty = try await model.createCatalog("Temporary")
        try await model.deleteCatalogAndPapers(empty)
        XCTAssertNil(model.libraryCatalogs.catalog(empty))
        XCTAssertEqual(model.papers.map(\.id), before)
    }

    func testCatalogImportKeepsItsAssignmentAfterSelectionChangesAndDuplicateAdd() async throws {
        let server = LibraryModelServer(activated: true), fixture = try fixture(server), model = fixture.model
        model.importPollDelay = { _ in 3600 }; await model.start()
        let catalog = try await model.createCatalog("New work")
        try await model.importPaper("1706.03762v7")
        model.selectCatalog(LibraryCatalogBatch.initialCatalogID)
        try await observe("Import catches up") { !model.libraryCommands.contains(where: \.isUnfinished) }
        XCTAssertEqual(model.libraryCatalogs.catalogID(for: "arxiv:1706.03762"), catalog)
        try await model.importPaper("1706.03762v7")
        XCTAssertEqual(model.libraryCatalogs.catalogID(for: "arxiv:1706.03762"), catalog, "Adding an existing paper never moves it")
    }

    func testCatalogPaperDeletionWaitsForActualRemovalAndKeepsCatalogAfterRefusal() async throws {
        let server = LibraryModelServer(activated: true, uploadEpoch: UUID()), fixture = try fixture(server), model = fixture.model
        model.importPollDelay = { _ in 3600 }; await model.start()
        let paper = try XCTUnwrap(model.papers.first), catalog = try await model.createCatalog("Remove these")
        try await model.movePaper(paper, toCatalog: catalog)
        server.setV5CommandsAvailable(false)
        do { try await model.deleteCatalogAndPapers(catalog); XCTFail("A refused removal must leave its catalog") }
        catch { XCTAssertEqual(error as? LibraryCatalogError, .pendingChanges) }
        XCTAssertNotNil(model.libraryCatalogs.catalog(catalog)); XCTAssertTrue(model.papers.contains { $0.id == paper.id })
        let before = try XCTUnwrap(server.commands().last).body
        server.setV5CommandsAvailable(true)
        try await model.deleteCatalogAndPapers(catalog)
        XCTAssertNil(model.libraryCatalogs.catalog(catalog)); XCTAssertFalse(model.papers.contains { $0.id == paper.id })
        XCTAssertEqual(server.commands().filter { $0.endpoint == "v5_set_library_item" }.last?.body, before, "Retry the original durable removal, not a new operation")
    }

    func testCatalogDeletionKeepsAPaperAddedAfterConfirmation() async throws {
        let server = LibraryModelServer(activated: true), fixture = try fixture(server), model = fixture.model
        model.importPollDelay = { _ in 3600 }; await model.start()
        let paper = try XCTUnwrap(model.papers.first), catalog = try await model.createCatalog("Review")
        try await model.movePaper(paper, toCatalog: catalog)
        let received = expectation(description: "Removal is in flight")
        server.enqueueCommand(.hold(received))
        let task = Task { try await model.deleteCatalogAndPapers(catalog) }
        await fulfillment(of: [received], timeout: 5)
        model.openSample()
        let added = try XCTUnwrap(model.papers.first(where: \.isSample))
        try await model.movePaper(added, toCatalog: catalog)
        server.releaseCommand()
        do { try await task.value; XCTFail("The newly added paper was not authorized for deletion") }
        catch { XCTAssertEqual(error as? LibraryCatalogError, .changedDuringDeletion) }
        XCTAssertNotNil(model.libraryCatalogs.catalog(catalog))
        XCTAssertTrue(model.papers.contains { $0.id == added.id })
    }

    func testPendingAndSourceOnlyPresentation() async throws {
        let server = LibraryModelServer(), fixture = try fixture(server)
        let model = fixture.model
        await model.start()
        let window = try window(for: model)
        try await capture(window, name: "Pending import beside saved paper")
        server.deliver(server.changes([server.pending(state: 3, sourceOnly: true)], through: 3))
        await model.refreshLibrary()
        XCTAssertNil(model.libraryIssue)
        try await capture(window, name: "Source-only result beside saved paper")
    }

    func testSourceAddedDateClearedKeywordsAndContextualSignOut() async throws {
        let server = LibraryModelServer(), fixture = try fixture(server), model = fixture.model
        await model.start()
        var row = server.pending(state: 3, sourceOnly: true)
        var metadata = try XCTUnwrap(row["metadata"] as? [String: Any])
        metadata["title"] = "Direct Preference Optimization: DPO"
        row["metadata"] = metadata
        row["added_at"] = "2026-10-02T09:15:00Z"; row["tags_customized"] = false
        server.deliver(server.changes([row], through: 3)); await model.refreshLibrary()
        let paper = try XCTUnwrap(model.papers.first { $0.sourceMembership != nil })
        XCTAssertEqual(paper.addedAt, ISO8601DateFormatter().date(from: "2026-10-02T09:15:00Z"))
        XCTAssertFalse(LibraryTags.tags(for: paper).isEmpty)
        row["state_seq"] = 4; row["intent_revision"] = 2; row["tags_customized"] = true; row["user_tags"] = [String]()
        server.deliver(server.changes([row], through: 4)); await model.refreshLibrary()
        let cleared = try XCTUnwrap(model.papers.first { $0.sourceMembership != nil })
        XCTAssertEqual(cleared.addedAt, paper.addedAt); XCTAssertTrue(LibraryTags.tags(for: cleared).isEmpty)
        let token = model.beginContextualChat(paperID: paper.id, manifest: String(repeating: "a", count: 64), element: "eq1", label: "Equation (1)", quote: "x^2")
        XCTAssertTrue(model.ownsContextualChat(token)); await model.signOut()
        XCTAssertFalse(model.hasContextualChat); XCTAssertFalse(model.ownsContextualChat(token))
        model.endContextualChat(token); XCTAssertFalse(model.hasContextualChat)
    }

    func testLiveHTMLSelectionInstallsAndDisplaysThroughTheAccountModel() async throws {
        guard ProcessInfo.processInfo.environment["SCIENCE_READER_LIVE_HTML"] == "1" else {
            throw XCTSkip("Opt-in live official HTML on the Simulator only.")
        }
        let server = LibraryModelServer(activated: true), fixture = try fixture(server), model = fixture.model
        await model.start()
        var row = server.pending(state: 3, sourceOnly: true)
        row["source_id"] = "2305.18290"; row["source_revision"] = 3
        row["source_url"] = "https://arxiv.org/abs/2305.18290v3"
        server.deliver(server.changes([row], through: 3))
        await model.refreshLibrary()
        let paper = try XCTUnwrap(model.papers.first { $0.sourceMembership != nil })
        model.select(paper)
        XCTAssertEqual(model.openingPaperID, paper.id)
        let observation = LibraryModelObservation("The selected HTML reader is installed and displayed") {
            model.selectedPaper?.readerBundle != nil || model.readerOpenIssue != nil
        }
        observation.observe()
        await fulfillment(of: [observation.ready], timeout: 90)
        observation.stop()
        XCTAssertNil(model.readerOpenIssue)
        XCTAssertEqual(model.selectedPaper?.readerBundle?.index.equations.count, 261)
        XCTAssertNotNil(model.readerDocumentScope)
        XCTAssertNil(model.openingPaperID)
        XCTAssertEqual(model.offlineStatus(for: try XCTUnwrap(model.selectedPaper)), .available)
    }

    /// Opt-in investigation of the build 63/64 Library failures. Unlike the cached compiler replay, this exercises
    /// URLSession acquisition, concurrent Library preparations, encrypted installation, and opening the saved copies.
    /// Only the account backend is a fixture; official arXiv content is fetched directly by the Simulator.
    func testReportedPapersDownloadInstallAndOpenThroughTheLibrary() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCIENCE_READER_LIVE_LIBRARY_CASES"] else {
            throw XCTSkip("Opt-in live reported-paper Library investigation on the Simulator only.")
        }
        struct ReportedPaper: Decodable {
            let source_id: String
            let source_revision: Int
            let title: String
            let authors: [String]
        }
        let cases = try JSONDecoder().decode([ReportedPaper].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertTrue((1...3).contains(cases.count))
        let server = LibraryModelServer(activated: true), fixture = try fixture(server), model = fixture.model
        await model.start()
        let rows = cases.map { paper -> [String: Any] in
            var row = server.pending(state: 3, sourceOnly: true)
            row["id"] = UUID().wire; row["created_seq"] = 3
            row["source_id"] = paper.source_id; row["source_revision"] = paper.source_revision
            row["source_url"] = "https://arxiv.org/abs/\(paper.source_id)v\(paper.source_revision)"
            row["metadata_id"] = UUID().wire; row["version_id"] = UUID().wire
            var metadata = row["metadata"] as? [String: Any] ?? [:]
            metadata["title"] = paper.title; metadata["authors"] = paper.authors
            row["metadata"] = metadata
            return row
        }
        server.deliver(server.changes(rows, through: 3))
        await model.refreshLibrary()
        let papers = model.papers.filter { paper in cases.contains { $0.source_id == paper.sourceID } }
        XCTAssertEqual(papers.count, cases.count)
        let started = Date()
        for paper in papers {
            model.prepareOnDevice(paper)
            XCTAssertTrue(model.isPreparingOnDevice(paper), "\(paper.sourceID ?? "unknown"): preparation started")
        }
        let preparation = LibraryModelObservation("Reported papers finish preparing in the Library") {
            papers.allSatisfy { !model.isPreparingOnDevice($0) }
        }
        preparation.observe()
        await fulfillment(of: [preparation.ready], timeout: 240)
        preparation.stop()
        for paper in papers {
            let issue = model.devicePreparationIssues[paper.id]
            print("Live Library preparation \(paper.sourceID ?? "unknown"): \(issue ?? "installed")")
            XCTAssertNil(issue)
            XCTAssertEqual(model.deviceCopy(for: paper), .reader)
            model.select(paper)
            let opened = LibraryModelObservation("Prepared paper opens from the encrypted store") {
                model.selectedPaper?.readerBundle != nil || model.readerOpenIssue != nil
            }
            opened.observe()
            await fulfillment(of: [opened.ready], timeout: 120)
            opened.stop()
            print("Live Library open \(paper.sourceID ?? "unknown"): \(model.readerOpenCode ?? "opened")")
            XCTAssertNil(model.readerOpenIssue)
            XCTAssertFalse(model.selectedPaper?.readerBundle?.index.blocks.isEmpty ?? true)
        }
        print("Live reported-paper Library flow: \(papers.count) papers in \(Date().timeIntervalSince(started)) seconds")
    }

    // Offline acceptance: only HTTP replies and account metadata are fixtures. The shipped native downloader,
    // WebKit compiler, validators, account-owned encrypted stores and ReaderModel state transitions all run.
    private func importNetwork() throws {
        ImportAcceptanceProtocol.reset()
        ArxivHTMLReader.fixtureProtocolClasses = [ImportAcceptanceProtocol.self]
        let suite = "import-acceptance-\(UUID().uuidString)"
        ArxivHTMLReader.refusalSuite = suite
        addTeardownBlock { @MainActor in
            ArxivHTMLReader.fixtureProtocolClasses = nil; ArxivHTMLReader.refusalSuite = nil
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            ImportAcceptanceProtocol.reset()
        }
    }
    private var importRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func importReplies(htmlStatus: Int = 200, delay: TimeInterval = 0) throws {
        let html = try Data(contentsOf: importRoot.appendingPathComponent("tests/fixtures/reader-arxiv/import-acceptance.html"))
        let png = try Data(contentsOf: importRoot.appendingPathComponent("tests/fixtures/reader/assets/attention.png"))
        ImportAcceptanceProtocol.put("https://arxiv.org/html/2601.01234v2", .init(status: htmlStatus, type: "text/html", body: html, delay: delay))
        for i in 0..<10 {
            ImportAcceptanceProtocol.put("https://arxiv.org/html/2601.01234v2/asset-\(i).png",
                .init(status: i == 5 ? 404 : 200, type: "image/png", body: png, delay: i % 4 == 0 ? 0.04 : 0))
        }
    }
    private func importPaper(_ server: LibraryModelServer, model: ReaderModel, sourceID: String = "2601.01234", revision: Int = 2) async throws -> Paper {
        await model.start()
        var row = server.pending(state: 3, sourceOnly: true)
        row["id"] = UUID().wire; row["created_seq"] = 3
        row["metadata_id"] = UUID().wire; row["version_id"] = UUID().wire
        row["source_id"] = sourceID; row["source_revision"] = revision
        row["source_url"] = "https://arxiv.org/abs/\(sourceID)v\(revision)"
        server.deliver(server.changes([row], through: 3))
        await model.refreshLibrary()
        return try XCTUnwrap(model.papers.first { $0.sourceID == sourceID })
    }
    private func importSettled(_ model: ReaderModel, paper: Paper) async throws {
        let observation = LibraryModelObservation("Native import reaches a terminal state") { !model.isPreparingOnDevice(paper) }
        observation.observe(); await fulfillment(of: [observation.ready], timeout: 60); observation.stop()
        guard !model.isPreparingOnDevice(paper) else {
            // Preserve the actual stalled stage, then stop this case. Continuing would deny the fixture replies
            // while preparation is still running and turn the original timeout into misleading offline failures.
            let progress = model.devicePreparations[paper.id].map { String($0) } ?? "none"
            XCTFail("Import still active: \(paper.sourceID), progress \(progress), \(ImportAcceptanceProtocol.requests.count) source requests")
            model.cancelDevicePreparation(paper)
            throw FixtureError.timedOut
        }
    }
    private func importOpened(_ model: ReaderModel) async throws {
        let observation = LibraryModelObservation("Native reader opens the verified bundle") {
            model.selectedPaper?.readerBundle != nil || model.readerOpenIssue != nil
        }
        observation.observe(); await fulfillment(of: [observation.ready], timeout: 60); observation.stop()
        XCTAssertNil(model.readerOpenIssue)
        XCTAssertNotNil(model.selectedPaper?.readerBundle)
    }

    func testOfflineImportDownloadsValidatesEncryptsAndReopensWithNoNetwork() async throws {
        try importNetwork(); try importReplies()
        let server = LibraryModelServer(activated: true), fixture = try fixture(server), model = fixture.model
        let paper = try await importPaper(server, model: model)
        model.prepareOnDevice(paper); model.prepareOnDevice(paper) // A repeated tap is one operation.
        try await importSettled(model, paper: paper)
        XCTAssertNil(model.devicePreparationIssues[paper.id]); XCTAssertEqual(model.deviceCopy(for: paper), .reader)
        let requested = ImportAcceptanceProtocol.requests
        XCTAssertEqual(requested.count, 11); XCTAssertEqual(Set(requested).count, 11)
        ImportAcceptanceProtocol.denyAll()
        model.select(paper); try await importOpened(model)
        let bundle = try XCTUnwrap(model.selectedPaper?.readerBundle)
        XCTAssertEqual(bundle.index.figures.count, 9)
        XCTAssertEqual(bundle.index.equations.count, 1)
        // A new store instance must recover the same verified bundle from encrypted bytes, not compiler memory.
        let reopened = try fixture.freshReaderStore()
        let records = await reopened.records(); XCTAssertEqual(records.count, 1)
        let recovered = try await reopened.read(try XCTUnwrap(records.first).identity)
        XCTAssertEqual(recovered.manifestSHA256, bundle.manifestSHA256)
        XCTAssertEqual(ImportAcceptanceProtocol.requests, requested, "reopening must work with all source requests denied")
        XCTAssertFalse(server.requestedEndpoints().contains { $0.contains("upload") || $0.contains("paper-assets") })
    }

    func testOfflineImportFailureDoesNotLoopAndExplicitRetrySucceeds() async throws {
        try importNetwork(); try importReplies(htmlStatus: 500)
        let server = LibraryModelServer(activated: true), fixture = try fixture(server), model = fixture.model
        let paper = try await importPaper(server, model: model)
        model.select(paper)
        try await observe("failed source open is visible") { model.readerOpenIssue != nil }
        XCTAssertEqual(model.readerOpenCode, "retrieval"); XCTAssertEqual(model.deviceCopy(for: paper), .cloud)
        let failed = ImportAcceptanceProtocol.requests
        await model.refreshLibrary(); await model.refreshLibrary()
        XCTAssertEqual(ImportAcceptanceProtocol.requests, failed, "sync cannot retry a failed selected paper")
        try importReplies()
        model.prepareOnDevice(paper); try await importSettled(model, paper: paper)
        XCTAssertNil(model.devicePreparationIssues[paper.id]); XCTAssertEqual(model.deviceCopy(for: paper), .reader)
        model.select(paper); try await importOpened(model)
    }

    func testOfflineImportCancellationDoesNotPublishAndCanBeRetried() async throws {
        try importNetwork(); try importReplies(delay: 1)
        let server = LibraryModelServer(activated: true), fixture = try fixture(server), model = fixture.model
        let paper = try await importPaper(server, model: model)
        model.prepareOnDevice(paper)
        try await renderReady("HTML request started") { !ImportAcceptanceProtocol.requests.isEmpty }
        model.cancelDevicePreparation(paper); try await importSettled(model, paper: paper)
        XCTAssertEqual(model.deviceCopy(for: paper), .cloud)
        let cancelledRecords = await (try fixture.freshReaderStore()).records()
        XCTAssertTrue(cancelledRecords.isEmpty)
        try importReplies()
        model.prepareOnDevice(paper); try await importSettled(model, paper: paper)
        XCTAssertNil(model.devicePreparationIssues[paper.id]); XCTAssertEqual(model.deviceCopy(for: paper), .reader)
    }

    /// A12, A13: archiving a source (arXiv metadata) paper moves it to Archived and recounts at once, while the change
    /// syncs, and sends the tags the server holds rather than the derived keywords (which would freeze them as the
    /// reader's own).
    func testArchivingASourcePaperAppliesAtOnceAndKeepsItsKeywordsDerived() async throws {
        let server = LibraryModelServer(activated: true, uploadEpoch: UUID()), f = try fixture(server), model = f.model
        model.importPollDelay = { _ in 3600 }
        await model.start()
        var row = server.pending(state: 3, sourceOnly: true)
        var metadata = try XCTUnwrap(row["metadata"] as? [String: Any])
        metadata["title"] = "Direct Preference Optimization: DPO"
        row["metadata"] = metadata; row["tags_customized"] = false
        server.deliver(server.changes([row], through: 3)); await model.refreshLibrary()
        let paper = try XCTUnwrap(model.papers.first { $0.sourceMembership != nil })
        XCTAssertFalse(LibraryTags.tags(for: paper).isEmpty, "Derived keywords show while the reader hasn't edited them")
        let before = model.libraryFilterSummary().counts
        await model.setArchived(paper, archived: true)
        XCTAssertNil(model.error)
        // The fixture's capture isn't observable: poll each frame.
        try await renderReady("source details sent") { server.commands().contains { $0.endpoint == "v5_set_source_details" } }
        XCTAssertTrue(model.isArchived(paper))
        let after = model.libraryFilterSummary().counts
        XCTAssertEqual(after[.archived, default: 0], before[.archived, default: 0] + 1, "Counted as archived while it syncs")
        XCTAssertEqual(after[.all, default: 0], before[.all, default: 0] - 1, "Hidden from All while it syncs")
        let sent = try XCTUnwrap(server.commands().last { $0.endpoint == "v5_set_source_details" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertEqual(body["p_archived"] as? Bool, true)
        XCTAssertEqual(body["p_tags"] as? [String], [], "The stored list, so the server keeps the keywords derived")
    }

    /// A4: signing out cancels the account's background downloads and clears their progress, so no row stays
    /// "Downloading…" and the next session can prepare the paper again.
    func testSignOutCancelsBackgroundPreparationAndClearsItsState() async throws {
        try importNetwork(); try importReplies(delay: 2)
        let server = LibraryModelServer(activated: true), fixture = try fixture(server), model = fixture.model
        let paper = try await importPaper(server, model: model)
        model.prepareOnDevice(paper)
        try await renderReady("HTML request started") { !ImportAcceptanceProtocol.requests.isEmpty }
        XCTAssertTrue(model.isPreparingOnDevice(paper))
        let session = model.sessionID
        await model.signOut()
        XCTAssertNotEqual(model.sessionID, session)
        XCTAssertFalse(model.isPreparingOnDevice(paper))
        // The fixture's baseline also has an accepted import of a paper already in the library: clearing the rows at
        // sign-out once started that paper's download for the old account.
        XCTAssertTrue(model.devicePreparations.isEmpty, "\(model.devicePreparations)")
        XCTAssertTrue(model.devicePreparationIssues.isEmpty, "\(model.devicePreparationIssues)")
        XCTAssertNil(model.deviceModelRun)
        XCTAssertNil(model.chatProfileTable, "The next account fetches its own profile table")
    }

    /// A7: opening a paper whose background download is under way joins it: every source is requested once, and the
    /// open shows the paper when that download installs it.
    func testOpeningAPaperJoinsItsBackgroundDownloadInsteadOfRestartingIt() async throws {
        try importNetwork(); try importReplies(delay: 1)
        let server = LibraryModelServer(activated: true), fixture = try fixture(server), model = fixture.model
        let paper = try await importPaper(server, model: model)
        model.prepareOnDevice(paper)
        try await renderReady("HTML request started") { !ImportAcceptanceProtocol.requests.isEmpty }
        model.select(paper)
        XCTAssertEqual(model.openingPaperID, paper.id)
        XCTAssertTrue(model.isPreparingOnDevice(paper), "The background download keeps going")
        try await importOpened(model)
        let requested = ImportAcceptanceProtocol.requests
        XCTAssertEqual(requested.count, 11, "One HTML page and ten images")
        XCTAssertEqual(Set(requested).count, requested.count, "No source was requested twice")
        XCTAssertEqual(model.deviceCopy(for: paper), .reader)
    }

    func testOfflineImportAbsentHTMLDownloadsAndReopensPDFWithoutUpload() async throws {
        try importNetwork(); try importReplies(htmlStatus: 404)
        let server = LibraryModelServer(activated: true), fixture = try fixture(server), model = fixture.model
        let paper = try await importPaper(server, model: model)
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 320, height: 480)).pdfData { context in
            context.beginPage(); ("Offline PDF acceptance" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
        }
        ImportAcceptanceProtocol.put("https://arxiv.org/pdf/2601.01234v2", .init(type: "application/pdf", body: pdf))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ImportAcceptanceProtocol.self]
        model.sourcePDFFetcher = DevicePDFFetcher(resolve: { _ in ["93.184.216.34"] }, configuration: configuration)
        model.select(paper)
        try await observe("Absent HTML offers the device PDF") { model.readerOpenIssue != nil }
        XCTAssertEqual(model.readerOpenCode, "no_html")
        model.openPDF(paper); model.openPDF(paper)
        try await observe("PDF is downloaded, encrypted and presented") { model.localPaperPresentation != nil || model.error != nil }
        XCTAssertNil(model.error); XCTAssertEqual(model.localPaperPresentation?.data, pdf)
        let records = await model.loadLocalPaperRecords(); XCTAssertEqual(records.count, 1)
        let reopened = try fixture.freshPaperStore()
        let recovered = try await reopened.read(try XCTUnwrap(records.first).identity)
        XCTAssertEqual(recovered, pdf)
        let requests = ImportAcceptanceProtocol.requests
        XCTAssertEqual(requests.filter { $0.contains("/pdf/") }.count, 1)
        ImportAcceptanceProtocol.denyAll(); model.localPaperPresentation = nil
        model.openPDF(paper)
        try await observe("PDF reopens offline") { model.localPaperPresentation != nil }
        XCTAssertEqual(model.localPaperPresentation?.data, pdf)
        XCTAssertEqual(ImportAcceptanceProtocol.requests, requests)
        XCTAssertFalse(server.requestedEndpoints().contains { $0.contains("upload") || $0.contains("paper-assets") })
    }

    func testOfflineReportedPaperRegressionsThroughNativeLibrary() async throws {
        struct Response: Decodable { let url: String; let status: Int; let type: String; let sha256: String; let bytes: Int }
        struct Case: Decodable { let source_id: String; let revision: Int; let kind: String; let responses: [Response]; let absent_text: [String]? }
        struct Corpus: Decodable { let cases: [Case] }
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: importRoot.appendingPathComponent("tests/corpus/import-regressions.json")))
        XCTAssertEqual(corpus.cases.count, 7, "every reported regression is required, never skipped for a missing cache")
        try importNetwork()
        let trace = FileManager.default.temporaryDirectory.appendingPathComponent("import-acceptance-\(UUID()).jsonl")
        try SessionTimeline.shared.begin(at: trace, metadata: ["fixture": "reported-paper-imports"])
        defer {
            SessionTimeline.shared.end()
            if let events = try? Data(contentsOf: trace) {
                let attachment = XCTAttachment(data: events, uniformTypeIdentifier: "public.json")
                attachment.name = "Reported-paper import timeline"; attachment.lifetime = .keepAlways; add(attachment)
                for line in String(decoding: events, as: UTF8.self).split(separator: "\n") {
                    if let data = line.data(using: .utf8),
                       let event = try? JSONDecoder().decode([String: String].self, from: data), event["kind"] == "reader" {
                        print("Offline import reader event: \(line)")
                    }
                }
            }
            try? FileManager.default.removeItem(at: trace)
        }
        for entry in corpus.cases {
            print("Offline native import starting: \(entry.source_id)v\(entry.revision) (\(entry.kind))")
            ImportAcceptanceProtocol.reset()
            var pdf: Data?
            for input in entry.responses {
                let bytes = try Data(contentsOf: importRoot.appendingPathComponent(".artifacts/import-corpus/\(input.sha256)"))
                XCTAssertEqual(bytes.count, input.bytes)
                XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), input.sha256)
                ImportAcceptanceProtocol.put(input.url, .init(status: input.status, type: input.type, body: bytes))
                if input.type == "application/pdf" { pdf = bytes }
            }
            let server = LibraryModelServer(activated: true), fixture = try fixture(server), model = fixture.model
            let paper = try await importPaper(server, model: model, sourceID: entry.source_id, revision: entry.revision)
            if entry.kind == "reader" {
                model.prepareOnDevice(paper); try await importSettled(model, paper: paper)
                if let issue = model.devicePreparationIssues[paper.id] {
                    XCTFail("\(entry.source_id): \(issue); inspect the reported-paper import timeline for its error code")
                    throw FixtureError.importFailed
                }
                XCTAssertEqual(model.deviceCopy(for: paper), .reader, entry.source_id)
                ImportAcceptanceProtocol.denyAll(); let requests = ImportAcceptanceProtocol.requests
                model.select(paper); try await importOpened(model)
                let bundle = try XCTUnwrap(model.selectedPaper?.readerBundle)
                let text = bundle.index.blocks.map(\.text).joined(separator: "\n")
                for forbidden in entry.absent_text ?? [] { XCTAssertFalse(text.contains(forbidden), "\(entry.source_id): leaked \(forbidden)") }
                XCTAssertGreaterThan(bundle.index.equations.count, 0, entry.source_id)
                XCTAssertGreaterThan(bundle.index.figures.count, 0, entry.source_id)
                let fresh = try fixture.freshReaderStore(), records = await fresh.records()
                let reopened = try await fresh.read(try XCTUnwrap(records.first).identity)
                XCTAssertEqual(reopened.manifestSHA256, bundle.manifestSHA256)
                XCTAssertEqual(ImportAcceptanceProtocol.requests, requests)
            } else {
                let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ImportAcceptanceProtocol.self]
                model.sourcePDFFetcher = DevicePDFFetcher(resolve: { _ in ["93.184.216.34"] }, configuration: configuration)
                model.select(paper)
                try await observe("Real absent-HTML paper offers PDF") { model.readerOpenIssue != nil }
                XCTAssertEqual(model.readerOpenCode, "no_html")
                model.openPDF(paper)
                try await observe("Real PDF opens locally") { model.localPaperPresentation != nil || model.error != nil }
                XCTAssertNil(model.error)
                let bytes = try XCTUnwrap(model.localPaperPresentation?.data)
                XCTAssertEqual(bytes, pdf)
                let document = try XCTUnwrap(PDFDocument(data: bytes)), page = try XCTUnwrap(document.page(at: 0))
                XCTAssertGreaterThan(document.pageCount, 0)
                XCTAssertNotNil(page.thumbnail(of: CGSize(width: 320, height: 480), for: .mediaBox).pngData())
                ImportAcceptanceProtocol.denyAll(); let requests = ImportAcceptanceProtocol.requests
                model.localPaperPresentation = nil; model.openPDF(paper)
                try await observe("Real PDF reopens offline") { model.localPaperPresentation != nil }
                XCTAssertEqual(ImportAcceptanceProtocol.requests, requests)
            }
            XCTAssertFalse(server.requestedEndpoints().contains { $0.contains("upload") || $0.contains("paper-assets") })
            print("Offline native import accepted: \(entry.source_id)v\(entry.revision) (\(entry.kind))")
            await fixture.close()
        }
    }

    func testLocalPDFFileAddsARealLibraryItemAndRejectsDamagedInput() async throws {
        try importNetwork()
        let server = LibraryModelServer(activated: true), fixture = try fixture(server), model = fixture.model
        await model.start()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("import-file-\(UUID().wire)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 320, height: 480)).pdfData { context in
            context.beginPage(); ("A PDF chosen from Files" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
        }
        let file = directory.appendingPathComponent("local-paper.pdf"); try pdf.write(to: file)
        _ = try await model.uploads.add(file: file, target: .newPaper)
        let paper = try XCTUnwrap(model.papers.first(where: \.isLocalPDF))
        XCTAssertEqual(model.papers.filter(\.isLocalPDF).count, 1)
        model.openPDF(paper)
        try await observe("Chosen PDF opens from the actual Library membership") { model.localPaperPresentation != nil }
        XCTAssertEqual(model.localPaperPresentation?.data, pdf)
        let fresh = try fixture.freshPaperStore(), records = await fresh.records()
        XCTAssertEqual(records.count, 1)
        let recovered = try await fresh.read(try XCTUnwrap(records.first).identity)
        XCTAssertEqual(recovered, pdf)
        let damaged = directory.appendingPathComponent("broken.pdf"); try Data("%PDF-1.7\ntruncated".utf8).write(to: damaged)
        do { _ = try await model.uploads.add(file: damaged, target: .newPaper); XCTFail("damaged input must not publish a membership") }
        catch { XCTAssertEqual(error as? PDFFileProblem, .unreadable) }
        XCTAssertEqual(model.papers.filter(\.isLocalPDF).count, 1)
        XCTAssertEqual(ImportAcceptanceProtocol.requests.count, 0)
        XCTAssertFalse(server.requestedEndpoints().contains { $0.contains("upload") || $0.contains("paper-assets") })
    }

    func testImportTableRowsReserveTheSameHeightBeforeMetadataAndWhileAdding() async throws {
        let server = LibraryModelServer(activated: true)
        server.metadataTitle = "Short title"
        let fixture = try fixture(server), model = fixture.model
        await model.start(); model.libraryLayout = .table
        // Search runs off the main actor. A rendered filter row does not mean the paper rows have arrived.
        await model.waitForLibrarySearch()
        let window = try window(for: model)
        func rowCells(_ view: UIView) -> [UICollectionViewCell] {
            if let list = view as? UICollectionView { return list.visibleCells }
            return view.subviews.flatMap(rowCells)
        }
        try await capture(window, name: "Library row heights while adding")
        // This fixture has exactly two papers. Their 44-point tap areas plus vertical insets are taller than
        // the filter-chip cell; SwiftUI's private section numbering differs across OS versions.
        XCTAssertEqual(model.libraryRows.count, 2)
        let cells = Array(rowCells(window).sorted { $0.bounds.height > $1.bounds.height }.prefix(2))
        XCTAssertGreaterThanOrEqual(cells.count, 2)
        let heights = cells.map { $0.bounds.height }
        print("Library ready/adding row heights: \(heights)")
        XCTAssertLessThanOrEqual((heights.max() ?? 0) - (heights.min() ?? 0), 1, "adding must not change the reserved title/author row height")
        func spinners(_ view: UIView) -> [UIActivityIndicatorView] {
            if let spinner = view as? UIActivityIndicatorView { return [spinner] }
            return view.subviews.flatMap(spinners)
        }
        let spinning = cells.flatMap { cell in spinners(cell).map { (cell, $0) } }
        XCTAssertFalse(spinning.isEmpty, "the Adding row must actually render a spinner")
        for (cell, spinner) in spinning {
            let frame = spinner.convert(spinner.bounds, to: cell)
            print("Adding spinner height \(frame.height), centre \(frame.midY), row centre \(cell.bounds.midY)")
            XCTAssertGreaterThanOrEqual(frame.height, 18)
            XCTAssertEqual(frame.midY, cell.bounds.midY, accuracy: 3, "centre the spinner in the whole row")
        }
    }

    private func capture(_ window: UIWindow, name: String) async throws {
        try await renderReady("Rendered rows for \(name)") {
            let host = window.rootViewController?.presentedViewController ?? window.rootViewController
            guard let host, host.viewIfLoaded?.window != nil, !host.isBeingPresented,
                  !host.isBeingDismissed, host.transitionCoordinator == nil else { return false }
            host.view.layoutIfNeeded()
            return Self.visibleRows(in: host.view) > 0
        }
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func visibleRows(in view: UIView) -> Int {
        if let list = view as? UICollectionView { return list.visibleCells.filter { !$0.isHidden && $0.alpha > 0 }.count }
        if let list = view as? UITableView { return list.visibleCells.filter { !$0.isHidden && $0.alpha > 0 }.count }
        return view.subviews.reduce(0) { $0 + visibleRows(in: $1) }
    }

    private func renderReady(_ description: String, _ condition: @escaping @MainActor () -> Bool) async throws {
        let observation = LibraryPresentationObservation(description, condition: condition)
        observation.start()
        await fulfillment(of: [observation.ready], timeout: 5)
        observation.stop()
        guard condition() else { throw FixtureError.timedOut }
    }

    private func waitForSheet(_ presented: Bool, in window: UIWindow) async throws {
        try await renderReady(presented ? "Sheet presentation completed" : "Sheet dismissal completed") {
            guard let controller = window.rootViewController?.presentedViewController else { return !presented }
            return presented && controller.viewIfLoaded?.window != nil && !controller.isBeingPresented
                && !controller.isBeingDismissed && controller.transitionCoordinator == nil
        }
    }

    func testImportResolutionFailureAvailabilityAndRemovalPreserveTheRightState() async throws {
        let server = LibraryModelServer(), fixture = try fixture(server)
        let model = fixture.model
        await model.start()
        XCTAssertTrue(model.libraryHasSnapshot)
        XCTAssertNil(model.libraryIssue)
        XCTAssertEqual(model.papers.map(\.id), [server.documentID], "Paper uses document identity, never membership/import identity")
        XCTAssertEqual(model.libraryImports.map(\.id), [server.importID])
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.libraryRows.count, 2)
        XCTAssertEqual(model.papers.first?.keywords, ["cs.LG", "stat.ML"])
        XCTAssertEqual(model.papers.first?.year, 2024)
        XCTAssertEqual(model.papers.first?.sourceReference, "2404.00001v1")
        model.libraryQuery = "stat.ml"
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.libraryRows.count, 1, "Public source categories participate in native search")
        model.libraryQuery = ""
        model.openSample()
        let sample = try XCTUnwrap(model.selectedPaper)
        let original = try XCTUnwrap(model.papers.first { $0.id == server.documentID })
        let cached = Paper(id: original.id, title: original.title, authors: original.authors, year: original.year,
                           abstract: original.abstract, keywords: original.keywords,
                           fileURL: URL(fileURLWithPath: "/synthetic-cache/paper.html"), artifactID: original.artifactID,
                           sourceID: original.sourceID, sourceRevision: original.sourceRevision)
        model.papers = [cached, sample]; model.select(cached)
        model.generalChat = false; model.chatInput = "Keep this private draft"
        server.deliver(Data("{}".utf8), status: 503)
        await model.refreshLibrary()
        XCTAssertNotNil(model.libraryIssue)
        XCTAssertEqual(model.libraryImports.count, 1)
        XCTAssertEqual(model.selectedPaper?.fileURL, cached.fileURL, "Failed refresh preserves the last complete presentation")

        model.libraryQuery = "2404.00001"
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.libraryRows.count, 2)
        server.deliver(server.changes([server.item(), server.pending(state: 3, resolved: true)], through: 3))
        await model.refreshLibrary()
        XCTAssertNil(model.libraryIssue)
        XCTAssertTrue(model.libraryImports.isEmpty)
        XCTAssertEqual(model.papers.filter { !$0.isSample }.map(\.id), [server.documentID], "Alias resolution produces no duplicate paper")
        XCTAssertTrue(model.papers.contains { $0.isSample })
        XCTAssertEqual(model.selectedPaper?.fileURL, cached.fileURL)
        XCTAssertEqual(model.chatInput, "Keep this private draft")
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.libraryRows.count, 1, "The same source-ID search survives import resolution")
        model.libraryQuery = "2404.00001v1"
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.libraryRows.count, 1, "An exact-version source reference is searchable")
        model.libraryQuery = ""

        model.headings = [.init(id: "paper-section", title: "Paper section")]
        server.deliver(server.changes([server.item(state: 4, available: false)], through: 4))
        await model.refreshLibrary()
        XCTAssertNil(model.libraryIssue)
        XCTAssertEqual(model.selectedPaper?.artifactID, server.artifactID, "Availability does not repin the artifact")
        XCTAssertNil(model.selectedPaper?.fileURL, "A quarantined artifact cannot stay active through its old cached URL")
        XCTAssertTrue(model.headings.isEmpty)
        XCTAssertEqual(model.chatInput, "Keep this private draft")

        server.deliver(server.changes([server.item(state: 5, visible: false, available: false)], through: 5))
        await model.refreshLibrary()
        XCTAssertNil(model.libraryIssue)
        XCTAssertNil(model.selectedPaper)
        XCTAssertEqual(model.tab, .library)
        XCTAssertEqual(model.chatPaperID, server.documentID, "Removing a library row must not silently rebind the private chat")
        XCTAssertEqual(model.chatInput, "Keep this private draft")
        XCTAssertEqual(model.papers.map(\.id), [sample.id])
    }

    func testInitialFailureCanRetryAndSourceOnlyStaysSeparateFromDocuments() async throws {
        let server = LibraryModelServer(); server.failInitial()
        let fixture = try fixture(server)
        let model = fixture.model
        await model.start()
        XCTAssertFalse(model.libraryHasSnapshot); XCTAssertNotNil(model.libraryIssue)
        XCTAssertFalse(model.libraryRefreshing); XCTAssertTrue(model.papers.isEmpty)
        server.deliver(server.changes([server.pending(state: 3, sourceOnly: true)], through: 3))
        await model.refreshLibrary()
        XCTAssertTrue(model.libraryHasSnapshot); XCTAssertNil(model.libraryIssue)
        let source = try XCTUnwrap(model.papers.first { $0.sourceMembership != nil })
        XCTAssertNil(source.artifactID)
        XCTAssertNil(source.readerBundle)
        XCTAssertTrue(source.canReadStructured)
        XCTAssertTrue(model.libraryImports.isEmpty)
        model.libraryQuery = "Ada"
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.libraryRows.count, 2, "Source-only metadata stays searchable beside the actual saved document")
        model.librarySort = .title
        await model.waitForLibrarySearch()
        XCTAssertEqual(Set(model.libraryRows.map(\.id)).count, 2, "Identical titles cannot collide across paper/import identities")
    }

    func testAddLostAcknowledgementExplicitRefreshAndCancelUseOneLibraryRow() async throws {
        let server = LibraryModelServer(activated: true), fixture = try fixture(server)
        let model = fixture.model
        // This test scripts each server command; background status polling must not interleave.
        model.importPollDelay = { _ in 3600 }
        await model.start()
        XCTAssertTrue(model.canBeginImport); XCTAssertTrue(model.draftsArePersistent)
        XCTAssertNil(model.syncIssue); XCTAssertNil(model.error)
        XCTAssertTrue(Set(server.privateRequests()).isSuperset(of: ["key_state", "pull", "ack"]))
        let window = try window(for: model)
        model.showImport = true
        try await waitForSheet(true, in: window)
        try await capture(window, name: "Add a paper — signed-in activated device")
        XCTAssertNotNil(window.rootViewController?.presentedViewController, "Capture the real sheet presentation")
        model.showImport = false
        try await waitForSheet(false, in: window)

        // This HTTP failure happens after server commit. The only valid retry
        // is the same operation and body, even after a new complete library pull.
        server.enqueueCommand(.loseAcknowledgement)
        try await model.importPaper("https://arxiv.org/abs/1706.03762v7")
        try await observe("Uncertain Add is saved on this device") {
            model.libraryCommands.first?.failure != nil && model.libraryCommandIssue != nil
        }
        let pending = try XCTUnwrap(model.libraryCommands.first)
        XCTAssertEqual(pending.mutation, .beginImport(sourceID: "1706.03762", requestedRevision: 7, observedCursor: 2))
        XCTAssertTrue(pending.everSubmitted); XCTAssertNil(pending.receipt)
        XCTAssertEqual(try fixture.savedCommandCount(), 1, "The pending row must actually exist in SQLite")
        XCTAssertEqual(model.papers.map(\.id), [server.documentID])
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.libraryRows.count, 3)
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.libraryRows.filter { $0.id == "import/\(pending.id.wire)" }.count, 1)
        try await capture(window, name: "Durable local import beside saved library after HTTP failure")
        model.showLibraryChanges = true
        try await waitForSheet(true, in: window)
        try await capture(window, name: "Pending changes — uncertain accepted import")
        XCTAssertNotNil(window.rootViewController?.presentedViewController)
        model.showLibraryChanges = false
        try await waitForSheet(false, in: window)

        let replay = expectation(description: "Explicit refresh replays Add")
        server.enqueueCommand(.hold(replay))
        await model.refreshLibrary()
        await fulfillment(of: [replay], timeout: 5)
        XCTAssertNil(model.libraryIssue)
        XCTAssertEqual(model.libraryImports.filter { $0.id == pending.id }.count, 1)
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.libraryRows.filter { $0.id == "import/\(pending.id.wire)" }.count, 1,
                       "A complete server observation replaces the local overlay before its replay response")
        await model.waitForLibrarySearch()
        XCTAssertFalse(model.libraryRows.contains { if case .queued(let value) = $0 { return value.id == pending.id }; return false })
        let attempts = server.commands()
        XCTAssertEqual(attempts.map(\.endpoint), ["v2_begin_import", "v2_begin_import"])
        XCTAssertEqual(attempts[0].body, attempts[1].body)
        server.releaseCommand()
        try await observe("Add receipt fully reconciled") { model.libraryCommands.isEmpty }
        XCTAssertEqual(try fixture.savedCommandCount(), 0)
        XCTAssertNil(model.libraryCommandIssue)
        await model.waitForLibrarySearch()
        XCTAssertEqual(Set(model.libraryRows.map(\.id)).count, model.libraryRows.count)
        try await capture(window, name: "Accepted server import without duplicate pending row")

        let imported = try XCTUnwrap(model.libraryImports.first { $0.id == pending.id })
        let cancel = expectation(description: "Cancel request issued"), catchup = expectation(description: "Cancel awaits full projection")
        server.enqueueCommand(.hold(cancel)); server.holdNextChanges(catchup)
        await model.changeImport(imported, retry: false)
        await fulfillment(of: [cancel], timeout: 5)
        XCTAssertTrue(model.libraryImports.contains { $0.id == pending.id })
        let cancellation = try XCTUnwrap(model.libraryCommands.first)
        XCTAssertEqual(cancellation.mutation, .cancelImport(importID: pending.id, expectedRevision: 1))
        server.releaseCommand()
        await fulfillment(of: [catchup], timeout: 5)
        try await observe("Cancel receipt is durable") { model.libraryCommands.first?.phase == .receiptAwaitingCatchup }
        XCTAssertTrue(model.libraryImports.contains { $0.id == pending.id }, "Receipt alone cannot replace a complete library")
        server.releaseChanges()
        try await observe("Cancelled import removed by complete projection") {
            model.libraryCommands.isEmpty && !model.libraryImports.contains { $0.id == pending.id }
        }
        XCTAssertEqual(model.papers.map(\.id), [server.documentID])
        XCTAssertEqual(model.libraryImports.map(\.id), [server.importID])
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.libraryRows.count, 2)
        XCTAssertEqual(server.commands().map(\.endpoint), ["v2_begin_import", "v2_begin_import", "v2_cancel_import"])
        XCTAssertNil(model.error)
        try await capture(window, name: "Cancelled import leaves the existing library intact")
    }

    /// Tags (migration 030): catalog tags arrive with the entry; an edit shows at once, is sent as the reader's own
    /// and hidden lists at the observed revision, and the synced entry keeps showing the same tags.
    func testTagEditsShowAtOnceAndSyncAsOwnAndHiddenLists() async throws {
        let server = LibraryModelServer(activated: true)
        server.catalogTags = ["Machine learning", "Transformers"]
        let fixture = try fixture(server), model = fixture.model
        await model.start()
        let paper = try XCTUnwrap(model.papers.first)
        XCTAssertEqual(paper.tags, ["Machine learning", "Transformers"])
        XCTAssertEqual(paper.catalogTags, ["Machine learning", "Transformers"])
        let issued = expectation(description: "Tag edit issued")
        server.enqueueCommand(.hold(issued))
        let problem = await model.saveTags(["Transformers", "Reading  group "], for: paper)
        XCTAssertNil(problem)
        XCTAssertEqual(model.papers.first?.tags, ["Transformers", "Reading group"], "Shown before the server confirms")
        await fulfillment(of: [issued], timeout: 5)
        let command = try XCTUnwrap(server.commands().last)
        XCTAssertEqual(command.endpoint, "v2_set_item_tags")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: command.body) as? [String: Any])
        XCTAssertEqual(body["p_tags"] as? [String], ["Reading group"])
        XCTAssertEqual(body["p_hidden_tags"] as? [String], ["Machine learning"])
        XCTAssertEqual(body["p_expected_revision"] as? Int, 1)
        server.releaseCommand()
        try await observe("Tag edit synced") { model.libraryCommands.isEmpty && model.papers.first?.ownTags == ["Reading group"] }
        XCTAssertEqual(model.papers.first?.tags, ["Transformers", "Reading group"])
        XCTAssertEqual(model.papers.first?.hiddenTags, ["Machine learning"])
        XCTAssertEqual(model.ownTagsInLibrary(excluding: UUID()), ["Reading group"])
        // A sample or a paper outside the library is never edited.
        let outside = await model.saveTags(["X"], for: Paper(id: UUID(), title: "Elsewhere", authors: "", year: nil, abstract: "",
                                                             keywords: [], fileURL: nil, artifactID: nil))
        XCTAssertNotNil(outside)
        XCTAssertNil(model.error)
    }

    /// Owner feedback 2026-10-07: a failed import offers Retry, and a retried row shows as downloading again at once —
    /// while the request is still on its way — then follows the server's own state.
    func testRetryShowsTheFailedImportDownloadingAtOnce() async throws {
        let server = LibraryModelServer(activated: true, pendingFailed: true), fixture = try fixture(server)
        let model = fixture.model
        model.importPollDelay = { _ in 3600 }
        await model.start()
        XCTAssertTrue(model.canChangeImports)
        let failed = try XCTUnwrap(model.libraryImports.first { $0.id == server.importID })
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(model.libraryStatus(for: .pending(failed)), .problem("Download failed"), "Plain words")
        XCTAssertEqual(model.libraryFacts(for: .pending(failed)).importAction, .retry, "Retry beside the status")

        let arrival = expectation(description: "Retry request issued")
        server.enqueueCommand(.hold(arrival))
        await model.changeImport(failed, retry: true)
        try await observe("Retry saved on this device") { model.isRetrying(failed) }
        XCTAssertEqual(model.libraryStatus(for: .pending(failed)), .active("Downloading…"), "Running again before the server answers")
        let facts = model.libraryFacts(for: .pending(failed))
        XCTAssertEqual(facts.step, .downloading)
        XCTAssertNil(facts.importAction, "No second Retry while one is on its way")
        await fulfillment(of: [arrival], timeout: 5)
        XCTAssertEqual(server.commands().map(\.endpoint), ["v2_retry_import"])

        server.releaseCommand()
        try await observe("The server's state replaces the local one") {
            model.libraryCommands.isEmpty && model.libraryImports.first { $0.id == server.importID }?.phase == .acquiring
        }
        let resumed = try XCTUnwrap(model.libraryImports.first { $0.id == server.importID })
        XCTAssertFalse(model.isRetrying(resumed))
        XCTAssertEqual(model.libraryFacts(for: .pending(resumed)).step, .preparing, "Acquiring, before the worker reports downloading")
        XCTAssertNil(model.error)
    }

    func testRemoveSavedPaperWaitsForCatchupAndKeepsPrivateChatAndDraft() async throws {
        let server = LibraryModelServer(activated: true), fixture = try fixture(server)
        let model = fixture.model
        await model.start()
        XCTAssertTrue(model.canChangeLibrary)
        let paper = try XCTUnwrap(model.papers.first)
        model.select(paper); model.generalChat = false
        model.chatInput = "What survives when this paper leaves my library?"
        await model.sendMessage()
        await model.synchronize()
        XCTAssertNil(model.error); XCTAssertNil(model.syncIssue)
        let conversation = try XCTUnwrap(model.activeConversation)
        XCTAssertEqual(model.chatMessages.map { $0.payload.text }, ["What survives when this paper leaves my library?"])
        model.chatInput = "Keep this unfinished follow-up"
        await model.flushDrafts()
        XCTAssertEqual(model.chatDraftStatus, .saved)
        let composer = model.chatComposerID
        let issued = expectation(description: "Remove issued"), catchup = expectation(description: "Remove receipt awaits full projection")
        server.enqueueCommand(.hold(issued)); server.holdNextChanges(catchup)
        await model.removePaper(paper)
        await fulfillment(of: [issued], timeout: 5)
        let command = try XCTUnwrap(model.libraryCommands.first)
        XCTAssertEqual(command.mutation, .setMembership(documentID: server.documentID, present: false,
            expectedRevision: 1, approvalID: server.approvalID))
        XCTAssertEqual(model.selectedPaper?.id, server.documentID)
        XCTAssertEqual(model.papers.map(\.id), [server.documentID])
        XCTAssertEqual(model.chatInput, "Keep this unfinished follow-up")
        server.releaseCommand()
        await fulfillment(of: [catchup], timeout: 5)
        try await observe("Remove receipt saved before projection") { model.libraryCommands.first?.phase == .receiptAwaitingCatchup }
        XCTAssertEqual(model.selectedPaper?.id, server.documentID)
        XCTAssertEqual(model.activeConversation, conversation)
        XCTAssertEqual(model.chatComposerID, composer)
        XCTAssertEqual(model.chatInput, "Keep this unfinished follow-up")
        server.releaseChanges()
        try await observe("Removal published after complete catchup") { model.libraryCommands.isEmpty && model.papers.isEmpty }
        XCTAssertNil(model.selectedPaper); XCTAssertEqual(model.tab, .library)
        XCTAssertEqual(model.chatPaperID, server.documentID)
        XCTAssertEqual(model.activeConversation, conversation); XCTAssertEqual(model.chatComposerID, composer)
        XCTAssertEqual(model.chatInput, "Keep this unfinished follow-up")
        XCTAssertEqual(model.chatMessages.map { $0.payload.text }, ["What survives when this paper leaves my library?"])
        XCTAssertFalse(model.chatWasDeleted)
        XCTAssertEqual(model.chatDraftStatus, .saved)
        XCTAssertEqual(try fixture.savedCommandCount(), 0)
        XCTAssertEqual(server.commands().map(\.endpoint), ["v2_set_library_item"])
        XCTAssertNil(model.error)
    }

    // MARK: Upload-capable (v5) library, migration 042 (owner feedback, build 17: "The Add is all greyed out?")

    private func feedResult(_ sourceID: String) throws -> DiscoveryResult {
        try JSONDecoder().decode(DiscoveryResult.self, from: Data("""
            {"source_id":"\(sourceID)","revision":1,"title":"Sparse Mixture-of-Experts Scaling","authors":["Mei Lin"],
             "year":2026,"abstract":null,"categories":["cs.LG"]}
            """.utf8))
    }

    func testFeedAddWorksUnderTheUploadCapableLibraryAndShowsTheImport() async throws {
        let epoch = UUID(), server = LibraryModelServer(activated: true, uploadEpoch: epoch), fixture = try fixture(server)
        let model = fixture.model
        model.importPollDelay = { _ in 3600 }
        await model.start()
        XCTAssertTrue(server.pages().contains { $0.endpoint == "v5_library_changes" && $0.epoch == epoch.wire },
                      "The fixture library is read through the v5 protocol")
        XCTAssertTrue(model.canChangeLibrary, "Library writes are available once v5 is adopted")
        XCTAssertTrue(model.canBeginImport, "Feed Add is enabled under v5")
        let result = try feedResult("2610.01234")
        XCTAssertFalse(model.librarySourceIDs.contains(result.sourceID))
        try await model.addDiscovered(result)
        try await observe("The Feed's paper is in the library after catch-up") {
            model.libraryCommands.isEmpty && model.libraryImports.contains { $0.sourceID == "2610.01234" }
        }
        XCTAssertTrue(model.librarySourceIDs.contains(result.sourceID), "The Feed row now shows In library")
        let sent = server.commands()
        XCTAssertEqual(sent.map(\.endpoint), ["v5_begin_import"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(sent.first).body) as? [String: Any])
        XCTAssertEqual(body["p_dataset_epoch"] as? String, epoch.wire)
        XCTAssertEqual(body["p_source_id"] as? String, "2610.01234")
        XCTAssertNil(model.libraryCommandIssue); XCTAssertNil(model.error)
        // Other library writes follow the same family: Remove of the saved paper.
        let paper = try XCTUnwrap(model.papers.first { $0.id == server.documentID })
        await model.removePaper(paper)
        try await observe("Remove reconciled") { model.libraryCommands.isEmpty && !model.papers.contains { $0.id == server.documentID } }
        XCTAssertEqual(server.commands().map(\.endpoint), ["v5_begin_import", "v5_set_library_item"])
    }

    func testRestoredDatasetSetsTheChangeAsideAndRefreshesTheLibrary() async throws {
        let server = LibraryModelServer(activated: true, uploadEpoch: UUID()), fixture = try fixture(server)
        let model = fixture.model
        model.importPollDelay = { _ in 3600 }
        await model.start()
        XCTAssertTrue(model.canBeginImport)
        // A restore rotates the dataset; the drain's capability read races it and still sees the old epoch,
        // so only the server's in-transaction check can refuse the old preconditions.
        server.rotateEpoch(stale: 1)
        let rotated = try XCTUnwrap(server.currentEpoch)
        try await model.importPaper("2404.00002")
        try await observe("The refused change is kept for review") {
            model.libraryCommands.first?.phase == .needsReview && model.libraryCommandIssue != nil
        }
        let kept = try XCTUnwrap(model.libraryCommands.first)
        XCTAssertEqual(model.libraryCommands.count, 1, "Never silently dropped")
        XCTAssertEqual(kept.failure, .datasetChanged); XCTAssertFalse(kept.canAttempt)
        XCTAssertEqual(kept.mutation, .beginImport(sourceID: "2404.00002", requestedRevision: nil, observedCursor: 2))
        XCTAssertEqual(model.libraryCommandIssue, "Your library was updated on the server. Review your saved change before trying it again.")
        XCTAssertEqual(server.commands().map(\.endpoint), ["v5_begin_import"])
        // Server-side evidence is not observable model state: poll it, bounded.
        var refreshed = false
        for _ in 0..<50 where !refreshed {
            refreshed = server.pages().last.map { $0.endpoint == "v5_library_changes" && $0.epoch == rotated.wire } ?? false
            if !refreshed { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertTrue(refreshed, "A fresh baseline in the restored dataset")
        XCTAssertEqual(try fixture.savedCommandCount(), 1)
        // The reader can repeat the action from the fresh observation; it is a new operation in the new dataset.
        var accepted = false
        for _ in 0..<50 where !accepted {
            do { try await model.importPaper("2404.00002"); accepted = true }
            catch LibraryCommandError.contextMismatch { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertTrue(accepted)
        try await observe("The repeated Add is reconciled") {
            model.libraryImports.contains { $0.sourceID == "2404.00002" } && !model.libraryCommands.contains { $0.isUnfinished }
        }
        let repeated = try XCTUnwrap(server.commands().last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: repeated.body) as? [String: Any])
        XCTAssertEqual(body["p_dataset_epoch"] as? String, rotated.wire)
        XCTAssertNotEqual(body["p_operation_id"] as? String, kept.id.wire)
        XCTAssertEqual(model.libraryCommands.map(\.id), [kept.id], "The refused change stays for review until dismissed")
    }

    func testV5RetryCancelTagsArchiveAndRemoveUseCurrentObservedRevisions() async throws {
        let epoch = UUID(), server = LibraryModelServer(activated: true, pendingFailed: true, uploadEpoch: epoch)
        server.catalogTags = ["Machine learning", "Transformers"]
        let f = try fixture(server), model = f.model
        model.importPollDelay = { _ in 3600 }
        await model.start()
        let failed = try XCTUnwrap(model.libraryImports.first { $0.id == server.importID })
        await model.changeImport(failed, retry: true)
        try await observe("v5 Retry catches up") {
            model.libraryCommands.isEmpty && model.libraryImports.first { $0.id == server.importID }?.phase == .acquiring
        }
        let retried = try XCTUnwrap(model.libraryImports.first { $0.id == server.importID })
        await model.changeImport(retried, retry: false)
        try await observe("v5 Cancel catches up") {
            model.libraryCommands.isEmpty && !model.libraryImports.contains { $0.id == server.importID }
        }

        var paper = try XCTUnwrap(model.papers.first { $0.id == server.documentID })
        let tagProblem = await model.saveTags(["Transformers", "Reading group"], for: paper)
        XCTAssertNil(tagProblem)
        try await observe("v5 tags catch up") {
            model.libraryCommands.isEmpty && model.papers.first?.ownTags == ["Reading group"]
        }
        paper = try XCTUnwrap(model.papers.first { $0.id == server.documentID })
        await model.setArchived(paper, archived: true)
        try await observe("v5 archive catches up") { model.libraryCommands.isEmpty && model.papers.first?.archived == true }
        paper = try XCTUnwrap(model.papers.first { $0.id == server.documentID })
        XCTAssertEqual(paper.tags, ["Transformers", "Reading group"], "Archiving retains the synced tag edit")
        await model.setArchived(paper, archived: false)
        try await observe("v5 unarchive catches up") { model.libraryCommands.isEmpty && model.papers.first?.archived == false }
        await model.removePaper(try XCTUnwrap(model.papers.first { $0.id == server.documentID }))
        try await observe("v5 Remove catches up after other item changes") {
            model.libraryCommands.isEmpty && !model.papers.contains { $0.id == server.documentID }
        }
        let sent = server.commands()
        XCTAssertEqual(sent.map(\.endpoint), ["v5_retry_import", "v5_cancel_import", "v5_set_item_tags",
                                               "v5_set_item_archived", "v5_set_item_archived", "v5_set_library_item"])
        let bodies = try sent.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0.body) as? [String: Any]) }
        XCTAssertEqual(bodies.map { $0["p_expected_revision"] as? Int }, [1, 2, 1, 2, 3, 4])
        XCTAssertTrue(bodies.allSatisfy { $0["p_dataset_epoch"] as? String == epoch.wire })
        XCTAssertNil(model.error); XCTAssertNil(model.libraryCommandIssue)
        XCTAssertEqual(try f.savedCommandCount(), 0)
    }

    func testMissingV5CommandsPreserveTheRequestAndNeverFallBackToV2() async throws {
        let epoch = UUID(), server = LibraryModelServer(activated: true, uploadEpoch: epoch), f = try fixture(server)
        server.setV5CommandsAvailable(false)
        let model = f.model
        model.importPollDelay = { _ in 3600 }
        await model.start()
        try await model.importPaper("2610.01234")
        try await observe("A missing command endpoint keeps the saved request") {
            model.libraryCommands.first?.failure == .connection && model.libraryCommandIssue != nil
        }
        let pending = try XCTUnwrap(model.libraryCommands.first), initial = try XCTUnwrap(server.commands().first)
        XCTAssertEqual(pending.phase, .submittedUnknown)
        XCTAssertEqual(initial.endpoint, "v5_begin_import")
        XCTAssertEqual(pending.request?.body, initial.body)
        XCTAssertFalse(model.libraryImports.contains { $0.sourceID == "2610.01234" })
        // Model the additive migration becoming available, then the user's explicit Refresh.
        server.setV5CommandsAvailable(true)
        await model.refreshLibrary()
        try await observe("The exact saved request succeeds once the v5 endpoint is available") {
            model.libraryCommands.isEmpty && model.libraryImports.contains { $0.sourceID == "2610.01234" }
        }
        let attempts = server.commands()
        XCTAssertEqual(attempts.map(\.endpoint), ["v5_begin_import", "v5_begin_import"])
        XCTAssertEqual(attempts[0].body, attempts[1].body)
        XCTAssertNil(model.error); XCTAssertNil(model.libraryCommandIssue)
    }

    @MainActor private final class Fixture {
        private var ownedModel: ReaderModel?
        var model: ReaderModel { ownedModel! }
        let environment: String
        let host: String
        let account: UUID
        private let server: LibraryModelServer
        private let root: URL
        init(_ server: LibraryModelServer) throws {
            self.server = server
            environment = "library-model-\(UUID().wire)"
            host = environment + ".invalid"
            account = server.account
            StubProtocol.install(host: host) { server.handle($0) }
            let session = AuthSession(access_token: "fixture-library-model", refresh_token: "fixture-refresh",
                                      expires_at: Date().timeIntervalSince1970 + 3600, user: .init(id: account, email: "fixture@example.invalid"))
            try KeychainVault.write(ReaderCrypto.encode(session), name: environment + ".auth-session")
            if let device = server.device {
                try server.installDeviceEnvelope()
                try KeychainVault.write(ReaderCrypto.encode(device), name: "\(environment).\(account.wire).device-keys")
            }
            root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true).appendingPathComponent(environment)
            let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = [StubProtocol.self]
            let configuration = BackendConfiguration(url: URL(string: "https://\(host)")!, anonKey: "fixture", environment: environment)
            ownedModel = ReaderModel(configuration: configuration, client: try BackendClient(configuration: configuration, network: URLSession(configuration: settings)))
        }
        func relaunch() async throws {
            await retireModel()
            let session = AuthSession(access_token: "fixture-library-model", refresh_token: "fixture-refresh",
                expires_at: Date().timeIntervalSince1970 + 3600, user: .init(id: account, email: "fixture@example.invalid"))
            try KeychainVault.write(ReaderCrypto.encode(session), name: environment + ".auth-session")
            if let device = server.device { try KeychainVault.write(ReaderCrypto.encode(device), name: "\(environment).\(account.wire).device-keys") }
            let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = [StubProtocol.self]
            let configuration = BackendConfiguration(url: URL(string: "https://\(host)")!, anonKey: "fixture", environment: environment)
            ownedModel = ReaderModel(configuration: configuration, client: try BackendClient(configuration: configuration, network: URLSession(configuration: settings)))
            await model.start()
        }
        func savedCommandCount() throws -> Int {
            var database: OpaquePointer?, statement: OpaquePointer?
            let url = root.appendingPathComponent(account.wire).appendingPathComponent("private-state.enc")
            let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
            defer { sqlite3_finalize(statement); sqlite3_close(database) }
            guard opened == SQLITE_OK else { throw FixtureError.sqlite(opened) }
            let prepared = sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM local_library_commands", -1, &statement, nil)
            guard prepared == SQLITE_OK else { throw FixtureError.sqlite(prepared) }
            let step = sqlite3_step(statement)
            guard step == SQLITE_ROW else { throw FixtureError.sqlite(step) }
            return Int(sqlite3_column_int(statement, 0))
        }
        func freshReaderStore() throws -> DeviceReaderStore {
            try DeviceReaderStore(directory: root.appendingPathComponent(account.wire).appendingPathComponent("device-readers"),
                                 accountID: account, localKey: XCTUnwrap(server.device).localStoreKey)
        }
        func freshPaperStore() throws -> DevicePaperStore {
            try DevicePaperStore(directory: root.appendingPathComponent(account.wire).appendingPathComponent("device-papers"),
                                accountID: account, localKey: XCTUnwrap(server.device).localStoreKey)
        }
        private func retireModel() async {
            if let model = ownedModel {
                await model.flushDrafts()
                await model.signOut()
                await model.waitForLocalRetirement()
            }
            ownedModel = nil
        }
        func close() async {
            server.releaseAll()
            await retireModel()
            StubProtocol.remove(host: host)
            for key in [environment + ".auth-session", "\(environment).\(account.wire).device-keys", "\(environment).\(account.wire).support-outbox-key"] {
                try? KeychainVault.delete(key)
            }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
