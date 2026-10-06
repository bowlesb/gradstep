import CryptoKit
import Foundation
import Observation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// Model journeys use the normal account path and cached Auth/device keys.
/// Only transport and native-admission scheduling are substituted; the cache,
/// writer handoff, image admission and model presentation are the real ones.
@MainActor
final class OfflineModelTests: XCTestCase {
    private enum Failure: Error { case observationTimedOut }

    private func fixture(expired: Bool = false, paperCount: Int = 1,
                         verification: @escaping ReaderBundleCoordinator.Verification = ReaderBundleInput.verify,
                         directory: @escaping ReaderBundleCoordinator.DirectoryReader = { try await $0.listInstalledReaderBundles(scope: $1) }) async throws -> OfflineModelFixture {
        let fixture = try OfflineModelFixture(expired: expired, paperCount: paperCount, verification: verification, directory: directory)
        addTeardownBlock { await fixture.close() }
        try await fixture.seed()
        return fixture
    }

    private func observe(_ description: String, _ condition: @escaping @MainActor () -> Bool) async throws {
        let observation = OfflineModelObservation(description, condition: condition)
        observation.start()
        await fulfillment(of: [observation.ready], timeout: 5)
        observation.stop()
        guard condition() else { throw Failure.observationTimedOut }
    }

    private func assertLoadedCopies(_ expected: Set<UUID>, in model: ReaderModel,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let paperIDs = Set(model.papers.filter { !$0.isSample && $0.readerBundle != nil }.map(\.id))
        let rowIDs = Set(model.libraryRows.compactMap { entry -> UUID? in
            guard case .paper(let paper) = entry, !paper.isSample, paper.readerBundle != nil else { return nil }
            return paper.id
        })
        XCTAssertEqual(paperIDs, expected, "Library metadata must not keep previously selected bundles", file: file, line: line)
        XCTAssertEqual(rowIDs, expected, "Published search rows must release the same old handles immediately", file: file, line: line)
    }

    func testChangingPapersEvictsOnlyTheLoadedCopyAndReopensFromDisk() async throws {
        let gate = OfflineModelSelectionVerifier()
        let fixture = try await fixture(paperCount: 2, verification: { try await gate.verify($0) }), model = fixture.model
        addTeardownBlock { await gate.release() }
        await model.start()
        await model.waitForLibrarySearch()
        let first = fixture.catalog, second = try XCTUnwrap(fixture.additionalCatalogs.first)
        model.select(try XCTUnwrap(model.papers.first { $0.id == first.document }))
        try await observe("The first encrypted copy is opened") { model.selectedPaper?.readerBundle != nil }
        let staleFirstRow = try XCTUnwrap(model.selectedPaper)
        assertLoadedCopies([first.document], in: model)

        let held = expectation(description: "Second paper admission remains suspended")
        await gate.arm(arrived: held)
        model.select(try XCTUnwrap(model.papers.first { $0.id == second.document }))
        // Check before any await: switching selection itself must evict A,
        // independently of whether B's SQLite read or verifier has begun.
        assertLoadedCopies([], in: model)
        XCTAssertNil(model.papers.first { $0.id == first.document }?.fileURL)
        XCTAssertEqual(model.selectedPaper?.id, second.document)
        XCTAssertNil(model.selectedPaper?.readerBundle)
        XCTAssertTrue(model.papers.allSatisfy { model.offlineStatus(for: $0) == .available }, "Eviction cannot remove the installed-copy badge")
        await fulfillment(of: [held], timeout: 5)
        assertLoadedCopies([], in: model)
        await gate.release()
        try await observe("The second encrypted copy is opened") {
            model.selectedPaper?.id == second.document && model.selectedPaper?.readerBundle != nil
        }
        assertLoadedCopies([second.document], in: model)

        let reopening = expectation(description: "An evicted paper must be verified again from encrypted storage")
        await gate.arm(arrived: reopening)
        model.select(staleFirstRow)
        XCTAssertEqual(model.selectedPaper?.id, first.document)
        XCTAssertNil(model.selectedPaper?.readerBundle, "A captured loaded row cannot reattach its old payload")
        assertLoadedCopies([], in: model)
        await fulfillment(of: [reopening], timeout: 5)
        await gate.release()
        try await observe("Returning to the first paper completes fresh admission") {
            model.selectedPaper?.id == first.document && model.selectedPaper?.readerBundle != nil
        }
        assertLoadedCopies([first.document], in: model)
        let calls = await gate.callCount()
        XCTAssertEqual(calls, 3)

        await model.signOut()
        await model.waitForLocalRetirement()
        let store = try fixture.reopenStore()
        let installed = try await store.listInstalledReaderBundles(scope: fixture.scope)
        XCTAssertEqual(Set(installed.installations.map { $0.binding.documentID }), [first.document, second.document],
                       "Selection changes evict memory only; both encrypted installations remain")
    }

