import Foundation
import ScienceReaderCore
import SQLite3
import XCTest
@testable import ScienceReader

private enum CommandFixtureError: Error { case connectionLost, unexpectedRequest, noHeldReply, sqlite(Int32) }

private final class CommandArrival: @unchecked Sendable {
    let expectation: XCTestExpectation
    init(_ label: String) { expectation = XCTestExpectation(description: label) }
}

/// Held replies deliberately ignore cancellation: retirement must reject a
/// response even if a transport delivers it after cancellation was requested.
private actor CommandFixtureTransport: LibraryCommandTransport, LibraryTransport {
    enum Step: Sendable {
        case data(Data), lost, rejected(String), held(CommandArrival)
    }
    private var commandSteps: [Step]
    private var pageSteps: [Step]
    private var commands: [LibraryCommandAttempt] = []
    private var pages: [LibraryPageRequest] = []
    private var heldCommand: CheckedContinuation<Data, Error>?
    private var heldPage: CheckedContinuation<Data, Error>?
    /// Upload-capable (v5) discovery answers in order; the last repeats. Empty models a legacy server.
    private var capabilitySteps: [Data]

    init(commands: [Step] = [], pages: [Step], capabilities: [Data] = []) {
        commandSteps = commands; pageSteps = pages; capabilitySteps = capabilities
    }
    func readerCapabilities(accountID: UUID) async throws -> ReaderCapabilities? {
        guard let next = capabilitySteps.first else { return nil }
        if capabilitySteps.count > 1 { capabilitySteps.removeFirst() }
        return try ReaderCapabilities.decode(next, accountID: accountID)
    }
    func appendCommands(_ steps: [Step]) { commandSteps += steps }
    func appendPages(_ steps: [Step]) { pageSteps += steps }
    func capturedCommands() -> [LibraryCommandAttempt] { commands }
    func capturedPages() -> [LibraryPageRequest] { pages }
    func releaseCommand(_ data: Data) throws {
        guard let reply = heldCommand else { throw CommandFixtureError.noHeldReply }
        heldCommand = nil; reply.resume(returning: data)
    }
    func releasePage(_ data: Data) throws {
        guard let reply = heldPage else { throw CommandFixtureError.noHeldReply }
        heldPage = nil; reply.resume(returning: data)
    }
    func abort() {
        heldCommand?.resume(throwing: CancellationError()); heldCommand = nil
        heldPage?.resume(throwing: CancellationError()); heldPage = nil
    }
    func libraryCommand(_ attempt: LibraryCommandAttempt) async throws -> LibraryCommandDelivery {
        commands.append(attempt)
        guard !commandSteps.isEmpty else { throw CommandFixtureError.unexpectedRequest }
        let data: Data
        switch commandSteps.removeFirst() {
        case .data(let value): data = value
        case .lost: throw CommandFixtureError.connectionLost
        case .rejected(let code): throw BackendError.rejected(code)
        case .held(let arrival):
            data = try await withCheckedThrowingContinuation {
                heldCommand = $0; arrival.expectation.fulfill()
            }
        }
        return LibraryCommandDelivery(attempt: attempt, response: try LibraryWire.decodeCommand(data))
    }
    func libraryPage(_ request: LibraryPageRequest) async throws -> LibraryPageDelivery {
        pages.append(request)
        guard !pageSteps.isEmpty else { throw CommandFixtureError.unexpectedRequest }
        let data: Data
        switch pageSteps.removeFirst() {
        case .data(let value): data = value
        case .lost: throw CommandFixtureError.connectionLost
        case .rejected(let code): throw BackendError.rejected(code)
        case .held(let arrival):
            data = try await withCheckedThrowingContinuation {
                heldPage = $0; arrival.expectation.fulfill()
            }
        }
        let page: LibraryPageDelivery.Page
        switch request.query {
        case .baseline: page = .baseline(try LibraryWire.decodeBaseline(data))
        case .changes: page = .changes(try LibraryWire.decodeChanges(data))
        }
        return LibraryPageDelivery(request: request, page: page)
    }
}

private struct CommandFixtureIdentity: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
    let accountID = UUID()
    let localKey = ReaderCrypto.randomKey()
    let keys: KeyBundle
    init() { keys = KeyBundle.generate(accountID: accountID) }
    var url: URL { directory.appendingPathComponent("commands.sqlite") }
    var scope: LibraryCommandScope { try! .init(accountID: accountID, deploymentID: "https://coordinator-fixture.supabase.co") }
}

