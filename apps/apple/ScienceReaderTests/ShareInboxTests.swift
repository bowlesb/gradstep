import Foundation
import XCTest
@testable import ScienceReader

/// The Share extension's inbox (docs/architecture/PDF_UPLOADS.md): whole items only, PDFs and web links
/// only, bounded, and old or broken items cleared.
final class ShareInboxTests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("share-inbox-\(UUID().uuidString)", isDirectory: true) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func file(_ contents: String, name: String = "paper.pdf") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testSharedPDFsAndLinksAreSavedWholeAndReadOldestFirst() throws {
        let inbox = ShareInbox(root: root)
        let pdf = try inbox.addPDF(from: try file("%PDF-1.7 tiny"), title: "Workshop draft")
        let link = try inbox.addLink(URL(string: "https://openreview.net/forum?id=X")!, title: "A page")
        XCTAssertEqual(inbox.pending().map(\.id), [pdf.id, link.id])
        XCTAssertEqual(try String(contentsOf: inbox.pdf(pdf), encoding: .utf8), "%PDF-1.7 tiny", "a copy, byte for byte")
        XCTAssertEqual(inbox.pending().last?.url, "https://openreview.net/forum?id=X")
        inbox.remove(pdf)
        XCTAssertEqual(inbox.pending().map(\.id), [link.id])
    }

    func testOnlyPDFsAndWebLinksWithinLimits() throws {
        let inbox = ShareInbox(root: root)
        XCTAssertThrowsError(try inbox.addPDF(from: try file("hello"), title: nil)) { XCTAssertEqual($0 as? ShareInboxError, .notPDF) }
        XCTAssertThrowsError(try inbox.addPDF(from: try file(""), title: nil)) { XCTAssertEqual($0 as? ShareInboxError, .tooLarge) }
        XCTAssertThrowsError(try inbox.addLink(URL(string: "file:///etc/passwd")!, title: nil)) { XCTAssertEqual($0 as? ShareInboxError, .unsupported) }
        XCTAssertThrowsError(try inbox.addLink(URL(string: "javascript:alert(1)")!, title: nil)) { XCTAssertEqual($0 as? ShareInboxError, .unsupported) }
        for n in 0..<ShareInbox.maximumItems { _ = try inbox.addLink(URL(string: "https://example.org/\(n)")!, title: nil) }
        XCTAssertThrowsError(try inbox.addLink(URL(string: "https://example.org/more")!, title: nil)) { XCTAssertEqual($0 as? ShareInboxError, .full) }
    }

    func testBrokenStaleAndHalfWrittenItemsAreCleared() throws {
        let inbox = ShareInbox(root: root)
        let pdf = try inbox.addPDF(from: try file("%PDF-1.4"), title: nil)
        let old = try inbox.addLink(URL(string: "https://example.org/old")!, title: nil)
        // A PDF item whose file vanished, and a staging folder from a crashed extension.
        try FileManager.default.removeItem(at: inbox.pdf(pdf))
        let staging = root.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        XCTAssertEqual(inbox.pending().map(\.id), [old.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path), "a recent staging folder may still be in use")
        XCTAssertEqual(inbox.pending(now: Date().addingTimeInterval(15 * 86_400)).count, 0, "two weeks later the share is dropped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }
}
