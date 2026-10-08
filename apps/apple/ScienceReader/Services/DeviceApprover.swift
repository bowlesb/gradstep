import CryptoKit
import Foundation
import Observation
import ScienceReaderCore
import UIKit

// Settings › Account › Add a device, and the "A new device is waiting" banner: this approved device adds a new one by
// wrapping its key bundle for the exact recipient the new device's QR code names (DeviceApproval in
// ScienceReaderCore; docs/architecture/PRIVACY_AND_SYNC.md#approving-a-new-device-qr). Uses the existing enrollment
// RPCs from migration 002; no new server state.

protocol DeviceApprovalTransport: Sendable {
    /// `v1_enrollment_requests()`: the account's unexpired, unapproved requests.
    func pendingRequests() async throws -> [EnrollmentRequestRecord]
    /// `v1_approve_enrollment`, with this device's key authority and the verified recipient.
    func approve(_ request: EnrollmentRequestRecord, epoch: Int, managementToken: Data, envelope: Data) async throws
}

struct LiveDeviceApprovalTransport: DeviceApprovalTransport {
    let backend: BackendClient
    let accountID: UUID

    func pendingRequests() async throws -> [EnrollmentRequestRecord] {
        struct Row: Decodable, Sendable { let id: UUID; let device_id: UUID; let public_key: String; let challenge: String }
        let rows: [Row] = try await backend.rpc("v1_enrollment_requests", params: EmptyResponse(), accountID: accountID)
        // The server caps unexpired requests at five per account; never trust it to.
        return try rows.prefix(16).map {
            EnrollmentRequestRecord(id: $0.id, deviceID: $0.device_id, publicKey: try DeviceKeys.bytea($0.public_key),
                                    challenge: try DeviceKeys.bytea($0.challenge))
        }
    }

    func approve(_ request: EnrollmentRequestRecord, epoch: Int, managementToken: Data, envelope: Data) async throws {
        struct Approval: Encodable, Sendable {
            let p_request_id: String; let p_epoch: Int; let p_management_token: String
            let p_expected_public_key: String; let p_expected_challenge: String; let p_envelope: String
        }
        try await backend.rpcVoid("v1_approve_enrollment", params: Approval(p_request_id: request.id.wire, p_epoch: epoch,
            p_management_token: DeviceKeys.hex(managementToken), p_expected_public_key: DeviceKeys.hex(request.publicKey),
            p_expected_challenge: DeviceKeys.hex(request.challenge), p_envelope: DeviceKeys.hex(envelope)), accountID: accountID)
    }
}

@MainActor @Observable
final class DeviceApprover {
    struct Candidate: Equatable, Identifiable {
        let request: EnrollmentRequestRecord
        /// Six digits; the new device shows the same number for this exact recipient.
        let code: String
        /// What the QR code says the new device is; nil when reviewing a waiting request without a scan.
        let kind: DeviceKind?
        var id: UUID { request.id }
        var name: String { kind?.name ?? "New device" }
    }

    enum Phase: Equatable {
        case scanning, checking
        case confirm(Candidate), approving(Candidate), approved(Candidate)
        case failed(String)
    }

    enum Refusal: Error { case noKeys, noAuthority }

    private(set) var phase: Phase = .scanning
    let accountID: UUID
    private let transport: any DeviceApprovalTransport
    private let currentKeys: @MainActor () -> KeyBundle?
    private let refreshKeys: @MainActor () async -> KeyBundle?

    init(accountID: UUID, transport: any DeviceApprovalTransport, currentKeys: @escaping @MainActor () -> KeyBundle?,
         refreshKeys: @escaping @MainActor () async -> KeyBundle?) {
        self.accountID = accountID; self.transport = transport; self.currentKeys = currentKeys; self.refreshKeys = refreshKeys
    }

    /// Whether this device holds key authority to share (the server still checks it).
    var canApprove: Bool { currentKeys() != nil }

    /// A scanned QR text: parse, check the account, then prove the server's request is the scanned recipient.
    func scanned(_ text: String) async {
        guard phase == .scanning else { return }
        phase = .checking
        do {
            let payload = try DeviceApprovalPayload(scanned: text)
            // Before any network request: a code for another account is never looked up.
            guard payload.accountTag == DeviceApproval.accountTag(accountID) else { throw DeviceApprovalError.differentAccount }
            let request = try DeviceApproval.match(payload, accountID: accountID, requests: try await transport.pendingRequests())
            phase = .confirm(Candidate(request: request, code: payload.comparisonCode, kind: payload.kind))
        } catch { phase = .failed(Self.message(error)) }
    }

    /// The banner's path (no camera): the number is computed here from the server's request, for the person to compare.
    func review(_ candidate: Candidate) { phase = .confirm(candidate) }

