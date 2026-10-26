import CryptoKit
import PDFKit
import UIKit
import XCTest
import ScienceReaderCore
@testable import ScienceReader

@MainActor
final class PDFPositionTests: XCTestCase {
    private let passage = "The efficient transformer learns robust representations using sparse attention across multiple independent training examples."

    private func pdf(_ texts: [String], rotated: Bool = false) throws -> Data {
        let bytes = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            for text in texts {
                context.beginPage()
                (text as NSString).draw(in: CGRect(x: 52, y: 90, width: 230, height: 500),
                                       withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            }
        }
        guard rotated else { return bytes }
        let document = try XCTUnwrap(PDFDocument(data: bytes))
        document.page(at: 1)?.rotation = 90
        document.page(at: 1)?.setBounds(CGRect(x: 24, y: 24, width: 564, height: 744), for: .cropBox)
        return try XCTUnwrap(document.dataRepresentation())
    }

    private func identity(_ data: Data) throws -> LocalPaperIdentity {
        try LocalPaperIdentity(sourceID: "2610.12345", revision: 1, sha256: Data(SHA256.hash(data: data)))
    }

    func testWorkerFindsPDFKitTextAndViewerZoomsOutlinesThenFadesRotatedCroppedPageWithoutAnnotations() async throws {
        let bytes = try pdf(["A different introduction with no relevant passage.", passage], rotated: true)
        let worker = PDFPositionWorker()
        let match = try await worker.match(data: bytes, identity: identity(bytes), text: passage)
        XCTAssertEqual(match.status, "matched")
        XCTAssertEqual(match.ranges.first?.page, 1)
        let view = PDFPeekNativeView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        view.autoScales = true
        view.document = PDFDocument(data: bytes)
        let page = try XCTUnwrap(view.document?.page(at: 1))
        let annotationCount = page.annotations.count
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first)
        window.addSubview(view)
        defer { view.removeFromSuperview() }
        view.apply(match); view.layoutIfNeeded()
        XCTAssertTrue(view.targetPage === page)
        XCTAssertFalse(view.targetBounds.isEmpty)
        XCTAssertTrue(view.outlineVisible)
        XCTAssertGreaterThan(view.outlineOpacity, 0)
        let initialScale = view.openingScale
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertGreaterThan(view.scaleFactor, initialScale, "Opening actually zooms into the passage")
        XCTAssertGreaterThan(view.outlineOpacity, 0)
        let visible = UIGraphicsImageRenderer(size: view.bounds.size).image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        let opened = XCTAttachment(image: visible); opened.name = "Cropped rotated PDF with fading outline"; opened.lifetime = .keepAlways; add(opened)
        XCTAssertLessThan(view.outlineOpacity, 1, "The outline fades immediately, during the opening")
        XCTAssertEqual(view.currentPage.map { view.document!.index(for: $0) }, 1, "The PDF viewer actually navigates to the matching page")
        XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(view.outlineFrame), "The whole outlined area is visible")
        XCTAssertTrue(view.highlightedSelections?.isEmpty != false, "No permanent text highlighting")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(view.outlineVisible)
        XCTAssertEqual(view.outlineOpacity, 0)
        let clear = UIGraphicsImageRenderer(size: view.bounds.size).image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        let faded = XCTAttachment(image: clear); faded.name = "Cropped rotated PDF after outline fades"; faded.lifetime = .keepAlways; add(faded)
        XCTAssertEqual(page.annotations.count, annotationCount)
        let document = view.document
        view.apply(match)
        XCTAssertTrue(view.document === document, "Updating the highlight does not replace the document")
        view.scaleFactor = max(view.scaleFactor, view.minScaleFactor) * 1.2
        let zoom = view.scaleFactor
        view.frame.size = CGSize(width: 700, height: 390); view.layoutIfNeeded()
        XCTAssertEqual(view.scaleFactor, zoom, accuracy: 0.001, "Layout must not apply the initial landing again")
    }

    func testSameSourceWithDifferentPDFDigestCannotReuseAnIndex() async throws {
        let worker = PDFPositionWorker(), original = try pdf([passage])
        let first = try await worker.match(data: original, identity: identity(original), text: passage)
        XCTAssertEqual(first.status, "matched")
        let changed = try pdf(["Unrelated maritime investigations concern Atlantic shipping routes and northern coastal navigation."])
        let second = try await worker.match(data: changed, identity: identity(changed), text: passage)
        XCTAssertEqual(second.status, "unmatched")
    }

    func testImageOnlyAndAmbiguousPDFsDoNotReceiveHighlights() async throws {
        let worker = PDFPositionWorker(), empty = try pdf([""])
        let noText = try await worker.match(data: empty, identity: identity(empty), text: passage)
        XCTAssertEqual(noText.reason, "no-text")
        let duplicate = try pdf([passage, passage])
        let ambiguous = try await worker.match(data: duplicate, identity: identity(duplicate), text: passage)
        XCTAssertEqual(ambiguous.reason, "ambiguous")
        XCTAssertTrue(ambiguous.ranges.isEmpty)
    }

    func testScopeFencesPaperRevisionAndAccountChanges() async throws {
        // A nil backend makes signOut a no-op. Use the existing unauthenticated retirement fixture pattern.
        let environment = "pdf-peek-retirement-\(UUID().wire)"
        defer { try? KeychainVault.delete(environment + ".auth-session") }
        let configuration = BackendConfiguration(url: URL(string: "https://\(environment).invalid")!, anonKey: "fixture", environment: environment)
        let model = ReaderModel(configuration: configuration, client: try BackendClient(configuration: configuration))
        let paper = Paper(id: UUID(), title: "Fixture", authors: "", year: nil, abstract: "", keywords: [],
                          fileURL: nil, artifactID: nil, sourceID: "2610.12345", sourceRevision: 1)
        model.selectedPaper = paper
        let scope = try XCTUnwrap(model.readerDocumentScope)
        XCTAssertTrue(model.isCurrentPDFPeek(paper: paper, scope: scope))
        var revision = paper; revision.sourceRevision = 2; model.selectedPaper = revision
        XCTAssertFalse(model.isCurrentPDFPeek(paper: paper, scope: scope))
        model.selectedPaper = paper
        await model.signOut()
        XCTAssertFalse(model.isCurrentPDFPeek(paper: paper, scope: scope))
    }

    func testCancelledMatchDoesNotPublish() async throws {
        let worker = PDFPositionWorker(), bytes = try pdf([passage]), identity = try identity(bytes), text = passage
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.match(data: bytes, identity: identity, text: text)
        }
        do { _ = try await task.value; XCTFail("Cancelled matching must not return a prediction") }
        catch is CancellationError { }
    }

    func testInvalidRangesCannotReachPDFKitSelectionException() throws {
        let view = PDFPeekNativeView(), bytes = try pdf([passage])
        view.document = PDFDocument(data: bytes)
        let match = PDFPositionMatch(status: "matched", reason: nil, ranges: [
            .init(page: -1, location: 0, length: 3), .init(page: 0, location: Int.max, length: Int.max),
            .init(page: 0, location: 0, length: 0)
        ])
        view.apply(match)
        XCTAssertNil(view.targetPage)
        XCTAssertFalse(view.outlineVisible)
    }

    func testSnapshotRejectsWrongBundleUnknownBlockOversizeAndUnknownKind() throws {
        let bundle = try ReaderBundleLoader.sample()
        let valid: [String: Any] = ["manifest_sha256": bundle.manifestSHA256, "block_id": bundle.index.blocks[0].id,
                                   "text": passage, "kind": "visible"]
        XCTAssertNotNil(PDFReadingSnapshot(message: valid, bundle: bundle))
        for (key, value) in [("manifest_sha256", "wrong"), ("block_id", "unknown"), ("text", String(repeating: "x", count: 2001)), ("kind", "guess")] {
            var invalid = valid; invalid[key] = value
            XCTAssertNil(PDFReadingSnapshot(message: invalid, bundle: bundle))
        }
    }

    func testExactRevisionDownloadIsExplicitEncryptedAndReopensOffline() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let account = UUID(), key = ReaderCrypto.randomKey(), keys = KeyBundle.generate(accountID: account)
        func open() async throws -> ReaderModel {
            let model = ReaderModel(configuration: nil)
            _ = try await model.localPersistence.activate(url: folder.appendingPathComponent("state.sqlite"),
                accountID: account, localKey: key, keys: keys)
            model.selectedPaper = Paper(id: UUID(), title: "Local fixture", authors: "", year: nil, abstract: "", keywords: [],
                fileURL: nil, artifactID: nil, sourceID: "2610.12345", sourceRevision: 2)
            return model
        }
        let model = try await open(), paper = try XCTUnwrap(model.selectedPaper), scope = try XCTUnwrap(model.readerDocumentScope)
        let bytes = try pdf([passage])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedProtocol.self]
        let fetcher = DevicePDFFetcher(resolve: { _ in ["93.184.216.34"] }, configuration: configuration)
        ScriptedProtocol.routes = ["https://arxiv.org/pdf/2610.12345v2": .init(body: bytes, headers: ["Content-Type": "application/pdf"])]
        ScriptedProtocol.userAgents = []
        defer { ScriptedProtocol.routes = [:]; ScriptedProtocol.userAgents = [] }
        do { _ = try await model.pdfForPeek(paper: paper, scope: scope, download: false, fetcher: fetcher); XCTFail("Needs an explicit download") }
        catch PDFPeekError.missing { }
        XCTAssertTrue(ScriptedProtocol.userAgents.isEmpty)
        let downloaded = try await model.pdfForPeek(paper: paper, scope: scope, download: true, fetcher: fetcher)
        XCTAssertEqual(downloaded.0, bytes)
        XCTAssertEqual(downloaded.1.revision, 2)
        XCTAssertEqual(ScriptedProtocol.userAgents.count, 1)
        let sealed = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("device-papers"), includingPropertiesForKeys: nil)
        XCTAssertGreaterThan(sealed.count, 1)
        for file in sealed {
            let disk = try Data(contentsOf: file)
            XCTAssertNotEqual(disk, bytes)
            XCTAssertFalse(disk.starts(with: Data("%PDF-".utf8)))
        }
        ScriptedProtocol.routes = [:]; ScriptedProtocol.userAgents = []
        let reopened = try await open()
        let offline = try await reopened.pdfForPeek(paper: XCTUnwrap(reopened.selectedPaper),
            scope: XCTUnwrap(reopened.readerDocumentScope), download: false, fetcher: fetcher)
        XCTAssertEqual(offline.0, bytes)
        XCTAssertEqual(offline.1, downloaded.1)
        XCTAssertTrue(ScriptedProtocol.userAgents.isEmpty, "A fresh model reopens encrypted bytes without any HTTP request")
        let result = try await PDFPositionWorker().match(data: offline.0, identity: offline.1, text: passage)
        XCTAssertEqual(result.status, "matched")
    }

    func testDownloadRejectsAnotherRevisionWithoutSavingIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let account = UUID(), model = ReaderModel(configuration: nil)
        _ = try await model.localPersistence.activate(url: folder.appendingPathComponent("state.sqlite"), accountID: account,
            localKey: ReaderCrypto.randomKey(), keys: KeyBundle.generate(accountID: account))
        let paper = Paper(id: UUID(), title: "Fixture", authors: "", year: nil, abstract: "", keywords: [],
                          fileURL: nil, artifactID: nil, sourceID: "2610.12345", sourceRevision: 2)
        model.selectedPaper = paper
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ScriptedProtocol.self]
        let bytes = try pdf([passage])
        ScriptedProtocol.routes = [
            "https://arxiv.org/pdf/2610.12345v2": .init(status: 302, headers: ["Location": "https://arxiv.org/pdf/2610.12345v3"]),
            "https://arxiv.org/pdf/2610.12345v3": .init(body: bytes)
        ]
        defer { ScriptedProtocol.routes = [:] }
        let fetcher = DevicePDFFetcher(resolve: { _ in ["93.184.216.34"] }, configuration: configuration)
        do {
            _ = try await model.pdfForPeek(paper: paper, scope: XCTUnwrap(model.readerDocumentScope), download: true, fetcher: fetcher)
            XCTFail("A redirected revision must not be used")
        } catch PDFPeekError.wrongRevision { }
        let records = await model.localPersistence.localPaperStore?.records()
        XCTAssertEqual(records?.count, 0)
    }
}

