import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

private final class ModelSearchArrival: @unchecked Sendable {
    let expectation: XCTestExpectation
    init(_ name: String) { expectation = XCTestExpectation(description: name) }
}

/// Compute the real metadata result before holding it. Returning that captured
/// result ignores later cancellation so model/session ownership is exercised.
private actor ModelSearchWorker {
    private let arrivals: [ModelSearchArrival]
    private var inputs: [LibrarySearchInput] = []
    private var held: [Int: (CheckedContinuation<[String], Never>, [String])] = [:]
    private var passThrough = false

    init(arrivals: [ModelSearchArrival]) { self.arrivals = arrivals }

    func run(_ input: LibrarySearchInput) async throws -> [String] {
        let rows = try LibrarySearchEngine.search(input)
        let index = inputs.count
        inputs.append(input)
        guard !passThrough, index < arrivals.count else { return rows }
        return await withCheckedContinuation { continuation in
            held[index] = (continuation, rows)
            arrivals[index].expectation.fulfill()
        }
    }

    func recorded() -> [LibrarySearchInput] { inputs }

    func release(_ index: Int) -> Bool {
        guard let (continuation, rows) = held.removeValue(forKey: index) else { return false }
        continuation.resume(returning: rows)
        return true
    }

    func finish() {
        passThrough = true
        let remaining = Array(held.values)
        held.removeAll()
        for (continuation, rows) in remaining { continuation.resume(returning: rows) }
    }
}

@MainActor
private final class ModelSearchFixture {
    let model: ReaderModel
    let worker: ModelSearchWorker
    let arrivals: [ModelSearchArrival]

    init(expectedStarts: Int, configuration: BackendConfiguration? = nil, client: BackendClient? = nil) {
        arrivals = (0..<expectedStarts).map { ModelSearchArrival("model search \($0 + 1) started") }
        let worker = ModelSearchWorker(arrivals: arrivals)
        self.worker = worker
        model = ReaderModel(configuration: configuration, client: client,
                            librarySearchWorker: { try await worker.run($0) })
    }

    func close() async {
        await worker.finish()
        await model.waitForLibrarySearch()
        await model.waitForLocalRetirement()
    }
}

/// Even an accidental auth request fails in-process. Empty-session sign-out
/// should never enter this protocol, and no request can reach a real backend.
private final class SearchModelNoNetworkProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Guest search session retirement must not make an HTTP request")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

@MainActor
final class LibrarySearchModelTests: XCTestCase {
    private func paper(_ title: String, id: UUID = UUID(), artifactID: UUID? = nil,
                       fileURL: URL? = nil) -> Paper {
        Paper(id: id, title: title, authors: "A Researcher", year: 2026,
              abstract: "A synthetic metadata search fixture", keywords: ["cs.LG"],
              fileURL: fileURL, artifactID: artifactID, isSample: true)
    }

    private func started(_ index: Int, in fixture: ModelSearchFixture,
                         file: StaticString = #filePath, line: UInt = #line) async -> LibrarySearchInput? {
        await fulfillment(of: [fixture.arrivals[index].expectation], timeout: 3)
        let inputs = await fixture.worker.recorded()
        guard inputs.indices.contains(index) else {
            XCTFail("Expected the held model search", file: file, line: line)
            return nil
        }
        return inputs[index]
    }

    private func release(_ index: Int, in fixture: ModelSearchFixture,
                         file: StaticString = #filePath, line: UInt = #line) async {
        let released = await fixture.worker.release(index)
        XCTAssertTrue(released, "The exact held worker must be released", file: file, line: line)
    }

    private func assertSearchingWithoutRows(_ model: ReaderModel,
                                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(model.librarySearchPending, file: file, line: line)
        XCTAssertTrue(model.libraryRows.isEmpty, "Old matches must not describe the new query", file: file, line: line)
        XCTAssertTrue(model.filteredPapers.isEmpty, file: file, line: line)
        XCTAssertNil(model.librarySearchIssue, file: file, line: line)
    }

