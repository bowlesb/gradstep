import CryptoKit
import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// Deterministic network schedules exercise real Keychain persistence and
/// CryptoKit recipient envelopes, including a delayed older approval winning.
private final class EnrollmentServer: @unchecked Sendable {
    enum Mode { case expired, lateApproval, rotated, revoked, suspended }
    struct Request: Codable {
        let p_request_id: UUID
        let p_device_id: UUID
        let p_public_key: String
        let p_challenge: String
    }
    struct Pending: Codable {
        let requestID: UUID
        let candidate: LocalDevice
        let envelope: Data
        let createdAt: Date
    }
    private let lock = NSLock()
    let mode: Mode
    let original: LocalDevice
    let pending: Pending
    let keys: KeyBundle
    let code = ReaderCrypto.recoveryCode()
    private let recovery: String
    private var requests: [UUID: Request] = [:]
    private var active: Set<UUID> = []
    private var envelopes: [UUID: String] = [:]
    private var calls: [Request] = []
    private var held: StubProtocol?
    private var holdFirstState = true
    let arrived = XCTestExpectation(description: "key-state request suspended")

    init(mode: Mode, createdAt: Date = Date()) throws {
        self.mode = mode
        original = LocalDevice.create(accountID: UUID())
        var candidate = LocalDevice.create(accountID: original.accountID, localStoreKey: original.localStoreKey)
        candidate.bundle = KeyBundle.generate(accountID: original.accountID)
        var current = candidate.bundle!
        if mode == .rotated || mode == .revoked { try current.rotate() }
        keys = current
        recovery = DeviceKeys.hex(try ReaderCrypto.wrapRecovery(current, code: code))
        let publicKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: candidate.privateKey).publicKey.rawRepresentation
        let envelope = try ReaderCrypto.wrapForDevice(candidate.bundle!, deviceID: candidate.deviceID,
            recipientPublicKey: publicKey, challenge: candidate.challenge)
        pending = Pending(requestID: UUID(), candidate: candidate, envelope: envelope, createdAt: createdAt)
        requests[pending.requestID] = Request(p_request_id: pending.requestID, p_device_id: candidate.deviceID,
            p_public_key: DeviceKeys.hex(publicKey), p_challenge: DeviceKeys.hex(candidate.challenge))
        if mode == .rotated || mode == .suspended { active.insert(pending.requestID) }
    }

    func handle(_ request: StubProtocol) {
        lock.withLock {
            do {
                let path = request.request.url!.path
                if path == "/auth/v1/token" {
                    let session = AuthSession(access_token: "fixture-access", refresh_token: "fixture-refresh",
                        expires_at: Date().timeIntervalSince1970 + 3600, user: .init(id: original.accountID, email: "fixture@example.invalid"))
                    request.respond(try ReaderCrypto.encode(session))
                } else if path.hasSuffix("v1_key_state") {
                    if mode == .suspended && holdFirstState {
                        holdFirstState = false; held = request; arrived.fulfill(); return
                    }
                    try respondToState(request)
                } else if path.hasSuffix("v1_devices") {
                    let rows = mode == .revoked ? [["id": pending.candidate.deviceID.wire, "revoked_at": "2026-10-03T00:00:00Z"]] : []
                    request.respond(try ReaderCrypto.encode(rows))
                } else if path.hasSuffix("v1_request_enrollment") {
                    let value = try JSONDecoder().decode(Request.self, from: body(request.request))
                    calls.append(value)
                    if requests[value.p_request_id] == nil {
                        if mode == .lateApproval {
                            // The old approver commits just as the client renews.
                            // A second approval of the same device will conflict.
                            envelopes[pending.candidate.deviceID] = DeviceKeys.hex(pending.envelope)
                        }
                        requests[value.p_request_id] = value; active.insert(value.p_request_id)
                    }
                    request.respond(try ReaderCrypto.encode(value.p_request_id))
                } else if path.hasSuffix("v1_enrollment_requests") {
                    request.respond(try ReaderCrypto.encode(active.map { ["id": $0.wire] }))
                } else if path.hasSuffix("v1_approve_enrollment") {
                    let data = try JSONSerialization.jsonObject(with: body(request.request)) as! [String: Any]
                    let id = UUID(uuidString: data["p_request_id"] as! String)!
                    guard let target = requests[id], active.contains(id),
                          data["p_epoch"] as? Int == keys.epoch,
                          data["p_management_token"] as? String == DeviceKeys.hex(keys.managementToken),
                          data["p_expected_public_key"] as? String == target.p_public_key,
                          data["p_expected_challenge"] as? String == target.p_challenge else {
                        request.respond(Data("{}".utf8), status: 400); return
                    }
                    if envelopes[target.p_device_id] != nil || (mode == .revoked && target.p_device_id == pending.candidate.deviceID) {
                        request.respond(Data("{}".utf8), status: 409); return
                    }
                    envelopes[target.p_device_id] = data["p_envelope"] as? String
                    active.remove(id)
                    request.respond(Data(), status: 204)
                } else { request.respond(Data("{}".utf8), status: 404) }
            } catch { request.respond(Data("{}".utf8), status: 500) }
        }
    }
    private func respondToState(_ request: StubProtocol) throws {
        let data = try JSONSerialization.jsonObject(with: body(request.request)) as! [String: String]
        let deviceID = UUID(uuidString: data["p_device_id"]!)!
        let value: [String: Any] = ["epoch": keys.epoch, "recovery_package": recovery,
                                    "device_envelope": envelopes[deviceID] as Any? ?? NSNull()]
        request.respond(try JSONSerialization.data(withJSONObject: value))
    }
    private func body(_ request: URLRequest) -> Data {
        if let bytes = request.httpBody { return bytes }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096); var bytes = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
        }
        return bytes
    }
    func releaseState() throws {
        try lock.withLock {
            if let held { try respondToState(held); self.held = nil }
        }
    }
    func requestCalls() -> [Request] { lock.withLock { calls } }
}

