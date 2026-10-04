import Dispatch
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
        XCTAssertEqual(restored.generation, 2, "One accepted append plus the fresh writer's ownership fence")
        XCTAssertEqual(restored.pendingCount, 1)
        XCTAssertEqual(Set(restored.state.events.keys), Set(saved.map(\.id)))
        _ = try await replacement.performWrite { store in
            [try await store.append(PrivateEvent(kind: .note, text: "Sent after signing back in"), deviceID: fixture.device)]
        }
        let final = await newStore.snapshot()
        XCTAssertEqual(final.generation, restored.generation + 1); XCTAssertEqual(final.state.events.count, 2)
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
        XCTAssertEqual(snapshot.generation, 2, "The replacement advances ownership after the accepted append")
        XCTAssertEqual(snapshot.pendingCount, 1)
    }

    func testOverlappingActivationWaitAppliesTheNewestKeysOnTheSameWriter() async throws {
        let fixture = RetirementFixture(), persistence = ReaderLocalPersistence(), gate = RetirementWriteGate()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.folder) }
        let original = try await persistence.activate(url: fixture.url, accountID: fixture.account,
            localKey: fixture.localKey, keys: fixture.keys)
        var firstKeys = fixture.keys; try firstKeys.rotate()
        var latestKeys = firstKeys; try latestKeys.rotate()
        let accepted = try persistence.acceptWrite { store in
            await gate.hold()
            return try await store.append(PrivateEvent(kind: .note, text: "Accepted before key activation"), deviceID: fixture.device)
        }
        await gate.waitUntilHeld()
        let firstEntered = expectation(description: "The first key activation waits for accepted work")
        let first = Task {
            firstEntered.fulfill()
            return try await persistence.activate(url: fixture.url, accountID: fixture.account,
                localKey: fixture.localKey, keys: firstKeys)
        }
        await fulfillment(of: [firstEntered], timeout: 3)
        XCTAssertTrue(persistence.isActivating)
        let replacementEntered = expectation(description: "The replacement joins the active key update")
        var resumedDuringActivation: Bool?
        let replacement = Task {
            replacementEntered.fulfill()
            await persistence.waitForActivation()
            resumedDuringActivation = persistence.isActivating
            return try await persistence.activate(url: fixture.url, accountID: fixture.account,
                localKey: fixture.localKey, keys: latestKeys)
        }
        await fulfillment(of: [replacementEntered], timeout: 3)
        XCTAssertNil(resumedDuringActivation)
        await gate.release()
        let before = try await accepted.value
        let firstStore = try await first.value, latestStore = try await replacement.value
        XCTAssertFalse(try XCTUnwrap(resumedDuringActivation))
        XCTAssertTrue(firstStore === original)
        XCTAssertTrue(latestStore === original, "Same-account activation must not open a second SQLite writer")
        XCTAssertEqual(before.epoch, fixture.keys.epoch)
        let after = try await persistence.performWrite { store in
            [try await store.append(PrivateEvent(kind: .note, text: "Accepted after the winning activation"), deviceID: fixture.device)]
        }
        XCTAssertEqual(after.first?.epoch, latestKeys.epoch)
        let snapshot = await original.snapshot()
        XCTAssertEqual(snapshot.state.events.count, 2)
        XCTAssertFalse(persistence.isActivating)
    }

    func testCancelledReplacementWaitDoesNotShortenTheAcceptedActivationLifetime() async throws {
        let fixture = RetirementFixture(), persistence = ReaderLocalPersistence(), gate = RetirementWriteGate()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.folder) }
        _ = try await persistence.activate(url: fixture.url, accountID: fixture.account,
            localKey: fixture.localKey, keys: fixture.keys)
        var acceptedKeys = fixture.keys; try acceptedKeys.rotate()
        var cancelledKeys = acceptedKeys; try cancelledKeys.rotate()
        let write = try persistence.acceptWrite { store in
            await gate.hold()
            return try await store.append(PrivateEvent(kind: .note, text: "An accepted write still drains"), deviceID: fixture.device)
        }
        await gate.waitUntilHeld()
        let activationEntered = expectation(description: "Accepted activation is pending")
        let activation = Task {
            activationEntered.fulfill()
            return try await persistence.activate(url: fixture.url, accountID: fixture.account,
                localKey: fixture.localKey, keys: acceptedKeys)
        }
        await fulfillment(of: [activationEntered], timeout: 3)
        XCTAssertTrue(persistence.isActivating)
        let waiterEntered = expectation(description: "Cancelled replacement has joined the prior activation")
        var resumedDuringActivation: Bool?
        let replacement = Task {
            waiterEntered.fulfill()
            await persistence.waitForActivation()
            resumedDuringActivation = persistence.isActivating
            try Task.checkCancellation()
            return try await persistence.activate(url: fixture.url, accountID: fixture.account,
                localKey: fixture.localKey, keys: cancelledKeys)
        }
        await fulfillment(of: [waiterEntered], timeout: 3)
        replacement.cancel()
        XCTAssertNil(resumedDuringActivation)
        await gate.release()
        _ = try await write.value
        _ = try await activation.value
        do { _ = try await replacement.value; XCTFail("The cancelled replacement cannot apply its keys") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(try XCTUnwrap(resumedDuringActivation), "Cancellation is checked only after the prior owner has drained")
        let saved = try await persistence.performWrite { store in
            [try await store.append(PrivateEvent(kind: .note, text: "Continue on the last accepted key set"), deviceID: fixture.device)]
        }
        XCTAssertEqual(saved.first?.epoch, acceptedKeys.epoch)
        XCTAssertFalse(persistence.isActivating)
    }

    func testRetirementJoinsAnActiveCoreKeyUpdateBeforeOpeningTheReplacementWriter() async throws {
        let fixture = RetirementFixture(), previous = ReaderLocalPersistence(), replacement = ReaderLocalPersistence()
        let retirement = ReaderRetirementQueue(), gate = RetirementActorGate()
        defer { gate.release() }
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.folder) }
        let original = try await previous.activate(url: fixture.url, accountID: fixture.account,
            localKey: fixture.localKey, keys: fixture.keys)
        var nextKeys = fixture.keys; try nextKeys.rotate()
        // Unlike a pending append, this occupied actor is not registered as an
        // accepted persistence write. Retirement must join activation itself.
        let occupied = Task.detached { await original.holdRetirementFixture(gate) }
        await fulfillment(of: [gate.entered], timeout: 3)
        let activationEntered = expectation(description: "Key update is accepted by the local writer")
        let activation = Task {
            activationEntered.fulfill()
            return try await previous.activate(url: fixture.url, accountID: fixture.account,
                localKey: fixture.localKey, keys: nextKeys)
        }
        await fulfillment(of: [activationEntered], timeout: 3)
        XCTAssertTrue(previous.isActivating)
        retirement.retire(sync: nil, persistence: previous)
        XCTAssertTrue(previous.isRetired)
        let resumedTooEarly = expectation(description: "Retirement cannot complete while updateKeys is still queued")
        resumedTooEarly.isInverted = true
        var released = false
        var resumedDuringActivation: Bool?
        let returning = Task {
            await retirement.wait()
            resumedDuringActivation = previous.isActivating
            if !released, previous.isActivating { resumedTooEarly.fulfill() }
            return try await replacement.activate(url: fixture.url, accountID: fixture.account,
                localKey: fixture.localKey, keys: nextKeys)
        }
        await fulfillment(of: [resumedTooEarly], timeout: 0.05)
        if previous.isActivating { XCTAssertNil(replacement.store) }
        released = true; gate.release()
        let releasedBeforeWatchdog = await occupied.value
        XCTAssertTrue(releasedBeforeWatchdog, "The actor gate's bounded fail-safe must not be the release mechanism")
        do { _ = try await activation.value; XCTFail("A retired activation cannot return an active writer") }
        catch { XCTAssertTrue(error is CancellationError) }
        let newStore = try await returning.value
        XCTAssertFalse(try XCTUnwrap(resumedDuringActivation))
        XCTAssertFalse(newStore === original)
        XCTAssertFalse(previous.isActivating)
        let saved = try await replacement.performWrite { store in
            [try await store.append(PrivateEvent(kind: .note, text: "Only the replacement may now write"), deviceID: fixture.device)]
        }
        XCTAssertEqual(saved.first?.epoch, nextKeys.epoch)
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

/// Test-only actor occupancy models the suspension at the real updateKeys hop.
/// It never blocks the main actor and has an independent bounded release.
private final class RetirementActorGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Core actor is occupied before updateKeys")
    private let semaphore = DispatchSemaphore(value: 0)
    func hold() -> Bool {
        entered.fulfill()
        return semaphore.wait(timeout: .now() + 10) == .success
    }
    func release() { semaphore.signal() }
}

private extension EncryptedStore {
    func holdRetirementFixture(_ gate: RetirementActorGate) -> Bool { gate.hold() }
}
