import Foundation
import Observation
import ScienceReaderCore

// AI recommendations (docs/architecture/AI_RECOMMENDATIONS.md; owner, TestFlight 78: "uses AI with our server to search
// for the most similar papers and just adds them … 1, 3 or 5"). The server chooses and adds; this device files each added
// paper in the catalog the reader was viewing, shows why each was chosen, and offers Remove and Undo through the
// ordinary library paths. Closing the sheet never stops a request: its papers are still filed and the library refreshed.

/// The network side: the backend in the app, a script in UI fixtures, a stub in tests.
protocol RecommendationService: Sendable {
    func stream(_ body: RecommendRequestBody) async throws -> AsyncThrowingStream<RecommendEvent, Error>
}

struct BackendRecommendations: RecommendationService {
    let backend: BackendClient
    let accountID: UUID
    func stream(_ body: RecommendRequestBody) async throws -> AsyncThrowingStream<RecommendEvent, Error> {
        try await backend.recommendStream(body, accountID: accountID)
    }
}

/// One request as the sheet shows it. Rows only ever append, so nothing jumps while papers arrive.
@MainActor @Observable
final class RecommendationRun: Identifiable {
    enum Subject: Equatable { case paper(title: String), catalog(name: String) }
    enum Phase: Equatable { case starting, searching, choosing(candidates: Int), finished(RecommendDone), failed(RecommendFailure) }
    enum RowState: Equatable { case added, removing, removed, present, failed, removeFailed }
    struct Row: Identifiable, Equatable {
        var paper: RecommendedPaper
        var state: RowState
        var id: String { paper.sourceID }
    }

    let id = UUID()
    let subject: Subject
    let count: Int
    let catalogID: UUID
    let catalogName: String
    /// The reader has more than one catalog, so where the papers went is worth naming.
    let namesCatalog: Bool
    let body: RecommendRequestBody
    var phase: Phase = .starting
    var rows: [Row] = []
    var undoing = false
    @ObservationIgnored var task: Task<Void, Never>?

    init(subject: Subject, count: Int, catalogID: UUID, catalogName: String, namesCatalog: Bool, body: RecommendRequestBody) {
        self.subject = subject; self.count = count; self.catalogID = catalogID; self.catalogName = catalogName
        self.namesCatalog = namesCatalog; self.body = body
    }

    var isRunning: Bool {
        switch phase { case .starting, .searching, .choosing: true; case .finished, .failed: false }
    }
    /// Papers still in the library from this request (Undo takes these).
    var removable: [Row] { rows.filter { $0.state == .added || $0.state == .removeFailed } }

    var subtitle: String {
        switch subject {
        case .paper(let title): "Like “\(title)”"
        case .catalog(let name): "For \(name)"
        }
    }

    /// While it runs: what the server is doing.
    var statusLine: String {
        switch phase {
        case .starting, .searching:
            switch subject {
            case .paper(let title): return "Finding papers like “\(title)”…"
            case .catalog(let name): return "Finding papers for \(name)…"
            }
        case .choosing(let candidates):
            return candidates > count ? "Choosing the best \(count) of \(candidates)…" : "Choosing from \(candidates) papers…"
        case .finished, .failed: return ""
        }
    }

    /// When it ends: what happened and what it cost.
    var outcome: String? {
        switch phase {
        case .starting, .searching, .choosing: return nil
        case .failed(let failure): return Recommendations.message(for: failure.code)
        case .finished(let done):
            if done.added == 0 {
                return done.reason == "not_added" ? "Couldn’t add these papers. Nothing was charged."
                    : "No closely related papers found. Nothing was charged."
            }
            let papers = done.added == 1 ? "1 paper" : "\(done.added) papers"
            let place = namesCatalog ? " to \(catalogName)" : ""
            let cost = done.charged && done.credits > 0 ? (done.credits == 1 ? "1 credit" : "\(done.credits) credits") : "No credit used"
            return "Added \(papers)\(place) · \(cost)"
        }
    }

