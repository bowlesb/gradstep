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

@MainActor
final class DeviceKeys {
    private let backend: BackendClient
    private let accountID: UUID
    private let vaultName: String
    private var device: LocalDevice
    private struct PendingEnrollment: Codable {
        let requestID: UUID
        var candidate: LocalDevice
        let envelope: Data
        let createdAt: Date
    }

    struct KeyState: Decodable, Sendable { let epoch: Int; let recovery_package: String; let device_envelope: String? }

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
        if let pending = try pendingEnrollment(), let completed = try await finishApproved(pending) { return .ready(completed) }
        let state: KeyState? = try await backend.rpc("v1_key_state", params: ["p_device_id": device.deviceID.wire], accountID: accountID)
        guard let state else {
            if device.bundle == nil {
                device.bundle = KeyBundle.generate(accountID: accountID)
                device.pendingRecoveryCode = ReaderCrypto.recoveryCode()
                try save()
            }
            guard let code = device.pendingRecoveryCode else { throw ReaderError.missingKey }
            return .saveRecoveryCode(code)
        }
        guard let wrapped = state.device_envelope else { return .recoveryRequired }
        let keys = try ReaderCrypto.unwrapForDevice(try Self.bytea(wrapped), accountID: accountID, deviceID: device.deviceID,
                                                    epoch: state.epoch, privateKey: .init(rawRepresentation: device.privateKey), challenge: device.challenge)
        device.bundle = keys
        try save()
        if let code = device.pendingRecoveryCode { return .saveRecoveryCode(code) }
        return .ready(device)
    }

    func confirmRecoverySaved() async throws -> LocalDevice {
        guard let keys = device.bundle, let code = device.pendingRecoveryCode else { throw ReaderError.missingKey }
        let publicKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: device.privateKey).publicKey.rawRepresentation
        let recovery = try ReaderCrypto.wrapRecovery(keys, code: code)
        let envelope = try ReaderCrypto.wrapForDevice(keys, deviceID: device.deviceID, recipientPublicKey: publicKey, challenge: device.challenge)
        struct Params: Encodable, Sendable { let p_device_id: String; let p_public_key: String; let p_recovery_package: String; let p_management_token: String; let p_device_envelope: String; let p_challenge: String }
        let created: Bool = try await backend.rpc("v1_bootstrap_keys", params: Params(p_device_id: device.deviceID.wire, p_public_key: Self.hex(publicKey),
            p_recovery_package: Self.hex(recovery), p_management_token: Self.hex(keys.managementToken), p_device_envelope: Self.hex(envelope), p_challenge: Self.hex(device.challenge)), accountID: accountID)
        if !created {
            // A timed-out successful bootstrap is recoverable through this exact
            // device envelope. A different first device must use enrollment.
            let state: KeyState? = try await backend.rpc("v1_key_state", params: ["p_device_id": device.deviceID.wire], accountID: accountID)
            guard let state, let wrapped = state.device_envelope else { throw ReaderError.missingKey }
            device.bundle = try ReaderCrypto.unwrapForDevice(try Self.bytea(wrapped), accountID: accountID, deviceID: device.deviceID,
                epoch: state.epoch, privateKey: .init(rawRepresentation: device.privateKey), challenge: device.challenge)
        }
        device.pendingRecoveryCode = nil
        try save()
        return device
    }

    func recover(code: String) async throws -> LocalDevice {
        if let pending = try pendingEnrollment(), let completed = try await finishApproved(pending) { return completed }
        let state: KeyState? = try await backend.rpc("v1_key_state", params: ["p_device_id": device.deviceID.wire], accountID: accountID)
        guard let state else { throw ReaderError.missingKey }
        let keys = try ReaderCrypto.recover(try Self.bytea(state.recovery_package), code: code, accountID: accountID)
        // Recovery enrolls a new identity; revoked device IDs are never revived.
        var pending = try pendingEnrollment()
        if pending == nil || pending!.candidate.bundle != keys || Date().timeIntervalSince(pending!.createdAt) > 14 * 60 {
            var candidate = LocalDevice.create(accountID: accountID, localStoreKey: device.localStoreKey)
            candidate.bundle = keys
            let publicKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: candidate.privateKey).publicKey.rawRepresentation
            let envelope = try ReaderCrypto.wrapForDevice(keys, deviceID: candidate.deviceID, recipientPublicKey: publicKey, challenge: candidate.challenge)
            pending = PendingEnrollment(requestID: UUID(), candidate: candidate, envelope: envelope, createdAt: Date())
            // Persist recipient private key, exact envelope, request identity and
            // the existing local-store key BEFORE either network operation.
            try KeychainVault.write(ReaderCrypto.encode(pending!), name: vaultName + ".pending-enrollment")
        }
        guard let pending else { throw ReaderError.missingKey }
        let candidate = pending.candidate
        let publicKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: candidate.privateKey).publicKey.rawRepresentation
        let _: UUID = try await backend.rpc("v1_request_enrollment", params: ["p_request_id": pending.requestID.wire, "p_device_id": candidate.deviceID.wire,
            "p_public_key": Self.hex(publicKey), "p_challenge": Self.hex(candidate.challenge)], accountID: accountID)
        struct Approval: Encodable, Sendable {
            let p_request_id: String; let p_epoch: Int; let p_management_token: String
            let p_expected_public_key: String; let p_expected_challenge: String; let p_envelope: String
        }
        try await backend.rpcVoid("v1_approve_enrollment", params: Approval(p_request_id: pending.requestID.wire, p_epoch: keys.epoch,
            p_management_token: Self.hex(keys.managementToken), p_expected_public_key: Self.hex(publicKey),
            p_expected_challenge: Self.hex(candidate.challenge), p_envelope: Self.hex(pending.envelope)), accountID: accountID)
        device = candidate; try save()
        try KeychainVault.delete(vaultName + ".pending-enrollment")
        return device
    }

    private func pendingEnrollment() throws -> PendingEnrollment? {
        guard let bytes = try KeychainVault.read(vaultName + ".pending-enrollment") else { return nil }
        let pending = try JSONDecoder().decode(PendingEnrollment.self, from: bytes)
        guard pending.candidate.accountID == accountID, pending.candidate.localStoreKey == device.localStoreKey else { throw ReaderError.wrongAccount }
        return pending
    }
    private func finishApproved(_ pending: PendingEnrollment) async throws -> LocalDevice? {
        let state: KeyState? = try await backend.rpc("v1_key_state", params: ["p_device_id": pending.candidate.deviceID.wire], accountID: accountID)
        guard let state, let wrapped = state.device_envelope else { return nil }
        var candidate = pending.candidate
        candidate.bundle = try ReaderCrypto.unwrapForDevice(try Self.bytea(wrapped), accountID: accountID, deviceID: candidate.deviceID,
            epoch: state.epoch, privateKey: .init(rawRepresentation: candidate.privateKey), challenge: candidate.challenge)
        device = candidate; try save()
        try KeychainVault.delete(vaultName + ".pending-enrollment")
        return device
    }

    private func save() throws { try KeychainVault.write(ReaderCrypto.encode(device), name: vaultName) }
    static func hex(_ data: Data) -> String { "\\x" + data.hex }
    static func bytea(_ string: String) throws -> Data {
        guard string.hasPrefix("\\x"), let data = Data(hex: String(string.dropFirst(2))) else { throw ReaderError.corruptData }
        return data
    }
}

