import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// A network that misbehaves the ways a phone's does: no network at all, a connection that drops partway, a body cut
/// short without an error, and a captive Wi‑Fi answering with its sign-in page.
private final class BadNetworkProtocol: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable { case offline, timeout, tls, dropAfter(Int), shortBody(sent: Int, declared: Int), captivePage }
    nonisolated(unsafe) static var mode: Mode = .offline
    nonisolated(unsafe) static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        func respond(_ headers: [String: String]) {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!,
                                cacheStoragePolicy: .notAllowed)
        }
        switch Self.mode {
        case .offline: client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .timeout: client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        case .tls: client?.urlProtocol(self, didFailWithError: URLError(.serverCertificateUntrusted))
        case .dropAfter(let count):
            respond(["Content-Type": "application/pdf", "Content-Length": String(Self.body.count)])
            client?.urlProtocol(self, didLoad: Self.body.prefix(count))
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .shortBody(let sent, let declared):
            respond(["Content-Type": "application/pdf", "Content-Length": String(declared)])
            client?.urlProtocol(self, didLoad: Self.body.prefix(sent))
            client?.urlProtocolDidFinishLoading(self)
        case .captivePage:
            respond(["Content-Type": "text/html; charset=utf-8"])
            client?.urlProtocol(self, didLoad: Data("<html><title>Sign in to Wi-Fi</title></html>".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private final class StoredSession: AuthenticationCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    init(_ value: Data) { self.value = value }
    func read(_ name: String) throws -> Data? { lock.withLock { value } }
    func write(_ data: Data, name: String) throws { lock.withLock { value = data } }
    func delete(_ name: String) throws { lock.withLock { value = nil } }
}

/// docs/reviews/OFFLINE_AND_STORAGE_20261025.md: no network, a bad connection and a full disk each say so in one short
/// line, never as a refusal, a broken paper or a generic failure; the work that can resume does.
@MainActor
final class OfflineAndStorageTests: XCTestCase {
    func testEachFailureHasOneShortSpecificLine() {
        XCTAssertEqual(ConnectionText.message(for: URLError(.notConnectedToInternet)), "You’re offline. What’s on this device still works.")
        XCTAssertEqual(ConnectionText.message(for: URLError(.dataNotAllowed)), ConnectionText.offline, "cellular data off for the app")
        XCTAssertEqual(ConnectionText.message(for: URLError(.timedOut), reaching: "arXiv"), "arXiv took too long to answer. Try again.")
        XCTAssertEqual(ConnectionText.message(for: URLError(.cannotFindHost)), "Couldn’t reach Gradstep. Check your connection and try again.")
        XCTAssertTrue(ConnectionText.message(for: URLError(.serverCertificateUntrusted))?.contains("If this Wi‑Fi asks you to sign in") == true,
                      "a captive Wi‑Fi in place of the server")
        XCTAssertEqual(ConnectionText.message(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)),
                       "The connection was lost. Try again.")
        XCTAssertNil(ConnectionText.message(for: URLError(.cancelled)))
        XCTAssertNil(ConnectionText.message(for: BackendError.rejected("insufficient_credits")), "a refusal keeps its own words")
        XCTAssertEqual(ConnectionText.message(for: POSIXError(.ENOSPC)), "This device is out of space. Free up some space and try again.")
        XCTAssertEqual(ChatFailureText.message(for: "offline"), "You’re offline. Your question is saved; try again when you’re connected.")
        XCTAssertTrue(ChatFailureText.isRetryable("offline") && ChatFailureText.isRetryable("unreachable") && ChatFailureText.isRetryable("network_sign_in"))
    }

    func testSyncSaysOfflineAndResumesByItself() {
        XCTAssertEqual(ReaderModel.syncIssue(for: URLError(.notConnectedToInternet)), "Offline · Saved on this device")
        let offline = SyncSummary.from(status: "Saved on this device · Sync paused", issue: ConnectionText.offlineSync, pending: 2)
        XCTAssertEqual(offline.short, "Offline"); XCTAssertEqual(offline.title, "You’re offline")
        XCTAssertEqual(ReaderModel.syncIssue(for: URLError(.timedOut)), "Can’t reach Gradstep · Saved on this device")
        XCTAssertEqual(ReaderModel.syncIssue(for: BackendError.rejected("network_sign_in")), ConnectionText.networkSignIn)
        XCTAssertEqual(ReaderModel.syncIssue(for: POSIXError(.ENOSPC)), "This device is out of space. Free up some space and try again.")
        XCTAssertEqual(ReaderModel.syncIssue(for: ReaderError.cursorGap), ReaderError.cursorGap.errorDescription, "other causes keep their words")
        XCTAssertEqual(ReaderModel.draftIssue(StorageFullError(needed: 1)), "Draft not saved: this device is out of space.")
        XCTAssertEqual(ReaderModel.draftIssue(ReaderError.storageUnavailable), "Draft not saved on this device. Try saving it again.")
    }

    /// Offline with an expired token on a new device: the refresh's connection failure is retried like any other, never
    /// sent to the recovery sheet.
    func testATokenRefreshThatCantConnectIsTheConnection() {
        XCTAssertTrue(ReaderModel.isReachability(AuthenticationError.connection))
        XCTAssertFalse(ReaderModel.isReachability(AuthenticationError.sessionExpired))
        XCTAssertFalse(ReaderModel.isReachability(AuthenticationError.invalidCode))
    }

    // MARK: arXiv

    func testOpeningAPaperOfflineOffersTryAgainNotItsPDF() async throws {
        let suite = "arxiv.offline.test.\(UUID().uuidString)"
        ArxivHTMLReader.refusalSuite = suite
        ArxivHTMLReader.fixtureProtocolClasses = [BadNetworkProtocol.self]
        defer { ArxivHTMLReader.fixtureProtocolClasses = nil; ArxivHTMLReader.refusalSuite = nil; UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        BadNetworkProtocol.mode = .offline
        do { _ = try await ArxivHTMLReader().prepare(try ArxivReaderSource(sourceID: "2610.00001", revision: 1)); XCTFail("offline") }
        catch {
            guard case ArxivHTMLError.offline = error else { return XCTFail("\(error)") }
            XCTAssertEqual(ReaderOpenFallback(error), .none, "Try again; a PDF would fail the same way")
            XCTAssertTrue((error as? ArxivHTMLError)?.message.hasPrefix("You’re offline.") == true)
        }
        BadNetworkProtocol.mode = .timeout
        do { _ = try await ArxivHTMLReader().prepare(try ArxivReaderSource(sourceID: "2610.00002", revision: 1)); XCTFail("timed out") }
        catch { guard case ArxivHTMLError.retrieval = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(ReaderOpenFallback(URLError(.networkConnectionLost)), .none)
        XCTAssertEqual(ReaderOpenFallback(StorageFullError(needed: 30_000_000)), .space)
        XCTAssertEqual(ReaderOpenFallback(ArxivHTMLError.compiler("arxiv_math_coverage")), .pdf, "a paper the reader can't show still offers its PDF")
        XCTAssertEqual(ReaderModel.preparationReason(StorageFullError(needed: 30_000_000)), "This device is out of space. Free up 30 MB and try again.")
        XCTAssertEqual(ReaderModel.preparationReason(URLError(.notConnectedToInternet)), ConnectionText.offline)
    }

    // MARK: PDFs downloaded on this device

    private func fetcher() -> DevicePDFFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BadNetworkProtocol.self]
        return DevicePDFFetcher(resolve: { _ in ["93.184.216.34"] }, configuration: configuration)
    }

    func testAPDFWhoseConnectionDropsPartwayIsUnreachableNotRefused() async throws {
        BadNetworkProtocol.body = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x20, count: 300_000)
        BadNetworkProtocol.mode = .dropAfter(100_000)
        do { _ = try await fetcher().fetch([URL(string: "https://repo.example.org/paper.pdf")!]) { _ in }; XCTFail("dropped") }
        catch { XCTAssertEqual(error as? DeviceFetchError, .unreachable, "was a raw error shown as “couldn’t download… open it in Safari”") }
        XCTAssertEqual(DeviceFetchError.unreachable.message, "Couldn’t reach the paper’s website from this device. Check your connection and try again.")
    }

    func testAPDFShorterThanItsDeclaredLengthIsNeverKept() async throws {
        BadNetworkProtocol.body = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x20, count: 300_000)
        BadNetworkProtocol.mode = .shortBody(sent: 150_000, declared: 300_009)
        do { _ = try await fetcher().fetch([URL(string: "https://repo.example.org/short.pdf")!]) { _ in }; XCTFail("cut short") }
        catch { XCTAssertEqual(error as? DeviceFetchError, .unreachable) }
        // The whole body is kept as before.
        BadNetworkProtocol.mode = .shortBody(sent: 300_009, declared: 300_009)
        let whole = try await fetcher().fetch([URL(string: "https://repo.example.org/whole.pdf")!]) { _ in }
        defer { try? FileManager.default.removeItem(at: whole.file) }
        XCTAssertEqual(try Data(contentsOf: whole.file).count, 300_009)
    }

    // MARK: Gradstep

    func testACaptiveWiFiPageInPlaceOfGradstepSaysSignInToTheWiFi() async throws {
        let host = "captive-\(UUID().wire).invalid", account = UUID()
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [BadNetworkProtocol.self]
        let session = try ReaderCrypto.encode(AuthSession(access_token: "fixture-access", refresh_token: "fixture-refresh",
            expires_at: Date().timeIntervalSince1970 + 3_600, user: .init(id: account, email: nil)))
        let client = try BackendClient(configuration: .init(url: URL(string: "https://\(host)")!, anonKey: "fixture-anon", environment: host),
                                       network: URLSession(configuration: settings), credentials: StoredSession(session))
        BadNetworkProtocol.mode = .captivePage
        do { _ = try await client.creditBalance(accountID: account); XCTFail("a web page isn't a balance") }
        catch let error as BackendError {
            guard case .rejected("network_sign_in") = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.isTransient, "sync and polls retry it with back-off")
            XCTAssertEqual(error.errorDescription, "This Wi‑Fi needs you to sign in. Open Safari to sign in, then try again.")
        }
        BadNetworkProtocol.mode = .offline
        do { _ = try await client.creditBalance(accountID: account); XCTFail("offline") }
        catch { XCTAssertTrue(ConnectionText.isOffline(error), "\(error)"); XCTAssertTrue(ReaderModel.isReachability(error)) }
    }

    // MARK: The on-device model

    func testTheModelDownloadSaysHowMuchToFreeBeforeDownloading() {
        XCTAssertEqual(DeviceModelAssets.spaceIssue(packBytes: 365_200_000, available: 200_000_000),
                       "This device is out of space. Free up 583 MB and try again.")
        XCTAssertNil(DeviceModelAssets.spaceIssue(packBytes: 365_200_000, available: 2_000_000_000))
        XCTAssertNil(DeviceModelAssets.spaceIssue(packBytes: 365_200_000, available: nil), "unknown free space never refuses")
        XCTAssertTrue(DeviceModelAssets.message(for: NSError(domain: NSCocoaErrorDomain, code: NSBundleOnDemandResourceOutOfSpaceError))
            .hasPrefix("This device is out of space. Free up "))
        XCTAssertTrue(DeviceModelAssets.message(for: POSIXError(.ENOSPC)).hasPrefix("This device is out of space."), "POSIX ENOSPC too")
        XCTAssertEqual(DeviceModelAssets.message(for: URLError(.networkConnectionLost)), "The download stopped. Check the connection and try again.")
    }

    #if DEBUG && FIXTURE_HOST
    func testFaultArgumentsCoverBadConnectionsAndOtherHosts() {
        let faults = BackendFaultProtocol.parse(["--backend-fault=*:offline", "--backend-fault=arxiv.org/html:lost", "--backend-fault=rest/v1/rpc:html",
                                                 "--backend-fault=functions/v1/chat:tls", "--backend-fault=auth/v1/token:dns", "--backend-fault=x:nonsense"])
        XCTAssertEqual(faults.map(\.kind), [.offline, .lost, .html, .tls, .dns])
        XCTAssertEqual(faults[1].prefix, "arxiv.org/html")
    }
    #endif

    // MARK: The Feed's last page, kept on the device (owner, 2026-10-25)

    func testTheFeedSaysOfflineOnlyWhenItIs() {
        XCTAssertTrue(ReaderModel.feedFailureIsOffline(URLError(.notConnectedToInternet), deviceOffline: false))
        XCTAssertTrue(ReaderModel.feedFailureIsOffline(AuthenticationError.connection, deviceOffline: true),
                      "an offline token refresh before the request")
        XCTAssertFalse(ReaderModel.feedFailureIsOffline(URLError(.timedOut), deviceOffline: false), "a slow server isn't offline")
        XCTAssertFalse(ReaderModel.feedFailureIsOffline(BackendError.rejected("rate_limited"), deviceOffline: true))
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(ReaderModel.feedOfflineLine(since: now.addingTimeInterval(-2 * 3_600), now: now), "Offline · from 2 hours ago")
    }

    #if targetEnvironment(simulator)
    private func feedResponse(_ ids: [String]) throws -> DiscoveryResponse {
        let rows: [[String: Any]] = ids.map {
            ["source_id": $0, "revision": 1, "title": "Paper \($0)", "authors": ["Mei Lin"], "year": 2026, "categories": ["cs.LG"],
             "abstract": "An abstract.", "reason": ["kind": "tag", "label": "RLHF", "text": "In your tag: RLHF"]]
        }
        return try JSONDecoder().decode(DiscoveryResponse.self, from: JSONSerialization.data(withJSONObject: ["feed": ["for_you": true], "results": rows]))
    }

    private func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out: \(description)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A launch of the synthetic account (its real encrypted folder), the Feed answered by `answer`.
    private func launch(reset: Bool, client: BackendClient? = nil, answer: @escaping @MainActor (FeedSelection) async throws -> DiscoveryResponse) async throws -> ReaderModel {
        let model = client.map { ReaderModel(configuration: BackendConfiguration(url: URL(string: "https://feed-kept.invalid")!, anonKey: "fixture",
                                                                                   environment: "feed-kept"), client: $0) } ?? ReaderModel(configuration: nil)
        try await model.configureDurableDraftFixture(reset: reset)
        model.feedPersonal = FeedPersonalization(available: true)
        model.feedRequestOverride = answer
        return model
    }

    /// Launched online, For you is kept; relaunched offline, it shows at once and stays with "Offline · from …", never
    /// "Feed unavailable"; relaunched online, the server's answer replaces it and becomes the kept page.
    func testTheFeedsLastPageShowsOfflineAtLaunchAndAnOnlineLaunchReplacesIt() async throws {
        defer { FeedPersonalization().save(to: .standard) }
        var first: ReaderModel? = try await launch(reset: true) { _ in try self.feedResponse(["2610.07767", "2610.05030"]) }
        first?.loadFeed()
        try await waitUntil("For you loads") { first?.feedResults.count == 2 }
        await first?.localPersistence.waitForAcceptedWrites()
        first = nil

        let offline = try await launch(reset: false) { _ in throw URLError(.notConnectedToInternet) }
        offline.loadFeed()
        XCTAssertEqual(offline.feedState, .loaded, "the kept page shows at once, before any answer")
        XCTAssertEqual(offline.feedResults.map(\.sourceID), ["2610.07767", "2610.05030"])
        XCTAssertEqual(offline.feedShown, .forYou)
        try await waitUntil("the offline line") { offline.feedOfflineNote != nil }
        XCTAssertEqual(offline.feedOfflineNote, "Offline · from a minute ago")
        XCTAssertNil(offline.feedStaleNote, "one quiet line, no banner")
        XCTAssertEqual(offline.feedState, .loaded, "never “Feed unavailable”")
        XCTAssertEqual(offline.feedResults.count, 2)

        let online = try await launch(reset: false) { _ in try self.feedResponse(["2610.09912"]) }
        online.loadFeed()
        XCTAssertEqual(online.feedResults.map(\.sourceID), ["2610.07767", "2610.05030"], "the kept page first")
        try await waitUntil("the answer replaces it") { online.feedResults.map(\.sourceID) == ["2610.09912"] }
        XCTAssertNil(online.feedOfflineNote); XCTAssertNil(online.feedStaleNote)
        await online.localPersistence.waitForAcceptedWrites()
        let kept = await online.localPersistence.feedPages?.load()
        XCTAssertEqual(kept?["for_you"]?.results.map(\.sourceID), ["2610.09912"], "the newest answer is the kept page")
    }

    /// Each chip keeps its own page; library papers stay hidden; with nothing kept, offline says so (not a spinner).
    func testEachViewKeepsItsPageAndLibraryPapersStayHidden() async throws {
        defer { FeedPersonalization().save(to: .standard) }
        var none: ReaderModel? = try await launch(reset: true) { _ in throw URLError(.notConnectedToInternet) }
        none?.loadFeed()
        try await waitUntil("offline with nothing kept") { none?.feedState != .loading }
        XCTAssertEqual(none?.feedState, .failed(ConnectionText.offline))
        await none?.localPersistence.waitForAcceptedWrites()
        none = nil

        let first = try await launch(reset: true) { selection in
            try self.feedResponse(selection == .forYou ? ["2610.07767"] : ["2610.03543", "2610.06120"])
        }
        first.loadFeed()
        try await waitUntil("For you") { first.feedResults.map(\.sourceID) == ["2610.07767"] }
        first.selectFeed(.category("cs.CL"))
        try await waitUntil("a category") { first.feedResults.count == 2 }
        await first.localPersistence.waitForAcceptedWrites()

        let offline = try await launch(reset: false) { _ in throw URLError(.notConnectedToInternet) }
        offline.selectFeed(.category("cs.CL"))
        XCTAssertEqual(offline.feedResults.map(\.sourceID), ["2610.03543", "2610.06120"])
        offline.selectFeed(.forYou)
        XCTAssertEqual(offline.feedResults.map(\.sourceID), ["2610.07767"], "For you's own page")
        // A kept paper the reader has since added is hidden, as the Feed always hides library papers.
        var added = Paper(id: UUID(), title: "Paper 2610.07767", authors: "Mei Lin", year: 2026, abstract: "", keywords: ["cs.LG"],
                          fileURL: nil, artifactID: nil)
        added.sourceID = "2610.07767"
        offline.papers.append(added)
        XCTAssertTrue(offline.shownFeedResults.isEmpty, "\(offline.shownFeedResults.map(\.sourceID))")
    }

    /// Sign-out erases the kept pages once the account's writer has drained; the account's other encrypted files stay
    /// (ordinary sign-out). Deleting the account removes its folder, and the pages with it.
    func testSignOutAndAccountDeletionEraseTheKeptPages() async throws {
        defer { FeedPersonalization().save(to: .standard) }
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [BadNetworkProtocol.self]
        BadNetworkProtocol.mode = .offline
        let session = try ReaderCrypto.encode(AuthSession(access_token: "fixture-access", refresh_token: "fixture-refresh",
            expires_at: Date().timeIntervalSince1970 + 3_600, user: .init(id: UUID(), email: nil)))
        let client = try BackendClient(configuration: .init(url: URL(string: "https://feed-kept.invalid")!, anonKey: "fixture", environment: "feed-kept"),
                                       network: URLSession(configuration: settings), credentials: StoredSession(session))
        let model = try await launch(reset: true, client: client) { _ in try self.feedResponse(["2610.07767"]) }
        model.loadFeed()
        try await waitUntil("For you") { model.feedResults.count == 1 }
        await model.localPersistence.waitForAcceptedWrites()
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("workflow-draft-fixture", isDirectory: true)
        let file = folder.appendingPathComponent(FeedPageStore.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "kept beside the account's encrypted store")
        await model.signOut()
        XCTAssertTrue(model.feedResults.isEmpty); XCTAssertNil(model.feedOfflineNote)
        await model.waitForLocalRetirement()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "erased on sign-out")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("state.sqlite").path), "the rest of the account's folder stays")

        let environment = "feed-kept-\(UUID().wire)", account = UUID()
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let accountFolder = base.appendingPathComponent("\(environment)/\(account.wire)", isDirectory: true)
        try FileManager.default.createDirectory(at: accountFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base.appendingPathComponent(environment)) }
        try await FeedPageStore(directory: accountFolder, accountID: account, localKey: ReaderCrypto.randomKey())
            .save(["for_you": FeedKeptPage(view: "for_you", fetchedAt: Date(), openedAt: Date(), results: try feedResponse(["2610.07767"]).results)])
        ReaderModel.eraseLocalAccountData(environment: environment, accountID: account)
        XCTAssertFalse(FileManager.default.fileExists(atPath: accountFolder.appendingPathComponent(FeedPageStore.fileName).path))
    }
    #endif
}