    var failureCode: String? { if case .failed(let failure) = phase { failure.code } else { nil } }
}

extension ReaderModel {
    /// The recommend function for the signed-in account (a script in UI fixtures, a stub in tests).
    var recommendationService: (any RecommendationService)? {
        if let recommendationServiceOverride { return recommendationServiceOverride }
        #if DEBUG && FIXTURE_HOST
        if let fixture = RecommendFixture.service { return fixture }
        #endif
        guard let backend, let accountID else { return nil }
        return BackendRecommendations(backend: backend, accountID: accountID)
    }

    /// A paper the server knows (arXiv or an open-access web paper): never a local PDF, a sample or while signed out.
    func canRecommend(_ paper: Paper) -> Bool {
        recommendationService != nil && !paper.isSample && !paper.isLocalPDF
            && paper.sourceID.map(Recommendations.isEligibleSourceID) == true
    }

    /// The current catalog's newest papers that can seed a request (at most eight).
    var catalogRecommendationSeeds: [Paper] {
        guard recommendationService != nil else { return [] }
        let eligible = papers.filter { canRecommend($0) && !$0.archived && catalogContains(catalogKey($0)) }
        return Recommendations.catalogSeeds(eligible, sourceID: \.sourceID, addedAt: \.addedAt)
    }

    /// Said before the tap: the price, and where the papers go when there is a choice.
    var recommendationCreditNote: String {
        libraryCatalogs.catalogs.count > 1 ? "1 credit · added to \(currentCatalog.name)" : "1 credit"
    }

    func recommendSimilar(_ paper: Paper, count: Int) {
        guard canRecommend(paper), let sourceID = paper.sourceID,
              let body = RecommendRequestBody.make(operationID: UUID(), count: count, scope: .paper,
                                                   seeds: [(sourceID: sourceID, keywords: LibraryTags.tags(for: paper))]) else { return }
        start(RecommendationRun(subject: .paper(title: paper.title), count: count, catalogID: currentCatalog.id,
                                catalogName: currentCatalog.name, namesCatalog: libraryCatalogs.catalogs.count > 1, body: body))
    }

    func recommendForCatalog(count: Int) {
        let seeds = catalogRecommendationSeeds.compactMap { paper in paper.sourceID.map { (sourceID: $0, keywords: LibraryTags.tags(for: paper)) } }
        guard let body = RecommendRequestBody.make(operationID: UUID(), count: count, scope: .catalog, seeds: seeds) else { return }
        start(RecommendationRun(subject: .catalog(name: currentCatalog.name), count: count, catalogID: currentCatalog.id,
                                catalogName: currentCatalog.name, namesCatalog: libraryCatalogs.catalogs.count > 1, body: body))
    }

    /// Try again after a failure: the same papers and count under a new request.
    func retryRecommendation() {
        guard let run = recommendation, !run.isRunning,
              let body = RecommendRequestBody.make(operationID: UUID(), count: run.count, scope: run.body.scope,
                                                   seeds: run.body.seeds.map { (sourceID: $0.sourceID, keywords: $0.keywords) }) else { return }
        start(RecommendationRun(subject: run.subject, count: run.count, catalogID: run.catalogID, catalogName: run.catalogName,
                                namesCatalog: run.namesCatalog, body: body))
    }

