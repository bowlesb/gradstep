import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

@MainActor
final class RetirementSafetyTests: XCTestCase {
    func testSignOutClearsRecoveryStateBeforeAnotherAccountCanSignIn() async throws {
        let environment = "retirement-account-\(UUID().wire)"
        defer { try? KeychainVault.delete(environment + ".auth-session") }
        let configuration = BackendConfiguration(url: URL(string: "https://\(environment).invalid")!, anonKey: "fixture", environment: environment)
        let backend = try BackendClient(configuration: configuration)
        let model = ReaderModel(configuration: configuration, client: backend)
        model.needsRecovery = true; model.showRecovery = true; model.recoveryCode = "previous account recovery fixture"
        let oldSession = model.readerSessionID

        await model.signOut()

        XCTAssertNotEqual(model.readerSessionID, oldSession)
        XCTAssertFalse(model.needsRecovery)
        XCTAssertFalse(model.showRecovery)
        XCTAssertNil(model.recoveryCode)
        XCTAssertNil(model.email)
    }

    func testImmediateSameAccountSignInWaitsForTheRetiredWriterBeforeOpening() async throws {
        let fixture = RetirementFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let previous = ReaderLocalPersistence(), replacement = ReaderLocalPersistence(), retirement = ReaderRetirementQueue()
        let oldStore = try await previous.activate(url: fixture.url, accountID: fixture.account, localKey: fixture.localKey, keys: fixture.keys)
        let gate = RetirementWriteGate()
        let accepted = Task {
            try await previous.performWrite { store in
                await gate.hold()
                return [try await store.append(PrivateEvent(kind: .note, text: "Sent before sign-out"), deviceID: fixture.device)]
            }
        }
        await gate.waitUntilHeld()

        retirement.retire(sync: nil, persistence: previous)

        XCTAssertTrue(previous.isRetired, "Retirement returns immediately and refuses later writes")
        let activating = expectation(description: "The next session waits for retirement")
        let nextSession = Task {
            activating.fulfill()
            await retirement.wait()
            return try await replacement.activate(url: fixture.url, accountID: fixture.account, localKey: fixture.localKey, keys: fixture.keys)
        }
        await fulfillment(of: [activating], timeout: 3)
        XCTAssertNil(replacement.store, "A new SQLite writer must not open before the accepted old write commits")
        do {
            _ = try await previous.performWrite { _ in XCTFail("Retired helpers cannot accept work"); return [] }
            XCTFail("Expected retired writer rejection")
        } catch { XCTAssertEqual(error as? ReaderError, .storageUnavailable) }
        do {
            _ = try await previous.activate(url: fixture.url, accountID: fixture.account, localKey: fixture.localKey, keys: fixture.keys)
            XCTFail("A retired helper must not reopen a store")
        } catch { XCTAssertEqual(error as? ReaderError, .storageUnavailable) }

        await gate.release()
        let saved = try await accepted.value
        let newStore = try await nextSession.value
        XCTAssertFalse(newStore === oldStore)
        let restored = await newStore.snapshot()
        XCTAssertEqual(restored.generation, 1)
        XCTAssertEqual(restored.pendingCount, 1)
        XCTAssertEqual(Set(restored.state.events.keys), Set(saved.map(\.id)))
        _ = try await replacement.performWrite { store in
            [try await store.append(PrivateEvent(kind: .note, text: "Sent after signing back in"), deviceID: fixture.device)]
        }
        let final = await newStore.snapshot()
        XCTAssertEqual(final.generation, 2); XCTAssertEqual(final.state.events.count, 2)
    }

