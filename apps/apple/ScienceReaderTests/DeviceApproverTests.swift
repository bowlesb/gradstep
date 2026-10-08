import CryptoKit
import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// The approving device's state machine over a scripted server: what it approves, what it refuses before any
/// approval reaches the server, and how it handles rotated or missing key authority.
private actor ScriptedApprovalServer: DeviceApprovalTransport {
    var requests: [EnrollmentRequestRecord]
    var listCalls = 0
    var approvals: [(EnrollmentRequestRecord, Int, Data, Data)] = []
    /// Accepted management token; anything else answers `key_authority_required`.
    var authority: Data
    var failure: Error?

    init(requests: [EnrollmentRequestRecord], authority: Data) { self.requests = requests; self.authority = authority }
    func set(requests: [EnrollmentRequestRecord]) { self.requests = requests }
    func set(failure: Error?) { self.failure = failure }

    func pendingRequests() async throws -> [EnrollmentRequestRecord] { listCalls += 1; return requests }
    func approve(_ request: EnrollmentRequestRecord, epoch: Int, managementToken: Data, envelope: Data) async throws {
        if let failure { throw failure }
        guard managementToken == authority else { throw BackendError.rejected("key_authority_required") }
        approvals.append((request, epoch, managementToken, envelope))
    }
}

@MainActor
final class DeviceApproverTests: XCTestCase {
    private let account = UUID()
    private let recipient = Curve25519.KeyAgreement.PrivateKey()
    private lazy var request = EnrollmentRequestRecord(id: UUID(), deviceID: UUID(), publicKey: recipient.publicKey.rawRepresentation,
                                                       challenge: ReaderCrypto.randomKey())
    private lazy var keys = KeyBundle.generate(accountID: account)

    private func payload(for request: EnrollmentRequestRecord, account: UUID? = nil, kind: DeviceKind = .browser) throws -> String {
        try DeviceApprovalPayload(requestID: request.id, accountID: account ?? self.account, deviceID: request.deviceID,
                                  publicKey: request.publicKey, challenge: request.challenge, kind: kind).encoded
    }

    private func approver(_ server: ScriptedApprovalServer, keys: KeyBundle?, refreshed: KeyBundle? = nil) -> DeviceApprover {
        DeviceApprover(accountID: account, transport: server, currentKeys: { keys }, refreshKeys: { refreshed ?? keys })
    }

    func testScannedRecipientIsConfirmedByNumberThenReceivesAnEnvelopeOnlyItCanOpen() async throws {
        let server = ScriptedApprovalServer(requests: [request], authority: keys.managementToken)
        let approver = approver(server, keys: keys)
        await approver.scanned(try payload(for: request))
        guard case .confirm(let candidate) = approver.phase else { return XCTFail("\(approver.phase)") }
        XCTAssertEqual(candidate.request, request)
        XCTAssertEqual(candidate.kind, .browser)
        XCTAssertEqual(candidate.code, try request.comparisonCode(accountID: account))
        let approvalsBeforeConfirming = await server.approvals.count
        XCTAssertEqual(approvalsBeforeConfirming, 0, "Nothing is shared before the person approves")

        await approver.approve()
        XCTAssertEqual(approver.phase, .approved(candidate))
        let first = await server.approvals.first
        let sent = try XCTUnwrap(first)
        XCTAssertEqual(sent.0, request)
        XCTAssertEqual(sent.1, keys.epoch)
        XCTAssertEqual(try ReaderCrypto.unwrapForDevice(sent.3, accountID: account, deviceID: request.deviceID, epoch: 1,
                                                        privateKey: recipient, challenge: request.challenge), keys)
        XCTAssertThrowsError(try ReaderCrypto.unwrapForDevice(sent.3, accountID: account, deviceID: request.deviceID, epoch: 1,
                                                              privateKey: .init(), challenge: request.challenge))
    }

    func testASubstitutedKeyIsRefusedAndNeverApproved() async throws {
        let substitute = EnrollmentRequestRecord(id: request.id, deviceID: request.deviceID,
            publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation, challenge: request.challenge)
        let server = ScriptedApprovalServer(requests: [substitute], authority: keys.managementToken)
        let approver = approver(server, keys: keys)
        await approver.scanned(try payload(for: request))
        XCTAssertEqual(approver.phase, .failed(DeviceApprover.message(DeviceApprovalError.keyMismatch)))
        await approver.approve() // no confirmation, so nothing to approve
        let approvals = await server.approvals.count
        XCTAssertEqual(approvals, 0)
    }

