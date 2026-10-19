import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

private enum LibraryFixtureFailure: Error { case interrupted, unexpectedRequest }

private actor LibraryScript: LibraryTransport {
    enum Capability: Sendable { case legacy, data(Data), failed }
    enum Step: Sendable {
        case data(Data), held, failure, compaction
        case wrongOwner(Data, LibraryPageRequest)
    }
    private var steps: [Step]
    private var captured: [LibraryPageRequest] = []
    private var held: CheckedContinuation<Data, Error>?
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var capabilitySteps: [Capability]

    init(_ steps: [Step], capabilities: [Capability] = []) { self.steps = steps; capabilitySteps = capabilities }
    func readerCapabilities(accountID: UUID) async throws -> ReaderCapabilities? {
        guard !capabilitySteps.isEmpty else { return nil }
        switch capabilitySteps.removeFirst() {
        case .legacy: return nil
        case .data(let bytes): return try ReaderCapabilities.decode(bytes, accountID: accountID)
        case .failed: throw LibraryFixtureFailure.interrupted
        }
    }
    func requests() -> [LibraryPageRequest] { captured }
    func append(_ steps: [Step]) { self.steps += steps }
    func waitForRequests(_ count: Int) async {
        if captured.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func release(_ data: Data) { held?.resume(returning: data); held = nil }
    func libraryPage(_ request: LibraryPageRequest) async throws -> LibraryPageDelivery {
        captured.append(request)
        guard !steps.isEmpty else { throw LibraryFixtureFailure.unexpectedRequest }
        let step = steps.removeFirst()
        let data: Data, owner: LibraryPageRequest
        owner = if case .wrongOwner(_, let other) = step { other } else { request }
        // Signal only after a held response is installed, so test release is
        // causally ordered even though the transport ignores task cancellation.
        switch step {
        case .held:
            data = try await withCheckedThrowingContinuation { continuation in
                held = continuation; notifyObservers()
            }
        case .data(let bytes), .wrongOwner(let bytes, _): data = bytes; notifyObservers()
        case .failure: notifyObservers(); throw LibraryFixtureFailure.interrupted
        case .compaction: notifyObservers(); throw LibraryTransportError.resyncRequired
        }
        let page: LibraryPageDelivery.Page
        switch request.query {
        case .baseline: page = .baseline(try LibraryWire.decodeBaseline(data))
        case .changes: page = .changes(try LibraryWire.decodeChanges(data))
        }
        return LibraryPageDelivery(request: owner, page: page)
    }
    private func notifyObservers() {
        let ready = observers.filter { $0.0 <= captured.count }
        observers.removeAll { $0.0 <= captured.count }
        ready.forEach { $0.1.resume() }
    }
}

private struct LibraryFixture {
    let accountID: UUID
    func bytes(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    func row(_ id: UUID, created: Int64, state: Int64? = nil, visible: Bool = true) -> [String: Any] {
        ["kind": "import", "id": id.wire, "created_seq": created, "state_seq": state ?? created,
         "intent_revision": visible ? 1 : 2, "visible": visible, "phase": visible ? "accepted" : "cancelled",
         "source": "arxiv", "source_id": "2601.00001", "requested_revision": NSNull(),
         "source_revision": NSNull(), "metadata_id": NSNull(), "version_id": NSNull(), "metadata": NSNull(),
         "metadata_recorded_at": NSNull(), "source_url": "https://arxiv.org/abs/2601.00001",
         "document_id": NSNull(), "library_item_id": NSNull(), "error_code": NSNull(), "retryable": false]
    }
    func capabilities(_ epoch: UUID) -> Data {
        bytes(["format": 1, "account_id": accountID.wire,
            "library": ["endpoint_family": "full-v5", "wire_format": 2, "source_level": 4, "dataset_epoch": epoch.wire],
            "descriptors": ["format": 1, "maximum_batch": 24],
            "uploads": ["protocol": "upload-chunks-v1", "enabled": false, "chunk_bytes": 4_194_304,
                "maximum_bytes": 67_108_864, "maximum_parts": 16, "part_attempts": 2]])
    }
    func baseline(_ rows: [[String: Any]], high: Int64, more: Bool = false, epoch: UUID? = nil) -> Data {
        let cursor: Any = rows.last.map {
            ["format": 2, "account_id": accountID.wire, "through": high,
             "created_seq": $0["created_seq"]!, "id": $0["id"]!, "kind": $0["kind"]!] as [String: Any]
        } ?? (NSNull() as Any)
        var value: [String: Any] = ["format": 2, "account_id": accountID.wire, "baseline_cursor": high, "retained_after": 0,
                      "entries": rows, "next_cursor": cursor, "has_more": more]
        if let epoch {
            value["dataset_epoch"] = epoch.wire
            if var continuation = cursor as? [String: Any] {
                continuation["dataset_epoch"] = epoch.wire; continuation["read_level"] = 4; value["next_cursor"] = continuation
            }
        }
        return bytes(value)
    }
    func changes(_ rows: [(Int64, [[String: Any]])], through: Int64, more: Bool = false, epoch: UUID? = nil) -> Data {
        var value: [String: Any] = ["format": 2, "account_id": accountID.wire, "through": through, "retained_after": 0,
               "changes": rows.map { ["seq": $0.0, "entries": $0.1] as [String: Any] },
               "next_cursor": more ? (rows.last?.0 ?? 0) : through, "has_more": more]
        if let epoch { value["dataset_epoch"] = epoch.wire }
        return bytes(value)
    }
}

@MainActor
final class LibraryServiceTests: XCTestCase {
    func testProtocolUpgradeAndRestoreEachStartFreshBaselineWithoutOldCursor() async throws {
        let scope = LibraryScope(accountID: UUID(), readerSessionID: UUID()), first = UUID(), second = UUID()
        let f = LibraryFixture(accountID: scope.accountID), one = UUID(), two = UUID()
        let script = LibraryScript([
            .data(f.baseline([f.row(first, created: 1)], high: 50)), .data(f.changes([], through: 50)),
            .data(f.baseline([f.row(second, created: 1)], high: 2, epoch: one)), .data(f.changes([], through: 2, epoch: one)),
            .data(f.baseline([], high: 0, epoch: two)), .data(f.changes([], through: 0, epoch: two))],
            capabilities: [.legacy, .data(f.capabilities(one)), .data(f.capabilities(two))])
        let service = LibraryService(scope: scope, transport: script)
        let legacy = try await service.refresh(), v5 = try await service.refresh(), restored = try await service.refresh()
        XCTAssertEqual(legacy.committedCursor, 50)
        XCTAssertEqual(v5.imports.map(\.id), [second]); XCTAssertEqual(v5.committedCursor, 2)
        XCTAssertTrue(restored.entries.isEmpty); XCTAssertEqual(restored.committedCursor, 0)
        let requests = await script.requests()
        for index in [0, 2, 4] { XCTAssertEqual(requests[index].query, .baseline(cursor: nil)) }
        XCTAssertEqual(Set(requests.map(\.sessionID)).count, 3)
        XCTAssertEqual(requests[3].readContext, .uploadFull5(datasetEpoch: one))
        XCTAssertEqual(requests[5].readContext, .uploadFull5(datasetEpoch: two))
        let permitsWrites = await service.permitsLegacyCommands()
        XCTAssertFalse(permitsWrites)
        // Writes follow the current dataset only (migration 042); old v3/v5 observations are refused.
        let current = await service.permitsCommands(in: .uploadFull5(datasetEpoch: two))
        let replaced = await service.permitsCommands(in: .uploadFull5(datasetEpoch: one))
        let legacyWrites = await service.permitsCommands(in: .legacyFull3)
        XCTAssertTrue(current); XCTAssertFalse(replaced); XCTAssertFalse(legacyWrites)
    }

    func testRememberedV5CannotDowngradeWhenDiscoveryIsMissingOrTransient() async throws {
        let scope = LibraryScope(accountID: UUID(), readerSessionID: UUID()), epoch = UUID()
        let script = LibraryScript([], capabilities: [.legacy, .failed])
        let service = LibraryService(scope: scope, transport: script, rememberedContext: .uploadFull5(datasetEpoch: epoch))
        do { _ = try await service.refresh(); XCTFail("Durably adopted protocol must not downgrade") }
        catch LibraryServiceError.capabilityUnavailable { }
        do { _ = try await service.refresh(); XCTFail("Transient discovery must not downgrade") }
        catch LibraryFixtureFailure.interrupted { }
        let captured = await script.requests(), published = await service.snapshot()
        XCTAssertTrue(captured.isEmpty)
        XCTAssertNil(published)
    }

    func testEncryptedResumeIsNeverPublishedBeforeFreshServerCatchup() async throws {
        let account = UUID(), epoch = UUID(), f = LibraryFixture(accountID: account)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheScope = try LibraryCommandScope(accountID: account, deploymentID: "https://resume.invalid")
        let store = try EncryptedStore(url: directory.appendingPathComponent("cache.sqlite"), accountID: account,
            localKey: ReaderCrypto.randomKey(), keys: .generate(accountID: account))
        var replica = LibraryReconciler(accountID: account, readContext: .uploadFull5(datasetEpoch: epoch))
        try replica.accept(LibraryWire.decodeBaseline(f.baseline([], high: 19, epoch: epoch)), for: replica.nextRequest())
        try replica.accept(LibraryWire.decodeChanges(f.changes([], through: 19, epoch: epoch)), for: replica.nextRequest())
        try await store.saveLibraryPresentation(replica.completeObservation(), scope: cacheScope)
        let seed = try await store.cachedLibraryReplicaSeed(scope: cacheScope)
        let script = LibraryScript([.held], capabilities: [.data(f.capabilities(epoch))])
        let service = LibraryService(scope: .init(accountID: account, readerSessionID: UUID()), transport: script,
            rememberedContext: .uploadFull5(datasetEpoch: epoch), resume: seed)
        let task = Task { try await service.refresh() }
        await script.waitForRequests(1)
        let before = await service.snapshot(), captured = await script.requests()
        XCTAssertNil(before)
        XCTAssertEqual(captured.first?.query, .changes(after: 19, through: nil))
        await script.release(f.changes([], through: 19, epoch: epoch))
        let completed = try await task.value
        XCTAssertEqual(completed.committedCursor, 19)
    }

    func testFirstPublicationWaitsForEveryBaselineAndFixedBoundaryDeltaPage() async throws {
        let scope = LibraryScope(accountID: UUID(), readerSessionID: UUID())
        let f = LibraryFixture(accountID: scope.accountID), firstID = UUID(), secondID = UUID()
        let script = LibraryScript([.data(f.baseline([f.row(firstID, created: 1)], high: 2, more: true)), .held, .held])
        let service = LibraryService(scope: scope, transport: script)
        let task = Task { try await service.refresh() }
        await script.waitForRequests(2)
        let baselinePending = await service.snapshot(); XCTAssertNil(baselinePending)
        await script.release(f.baseline([f.row(secondID, created: 2)], high: 2))
        await script.waitForRequests(3)
        let deltaPending = await service.snapshot(); XCTAssertNil(deltaPending)
        let requests = await script.requests()
        XCTAssertEqual(requests[2].query, .changes(after: 2, through: nil))
        XCTAssertEqual(Set(requests.map(\.sessionID)).count, 1)
        await script.release(f.changes([(3, [f.row(firstID, created: 1, state: 3, visible: false)])], through: 3))
        let result = try await task.value
        XCTAssertEqual(result.scope, scope); XCTAssertEqual(result.generation, 1)
        XCTAssertEqual(result.committedCursor, 3); XCTAssertEqual(result.imports.count, 2)
        XCTAssertEqual(result.imports.first { $0.id == firstID }?.visible, false)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(result.imports.allSatisfy { $0.documentID == nil })
    }

    func testFailureRetainsPublishedSnapshotAndRetriesExactFixedBoundaryTicket() async throws {
        let scope = LibraryScope(accountID: UUID(), readerSessionID: UUID()), id = UUID(), other = UUID()
        let f = LibraryFixture(accountID: scope.accountID)
        let script = LibraryScript([.data(f.baseline([f.row(id, created: 1)], high: 1)), .data(f.changes([], through: 1)),
                                    .data(f.changes([(2, [f.row(other, created: 2)])], through: 3, more: true)), .failure,
                                    .data(f.changes([(3, [f.row(id, created: 1, state: 3, visible: false)])], through: 3))])
        let service = LibraryService(scope: scope, transport: script)
        let initial = try await service.refresh()
        do { _ = try await service.refresh(); XCTFail("Interrupted page must fail") }
        catch LibraryFixtureFailure.interrupted { }
        let stillPublished = await service.snapshot(); XCTAssertEqual(stillPublished, initial)
        let result = try await service.refresh(), requests = await script.requests()
        XCTAssertEqual(requests[3], requests[4])
        XCTAssertEqual(requests[3].query, .changes(after: 2, through: 3))
        XCTAssertEqual(result.generation, 2); XCTAssertEqual(result.committedCursor, 3)
        XCTAssertEqual(result.imports.count, 2)
    }

    func testMalformedAndWrongOwnerResponsesDoNotPoisonTheNextValidRetry() async throws {
        let scope = LibraryScope(accountID: UUID(), readerSessionID: UUID())
        let f = LibraryFixture(accountID: scope.accountID)
        var other = LibraryReconciler(accountID: scope.accountID)
        let wrongOwner = try other.nextRequest()
        let script = LibraryScript([.data(Data("not JSON".utf8)), .wrongOwner(f.baseline([], high: 0), wrongOwner),
                                    .data(f.baseline([], high: 0)), .data(f.changes([], through: 0))])
        let service = LibraryService(scope: scope, transport: script)
        do { _ = try await service.refresh(); XCTFail("Malformed response must fail") } catch { }
        do { _ = try await service.refresh(); XCTFail("Foreign ticket must fail") }
        catch LibraryServiceError.wrongDelivery { }
        let result = try await service.refresh(), requests = await script.requests()
        XCTAssertEqual(requests[0], requests[1]); XCTAssertEqual(requests[1], requests[2])
        XCTAssertEqual(result.generation, 1); XCTAssertTrue(result.entries.isEmpty)
    }

    func testConcurrentRefreshesShareTheSameCompletePublication() async throws {
        let scope = LibraryScope(accountID: UUID(), readerSessionID: UUID())
        let f = LibraryFixture(accountID: scope.accountID)
        let script = LibraryScript([.held, .held])
        let service = LibraryService(scope: scope, transport: script)
        let first = Task { try await service.refresh() }
        await script.waitForRequests(1)
        let second = Task { try await service.refresh() }
        // Keep the second network boundary suspended as well. Both callers
        // must join this same complete pull before it can publish.
        await script.release(f.baseline([], high: 0))
        await script.waitForRequests(2)
        let pending = await service.snapshot(); XCTAssertNil(pending)
        await script.release(f.changes([], through: 0))
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a, b); XCTAssertEqual(a.generation, 1)
        let requests = await script.requests(); XCTAssertEqual(requests.count, 2)
    }

    func testPageBudgetExhaustionCanContinueWithoutRestartingItsBaseline() async throws {
        let scope = LibraryScope(accountID: UUID(), readerSessionID: UUID())
        let f = LibraryFixture(accountID: scope.accountID)
        let script = LibraryScript([.data(f.baseline([], high: 0)), .data(f.changes([], through: 0))])
        let service = LibraryService(scope: scope, transport: script, limits: .init(pagesPerRefresh: 1))
        do { _ = try await service.refresh(); XCTFail("Bounded pull must yield") }
        catch LibraryServiceError.pageBudgetExhausted { }
        let pending = await service.snapshot(); XCTAssertNil(pending)
        let result = try await service.refresh(), requests = await script.requests()
        XCTAssertEqual(requests[1].query, .changes(after: 0, through: nil))
        XCTAssertEqual(requests[0].sessionID, requests[1].sessionID)
        XCTAssertEqual(result.generation, 1)
    }

    func testRepeatedCompactionIsBoundedAndNextRefreshUsesAFreshPullSession() async throws {
        let scope = LibraryScope(accountID: UUID(), readerSessionID: UUID()), id = UUID()
        let f = LibraryFixture(accountID: scope.accountID)
        let script = LibraryScript([.data(f.baseline([f.row(id, created: 1)], high: 1)), .data(f.changes([], through: 1)),
                                    .compaction, .compaction, .data(f.baseline([], high: 2)), .data(f.changes([], through: 2))])
        let service = LibraryService(scope: scope, transport: script)
        let initial = try await service.refresh()
        do { _ = try await service.refresh(); XCTFail("Repeated compaction must stop") }
        catch LibraryServiceError.repeatedCompaction { }
        let preserved = await service.snapshot(); XCTAssertEqual(preserved, initial)
        let result = try await service.refresh(), requests = await script.requests()
        XCTAssertEqual(requests.count, 6)
        XCTAssertNotEqual(requests[2].sessionID, requests[3].sessionID)
        XCTAssertNotEqual(requests[3].sessionID, requests[4].sessionID)
        XCTAssertEqual(requests[4].query, .baseline(cursor: nil))
        XCTAssertEqual(result.scope, scope); XCTAssertEqual(result.generation, 2)
    }

    func testInvalidationClearsAccountAndRejectsCancellationIgnoringOldCompletion() async throws {
        let account = UUID(), scope = LibraryScope(accountID: account, readerSessionID: UUID()), id = UUID()
        let f = LibraryFixture(accountID: account)
        let script = LibraryScript([.data(f.baseline([f.row(id, created: 1)], high: 1)), .data(f.changes([], through: 1)), .held])
        let service = LibraryService(scope: scope, transport: script)
        _ = try await service.refresh()
        let old = Task { try await service.refresh() }
        await script.waitForRequests(3)
        await service.invalidate()
        let cleared = await service.snapshot(); XCTAssertNil(cleared)
        let nextScope = LibraryScope(accountID: account, readerSessionID: UUID())
        let nextScript = LibraryScript([.data(f.baseline([], high: 1)), .data(f.changes([], through: 1))])
        let next = LibraryService(scope: nextScope, transport: nextScript)
        let result = try await next.refresh()
        await script.release(f.changes([], through: 1))
        do { _ = try await old.value; XCTFail("Retired completion must fail") } catch is CancellationError { }
        let stillClear = await service.snapshot(), newSnapshot = await next.snapshot()
        XCTAssertNil(stillClear); XCTAssertEqual(newSnapshot, result)
        XCTAssertNotEqual(result.scope.readerSessionID, scope.readerSessionID)
        do { _ = try await service.refresh(); XCTFail("Retired service cannot restart") }
        catch LibraryServiceError.retired { }
    }

    func testCommandCatchupWaitsOutOlderPullAndPublishesTheWholeChangeGroup() async throws {
        let scope = LibraryScope(accountID: UUID(), readerSessionID: UUID()), first = UUID(), second = UUID()
        let f = LibraryFixture(accountID: scope.accountID)
        let script = LibraryScript([.data(f.baseline([f.row(first, created: 1), f.row(second, created: 2)], high: 2)),
                                    .data(f.changes([], through: 2)), .held, .held])
        let service = LibraryService(scope: scope, transport: script)
        _ = try await service.refresh()
        let oldPull = Task { try await service.refresh() }
        await script.waitForRequests(3)
        let commandPull = Task { try await service.refreshAfterCommand(minimumCursor: 3) }
        await script.release(f.changes([], through: 2))
        _ = try await oldPull.value
        await script.waitForRequests(4)
        let stillComplete = await service.snapshot()
        XCTAssertEqual(stillComplete?.committedCursor, 2)
        XCTAssertEqual(stillComplete?.imports.filter(\.visible).count, 2)
        await script.release(f.changes([(3, [f.row(first, created: 1, state: 3, visible: false),
                                               f.row(second, created: 2, state: 3, visible: false)])], through: 3))
        let result = try await commandPull.value
        XCTAssertEqual(result.committedCursor, 3)
        XCTAssertTrue(result.imports.allSatisfy { !$0.visible })
        let requests = await script.requests()
        XCTAssertEqual(requests[3].query, .changes(after: 2, through: nil))
    }

    func testAbsentConflictStillRequiresNewBoundaryAfterResumingInterruptedOldPage() async throws {
        let scope = LibraryScope(accountID: UUID(), readerSessionID: UUID()), first = UUID(), second = UUID()
        let f = LibraryFixture(accountID: scope.accountID)
        let script = LibraryScript([.data(f.baseline([f.row(first, created: 1)], high: 1)), .data(f.changes([], through: 1)),
                                    .data(f.changes([(2, [f.row(second, created: 2)])], through: 3, more: true)), .failure,
                                    .data(f.changes([(3, [f.row(first, created: 1, state: 3, visible: false)])], through: 3)), .held])
        let service = LibraryService(scope: scope, transport: script)
        let initial = try await service.refresh()
        do { _ = try await service.refresh(); XCTFail("Old page should be interrupted") } catch LibraryFixtureFailure.interrupted { }
        // An absent-item conflict has neither a receipt sequence nor an entry.
        let commandPull = Task { try await service.refreshAfterCommand(minimumCursor: 0) }
        await script.waitForRequests(6)
        let pending = await service.snapshot(); XCTAssertEqual(pending, initial)
        let requests = await script.requests()
        XCTAssertEqual(requests[3], requests[4])
        XCTAssertEqual(requests[5].query, .changes(after: 3, through: nil))
        await script.release(f.changes([(4, [f.row(second, created: 2, state: 4, visible: false)])], through: 4))
        let result = try await commandPull.value
        XCTAssertEqual(result.generation, 2); XCTAssertEqual(result.committedCursor, 4)
        XCTAssertTrue(result.imports.allSatisfy { !$0.visible })
    }

    func testUnobservedReceiptCannotFabricateCursorOrSpinAndCanRetryLater() async throws {
        let scope = LibraryScope(accountID: UUID(), readerSessionID: UUID()), id = UUID()
        let f = LibraryFixture(accountID: scope.accountID)
        let script = LibraryScript([.data(f.baseline([f.row(id, created: 1)], high: 1)), .data(f.changes([], through: 1)),
                                    .data(f.changes([], through: 1)),
                                    .data(f.changes([(4, [f.row(id, created: 1, state: 4, visible: false)])], through: 4))])
        let service = LibraryService(scope: scope, transport: script)
        let initial = try await service.refresh()
        do { _ = try await service.refreshAfterCommand(minimumCursor: 4); XCTFail("Receipt is not a consumed page") }
        catch LibraryServiceError.receiptNotObserved { }
        let pending = await service.snapshot(), requests = await script.requests()
        XCTAssertEqual(pending, initial); XCTAssertEqual(requests.count, 3)
        let result = try await service.refreshAfterCommand(minimumCursor: 4)
        XCTAssertEqual(result.generation, 2); XCTAssertEqual(result.committedCursor, 4)
    }

    func testRetirementWhileWaitingForCommandBoundaryDoesNotStartAnotherPull() async throws {
        let scope = LibraryScope(accountID: UUID(), readerSessionID: UUID())
        let f = LibraryFixture(accountID: scope.accountID)
        let script = LibraryScript([.data(f.baseline([], high: 0)), .data(f.changes([], through: 0)), .held])
        let service = LibraryService(scope: scope, transport: script)
        _ = try await service.refresh()
        let old = Task { try await service.refresh() }
        await script.waitForRequests(3)
        let command = Task { try await service.refreshAfterCommand(minimumCursor: 1) }
        await service.invalidate()
        await script.release(f.changes([], through: 0))
        do { _ = try await old.value; XCTFail("Old pull must be fenced") } catch { }
        do { _ = try await command.value; XCTFail("Command pull must be fenced") } catch { }
        let requests = await script.requests(), snapshot = await service.snapshot()
        XCTAssertEqual(requests.count, 3); XCTAssertNil(snapshot)
    }
}

private final class LibraryTestProtocol: URLProtocol, @unchecked Sendable {
    struct Route: Sendable {
        let start: @Sendable (LibraryTestProtocol) -> Void
        let stop: @Sendable () -> Void
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]
    static func install(_ host: String, route: Route) { lock.withLock { routes[host] = route } }
    static func remove(_ host: String) { _ = lock.withLock { routes.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host, let route = Self.lock.withLock({ Self.routes[host] }) else { return }
        route.start(self)
    }
    override func stopLoading() {
        guard let host = request.url?.host, let route = Self.lock.withLock({ Self.routes[host] }) else { return }
        route.stop()
    }
    func respond(_ data: Data, status: Int = 200, finish: Bool = true, headers: [String: String] = [:]) {
        var headers = headers; headers["Content-Type"] = "application/json"
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        if finish { client?.urlProtocolDidFinishLoading(self) }
    }
}

private final class LibraryHTTPServer: @unchecked Sendable {
    struct Reply: Sendable { let data: Data; var status = 200; var finish = true; var headers: [String: String] = [:] }
    private let lock = NSLock()
    let account: UUID
    let arrived = XCTestExpectation(description: "Library HTTP request held")
    let cancelled = XCTestExpectation(description: "Library transfer cancelled")
    private var pending: LibraryTestProtocol?
    private var replies: [Reply]
    private var captured: [URLRequest] = []
    var holdNext = false
    init(account: UUID, replies: [Reply] = []) { self.account = account; self.replies = replies }
    func handle(_ request: LibraryTestProtocol) {
        lock.withLock {
            if request.request.url?.path == "/auth/v1/token" {
                request.respond(try! ReaderCrypto.encode(AuthSession(access_token: "fixture-library-token", refresh_token: "fixture-refresh",
                    expires_at: Date().timeIntervalSince1970 + 3_600, user: .init(id: account, email: nil))))
            } else if request.request.url?.path == "/auth/v1/logout" { request.respond(Data("{}".utf8)) }
            else {
                captured.append(request.request)
                if holdNext { holdNext = false; pending = request; arrived.fulfill() }
                else if !replies.isEmpty {
                    let reply = replies.removeFirst()
                    request.respond(reply.data, status: reply.status, finish: reply.finish, headers: reply.headers)
                } else { request.respond(Data("{}".utf8), status: 503) }
            }
        }
    }
    func release(_ reply: Reply) {
        lock.withLock { pending?.respond(reply.data, status: reply.status, finish: reply.finish, headers: reply.headers); pending = nil }
    }
    func requests() -> [URLRequest] { lock.withLock { captured } }
    func append(_ replies: [Reply]) { lock.withLock { self.replies += replies } }
}

@MainActor
final class LibraryTransportTests: XCTestCase {
    private func fixture(_ server: LibraryHTTPServer) throws -> (BackendClient, String, String) {
        let environment = "library-transport-\(UUID().wire)", host = environment + ".invalid"
        LibraryTestProtocol.install(host, route: .init(start: { server.handle($0) }, stop: { server.cancelled.fulfill() }))
        let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = [LibraryTestProtocol.self]
        let client = try BackendClient(configuration: .init(url: URL(string: "https://\(host)")!, anonKey: "fixture", environment: environment),
                                       network: URLSession(configuration: settings))
        return (client, environment, host)
    }
    private func clean(_ environment: String, _ host: String) {
        LibraryTestProtocol.remove(host); try? KeychainVault.delete(environment + ".auth-session")
    }
    private func bodyData(_ request: URLRequest) -> Data {
        let data: Data
        if let bytes = request.httpBody { data = bytes }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096), bytes = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
            }
            data = bytes
        } else { data = Data() }
        return data
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData(request)) as? [String: Any])
    }
    private func command(account: UUID, host: String) async throws -> (LibraryCommandAttempt, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        let store = try EncryptedStore(url: directory.appendingPathComponent("queue.sqlite"), accountID: account,
                                       localKey: ReaderCrypto.randomKey(), keys: KeyBundle.generate(accountID: account))
        let scope = try LibraryCommandScope(accountID: account, deploymentID: "https://\(host)")
        let handle = try await store.enqueueLibraryCommand(scope: scope,
            mutation: .beginImport(sourceID: "2601.00001", requestedRevision: nil, observedCursor: 7))
        return (try await store.beginLibraryAttempt(handle, scope: scope), directory)
    }

    func testExactMissingCapabilitiesChoosesFreshLegacyBaseline() async throws {
        let account = UUID(), f = LibraryFixture(accountID: account)
        let missing = Data(#"{"code":"PGRST202","message":"Could not find the function public.v1_reader_capabilities without parameters in the schema cache"}"#.utf8)
        let server = LibraryHTTPServer(account: account, replies: [
            .init(data: missing, status: 404), .init(data: f.baseline([], high: 0)), .init(data: f.changes([], through: 0))])
        let (client, environment, host) = try fixture(server)
        defer { clean(environment, host) }
        _ = try await client.signIn(email: "fixture@example.invalid", password: "fixture")
        let service = LibraryService(scope: .init(accountID: account, readerSessionID: UUID()), transport: client)
        let result = try await service.refresh()
        XCTAssertEqual(result.observation.readContext, .legacyFull3)
        XCTAssertEqual(server.requests().map { $0.url!.lastPathComponent }, ["v1_reader_capabilities", "v3_library_page", "v3_library_changes"])
    }

    func testBoundedTransportUsesV2ParametersAndPreservesExactRequestOwnership() async throws {
        let account = UUID(), f = LibraryFixture(accountID: account), id = UUID()
        let server = LibraryHTTPServer(account: account, replies: [
            .init(data: f.baseline([f.row(id, created: 1)], high: 1, more: true)),
            .init(data: f.baseline([], high: 1)), .init(data: f.changes([], through: 1))])
        let (client, environment, host) = try fixture(server)
        defer { clean(environment, host) }
        _ = try await client.signIn(email: "fixture@example.invalid", password: "fixture")
        var reconciler = LibraryReconciler(accountID: account)
        let first = try reconciler.nextRequest(limit: 7), firstReply = try await client.libraryPage(first)
        XCTAssertEqual(firstReply.request, first)
        guard case .baseline(let firstPage) = firstReply.page else { return XCTFail("Expected baseline") }
        try reconciler.accept(firstPage, for: first)
        let second = try reconciler.nextRequest(limit: 7), secondReply = try await client.libraryPage(second)
        guard case .baseline(let secondPage) = secondReply.page else { return XCTFail("Expected baseline") }
        try reconciler.accept(secondPage, for: second)
        let third = try reconciler.nextRequest(limit: 7), thirdReply = try await client.libraryPage(third)
        XCTAssertEqual(thirdReply.request, third)
        let requests = server.requests()
        XCTAssertEqual(requests.map { $0.url!.lastPathComponent }, ["v3_library_page", "v3_library_page", "v3_library_changes"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-library-token" })
        let continuation = try XCTUnwrap(try body(requests[1])["p_cursor"] as? [String: Any])
        XCTAssertEqual(continuation["account_id"] as? String, account.wire)
        XCTAssertEqual(continuation["id"] as? String, id.wire)
        XCTAssertEqual(try body(requests[2])["p_after"] as? Int, 1)
        XCTAssertEqual(try body(requests[2])["p_limit"] as? Int, 7)
    }

    func testActualOversizeBytesCancelAnOpenTransferWithoutContentLength() async throws {
        let account = UUID()
        let server = LibraryHTTPServer(account: account, replies: [
            .init(data: Data(repeating: 32, count: LibraryWire.maximumPageBytes + 1), finish: false)])
        let (client, environment, host) = try fixture(server)
        defer { clean(environment, host) }
        _ = try await client.signIn(email: "fixture@example.invalid", password: "fixture")
        var reconciler = LibraryReconciler(accountID: account)
        do { _ = try await client.libraryPage(reconciler.nextRequest()); XCTFail("Actual byte cap must stop transfer") }
        catch LibraryProtocolError.payloadTooLarge { }
        await fulfillment(of: [server.cancelled], timeout: 5)
    }

    func testOnlyExactStructuredPostgresErrorMeansCompaction() async throws {
        let account = UUID(), f = LibraryFixture(accountID: account)
        let server = LibraryHTTPServer(account: account, replies: [
            .init(data: f.bytes(["code": "P0001", "message": "library_resync_required"]), status: 400),
            .init(data: f.bytes(["code": "other", "message": "library_resync_required"]), status: 400),
            .init(data: f.bytes(["code": "P0001", "message": "some library_resync_required text"]), status: 400),
            .init(data: f.bytes(["code": "P0001", "details": "library_resync_required"]), status: 400),
            .init(data: f.bytes(["code": "P0001", "message": "library_resync_required"]), status: 503),
            .init(data: f.bytes(["code": "P0001", "message": "library_resync_required"]), status: 200),
            .init(data: f.baseline([], high: 0))])
        let (client, environment, host) = try fixture(server)
        defer { clean(environment, host) }
        _ = try await client.signIn(email: "fixture@example.invalid", password: "fixture")
        var reconciler = LibraryReconciler(accountID: account)
        let request = try reconciler.nextRequest()
        do { _ = try await client.libraryPage(request); XCTFail("Trusted compaction must be typed") }
        catch LibraryTransportError.resyncRequired { }
        for _ in 0..<5 {
            do { _ = try await client.libraryPage(request); XCTFail("Invalid reply must fail") }
            catch is LibraryTransportError { XCTFail("Unrelated content is not compaction") }
            catch { }
        }
        _ = try await client.libraryPage(request)
    }

    func testWrongAccountIsRejectedBeforeNetworkAndLateErrorCannotResetNewLogin() async throws {
        let account = UUID(), f = LibraryFixture(accountID: account)
        let server = LibraryHTTPServer(account: account); server.holdNext = true
        let (client, environment, host) = try fixture(server)
        defer { clean(environment, host) }
        _ = try await client.signIn(email: "fixture@example.invalid", password: "fixture")
        var wrong = LibraryReconciler(accountID: UUID())
        do { _ = try await client.libraryPage(wrong.nextRequest()); XCTFail("Foreign account must fail") }
        catch BackendError.signInRequired { }
        XCTAssertTrue(server.requests().isEmpty)
        var right = LibraryReconciler(accountID: account)
        let request = try right.nextRequest()
        let old = Task { try await client.libraryPage(request) }
        await fulfillment(of: [server.arrived], timeout: 5)
        try await client.signOut()
        _ = try await client.signIn(email: "fixture@example.invalid", password: "fixture")
        server.release(.init(data: f.bytes(["code": "P0001", "message": "library_resync_required"]), status: 400))
        do { _ = try await old.value; XCTFail("Old auth generation must not deliver a compaction error") }
        catch is CancellationError { }
        let current = await client.currentUser(); XCTAssertEqual(current?.id, account)
    }

    func testCommandReplaySendsTheIdenticalDurablyPreparedBytesWithoutAutomaticRetry() async throws {
        let account = UUID(), f = LibraryFixture(accountID: account)
        let server = LibraryHTTPServer(account: account)
        let (client, environment, host) = try fixture(server)
        defer { clean(environment, host) }
        let (attempt, directory) = try await command(account: account, host: host)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = attempt.request.operationID
        server.append([.init(data: Data("unavailable".utf8), status: 503),
                       .init(data: f.bytes(["result": ["status": "applied", "kind": "import", "id": id.wire,
                                                      "seq": 8, "revision": 1],
                                           "replayed": true, "entry": f.row(id, created: 8)]))])
        _ = try await client.signIn(email: "fixture@example.invalid", password: "fixture")
        do { _ = try await client.libraryCommand(attempt); XCTFail("Uncertain response must fail") }
        catch BackendError.rejected(let code) { XCTAssertEqual(code, "request_failed") }
        XCTAssertEqual(server.requests().count, 1, "Transport does not retry on its own")
        let delivery = try await client.libraryCommand(attempt)
        XCTAssertEqual(delivery.attempt, attempt)
        XCTAssertTrue(delivery.response.replayed)
        let requests = server.requests()
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/v2_begin_import")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-library-token")
            XCTAssertEqual(bodyData(request), attempt.request.body)
        }
        let frozen = try XCTUnwrap(JSONSerialization.jsonObject(with: attempt.request.body) as? [String: Any])
        XCTAssertEqual(frozen["p_observed_cursor"] as? Int, 7)
        XCTAssertEqual(frozen["p_operation_id"] as? String, id.wire)
    }

    func testSourceKeywordEditSurvivesRestartAndUsesTheRealV5Transport() async throws {
        try await checkSourceKeywordEdit(tags: ["Numerical methods", "Graph neural networks"])
        // Source membership stores the complete keyword list, not only the 12 personal tags.
        try await checkSourceKeywordEdit(tags: (0..<32).map { String(format: "%02d ", $0) + String(repeating: "数", count: 35) })
    }

    private func checkSourceKeywordEdit(tags: [String]) async throws {
        let account = UUID(), imported = UUID(), epoch = UUID(), f = LibraryFixture(accountID: account)
        let server = LibraryHTTPServer(account: account)
        let (client, environment, host) = try fixture(server)
        defer { clean(environment, host) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("queue.sqlite"), key = ReaderCrypto.randomKey()
        let keys = KeyBundle.generate(accountID: account)
        let store = try EncryptedStore(url: url, accountID: account, localKey: key, keys: keys)
        let scope = try LibraryCommandScope(accountID: account, deploymentID: "https://\(host)")
        let context = LibraryReadContext.uploadFull5(datasetEpoch: epoch)
        func observation(_ rows: [[String: Any]], cursor: Int64) throws -> LibraryCompleteObservation {
            var reconciler = LibraryReconciler(accountID: account, readContext: context)
            let next: Any = rows.last.map { ["format": 2, "account_id": account.wire, "through": cursor,
                "created_seq": $0["created_seq"]!, "id": $0["id"]!, "kind": $0["kind"]!,
                "read_level": 4, "dataset_epoch": epoch.wire] as [String: Any] } ?? NSNull()
            try reconciler.accept(LibraryWire.decodeBaseline(f.bytes(["format": 2, "account_id": account.wire,
                "baseline_cursor": cursor, "retained_after": 0, "entries": rows, "next_cursor": next,
                "has_more": false, "dataset_epoch": epoch.wire])), for: reconciler.nextRequest())
            try reconciler.accept(LibraryWire.decodeChanges(f.bytes(["format": 2, "account_id": account.wire,
                "through": cursor, "retained_after": 0, "changes": [], "next_cursor": cursor,
                "has_more": false, "dataset_epoch": epoch.wire])), for: reconciler.nextRequest())
            return try reconciler.completeObservation()
        }
        try await store.saveLibraryPresentation(observation([f.row(imported, created: 7)], cursor: 7), scope: scope)
        let handle = try await store.enqueueLibraryCommand(scope: scope,
            mutation: .setSourceDetails(importID: imported, archived: false, tags: tags, expectedRevision: 1),
            readContext: context)
        let original = try await store.beginLibraryAttempt(handle, scope: scope, readContext: context)
        _ = try await store.recordLibraryFailure(.invalidResponse, for: original)
        let reopened = try EncryptedStore(url: url, accountID: account, localKey: key, keys: keys)
        let retry = try await reopened.beginLibraryAttempt(handle, scope: scope, readContext: context)
        XCTAssertEqual(retry.request, original.request, "An already queued edit keeps its operation and bytes")
        if tags.count == 32 { XCTAssertGreaterThan(retry.request.body.count, 2_048) }
        var entry = f.row(imported, created: 7, state: 8)
        entry["intent_revision"] = 2; entry["user_tags"] = tags; entry["archived"] = false
        server.append([.init(data: f.bytes(["result": ["status": "applied", "kind": "import", "id": imported.wire,
            "seq": 8, "revision": 2], "replayed": false, "entry": entry, "dataset_epoch": epoch.wire]))])
        _ = try await client.signIn(email: "fixture@example.invalid", password: "fixture")
        let delivery = try await client.libraryCommand(retry)
        let accepted = try await reopened.recordLibraryReceipt(delivery.response, for: retry)
        XCTAssertEqual(accepted.commands.first?.phase, .receiptAwaitingCatchup)
        let request = try XCTUnwrap(server.requests().first)
        XCTAssertEqual(server.requests().count, 1)
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/v5_set_source_details")
        XCTAssertEqual(bodyData(request), original.request.body)
        XCTAssertEqual(try body(request)["p_dataset_epoch"] as? String, epoch.wire)
        XCTAssertEqual(try body(request)["p_tags"] as? [String], tags)
        let receipt = try XCTUnwrap(accepted.commands.first?.receipt)
        let finished = try await reopened.reconcileLibraryCommands([.init(handle: handle, receiptID: receipt.id)],
            observation: observation([entry], cursor: 8), scope: scope)
        XCTAssertEqual(finished.commands.first?.phase, .finished, "Only confirmed catch-up clears the pending edit")
    }

    func testCommandErrorsRequireExactWhitelistedSQLAndHTTPStatus() async throws {
        let account = UUID(), f = LibraryFixture(accountID: account)
        let cases: [(LibraryHTTPServer.Reply, String)] = [
            (.init(data: f.bytes(["code": "P0001", "message": "operation_id_conflict"]), status: 400), "operation_id_conflict"),
            (.init(data: f.bytes(["code": "P0001", "message": "request_rate_limit"]), status: 400), "request_rate_limit"),
            (.init(data: f.bytes(["code": "P0001", "message": "library_account_item_limit"]), status: 400), "library_account_item_limit"),
            (.init(data: f.bytes(["code": "P0001", "message": "operation_id_conflict"]), status: 503), "request_failed"),
            // A busy server is not a conflict either: it says to wait (RESILIENCE.md fix 9).
            (.init(data: f.bytes(["code": "P0001", "message": "operation_id_conflict"]), status: 429), "throttled"),
            (.init(data: f.bytes(["code": "other", "message": "operation_id_conflict"]), status: 400), "request_failed"),
            (.init(data: f.bytes(["code": "P0001", "message": "some operation_id_conflict text"]), status: 400), "request_failed"),
            (.init(data: f.bytes(["code": "P0001", "details": "operation_id_conflict"]), status: 400), "request_failed"),
            (.init(data: f.bytes(["code": "P0001", "message": "key_authority_required"]), status: 400), "request_failed")
        ]
        let server = LibraryHTTPServer(account: account, replies: cases.map(\.0) + [.init(data: Data(), status: 401)])
        let (client, environment, host) = try fixture(server)
        defer { clean(environment, host) }
        let (attempt, directory) = try await command(account: account, host: host)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await client.signIn(email: "fixture@example.invalid", password: "fixture")
        for (_, expected) in cases {
            do { _ = try await client.libraryCommand(attempt); XCTFail("Error must reject") }
            catch BackendError.rejected(let code) { XCTAssertEqual(code, expected) }
            catch BackendError.throttled { XCTAssertEqual("throttled", expected) }
        }
        do { _ = try await client.libraryCommand(attempt); XCTFail("Expired auth must pause") }
        catch AuthenticationError.sessionExpired { }
        XCTAssertEqual(server.requests().count, cases.count + 1)
        let current = await client.currentUser(); XCTAssertNil(current)
    }

    func testCommandScopeFencesNetworkAndLateSuccessBelongsToOldAuthGeneration() async throws {
        let account = UUID(), f = LibraryFixture(accountID: account)
        let server = LibraryHTTPServer(account: account); server.holdNext = true
        let (client, environment, host) = try fixture(server)
        defer { clean(environment, host) }
        let (wrongAccount, firstDirectory) = try await command(account: UUID(), host: host)
        let (wrongOrigin, secondDirectory) = try await command(account: account, host: "other.invalid")
        let (attempt, directory) = try await command(account: account, host: host)
        defer { for url in [firstDirectory, secondDirectory, directory] { try? FileManager.default.removeItem(at: url) } }
        _ = try await client.signIn(email: "fixture@example.invalid", password: "fixture")
        do { _ = try await client.libraryCommand(wrongAccount); XCTFail("Foreign account must fail before HTTP") }
        catch BackendError.signInRequired { }
        do { _ = try await client.libraryCommand(wrongOrigin); XCTFail("Foreign deployment must fail before HTTP") }
        catch LibraryCommandError.invalidScope { }
        XCTAssertTrue(server.requests().isEmpty)
        let old = Task { try await client.libraryCommand(attempt) }
        await fulfillment(of: [server.arrived], timeout: 5)
        try await client.signOut()
        _ = try await client.signIn(email: "fixture@example.invalid", password: "fixture")
        let id = attempt.request.operationID
        server.release(.init(data: f.bytes(["result": ["status": "applied", "kind": "import", "id": id.wire,
                                                       "seq": 8, "revision": 1],
                                            "replayed": false, "entry": f.row(id, created: 8)])))
        do { _ = try await old.value; XCTFail("Old auth generation cannot deliver a receipt") }
        catch is CancellationError { }
        let current = await client.currentUser(); XCTAssertEqual(current?.id, account)
    }

    func testCommandResponseByteLimitCancelsAnUnfinishedOversizeTransfer() async throws {
        let account = UUID()
        let server = LibraryHTTPServer(account: account, replies: [
            .init(data: Data(repeating: 32, count: LibraryWire.maximumPageBytes + 1), finish: false)])
        let (client, environment, host) = try fixture(server)
        defer { clean(environment, host) }
        let (attempt, directory) = try await command(account: account, host: host)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await client.signIn(email: "fixture@example.invalid", password: "fixture")
        do { _ = try await client.libraryCommand(attempt); XCTFail("Actual byte cap must stop command response") }
        catch LibraryProtocolError.payloadTooLarge { }
        await fulfillment(of: [server.cancelled], timeout: 5)
        XCTAssertEqual(server.requests().count, 1)
    }
}
