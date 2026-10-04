import CryptoKit
import Foundation
import ScienceReaderCore
import SQLite3
import XCTest
@testable import ScienceReader

@MainActor
final class ReaderBundleCoordinatorTests: XCTestCase {
    func testInstalledBundleReopensThroughNativeAdmissionAfterFreshWriterActivation() async throws {
        let fixture = try OfflineBundleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let first = ReaderLocalPersistence()
        _ = try await fixture.activate(first)
        let coordinator = ReaderBundleCoordinator(scope: fixture.scope, persistence: first)
        _ = try await coordinator.observe(fixture.observation()).value
        let saved = try await fixture.install(coordinator).value
        let retirement = ReaderRetirementQueue()
        retirement.retire(sync: nil, persistence: first, bundles: coordinator)
        await retirement.wait()

        let replacement = ReaderLocalPersistence()
        let reopenedStore = try await fixture.activate(replacement)
        let reopened = ReaderBundleCoordinator(scope: fixture.scope, persistence: replacement)
        let restoration = try await reopened.restore()
        XCTAssertEqual(try restoration.presentation.get()?.committedCursor, 1)
        let listing = try restoration.installations.get()
        XCTAssertEqual(listing.installations.count, 1)
        let read = try await reopened.open(try XCTUnwrap(reopened.localCopy(documentID: fixture.document, artifactID: fixture.artifact))).value
        XCTAssertEqual(read.installation.id, saved.id)
        XCTAssertEqual(read.bundle.manifestData, fixture.bundle.manifestData)
        XCTAssertEqual(read.bundle.index.equations.count, 7)
        XCTAssertEqual(read.bundle.index.figures.count, 2)
        let snapshot = await reopenedStore.snapshot()
        XCTAssertTrue(snapshot.state.events.isEmpty, "Derived reading bytes must not become private sync events")
    }

    func testCancelledVerificationReleasesItsTicketAndAllowsAnExplicitRetry() async throws {
        let fixture = try OfflineBundleFixture(), persistence = ReaderLocalPersistence(), gate = BundleVerificationGate()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let store = try await fixture.activate(persistence)
        let coordinator = ReaderBundleCoordinator(scope: fixture.scope, persistence: persistence, verify: { try await gate.verify($0) })
        let installing = try fixture.install(coordinator)
        await gate.waitUntilHeld()
        coordinator.cancelInstall()
        XCTAssertThrowsError(try fixture.install(coordinator)) { XCTAssertEqual($0 as? OfflineCacheError, .installBusy) }
        await gate.release()
        await expectCancellation(installing)
        let empty = try await store.listInstalledReaderBundles(scope: fixture.scope)
        XCTAssertTrue(empty.installations.isEmpty)
        let retried = try await fixture.install(coordinator).value
        XCTAssertTrue(retried.canOpen)
    }

    func testRetirementJoinsVerificationBeforeOpeningTheSameAccountAgain() async throws {
        let fixture = try OfflineBundleFixture(), persistence = ReaderLocalPersistence(), replacement = ReaderLocalPersistence()
        let retirement = ReaderRetirementQueue(), gate = BundleVerificationGate()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        _ = try await fixture.activate(persistence)
        let coordinator = ReaderBundleCoordinator(scope: fixture.scope, persistence: persistence, verify: { try await gate.verify($0) })
        let installing = try fixture.install(coordinator)
        await gate.waitUntilHeld()
        retirement.retire(sync: nil, persistence: persistence, bundles: coordinator)
        let waiting = expectation(description: "Replacement waits behind reader verification")
        let next = Task {
            waiting.fulfill()
            await retirement.wait()
            return try await fixture.activate(replacement)
        }
        await fulfillment(of: [waiting], timeout: 3)
        XCTAssertTrue(persistence.isRetired)
        XCTAssertNil(replacement.store)
        await gate.release()
        await expectCancellation(installing)
        let fresh = try await next.value
        let listing = try await fresh.listInstalledReaderBundles(scope: fixture.scope)
        XCTAssertTrue(listing.installations.isEmpty)
    }