private struct CommandWireFixture {
    let accountID: UUID
    func bytes(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    func imported(_ id: UUID, created: Int64 = 1, state: Int64 = 1, revision: Int64 = 1,
                  cancelled: Bool = false, source: String = "2601.00001") -> [String: Any] {
        ["kind": "import", "id": id.wire, "created_seq": created, "state_seq": state,
         "intent_revision": revision, "visible": !cancelled, "phase": cancelled ? "cancelled" : "accepted",
         "source": "arxiv", "source_id": source, "requested_revision": NSNull(),
         "source_revision": NSNull(), "metadata_id": NSNull(), "version_id": NSNull(), "metadata": NSNull(),
         "metadata_recorded_at": NSNull(), "source_url": "https://arxiv.org/abs/\(source)",
         "document_id": NSNull(), "library_item_id": NSNull(), "error_code": NSNull(), "retryable": false]
    }
    func baseline(_ rows: [[String: Any]] = [], through: Int64 = 0, epoch: UUID? = nil) -> Data {
        let cursor: Any = rows.last.map {
            var value: [String: Any] = ["format": 2, "account_id": accountID.wire, "through": through,
                                        "created_seq": $0["created_seq"]!, "id": $0["id"]!, "kind": $0["kind"]!]
            if let epoch { value["read_level"] = 4; value["dataset_epoch"] = epoch.wire }
            return value
        } ?? (NSNull() as Any)
        var value: [String: Any] = ["format": 2, "account_id": accountID.wire, "baseline_cursor": through, "retained_after": 0,
                                    "entries": rows, "next_cursor": cursor, "has_more": false]
        if let epoch { value["dataset_epoch"] = epoch.wire }
        return bytes(value)
    }
    func changes(_ rows: [(Int64, [[String: Any]])] = [], through: Int64 = 0, more: Bool = false, epoch: UUID? = nil) -> Data {
        var value: [String: Any] = ["format": 2, "account_id": accountID.wire, "through": through, "retained_after": 0,
               "changes": rows.map { ["seq": $0.0, "entries": $0.1] as [String: Any] },
               "next_cursor": more ? (rows.last?.0 ?? 0) : through, "has_more": more]
        if let epoch { value["dataset_epoch"] = epoch.wire }
        return bytes(value)
    }
    func accepted(_ entry: [String: Any], sequence: Int64 = 1, revision: Int64 = 1, replayed: Bool = false, epoch: UUID? = nil) -> Data {
        var value: [String: Any] = ["result": ["status": "applied", "kind": "import", "id": entry["id"]!, "seq": sequence,
                                               "revision": revision], "entry": entry, "replayed": replayed]
        if let epoch { value["dataset_epoch"] = epoch.wire }
        return bytes(value)
    }
    func capabilities(_ epoch: UUID) -> Data {
        bytes(["format": 1, "account_id": accountID.wire,
            "library": ["endpoint_family": "full-v5", "wire_format": 2, "source_level": 4, "dataset_epoch": epoch.wire],
            "descriptors": ["format": 1, "maximum_batch": 24],
            "uploads": ["protocol": "upload-chunks-v1", "enabled": false, "chunk_bytes": 4_194_304,
                "maximum_bytes": 67_108_864, "maximum_parts": 16, "part_attempts": 2]])
    }
}

@MainActor
private final class CommandPublications {
    var queues: [LocalLibraryCommandSnapshot] = []
    var libraries: [LibrarySnapshot] = []
    var issues: [String?] = []
    func receive(_ queue: LocalLibraryCommandSnapshot, _ library: LibrarySnapshot?) {
        queues.append(queue)
        if let library { libraries.append(library) }
    }
}

@MainActor
private final class CoordinatorFixture {
    let identity: CommandFixtureIdentity
    private var ownedPersistence: ReaderLocalPersistence?
    private var ownedStore: EncryptedStore?
    private var ownedCoordinator: LibraryCommandCoordinator?
    var persistence: ReaderLocalPersistence { ownedPersistence! }
    var store: EncryptedStore { ownedStore! }
    var coordinator: LibraryCommandCoordinator { ownedCoordinator! }
    let transport: CommandFixtureTransport
    let library: LibraryService
    let publications = CommandPublications()
    let initial: LibrarySnapshot

