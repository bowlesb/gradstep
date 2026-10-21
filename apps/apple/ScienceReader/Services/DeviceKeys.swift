import CryptoKit
import Foundation
import ScienceReaderCore

struct LocalDevice: Codable, Sendable {
    let accountID: UUID
    let deviceID: UUID
    let privateKey: Data
    let challenge: Data
    let localStoreKey: Data
    var bundle: KeyBundle?
    var pendingRecoveryCode: String?

    static func create(accountID: UUID, localStoreKey: Data? = nil) -> LocalDevice {
        .init(accountID: accountID, deviceID: UUID(), privateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
              challenge: ReaderCrypto.randomKey(), localStoreKey: localStoreKey ?? ReaderCrypto.randomKey())
    }
}

enum KeyPreparation: Sendable { case ready(LocalDevice), saveRecoveryCode(String), recoveryRequired }

enum DeviceKeyError: LocalizedError {
    case operationInProgress
    case noKeyAuthority
    var errorDescription: String? {
        switch self {
        case .operationInProgress: "Encryption keys are being updated. Please try again in a moment."
        case .noKeyAuthority: "This account has no approved device yet. Use the recovery code to create the account keys first."
        }
    }
}

@MainActor
final class DeviceKeys {
    private let backend: BackendClient
    private let accountID: UUID
    private let vaultName: String
    private var device: LocalDevice
    private var operationInProgress = false
    private struct PendingEnrollment: Codable {
        let requestID: UUID
        var candidate: LocalDevice
        /// Nil for a newly signed-in device waiting for an approved device to wrap the account bundle.
        let envelope: Data?
        // Informational only. Server request state determines renewal.
        let createdAt: Date
    }

    struct KeyState: Decodable, Sendable { let epoch: Int; let recovery_package: String; let device_envelope: String? }
    private struct DeviceRegistration: Decodable, Sendable { let id: UUID; let revoked_at: String? }
    private struct EnrollmentRequest: Decodable, Sendable { let id: UUID }

    init(backend: BackendClient, accountID: UUID, environment: String) throws {
        self.backend = backend; self.accountID = accountID
        self.vaultName = "\(environment).\(accountID.wire).device-keys"
        if let bytes = try KeychainVault.read(vaultName) {
            let saved = try JSONDecoder().decode(LocalDevice.self, from: bytes)
            guard saved.accountID == accountID else { throw ReaderError.wrongAccount }
            self.device = saved
        } else {
            self.device = .create(accountID: accountID)
            try KeychainVault.write(ReaderCrypto.encode(device), name: vaultName)
        }
    }

    func cachedDevice() throws -> LocalDevice? {
        guard let bundle = device.bundle, device.pendingRecoveryCode == nil else { return nil }
        try bundle.validate(accountID: accountID)
        guard device.accountID == accountID, device.localStoreKey.count == 32, device.challenge.count == 32,
              device.privateKey.count == 32 else { throw ReaderError.invalidKey }
        return device
    }

    func prepare() async throws -> KeyPreparation {
        try beginOperation(); defer { operationInProgress = false }
        if let pending = try pendingEnrollment(), let completed = try await finishApproved(pending) { return .ready(completed) }
        let state: KeyState? = try await backend.rpc("v1_key_state", params: ["p_device_id": device.deviceID.wire], accountID: accountID)
        try Task.checkCancellation()
        guard let state else {
            if device.bundle == nil {
                var candidate = device
                candidate.bundle = KeyBundle.generate(accountID: accountID)
                candidate.pendingRecoveryCode = ReaderCrypto.recoveryCode()
                try activate(candidate)
            }
            guard let code = device.pendingRecoveryCode else { throw ReaderError.missingKey }
            return .saveRecoveryCode(code)
        }
        guard let wrapped = state.device_envelope else { return .recoveryRequired }
        let keys = try ReaderCrypto.unwrapForDevice(try Self.bytea(wrapped), accountID: accountID, deviceID: device.deviceID,
                                                    epoch: state.epoch, privateKey: .init(rawRepresentation: device.privateKey), challenge: device.challenge)
        var candidate = device; candidate.bundle = keys
        try activate(candidate)
        if let code = device.pendingRecoveryCode { return .saveRecoveryCode(code) }
        return .ready(device)
    }

