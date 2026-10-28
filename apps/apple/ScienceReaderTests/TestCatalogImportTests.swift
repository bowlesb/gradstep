import CryptoKit
import XCTest
@testable import ScienceReader

/// The staff test catalog inside the app (docs/architecture/TEST_CATALOGS.md): what a chosen folder contributes, and
/// that a reader without an operator role never gets the action.
@MainActor
final class TestCatalogImportTests: XCTestCase {
    func testAFolderContributesItsOwnPDFsWithTheirContentHashes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("test-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let a = Data("%PDF-1.4 a".utf8), b = Data("%PDF-1.7 b".utf8)
        try a.write(to: folder.appendingPathComponent("Alpha 2001 - A paper.pdf"))
        try b.write(to: folder.appendingPathComponent("beta.PDF"))
        try Data("notes".utf8).write(to: folder.appendingPathComponent("selection.json"))
        try a.write(to: folder.appendingPathComponent(".hidden.pdf"))
        try b.write(to: folder.appendingPathComponent("nested/inner.pdf"))

        let files = ReaderModel.testCatalogFiles(in: folder).sorted { $0.name < $1.name }
        let hex = { (data: Data) in SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(files.map(\.name), ["Alpha 2001 - A paper.pdf", "beta.PDF"], "only the folder's own, visible PDFs")
        XCTAssertEqual(files.map(\.sha256), [hex(a), hex(b)])
        XCTAssertTrue(ReaderModel.testCatalogFiles(in: folder.appendingPathComponent("missing")).isEmpty)
    }

    func testAReaderWithoutAnOperatorRoleNeverGetsTheAction() {
        let model = ReaderModel(configuration: nil)
        XCTAssertFalse(model.showsTestCatalogTools)
        model.beginTestCatalogImport()
        XCTAssertFalse(model.testCatalogPicking)
        XCTAssertNil(model.testCatalog)
    }
}