    /// Get credits from the sheet: it closes first, then the store opens.
    func openCreditsFromRecommendations() {
        showRecommendations = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            self.showStore = true
        }
    }

    private func start(_ run: RecommendationRun) {
        guard let service = recommendationService else { openSignIn(); return }
        // An earlier request keeps running on its own (its papers are still filed); the sheet shows the new one.
        recommendation = run; showRecommendations = true
        let scope = sessionID
        run.task = Task { [weak self] in await self?.consume(run, service: service, scope: scope, replays: 1) }
    }

    private func consume(_ run: RecommendationRun, service: any RecommendationService, scope: UUID, replays: Int) async {
        var ended = false, added = false
        do {
            let stream = try await service.stream(run.body)
            for try await event in stream {
                guard sessionID == scope else { return }
                switch event {
                case .searching: run.phase = .searching
                case .choosing(let candidates): run.phase = .choosing(candidates: candidates)
                case .paper(_, let paper):
                    guard !run.rows.contains(where: { $0.id == paper.sourceID }) else { continue }
                    let state: RecommendationRun.RowState = switch paper.status { case .added: .added; case .present: .present; case .failed: .failed }
                    run.rows.append(.init(paper: paper, state: state))
                    if paper.status == .added {
                        added = true
                        #if DEBUG && FIXTURE_HOST
                        if RecommendFixture.isEnabled, let record = RecommendFixture.importRecord(for: paper) { insertFixtureImport(record) }
                        #endif
                        // Filed where the reader asked, as any server Add (best effort; the add itself has happened).
                        if let key = Self.addedCatalogKey(paper.sourceID) { await assignAddedPaper(key: key, to: run.catalogID) }
                    }
                case .done(let done): run.phase = .finished(done); ended = true
                case .failed(let failure):
                    // The same request still running elsewhere (a resend after a dropped connection): ask once more.
                    if failure.code == "in_progress", replays > 0 {
                        try await Task.sleep(for: .seconds(min(30, max(1, failure.retryAfter ?? 5))))
                        await consume(run, service: service, scope: scope, replays: replays - 1)
                        if added, sessionID == scope { await refreshLibrary() }
                        return
                    }
                    run.phase = .failed(failure); ended = true
                }
            }
            if !ended { run.phase = .failed(RecommendFailure(code: run.rows.isEmpty ? "service_unavailable" : "connection")) }
        } catch is CancellationError {
            return
        } catch let failure as RecommendFailure {
            if sessionID == scope { run.phase = .failed(failure) }
        } catch {
            if sessionID == scope { run.phase = .failed(RecommendFailure(code: run.rows.isEmpty ? "service_unavailable" : "connection")) }
        }
        if added, sessionID == scope { await refreshLibrary() }
    }

    /// Takes one added paper back out through the ordinary library paths (cancel its import, or remove the item it became).
    func removeRecommended(_ sourceID: String) async {
        guard let run = recommendation, let row = run.rows.first(where: { $0.id == sourceID }),
              row.state == .added || row.state == .removeFailed else { return }
        await remove(row, from: run)
    }

    /// Undo: every paper of this request still in the library.
    func undoRecommendations() async {
        guard let run = recommendation, !run.undoing else { return }
        run.undoing = true
        defer { run.undoing = false }
        for row in run.removable { await remove(row, from: run) }
    }

    private func remove(_ row: RecommendationRun.Row, from run: RecommendationRun) async {
        func set(_ state: RecommendationRun.RowState) {
            if let index = run.rows.firstIndex(where: { $0.id == row.id }) { run.rows[index].state = state }
        }
        set(.removing)
        let scope = sessionID
        for attempt in 0..<2 {
            switch removalTarget(row.paper) {
            case .import(let item): await changeImport(item, retry: false); set(.removed); return
            case .paper(let paper): await removePaper(paper); set(.removed); return
            case nil:
                // Not in this device's library yet: catch up once, then look again.
                if attempt == 0 { await refreshLibrary() }
                guard sessionID == scope else { return }
            }
        }
        set(.removeFailed)
    }

    private enum RemovalTarget { case `import`(LibraryImportRecord), paper(Paper) }
    private func removalTarget(_ recommended: RecommendedPaper) -> RemovalTarget? {
        if let id = recommended.importID, let item = libraryImports.first(where: { $0.id == id && $0.visible && $0.phase != .cancelled }) {
            return .import(item)
        }
        if let paper = papers.first(where: { !$0.isSample && !$0.isLocalPDF && $0.sourceID == recommended.sourceID }) { return .paper(paper) }
        if let item = libraryImports.first(where: { $0.visible && $0.sourceID == recommended.sourceID && $0.phase != .cancelled }) {
            return .import(item)
        }
        return nil
    }
}