    func testOtherAccountsUnknownTextAndExpiredRequestsAreExplained() async throws {
        let server = ScriptedApprovalServer(requests: [request], authority: keys.managementToken)
        var approver = approver(server, keys: keys)
        await approver.scanned(try payload(for: request, account: UUID()))
        XCTAssertEqual(approver.phase, .failed(DeviceApprover.message(DeviceApprovalError.differentAccount)))
        let lookups = await server.listCalls
        XCTAssertEqual(lookups, 0, "Another account's code is never looked up")

        approver = self.approver(server, keys: keys)
        await approver.scanned("https://example.com/not-a-device-code")
        XCTAssertEqual(approver.phase, .failed(DeviceApprover.message(DeviceApprovalError.unrecognized)))

        // Expired or already approved: the server no longer lists it.
        await server.set(requests: [])
        approver = self.approver(server, keys: keys)
        await approver.scanned(try payload(for: request))
        XCTAssertEqual(approver.phase, .failed(DeviceApprover.message(DeviceApprovalError.expiredOrUsed)))

        // Expired between the scan and the approval: the server refuses; the person is told to show a new code.
        await server.set(requests: [request])
        await server.set(failure: BackendError.rejected("enrollment_mismatch"))
        approver = self.approver(server, keys: keys)
        await approver.scanned(try payload(for: request))
        await approver.approve()
        XCTAssertEqual(approver.phase, .failed(DeviceApprover.message(BackendError.rejected("enrollment_mismatch"))))
        XCTAssertTrue(DeviceApprover.message(BackendError.rejected("enrollment_mismatch")).contains("expired"))
    }

    func testRotatedKeysAreRefreshedOnceAndLostAuthorityIsExplained() async throws {
        var rotated = keys; try rotated.rotate()
        let server = ScriptedApprovalServer(requests: [request], authority: rotated.managementToken)
        var approver = approver(server, keys: keys, refreshed: rotated)
        await approver.scanned(try payload(for: request))
        await approver.approve()
        guard case .approved = approver.phase else { return XCTFail("\(approver.phase)") }
        let first = await server.approvals.first
        let sent = try XCTUnwrap(first)
        XCTAssertEqual(sent.1, 2)
        XCTAssertEqual(try ReaderCrypto.unwrapForDevice(sent.3, accountID: account, deviceID: request.deviceID, epoch: 2,
                                                        privateKey: recipient, challenge: request.challenge), rotated)

        // Refreshing changes nothing: this device was removed or is stale.
        let removed = ScriptedApprovalServer(requests: [request], authority: ReaderCrypto.randomKey())
        approver = self.approver(removed, keys: keys)
        await approver.scanned(try payload(for: request))
        await approver.approve()
        XCTAssertEqual(approver.phase, .failed(DeviceApprover.message(DeviceApprover.Refusal.noAuthority)))

        // No keys at all: nothing to share, explained before any approval.
        approver = self.approver(server, keys: nil)
        XCTAssertFalse(approver.canApprove)
        await approver.scanned(try payload(for: request))
        await approver.approve()
        XCTAssertEqual(approver.phase, .failed(DeviceApprover.message(DeviceApprover.Refusal.noKeys)))
    }

    func testWaitingRequestsCarryTheNumberTheNewDeviceShows() async throws {
        let malformed = EnrollmentRequestRecord(id: UUID(), deviceID: UUID(), publicKey: Data(count: 31), challenge: ReaderCrypto.randomKey())
        let server = ScriptedApprovalServer(requests: [malformed, request], authority: keys.managementToken)
        let approver = approver(server, keys: keys)
        let waiting = try await approver.waiting()
        XCTAssertEqual(waiting.map(\.request), [request])
        XCTAssertEqual(waiting.first?.code, try DeviceApprovalPayload(scanned: try payload(for: request)).comparisonCode)
        XCTAssertNil(waiting.first?.kind)
        approver.review(try XCTUnwrap(waiting.first))
        await approver.approve()
        guard case .approved = approver.phase else { return XCTFail("\(approver.phase)") }
    }
}