    /// Starts or resumes the Mac's enrollment request and returns the exact payload the approved device must scan.
    ///
    /// A new account has no keyring yet and must use the recovery-code bootstrap. An existing account has a keyring
    /// but no envelope for this device; in that case the recipient identity is persisted before the request is sent,
    /// so a lost response or a relaunch can continue the same approval. With `refresh == false` this is local-only;
    /// the Mac poller uses the slower refresh calls to check whether the server has delivered the envelope.
    func macApprovalPayload(refresh: Bool) async throws -> DeviceApprovalPayload? {
        try beginOperation(); defer { operationInProgress = false }
        if try cachedDevice() != nil { return nil }
        guard device.bundle == nil, device.pendingRecoveryCode == nil else { throw DeviceKeyError.noKeyAuthority }

        var pending = try pendingEnrollment()
        if pending == nil {
            let state: KeyState? = try await backend.rpc("v1_key_state", params: ["p_device_id": device.deviceID.wire], accountID: accountID)
            try Task.checkCancellation()
            // There is no authority to wrap keys until the first device completes recovery-code bootstrap.
            guard state != nil else { throw DeviceKeyError.noKeyAuthority }
            guard state?.device_envelope == nil else { throw DeviceKeyError.noKeyAuthority }
            let candidate = device
            pending = PendingEnrollment(requestID: UUID(), candidate: candidate, envelope: nil, createdAt: Date())
            try savePending(pending!)
        }
        guard var request = pending else { throw DeviceKeyError.noKeyAuthority }
        let publicKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: request.candidate.privateKey).publicKey.rawRepresentation
        if refresh {
            if let completed = try await finishApproved(request) {
                device = completed
                return nil
            }
            try await requestEnrollment(request, publicKey: publicKey)
            // Keep the exact persisted request identity; a server renewal is only possible after an explicit expiry.
            request = try pendingEnrollment() ?? request
        }
        return try DeviceApprovalPayload(requestID: request.requestID, accountID: accountID, deviceID: request.candidate.deviceID,
                                         publicKey: publicKey, challenge: request.candidate.challenge, kind: .mac)
    }

    func confirmRecoverySaved() async throws -> LocalDevice {
        try beginOperation(); defer { operationInProgress = false }
        guard let keys = device.bundle, let code = device.pendingRecoveryCode else { throw ReaderError.missingKey }
        let publicKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: device.privateKey).publicKey.rawRepresentation
        let recovery = try ReaderCrypto.wrapRecovery(keys, code: code)
        let envelope = try ReaderCrypto.wrapForDevice(keys, deviceID: device.deviceID, recipientPublicKey: publicKey, challenge: device.challenge)
        struct Params: Encodable, Sendable { let p_device_id: String; let p_public_key: String; let p_recovery_package: String; let p_management_token: String; let p_device_envelope: String; let p_challenge: String }
        let created: Bool = try await backend.rpc("v1_bootstrap_keys", params: Params(p_device_id: device.deviceID.wire, p_public_key: Self.hex(publicKey),
            p_recovery_package: Self.hex(recovery), p_management_token: Self.hex(keys.managementToken), p_device_envelope: Self.hex(envelope), p_challenge: Self.hex(device.challenge)), accountID: accountID)
        var candidate = device
        if !created {
            // A timed-out successful bootstrap is recoverable through this exact
            // device envelope. A different first device must use enrollment.
            let state: KeyState? = try await backend.rpc("v1_key_state", params: ["p_device_id": device.deviceID.wire], accountID: accountID)
            guard let state, let wrapped = state.device_envelope else { throw ReaderError.missingKey }
            candidate.bundle = try ReaderCrypto.unwrapForDevice(try Self.bytea(wrapped), accountID: accountID, deviceID: device.deviceID,
                epoch: state.epoch, privateKey: .init(rawRepresentation: device.privateKey), challenge: device.challenge)
        }
        candidate.pendingRecoveryCode = nil
        try activate(candidate)
        return device
    }

    func recover(code: String) async throws -> LocalDevice {
        try beginOperation(); defer { operationInProgress = false }
        var saved = try pendingEnrollment()
        if let saved, let completed = try await finishApproved(saved) { return completed }
        let state: KeyState? = try await backend.rpc("v1_key_state", params: ["p_device_id": device.deviceID.wire], accountID: accountID)
        try Task.checkCancellation()
        guard let state else { throw ReaderError.missingKey }
        let keys = try ReaderCrypto.recover(try Self.bytea(state.recovery_package), code: code, accountID: accountID)
        guard keys.epoch == state.epoch else { throw ReaderError.staleEpoch }
        if let pending = saved {
            let registrations: [DeviceRegistration] = try await backend.rpc("v1_devices", params: EmptyResponse(), accountID: accountID)
            try Task.checkCancellation()
            // A positive revocation record is the only reason to retire this
            // recipient. Timeouts, elapsed time and new epochs are insufficient.
            if registrations.contains(where: { $0.id == pending.candidate.deviceID && $0.revoked_at != nil }) { saved = nil }
        }
        var candidate = saved?.candidate ?? LocalDevice.create(accountID: accountID, localStoreKey: device.localStoreKey)
        let sameBundle = candidate.bundle == keys
        candidate.bundle = keys
        let publicKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: candidate.privateKey).publicKey.rawRepresentation
        let envelope: Data
        if let saved, sameBundle, let savedEnvelope = saved.envelope { envelope = savedEnvelope }
        else { envelope = try ReaderCrypto.wrapForDevice(keys, deviceID: candidate.deviceID, recipientPublicKey: publicKey, challenge: candidate.challenge) }
        var pending = PendingEnrollment(requestID: saved?.requestID ?? UUID(), candidate: candidate, envelope: envelope,
                                        createdAt: saved?.createdAt ?? Date())
        try savePending(pending)
        try await requestEnrollment(pending, publicKey: publicKey)
        let requests: [EnrollmentRequest] = try await backend.rpc("v1_enrollment_requests", params: EmptyResponse(), accountID: accountID)
        try Task.checkCancellation()
        if !requests.contains(where: { $0.id == pending.requestID }) {
            if let completed = try await finishApproved(pending) { return completed }
            // An old request may still win after the read above. Keep its
            // recipient key so that approval remains recoverable in that race.
            pending = PendingEnrollment(requestID: UUID(), candidate: candidate, envelope: envelope, createdAt: Date())
            try savePending(pending)
            try await requestEnrollment(pending, publicKey: publicKey)
        }
        struct Approval: Encodable, Sendable {
            let p_request_id: String; let p_epoch: Int; let p_management_token: String
            let p_expected_public_key: String; let p_expected_challenge: String; let p_envelope: String
        }
        guard let pendingEnvelope = pending.envelope else { throw ReaderError.missingKey }
        do {
            try await backend.rpcVoid("v1_approve_enrollment", params: Approval(p_request_id: pending.requestID.wire, p_epoch: keys.epoch,
                p_management_token: Self.hex(keys.managementToken), p_expected_public_key: Self.hex(publicKey),
                p_expected_challenge: Self.hex(candidate.challenge), p_envelope: Self.hex(pendingEnvelope)), accountID: accountID)
        } catch {
            try Task.checkCancellation()
            // The server may have committed, or the older request may have won.
            // If reconciliation itself fails, retain the pending recipient and
            // report the original error; prepare() can resume after a restart.
            if let completed = try? await finishApproved(pending) { return completed }
            throw error
        }
        guard let completed = try await finishApproved(pending) else { throw ReaderError.missingKey }
        return completed
    }

    private func requestEnrollment(_ pending: PendingEnrollment, publicKey: Data) async throws {
        let receipt: UUID = try await backend.rpc("v1_request_enrollment", params: ["p_request_id": pending.requestID.wire,
            "p_device_id": pending.candidate.deviceID.wire, "p_public_key": Self.hex(publicKey),
            "p_challenge": Self.hex(pending.candidate.challenge)], accountID: accountID)
        try Task.checkCancellation()
        guard receipt == pending.requestID else { throw ReaderError.corruptData }
    }
    private func savePending(_ pending: PendingEnrollment) throws {
        try Task.checkCancellation()
        try KeychainVault.write(ReaderCrypto.encode(pending), name: vaultName + ".pending-enrollment")
    }
    private func pendingEnrollment() throws -> PendingEnrollment? {
        guard let bytes = try KeychainVault.read(vaultName + ".pending-enrollment") else { return nil }
        let pending = try JSONDecoder().decode(PendingEnrollment.self, from: bytes)
        guard pending.candidate.accountID == accountID, pending.candidate.localStoreKey == device.localStoreKey else { throw ReaderError.wrongAccount }
        guard pending.candidate.pendingRecoveryCode == nil, pending.candidate.privateKey.count == 32,
              pending.candidate.challenge.count == 32, pending.candidate.localStoreKey.count == 32 else { throw ReaderError.invalidKey }
        try pending.candidate.bundle?.validate(accountID: accountID)
        return pending
    }
    private func finishApproved(_ pending: PendingEnrollment) async throws -> LocalDevice? {
        let state: KeyState? = try await backend.rpc("v1_key_state", params: ["p_device_id": pending.candidate.deviceID.wire], accountID: accountID)
        try Task.checkCancellation()
        guard let state, let wrapped = state.device_envelope else { return nil }
        var candidate = pending.candidate
        candidate.bundle = try ReaderCrypto.unwrapForDevice(try Self.bytea(wrapped), accountID: accountID, deviceID: candidate.deviceID,
            epoch: state.epoch, privateKey: .init(rawRepresentation: candidate.privateKey), challenge: candidate.challenge)
        try activate(candidate)
        try KeychainVault.delete(vaultName + ".pending-enrollment")
        return device
    }

    private func activate(_ candidate: LocalDevice) throws {
        try Task.checkCancellation()
        try KeychainVault.write(ReaderCrypto.encode(candidate), name: vaultName)
        device = candidate
    }
    private func beginOperation() throws {
        try Task.checkCancellation()
        guard !operationInProgress else { throw DeviceKeyError.operationInProgress }
        operationInProgress = true
    }
    nonisolated static func hex(_ data: Data) -> String { "\\x" + data.hex }
    nonisolated static func bytea(_ string: String) throws -> Data {
        guard string.hasPrefix("\\x"), let data = Data(hex: String(string.dropFirst(2))) else { throw ReaderError.corruptData }
        return data
    }
}