    /// The Library / ML paper search switch keeps the words (owner, TestFlight 91 session: "I just switched, but the text
    /// disappeared") and searches them in the new scope.
    func testTheScopeSwitchCarriesTheWordsBothWaysAndSearchesThem() async {
        let fixture = ModelSearchFixture(expectedStarts: 0)
        let model = fixture.model
        model.libraryQuery = "diffusion policy"
        model.setSearchScope(external: true)
        XCTAssertTrue(model.searchExternal)
        XCTAssertEqual(model.searchQuery, "diffusion policy")
        // Searched at once (signed out here, so the failure says so; never empty results).
        XCTAssertEqual(model.discoveryState, .failed("Sign in to search ML papers."))
        model.searchQuery = "diffusion policy robot"
        model.setSearchScope(external: false)
        XCTAssertFalse(model.searchExternal)
        XCTAssertEqual(model.libraryQuery, "diffusion policy robot")
        XCTAssertEqual(model.searchQuery, "diffusion policy robot")
        await fixture.close()
    }

    /// ML paper search results are measured against the words alone (not Search by fields' names or years), at their
    /// arXiv ID, title, abstract (with word endings folded, as arXiv does) and authors.
    func testMLPaperSearchMatchesMeasureTheWordsInEachResult() throws {
        XCTAssertEqual(ReaderModel.discoveryMatchQuery(#"title:"diffusion policy" author:"Chi" year:"2024""#).clauses.map(\.text),
                       ["diffusion policy", "Chi"])
        let json = #"{"source_id":"2610.03011","revision":1,"title":"Diffusion Policies for Robot Manipulation","authors":["Hiro Tanaka"],"year":2026,"abstract":"A learned policy.","categories":["cs.RO"]}"#
        let result = try JSONDecoder().decode(DiscoveryResult.self, from: Data(json.utf8))
        let match = ReaderModel.discoveryMatch(result, query: ReaderModel.discoveryMatchQuery("diffusion learning tanaka 2610.03011"))
        XCTAssertEqual(match.match.label, "100% · ID, title, abstract, authors")
        XCTAssertEqual(match.titleHighlights, [0..<9])
        XCTAssertEqual(match.excerpt?.firstMatch, "learned")
        let partial = ReaderModel.discoveryMatch(result, query: ReaderModel.discoveryMatchQuery("robot transformer world"))
        XCTAssertEqual(partial.match.label, "33% · title")
    }

    func testQueryAToBToAOnlyPublishesTheLastIntentAndHidesOldRowsWhilePending() async {
        let fixture = ModelSearchFixture(expectedStarts: 3)
        let model = fixture.model
        let alpha = paper("Alpha paper"), beta = paper("Beta paper")
        model.papers = [alpha, beta]
        guard await started(0, in: fixture) != nil else { await fixture.close(); return }
        await release(0, in: fixture)
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.filteredPapers.map(\.id), [alpha.id, beta.id])

        model.libraryQuery = "alpha"
        assertSearchingWithoutRows(model)
        guard let firstA = await started(1, in: fixture) else { await fixture.close(); return }
        model.libraryQuery = "beta"
        assertSearchingWithoutRows(model)
        model.libraryQuery = "alpha"
        assertSearchingWithoutRows(model)

        await release(1, in: fixture)
        guard let lastA = await started(2, in: fixture) else { await fixture.close(); return }
        XCTAssertEqual(firstA.ticket.key, lastA.ticket.key)
        XCTAssertNotEqual(firstA.ticket.id, lastA.ticket.id)
        assertSearchingWithoutRows(model)
        await release(2, in: fixture)
        await model.waitForLibrarySearch()

        XCTAssertFalse(model.librarySearchPending)
        XCTAssertNil(model.librarySearchIssue)
        XCTAssertEqual(model.filteredPapers.map(\.id), [alpha.id])
        let inputs = await fixture.worker.recorded()
        XCTAssertEqual(inputs.map { $0.ticket.key.query }, ["", "alpha", "alpha"])
        await fixture.close()
    }

    func testSameQueryRefreshRetainsSurvivorsAndHeldSourceCannotReviveRemovedPaper() async {
        let fixture = ModelSearchFixture(expectedStarts: 3)
        let model = fixture.model
        let removed = paper("Common removed"), retained = paper("Common retained"), added = paper("Common added")
        let revised = paper("Common revised", id: retained.id)
        let latest = paper("Common latest")
        model.papers = [removed, retained]
        model.libraryQuery = "common"
        guard let before = await started(0, in: fixture) else { await fixture.close(); return }
        await release(0, in: fixture)
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.filteredPapers.map(\.id), [removed.id, retained.id])