    func testHistoryAndUnsentDraftSelectionEvictOtherBundlesButChatAndRefreshKeepTheCurrentCopy() async throws {
        let gate = OfflineModelSelectionVerifier()
        let fixture = try await fixture(paperCount: 2, verification: { try await gate.verify($0) }), model = fixture.model
        addTeardownBlock { await gate.release() }
        let first = fixture.catalog, second = try XCTUnwrap(fixture.additionalCatalogs.first)
        let saved = try await fixture.seedConversationAndDraft(conversationDocument: first.document, draftDocument: second.document)
        await model.start()
        await model.waitForLibrarySearch()
        XCTAssertTrue(model.unsentDrafts.contains { $0.id == saved.draftID })
        model.select(try XCTUnwrap(model.papers.first { $0.id == second.document }))
        try await observe("The starting paper is opened") { model.selectedPaper?.readerBundle != nil }

        let historyHeld = expectation(description: "Saved conversation switches to its own paper")
        await gate.arm(arrived: historyHeld)
        model.openConversation(saved.conversationID)
        assertLoadedCopies([], in: model)
        XCTAssertEqual(model.selectedPaper?.id, first.document)
        XCTAssertEqual(model.activeConversation, saved.conversationID)
        XCTAssertEqual(model.tab, .chat)
        await fulfillment(of: [historyHeld], timeout: 5)
        await gate.release()
        try await observe("History's paper completes admission") {
            model.selectedPaper?.id == first.document && model.selectedPaper?.readerBundle != nil
        }
        assertLoadedCopies([first.document], in: model)

        let draftHeld = expectation(description: "The durable unsent draft switches back to its paper")
        await gate.arm(arrived: draftHeld)
        model.openUnsentDraft(saved.draftID)
        assertLoadedCopies([], in: model)
        XCTAssertEqual(model.selectedPaper?.id, second.document)
        XCTAssertEqual(model.chatInput, "Keep this unsent paper question")
        await fulfillment(of: [draftHeld], timeout: 5)
        await gate.release()
        try await observe("The unsent draft's paper completes admission") {
            model.selectedPaper?.id == second.document && model.selectedPaper?.readerBundle != nil
        }
        assertLoadedCopies([second.document], in: model)

        let scope = model.readerDocumentScope
        model.newChat(general: false)
        model.newChat(general: true)
        model.tab = .library
        model.askAboutSelectedPaper()
        await model.refreshLibrary()
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.readerDocumentScope, scope, "Chat/tab navigation and unchanged metadata keep the selected reading scope")
        assertLoadedCopies([second.document], in: model)
        XCTAssertTrue(model.papers.allSatisfy { model.offlineStatus(for: $0) == .available })
        let calls = await gate.callCount()
        XCTAssertEqual(calls, 3, "Unchanged selection must not trigger another bundle verification")
    }

    func testCancelledOlderVerificationCannotRepopulateAnEvictedPaper() async throws {
        let gate = OfflineModelSelectionVerifier()
        let fixture = try await fixture(paperCount: 2, verification: { try await gate.verify($0) }), model = fixture.model
        addTeardownBlock { await gate.release() }
        await model.start()
        await model.waitForLibrarySearch()
        let first = fixture.catalog, second = try XCTUnwrap(fixture.additionalCatalogs.first)
        let held = expectation(description: "Old paper's native verification is held")
        let cancelled = expectation(description: "Changing papers cancels the older open")
        await gate.arm(arrived: held, cancelled: cancelled, ignoreCancellation: true)
        model.select(try XCTUnwrap(model.papers.first { $0.id == first.document }))
        await fulfillment(of: [held], timeout: 5)
        model.select(try XCTUnwrap(model.papers.first { $0.id == second.document }))
        await fulfillment(of: [cancelled], timeout: 5)
        XCTAssertEqual(model.selectedPaper?.id, second.document)
        assertLoadedCopies([], in: model)
        let beforeRelease = await gate.callCount()
        XCTAssertEqual(beforeRelease, 1, "The replacement verifier must wait for the cancelled verifier to drain")
        await gate.release()
        try await observe("Only the replacement paper can publish its verified bundle") {
            model.selectedPaper?.id == second.document && model.selectedPaper?.readerBundle != nil
        }
        assertLoadedCopies([second.document], in: model)
        XCTAssertNil(model.readerOpenIssue)
        let calls = await gate.callCount(), maximum = await gate.maximumConcurrent()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(maximum, 1)
    }

    func testExpiredCachedAuthenticationOpensEncryptedPaperBeforeRefreshReturns() async throws {
        let fixture = try await fixture(expired: true), model = fixture.model
        let starting = Task { await model.start() }
        addTeardownBlock { fixture.server.releaseRefresh(); await starting.value }

        await fulfillment(of: [fixture.server.refreshArrived], timeout: 5)
        try await observe("Cached rows restore while token refresh is still suspended") { model.libraryHasSnapshot }
        XCTAssertEqual(model.papers.map(\.id), [fixture.catalog.document])
        XCTAssertFalse(model.canChangeLibrary, "A presentation cache cannot manufacture a complete live command observation")
        XCTAssertTrue(model.draftsArePersistent)
        XCTAssertTrue(fixture.server.requests().allSatisfy { $0 == "token" })
        do {
            try await model.importPaper("2404.00002")
            XCTFail("A cached-only library must not authorize a new server command")
        } catch { XCTAssertEqual(error as? ReaderError, .storageUnavailable) }

        model.select(try XCTUnwrap(model.papers.first))
        try await observe("Encrypted local paper opens without a refreshed access token") { model.selectedPaper?.readerBundle != nil }
        XCTAssertEqual(model.selectedPaper?.readerBundle?.manifestSHA256, fixture.bundle.manifestSHA256)
        XCTAssertEqual(model.selectedPaper?.readerBundle?.index.figures.count, 2)
        XCTAssertNil(model.readerOpenIssue)
        XCTAssertNil(model.offlineCacheIssue)
        XCTAssertFalse(model.selectedPaper?.isSample ?? true, "The test account has a synthetic membership, not the guest sample bypass")

        fixture.server.releaseRefresh()
        await starting.value
        XCTAssertNotNil(model.libraryIssue, "Failed catch-up remains visible without discarding the local presentation")
        XCTAssertNotNil(model.syncIssue)
        XCTAssertEqual(model.selectedPaper?.readerBundle?.manifestSHA256, fixture.bundle.manifestSHA256)
        XCTAssertFalse(model.canChangeLibrary)
        XCTAssertTrue(fixture.server.requests().allSatisfy { $0 == "token" })
    }

    func testOutageKeepsTheOpenCopyButQuarantineClearsItsReaderScope() async throws {
        let fixture = try await fixture(), model = fixture.model
        await model.start()
        XCTAssertTrue(model.canChangeLibrary)
        model.select(try XCTUnwrap(model.papers.first))
        try await observe("Installed paper is admitted") { model.selectedPaper?.readerBundle != nil }
        let openedPaper = try XCTUnwrap(model.selectedPaper)
        let openedScope = model.readerDocumentScope
        model.selectedQuote = "A retained paper selection"
        model.headings = [.init(id: "fixture-heading", title: "Retained contents")]
        model.generalChat = false; model.chatInput = "Keep this private question"

        fixture.server.setAvailability("unavailable")
        await model.refreshLibrary()
        XCTAssertEqual(model.readerDocumentScope, openedScope, "A remote outage must preserve verified local bytes and reader location")
        XCTAssertEqual(model.selectedQuote, "A retained paper selection")
        XCTAssertEqual(model.headings.count, 1)
        XCTAssertNil(model.readerOpenIssue)

        fixture.server.setAvailability("quarantined")
        await model.refreshLibrary()
        XCTAssertEqual(model.selectedPaper?.id, fixture.catalog.document)
        XCTAssertEqual(model.selectedPaper?.artifactID, fixture.catalog.artifact)
        XCTAssertNil(model.selectedPaper?.readerBundle)
        XCTAssertNil(model.selectedPaper?.fileURL)
        XCTAssertNotEqual(model.readerDocumentScope, openedScope)
        XCTAssertTrue(model.headings.isEmpty)
        XCTAssertTrue(model.selectedQuote.isEmpty)
        XCTAssertNotNil(model.readerOpenIssue)
        XCTAssertEqual(model.chatInput, "Keep this private question")
        model.select(openedPaper)
        XCTAssertNil(model.selectedPaper?.readerBundle, "A stale row button cannot revive its formerly loaded, now quarantined handle")
        await model.flushDrafts()
        await model.signOut()
        model.openSample()
        let guestID = model.selectedPaper?.id
        model.select(openedPaper)
        XCTAssertEqual(model.selectedPaper?.id, guestID, "A captured prior-account paper cannot replace the guest reader after sign-out")
        XCTAssertTrue(model.selectedPaper?.isSample ?? false)
    }

    func testCachedImportMappingsDeduplicateAmbiguousCommandsWithoutGrantingLiveAuthority() async throws {
        let fixture = try await fixture(expired: true), model = fixture.model
        let importIDs = try await fixture.seedPendingAndResolvedImports()
        let starting = Task { await model.start() }
        addTeardownBlock { fixture.server.releaseRefresh(); await starting.value }
        await fulfillment(of: [fixture.server.refreshArrived], timeout: 5)
        try await observe("Cached import mappings and the durable queue restore independently") {
            model.libraryHasSnapshot && model.libraryCommands.count == 2
        }

        XCTAssertEqual(Set(model.libraryCommands.map(\.id)), Set(importIDs), "Presentation dedup must not settle ambiguous commands")
        XCTAssertEqual(model.libraryImports.map(\.id), [importIDs[0]], "The resolved alias remains hidden")
        XCTAssertEqual(model.papers.map(\.id), [fixture.catalog.document])
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.libraryRows.count, 2, "Show one pending import beside its existing paper, without duplicated queued aliases")
        await model.waitForLibrarySearch()
        XCTAssertEqual(Set(model.libraryRows.map(\.id)).count, model.libraryRows.count)
        await model.waitForLibrarySearch()
        XCTAssertFalse(model.libraryRows.contains { if case .queued = $0 { return true }; return false })
        XCTAssertFalse(model.canChangeLibrary, "Cached alias mappings provide presentation, never command reconciliation authority")
        XCTAssertTrue(fixture.server.requests().allSatisfy { $0 == "token" })
    }

    func testProjectedRestoreKeepsCompleteMetadataOptionalFallbacksAndGlobalSearchOrder() async throws {
        // Seed the complete checkpoint directly before the first model writer;
        // changing an existing pinned metadata record would be invalid input.
        let fixture = try OfflineModelFixture(expired: true, paperCount: 2,
            verification: ReaderBundleInput.verify,
            directory: { try await $0.listInstalledReaderBundles(scope: $1) })
        addTeardownBlock { await fixture.close() }
        let model = fixture.model, first = fixture.catalog, second = try XCTUnwrap(fixture.additionalCatalogs.first)
        var firstRow = first.row(state: 6), secondRow = second.row(state: 6)
        let fullAbstract = String(repeating: "Complete searchable text. ", count: 300) + "tailneedle"
        firstRow["metadata"] = ["title": "Équations 東京", "authors": ["Zoë", "李"], "abstract": fullAbstract,
            "categories": ["cs.LG", "数学"], "published_at": "2024-04-03", "updated_at": "2024-05-01", "venue": "Fixture"]
        secondRow["metadata"] = ["title": "Beta optional", "authors": [], "categories": []]
        let optionalID = UUID(), removedID = UUID(), pendingID = UUID(), readyID = UUID()
        var optional = first.row(state: 6)
        optional["id"] = UUID().wire; optional["document_id"] = optionalID.wire; optional["created_seq"] = 3
        for field in ["approval_id", "version_id", "metadata_id", "source", "source_id", "source_revision",
                      "metadata", "metadata_recorded_at", "source_url", "original_object_id", "artifact_id"] {
            optional[field] = NSNull()
        }
        optional["scope"] = "owner_private"; optional["readiness"] = "unverified"
        optional["render_availability"] = "unavailable"; optional["original_availability"] = "unavailable"
        var removed = first.row(state: 6)
        removed["id"] = UUID().wire; removed["document_id"] = removedID.wire; removed["created_seq"] = 4
        removed["visible"] = false; removed["membership_revision"] = 2; removed["last_remove_seq"] = 6
        func imported(_ id: UUID, ready: Bool) -> [String: Any] {
            ["kind": "import", "id": id.wire, "created_seq": ready ? 6 : 5, "state_seq": 6,
             "intent_revision": 1, "visible": !ready, "phase": ready ? "ready" : "source_only", "source": "arxiv",
             "source_id": ready ? "2404.00001" : "2501.00001", "requested_revision": ready ? 1 : 2,
             "source_revision": ready ? 1 : 2, "metadata_id": ready ? first.metadata.wire : UUID().wire,
             "version_id": ready ? first.version.wire : UUID().wire,
             "metadata": ready ? firstRow["metadata"]! : ["title": "Alpha pending", "authors": ["PendingAuthor"],
                "abstract": "missing-tail", "categories": ["cs.AI"]],
             "metadata_recorded_at": "2026-10-03T10:00:00Z",
             "source_url": ready ? "https://arxiv.org/abs/2404.00001v1" : "https://arxiv.org/abs/2501.00001v2",
             "document_id": ready ? (first.document.wire as Any) : NSNull(),
             "library_item_id": ready ? (first.item.wire as Any) : NSNull(), "retryable": false]
        }
        let ordered = try await fixture.seedPresentation(rows: [firstRow, secondRow, optional, removed,
            imported(pendingID, ready: false), imported(readyID, ready: true)], cursor: 6)
        let liveMapped = ordered.compactMap(LibraryPresentationRow.project)
        XCTAssertEqual(liveMapped.count, 5, "Only the removed item is omitted; hidden import identity remains")
        XCTAssertTrue(liveMapped.contains { if case .imported(let id, nil) = $0 { return id == readyID }; return false })

        let starting = Task { await model.start() }
        addTeardownBlock { fixture.server.releaseRefresh(); await starting.value }
        await fulfillment(of: [fixture.server.refreshArrived], timeout: 5)
        // Support refresh can request a token before activation finishes its
        // cache read; the network barrier is not a restoration-complete signal.
        try await observe("The complete metadata projection publishes while refresh remains held") {
            model.libraryHasSnapshot || model.offlineCacheIssue != nil
        }
        XCTAssertNil(model.offlineCacheIssue)
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.papers.map(\.id), [first.document, second.document, optionalID])
        XCTAssertEqual(model.libraryImports.map(\.id), [pendingID])
        for projected in liveMapped {
            guard case .item(let item) = projected else { continue }
            let actual = try XCTUnwrap(model.papers.first { $0.id == item.paper.id })
            XCTAssertEqual(actual.title, item.paper.title); XCTAssertEqual(actual.authors, item.paper.authors)
            XCTAssertEqual(actual.year, item.paper.year); XCTAssertEqual(actual.abstract, item.paper.abstract)
            XCTAssertEqual(actual.keywords, item.paper.keywords); XCTAssertEqual(actual.artifactID, item.paper.artifactID)
            XCTAssertEqual(actual.sourceID, item.paper.sourceID); XCTAssertEqual(actual.sourceRevision, item.paper.sourceRevision)
            XCTAssertNil(actual.readerBundle); XCTAssertNil(actual.fileURL)
        }
        let paper = try XCTUnwrap(model.papers.first)
        XCTAssertEqual(paper.title, "Équations 東京"); XCTAssertEqual(paper.authors, "Zoë, 李")
        XCTAssertEqual(paper.abstract, fullAbstract); XCTAssertEqual(paper.year, 2024)
        XCTAssertEqual(paper.keywords, ["cs.LG", "数学"]); XCTAssertEqual(paper.sourceReference, "2404.00001v1")
        let fallback = try XCTUnwrap(model.papers.first { $0.id == optionalID })
        XCTAssertEqual(fallback.title, "Untitled paper"); XCTAssertEqual(fallback.authors, "")
        XCTAssertNil(fallback.year); XCTAssertEqual(fallback.abstract, ""); XCTAssertTrue(fallback.keywords.isEmpty)
        XCTAssertNil(fallback.sourceReference); XCTAssertNil(fallback.artifactID)
        XCTAssertFalse(model.papers.contains { $0.id == removedID })
        XCTAssertEqual(model.libraryRows.map(\.id), ["import/\(pendingID.wire)", "paper/\(optionalID.wire)",
            "paper/\(second.document.wire)", "paper/\(first.document.wire)"], "Recent order spans pending imports and every restored paper")

        model.libraryQuery = "  東京 Zoë tailneedle 数学 2404.00001v1  "
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.libraryRows.map(\.id), ["paper/\(first.document.wire)"], "AND terms may match separate untruncated fields")
        model.libraryQuery = "PendingAuthor missing-tail cs.AI 2501.00001v2"
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.libraryRows.map(\.id), ["import/\(pendingID.wire)"])
        model.libraryQuery = "tailneedle absent-token"
        await model.waitForLibrarySearch()
        XCTAssertTrue(model.libraryRows.isEmpty)
        model.libraryQuery = ""; model.librarySort = .title
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.libraryRows.map(\.id), ["import/\(pendingID.wire)", "paper/\(second.document.wire)",
            "paper/\(first.document.wire)", "paper/\(optionalID.wire)"])
        XCTAssertFalse(model.canChangeLibrary, "Projection remains cached presentation while live Auth is held")
        XCTAssertTrue(fixture.server.requests().allSatisfy { $0 == "token" })
    }

    func testSignOutDuringCompletedProjectionDrainsRestoreWithoutPublishingIntoGuest() async throws {
        let gate = OfflineModelRestorationGate()
        let fixture = try await fixture(directory: { try await gate.read($0, scope: $1) }), model = fixture.model
        addTeardownBlock { await gate.release() }
        await gate.arm()
        let starting = Task { await model.start() }
        addTeardownBlock { await gate.release(); await starting.value }
        // DirectoryReader runs after Core's complete projection. Hold that
        // result before the coordinator/model can apply any of its rows.
        await fulfillment(of: [gate.arrived], timeout: 5)
        XCTAssertTrue(model.papers.isEmpty)
        await model.signOut()
        model.openSample()
        let guest = try XCTUnwrap(model.selectedPaper)
        XCTAssertTrue(guest.isSample)
        XCTAssertEqual(model.papers.map(\.id), [guest.id])
        await gate.release()
        await starting.value
        await model.waitForLocalRetirement()
        await model.waitForLibrarySearch()
        XCTAssertEqual(model.papers.map(\.id), [guest.id])
        XCTAssertEqual(model.selectedPaper?.id, guest.id)
        XCTAssertFalse(model.isSignedIn); XCTAssertNil(model.offlineCacheIssue)
        XCTAssertFalse(model.canChangeLibrary)
        let restored = try await fixture.reopenStore().cachedLibraryPresentation(scope: fixture.scope)
        XCTAssertEqual(restored?.entries.count, 1, "Retirement drains the read; sign-out does not delete the encrypted cache")
    }

    func testSignOutDuringNativeVerificationCannotReplaceANewGuestReader() async throws {
        let gate = OfflineModelVerificationGate()
        let fixture = try await fixture(verification: { try await gate.verify($0) }), model = fixture.model
        addTeardownBlock { await gate.release() }
        await model.start()
        let oldSession = model.readerSessionID
        model.select(try XCTUnwrap(model.papers.first))
        await fulfillment(of: [gate.arrived], timeout: 5)
        XCTAssertEqual(model.openingPaperID, fixture.catalog.document)

        await model.signOut()
        XCTAssertNotEqual(model.readerSessionID, oldSession)
        XCTAssertTrue(model.papers.isEmpty)
        XCTAssertNil(model.selectedPaper)
        XCTAssertNil(model.openingPaperID)
        XCTAssertNil(model.offlineCacheIssue)
        model.openSample()
        let guest = try XCTUnwrap(model.selectedPaper)
        XCTAssertTrue(guest.isSample)
        await gate.release()
        await model.waitForLocalRetirement()

        XCTAssertEqual(model.papers.map(\.id), [guest.id])
        XCTAssertEqual(model.selectedPaper?.id, guest.id)
        XCTAssertTrue(model.selectedPaper?.isSample ?? false)
        XCTAssertNil(model.readerOpenIssue)
        XCTAssertNil(model.offlineCacheIssue)
        XCTAssertFalse(model.canChangeLibrary)
    }

    func testFailedSameAccountActivationResumesAndReopensTheCancelledLocalRead() async throws {
        let gate = OfflineModelVerificationGate()
        let fixture = try await fixture(verification: { try await gate.verify($0) }), model = fixture.model
        addTeardownBlock { await gate.release() }
        await model.start()
        model.select(try XCTUnwrap(model.papers.first))
        await fulfillment(of: [gate.arrived], timeout: 5)
        let wrongKey = LocalDevice(accountID: fixture.device.accountID, deviceID: fixture.device.deviceID,
            privateKey: fixture.device.privateKey, challenge: fixture.device.challenge,
            localStoreKey: ReaderCrypto.randomKey(), bundle: fixture.device.bundle)
        let scope = model.readerSessionID
        let activation = Task { try await model.activate(wrongKey, scope: scope) }
        try await observe("Reactivation takes ownership before waiting for the old verifier") { !model.canChangeLibrary }
        await gate.release()
        do { _ = try await activation.value; XCTFail("The reused store must reject a changed local key") }
        catch { XCTAssertEqual(error as? ReaderError, .invalidKey) }

        try await observe("Failed activation resumes the prior account's local reader") { model.selectedPaper?.readerBundle != nil }
        XCTAssertEqual(model.selectedPaper?.readerBundle?.manifestSHA256, fixture.bundle.manifestSHA256)
        XCTAssertNil(model.openingPaperID)
        XCTAssertNil(model.readerOpenIssue)
        XCTAssertNotNil(model.syncIssue)
        XCTAssertTrue(model.canChangeLibrary)
        try await model.importPaper("2404.00002")
        XCTAssertEqual(model.libraryCommands.count, 1, "Resumed actions must accept durable intent, not merely appear enabled")
    }

    func testCancelledSameAccountActivationDoesNotLeaveTheReaderPaused() async throws {
        let gate = OfflineModelVerificationGate()
        let fixture = try await fixture(verification: { try await gate.verify($0) }), model = fixture.model
        addTeardownBlock { await gate.release() }
        await model.start()
        model.select(try XCTUnwrap(model.papers.first))
        await fulfillment(of: [gate.arrived], timeout: 5)
        let scope = model.readerSessionID
        let activation = Task { try await model.activate(fixture.device, scope: scope) }
        try await observe("Activation pauses before its cancelled verifier settles") { !model.canChangeLibrary }
        activation.cancel()
        await gate.release()
        do { _ = try await activation.value; XCTFail("Expected caller cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }

        try await observe("Owned activation cancellation cannot strand an installed paper") { model.selectedPaper?.readerBundle != nil }
        XCTAssertEqual(model.selectedPaper?.id, fixture.catalog.document)
        XCTAssertNil(model.openingPaperID)
        XCTAssertNil(model.readerOpenIssue)
        XCTAssertTrue(model.canChangeLibrary)
        try await model.importPaper("2404.00002")
        XCTAssertEqual(model.libraryCommands.count, 1, "Cancellation must resume the same command coordinator as the reader")
    }

    func testSupersededSameAccountRestoreCannotPublishItsLateCacheFailure() async throws {
        let gate = OfflineModelDirectoryGate()
        let fixture = try await fixture(directory: { try await gate.read($0, scope: $1) }), model = fixture.model
        addTeardownBlock { await gate.release() }
        await model.start()
        await model.flushDrafts() // Also drains the accepted initial presentation save.
        XCTAssertNil(model.offlineCacheIssue)
        await gate.armFailure()
        let scope = model.readerSessionID
        let first = Task { try await model.activate(fixture.device, scope: scope) }
        await fulfillment(of: [gate.arrived], timeout: 5)
        XCTAssertFalse(model.canChangeLibrary, "Actions stay paused until owned restoration and publication finish")
        let replacementEntered = expectation(description: "Replacement activation begins on the main actor")
        let second = Task { @MainActor in
            // activate enters its synchronous ownership fence on this same
            // actor before suspending behind the first restore's accepted read.
            replacementEntered.fulfill()
            return try await model.activate(fixture.device, scope: scope)
        }
        await fulfillment(of: [replacementEntered], timeout: 5)
        await gate.release()
        do { _ = try await first.value; XCTFail("The older activation must not retain publication authority") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try await second.value

        XCTAssertNil(model.offlineCacheIssue, "A losing restore's error must not overwrite the current activation")
        XCTAssertEqual(model.papers.map(\.id), [fixture.catalog.document])
        model.select(try XCTUnwrap(model.papers.first))
        try await observe("The current activation can still read the installed copy") { model.selectedPaper?.readerBundle != nil }
        XCTAssertNil(model.readerOpenIssue)
    }

    func testQuarantineArrivingDuringActivationPersistsBeforeALaterOutage() async throws {
        let gate = OfflineModelVerificationGate()
        let fixture = try await fixture(verification: { try await gate.verify($0) }), model = fixture.model
        addTeardownBlock { await gate.release() }
        await model.start()
        await model.flushDrafts()
        model.select(try XCTUnwrap(model.papers.first))
        await fulfillment(of: [gate.arrived], timeout: 5)

        fixture.server.setAvailability("quarantined")
        let responseHeld = expectation(description: "Quarantine response is in flight before activation")
        fixture.server.holdNextChanges(responseHeld)
        let refreshing = Task { await model.refreshLibrary() }
        addTeardownBlock { fixture.server.releaseChanges(); await refreshing.value }
        await fulfillment(of: [responseHeld], timeout: 5)
        let session = model.readerSessionID
        let activation = Task { try await model.activate(fixture.device, scope: session) }
        addTeardownBlock { activation.cancel(); await gate.release(); _ = await activation.result }
        // Cancellation of the held verifier proves activation reached the
        // coordinator pause, rather than merely beginning its earlier work.
        await fulfillment(of: [gate.cancelled], timeout: 5)
        fixture.server.releaseChanges()
        await refreshing.value

        XCTAssertNil(model.selectedPaper?.readerBundle)
        XCTAssertNotNil(model.readerOpenIssue, "The live block applies even though the cache writer is temporarily paused")
        XCTAssertNil(model.offlineCacheIssue, "Intentional activation deferral is not a failed cache checkpoint")
        let requestsBefore = fixture.server.requests().count
        await model.refreshLibrary()
        XCTAssertEqual(fixture.server.requests().count, requestsBefore, "A paused writer cannot accumulate unlimited replacement observations")

        await gate.release()
        _ = try await activation.value
        fixture.server.setAvailability("unavailable")
        await model.refreshLibrary()
        model.retryOpeningSelectedPaper()
        XCTAssertNil(model.selectedPaper?.readerBundle)
        XCTAssertNotNil(model.readerOpenIssue)
        XCTAssertNil(model.offlineCacheIssue)
        await model.flushDrafts()
        await model.signOut()
        await model.waitForLocalRetirement()

        let store = try fixture.reopenStore()
        let restored = try await store.listInstalledReaderBundles(scope: fixture.scope)
        let installation = try XCTUnwrap(restored.installations.first)
        XCTAssertEqual(installation.block, .quarantined, "The accepted intermediate block must reach disk before the ordinary outage")
        XCTAssertEqual(installation.eligibility.cursor, 3)
    }

    func testFirstKeyRecoveryPreservesAnExistingLiveObservationAndTheInflightRefresh() async throws {
        let gate = OfflineModelRestorationGate()
        let fixture = try await fixture(directory: { try await gate.read($0, scope: $1) }), model = fixture.model
        addTeardownBlock { await gate.release() }
        try fixture.requireKeyRecovery()
        await model.start()
        XCTAssertTrue(model.needsRecovery)
        XCTAssertTrue(model.libraryHasSnapshot, "The first live library can exist before private keys are approved")
        XCTAssertFalse(model.canChangeLibrary)
        model.select(try XCTUnwrap(model.papers.first))
        XCTAssertNil(model.selectedPaper?.readerBundle)

        fixture.server.setAvailability("quarantined")
        let responseHeld = expectation(description: "A second live library observation is already in flight")
        fixture.server.holdNextChanges(responseHeld)
        let refreshing = Task { await model.refreshLibrary() }
        addTeardownBlock { fixture.server.releaseChanges(); await refreshing.value }
        await fulfillment(of: [responseHeld], timeout: 5)
        await gate.arm()
        fixture.server.setDeviceEnvelopeAvailable(true)
        let session = model.readerSessionID
        let recovery = Task { try await model.activate(fixture.device, scope: session) }
        addTeardownBlock { recovery.cancel(); await gate.release(); _ = await recovery.result }
        // Both the newly registered C1 checkpoint and the first directory
        // restoration remain gated; C2 therefore crosses the activation.
        await fulfillment(of: [gate.arrived], timeout: 5)
        fixture.server.releaseChanges()
        await refreshing.value
        XCTAssertNil(model.offlineCacheIssue, "Replaying C1 must not consume the one in-flight C2 deferral slot")
        XCTAssertFalse(model.canChangeLibrary)

        await gate.release()
        _ = try await recovery.value
        XCTAssertFalse(model.needsRecovery)
        XCTAssertNil(model.offlineCacheIssue)
        XCTAssertNil(model.selectedPaper?.readerBundle)
        XCTAssertNotNil(model.readerOpenIssue)
        await model.flushDrafts()
        await model.signOut()
        await model.waitForLocalRetirement()
        let store = try fixture.reopenStore()
        let cached = try await store.cachedLibraryPresentation(scope: fixture.scope)
        let installed = try await store.listInstalledReaderBundles(scope: fixture.scope)
        XCTAssertEqual(cached?.committedCursor, 2)
        XCTAssertEqual(installed.installations.first?.block, .quarantined)
    }
}

@MainActor
private final class OfflineModelFixture {
    let catalog = OfflineModelCatalog()
    let additionalCatalogs: [OfflineModelCatalog]
    let environment = "offline-model-\(UUID().wire)"
    let root: URL
    let device: LocalDevice
    let bundle: VerifiedReaderBundle
    let scope: LibraryCommandScope
    let server: OfflineModelServer
    let model: ReaderModel
    private let network: URLSession
    private var host: String { environment + ".invalid" }

    init(expired: Bool, paperCount: Int, verification: @escaping ReaderBundleCoordinator.Verification,
         directory: @escaping ReaderBundleCoordinator.DirectoryReader) throws {
        precondition((1...3).contains(paperCount))
        let account = catalog.account
        additionalCatalogs = (1..<paperCount).map { OfflineModelCatalog(account: account, sequence: Int64($0 + 1)) }
        let configuration = BackendConfiguration(url: URL(string: "https://\(environment).invalid")!,
                                                 anonKey: "fixture", environment: environment)
        root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                           appropriateFor: nil, create: true).appendingPathComponent(environment)
        var device = LocalDevice.create(accountID: catalog.account)
        device.bundle = KeyBundle.generate(accountID: catalog.account)
        self.device = device
        bundle = try ReaderBundleLoader.sample()
        scope = try LibraryCommandScope(accountID: catalog.account, deploymentID: configuration.url.absoluteString)
        let session = AuthSession(access_token: "offline-fixture-token", refresh_token: "offline-fixture-refresh",
            expires_at: Date().timeIntervalSince1970 + (expired ? -3_600 : 3_600),
            user: .init(id: catalog.account, email: "offline-fixture@example.invalid"))
        try KeychainVault.write(ReaderCrypto.encode(session), name: environment + ".auth-session")
        try KeychainVault.write(ReaderCrypto.encode(device), name: "\(environment).\(catalog.account.wire).device-keys")
        server = try OfflineModelServer(catalog: catalog, additionalCatalogs: additionalCatalogs, device: device, holdRefresh: expired)
        let server = server
        StubProtocol.install(host: configuration.url.host!) { server.handle($0) }
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [StubProtocol.self]
        network = URLSession(configuration: settings)
        model = ReaderModel(configuration: configuration, client: try BackendClient(configuration: configuration, network: network),
            readerBundleVerification: verification, readerBundleDirectoryReader: directory)
    }

    func seed() async throws {
        // This writer is never used again once the model opens its account;
        // startup must claim the normal fresh-writer generation itself.
        let store = try reopenStore()
        try await store.saveLibraryPresentation(catalog.observation(additionalCatalogs: additionalCatalogs), scope: scope)
        for entry in [catalog] + additionalCatalogs {
            let binding = try ReaderArtifactBinding(scope: scope, documentID: entry.document,
                artifactID: entry.artifact, manifestSHA256: bundle.manifestSHA256)
            let ticket = try await store.beginReaderInstall(binding: binding)
            _ = try await store.commitReaderInstall(ticket, bundle: bundle)
        }
    }

    /// Seed through the actual private event and encrypted draft APIs before
    /// startup; model history/draft restoration supplies the selection routes.
    func seedConversationAndDraft(conversationDocument: UUID, draftDocument: UUID) async throws -> (conversationID: UUID, draftID: UUID) {
        let store = try reopenStore(), conversation = UUID(), rootEvent = UUID(), message = UUID(), draft = UUID()
        _ = try await store.appendBatch([
            (id: rootEvent, event: PrivateEvent(kind: .conversation, entityID: conversation,
                documentID: conversationDocument, text: "Saved paper conversation")),
            (id: message, event: PrivateEvent(kind: .message, entityID: message, parents: [rootEvent],
                conversationID: conversation, documentID: conversationDocument, text: "A saved paper question",
                role: .user, status: .complete))
        ], deviceID: device.deviceID)
        _ = try await store.saveDraft(LocalDraft(id: draft, documentID: draftDocument,
            revision: 1, textRevision: UUID(), text: "Keep this unsent paper question",
            editedAt: Date(), branchRevision: UUID()))
        return (conversation, draft)
    }

    func seedPendingAndResolvedImports() async throws -> [UUID] {
        let store = try reopenStore()
        let pending = try await store.enqueueLibraryCommand(scope: scope,
            mutation: .beginImport(sourceID: "2404.00002", requestedRevision: nil, observedCursor: 1), display: "Pending fixture")
        let resolved = try await store.enqueueLibraryCommand(scope: scope,
            mutation: .beginImport(sourceID: "2404.00001", requestedRevision: nil, observedCursor: 1), display: "Resolved fixture")
        // Both exact requests were issued, but their acknowledgements were
        // lost. Cached server mappings alone cannot settle either command.
        _ = try await store.beginLibraryAttempt(pending, scope: scope)
        _ = try await store.beginLibraryAttempt(resolved, scope: scope)
        func imported(_ id: UUID, source: String, sequence: Int, ready: Bool) -> [String: Any] {
            ["kind": "import", "id": id.wire, "created_seq": sequence, "state_seq": sequence,
             "intent_revision": 1, "visible": !ready, "phase": ready ? "ready" : "accepted", "source": "arxiv",
             "source_id": source, "requested_revision": NSNull(), "source_revision": ready ? (1 as Any) : NSNull(),
             "metadata_id": ready ? (catalog.metadata.wire as Any) : NSNull(),
             "version_id": ready ? (catalog.version.wire as Any) : NSNull(),
             "metadata": ready ? catalog.row()["metadata"]! : NSNull(),
             "metadata_recorded_at": ready ? ("2026-10-03T10:00:00Z" as Any) : NSNull(),
             "source_url": "https://arxiv.org/abs/" + source + (ready ? "v1" : ""),
             "document_id": ready ? (catalog.document.wire as Any) : NSNull(),
             "library_item_id": ready ? (catalog.item.wire as Any) : NSNull(),
             "error_code": NSNull(), "retryable": false]
        }
        let baseline: [String: Any] = ["format": 2, "account_id": catalog.account.wire, "baseline_cursor": 3, "retained_after": 0,
            "entries": [catalog.row(), imported(pending.intentID, source: "2404.00002", sequence: 2, ready: false),
                        imported(resolved.intentID, source: "2404.00001", sequence: 3, ready: true)],
            "has_more": false, "next_cursor": ["format": 2, "account_id": catalog.account.wire, "through": 3,
                "created_seq": 3, "id": resolved.intentID.wire, "kind": "import"]]
        var reconciler = LibraryReconciler(accountID: catalog.account)
        let first = try reconciler.nextRequest()
        try reconciler.accept(LibraryWire.decodeBaseline(OfflineModelCatalog.bytes(baseline)), for: first)
        let next = try reconciler.nextRequest()
        try reconciler.accept(LibraryWire.decodeChanges(catalog.changes(after: 3, through: 3)), for: next)
        try await store.saveLibraryPresentation(reconciler.completeObservation(), scope: scope)
        return [pending.intentID, resolved.intentID]
    }

    func seedPresentation(rows: [[String: Any]], cursor: Int64) async throws -> [LibraryEntry] {
        let store = try reopenStore()
        let last = try XCTUnwrap(rows.last)
        let baseline: [String: Any] = ["format": 2, "account_id": catalog.account.wire,
            "baseline_cursor": cursor, "retained_after": 0, "entries": rows, "has_more": false,
            "next_cursor": ["format": 2, "account_id": catalog.account.wire, "through": cursor,
                "created_seq": last["created_seq"]!, "id": last["id"]!, "kind": last["kind"]!]]
        var reconciler = LibraryReconciler(accountID: catalog.account)
        let first = try reconciler.nextRequest()
        try reconciler.accept(LibraryWire.decodeBaseline(OfflineModelCatalog.bytes(baseline)), for: first)
        let next = try reconciler.nextRequest()
        try reconciler.accept(LibraryWire.decodeChanges(catalog.changes(after: cursor, through: cursor)), for: next)
        try await store.saveLibraryPresentation(reconciler.completeObservation(), scope: scope)
        return reconciler.orderedEntries
    }

    func requireKeyRecovery() throws {
        let unapproved = LocalDevice(accountID: device.accountID, deviceID: device.deviceID,
            privateKey: device.privateKey, challenge: device.challenge, localStoreKey: device.localStoreKey)
        try KeychainVault.write(ReaderCrypto.encode(unapproved), name: "\(environment).\(catalog.account.wire).device-keys")
        server.setDeviceEnvelopeAvailable(false)
    }

    /// Call only before start or after the model's retirement barrier drains.
    func reopenStore() throws -> EncryptedStore {
        try EncryptedStore(url: root.appendingPathComponent(catalog.account.wire).appendingPathComponent("private-state.enc"),
            accountID: catalog.account, localKey: device.localStoreKey, keys: XCTUnwrap(device.bundle))
    }

    func close() async {
        server.releaseRefresh()
        server.releaseChanges()
        await model.flushDrafts()
        await model.signOut()
        await model.waitForLocalRetirement()
        network.invalidateAndCancel()
        StubProtocol.remove(host: host)
        for name in [environment + ".auth-session", "\(environment).\(catalog.account.wire).device-keys",
                     "\(environment).\(catalog.account.wire).support-outbox-key"] {
            try? KeychainVault.delete(name)
        }
        try? FileManager.default.removeItem(at: root)
    }
}

private struct OfflineModelCatalog: Sendable {
    let account: UUID
    let sequence: Int64
    let document = UUID(), artifact = UUID(), item = UUID()
    let approval = UUID(), version = UUID(), metadata = UUID(), original = UUID()
    private var sourceID: String { "2404." + String(format: "%05d", Int(sequence)) }

    init(account: UUID = UUID(), sequence: Int64 = 1) {
        self.account = account; self.sequence = sequence
    }

    func row(state: Int64 = 1, availability: String = "available") -> [String: Any] {
        ["kind": "item", "id": item.wire, "document_id": document.wire, "created_seq": sequence, "state_seq": state,
         "membership_revision": 1, "visible": true, "added_at": "2026-10-03T10:00:00Z", "last_remove_seq": 0,
         "approval_id": approval.wire, "version_id": version.wire, "metadata_id": metadata.wire, "source": "arxiv",
         "source_id": sourceID, "source_revision": 1, "metadata": ["title": "Synthetic account's authored reading fixture",
            "authors": ["Offline Fixture"], "abstract": "Account-scoped local reading test, with no server artifact claim.",
            "categories": ["cs.LG"], "published_at": "2024-04-03", "updated_at": "2024-04-03", "venue": NSNull()],
         "metadata_recorded_at": "2026-10-03T10:00:00Z", "source_url": "https://arxiv.org/abs/" + sourceID + "v1",
         "scope": "shared_catalog", "page_count": 1, "original_object_id": original.wire, "artifact_id": artifact.wire,
         "readiness": availability == "available" ? "converted_ready" : "unavailable", "original_availability": "available",
         "render_availability": availability, "original_availability_revision": 1, "render_availability_revision": state]
    }

    func baseline(state: Int64 = 1, availability: String = "available", additionalCatalogs: [Self] = []) -> Data {
        let last = additionalCatalogs.last ?? self
        return Self.bytes(["format": 2, "account_id": account.wire, "baseline_cursor": state, "retained_after": 0,
            "entries": ([self] + additionalCatalogs).map { $0.row(state: state, availability: availability) }, "has_more": false,
            "next_cursor": ["format": 2, "account_id": account.wire, "through": state,
                "created_seq": last.sequence, "id": last.item.wire, "kind": "item"]])
    }

    func changes(after: Int64, through: Int64, availability: String = "available", additionalCatalogs: [Self] = []) -> Data {
        Self.bytes(["format": 2, "account_id": account.wire, "through": through, "retained_after": 0,
            "changes": after < through ? [["seq": through, "entries": ([self] + additionalCatalogs).map {
                $0.row(state: through, availability: availability)
            }]] : [],
            "next_cursor": through, "has_more": false])
    }

    func observation(additionalCatalogs: [Self] = []) throws -> LibraryCompleteObservation {
        let through = additionalCatalogs.last?.sequence ?? sequence
        var reconciler = LibraryReconciler(accountID: account)
        let baselineRequest = try reconciler.nextRequest()
        try reconciler.accept(LibraryWire.decodeBaseline(baseline(state: through, additionalCatalogs: additionalCatalogs)), for: baselineRequest)
        let deltaRequest = try reconciler.nextRequest()
        try reconciler.accept(LibraryWire.decodeChanges(changes(after: through, through: through, additionalCatalogs: additionalCatalogs)), for: deltaRequest)
        return try reconciler.completeObservation()
    }

    static func bytes(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }
}

private final class OfflineModelServer: @unchecked Sendable {
    let refreshArrived = XCTestExpectation(description: "Expired session attempts token refresh")
    private let lock = NSLock()
    private let catalog: OfflineModelCatalog
    private let additionalCatalogs: [OfflineModelCatalog]
    private let keyState: Data
    private let recoveryState: Data
    private var deviceEnvelopeAvailable = true
    private var holdRefresh: Bool
    private var pendingRefresh: StubProtocol?
    private var holdChanges: XCTestExpectation?
    private var pendingChanges: (StubProtocol, Data)?
    private var state: Int64 = 1
    private var availability = "available"
    private var paths: [String] = []

    init(catalog: OfflineModelCatalog, additionalCatalogs: [OfflineModelCatalog], device: LocalDevice, holdRefresh: Bool) throws {
        self.catalog = catalog; self.additionalCatalogs = additionalCatalogs; self.holdRefresh = holdRefresh
        state = additionalCatalogs.last?.sequence ?? catalog.sequence
        let keys = try XCTUnwrap(device.bundle)
        let publicKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: device.privateKey).publicKey.rawRepresentation
        let envelope = try ReaderCrypto.wrapForDevice(keys, deviceID: device.deviceID,
            recipientPublicKey: publicKey, challenge: device.challenge)
        keyState = OfflineModelCatalog.bytes(["epoch": keys.epoch, "recovery_package": "\\x", "device_envelope": DeviceKeys.hex(envelope)])
        recoveryState = OfflineModelCatalog.bytes(["epoch": keys.epoch, "recovery_package": "\\x", "device_envelope": NSNull()])
    }

    func requests() -> [String] { lock.withLock { paths } }
    func setAvailability(_ value: String) { lock.withLock { state += 1; availability = value } }
    func setDeviceEnvelopeAvailable(_ value: Bool) { lock.withLock { deviceEnvelopeAvailable = value } }
    func holdNextChanges(_ arrival: XCTestExpectation) { lock.withLock { holdChanges = arrival } }
    func releaseChanges() {
        let pending = lock.withLock { () -> (StubProtocol, Data)? in
            let response = pendingChanges; pendingChanges = nil
            return response
        }
        if let (request, bytes) = pending { request.respond(bytes) }
    }
    func releaseRefresh() {
        let pending = lock.withLock { () -> StubProtocol? in
            holdRefresh = false
            let request = pendingRefresh; pendingRefresh = nil
            return request
        }
        pending?.respond(Data("{}".utf8), status: 503)
    }

    func handle(_ request: StubProtocol) {
        lock.withLock {
            let path = request.request.url!.lastPathComponent
            paths.append(path)
            switch path {
            case "token":
                if holdRefresh {
                    holdRefresh = false; pendingRefresh = request; refreshArrived.fulfill()
                } else { request.respond(Data("{}".utf8), status: 503) }
            case "v1_key_state": request.respond(deviceEnvelopeAvailable ? keyState : recoveryState)
            case "v2_pull_events":
                let after = (Self.fields(request.request)["p_after"] as? NSNumber)?.int64Value ?? 0
                request.respond(OfflineModelCatalog.bytes(["events": [], "next_cursor": after, "has_more": false]))
            case "v1_acknowledge_cursor": request.respond(Data(), status: 204)
            case "v2_library_page": request.respond(catalog.baseline(state: state, availability: availability, additionalCatalogs: additionalCatalogs))
            case "v2_library_changes":
                let input = Self.fields(request.request)
                let after = (input["p_after"] as? NSNumber)?.int64Value ?? 0
                let through = (input["p_through"] as? NSNumber)?.int64Value ?? state
                let bytes = catalog.changes(after: after, through: through, availability: availability, additionalCatalogs: additionalCatalogs)
                if let arrival = holdChanges {
                    holdChanges = nil; pendingChanges = (request, bytes); arrival.fulfill()
                } else { request.respond(bytes) }
            case "v2_reports": request.respond(Data("[]".utf8))
            case "logout": request.respond(Data("{}".utf8))
            default: request.respond(Data("{}".utf8), status: 503)
            }
        }
    }

    private static func fields(_ request: URLRequest) -> [String: Any] {
        let bytes: Data
        if let body = request.httpBody { bytes = body }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            bytes = body
        } else { bytes = Data() }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
    }
}