    func testMutableCallerBytesAreOwnedBeforeTheInstallTaskStarts() async throws {
        let fixture = try OfflineBundleFixture(), persistence = ReaderLocalPersistence()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        _ = try await fixture.activate(persistence)
        let coordinator = ReaderBundleCoordinator(scope: fixture.scope, persistence: persistence)
        let manifest = fixture.bundle.manifestData, path = fixture.bundle.manifest.entrypoint
        let original = try XCTUnwrap(fixture.members[path])
        let manifestPointer = UnsafeMutableRawPointer.allocate(byteCount: manifest.count, alignment: 1)
        let memberPointer = UnsafeMutableRawPointer.allocate(byteCount: original.count, alignment: 1)
        defer { manifestPointer.deallocate(); memberPointer.deallocate() }
        manifest.withUnsafeBytes { manifestPointer.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        original.withUnsafeBytes { memberPointer.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        var members = fixture.members
        members[path] = Data(bytesNoCopy: memberPointer, count: original.count, deallocator: .none)
        let installing = try coordinator.install(binding: fixture.binding,
            manifestData: Data(bytesNoCopy: manifestPointer, count: manifest.count, deallocator: .none), members: members)
        manifestPointer.initializeMemory(as: UInt8.self, repeating: 0, count: manifest.count)
        memberPointer.initializeMemory(as: UInt8.self, repeating: 0, count: original.count)
        let installed = try await installing.value
        let opened = try await coordinator.open(installed).value
        XCTAssertEqual(opened.bundle.manifestData, manifest)
        XCTAssertEqual(opened.bundle.data(for: path), original)
    }

    func testCoreValidBundleWithFalseImageDimensionsCannotBeInstalled() async throws {
        let fixture = try OfflineBundleFixture(), persistence = ReaderLocalPersistence()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let store = try await fixture.activate(persistence)
        let coordinator = ReaderBundleCoordinator(scope: fixture.scope, persistence: persistence)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.bundle.manifestData) as? [String: Any])
        var members = try XCTUnwrap(manifest["members"] as? [[String: Any]])
        let image = try XCTUnwrap(members.firstIndex { $0["role"] as? String == "image" })
        members[image]["width"] = (members[image]["width"] as! Int) + 1
        manifest["members"] = members
        let raw = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        _ = try VerifiedReaderBundle.verify(manifest: raw, expectedSHA256: digest, members: fixture.members)
        let binding = try ReaderArtifactBinding(scope: fixture.scope, documentID: fixture.document,
                                               artifactID: fixture.artifact, manifestSHA256: digest)
        do {
            _ = try await coordinator.install(binding: binding, manifestData: raw, members: fixture.members).value
            XCTFail("Core byte verification alone cannot admit an image")
        } catch { XCTAssertEqual(error as? ReaderBundleError, .invalidResource) }
        let listing = try await store.listInstalledReaderBundles(scope: fixture.scope)
        XCTAssertTrue(listing.installations.isEmpty)
        _ = try await fixture.install(coordinator).value
    }

