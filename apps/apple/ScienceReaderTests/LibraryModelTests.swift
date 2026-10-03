import Foundation
import ScienceReaderCore
import SwiftUI
import XCTest
@testable import ScienceReader

private final class LibraryModelServer: @unchecked Sendable {
    let account = UUID(), itemID = UUID(), documentID = UUID(), importID = UUID()
    let artifactID = UUID(), metadataID = UUID(), versionID = UUID(), approvalID = UUID(), objectID = UUID()
    private let lock = NSLock()
    private var next: (Data, Int)?
    private var failBaseline = false
    func failInitial() { lock.withLock { failBaseline = true } }
    func deliver(_ data: Data, status: Int = 200) { lock.withLock { next = (data, status) } }
    func handle(_ request: StubProtocol) {
        lock.withLock {
            switch request.request.url!.lastPathComponent {
            case "v2_library_page":
                if failBaseline { failBaseline = false; request.respond(Data("{}".utf8), status: 503) }
                else { request.respond(baseline()) }
            case "v2_library_changes":
                let response = next ?? (changes([], through: 2), 200); next = nil
                request.respond(response.0, status: response.1)
            case "v1_key_state": request.respond(Data("null".utf8))
            case "logout": request.respond(Data("{}".utf8))
            default: request.respond(Data("[]".utf8))
            }
        }
    }
    private func bytes(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    private var metadata: [String: Any] {
        ["title": "A paper about equation handling", "authors": ["Ada Researcher"], "abstract": "A bounded test of library transitions.",
         "published_at": "2024-04-03", "updated_at": "2024-05-02", "categories": ["cs.LG", "stat.ML"], "venue": NSNull()]
    }
    func item(state: Int = 1, visible: Bool = true, available: Bool = true) -> [String: Any] {
        ["kind": "item", "id": itemID.wire, "document_id": documentID.wire, "created_seq": 1, "state_seq": state,
         "membership_revision": visible ? 1 : 2, "visible": visible, "added_at": "2026-10-03T10:00:00Z", "last_remove_seq": visible ? 0 : state,
         "approval_id": approvalID.wire, "version_id": versionID.wire, "metadata_id": metadataID.wire, "source": "arxiv",
         "source_id": "2404.00001", "source_revision": 1, "metadata": metadata, "metadata_recorded_at": "2026-10-03T10:00:00Z",
         "source_url": "https://arxiv.org/abs/2404.00001v1", "scope": "shared_catalog", "page_count": 10,
         "original_object_id": objectID.wire, "artifact_id": artifactID.wire, "readiness": available ? "converted_ready" : "unavailable",
         "original_availability": "available", "render_availability": available ? "available" : "quarantined",
         "original_availability_revision": 1, "render_availability_revision": available ? 1 : 2]
    }
    func pending(state: Int = 2, resolved: Bool = false, sourceOnly: Bool = false) -> [String: Any] {
        let pinned = resolved || sourceOnly
        return ["kind": "import", "id": importID.wire, "created_seq": 2, "state_seq": state, "intent_revision": 1,
                "visible": !resolved, "phase": resolved ? "ready" : (sourceOnly ? "source_only" : "accepted"),
                "source": "arxiv", "source_id": "2404.00001", "requested_revision": NSNull(),
                "source_revision": pinned ? (1 as Any) : NSNull(), "metadata_id": pinned ? (metadataID.wire as Any) : NSNull(),
                "version_id": pinned ? (versionID.wire as Any) : NSNull(), "metadata": pinned ? (metadata as Any) : NSNull(),
                "metadata_recorded_at": pinned ? ("2026-10-03T10:00:00Z" as Any) : NSNull(),
                "source_url": pinned ? "https://arxiv.org/abs/2404.00001v1" : "https://arxiv.org/abs/2404.00001",
                "document_id": resolved ? (documentID.wire as Any) : NSNull(), "library_item_id": resolved ? (itemID.wire as Any) : NSNull(),
                "error_code": sourceOnly ? ("license_unverified" as Any) : NSNull(), "retryable": false]
    }
    func baseline() -> Data {
        bytes(["format": 2, "account_id": account.wire, "baseline_cursor": 2, "retained_after": 0,
               "entries": [item(), pending()], "has_more": false,
               "next_cursor": ["format": 2, "account_id": account.wire, "through": 2, "created_seq": 2, "id": importID.wire, "kind": "import"]])
    }
    func changes(_ rows: [[String: Any]], through: Int) -> Data {
        bytes(["format": 2, "account_id": account.wire, "through": through, "retained_after": 0,
               "changes": rows.isEmpty ? [] : [["seq": through, "entries": rows]], "next_cursor": through, "has_more": false])
    }
}

@MainActor
final class LibraryModelTests: XCTestCase {
    func testPendingAndSourceOnlyPresentation() async throws {
        let server = LibraryModelServer(), fixture = try Fixture(server)
        defer { fixture.close() }
        let model = fixture.model
        await model.start()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIHostingController(rootView: LibraryView(model: model))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await capture(window, name: "Pending import beside saved paper")
        server.deliver(server.changes([server.pending(state: 3, sourceOnly: true)], through: 3))
        await model.refreshLibrary()
        XCTAssertNil(model.libraryIssue)
        try await capture(window, name: "Source-only result beside saved paper")
    }