@MainActor
private final class OfflineModelObservation {
    let ready: XCTestExpectation
    private let condition: @MainActor () -> Bool
    private var stopped = false
    init(_ description: String, condition: @escaping @MainActor () -> Bool) {
        ready = XCTestExpectation(description: description); self.condition = condition
    }
    func start() {
        guard !stopped else { return }
        let complete = withObservationTracking { condition() } onChange: {
            Task { @MainActor [weak self] in self?.start() }
        }
        if complete { stopped = true; ready.fulfill() }
    }
    func stop() { stopped = true }
}

/// This verifier can deliberately return a valid bundle after cancellation.
/// The coordinator must still join it and fence that obsolete completion.
private actor OfflineModelSelectionVerifier {
    private struct Hold {
        let arrived: XCTestExpectation
        let cancelled: XCTestExpectation?
        let ignoreCancellation: Bool
    }
    private var nextHold: Hold?
    private var continuation: CheckedContinuation<Void, Never>?
    private var calls = 0
    private var active = 0
    private var maximum = 0

    func arm(arrived: XCTestExpectation, cancelled: XCTestExpectation? = nil, ignoreCancellation: Bool = false) {
        precondition(nextHold == nil && continuation == nil)
        nextHold = Hold(arrived: arrived, cancelled: cancelled, ignoreCancellation: ignoreCancellation)
    }

    func verify(_ input: ReaderBundleInput) async throws -> VerifiedReaderBundle {
        calls += 1; active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        let hold = nextHold; nextHold = nil
        if let hold {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    hold.arrived.fulfill()
                }
            } onCancel: { hold.cancelled?.fulfill() }
        }
        if hold?.ignoreCancellation == true {
            // Detached admission has no inherited cancellation. Returning it
            // exercises the real callback fence, not just a thrown test error.
            return try await Task.detached {
                try ReaderBundleLoader.verify(manifest: input.manifestData,
                    expectedSHA256: input.expectedSHA256, members: input.members)
            }.value
        }
        return try await ReaderBundleInput.verify(input)
    }

    func callCount() -> Int { calls }
    func maximumConcurrent() -> Int { maximum }
    func release() {
        nextHold = nil
        continuation?.resume(); continuation = nil
    }
}