        model.papers = [revised, added]
        XCTAssertTrue(model.librarySearchPending)
        XCTAssertTrue(model.librarySearchKeepsCurrentRows)
        XCTAssertEqual(model.filteredPapers.map(\.id), [retained.id], "Remove obsolete rows synchronously")
        XCTAssertEqual(model.filteredPapers.first?.title, revised.title)
        model.select(removed)
        XCTAssertNil(model.selectedPaper, "A captured removed row must also fail selection")
        guard let refreshed = await started(1, in: fixture) else { await fixture.close(); return }
        XCTAssertNotEqual(before.ticket.key.sourceRevision, refreshed.ticket.key.sourceRevision)

        model.papers = [revised, latest]
        XCTAssertTrue(model.librarySearchPending)
        XCTAssertTrue(model.librarySearchKeepsCurrentRows)
        XCTAssertEqual(model.filteredPapers.map(\.id), [retained.id])
        await release(1, in: fixture)
        guard let after = await started(2, in: fixture) else { await fixture.close(); return }
        XCTAssertEqual(before.ticket.key.query, after.ticket.key.query)
        XCTAssertNotEqual(refreshed.ticket.key.sourceRevision, after.ticket.key.sourceRevision)
        XCTAssertTrue(model.librarySearchPending)
        XCTAssertEqual(model.filteredPapers.map(\.id), [retained.id], "The canceled result must not restore its added row")
        await release(2, in: fixture)
        await model.waitForLibrarySearch()

