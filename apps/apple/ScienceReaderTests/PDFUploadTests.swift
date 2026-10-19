import Foundation
import ScienceReaderCore
import UIKit
import PDFKit
import XCTest
@testable import ScienceReader

/// Device-only PDF admission, encrypted installation and the prohibition on legacy upload retries.
@MainActor
final class PDFUploadTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-upload-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private func makePDF(pages: Int = 2, title: String? = nil, name: String = "paper.pdf") throws -> URL {
        let format = UIGraphicsPDFRendererFormat()
        if let title { format.documentInfo = [kCGPDFContextTitle as String: title] }
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200), format: format).pdfData { context in
            for _ in 0..<pages { context.beginPage() }
        }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testDeviceChecksPDFBeforeLocalAdmission() throws {
        let url = try makePDF(pages: 3, title: "Sparse Attention, Revisited", name: "draft_v2.pdf")
        let checked = try PDFFileCheck.check(url)
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(checked.byteCount, Int64(bytes.count))
        XCTAssertEqual(checked.pages, 3)
        XCTAssertEqual(checked.title, "Sparse Attention, Revisited")
        XCTAssertEqual(checked.sha256.count, 64)
        // The filename when the PDF has no useful title; the reader's (or the server's) title first.
        XCTAssertEqual(try PDFFileCheck.check(try makePDF(title: "Microsoft Word - draft.docx", name: "sparse_attention-v2.pdf")).title, "sparse attention-v2")
        XCTAssertEqual(try PDFFileCheck.check(url, title: "  A   paper\u{7}title ").title, "A paper title")

        let text = directory.appendingPathComponent("notes.pdf"); try Data("hello, not a pdf".utf8).write(to: text)
        XCTAssertThrowsError(try PDFFileCheck.check(text)) { XCTAssertEqual($0 as? PDFFileProblem, .notPDF) }
        let empty = directory.appendingPathComponent("empty.pdf"); try Data().write(to: empty)
        XCTAssertThrowsError(try PDFFileCheck.check(empty)) { XCTAssertEqual($0 as? PDFFileProblem, .empty) }
        // A PDF header with nothing readable after it.
        let broken = directory.appendingPathComponent("broken.pdf"); try Data("%PDF-1.7\ngarbage".utf8).write(to: broken)
        XCTAssertThrowsError(try PDFFileCheck.check(broken)) { XCTAssertEqual($0 as? PDFFileProblem, .unreadable) }
        XCTAssertTrue(PDFFileProblem.tooLarge.message.contains("64 MB"))
    }

    // MARK: The queue

    private final class FakeService: PaperAddingService, @unchecked Sendable {
        func addPaper(_ query: String) async throws -> AddPaperResult { throw BackendError.unavailable }
        func importSources(_ importID: UUID) async throws -> PDFImportSources { throw BackendError.unavailable }
    }

    private var clock = Date(timeIntervalSince1970: 1_791_201_600)
    private func center(_ store: PDFUploadStore) -> PDFUploadCenter {
        PDFUploadCenter(store: store, now: { [unowned self] in self.clock })
    }
    private func context(_ service: FakeService, account: UUID, cursor: Int64? = 9, added: @escaping @MainActor () -> Void = {}) -> PDFUploadCenter.Context {
        .init(service: service, accountID: account, deploymentID: "https://fixture.invalid", cursor: { cursor }, added: added)
    }
    private func settle(_ center: PDFUploadCenter, until done: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testLocalInstallerCapturesCatalogBeforeFileCheckingSuspends() async throws {
        let center = center(PDFUploadStore(root: directory)), file = try makePDF()
        var selected = UUID(), captured: UUID?, installed: UUID?
        let original = selected, chose = expectation(description: "Catalog captured at Add")
        var ctx = context(FakeService(), account: UUID())
        ctx.captureLocalInstall = {
            let destination = selected; captured = destination; chose.fulfill()
            return { _, _, _ in installed = destination }
        }
        center.activate(ctx)
        let task = Task { try await center.add(file: file, target: .newPaper) }
        await fulfillment(of: [chose], timeout: 3)
        selected = UUID()
        _ = try await task.value
        XCTAssertEqual(captured, original); XCTAssertEqual(installed, original)
        XCTAssertNotEqual(installed, selected)
    }

    func testChosenPDFCommitsOnlyToDeviceSink() async throws {
        let disk = PDFUploadStore(root: directory.appendingPathComponent("store")), service = FakeService(), account = UUID()
        let local = try DevicePaperStore(directory: directory.appendingPathComponent("encrypted"), accountID: account, localKey: ReaderCrypto.randomKey())
        let queue = center(disk)
        var ctx = context(service, account: account)
        ctx.installLocal = { file, checked, _ in
            _ = try await local.install(pdfAt: file, sourceID: "local:fixture", revision: 1)
            XCTAssertEqual(checked.pages, 2)
        }
        queue.activate(ctx)
        _ = try await queue.add(file: makePDF(), target: .newPaper)
        XCTAssertTrue(queue.jobs.isEmpty)
        XCTAssertTrue(queue.notice?.contains("on this device") == true)
        let records = await local.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(disk.load(deployment: "https://fixture.invalid", account: account).isEmpty)
    }
    func testNoDeviceSinkCannotFallBackToUpload() async throws {
        let service = FakeService(), queue = center(PDFUploadStore(root: directory.appendingPathComponent("store")))
        queue.activate(context(service, account: UUID()))
        do { _ = try await queue.add(file: makePDF(), target: .newPaper); XCTFail("requires local sink") }
        catch BackendError.rejected(let code) { XCTAssertEqual(code, "pdf_device_only") }
    }
    func testLegacyPendingJobNeverResumesSending() async throws {
        let disk = PDFUploadStore(root: directory.appendingPathComponent("store")), service = FakeService(), account = UUID()
        let file = try makePDF(), checked = try PDFFileCheck.check(file)
        let job = PDFUploadJob(id: UUID(), uploadID: UUID(), accountID: account, createdAt: clock, title: checked.title,
            sha256: checked.sha256, byteCount: checked.byteCount, target: .newPaper)
        try disk.adopt(file, job: job, deployment: "https://fixture.invalid")
        let queue = center(disk); queue.activate(context(service, account: account))
        queue.resume(); queue.retry(job.id)
        XCTAssertEqual(queue.jobs.first?.issueCode, "pdf_device_only")
        XCTAssertEqual(queue.jobs.first?.phase, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        await settle(queue) { queue.jobs.first?.issue?.contains("couldn’t be saved") == true }
        XCTAssertEqual(queue.jobs.count, 1)
        // With this device's sink, the legacy file is saved locally and the stopped record is cleared.
        let local = try DevicePaperStore(directory: directory.appendingPathComponent("legacy-encrypted"), accountID: account, localKey: ReaderCrypto.randomKey())
        var ctx = context(service, account: account)
        ctx.installLocal = { file, _, _ in _ = try await local.install(pdfAt: file, sourceID: "local:legacy", revision: 1) }
        queue.activate(ctx)
        queue.retry(job.id)
        await settle(queue) { queue.jobs.isEmpty }
        XCTAssertTrue(queue.jobs.isEmpty)
        let saved = await local.records().count
        XCTAssertEqual(saved, 1)
        XCTAssertTrue(disk.load(deployment: "https://fixture.invalid", account: account).isEmpty)
    }

    func testLockedAndOverLimitPDFsAreRejectedLocally() throws {
        let document = try XCTUnwrap(PDFDocument(url: makePDF()))
        let locked = directory.appendingPathComponent("locked.pdf")
        XCTAssertTrue(document.write(to: locked, withOptions: [.userPasswordOption: "test-only", .ownerPasswordOption: "test-owner"]))
        XCTAssertThrowsError(try PDFFileCheck.check(locked)) { XCTAssertEqual($0 as? PDFFileProblem, .locked) }
        XCTAssertEqual(try PDFFileCheck.check(makePDF(pages: 250)).pages, 250)
        XCTAssertThrowsError(try PDFFileCheck.check(makePDF(pages: 251))) { XCTAssertEqual($0 as? PDFFileProblem, .tooManyPages) }
    }

    // Slow, opt-in downloaded corpus. Missing cache is explicit in ordinary native runs.
    func testRealPDFCorpusChecksRendersEncryptsAndReopensWithoutUploads() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        struct Input: Decodable { let bytes: Int64; let sha256: String }
        struct Paper: Decodable { let key: String; let pdf: Input }
        struct Lock: Decodable { let papers: [Paper] }
        let lock = try JSONDecoder().decode(Lock.self, from: Data(contentsOf: root.appendingPathComponent("tests/corpus/reader-lock.json")))
        let cache = root.appendingPathComponent(".artifacts/reader-corpus")
        guard lock.papers.allSatisfy({ FileManager.default.fileExists(atPath: cache.appendingPathComponent("\($0.key)/paper.pdf").path) }) else {
            throw XCTSkip("Run npm run test:slow:fetch on this device first.")
        }
        let account = UUID(), key = ReaderCrypto.randomKey(), storeURL = directory.appendingPathComponent("corpus-store")
        let local = try DevicePaperStore(directory: storeURL, accountID: account, localKey: key)
        let service = FakeService(), queue = center(PDFUploadStore(root: directory.appendingPathComponent("unused-queue")))
        var ctx = context(service, account: account)
        ctx.installLocal = { file, _, _ in _ = try await local.install(pdfAt: file, sourceID: file.deletingLastPathComponent().lastPathComponent, revision: 1) }
        queue.activate(ctx)
        for paper in lock.papers {
            let file = cache.appendingPathComponent("\(paper.key)/paper.pdf"), checked = try PDFFileCheck.check(file)
            XCTAssertEqual(checked.sha256, paper.pdf.sha256, paper.key); XCTAssertEqual(checked.byteCount, paper.pdf.bytes, paper.key)
            _ = try await queue.add(file: file, target: .newPaper)
            let records = await local.records()
            let record = try XCTUnwrap(records.first { $0.identity.sourceID == paper.key })
            let reopened = try DevicePaperStore(directory: storeURL, accountID: account, localKey: key)
            let bytes = try await reopened.read(record.identity)
            XCTAssertEqual(bytes, try Data(contentsOf: file), paper.key)
            let pdf = try XCTUnwrap(PDFDocument(data: bytes))
            XCTAssertEqual(pdf.pageCount, checked.pages, paper.key)
            for page in Set([0, checked.pages / 2, checked.pages - 1]) {
                let image = try XCTUnwrap(pdf.page(at: page)).thumbnail(of: CGSize(width: 300, height: 400), for: .mediaBox)
                XCTAssertGreaterThan(try XCTUnwrap(image.pngData()).count, 100, paper.key)
            }
            print("Local corpus PDF \(paper.key): \(checked.pages) pages, \(checked.byteCount) bytes, encrypted reopen and PDFKit render passed")
        }
        XCTAssertTrue(queue.jobs.isEmpty)
    }
}