private actor OfflineModelVerificationGate {
    nonisolated let arrived = XCTestExpectation(description: "Native bundle verification is suspended")
    nonisolated let cancelled = XCTestExpectation(description: "Reader pause cancels the held native verifier")
    private var first = true
    private var continuation: CheckedContinuation<Void, Never>?
    func verify(_ input: ReaderBundleInput) async throws -> VerifiedReaderBundle {
        if first {
            first = false
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    arrived.fulfill()
                }
            } onCancel: { self.cancelled.fulfill() }
        }
        return try await ReaderBundleInput.verify(input)
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor OfflineModelDirectoryGate {
    private enum Failure: Error { case simulatedReadFailure }
    nonisolated let arrived = XCTestExpectation(description: "Old activation's directory read is suspended")
    private var failNext = false
    private var continuation: CheckedContinuation<Void, Never>?
    func armFailure() { failNext = true }
    func read(_ store: EncryptedStore, scope: LibraryCommandScope) async throws -> InstalledReaderBundleList {
        let list = try await store.listInstalledReaderBundles(scope: scope)
        if failNext {
            failNext = false
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                arrived.fulfill()
            }
            throw Failure.simulatedReadFailure
        }
        return list
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor OfflineModelRestorationGate {
    nonisolated let arrived = XCTestExpectation(description: "The first key activation is restoring its installed directory")
    private var armed = false
    private var announced = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func arm() { armed = true }
    func read(_ store: EncryptedStore, scope: LibraryCommandScope) async throws -> InstalledReaderBundleList {
        let list = try await store.listInstalledReaderBundles(scope: scope)
        if armed {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
                if !announced { announced = true; arrived.fulfill() }
            }
        }
        return list
    }
    func release() {
        armed = false
        continuations.forEach { $0.resume() }; continuations = []
    }
}
