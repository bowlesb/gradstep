import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

private enum LibraryFixtureFailure: Error { case interrupted, unexpectedRequest }

private actor LibraryScript: LibraryTransport {
    enum Step: Sendable {
        case data(Data), held, failure, compaction
        case wrongOwner(Data, LibraryPageRequest)
    }
    private var steps: [Step]
    private var captured: [LibraryPageRequest] = []
    private var held: CheckedContinuation<Data, Error>?
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    init(_ steps: [Step]) { self.steps = steps }
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
    func baseline(_ rows: [[String: Any]], high: Int64, more: Bool = false) -> Data {
        let cursor: Any = rows.last.map {
            ["format": 2, "account_id": accountID.wire, "through": high,
             "created_seq": $0["created_seq"]!, "id": $0["id"]!, "kind": $0["kind"]!] as [String: Any]
        } ?? (NSNull() as Any)
        return bytes(["format": 2, "account_id": accountID.wire, "baseline_cursor": high, "retained_after": 0,
                      "entries": rows, "next_cursor": cursor, "has_more": more])
    }
    func changes(_ rows: [(Int64, [[String: Any]])], through: Int64, more: Bool = false) -> Data {
        bytes(["format": 2, "account_id": accountID.wire, "through": through, "retained_after": 0,
               "changes": rows.map { ["seq": $0.0, "entries": $0.1] as [String: Any] },
               "next_cursor": more ? (rows.last?.0 ?? 0) : through, "has_more": more])
    }
}

@MainActor
final class LibraryServiceTests: XCTestCase {
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
    private func body(_ request: URLRequest) throws -> [String: Any] {
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
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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
        XCTAssertEqual(requests.map { $0.url!.lastPathComponent }, ["v2_library_page", "v2_library_page", "v2_library_changes"])
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
}