    func testRemoteOutagePreservesLocalOpenAndQuarantineBlocksBeforeDiskAcknowledgement() async throws {
        let fixture = try OfflineBundleFixture(), persistence = ReaderLocalPersistence()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        _ = try await fixture.activate(persistence)
        let coordinator = ReaderBundleCoordinator(scope: fixture.scope, persistence: persistence)
        _ = try await coordinator.observe(fixture.observation()).value
        _ = try await fixture.install(coordinator).value
        _ = try await coordinator.observe(fixture.observation(state: 2, availability: "unavailable", availabilityRevision: 2)).value
        let available = try XCTUnwrap(coordinator.localCopy(documentID: fixture.document, artifactID: fixture.artifact))
        _ = try await coordinator.open(available).value
        let save = try coordinator.observe(fixture.observation(state: 3, availability: "quarantined", availabilityRevision: 3))
        XCTAssertNil(coordinator.localCopy(documentID: fixture.document, artifactID: fixture.artifact))
        XCTAssertThrowsError(try coordinator.open(available)) { XCTAssertEqual($0 as? OfflineCacheError, .blocked) }
        _ = try await save.value
        _ = try await coordinator.observe(fixture.observation(state: 4, availability: "unavailable", availabilityRevision: 4)).value
        XCTAssertNil(coordinator.localCopy(documentID: fixture.document, artifactID: fixture.artifact))
        _ = try await coordinator.observe(fixture.observation(state: 5, availability: "available", availabilityRevision: 5)).value
        let admitted = try XCTUnwrap(coordinator.localCopy(documentID: fixture.document, artifactID: fixture.artifact))
        _ = try await coordinator.open(admitted).value
    }

    func testQuarantineDuringNativeOpenCannotPublishTheOlderVerifiedHandle() async throws {
        let fixture = try OfflineBundleFixture(), persistence = ReaderLocalPersistence()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        _ = try await fixture.activate(persistence)
        let installer = ReaderBundleCoordinator(scope: fixture.scope, persistence: persistence)
        _ = try await installer.observe(fixture.observation()).value
        let installed = try await fixture.install(installer).value
        installer.close(); await installer.stop()
        let gate = BundleVerificationGate()
        let reader = ReaderBundleCoordinator(scope: fixture.scope, persistence: persistence, verify: { try await gate.verify($0) })
        _ = try await reader.restore()
        let opening = try reader.open(installed)
        await gate.waitUntilHeld()
        _ = try await reader.observe(fixture.observation(state: 2, availability: "quarantined", availabilityRevision: 2)).value
        await gate.release()
        await expectCancellation(opening)
        XCTAssertNil(reader.localCopy(documentID: fixture.document, artifactID: fixture.artifact))
    }

    func testDelayedDirectoryReadCannotResurrectARemovedInstallation() async throws {
        let fixture = try OfflineBundleFixture(), persistence = ReaderLocalPersistence(), delivery = BundleDirectoryGate()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        _ = try await fixture.activate(persistence)
        let coordinator = ReaderBundleCoordinator(scope: fixture.scope, persistence: persistence,
            readDirectory: { try await delivery.read($0, scope: $1) })
        _ = try await coordinator.observe(fixture.observation()).value
        let installed = try await fixture.install(coordinator).value
        await delivery.arm()
        let earlier = try coordinator.observe(fixture.observation())
        await delivery.waitUntilHeld()
        try await coordinator.remove(installed).value
        XCTAssertNil(coordinator.localCopy(documentID: fixture.document, artifactID: fixture.artifact))
        await delivery.release()
        _ = try await earlier.value
        XCTAssertNil(coordinator.localCopy(documentID: fixture.document, artifactID: fixture.artifact))
        XCTAssertThrowsError(try coordinator.open(installed)) { XCTAssertEqual($0 as? OfflineCacheError, .notInstalled) }
    }

    func testIdenticalRefreshDoesNotCancelAnExplicitInstall() async throws {
        let fixture = try OfflineBundleFixture(), persistence = ReaderLocalPersistence(), gate = BundleVerificationGate()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        _ = try await fixture.activate(persistence)
        let coordinator = ReaderBundleCoordinator(scope: fixture.scope, persistence: persistence,
            verify: { try await gate.verify($0) })
        _ = try await coordinator.observe(fixture.observation()).value
        let installing = try fixture.install(coordinator)
        await gate.waitUntilHeld()
        _ = try await coordinator.observe(fixture.observation()).value
        await gate.release()
        let installed = try await installing.value
        XCTAssertTrue(coordinator.permits(installed))
    }

