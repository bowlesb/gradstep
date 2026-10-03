import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

@MainActor
final class LiveSyncTests: XCTestCase {
    func testTwoDeviceRecoveryOfflineEditsAndLostAcknowledgment() async throws {
        let variables = ProcessInfo.processInfo.environment
        guard let email = variables["SCIENCE_READER_LIVE_EMAIL"], let password = variables["SCIENCE_READER_LIVE_PASSWORD"],
              let source = variables["SCIENCE_READER_LIVE_ACCOUNT"], let account = UUID(uuidString: source) else {
            throw XCTSkip("Run scripts/check-native-sync.mjs for the disposable hosted fixture.")
        }
        guard let bundled = BackendConfiguration.bundled(), bundled.url.host == "coxhjvqpflgxkleydati.supabase.co" else { return XCTFail("Staging is required") }
        let environments = ["unit-sync-a-\(UUID().wire)", "unit-sync-b-\(UUID().wire)"]
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        defer {
            for environment in environments {
                for suffix in [".auth-session", ".\(account.wire).device-keys", ".\(account.wire).device-keys.pending-enrollment"] { try? KeychainVault.delete(environment + suffix) }
                let directory = root.appendingPathComponent(environment, isDirectory: true)
                if FileManager.default.fileExists(atPath: directory.path) { try? FileManager.default.removeItem(at: directory) }
            }
        }
        let clients = try environments.map { try BackendClient(configuration: BackendConfiguration(url: bundled.url, anonKey: bundled.anonKey, environment: $0)) }
        print("Native sync phase: sign in two clients")
        for client in clients { let user = try await client.signIn(email: email, password: password); XCTAssertEqual(user.id, account) }
        print("Native sync phase: bootstrap first device")
        let managerA = try DeviceKeys(backend: clients[0], accountID: account, environment: environments[0])
        guard case .saveRecoveryCode(let code) = try await managerA.prepare() else { return XCTFail("New account must bootstrap device keys") }
        let deviceA = try await managerA.confirmRecoverySaved()
        print("Native sync phase: recover second device")
        let managerB = try DeviceKeys(backend: clients[1], accountID: account, environment: environments[1])
        guard case .recoveryRequired = try await managerB.prepare() else { return XCTFail("Account login alone must not grant history keys") }
        let deviceB = try await managerB.recover(code: code)
        XCTAssertNotEqual(deviceA.deviceID, deviceB.deviceID)
        XCTAssertEqual(deviceA.bundle, deviceB.bundle)
        let keys = try XCTUnwrap(deviceA.bundle)
        let pathA = root.appendingPathComponent(environments[0], isDirectory: true).appendingPathComponent("state.sqlite")
        let pathB = root.appendingPathComponent(environments[1], isDirectory: true).appendingPathComponent("state.sqlite")
        print("Native sync phase: open encrypted stores")
        let storeA = try EncryptedStore(url: pathA, accountID: account, localKey: deviceA.localStoreKey, keys: keys)
        let storeB = try EncryptedStore(url: pathB, accountID: account, localKey: deviceB.localStoreKey, keys: keys)
        let syncA = CloudSync(backend: clients[0], device: deviceA, keyManager: managerA, store: storeA)
        let syncB = CloudSync(backend: clients[1], device: deviceB, keyManager: managerB, store: storeB)
        let noteID = UUID()
        let original = try await storeA.append(PrivateEvent(kind: .note, entityID: noteID, text: "Shared encrypted baseline"), deviceID: deviceA.deviceID)
        print("Native sync phase: initial catch-up")
        try await syncA.synchronize(); try await syncB.synchronize()
        let firstA = await storeA.state(), firstB = await storeB.state()
        XCTAssertEqual(firstA.events, firstB.events)

        // Both working copies edit the same revision before either syncs.
        try await storeA.append(PrivateEvent(kind: .note, entityID: noteID, parents: [original.id], text: "Offline edit A"), deviceID: deviceA.deviceID)
        try await storeB.append(PrivateEvent(kind: .note, entityID: noteID, parents: [original.id], text: "Offline edit B"), deviceID: deviceB.deviceID)
        print("Native sync phase: concurrent offline edits")
        async let fromA: Void = syncA.synchronize()
        async let fromB: Void = syncB.synchronize()
        try await fromA; try await fromB
        let cursorA = await storeA.cursor(), cursorB = await storeB.cursor()
        if cursorA < cursorB { try await syncA.synchronize() }
        if cursorB < cursorA { try await syncB.synchronize() }
        let a = await storeA.state(), b = await storeB.state()
        XCTAssertEqual(a.events, b.events)
        XCTAssertEqual(Set(a.revisions(for: noteID).compactMap { $0.payload.text }), ["Offline edit A", "Offline edit B"])

        // The server commits, then the client 'crashes' before recording its ack.
        print("Native sync phase: interrupted acknowledgment")
        let lost = try await storeA.append(PrivateEvent(kind: .note, text: "Committed but not acknowledged locally"), deviceID: deviceA.deviceID)
        struct Push: Encodable, Sendable { let p_device_id: UUID; let p_id: UUID; let p_epoch: Int; let p_format: Int; let p_ciphertext: String; let p_management_token: String }
        let committedCursor: Int64 = try await clients[0].rpc("v1_append_event", params: Push(p_device_id: lost.deviceID, p_id: lost.id,
            p_epoch: lost.epoch, p_format: lost.format, p_ciphertext: DeviceKeys.hex(lost.ciphertext), p_management_token: DeviceKeys.hex(keys.managementToken)), accountID: account)
        await syncA.stop()
        let reopened = try EncryptedStore(url: pathA, accountID: account, localKey: deviceA.localStoreKey, keys: keys)
        let pending = await reopened.pending(); XCTAssertEqual(pending, [lost])
        let restarted = CloudSync(backend: clients[0], device: deviceA, keyManager: managerA, store: reopened)
        try await restarted.synchronize(); try await syncB.synchronize()
        let remaining = await reopened.pending(), finalA = await reopened.state(), finalB = await storeB.state(), cursor = await reopened.cursor()
        XCTAssertTrue(remaining.isEmpty); XCTAssertEqual(cursor, committedCursor)
        XCTAssertEqual(finalA.events, finalB.events); XCTAssertEqual(finalA.events.count, 4)
        XCTAssertEqual(try managerA.cachedDevice()?.bundle, keys)
        struct DeviceRow: Decodable, Sendable { let id: UUID }
        let devices: [DeviceRow] = try await clients[0].rpc("v1_devices", params: EmptyResponse(), accountID: account)
        XCTAssertEqual(Set(devices.map(\.id)), [deviceA.deviceID, deviceB.deviceID])
        await restarted.stop(); await syncB.stop()
        for client in clients { try await client.signOut() }
    }
}