struct EmptyResponse: Codable, Sendable {}

/// A short code for the session timeline: an error's case or a code from BackendClient's finite known set,
/// never server prose, event content or localized text.
enum SyncFailure {
    static func code(_ error: Error) -> String {
        switch error {
        case let reader as ReaderError: "reader_" + String(describing: reader)
        case BackendError.rejected(let code): code
        case let backend as BackendError: String(describing: backend)
        case let url as URLError: "url_\(url.code.rawValue)"
        case is CancellationError: "cancelled"
        default: String(describing: type(of: error))
        }
    }
}

@MainActor
final class CloudSync {
    private let backend: BackendClient
    private(set) var device: LocalDevice
    private let keyManager: DeviceKeys
    private let store: EncryptedStore
    private let onDeviceChanged: @MainActor (LocalDevice) -> Void
    private var currentTask: Task<Void, Error>?
    /// Notes snippet images (NOTES_AND_SNIPPETS.md): uploaded before events, so a held entry follows its blobs.
    private let noteAssets: (any NoteAssetTransport)?
    private let onNoteUploads: @MainActor (NoteUploadReport) -> Void

    init(backend: BackendClient, device: LocalDevice, keyManager: DeviceKeys, store: EncryptedStore,
         noteAssets: (any NoteAssetTransport)? = nil, onNoteUploads: @escaping @MainActor (NoteUploadReport) -> Void = { _ in },
         onDeviceChanged: @escaping @MainActor (LocalDevice) -> Void = { _ in }) {
        self.backend = backend; self.device = device; self.keyManager = keyManager; self.store = store; self.onDeviceChanged = onDeviceChanged
        self.noteAssets = noteAssets; self.onNoteUploads = onNoteUploads
    }

