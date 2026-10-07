import Foundation
import ScienceReaderCore
import UIKit
import XCTest
@testable import ScienceReader

/// PDF uploads on this device (docs/architecture/PDF_UPLOADS.md): the server's checks applied before
/// sending, and the durable queue's begin → send → finalize with retries, expiry and replays.
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

    func testFileCheckMatchesTheServer() throws {
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
        let lock = NSLock()
        var begins: [(UUID, PDFUploadTarget)] = []
        var sends = 0, finalizes: [(UUID, Int64)] = []
        var beginResults: [Result<String, Error>] = []      // ticket state to return, or an error
        var sendErrors: [Error] = []
        var finalizeErrors: [Error] = []
        func addPaper(_ query: String) async throws -> AddPaperResult { throw BackendError.unavailable }
        func beginUpload(_ job: PDFUploadJob) async throws -> PDFUploadTicket {
            let next: Result<String, Error> = lock.withLock { begins.append((job.uploadID, job.target)); return beginResults.isEmpty ? .success("pending") : beginResults.removeFirst() }
            let state = try next.get()
            return PDFUploadTicket(upload_id: job.uploadID, state: state, path: "a/\(job.uploadID.uuidString.lowercased()).pdf", token: state == "pending" ? "t" : nil)
        }
        func sendUpload(file: URL, path: String, token: String, progress: @escaping @Sendable (Double) -> Void) async throws {
            let error: Error? = lock.withLock { sends += 1; return sendErrors.isEmpty ? nil : sendErrors.removeFirst() }
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            if let error { throw error }
            progress(1)
        }
        func finalizeUpload(_ uploadID: UUID, observedCursor: Int64) async throws {
            let error: Error? = lock.withLock { finalizes.append((uploadID, observedCursor)); return finalizeErrors.isEmpty ? nil : finalizeErrors.removeFirst() }
            if let error { throw error }
        }
        func importSources(_ importID: UUID) async throws -> PDFImportSources { throw BackendError.unavailable }
    }

    private var clock = Date(timeIntervalSince1970: 1_791_201_600)
    private func center(_ store: PDFUploadStore) -> PDFUploadCenter {
        PDFUploadCenter(store: store, now: { [unowned self] in self.clock }, sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
    }
    private func context(_ service: FakeService, account: UUID, cursor: Int64? = 9, added: @escaping @MainActor () -> Void = {}) -> PDFUploadCenter.Context {
        .init(service: service, accountID: account, deploymentID: "https://fixture.invalid", cursor: { cursor }, added: added)
    }
    private func settle(_ center: PDFUploadCenter, until done: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testAnUploadIsSentFinalizedAndForgotten() async throws {
        let store = PDFUploadStore(root: directory.appendingPathComponent("store")), service = FakeService(), account = UUID()
        let queue = center(store); var added = 0
        queue.activate(context(service, account: account, added: { added += 1 }))
        let job = try await queue.add(file: try makePDF(title: "A paper"), target: .newPaper)
        await settle(queue) { queue.jobs.isEmpty }
        XCTAssertEqual(service.begins.map(\.0), [job.uploadID])
        XCTAssertEqual(service.sends, 1)
        XCTAssertEqual(service.finalizes.map(\.0), [job.uploadID]); XCTAssertEqual(service.finalizes.first?.1, 9)
        XCTAssertEqual(added, 1)
        XCTAssertEqual(queue.notice, "Added “A paper”. It’s being prepared to read.")
        XCTAssertTrue(store.load(deployment: "https://fixture.invalid", account: account).isEmpty, "the local copy is deleted once the server has it")
    }

    func testFailuresWaitRetryOrStopAsTheServerSays() async throws {
        let store = PDFUploadStore(root: directory.appendingPathComponent("store")), service = FakeService(), account = UUID()
        let queue = center(store)
        queue.activate(context(service, account: account))
        // A dropped connection while sending: waits (5 s back-off), keeps the same upload ID.
        service.sendErrors = [BackendError.transport]
        let job = try await queue.add(file: try makePDF(), target: .importID(UUID(), revision: 2))
        await settle(queue) { queue.jobs.first?.phase == .waiting && queue.jobs.first?.attempts == 1 }
        XCTAssertEqual(queue.jobs.first?.issue, "Waiting for a connection")
        XCTAssertEqual(queue.jobs.first?.nextAttemptAt, clock.addingTimeInterval(5))
        clock = clock.addingTimeInterval(6); queue.resume()
        await settle(queue) { queue.jobs.isEmpty }
        XCTAssertEqual(Set(service.begins.map(\.0)), [job.uploadID], "retried under the same upload ID")
        if case .importID = service.begins.first?.1 {} else { XCTFail("target kept") }

        // A full private quota stops the upload with what to do; Try again starts it afresh.
        service.beginResults = [.failure(BackendError.rejected("upload_quota"))]
        let full = try await queue.add(file: try makePDF(name: "b.pdf"), target: .newPaper)
        await settle(queue) { queue.jobs.first?.phase == .failed }
        XCTAssertEqual(queue.jobs.first?.issueCode, "upload_quota")
        XCTAssertTrue(queue.jobs.first?.issue?.contains("private storage is full") == true)
        queue.retry(full.id)
        await settle(queue) { queue.jobs.isEmpty }

        // An expired session starts again under a new upload ID; a finalized one only finalizes (a replay).
        service.beginResults = [.failure(BackendError.rejected("upload_expired")), .success("finalized")]
        let expired = try await queue.add(file: try makePDF(name: "c.pdf"), target: .newPaper)
        await settle(queue) { queue.jobs.isEmpty }
        let ids = service.begins.suffix(2).map(\.0)
        XCTAssertEqual(ids.first, expired.uploadID); XCTAssertNotEqual(ids.last, expired.uploadID)
        XCTAssertEqual(service.finalizes.last?.0, ids.last)
    }

    func testFinalizeWaitsForTheLibraryAndKeepsItsCursor() async throws {
        let store = PDFUploadStore(root: directory.appendingPathComponent("store")), service = FakeService(), account = UUID()
        var cursor: Int64? = nil
        let queue = center(store)
        queue.activate(.init(service: service, accountID: account, deploymentID: "https://fixture.invalid", cursor: { cursor }, added: {}))
        _ = try await queue.add(file: try makePDF(), target: .newPaper)
        await settle(queue) { queue.jobs.first?.issue == "Waiting for your library" }
        XCTAssertTrue(service.finalizes.isEmpty)
        // A lost finalize answer is retried with the cursor first sent.
        cursor = 4; service.finalizeErrors = [BackendError.transport]
        clock = clock.addingTimeInterval(10); queue.resume()
        await settle(queue) { queue.jobs.first?.attempts == 2 }
        cursor = 8; clock = clock.addingTimeInterval(60); queue.resume()
        await settle(queue) { queue.jobs.isEmpty }
        XCTAssertEqual(service.finalizes.map(\.1), [4, 4])
    }

    func testUnsentUploadsSurviveARelaunchAndStayWithTheirAccount() async throws {
        let store = PDFUploadStore(root: directory.appendingPathComponent("store")), service = FakeService()
        let first = UUID(), second = UUID()
        service.sendErrors = [BackendError.transport]
        let queue = center(store)
        queue.activate(context(service, account: first))
        let job = try await queue.add(file: try makePDF(), target: .newPaper)
        await settle(queue) { queue.jobs.first?.phase == .waiting && queue.jobs.first?.attempts == 1 }
        // Sign-out: nothing is sent under the next account.
        queue.deactivate()
        queue.activate(context(service, account: second))
        XCTAssertTrue(queue.jobs.isEmpty)
        // A new launch for the first account resumes its upload.
        let relaunched = center(store)
        relaunched.activate(context(service, account: first))
        XCTAssertEqual(relaunched.jobs.map(\.id), [job.id])
        await settle(relaunched) { relaunched.jobs.isEmpty }
        XCTAssertEqual(service.finalizes.map(\.0), [job.uploadID])
    }
}
