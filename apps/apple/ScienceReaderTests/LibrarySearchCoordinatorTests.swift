import Foundation
import XCTest
@testable import ScienceReader

private enum SearchFixtureError: Error { case failed }

private enum SearchThreadObservation {
    // Read the calling thread synchronously, before an injected worker awaits
    // its gate. Do not hop to MainActor merely to perform the observation.
    nonisolated static func isMainThread() -> Bool { Thread.isMainThread }
}

private final class SearchArrival: @unchecked Sendable {
    let expectation: XCTestExpectation
    init(_ name: String) { expectation = XCTestExpectation(description: name) }
}

/// Completion deliberately ignores cancellation. A replacement must wait for
/// actual exit and must reject a late success or failure from the old worker.
private actor SearchWorkerControl {
    private let arrivals: [SearchArrival]
    private var held: [UUID: CheckedContinuation<[String], Error>] = [:]
    private var started: [LibrarySearchTicket] = []
    private var mainThreadEntries: [Bool] = []
    private var active = 0
    private var highestActive = 0
    private var aborted = false

    init(arrivals: [SearchArrival]) { self.arrivals = arrivals }

    func run(_ input: LibrarySearchInput, enteredOnMainThread: Bool) async throws -> [String] {
        active += 1
        highestActive = max(highestActive, active)
        defer { active -= 1 }
        started.append(input.ticket)
        mainThreadEntries.append(enteredOnMainThread)
        guard !aborted else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            held[input.ticket.id] = continuation
            if started.count <= arrivals.count { arrivals[started.count - 1].expectation.fulfill() }
        }
    }

    func complete(_ ticket: LibrarySearchTicket, _ result: Result<[String], Error>) -> Bool {
        guard let continuation = held.removeValue(forKey: ticket.id) else { return false }
        continuation.resume(with: result)
        return true
    }

    func snapshot() -> (tickets: [LibrarySearchTicket], maximumActive: Int, mainThreadEntries: [Bool]) {
        (started, highestActive, mainThreadEntries)
    }

    func abort() {
        aborted = true
        let continuations = Array(held.values)
        held.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor
private final class SearchPublications {
    var events: [LibrarySearchEvent] = []
    var completed: [LibrarySearchResult] {
        events.compactMap { if case .completed(let result) = $0 { result } else { nil } }
    }
    var failed: [LibrarySearchTicket] {
        events.compactMap { if case .failed(let ticket) = $0 { ticket } else { nil } }
    }
}

@MainActor
private final class SearchCoordinatorFixture {
    let arrivals: [SearchArrival]
    let control: SearchWorkerControl
    let publications = SearchPublications()
    let coordinator: LibrarySearchCoordinator

    init(expectedStarts: Int) {
        arrivals = (0..<expectedStarts).map { SearchArrival("worker \($0 + 1) started") }
        let control = SearchWorkerControl(arrivals: arrivals)
        self.control = control
        let publications = publications
        coordinator = LibrarySearchCoordinator(worker: { input in
            let enteredOnMainThread = SearchThreadObservation.isMainThread()
            return try await control.run(input, enteredOnMainThread: enteredOnMainThread)
        }, publish: { publications.events.append($0) })
    }

    func close() async {
        coordinator.invalidate()
        await control.abort()
        await coordinator.waitForIdle()
    }
}

@MainActor
private final class SearchReentrantPublisher {
    weak var coordinator: LibrarySearchCoordinator?
    let nextKey: LibrarySearchKey
    var tickets: [LibrarySearchTicket] = []
    var nextTicket: LibrarySearchTicket?

    init(nextKey: LibrarySearchKey) { self.nextKey = nextKey }

    func receive(_ event: LibrarySearchEvent) {
        guard case .completed(let result) = event else { return }
        tickets.append(result.ticket)
        if tickets.count == 1 { nextTicket = coordinator?.submit(key: nextKey, candidates: []) }
    }
}

@MainActor
final class LibrarySearchCoordinatorTests: XCTestCase {
    private let sessionID = UUID()
    private let accountID = UUID()

    private func key(_ query: String = "", sort: LibrarySearchSort = .recent,
                     sourceRevision: UInt64 = 1, commandRevision: Int64 = -1,
                     session: UUID? = nil, account: UUID? = nil) -> LibrarySearchKey {
        LibrarySearchKey(sessionID: session ?? sessionID, accountID: account ?? accountID,
            sourceRevision: sourceRevision, query: query, sort: sort, commandRevision: commandRevision)
    }

    private func candidate(_ id: String, title: String, fields: [String]? = nil,
                           sequence: Int64 = 1, position: Int = 0) -> LibrarySearchCandidate {
        LibrarySearchCandidate(id: id, title: title, fields: fields ?? [title],
                               recentSequence: sequence, position: position)
    }

    private func search(_ query: String, rows: [LibrarySearchCandidate],
                        sort: LibrarySearchSort = .recent) throws -> [String] {
        try LibrarySearchEngine.search(.init(ticket: .init(key: key(query, sort: sort)), candidates: rows))
    }

    func testLocalizedTermsMatchOriginalPaperImportAndQueuedFields() throws {
        let rows = [
            candidate("paper/p", title: "Neural methods", fields: ["Neural methods", "Zoë Researcher",
                "A sparse hidden abstract", "2601.00001v2", "cs.LG"], sequence: 1, position: 0),
            candidate("import/i", title: "Pending title", fields: ["2601.00002v3", "Pending title",
                "A geometric abstract", "René Researcher", "stat.ML"], sequence: 2, position: 1),
            candidate("import/q", title: "Queued paper", fields: ["Queued paper", "2601.00003v4"],
                      sequence: .max, position: 2)
        ]
        XCTAssertEqual(try search("  ZOE\tcs.lg\n00001v2  ", rows: rows), ["paper/p"])
        XCTAssertEqual(try search("hidden sparse", rows: rows), ["paper/p"])
        XCTAssertEqual(try search("rene geometric stat.ml", rows: rows), ["import/i"])
        XCTAssertEqual(try search("queued 00003v4", rows: rows), ["import/q"])
        XCTAssertEqual(try search("neural stat.ml", rows: rows), [])
        XCTAssertEqual(try search("00003v2", rows: rows), [])
    }

    func testWhitespaceQueryIncludesRowsWithNoFieldsAndRecentKeepsOriginalTieOrder() throws {
        let rows = [
            candidate("paper/later", title: "Earlier alphabetically", fields: [], sequence: 4, position: 9),
            candidate("paper/first", title: "Later alphabetically", fields: [], sequence: 4, position: 2),
            candidate("import/q", title: "Newest local", fields: [], sequence: .max, position: 12),
            candidate("paper/old", title: "Old", fields: [], sequence: 3, position: 0)
        ]
        XCTAssertEqual(try search(" \t\n", rows: rows),
                       ["import/q", "paper/first", "paper/later", "paper/old"])
        XCTAssertEqual(try search("anything", rows: rows), [])
    }

    func testTitleSortUsesLocalizedTitleThenStableRowIDAcrossRowKinds() throws {
        let rows = [
            candidate("paper/z", title: "Shared title", sequence: .max, position: 0),
            candidate("paper/a", title: "Shared title", sequence: 2, position: 1),
            candidate("import/z", title: "Shared title", sequence: 1, position: 2),
            candidate("paper/alpha", title: "Alpha", sequence: 0, position: 3)
        ]
        XCTAssertEqual(try search("", rows: rows, sort: .title),
                       ["paper/alpha", "import/z", "paper/a", "paper/z"])
    }

    func testCanceledTaskCannotEnterPureSearchAfterAnAwaitedWorkerStage() async {
        let arrival = SearchArrival("cancellation checkpoint")
        let control = SearchWorkerControl(arrivals: [arrival])
        let input = LibrarySearchInput(ticket: .init(key: key()),
            candidates: [candidate("paper/p", title: "Paper")])
        let task = Task.detached {
            _ = try await control.run(input, enteredOnMainThread: SearchThreadObservation.isMainThread())
            return try LibrarySearchEngine.search(input)
        }
        await fulfillment(of: [arrival.expectation], timeout: 2)
        task.cancel()
        let released = await control.complete(input.ticket, .success([]))
        XCTAssertTrue(released)
        await control.abort()
        switch await task.result {
        case .success: XCTFail("Canceled pure search returned rows")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
    }

    func testReplacementWaitsForRunningWorkerAndOnlyLatestPendingStarts() async {
        let fixture = SearchCoordinatorFixture(expectedStarts: 2)
        let first = fixture.coordinator.submit(key: key("a"), candidates: [])
        await fulfillment(of: [fixture.arrivals[0].expectation], timeout: 2)
        let ignored = fixture.coordinator.submit(key: key("b"), candidates: [])
        let latest = fixture.coordinator.submit(key: key("c"), candidates: [])
        let waiting = SearchArrival("idle join installed")
        var idleReturned = false
        let join = Task { @MainActor in
            waiting.expectation.fulfill()
            await fixture.coordinator.waitForIdle()
            idleReturned = true
        }
        await fulfillment(of: [waiting.expectation], timeout: 2)
        let beforeRelease = await fixture.control.snapshot()
        XCTAssertEqual(beforeRelease.tickets, [first])
        XCTAssertFalse(idleReturned)
        let releasedFirst = await fixture.control.complete(first, .success(["old"]))
        XCTAssertTrue(releasedFirst)
        await fulfillment(of: [fixture.arrivals[1].expectation], timeout: 2)
        XCTAssertTrue(fixture.publications.events.isEmpty)
        XCTAssertFalse(idleReturned)
        let releasedLatest = await fixture.control.complete(latest, .success(["current"]))
        XCTAssertTrue(releasedLatest)
        await fixture.control.abort()
        await join.value
        let final = await fixture.control.snapshot()
        XCTAssertEqual(final.tickets, [first, latest])
        XCTAssertFalse(final.tickets.contains(ignored))
        XCTAssertEqual(final.maximumActive, 1)
        XCTAssertEqual(fixture.publications.completed.map(\.ticket), [latest])
        XCTAssertEqual(fixture.publications.completed.first?.rowIDs, ["current"])
        XCTAssertTrue(idleReturned)
        await fixture.close()
    }

    func testReturningToIdenticalKeyRejectsOriginalSubmissionNonce() async {
        let fixture = SearchCoordinatorFixture(expectedStarts: 2)
        let sameKey = key("a")
        let first = fixture.coordinator.submit(key: sameKey, candidates: [])
        await fulfillment(of: [fixture.arrivals[0].expectation], timeout: 2)
        fixture.coordinator.submit(key: key("b"), candidates: [])
        let latest = fixture.coordinator.submit(key: sameKey, candidates: [])
        XCTAssertEqual(first.key, latest.key)
        XCTAssertNotEqual(first.id, latest.id)
        let releasedFirst = await fixture.control.complete(first, .success(["old-a"]))
        XCTAssertTrue(releasedFirst)
        await fulfillment(of: [fixture.arrivals[1].expectation], timeout: 2)
        XCTAssertTrue(fixture.publications.events.isEmpty)
        let releasedLatest = await fixture.control.complete(latest, .success(["new-a"]))
        XCTAssertTrue(releasedLatest)
        await fixture.control.abort()
        await fixture.coordinator.waitForIdle()
        XCTAssertEqual(fixture.publications.completed.map(\.ticket), [latest])
        XCTAssertEqual(fixture.publications.completed.first?.rowIDs, ["new-a"])
        await fixture.close()
    }

    func testInvalidationDiscardsPendingAndLateFailureBeforeNextAccountStarts() async {
        let fixture = SearchCoordinatorFixture(expectedStarts: 2)
        let old = fixture.coordinator.submit(key: key("old"), candidates: [])
        await fulfillment(of: [fixture.arrivals[0].expectation], timeout: 2)
        fixture.coordinator.submit(key: key("old pending"), candidates: [])
        fixture.coordinator.invalidate()
        let nextKey = key("new", sourceRevision: 2, commandRevision: 3, session: UUID(), account: UUID())
        let next = fixture.coordinator.submit(key: nextKey, candidates: [])
        let beforeRelease = await fixture.control.snapshot()
        XCTAssertEqual(beforeRelease.tickets, [old])
        let releasedOld = await fixture.control.complete(old, .failure(SearchFixtureError.failed))
        XCTAssertTrue(releasedOld)
        await fulfillment(of: [fixture.arrivals[1].expectation], timeout: 2)
        XCTAssertTrue(fixture.publications.events.isEmpty)
        let releasedNext = await fixture.control.complete(next, .success(["new-account"]))
        XCTAssertTrue(releasedNext)
        await fixture.control.abort()
        await fixture.coordinator.waitForIdle()
        let final = await fixture.control.snapshot()
        XCTAssertEqual(final.tickets, [old, next])
        XCTAssertEqual(final.maximumActive, 1)
        XCTAssertEqual(fixture.publications.completed.map(\.ticket), [next])
        XCTAssertTrue(fixture.publications.failed.isEmpty)
        await fixture.close()
    }

    func testInvalidateWithoutReplacementJoinsAndPublishesNothing() async {
        let fixture = SearchCoordinatorFixture(expectedStarts: 1)
        let ticket = fixture.coordinator.submit(key: key(), candidates: [])
        await fulfillment(of: [fixture.arrivals[0].expectation], timeout: 2)
        fixture.coordinator.invalidate()
        let released = await fixture.control.complete(ticket, .success(["retired"]))
        XCTAssertTrue(released)
        await fixture.control.abort()
        await fixture.coordinator.waitForIdle()
        XCTAssertTrue(fixture.publications.events.isEmpty)
        await fixture.close()
    }

    func testCurrentFailureIsFiniteAndCarriesExactTicket() async {
        let fixture = SearchCoordinatorFixture(expectedStarts: 1)
        let ticket = fixture.coordinator.submit(key: key(commandRevision: 8), candidates: [])
        await fulfillment(of: [fixture.arrivals[0].expectation], timeout: 2)
        let released = await fixture.control.complete(ticket, .failure(SearchFixtureError.failed))
        XCTAssertTrue(released)
        await fixture.control.abort()
        await fixture.coordinator.waitForIdle()
        XCTAssertEqual(fixture.publications.failed, [ticket])
        XCTAssertTrue(fixture.publications.completed.isEmpty)
        await fixture.close()
    }

    func testWorkerRunsAwayFromMainThreadAndMainActorRemainsAvailableWhileHeld() async {
        let fixture = SearchCoordinatorFixture(expectedStarts: 1)
        let ticket = fixture.coordinator.submit(key: key(), candidates: [])
        await fulfillment(of: [fixture.arrivals[0].expectation], timeout: 2)
        var mainActorMarker = false
        await Task { @MainActor in mainActorMarker = true }.value
        XCTAssertTrue(mainActorMarker)
        let snapshot = await fixture.control.snapshot()
        XCTAssertEqual(snapshot.mainThreadEntries, [false])
        XCTAssertTrue(fixture.publications.events.isEmpty)
        let released = await fixture.control.complete(ticket, .success([]))
        XCTAssertTrue(released)
        await fixture.control.abort()
        await fixture.coordinator.waitForIdle()
        let elapsed = fixture.publications.completed.first?.workerElapsedMilliseconds
        XCTAssertNotNil(elapsed)
        XCTAssertTrue(elapsed?.isFinite == true)
        XCTAssertGreaterThanOrEqual(elapsed ?? -1, 0)
        await fixture.close()
    }

    func testReentrantPublicationCanSubmitWithoutStartingTwoWorkers() async {
        let arrivals = [SearchArrival("first reentrant worker"), SearchArrival("second reentrant worker")]
        let control = SearchWorkerControl(arrivals: arrivals)
        let receiver = SearchReentrantPublisher(nextKey: key("next"))
        let coordinator = LibrarySearchCoordinator(worker: { input in
            try await control.run(input, enteredOnMainThread: SearchThreadObservation.isMainThread())
        }, publish: { receiver.receive($0) })
        receiver.coordinator = coordinator
        let first = coordinator.submit(key: key("first"), candidates: [])
        await fulfillment(of: [arrivals[0].expectation], timeout: 2)
        let releasedFirst = await control.complete(first, .success(["first"]))
        XCTAssertTrue(releasedFirst)
        await fulfillment(of: [arrivals[1].expectation], timeout: 2)
        if let next = receiver.nextTicket {
            let releasedNext = await control.complete(next, .success(["next"]))
            XCTAssertTrue(releasedNext)
        } else { XCTFail("Publication did not submit its replacement") }
        await control.abort()
        await coordinator.waitForIdle()
        let snapshot = await control.snapshot()
        XCTAssertEqual(snapshot.maximumActive, 1)
        XCTAssertEqual(receiver.tickets, snapshot.tickets)
        XCTAssertEqual(receiver.tickets.count, 2)
        coordinator.invalidate()
    }

    func testDefaultWorkerReturnsSortedIDsWithExactKeyAndFiniteTiming() async {
        let publications = SearchPublications()
        let coordinator = LibrarySearchCoordinator { publications.events.append($0) }
        let request = key("paper", sort: .title, sourceRevision: 42, commandRevision: 7)
        let ticket = coordinator.submit(key: request, candidates: [
            candidate("paper/b", title: "B paper", position: 0),
            candidate("paper/a", title: "A paper", position: 1),
            candidate("paper/c", title: "Unrelated", position: 2)
        ])
        await coordinator.waitForIdle()
        XCTAssertEqual(publications.completed.map(\.ticket), [ticket])
        XCTAssertEqual(publications.completed.first?.ticket.key, request)
        XCTAssertEqual(publications.completed.first?.rowIDs, ["paper/a", "paper/b"])
        XCTAssertTrue(publications.failed.isEmpty)
        XCTAssertTrue(publications.completed.first?.workerElapsedMilliseconds.isFinite == true)
        coordinator.invalidate()
    }
}