        XCTAssertFalse(model.librarySearchPending)
        XCTAssertNil(model.librarySearchIssue)
        XCTAssertEqual(model.filteredPapers.map(\.id), [retained.id, latest.id])
        XCTAssertFalse(model.libraryRows.contains { $0.id == "paper/\(removed.id.wire)" })
        XCTAssertFalse(model.libraryRows.contains { $0.id == "paper/\(added.id.wire)" })
        let inputs = await fixture.worker.recorded()
        XCTAssertEqual(inputs.count, 3)
        await fixture.close()
    }

    func testEquivalentMetadataRetryCannotReuseCompletedMatchesFromPreviousSource() async {
        let fixture = ModelSearchFixture(expectedStarts: 3)
        let model = fixture.model
        let firstID = UUID(), secondID = UUID()
        let previousMatch = paper("Target original", id: firstID)
        let previousOther = paper("Unrelated original", id: secondID)
        model.papers = [previousMatch, previousOther]
        model.libraryQuery = "target"
        guard let completed = await started(0, in: fixture) else { await fixture.close(); return }
        await release(0, in: fixture)
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.filteredPapers.map(\.id), [firstID])

        // Keep both identities, but swap which metadata matches. Reusing the
        // completed source's IDs would produce a valid row with the wrong match.
        let currentOther = paper("Unrelated changed", id: firstID)
        let currentMatch = paper("Target changed", id: secondID)
        model.papers = [currentOther, currentMatch]
        guard let changed = await started(1, in: fixture) else { await fixture.close(); return }
        XCTAssertNotEqual(completed.ticket.key.sourceRevision, changed.ticket.key.sourceRevision)
        XCTAssertTrue(model.librarySearchPending)

        // An equivalent publication needs no extra scan by itself. Explicit
        // retry revisits the reuse decision while B has not completed; matching
        // the current candidate snapshot is not proof A's IDs are reusable.
        model.papers = [currentOther, currentMatch]
        XCTAssertTrue(model.librarySearchPending)
        model.retryLibrarySearch()
        XCTAssertTrue(model.librarySearchPending)
        await release(1, in: fixture)
        guard let retried = await started(2, in: fixture) else { await fixture.close(); return }
        XCTAssertEqual(changed.candidates, retried.candidates)
        XCTAssertEqual(changed.ticket.key, retried.ticket.key)
        XCTAssertNotEqual(changed.ticket.id, retried.ticket.id)
        XCTAssertTrue(model.librarySearchPending, "Neither the old source nor canceled B may finish this retry")
        await release(2, in: fixture)
        await model.waitForLibrarySearch()

        XCTAssertFalse(model.librarySearchPending)
        XCTAssertNil(model.librarySearchIssue)
        XCTAssertEqual(model.filteredPapers.map(\.id), [secondID])
        XCTAssertEqual(model.filteredPapers.first?.title, currentMatch.title)
        let inputs = await fixture.worker.recorded()
        XCTAssertEqual(inputs.count, 3)
        await fixture.close()
    }

    func testGuestSignOutChangesScopeAndRejectsHeldSameQueryResult() async throws {
        let environment = "search-model-\(UUID().wire)"
        let vaultName = environment + ".auth-session"
        XCTAssertNil(try KeychainVault.read(vaultName))
        defer { try? KeychainVault.delete(vaultName) }
        let configuration = BackendConfiguration(url: URL(string: "https://\(environment).invalid")!,
                                                 anonKey: "fixture", environment: environment)
        let networkConfiguration = URLSessionConfiguration.ephemeral
        networkConfiguration.protocolClasses = [SearchModelNoNetworkProtocol.self]
        let network = URLSession(configuration: networkConfiguration)
        defer { network.invalidateAndCancel() }
        let backend = try BackendClient(configuration: configuration, network: network)
        let user = await backend.currentUser()
        XCTAssertNil(user)
        let fixture = ModelSearchFixture(expectedStarts: 2, configuration: configuration, client: backend)
        let model = fixture.model
        let old = paper("Shared previous session"), current = paper("Shared current session")
        model.papers = [old]
        model.libraryQuery = "shared"
        guard let before = await started(0, in: fixture) else { await fixture.close(); return }
        let previousSession = model.readerSessionID

        await model.signOut()
        XCTAssertNotEqual(model.readerSessionID, previousSession)
        XCTAssertTrue(model.papers.isEmpty)
        XCTAssertTrue(model.libraryRows.isEmpty)
        XCTAssertNil(model.selectedPaper)
        model.papers = [current]
        model.libraryQuery = "shared"
        assertSearchingWithoutRows(model)
        await release(0, in: fixture)
        guard let after = await started(1, in: fixture) else { await fixture.close(); return }
        XCTAssertEqual(before.ticket.key.query, after.ticket.key.query)
        XCTAssertNil(before.ticket.key.accountID)
        XCTAssertNil(after.ticket.key.accountID)
        XCTAssertNotEqual(before.ticket.key.sessionID, after.ticket.key.sessionID)
        XCTAssertEqual(after.ticket.key.sessionID, model.readerSessionID)
        assertSearchingWithoutRows(model)
        await release(1, in: fixture)
        await model.waitForLibrarySearch()

        XCTAssertEqual(model.filteredPapers.map(\.id), [current.id])
        XCTAssertFalse(model.librarySearchPending)
        XCTAssertNil(model.librarySearchIssue)
        XCTAssertNil(model.error)
        XCTAssertNil(try KeychainVault.read(vaultName))
        await fixture.close()
    }

    func testSameBindingPresentationHydrationResolvesCurrentRowWithoutAnotherSearch() async {
        let fixture = ModelSearchFixture(expectedStarts: 1)
        let model = fixture.model
        let id = UUID(), artifactID = UUID()
        let original = paper("Equation paper", id: id, artifactID: artifactID)
        let hydrated = paper("Equation paper", id: id, artifactID: artifactID,
                             fileURL: URL(fileURLWithPath: "/synthetic-reader/first.html"))
        model.papers = [original]
        model.libraryQuery = "equation"
        guard let captured = await started(0, in: fixture) else { await fixture.close(); return }

        model.papers = [hydrated]
        assertSearchingWithoutRows(model)
        await release(0, in: fixture)
        await model.waitForLibrarySearch()
        XCTAssertFalse(model.librarySearchPending)
        XCTAssertEqual(model.filteredPapers.first?.fileURL, hydrated.fileURL)
        XCTAssertEqual(model.filteredPapers.first?.artifactID, artifactID)
        model.select(original)
        XCTAssertEqual(model.selectedPaper?.fileURL, hydrated.fileURL,
                       "The captured row resolves the current same-binding presentation")

        let newer = paper("Equation paper", id: id, artifactID: artifactID,
                          fileURL: URL(fileURLWithPath: "/synthetic-reader/second.html"))
        model.papers = [newer]
        XCTAssertFalse(model.librarySearchPending)
        XCTAssertEqual(model.filteredPapers.first?.fileURL, newer.fileURL)
        model.select(hydrated)
        XCTAssertEqual(model.selectedPaper?.fileURL, newer.fileURL)
        model.papers = [newer]
        XCTAssertFalse(model.librarySearchPending, "An identical assignment must not remount or rescan the list")
        XCTAssertEqual(model.filteredPapers.first?.fileURL, newer.fileURL)
        await model.waitForLibrarySearch()
        let inputs = await fixture.worker.recorded()
        XCTAssertEqual(inputs.map(\.ticket), [captured.ticket], "Reader hydration must not rescan unchanged metadata")
        XCTAssertNil(model.librarySearchIssue)
        await fixture.close()
    }
}