    func synchronize() async throws {
        if let currentTask { return try await currentTask.value }
        let task = Task { try await self.transfer() }
        currentTask = task
        defer { currentTask = nil }
        try await task.value
    }

    func cancel() { currentTask?.cancel() }
    func stop() async { if let currentTask { currentTask.cancel(); _ = await currentTask.result } }

    private func transfer() async throws {
        for attempt in 0..<2 {
            do { try await transferOnce(); return }
            catch {
                let canRefresh: Bool
                switch error {
                case ReaderError.missingKey, ReaderError.staleEpoch: canRefresh = true
                case BackendError.rejected(let code): canRefresh = ["stale_key_epoch", "key_authority_required"].contains(code)
                default: canRefresh = false
                }
                guard attempt == 0 && canRefresh else { throw error }
            }
        }
    }

    private func transferOnce() async throws {
        try Task.checkCancellation()
        guard case .ready(let refreshed) = try await keyManager.prepare(), let keys = refreshed.bundle else { throw ReaderError.missingKey }
        try Task.checkCancellation()
        guard refreshed.accountID == device.accountID else { throw ReaderError.wrongAccount }
        try await store.updateKeys(keys)
        device = refreshed; onDeviceChanged(refreshed)
        // Pull-first resolves accepted uploads with lost acknowledgements. A
        // visible newer epoch fences any subsequent old-epoch server commits.
        try await pull()
        try Task.checkCancellation()
        try await store.rebasePendingAfterCatchUp(deviceID: device.deviceID, verifiedEpoch: keys.epoch, cursor: await store.cursor())
        // Snippet blobs first: an entry event is uploaded only after its blobs are `ready` (store.pending() holds it
        // until then). A failed image never blocks chats, catalogs or other notes; its report is shown in Notes.
        if let noteAssets, !(try await store.pendingNoteUploads()).isEmpty {
            let report = try await NoteAssetSync.uploadPending(store: store, transport: noteAssets)
            try Task.checkCancellation()
            onNoteUploads(report)
            if !report.failures.isEmpty {
                SessionTimeline.shared.record("sync", ["step": "note-assets", "uploaded": String(report.uploaded.count),
                                                       "failed": String(report.failures.count)])
            }
        }
        struct Push: Encodable, Sendable {
            let p_device_id: UUID; let p_id: UUID; let p_epoch: Int; let p_format: Int; let p_ciphertext: String; let p_management_token: String
        }
        var uploaded = 0
        while uploaded < 1_000 {
            let pending = await store.pending()
            if pending.isEmpty { break }
            for event in pending.prefix(1_000 - uploaded) {
                try Task.checkCancellation()
                let cursor: Int64 = try await backend.rpc("v1_append_event", params: Push(p_device_id: event.deviceID, p_id: event.id,
                    p_epoch: event.epoch, p_format: event.format, p_ciphertext: DeviceKeys.hex(event.ciphertext), p_management_token: DeviceKeys.hex(keys.managementToken)), accountID: device.accountID)
                try Task.checkCancellation()
                guard cursor > 0 else { throw ReaderError.corruptData }
                try await store.acknowledge(event); uploaded += 1
            }
        }
        try await pull()
        try Task.checkCancellation()
        struct Acknowledgment: Encodable, Sendable { let p_device_id: UUID; let p_cursor: Int64; let p_management_token: String }
        // The pull above is complete and durable; the acknowledgement only trims server retention. As in the
        // browser (history.ts), its failure is logged and the cursor is sent again next sync, never "Sync paused".
        do {
            try await backend.rpcVoid("v1_acknowledge_cursor", params: Acknowledgment(p_device_id: device.deviceID,
                p_cursor: await store.cursor(), p_management_token: DeviceKeys.hex(keys.managementToken)), accountID: device.accountID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            SessionTimeline.shared.record("sync", ["step": "acknowledge", "status": "failed", "code": SyncFailure.code(error)])
        }
    }

    private func pull() async throws {
        struct Pull: Encodable, Sendable { let p_after: Int64; let p_limit = 200 }
        struct Row: Decodable, Sendable { let id: UUID; let device_id: UUID; let cursor: Int64; let epoch: Int; let format: Int; let ciphertext: String; let ciphertext_sha256: String }
        struct Page: Decodable, Sendable { let events: [Row]; let next_cursor: Int64; let has_more: Bool }
        while true {
            try Task.checkCancellation()
            let before = await store.cursor()
            let response: Page = try await backend.rpc("v3_pull_events", params: Pull(p_after: before), accountID: device.accountID)
            try Task.checkCancellation()
            guard response.next_cursor == (response.events.last?.cursor ?? before),
                  !response.has_more || !response.events.isEmpty else { throw ReaderError.corruptData }
            let page = try response.events.map { row in
                RemoteEvent(cursor: row.cursor, envelope: EventEnvelope(id: row.id, deviceID: row.device_id, epoch: row.epoch,
                    format: row.format, ciphertext: try DeviceKeys.bytea(row.ciphertext)), digest: try DeviceKeys.bytea(row.ciphertext_sha256))
            }
            try await store.ingest(page)
            if !response.has_more { break }
        }
    }
}