    func testOrdinaryRemoteOutageDoesNotDiscardAnInFlightVerifiedOpen() async throws {
        let fixture = try OfflineBundleFixture(), persistence = ReaderLocalPersistence()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        _ = try await fixture.activate(persistence)
        let installer = ReaderBundleCoordinator(scope: fixture.scope, persistence: persistence)
        _ = try await installer.observe(fixture.observation()).value
        let installed = try await fixture.install(installer).value
        installer.close(); await installer.stop()
        let gate = BundleVerificationGate()
        let reader = ReaderBundleCoordinator(scope: fixture.scope, persistence: persistence, verify: { try await gate.verify($0) })
        _ = try await reader.restore()
        let opening = try reader.open(installed)
        await gate.waitUntilHeld()
        _ = try await reader.observe(fixture.observation(state: 2, availability: "unavailable", availabilityRevision: 2)).value
        await gate.release()
        let opened = try await opening.value
        XCTAssertEqual(opened.installation.revision, installed.revision)
        XCTAssertEqual(opened.bundle.manifestSHA256, fixture.bundle.manifestSHA256)
    }

    func testFailedQuarantineCheckpointCannotBeSkippedByALaterOutage() async throws {
        let fixture = try OfflineBundleFixture(), persistence = ReaderLocalPersistence()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let store = try await fixture.activate(persistence)
        var issue: String?
        let coordinator = ReaderBundleCoordinator(scope: fixture.scope, persistence: persistence, report: { issue = $0 })
        _ = try await coordinator.observe(fixture.observation()).value
        _ = try await fixture.install(coordinator).value
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TRIGGER refuse_checkpoint BEFORE UPDATE ON local_library_cache_checkpoint BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END", nil, nil, nil), SQLITE_OK)
        let quarantine = try coordinator.observe(fixture.observation(state: 2, availability: "quarantined", availabilityRevision: 2))
        let outage = try coordinator.observe(fixture.observation(state: 3, availability: "unavailable", availabilityRevision: 3))
        for save in [quarantine, outage] {
            do { _ = try await save.value; XCTFail("The ordered checkpoint must stop at its first failure") }
            catch { }
        }
        await coordinator.waitUntilIdle()
        XCTAssertNil(coordinator.localCopy(documentID: fixture.document, artifactID: fixture.artifact))
        XCTAssertThrowsError(try fixture.install(coordinator)) { XCTAssertEqual($0 as? ReaderError, .storageUnavailable) }
        let prior = try await store.cachedLibraryPresentation(scope: fixture.scope)
        XCTAssertEqual(prior?.committedCursor, 1, "The failed block and its successor must both remain unacknowledged")
        XCTAssertEqual(sqlite3_exec(database, "DROP TRIGGER refuse_checkpoint", nil, nil, nil), SQLITE_OK)
        _ = try await persistence.performWrite { store in
            [try await store.append(PrivateEvent(kind: .note, text: "Private notes survive an optional cache failure"), deviceID: UUID())]
        }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.state.events.count, 1)
        XCTAssertNotNil(issue)
    }

    private func expectCancellation<T: Sendable>(_ task: Task<T, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("Expected cancelled old operation", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected \(error)", file: file, line: line) }
    }
}