struct EmptyResponse: Codable, Sendable {}

@MainActor
final class CloudSync {
    private let backend: BackendClient
    private(set) var device: LocalDevice
    private let keyManager: DeviceKeys
    private let store: EncryptedStore
    private let onDeviceChanged: @MainActor (LocalDevice) -> Void
    private var currentTask: Task<Void, Error>?

    init(backend: BackendClient, device: LocalDevice, keyManager: DeviceKeys, store: EncryptedStore,
         onDeviceChanged: @escaping @MainActor (LocalDevice) -> Void = { _ in }) {
        self.backend = backend; self.device = device; self.keyManager = keyManager; self.store = store; self.onDeviceChanged = onDeviceChanged
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
        try await backend.rpcVoid("v1_acknowledge_cursor", params: Acknowledgment(p_device_id: device.deviceID,
            p_cursor: await store.cursor(), p_management_token: DeviceKeys.hex(keys.managementToken)), accountID: device.accountID)
    }

    private func pull() async throws {
        struct Pull: Encodable, Sendable { let p_after: Int64; let p_limit = 200 }
        struct Row: Decodable, Sendable { let id: UUID; let device_id: UUID; let cursor: Int64; let epoch: Int; let format: Int; let ciphertext: String; let ciphertext_sha256: String }
        struct Page: Decodable, Sendable { let events: [Row]; let next_cursor: Int64; let has_more: Bool }
        while true {
            try Task.checkCancellation()
            let before = await store.cursor()
            let response: Page = try await backend.rpc("v2_pull_events", params: Pull(p_after: before), accountID: device.accountID)
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