    init(identity: CommandFixtureIdentity, transport: CommandFixtureTransport) async throws {
        self.identity = identity; self.transport = transport
        let persistence = ReaderLocalPersistence()
        ownedPersistence = persistence
        ownedStore = try await persistence.activate(url: identity.url, accountID: identity.accountID,
                                                    localKey: identity.localKey, keys: identity.keys)
        library = LibraryService(scope: .init(accountID: identity.accountID, readerSessionID: UUID()), transport: transport)
        initial = try await library.refresh()
        // The app's offline cache records an adopted upload-capable context with its first
        // complete observation; Core admits commands only in that saved context.
        if initial.observation.readContext.permitsUploads {
            try await ownedStore!.saveLibraryPresentation(initial.observation, scope: identity.scope)
        }
        let publications = publications
        let coordinator = LibraryCommandCoordinator(scope: identity.scope, persistence: persistence, library: library,
            transport: transport, publish: { publications.receive($0, $1) }, report: { publications.issues.append($0) })
        ownedCoordinator = coordinator
        try await coordinator.restore()
    }
    func queue() async throws -> LocalLibraryCommandSnapshot { try await store.libraryCommandSnapshot(scope: identity.scope) }
    func close() async {
        guard let coordinator = ownedCoordinator, let persistence = ownedPersistence else { return }
        coordinator.close(); await transport.abort(); await coordinator.stop()
        persistence.retire(); await persistence.waitForAcceptedWrites(); await library.invalidate()
        // Release every fixture-owned SQLite owner before deleting its files.
        ownedCoordinator = nil; ownedStore = nil; ownedPersistence = nil
    }
}

@MainActor
final class LibraryCommandCoordinatorTests: XCTestCase {
    private func fixture(_ identity: CommandFixtureIdentity = .init(), commands: [CommandFixtureTransport.Step] = [],
                         initialRows: [[String: Any]] = [], cursor: Int64 = 0,
                         pages: [CommandFixtureTransport.Step] = [], epochs: [UUID] = []) async throws -> CoordinatorFixture {
        let wire = CommandWireFixture(accountID: identity.accountID)
        let transport = CommandFixtureTransport(commands: commands,
            pages: [.data(wire.baseline(initialRows, through: cursor, epoch: epochs.first)),
                    .data(wire.changes(through: cursor, epoch: epochs.first))] + pages,
            capabilities: epochs.map(wire.capabilities))
        let value = try await CoordinatorFixture(identity: identity, transport: transport)
        addTeardownBlock {
            await value.close()
            try? FileManager.default.removeItem(at: identity.directory)
        }
        return value
    }
    private func begin(cursor: Int64 = 0) -> LibraryMutation {
        .beginImport(sourceID: "2601.00001", requestedRevision: nil, observedCursor: cursor)
    }
    private func wait(_ arrival: CommandArrival) async {
        await fulfillment(of: [arrival.expectation], timeout: 5)
    }
    private func sql(_ statement: String, at url: URL) throws {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(database) }
        guard opened == SQLITE_OK else { throw CommandFixtureError.sqlite(opened) }
        let result = sqlite3_exec(database, statement, nil, nil, nil)
        guard result == SQLITE_OK else { throw CommandFixtureError.sqlite(result) }
    }

    func testLostAcknowledgementReopensAndReplaysTheSameFrozenRequest() async throws {
        let first = try await fixture(commands: [.lost])
        let identity = first.identity, wire = CommandWireFixture(accountID: identity.accountID)
        let handle = try await first.coordinator.enqueue(begin(), display: "arXiv:2601.00001", observedIn: .legacyFull3)
        await first.coordinator.waitUntilIdle()
        let uncertain = try await first.queue(), initialAttempts = await first.transport.capturedCommands()
        let original = try XCTUnwrap(initialAttempts.first)
        XCTAssertEqual(uncertain.commands.first?.phase, .submittedUnknown)
        XCTAssertEqual(uncertain.commands.first?.failure, .connection)
        XCTAssertNil(uncertain.commands.first?.receipt)
        await first.close()

        // The server applied the first request but its response was lost. A
        // fresh session can observe that import and still replay its exact ID.
        let row = wire.imported(handle.intentID), received = CommandArrival("Restarted exact replay")
        let reopened = try await fixture(identity, commands: [.held(received)], initialRows: [row], cursor: 1,
                                         pages: [.data(wire.changes(through: 1))])
        let restored = try await reopened.queue()
        XCTAssertEqual(restored.commands.first?.request, original.request)
        reopened.coordinator.resume(); await wait(received)
        let replayAttempts = await reopened.transport.capturedCommands()
        let replay = try XCTUnwrap(replayAttempts.first)
        XCTAssertEqual(replay.handle, original.handle)
        XCTAssertEqual(replay.request, original.request)
        XCTAssertNotEqual(replay.attemptID, original.attemptID)
        try await reopened.transport.releaseCommand(wire.accepted(row, replayed: true))
        await reopened.coordinator.waitUntilIdle()
        let complete = try await reopened.queue(), library = await reopened.library.snapshot()
        XCTAssertTrue(complete.commands.isEmpty)
        XCTAssertEqual(library?.imports.map(\.id), [handle.intentID])
        let commands = await reopened.transport.capturedCommands()
        XCTAssertEqual(commands.count, 1)
        let privateCursor = await reopened.store.cursor(), privatePending = await reopened.store.pending()
        XCTAssertEqual(privateCursor, 0); XCTAssertTrue(privatePending.isEmpty)
    }