@MainActor
final class EnrollmentSafetyTests: XCTestCase {
    private struct Fixture {
        let manager: DeviceKeys
        let client: BackendClient
        let vault: String
        let environment: String
        let host: String
        func clean() throws {
            StubProtocol.remove(host: host)
            try KeychainVault.delete(environment + ".auth-session")
            try KeychainVault.delete(vault)
            try KeychainVault.delete(vault + ".pending-enrollment")
        }
    }
    private func fixture(_ server: EnrollmentServer) async throws -> Fixture {
        let environment = "enrollment-test-\(UUID().wire)", host = environment + ".invalid"
        let vault = "\(environment).\(server.original.accountID.wire).device-keys"
        StubProtocol.install(host: host) { server.handle($0) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let client = try BackendClient(configuration: .init(url: URL(string: "https://\(host)")!, anonKey: "fixture", environment: environment),
                                       network: URLSession(configuration: configuration))
        _ = try await client.signIn(email: "fixture", password: "fixture")
        try KeychainVault.write(ReaderCrypto.encode(server.original), name: vault)
        // This is the existing persisted format, including its legacy timestamp.
        try KeychainVault.write(ReaderCrypto.encode(server.pending), name: vault + ".pending-enrollment")
        return Fixture(manager: try DeviceKeys(backend: client, accountID: server.original.accountID, environment: environment),
                       client: client, vault: vault, environment: environment, host: host)
    }

    func testRequestRenewalIgnoresLocalClockAndRetainsRecipient() async throws {
        for offset: TimeInterval in [-86_400, 86_400] {
            let server = try EnrollmentServer(mode: .expired, createdAt: Date().addingTimeInterval(offset))
            let test = try await fixture(server); defer { try? test.clean() }
            let restored = try await test.manager.recover(code: server.code)
            XCTAssertEqual(restored.deviceID, server.pending.candidate.deviceID)
            XCTAssertEqual(restored.privateKey, server.pending.candidate.privateKey)
            XCTAssertEqual(restored.challenge, server.pending.candidate.challenge)
            XCTAssertEqual(restored.localStoreKey, server.original.localStoreKey)
            XCTAssertEqual(restored.bundle, server.keys)
            let calls = server.requestCalls()
            XCTAssertEqual(calls.count, 2)
            XCTAssertEqual(calls.first?.p_request_id, server.pending.requestID)
            XCTAssertNotEqual(calls.last?.p_request_id, server.pending.requestID)
            XCTAssertEqual(Set(calls.map(\.p_device_id)), [server.pending.candidate.deviceID])
        }
    }

    func testLateOlderApprovalSurvivesRenewalAndRestart() async throws {
        let server = try EnrollmentServer(mode: .lateApproval, createdAt: .distantPast)
        let test = try await fixture(server); defer { try? test.clean() }
        let restored = try await test.manager.recover(code: server.code)
        XCTAssertEqual(restored.deviceID, server.pending.candidate.deviceID)
        XCTAssertEqual(restored.privateKey, server.pending.candidate.privateKey)
        XCTAssertEqual(restored.bundle, server.keys)
        XCTAssertNil(try KeychainVault.read(test.vault + ".pending-enrollment"))
        let reopened = try DeviceKeys(backend: test.client, accountID: server.original.accountID, environment: test.environment)
        guard case .ready(let device) = try await reopened.prepare() else { return XCTFail("Approved identity must survive restart") }
        XCTAssertEqual(device.privateKey, server.pending.candidate.privateKey)
        XCTAssertEqual(Set(server.requestCalls().map(\.p_device_id)), [server.pending.candidate.deviceID])
    }

    func testNewEpochRewrapsTheSamePendingRecipient() async throws {
        let server = try EnrollmentServer(mode: .rotated)
        let test = try await fixture(server); defer { try? test.clean() }
        let restored = try await test.manager.recover(code: server.code)
        XCTAssertEqual(restored.deviceID, server.pending.candidate.deviceID)
        XCTAssertEqual(restored.privateKey, server.pending.candidate.privateKey)
        XCTAssertEqual(restored.bundle, server.keys)
        XCTAssertEqual(server.requestCalls().map(\.p_request_id), [server.pending.requestID])
    }

    func testOnlyConfirmedRevocationReplacesAPendingIdentity() async throws {
        let server = try EnrollmentServer(mode: .revoked)
        let test = try await fixture(server); defer { try? test.clean() }
        let restored = try await test.manager.recover(code: server.code)
        XCTAssertNotEqual(restored.deviceID, server.pending.candidate.deviceID)
        XCTAssertNotEqual(restored.privateKey, server.pending.candidate.privateKey)
        XCTAssertEqual(restored.localStoreKey, server.original.localStoreKey)
        XCTAssertEqual(restored.bundle, server.keys)
        XCTAssertEqual(Set(server.requestCalls().map(\.p_device_id)), [restored.deviceID])
    }

    func testOverlappingRecoveryDoesNotReplaceSuspendedPrepareKeys() async throws {
        let server = try EnrollmentServer(mode: .suspended)
        let test = try await fixture(server); defer { try? test.clean() }
        let before = try KeychainVault.read(test.vault + ".pending-enrollment")
        let preparing = Task { try await test.manager.prepare() }
        await fulfillment(of: [server.arrived], timeout: 5)
        do { _ = try await test.manager.recover(code: server.code); XCTFail("Overlapping mutation must be refused") }
        catch DeviceKeyError.operationInProgress { }
        XCTAssertEqual(try KeychainVault.read(test.vault + ".pending-enrollment"), before)
        try server.releaseState()
        guard case .recoveryRequired = try await preparing.value else { return XCTFail("Unapproved device must need recovery") }
        let restored = try await test.manager.recover(code: server.code)
        XCTAssertEqual(restored.deviceID, server.pending.candidate.deviceID)
    }
}