    func approve() async {
        guard case .confirm(let candidate) = phase else { return }
        phase = .approving(candidate)
        do {
            guard let keys = currentKeys() else { throw Refusal.noKeys }
            do { try await send(candidate, keys: keys) }
            catch BackendError.rejected(let code) where code == "key_authority_required" {
                // Another device may have rotated the keys; refresh once. Unchanged keys mean this device lost authority.
                guard let refreshed = await refreshKeys(), refreshed.epoch != keys.epoch || refreshed.managementToken != keys.managementToken else {
                    throw Refusal.noAuthority
                }
                do { try await send(candidate, keys: refreshed) }
                catch BackendError.rejected(let code) where code == "key_authority_required" { throw Refusal.noAuthority }
            }
            phase = .approved(candidate)
        } catch { phase = .failed(Self.message(error)) }
    }

    private func send(_ candidate: Candidate, keys: KeyBundle) async throws {
        try keys.validate(accountID: accountID)
        let envelope = try DeviceApproval.envelope(for: candidate.request, keys: keys)
        try await transport.approve(candidate.request, epoch: keys.epoch, managementToken: keys.managementToken, envelope: envelope)
    }

    func restart() { phase = .scanning }

    /// Requests waiting for approval, for the banner. Rows that aren't valid recipients are left out.
    func waiting() async throws -> [Candidate] {
        try await transport.pendingRequests().compactMap { request in
            (try? request.comparisonCode(accountID: accountID)).map { Candidate(request: request, code: $0, kind: nil) }
        }
    }

    static var thisDevice: String {
        if Platform.isMac { return "Mac" }
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    static func message(_ error: Error) -> String {
        switch error {
        case DeviceApprovalError.unrecognized:
            return "That isn’t a Gradstep device code. On the new device, sign in to Gradstep and scan the code it shows."
        case DeviceApprovalError.differentAccount:
            return "That code is for a different Gradstep account. Sign in with the same account on both devices."
        case DeviceApprovalError.expiredOrUsed:
            return "That request has expired or was already used. On the new device, show a new code and scan it again."
        case DeviceApprovalError.keyMismatch:
            return "The server’s copy of this request doesn’t match the code you scanned, so nothing was approved or shared. Try again from the new device; if this happens again, send a report."
        case Refusal.noKeys:
            return "This \(thisDevice) isn’t set up for your private library yet, so it can’t approve other devices. Restore it with your recovery code first."
        case Refusal.noAuthority:
            return "This \(thisDevice) can’t approve other devices: its keys are out of date or it was removed from your account. Use your recovery code on the new device instead."
        case BackendError.rejected("enrollment_mismatch"):
            return "That request expired before it was approved. On the new device, show a new code and scan it again."
        case BackendError.rejected("enrollment_conflict"):
            return "That device was already added."
        case BackendError.transport, is URLError:
            return "Couldn’t reach Gradstep. Check your connection and try again."
        default:
            return "The device couldn’t be added. Try again."
        }
    }
}

#if FIXTURE_HOST
/// `--device-approval-fixture` (with the draft/chat fixture's signed-in account): one waiting "web browser" built from
/// public test values, and a test hook that stands in for the camera. `--device-approval-fixture-swapped` makes the
/// "server" substitute another key for the scanned request. Approval proves the envelope opens with the browser's key.
actor DeviceApprovalFixture: DeviceApprovalTransport {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--device-approval-fixture") }
    static let shared = DeviceApprovalFixture()
    static let account = UUID(uuidString: "eeeeeeee-0000-4000-8000-000000000001")!
    static let browserKey = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
    static let request = EnrollmentRequestRecord(id: UUID(uuidString: "0a0a0a0a-0000-4000-8000-00000000a11e")!,
        deviceID: UUID(uuidString: "0b0b0b0b-0000-4000-8000-00000000d1ce")!,
        publicKey: browserKey.publicKey.rawRepresentation, challenge: Data(repeating: 0x43, count: 32))
    /// The text the browser's QR code would hold.
    static var scannedText: String {
        try! DeviceApprovalPayload(requestID: request.id, accountID: account, deviceID: request.deviceID,
                                   publicKey: request.publicKey, challenge: request.challenge, kind: .browser).encoded
    }

    private let swapped = ProcessInfo.processInfo.arguments.contains("--device-approval-fixture-swapped")
    private var approved = false

    func pendingRequests() async throws -> [EnrollmentRequestRecord] {
        try await Task.sleep(for: .milliseconds(250))
        guard !approved else { return [] }
        if swapped {
            return [EnrollmentRequestRecord(id: Self.request.id, deviceID: Self.request.deviceID,
                                            publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation, challenge: Self.request.challenge)]
        }
        return [Self.request]
    }

    func approve(_ request: EnrollmentRequestRecord, epoch: Int, managementToken: Data, envelope: Data) async throws {
        try await Task.sleep(for: .milliseconds(250))
        guard request == Self.request, !approved else { throw BackendError.rejected("enrollment_mismatch") }
        let opened = try ReaderCrypto.unwrapForDevice(envelope, accountID: Self.account, deviceID: request.deviceID, epoch: epoch,
                                                      privateKey: Self.browserKey, challenge: request.challenge)
        guard opened.managementToken == managementToken else { throw ReaderError.corruptData }
        approved = true
    }
}
#endif
