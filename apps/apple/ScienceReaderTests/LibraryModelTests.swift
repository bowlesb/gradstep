import CryptoKit
import Foundation
import Observation
import ScienceReaderCore
import SQLite3
import SwiftUI
import XCTest
@testable import ScienceReader

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
    /// The catalog's topic tags on the item entry (migration 030); none by default (no `tags` key).
    var catalogTags: [String] = []

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
                guard let id = input["p_import_id"] as? String, var row = changedEntries[id],
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
        ["title": "A paper about equation handling", "authors": ["Ada Researcher"], "abstract": "A bounded test of library transitions.",
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
        bytes(["format": 2, "account_id": account.wire, "through": through, "retained_after": 0,
               "changes": rows.isEmpty ? [] : [["seq": through, "entries": rows]], "next_cursor": through, "has_more": false])
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
    private enum FixtureError: Error { case timedOut, sqlite(Int32) }

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