    private func capture(_ window: UIWindow, name: String) async throws {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testImportResolutionFailureAvailabilityAndRemovalPreserveTheRightState() async throws {
        let server = LibraryModelServer(), fixture = try Fixture(server)
        defer { fixture.close() }
        let model = fixture.model
        await model.start()
        XCTAssertTrue(model.libraryHasSnapshot)
        XCTAssertNil(model.libraryIssue)
        XCTAssertEqual(model.papers.map(\.id), [server.documentID], "Paper uses document identity, never membership/import identity")
        XCTAssertEqual(model.libraryImports.map(\.id), [server.importID])
        XCTAssertEqual(model.libraryRows.count, 2)
        XCTAssertEqual(model.papers.first?.keywords, ["cs.LG", "stat.ML"])
        XCTAssertEqual(model.papers.first?.year, 2024)
        XCTAssertEqual(model.papers.first?.sourceReference, "2404.00001v1")
        model.libraryQuery = "stat.ml"
        XCTAssertEqual(model.libraryRows.count, 1, "Public source categories participate in native search")
        model.libraryQuery = ""
        model.openSample()
        let sample = try XCTUnwrap(model.selectedPaper)
        let original = try XCTUnwrap(model.papers.first { $0.id == server.documentID })
        let cached = Paper(id: original.id, title: original.title, authors: original.authors, year: original.year,
                           abstract: original.abstract, keywords: original.keywords,
                           fileURL: URL(fileURLWithPath: "/synthetic-cache/paper.html"), artifactID: original.artifactID,
                           sourceID: original.sourceID, sourceRevision: original.sourceRevision)
        model.papers = [cached, sample]; model.select(cached)
        model.generalChat = false; model.chatInput = "Keep this private draft"
        server.deliver(Data("{}".utf8), status: 503)
        await model.refreshLibrary()
        XCTAssertNotNil(model.libraryIssue)
        XCTAssertEqual(model.libraryImports.count, 1)
        XCTAssertEqual(model.selectedPaper?.fileURL, cached.fileURL, "Failed refresh preserves the last complete presentation")

        model.libraryQuery = "2404.00001"
        XCTAssertEqual(model.libraryRows.count, 2)
        server.deliver(server.changes([server.item(), server.pending(state: 3, resolved: true)], through: 3))
        await model.refreshLibrary()
        XCTAssertNil(model.libraryIssue)
        XCTAssertTrue(model.libraryImports.isEmpty)
        XCTAssertEqual(model.papers.filter { !$0.isSample }.map(\.id), [server.documentID], "Alias resolution produces no duplicate paper")
        XCTAssertTrue(model.papers.contains { $0.isSample })
        XCTAssertEqual(model.selectedPaper?.fileURL, cached.fileURL)
        XCTAssertEqual(model.chatInput, "Keep this private draft")
        XCTAssertEqual(model.libraryRows.count, 1, "The same source-ID search survives import resolution")
        model.libraryQuery = "2404.00001v1"
        XCTAssertEqual(model.libraryRows.count, 1, "An exact-version source reference is searchable")
        model.libraryQuery = ""

        model.headings = [.init(id: "paper-section", title: "Paper section")]
        server.deliver(server.changes([server.item(state: 4, available: false)], through: 4))
        await model.refreshLibrary()
        XCTAssertNil(model.libraryIssue)
        XCTAssertEqual(model.selectedPaper?.artifactID, server.artifactID, "Availability does not repin the artifact")
        XCTAssertNil(model.selectedPaper?.fileURL, "A quarantined artifact cannot stay active through its old cached URL")
        XCTAssertTrue(model.headings.isEmpty)
        XCTAssertEqual(model.chatInput, "Keep this private draft")

        server.deliver(server.changes([server.item(state: 5, visible: false, available: false)], through: 5))
        await model.refreshLibrary()
        XCTAssertNil(model.libraryIssue)
        XCTAssertNil(model.selectedPaper)
        XCTAssertEqual(model.tab, .library)
        XCTAssertEqual(model.chatPaperID, server.documentID, "Removing a library row must not silently rebind the private chat")
        XCTAssertEqual(model.chatInput, "Keep this private draft")
        XCTAssertEqual(model.papers.map(\.id), [sample.id])
    }

    func testInitialFailureCanRetryAndSourceOnlyStaysSeparateFromDocuments() async throws {
        let server = LibraryModelServer(); server.failInitial()
        let fixture = try Fixture(server)
        defer { fixture.close() }
        let model = fixture.model
        await model.start()
        XCTAssertFalse(model.libraryHasSnapshot); XCTAssertNotNil(model.libraryIssue)
        XCTAssertFalse(model.libraryRefreshing); XCTAssertTrue(model.papers.isEmpty)
        server.deliver(server.changes([server.pending(state: 3, sourceOnly: true)], through: 3))
        await model.refreshLibrary()
        XCTAssertTrue(model.libraryHasSnapshot); XCTAssertNil(model.libraryIssue)
        XCTAssertEqual(model.libraryImports.first?.phase, .sourceOnly)
        XCTAssertNil(model.libraryImports.first?.documentID)
        model.libraryQuery = "Ada"
        XCTAssertEqual(model.libraryRows.count, 2, "Source-only metadata stays searchable beside the actual saved document")
        model.librarySort = "Title"
        XCTAssertEqual(Set(model.libraryRows.map(\.id)).count, 2, "Identical titles cannot collide across paper/import identities")
    }

    @MainActor private final class Fixture {
        let model: ReaderModel
        let environment: String
        let host: String
        let account: UUID
        init(_ server: LibraryModelServer) throws {
            environment = "library-model-\(UUID().wire)"
            host = environment + ".invalid"
            account = server.account
            StubProtocol.install(host: host) { server.handle($0) }
            let session = AuthSession(access_token: "fixture-library-model", refresh_token: "fixture-refresh",
                                      expires_at: Date().timeIntervalSince1970 + 3600, user: .init(id: account, email: "fixture@example.invalid"))
            try KeychainVault.write(ReaderCrypto.encode(session), name: environment + ".auth-session")
            let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = [StubProtocol.self]
            let configuration = BackendConfiguration(url: URL(string: "https://\(host)")!, anonKey: "fixture", environment: environment)
            model = ReaderModel(configuration: configuration, client: try BackendClient(configuration: configuration, network: URLSession(configuration: settings)))
        }
        func close() {
            StubProtocol.remove(host: host)
            for key in [environment + ".auth-session", "\(environment).\(account.wire).device-keys", "\(environment).\(account.wire).support-outbox-key"] {
                try? KeychainVault.delete(key)
            }
            if let root = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(environment))
            }
        }
    }
}