/// Explicit, device-local replay of the already cached DPO v3 original. Not part of routine fast checks.
@MainActor
final class PDFPeekCorpusTests: XCTestCase {
    func testCachedDPOPageAndNativeTiming() async throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["PDF_PEEK_PDF"], "Pass PDF_PEEK_PDF to the Simulator runner")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let digest = Data(SHA256.hash(data: bytes))
        XCTAssertEqual(digest.map { String(format: "%02x", $0) }.joined(), "92cb3a2b71362acda98a789b03d88688fd33cf5fcf13f81d2b1de30ee7d3b67a")
        let identity = try LocalPaperIdentity(sourceID: "2305.18290", revision: 3, sha256: digest)
        let query = "At a high level, existing methods instill the desired behaviors into a language model using curated sets of human preferences"
        let worker = PDFPositionWorker(), start = ProcessInfo.processInfo.systemUptime
        let match = try await worker.match(data: bytes, identity: identity, text: query)
        let cold = (ProcessInfo.processInfo.systemUptime - start) * 1000
        XCTAssertEqual(match.status, "matched")
        XCTAssertEqual(match.ranges.first?.page, 1)
        let view = PDFPeekNativeView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        view.document = PDFDocument(data: bytes)
        view.reduceMotion = true
        view.apply(match); view.layoutIfNeeded()
        let page = try XCTUnwrap(view.document?.page(at: 1))
        XCTAssertTrue(view.targetPage === page)
        XCTAssertFalse(view.targetBounds.intersection(page.bounds(for: .cropBox)).isEmpty)
        XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(view.outlineFrame))
        XCTAssertGreaterThan(view.outlineOpacity, 0)
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertEqual(view.outlineOpacity, 0, "Reduce Motion hides the outline after a second")
        var times: [Double] = []
        for _ in 0..<100 {
            let began = ProcessInfo.processInfo.systemUptime
            let warm = try await worker.match(data: bytes, identity: identity, text: query)
            times.append((ProcessInfo.processInfo.systemUptime - began) * 1000)
            XCTAssertEqual(warm.ranges.first?.page, 1)
        }
        times.sort()
        let evidence: [String: Any] = ["environment": "iOS Simulator", "device": UIDevice.current.model,
            "pdf_sha256": digest.map { String(format: "%02x", $0) }.joined(), "pages": view.document!.pageCount,
            "cold_extraction_index_match_ms": cold, "warm_match_p50_ms": times[49], "warm_match_p95_ms": times[94], "queries": 100]
        let report = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
            uniformTypeIdentifier: "public.json")
        report.name = "PDF peek native timing"; report.lifetime = .keepAlways; add(report)
    }
}
