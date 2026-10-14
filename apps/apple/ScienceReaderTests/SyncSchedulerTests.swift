import CryptoKit
import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// An activated account with cached device keys, an empty legacy (v3) library and an empty encrypted history.
/// Any RPC can be made to fail with a status and body; requests are counted by RPC name.
private final class SyncSchedulerServer: @unchecked Sendable {
    let account = UUID()
    let device: LocalDevice
    private let lock = NSLock()
    private let keyState: Data
    private var failures: [String: (status: Int, body: Data)] = [:]
    private var pullRows: [[String: Any]] = []
    private var calls: [String] = []

    init() throws {
        var device = LocalDevice.create(accountID: account)
        let bundle = KeyBundle.generate(accountID: account)
        device.bundle = bundle
        self.device = device
        let publicKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: device.privateKey).publicKey.rawRepresentation
        let envelope = try ReaderCrypto.wrapForDevice(bundle, deviceID: device.deviceID, recipientPublicKey: publicKey, challenge: device.challenge)
        keyState = try JSONSerialization.data(withJSONObject: ["epoch": bundle.epoch, "recovery_package": "\\x", "device_envelope": DeviceKeys.hex(envelope)])
    }

    func fail(_ rpc: String, status: Int, code: String? = nil) {
        let body = code.map { Data(#"{"code":"P0001","message":"\#($0)"}"#.utf8) } ?? Data("{}".utf8)
        lock.withLock { failures[rpc] = (status, body) }
    }
    func recover(_ rpc: String) { _ = lock.withLock { failures.removeValue(forKey: rpc) } }
    func count(_ rpc: String) -> Int { lock.withLock { calls.filter { $0 == rpc }.count } }
    /// One remote entry whose ciphertext no key can open (its digest is honest, so only decryption fails).
    func serveUnreadableEntry() {
        let bytes = ReaderCrypto.randomKey() + ReaderCrypto.randomKey()
        let row: [String: Any] = ["id": UUID().wire, "device_id": UUID().wire, "cursor": 1, "epoch": 1, "format": 1,
                                  "ciphertext": DeviceKeys.hex(bytes), "ciphertext_sha256": DeviceKeys.hex(Data(SHA256.hash(data: bytes)))]
        lock.withLock { pullRows = [row] }
    }

    func handle(_ request: StubProtocol) {
        lock.withLock {
            let name = request.request.url!.lastPathComponent
            calls.append(name)
            if let failure = failures[name] { request.respond(failure.body, status: failure.status); return }
            switch name {
            case "v1_key_state": request.respond(keyState)
            case "v1_reader_capabilities":
                request.respond(Data(#"{"code":"PGRST202","message":"Could not find the function public.v1_reader_capabilities without parameters in the schema cache"}"#.utf8), status: 404)
            case "v3_library_page":
                request.respond(json(["format": 2, "account_id": account.wire, "baseline_cursor": 0, "retained_after": 0,
                                      "entries": [], "next_cursor": NSNull(), "has_more": false]))
            case "v3_library_changes":
                request.respond(json(["format": 2, "account_id": account.wire, "through": 0, "retained_after": 0,
                                      "changes": [], "next_cursor": 0, "has_more": false]))
            case "v3_pull_events":
                let after = fields(request.request)["p_after"] as? Int ?? 0
                let rows = pullRows.filter { ($0["cursor"] as? Int ?? 0) > after }
                request.respond(json(["events": rows, "next_cursor": rows.last?["cursor"] ?? after, "has_more": false]))
            case "v1_acknowledge_cursor": request.respond(Data(), status: 204)
            case "logout": request.respond(Data("{}".utf8))
            default: request.respond(Data("[]".utf8))
            }
        }
    }
    private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func fields(_ request: URLRequest) -> [String: Any] {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
    }
}

/// The failure counts the model asked a delay for, in order.
private final class DelayLog: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [Int] = []
    func record(_ failures: Int) { lock.withLock { asked.append(failures) } }
    var values: [Int] { lock.withLock { asked } }
}

@MainActor
private final class SyncSchedulerFixture {
    let server: SyncSchedulerServer
    let model: ReaderModel
    private let environment: String, host: String, root: URL

    init(_ server: SyncSchedulerServer) throws {
        self.server = server
        environment = "sync-scheduler-\(UUID().wire)"; host = environment + ".invalid"
        StubProtocol.install(host: host) { server.handle($0) }
        let session = AuthSession(access_token: "fixture-sync-scheduler", refresh_token: "fixture-refresh",
                                  expires_at: Date().timeIntervalSince1970 + 3600, user: .init(id: server.account, email: "fixture@example.invalid"))
        try KeychainVault.write(ReaderCrypto.encode(session), name: environment + ".auth-session")
        try KeychainVault.write(ReaderCrypto.encode(server.device), name: "\(environment).\(server.account.wire).device-keys")
        root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(environment)
        let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = [StubProtocol.self]
        let configuration = BackendConfiguration(url: URL(string: "https://\(host)")!, anonKey: "fixture", environment: environment)
        model = ReaderModel(configuration: configuration,
                            client: try BackendClient(configuration: configuration, network: URLSession(configuration: settings)))
    }

    func close() async {
        model.sceneActive = false
        await model.flushDrafts()
        await model.signOut()
        await model.waitForLocalRetirement()
        StubProtocol.remove(host: host)
        for key in [environment + ".auth-session", "\(environment).\(server.account.wire).device-keys",
                    "\(environment).\(server.account.wire).support-outbox-key"] { try? KeychainVault.delete(key) }
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
final class SyncSchedulerTests: XCTestCase {
    private enum Failure: Error { case timedOut(String) }
    private static let updateCopy = "Update Gradstep to keep syncing this history. Everything on this device stays available."

    private func fixture() async throws -> SyncSchedulerFixture {
        let fixture = try SyncSchedulerFixture(try SyncSchedulerServer())
        addTeardownBlock { await fixture.close() }
        return fixture
    }

    /// Server counters aren't observable, so conditions are polled.
    private func waitUntil(_ description: String, timeout: Duration = .seconds(5), until condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.timedOut(description) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    func testScheduledSyncRunsOnTheIntervalBacksOffAfterFailuresAndStopsWhenInactive() async throws {
        let fixture = try await fixture(), model = fixture.model, server = fixture.server
        let delays = DelayLog()
        model.syncScheduleDelay = { failures in delays.record(failures); return .milliseconds(failures == 0 ? 60 : 120) }
        await model.start()
        XCTAssertEqual(model.syncStatus, "Synced")
        XCTAssertFalse(model.isSyncScheduled, "Nothing is scheduled until the scene is active")
        let pullsAfterStart = server.count("v3_pull_events")

        model.sceneActive = true
        XCTAssertTrue(model.isSyncScheduled)
        // Each sync pulls twice (before and after push); two ticks show the interval repeats.
        try await waitUntil("Scheduled syncs pull on the interval") { server.count("v3_pull_events") >= pullsAfterStart + 4 && model.syncStatus == "Synced" }
        XCTAssertEqual(model.syncStatus, "Synced"); XCTAssertNil(model.syncIssue)
        XCTAssertTrue(delays.values.allSatisfy { $0 == 0 }, "A healthy schedule asks for the base interval")

        server.fail("v3_pull_events", status: 503)
        try await waitUntil("A failed scheduled sync pauses sync") { model.syncIssue != nil }
        XCTAssertEqual(model.syncStatus, "Saved on this device · Sync paused")
        try await waitUntil("Back-off grows with consecutive failures") { delays.values.contains(3) }
        let afterFailure = delays.values.drop(while: { $0 == 0 })
        XCTAssertEqual(Array(afterFailure.prefix(3)), [1, 2, 3], "Each failure asks for the next back-off step")
        XCTAssertTrue(model.isSyncScheduled, "Failures keep the schedule alive")

        server.recover("v3_pull_events")
        try await waitUntil("A later scheduled sync recovers") { model.syncIssue == nil && model.syncStatus == "Synced" }
        try await waitUntil("Recovery returns to the base interval") { delays.values.last == 0 }

        model.sceneActive = false
        XCTAssertFalse(model.isSyncScheduled, "Leaving the foreground stops the schedule")
        try await Task.sleep(for: .milliseconds(300)) // A tick already past its guard finishes.
        let pullsAfterStop = server.count("v3_pull_events")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(server.count("v3_pull_events"), pullsAfterStop, "No sync runs while the scene is inactive")

        model.sceneActive = true
        XCTAssertTrue(model.isSyncScheduled, "Returning to the foreground resumes the schedule")
        try await waitUntil("The resumed schedule syncs again") { server.count("v3_pull_events") > pullsAfterStop }
    }

    func testScheduleEndsWithSignOut() async throws {
        let fixture = try await fixture(), model = fixture.model
        model.syncScheduleDelay = { _ in .milliseconds(50) }
        await model.start()
        model.sceneActive = true
        XCTAssertTrue(model.isSyncScheduled)
        await model.signOut()
        XCTAssertFalse(model.isSyncScheduled)
        XCTAssertEqual(model.syncStatus, "On this device")
    }

    func testFailedCursorAcknowledgementIsNotASyncFailure() async throws {
        let fixture = try await fixture(), model = fixture.model, server = fixture.server
        server.fail("v1_acknowledge_cursor", status: 503)
        await model.start()
        XCTAssertGreaterThanOrEqual(server.count("v1_acknowledge_cursor"), 1)
        XCTAssertEqual(model.syncStatus, "Synced", "The pull completed; retention trimming can wait")
        XCTAssertNil(model.syncIssue)
        server.recover("v1_acknowledge_cursor")
        let acknowledgements = server.count("v1_acknowledge_cursor")
        await model.synchronize()
        XCTAssertEqual(model.syncStatus, "Synced")
        XCTAssertGreaterThan(server.count("v1_acknowledge_cursor"), acknowledgements, "The cursor is sent again next sync")
    }

    func testServerUpdateRequirementUsesTheUpdateCopy() async throws {
        let fixture = try await fixture(), model = fixture.model, server = fixture.server
        server.fail("v3_pull_events", status: 400, code: "reader_update_required")
        await model.start()
        XCTAssertEqual(model.syncStatus, "Saved on this device · Sync paused")
        XCTAssertEqual(model.syncIssue, Self.updateCopy)
    }

    func testUnreadableEntryIsNamedInsteadOfAGenericFailure() async throws {
        let fixture = try await fixture(), model = fixture.model, server = fixture.server
        server.serveUnreadableEntry()
        await model.start()
        XCTAssertEqual(model.syncStatus, "Saved on this device · Sync paused")
        XCTAssertEqual(model.syncIssue, ReaderError.invalidEvent.errorDescription)
        XCTAssertFalse(model.syncIssue?.contains("could not finish") ?? true)
    }

    func testSyncCopyAndTimelineCodesNeverCarryServerText() {
        XCTAssertEqual(BackendError.rejected("reader_update_required").errorDescription, Self.updateCopy)
        XCTAssertEqual(BackendError.rejected("sync_page_too_large").errorDescription, Self.updateCopy)
        XCTAssertEqual(ReaderError.unsupportedFormat.errorDescription, Self.updateCopy)
        XCTAssertEqual(ReaderError.invalidEvent.errorDescription,
                       "Sync stopped at an entry this device can’t read. Everything on this device stays available; send a report so it can be fixed.")
        XCTAssertEqual(BackendError.rejected("private-server-detail").errorDescription,
                       "The server could not complete this request. Please try again.")
        XCTAssertEqual(SyncFailure.code(ReaderError.invalidEvent), "reader_invalidEvent")
        XCTAssertEqual(SyncFailure.code(ReaderError.unsupportedFormat), "reader_unsupportedFormat")
        XCTAssertEqual(SyncFailure.code(BackendError.rejected("reader_update_required")), "reader_update_required")
        XCTAssertEqual(SyncFailure.code(BackendError.transport), "transport")
        XCTAssertEqual(SyncFailure.code(URLError(.notConnectedToInternet)), "url_-1009")
        XCTAssertEqual(SyncFailure.code(CancellationError()), "cancelled")
    }
}
