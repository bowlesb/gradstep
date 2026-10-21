import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// AI recommendations in the app model (docs/architecture/AI_RECOMMENDATIONS.md): who can seed a request, what is
/// sent, the run continuing with its sheet closed, Remove and Undo through the library's own paths, failures and the
/// one resend of a request still running elsewhere. The backend transport and catalog filing: LibraryModelTests.
@MainActor
final class RecommendationsAppTests: XCTestCase {
    #if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))
    private func makeModel(with service: (any RecommendationService)?) throws -> (ReaderModel, Paper) {
        let model = ReaderModel(configuration: nil)
        try model.configureWorkflowFixture()
        var paper = Paper(id: UUID(), title: "Attention Is All You Need", authors: "Ashish Vaswani, Noam Shazeer", year: 2017,
                          abstract: "We propose the Transformer, based solely on attention mechanisms, for sequence transduction.",
                          keywords: ["cs.CL", "cs.LG"], fileURL: nil, artifactID: nil)
        paper.sourceID = "1706.03762"; paper.addedAt = Date()
        model.papers.append(paper)
        model.recommendationServiceOverride = service
        return (model, paper)
    }

    func testOnlyPapersTheServerKnowsCanSeedARequest() throws {
        let (signedOut, paper) = try makeModel(with: nil)
        XCTAssertFalse(signedOut.canRecommend(paper), "signed out: no service")
        let (model, seeded) = try makeModel(with: ScriptedRecommendations(mode: "added"))
        XCTAssertTrue(model.canRecommend(seeded))
        var local = paper; local.isLocalPDF = true
        var sample = paper; sample.isSample = true
        var upload = paper; upload.sourceID = "upload:7c1f"
        XCTAssertFalse(model.canRecommend(local)); XCTAssertFalse(model.canRecommend(sample)); XCTAssertFalse(model.canRecommend(upload))
        XCTAssertEqual(model.recommendationCreditNote, "1 credit", "one catalog: the price only")
        XCTAssertEqual(model.catalogRecommendationSeeds.map(\.id), [seeded.id], "the catalog's eligible papers")
    }

    func testARequestRunsWithItsSheetClosedAndUndoRemovesWhatItAdded() async throws {
        let (model, paper) = try makeModel(with: ScriptedRecommendations(mode: "added"))
        model.recommendSimilar(paper, count: 3)
        let run = try XCTUnwrap(model.recommendation)
        XCTAssertTrue(model.showRecommendations)
        XCTAssertEqual(run.body.scope, .paper); XCTAssertEqual(run.body.count, 3)
        XCTAssertEqual(run.body.seeds.map(\.sourceID), ["1706.03762"])
        XCTAssertEqual(run.body.seeds[0].keywords, Recommendations.keywords(LibraryTags.tags(for: paper), limit: 6))
        XCTAssertEqual(run.statusLine, "Finding papers like “Attention Is All You Need”…")
        model.showRecommendations = false   // closing the sheet never stops it
        await run.task?.value
        XCTAssertEqual(run.rows.map(\.id), ["2004.05150", "2001.04451", "2006.04768"])
        XCTAssertEqual(run.rows.map(\.state), [.added, .added, .added])
        XCTAssertEqual(run.outcome, "Added 3 papers · 1 credit")
        XCTAssertFalse(run.isRunning)
        // The server's adds, as the library lists them after its refresh.
        for row in run.rows { model.insertFixtureImport(try XCTUnwrap(RecommendFixture.importRecord(for: row.paper))) }
        await model.removeRecommended("2004.05150")
        XCTAssertEqual(run.rows[0].state, .removed)
        XCTAssertFalse(model.libraryImports.contains { $0.sourceID == "2004.05150" })
        XCTAssertTrue(model.libraryImports.contains { $0.sourceID == "2001.04451" }, "only that one")
        await model.undoRecommendations()
        XCTAssertEqual(run.rows.map(\.state), [.removed, .removed, .removed])
        XCTAssertTrue(run.removable.isEmpty)
        XCTAssertFalse(model.libraryImports.contains { ["2001.04451", "2006.04768"].contains($0.sourceID ?? "") })
    }

    func testCatalogRequestAndOutcomesSayWhatHappened() async throws {
        let (model, _) = try makeModel(with: ScriptedRecommendations(mode: "none"))
        model.recommendForCatalog(count: 5)
        let catalogRun = try XCTUnwrap(model.recommendation)
        XCTAssertEqual(catalogRun.body.scope, .catalog); XCTAssertEqual(catalogRun.subtitle, "For \(model.currentCatalog.name)")
        await catalogRun.task?.value
        XCTAssertEqual(catalogRun.outcome, "No closely related papers found. Nothing was charged.")
        for (mode, message) in [("daily_limit", "You’ve asked for recommendations 20 times today. Try again tomorrow."),
                                ("insufficient_credits", "You’re out of AI credits."),
                                ("error", "Recommendations aren’t available right now. Nothing was charged.")] {
            let (failing, paper) = try self.makeModel(with: ScriptedRecommendations(mode: mode))
            failing.recommendSimilar(paper, count: 1)
            let run = try XCTUnwrap(failing.recommendation)
            await run.task?.value
            XCTAssertEqual(run.outcome, message, mode); XCTAssertTrue(run.rows.isEmpty)
        }
        // Try again: a new request (new operation id) for the same paper and count.
        let (retrying, paper) = try makeModel(with: ScriptedRecommendations(mode: "error"))
        retrying.recommendSimilar(paper, count: 3)
        let first = try XCTUnwrap(retrying.recommendation); await first.task?.value
        retrying.retryRecommendation()
        let second = try XCTUnwrap(retrying.recommendation)
        XCTAssertNotEqual(second.id, first.id); XCTAssertNotEqual(second.body.operationID, first.body.operationID)
        XCTAssertEqual(second.body.seeds, first.body.seeds); XCTAssertEqual(second.count, 3)
        await second.task?.value
    }

    /// A request still running elsewhere (a resend after a dropped connection) is asked for once more, unchanged.
    func testInProgressIsAskedOnceMoreWithTheSameOperation() async throws {
        let service = ReplayingService()
        let (model, paper) = try makeModel(with: service)
        model.recommendSimilar(paper, count: 1)
        let run = try XCTUnwrap(model.recommendation)
        await run.task?.value
        XCTAssertEqual(service.operations.count, 2); XCTAssertEqual(Set(service.operations).count, 1)
        XCTAssertEqual(run.rows.count, 1); XCTAssertEqual(run.outcome, "Added 1 paper · 1 credit")
    }
    #endif
}

private final class ReplayingService: RecommendationService, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [UUID] = []
    var operations: [UUID] { lock.withLock { seen } }
    func stream(_ body: RecommendRequestBody) async throws -> AsyncThrowingStream<RecommendEvent, Error> {
        let first = lock.withLock { seen.append(body.operationID); return seen.count == 1 }
        return AsyncThrowingStream { continuation in
            if first { continuation.yield(.failed(RecommendFailure(code: "in_progress", retryAfter: 0))) }
            else {
                continuation.yield(.paper(ordinal: 1, RecommendedPaper(sourceID: "2004.05150", revision: 2, title: "Longformer", authors: [], year: 2020,
                                                                       reason: "Sparse attention", status: .added, importID: UUID())))
                continuation.yield(.done(RecommendDone(added: 1, requested: 1, credits: 1, charged: true, reason: nil)))
            }
            continuation.finish()
        }
    }
}