private struct OfflineBundleFixture: Sendable {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offline-bundle-\(UUID().wire)", isDirectory: true)
    let account = UUID(), document = UUID(), artifact = UUID(), item = UUID()
    let approval = UUID(), version = UUID(), metadata = UUID(), original = UUID()
    let localKey = ReaderCrypto.randomKey()
    let keys: KeyBundle
    let scope: LibraryCommandScope
    let bundle: VerifiedReaderBundle
    let binding: ReaderArtifactBinding
    let members: [String: Data]
    var url: URL { folder.appendingPathComponent("state.sqlite") }
    init() throws {
        keys = KeyBundle.generate(accountID: account)
        scope = try LibraryCommandScope(accountID: account, deploymentID: "https://offline-fixture.invalid")
        let loaded = try ReaderBundleLoader.sample()
        bundle = loaded
        binding = try ReaderArtifactBinding(scope: scope, documentID: document, artifactID: artifact, manifestSHA256: loaded.manifestSHA256)
        members = Dictionary(uniqueKeysWithValues: loaded.manifest.members.map { ($0.path, loaded.data(for: $0.path)!) })
    }
    @MainActor func activate(_ persistence: ReaderLocalPersistence) async throws -> EncryptedStore {
        try await persistence.activate(url: url, accountID: account, localKey: localKey, keys: keys)
    }
    @MainActor func install(_ coordinator: ReaderBundleCoordinator) throws -> Task<InstalledReaderBundle, Error> {
        try coordinator.install(binding: binding, manifestData: bundle.manifestData, members: members)
    }
    func observation(state: Int64 = 1, availability: String = "available", availabilityRevision: Int64 = 1) throws -> LibraryCompleteObservation {
        let row: [String: Any] = ["kind": "item", "id": item.wire, "document_id": document.wire, "created_seq": 1, "state_seq": state,
            "membership_revision": 1, "visible": true, "added_at": "2026-10-03T10:00:00Z", "last_remove_seq": 0,
            "approval_id": approval.wire, "version_id": version.wire, "metadata_id": metadata.wire, "source": "arxiv",
            "source_id": "2404.00001", "source_revision": 1, "metadata": ["title": "Authored offline fixture", "authors": ["Fixture"],
                "abstract": "Synthetic library record for native persistence tests.", "categories": ["cs.LG"],
                "published_at": "2024-04-03", "updated_at": "2024-04-03", "venue": NSNull()],
            "metadata_recorded_at": "2026-10-03T10:00:00Z", "source_url": "https://arxiv.org/abs/2404.00001v1",
            "scope": "shared_catalog", "page_count": 1, "original_object_id": original.wire, "artifact_id": artifact.wire,
            "readiness": availability == "available" ? "converted_ready" : "unavailable", "original_availability": "available",
            "render_availability": availability, "original_availability_revision": 1, "render_availability_revision": availabilityRevision]
        let baseline: [String: Any] = ["format": 2, "account_id": account.wire, "baseline_cursor": state, "retained_after": 0,
            "entries": [row], "has_more": false, "next_cursor": ["format": 2, "account_id": account.wire, "through": state,
                "created_seq": 1, "id": item.wire, "kind": "item"]]
        let changes: [String: Any] = ["format": 2, "account_id": account.wire, "through": state, "retained_after": 0,
            "changes": [], "next_cursor": state, "has_more": false]
        var reconciler = LibraryReconciler(accountID: account)
        let first = try reconciler.nextRequest()
        try reconciler.accept(LibraryWire.decodeBaseline(JSONSerialization.data(withJSONObject: baseline)), for: first)
        let next = try reconciler.nextRequest()
        try reconciler.accept(LibraryWire.decodeChanges(JSONSerialization.data(withJSONObject: changes)), for: next)
        return try reconciler.completeObservation()
    }
}

private actor BundleVerificationGate {
    private var didHold = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func verify(_ input: ReaderBundleInput) async throws -> VerifiedReaderBundle {
        if !didHold {
            didHold = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                observers.forEach { $0.resume() }; observers = []
            }
        }
        return try await ReaderBundleInput.verify(input)
    }
    func waitUntilHeld() async { if !didHold { await withCheckedContinuation { observers.append($0) } } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor BundleDirectoryGate {
    private var armed = false
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func arm() { armed = true }
    func read(_ store: EncryptedStore, scope: LibraryCommandScope) async throws -> InstalledReaderBundleList {
        let list = try await store.listInstalledReaderBundles(scope: scope)
        if armed {
            armed = false; held = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                observers.forEach { $0.resume() }; observers = []
            }
        }
        return list
    }
    func waitUntilHeld() async { if !held { await withCheckedContinuation { observers.append($0) } } }
    func release() { continuation?.resume(); continuation = nil }
}