    func testRapidAccountChangesDrainEveryRetiringSession() async throws {
        let first = RetirementFixture(), second = RetirementFixture()
        defer {
            try? FileManager.default.removeItem(at: first.folder)
            try? FileManager.default.removeItem(at: second.folder)
        }
        let firstSession = ReaderLocalPersistence(), secondSession = ReaderLocalPersistence()
        let retirement = ReaderRetirementQueue(), returningSession = ReaderLocalPersistence()
        _ = try await firstSession.activate(url: first.url, accountID: first.account, localKey: first.localKey, keys: first.keys)
        _ = try await secondSession.activate(url: second.url, accountID: second.account, localKey: second.localKey, keys: second.keys)
        let firstGate = RetirementWriteGate(), secondGate = RetirementWriteGate()
        let firstWrite = Task {
            try await firstSession.performWrite { store in
                await firstGate.hold()
                return [try await store.append(PrivateEvent(kind: .note, text: "First account pending work"), deviceID: first.device)]
            }
        }
        let secondWrite = Task {
            try await secondSession.performWrite { store in
                await secondGate.hold()
                return [try await store.append(PrivateEvent(kind: .note, text: "Second account pending work"), deviceID: second.device)]
            }
        }
        await firstGate.waitUntilHeld(); await secondGate.waitUntilHeld()
        retirement.retire(sync: nil, persistence: firstSession)
        retirement.retire(sync: nil, persistence: secondSession)
        let waiting = expectation(description: "The returning session waits for the retirement chain")
        let returning = Task {
            waiting.fulfill()
            await retirement.wait()
            return try await returningSession.activate(url: first.url, accountID: first.account, localKey: first.localKey, keys: first.keys)
        }
        await fulfillment(of: [waiting], timeout: 3)
        await firstGate.release()
        _ = try await firstWrite.value
        XCTAssertNil(returningSession.store, "Completing the first retirement cannot clear a newer pending retirement")
        await secondGate.release()
        _ = try await secondWrite.value
        let restored = try await returning.value
        let snapshot = await restored.snapshot()
        XCTAssertEqual(snapshot.state.events.count, 1)
        XCTAssertEqual(snapshot.state.events.values.first?.payload.text, "First account pending work")
        XCTAssertTrue(firstSession.isRetired); XCTAssertTrue(secondSession.isRetired)
    }

    func testRetiringAnActivationThatWaitsForAnAppendPreventsItsLateReuse() async throws {
        let fixture = RetirementFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let persistence = ReaderLocalPersistence(), retirement = ReaderRetirementQueue()
        _ = try await persistence.activate(url: fixture.url, accountID: fixture.account, localKey: fixture.localKey, keys: fixture.keys)
        let gate = RetirementWriteGate()
        let write = Task {
            try await persistence.performWrite { store in
                await gate.hold()
                return [try await store.append(PrivateEvent(kind: .note, text: "Keep the accepted write"), deviceID: fixture.device)]
            }
        }
        await gate.waitUntilHeld()
        var rotated = fixture.keys; try rotated.rotate()
        let started = expectation(description: "An old activation is suspended behind its write")
        let activation = Task {
            started.fulfill()
            return try await persistence.activate(url: fixture.url, accountID: fixture.account, localKey: fixture.localKey, keys: rotated)
        }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(persistence.isActivating)

        retirement.retire(sync: nil, persistence: persistence)
        await gate.release()
        let saved = try await write.value
        await retirement.wait()
        do { _ = try await activation.value; XCTFail("Retirement must invalidate an activation already waiting for writes") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(persistence.isActivating)
        XCTAssertTrue(persistence.isRetired)
        XCTAssertEqual(saved.first?.epoch, fixture.keys.epoch)
        let replacement = ReaderLocalPersistence()
        let restored = try await replacement.activate(url: fixture.url, accountID: fixture.account, localKey: fixture.localKey, keys: fixture.keys)
        let snapshot = await restored.snapshot()
        XCTAssertEqual(snapshot.generation, 1); XCTAssertEqual(snapshot.pendingCount, 1)
    }
}

private struct RetirementFixture: Sendable {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("retirement-\(UUID().wire)", isDirectory: true)
    let account = UUID(), device = UUID(), localKey = ReaderCrypto.randomKey()
    let keys: KeyBundle
    var url: URL { folder.appendingPathComponent("state.sqlite") }
    init() { keys = KeyBundle.generate(accountID: account) }
}

private actor RetirementWriteGate {
    private var held = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        await withCheckedContinuation { continuation in
            blocked = continuation; held = true
            for arrival in arrivals { arrival.resume() }
            arrivals = []
        }
    }
    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
    func release() { blocked?.resume(); blocked = nil }
}