    func testCancelIssuedImportWaitsForReceiptAndUsesItsRevision() async throws {
        let issued = CommandArrival("Begin import issued"), reversal = CommandArrival("Dependent cancel issued")
        let f = try await fixture(commands: [.held(issued), .held(reversal)])
        let wire = CommandWireFixture(accountID: f.identity.accountID)
        let handle = try await f.coordinator.enqueue(begin(), display: "arXiv:2601.00001", observedIn: .legacyFull3)
        await wait(issued)
        let issuedQueue = try await f.queue(), command = try XCTUnwrap(issuedQueue.commands.first)
        XCTAssertEqual(command.phase, .submittedUnknown)
        XCTAssertEqual(f.publications.queues.last?.commands.first?.phase, .submittedUnknown,
                       "The submitted marker must reach presentation before the network returns")
        try await f.coordinator.cancel(command)
        let pending = try await f.queue(), child = try XCTUnwrap(pending.commands.last)
        XCTAssertEqual(pending.commands.count, 2); XCTAssertEqual(child.phase, .held); XCTAssertNil(child.request)
        let before = await f.transport.capturedCommands(); XCTAssertEqual(before.count, 1)
        // A historical applied result still has revision 1 even when the
        // returned current row has advanced. It alone authorizes the reversal.
        let advanced = wire.imported(handle.intentID, state: 3, revision: 3)
        await f.transport.appendPages([.data(wire.changes([(3, [advanced])], through: 3))])
        try await f.transport.releaseCommand(wire.accepted(advanced, sequence: 1, revision: 1, replayed: true))
        await wait(reversal)
        let sent = await f.transport.capturedCommands(), cancel = try XCTUnwrap(sent.last)
        XCTAssertEqual(sent.count, 2); XCTAssertEqual(cancel.request.endpoint, "v2_cancel_import")
        XCTAssertNotEqual(cancel.request.operationID, handle.intentID)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: cancel.request.body) as? [String: Any])
        XCTAssertEqual(body["p_import_id"] as? String, handle.intentID.wire)
        XCTAssertEqual(body["p_expected_revision"] as? Int, 1)
        // A newer server revision yields conflict, never an automatic rebase.
        let conflict = wire.bytes(["result": ["status": "revision_conflict", "kind": "import",
            "id": handle.intentID.wire, "seq": NSNull(), "revision": 3], "entry": advanced, "replayed": false])
        await f.transport.appendPages([.data(wire.changes(through: 3))])
        try await f.transport.releaseCommand(conflict)
        await f.coordinator.waitUntilIdle()
        let result = try await f.queue(), library = await f.library.snapshot()
        XCTAssertEqual(result.commands.count, 1)
        XCTAssertEqual(result.commands.first?.phase, .needsReview)
        XCTAssertEqual(result.commands.first?.request, cancel.request)
        XCTAssertEqual(library?.imports.first?.intentRevision, 3)
        XCTAssertEqual(library?.imports.first?.visible, true)
        let total = await f.transport.capturedCommands(); XCTAssertEqual(total.count, 2)
    }

    func testReceiptIsDurableBeforeWholeCatchupAndNeverPublishesAPartialLibrary() async throws {
        let identity = CommandFixtureIdentity(), wire = CommandWireFixture(accountID: identity.accountID)
        let existing = UUID(), intermediate = UUID()
        let issued = CommandArrival("Import request"), lastPage = CommandArrival("Final fixed-boundary page")
        let f = try await fixture(identity, commands: [.held(issued)], initialRows: [wire.imported(existing)], cursor: 1)
        let handle = try await f.coordinator.enqueue(begin(cursor: 1), display: nil, observedIn: .legacyFull3)
        await wait(issued)
        let row = wire.imported(handle.intentID, created: 3, state: 3)
        await f.transport.appendPages([
            .data(wire.changes([(2, [wire.imported(intermediate, created: 2, state: 2)])], through: 3, more: true)),
            .held(lastPage)])
        try await f.transport.releaseCommand(wire.accepted(row, sequence: 3))
        await wait(lastPage)
        let pending = try await f.queue(), stillPublished = await f.library.snapshot()
        XCTAssertEqual(pending.commands.first?.phase, .receiptAwaitingCatchup)
        XCTAssertEqual(pending.commands.first?.receipt?.requiredCursor, 3)
        XCTAssertEqual(stillPublished, f.initial)
        XCTAssertTrue(f.publications.libraries.isEmpty)
        XCTAssertTrue(f.publications.queues.contains { $0.commands.first?.receipt != nil })
        let pages = await f.transport.capturedPages()
        XCTAssertEqual(pages.last?.query, .changes(after: 2, through: 3))
        try await f.transport.releasePage(wire.changes([(3, [row])], through: 3))
        await f.coordinator.waitUntilIdle()
        let final = try await f.queue(), observed = try XCTUnwrap(f.publications.libraries.last)
        XCTAssertTrue(final.commands.isEmpty)
        XCTAssertEqual(observed.committedCursor, 3)
        XCTAssertEqual(Set(observed.imports.map(\.id)), Set([existing, intermediate, handle.intentID]))
        XCTAssertEqual(f.publications.libraries.count, 1)
        let commands = await f.transport.capturedCommands(); XCTAssertEqual(commands.count, 1)
    }

    func testRetirementIgnoresLateResponseAndDrainsBeforeSameAccountReopen() async throws {
        let issued = CommandArrival("Old account command held")
        let f = try await fixture(commands: [.held(issued)])
        let wire = CommandWireFixture(accountID: f.identity.accountID)
        let handle = try await f.coordinator.enqueue(begin(), display: nil, observedIn: .legacyFull3)
        await wait(issued)
        let before = try await f.queue(), publishedCount = f.publications.queues.count
        let retirement = ReaderRetirementQueue(), replacement = ReaderLocalPersistence()
        retirement.retire(sync: nil, persistence: f.persistence, commands: f.coordinator)
        XCTAssertTrue(f.persistence.isRetired)
        let waiting = expectation(description: "Same-account reopen waits for retirement")
        let identity = f.identity
        let reopened = Task {
            waiting.fulfill(); await retirement.wait()
            return try await replacement.activate(url: identity.url, accountID: identity.accountID,
                                                   localKey: identity.localKey, keys: identity.keys)
        }
        await fulfillment(of: [waiting], timeout: 5)
        XCTAssertNil(replacement.store)
        do { _ = try await f.coordinator.enqueue(begin(), display: nil, observedIn: .legacyFull3); XCTFail("Retired queue must reject work") }
        catch is CancellationError { }
        try await f.transport.releaseCommand(wire.accepted(wire.imported(handle.intentID)))
        let store = try await reopened.value
        let restored = try await store.libraryCommandSnapshot(scope: identity.scope)
        XCTAssertEqual(f.publications.queues.count, publishedCount)
        XCTAssertEqual(restored.commands.first?.phase, .submittedUnknown)
        XCTAssertNil(restored.commands.first?.receipt)
        XCTAssertNil(restored.commands.first?.attemptID)
        XCTAssertEqual(restored.commands.first?.request, before.commands.first?.request)
        let pages = await f.transport.capturedPages(); XCTAssertEqual(pages.count, 2)
        replacement.retire(); await replacement.waitForAcceptedWrites()
    }

    func testKeyActivationPauseSavesReturnedReceiptThenResumesWithoutAnotherPOST() async throws {
        let issued = CommandArrival("Issued command before key activation")
        let f = try await fixture(commands: [.held(issued)])
        let wire = CommandWireFixture(accountID: f.identity.accountID)
        let handle = try await f.coordinator.enqueue(begin(), display: nil, observedIn: .legacyFull3)
        await wait(issued)
        let started = expectation(description: "Coordinator pause entered")
        let pause = Task { started.fulfill(); await f.coordinator.pause() }
        await fulfillment(of: [started], timeout: 5)
        do { _ = try await f.coordinator.enqueue(begin(), display: nil, observedIn: .legacyFull3); XCTFail("Paused queue must reject new work") }
        catch is CancellationError { }
        let row = wire.imported(handle.intentID)
        try await f.transport.releaseCommand(wire.accepted(row))
        await pause.value
        let saved = try await f.queue()
        XCTAssertEqual(saved.commands.first?.phase, .receiptAwaitingCatchup)
        var rotated = f.identity.keys; try rotated.rotate()
        let activated = try await f.persistence.activate(url: f.identity.url, accountID: f.identity.accountID,
                                                         localKey: f.identity.localKey, keys: rotated)
        XCTAssertTrue(activated === f.store)
        await f.transport.appendPages([.data(wire.changes([(1, [row])], through: 1))])
        f.coordinator.resume(); await f.coordinator.waitUntilIdle()
        let complete = try await f.queue(), sent = await f.transport.capturedCommands()
        XCTAssertTrue(complete.commands.isEmpty); XCTAssertEqual(sent.count, 1)
        XCTAssertFalse(f.publications.issues.compactMap { $0 }.contains { $0.contains("Reopen the app") })
    }

    func testPauseDuringReceiptCatchupCanResumeAfterKeyActivation() async throws {
        let issued = CommandArrival("Command accepted"), catchup = CommandArrival("Receipt catchup paused")
        let f = try await fixture(commands: [.held(issued)])
        let wire = CommandWireFixture(accountID: f.identity.accountID)
        let handle = try await f.coordinator.enqueue(begin(), display: nil, observedIn: .legacyFull3)
        await wait(issued)
        await f.transport.appendPages([.held(catchup)])
        let row = wire.imported(handle.intentID)
        try await f.transport.releaseCommand(wire.accepted(row))
        await wait(catchup)
        let started = expectation(description: "Pause while awaiting complete observation")
        let pause = Task { started.fulfill(); await f.coordinator.pause() }
        await fulfillment(of: [started], timeout: 5)
        try await f.transport.releasePage(wire.changes([(1, [row])], through: 1))
        await pause.value
        XCTAssertTrue(f.publications.libraries.isEmpty, "A cancelled continuation cannot publish its observation")
        let pending = try await f.queue(); XCTAssertEqual(pending.commands.first?.phase, .receiptAwaitingCatchup)
        var rotated = f.identity.keys; try rotated.rotate()
        _ = try await f.persistence.activate(url: f.identity.url, accountID: f.identity.accountID,
                                             localKey: f.identity.localKey, keys: rotated)
        await f.transport.appendPages([.data(wire.changes(through: 1))])
        f.coordinator.resume(); await f.coordinator.waitUntilIdle()
        let complete = try await f.queue(), sent = await f.transport.capturedCommands()
        XCTAssertTrue(complete.commands.isEmpty); XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(f.publications.libraries.last?.committedCursor, 1)
        XCTAssertFalse(f.publications.issues.compactMap { $0 }.contains { $0.contains("Reopen the app") })
    }

    func testOperationIDConflictDoesNotRetryAndCanBeDismissed() async throws {
        let f = try await fixture(commands: [.rejected("operation_id_conflict")])
        _ = try await f.coordinator.enqueue(begin(), display: nil, observedIn: .legacyFull3)
        await f.coordinator.waitUntilIdle()
        let snapshot = try await f.queue(), command = try XCTUnwrap(snapshot.commands.first)
        XCTAssertEqual(command.failure, .operationConflict)
        XCTAssertEqual(command.phase, .needsReview); XCTAssertFalse(command.canAttempt)
        XCTAssertNil(command.receipt)
        f.coordinator.flush(); await f.coordinator.waitUntilIdle()
        let attempts = await f.transport.capturedCommands(); XCTAssertEqual(attempts.count, 1)
        try await f.coordinator.dismiss(command)
        let dismissed = try await f.queue(); XCTAssertTrue(dismissed.commands.isEmpty)
    }

    func testUnclassifiedServerFailureDoesNotClaimTheIssuedChangeWasRejected() async throws {
        let f = try await fixture(commands: [.rejected("request_failed")])
        _ = try await f.coordinator.enqueue(begin(), display: nil, observedIn: .legacyFull3)
        await f.coordinator.waitUntilIdle()
        let queue = try await f.queue(), command = try XCTUnwrap(queue.commands.first)
        XCTAssertTrue(command.everSubmitted)
        XCTAssertEqual(command.phase, .submittedUnknown)
        XCTAssertEqual(command.failure, .connection)
        XCTAssertNil(command.receipt)
        let attempts = await f.transport.capturedCommands(); XCTAssertEqual(attempts.count, 1)
    }

    func testCapacityBlockedAddCannotStarveAnUnrelatedCancellation() async throws {
        let identity = CommandFixtureIdentity(), wire = CommandWireFixture(accountID: identity.accountID)
        let existingID = UUID(), arrival = CommandArrival("Cancel admitted ahead of blocked Add")
        let f = try await fixture(identity, commands: [.rejected("library_active_import_limit"), .held(arrival),
                                                       .rejected("library_active_import_limit")],
                                  initialRows: [wire.imported(existingID, source: "2601.00002")], cursor: 1)
        let add = try await f.coordinator.enqueue(begin(cursor: 1), display: nil, observedIn: .legacyFull3)
        await f.coordinator.waitUntilIdle()
        let firstAttempts = await f.transport.capturedCommands()
        let frozen = try XCTUnwrap(firstAttempts.first?.request)
        let cancel = try await f.coordinator.enqueue(.cancelImport(importID: existingID, expectedRevision: 1), display: nil, observedIn: .legacyFull3)
        await wait(arrival)
        let afterCancel = await f.transport.capturedCommands()
        XCTAssertEqual(afterCancel.map(\.handle), [add, cancel])
        XCTAssertEqual(afterCancel.last?.request.endpoint, "v2_cancel_import")
        let cancelled = wire.imported(existingID, state: 2, revision: 2, cancelled: true, source: "2601.00002")
        await f.transport.appendPages([.data(wire.changes([(2, [cancelled])], through: 2))])
        try await f.transport.releaseCommand(wire.accepted(cancelled, sequence: 2, revision: 2))
        await f.coordinator.waitUntilIdle()
        let attempts = await f.transport.capturedCommands(), queue = try await f.queue()
        XCTAssertEqual(attempts.map(\.handle), [add, cancel, add])
        XCTAssertEqual(attempts.last?.request, frozen, "Capacity relief cannot rebase the older Add")
        XCTAssertEqual(queue.commands.map(\.handle), [add])
        XCTAssertEqual(queue.commands.first?.failure, .capacity)
        let library = await f.library.snapshot()
        XCTAssertEqual(library?.imports.first?.visible, false)
    }

    func testRolledBackReceiptStopsDispatchUntilExplicitAuthenticatedRetry() async throws {
        let issued = CommandArrival("Response before local receipt failure"), replayed = CommandArrival("Explicit replay after rollback")
        let f = try await fixture(commands: [.held(issued), .held(replayed)])
        let wire = CommandWireFixture(accountID: f.identity.accountID)
        let handle = try await f.coordinator.enqueue(begin(), display: nil, observedIn: .legacyFull3)
        await wait(issued)
        let original = await f.transport.capturedCommands()
        try sql("CREATE TRIGGER reject_fixture_receipt BEFORE UPDATE ON local_library_commands BEGIN SELECT RAISE(ABORT,'fixture_receipt_failure'); END", at: f.identity.url)
        let row = wire.imported(handle.intentID)
        try await f.transport.releaseCommand(wire.accepted(row))
        await f.coordinator.waitUntilIdle()
        let uncertain = try await f.queue()
        XCTAssertEqual(uncertain.commands.first?.phase, .submittedUnknown)
        XCTAssertNil(uncertain.commands.first?.receipt)
        XCTAssertTrue(f.publications.issues.compactMap { $0 }.contains { $0.contains("Library changes are paused") })
        f.coordinator.flush(); await f.coordinator.waitUntilIdle()
        let stopped = await f.transport.capturedCommands(); XCTAssertEqual(stopped.count, 1)
        try sql("DROP TRIGGER reject_fixture_receipt", at: f.identity.url)
        await f.transport.appendPages([.data(wire.changes([(1, [row])], through: 1))])
        await f.coordinator.retry(); await wait(replayed)
        let retry = await f.transport.capturedCommands()
        XCTAssertEqual(retry.count, 2)
        XCTAssertEqual(retry.last?.request, original.first?.request)
        XCTAssertNotEqual(retry.last?.attemptID, original.first?.attemptID)
        try await f.transport.releaseCommand(wire.accepted(row, replayed: true))
        await f.coordinator.waitUntilIdle()
        let complete = try await f.queue(); XCTAssertTrue(complete.commands.isEmpty)
    }

    func testRetryCannotRestoreAuthorityAfterAnotherStoreOwnerOpens() async throws {
        let f = try await fixture(commands: [.lost])
        _ = try await f.coordinator.enqueue(begin(), display: nil, observedIn: .legacyFull3)
        await f.coordinator.waitUntilIdle()
        let before = try await f.queue(), identity = f.identity
        // Opening a replacement writer changes the authenticated checkpoint;
        // the old actor must fail even if its cached queue still looks usable.
        let replacement = try EncryptedStore(url: identity.url, accountID: identity.accountID,
                                               localKey: identity.localKey, keys: identity.keys)
        await f.coordinator.retry(); await f.coordinator.waitUntilIdle()
        await f.coordinator.retry(); await f.coordinator.waitUntilIdle()
        let attempts = await f.transport.capturedCommands(); XCTAssertEqual(attempts.count, 1)
        XCTAssertTrue(f.publications.issues.compactMap { $0 }.contains { $0.contains("Library changes are paused") })
        do { _ = try await f.coordinator.enqueue(begin(), display: nil, observedIn: .legacyFull3); XCTFail("A stale writer cannot accept new work") }
        catch { XCTAssertEqual(error as? ReaderError, .storageUnavailable) }
        let current = try await replacement.libraryCommandSnapshot(scope: identity.scope)
        XCTAssertEqual(current.commands.first?.request, before.commands.first?.request)
        XCTAssertNil(current.commands.first?.receipt)
    }

    // MARK: Upload-capable (v5) library, migration 042

    func testV5AddSendsTheObservedDatasetEpochAndCatchesUpInThatDataset() async throws {
        let identity = CommandFixtureIdentity(), wire = CommandWireFixture(accountID: identity.accountID), epoch = UUID()
        let issued = CommandArrival("v5 import issued")
        let f = try await fixture(identity, commands: [.held(issued)], epochs: [epoch])
        let context = LibraryReadContext.uploadFull5(datasetEpoch: epoch)
        XCTAssertEqual(f.initial.observation.readContext, context)
        do { _ = try await f.coordinator.enqueue(begin(), display: nil, observedIn: .legacyFull3); XCTFail("A v3 observation cannot write after v5 adoption") }
        catch LibraryCommandError.contextMismatch {}
        let handle = try await f.coordinator.enqueue(begin(), display: "arXiv:2601.00001", observedIn: context)
        await wait(issued)
        let captured = await f.transport.capturedCommands(), sent = try XCTUnwrap(captured.first)
        XCTAssertEqual(sent.request.endpoint, "v5_begin_import"); XCTAssertEqual(sent.readContext, context)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.request.body) as? [String: Any])
        XCTAssertEqual(body["p_dataset_epoch"] as? String, epoch.wire)
        XCTAssertEqual(body["p_operation_id"] as? String, handle.intentID.wire)
        let row = wire.imported(handle.intentID)
        await f.transport.appendPages([.data(wire.changes([(1, [row])], through: 1, epoch: epoch))])
        try await f.transport.releaseCommand(wire.accepted(row, sequence: 1, epoch: epoch))
        await f.coordinator.waitUntilIdle()
        let queue = try await f.queue(), library = await f.library.snapshot()
        XCTAssertTrue(queue.commands.isEmpty, "The receipt floor is reached by a v5 catch-up in the same dataset")
        XCTAssertEqual(library?.imports.map(\.id), [handle.intentID])
        XCTAssertEqual(library?.observation.readContext, context)
        let pages = await f.transport.capturedPages()
        XCTAssertEqual(pages.last?.query, .changes(after: 0, through: nil)); XCTAssertEqual(pages.last?.readContext, context)
        XCTAssertNil(f.publications.issues.last ?? nil)
    }

    func testV5DatasetRefusalSetsTheCommandAsideAndReadsAFreshBaseline() async throws {
        let identity = CommandFixtureIdentity(), wire = CommandWireFixture(accountID: identity.accountID)
        let old = UUID(), new = UUID()
        // Discovery: the first refresh and the drain see the old dataset; a restore rotates it before the POST.
        let f = try await fixture(identity, commands: [.rejected("library_resync_required")],
            pages: [.data(wire.baseline([], through: 0, epoch: new)), .data(wire.changes(through: 0, epoch: new))],
            epochs: [old, old, new])
        let handle = try await f.coordinator.enqueue(begin(), display: nil, observedIn: .uploadFull5(datasetEpoch: old))
        await f.coordinator.waitUntilIdle()
        let queue = try await f.queue(), command = try XCTUnwrap(queue.commands.first)
        XCTAssertEqual(queue.commands.count, 1, "Never silently dropped")
        XCTAssertEqual(command.handle, handle); XCTAssertEqual(command.phase, .needsReview)
        XCTAssertEqual(command.failure, .datasetChanged); XCTAssertFalse(command.canAttempt)
        XCTAssertEqual(command.request?.endpoint, "v5_begin_import"); XCTAssertEqual(command.readContext, .uploadFull5(datasetEpoch: old))
        XCTAssertEqual(f.publications.libraries.last?.observation.readContext, .uploadFull5(datasetEpoch: new),
                       "A fresh baseline in the new dataset is published")
        let pages = await f.transport.capturedPages()
        XCTAssertEqual(pages.suffix(2).map(\.query), [.baseline(cursor: nil), .changes(after: 0, through: nil)])
        XCTAssertEqual(f.publications.issues.last ?? nil,
                       "Your library was updated on the server. Review your saved change before trying it again.")
        // Retrying never resends the refused request; a new action from the new observation can.
        await f.coordinator.retry(); await f.coordinator.waitUntilIdle()
        let attempts = await f.transport.capturedCommands()
        XCTAssertEqual(attempts.count, 1)
        try await f.store.saveLibraryPresentation(try XCTUnwrap(f.publications.libraries.last).observation, scope: identity.scope)
        await f.transport.appendCommands([.lost])
        let again = try await f.coordinator.enqueue(begin(), display: nil, observedIn: .uploadFull5(datasetEpoch: new))
        await f.coordinator.waitUntilIdle()
        let latest = await f.transport.capturedCommands(), resent = try XCTUnwrap(latest.last)
        XCTAssertEqual(resent.handle, again); XCTAssertNotEqual(again.intentID, handle.intentID)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: resent.request.body) as? [String: Any])
        XCTAssertEqual(body["p_dataset_epoch"] as? String, new.wire)
    }
}
