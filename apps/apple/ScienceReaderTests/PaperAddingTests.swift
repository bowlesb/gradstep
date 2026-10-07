import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// Add by any identifier or link (docs/architecture/PDF_UPLOADS.md): what the reader typed, and the
/// server's outcome in the reader's words with the next step.
final class PaperAddingTests: XCTestCase {
    private func result(_ json: String) throws -> AddPaperResult {
        try JSONDecoder().decode(AddPaperResult.self, from: Data(json.utf8))
    }

    func testInputKinds() throws {
        XCTAssertEqual(AddInput("  "), .empty)
        XCTAssertEqual(AddInput("2305.18290v2"), .arxiv(try ArxivReference("2305.18290v2")))
        XCTAssertEqual(AddInput("https://arxiv.org/abs/1706.03762"), .arxiv(try ArxivReference("1706.03762")))
        XCTAssertEqual(AddInput("10.1145/3292500.3330701"), .lookup("10.1145/3292500.3330701"))
        XCTAssertEqual(AddInput(" https://openreview.net/pdf?id=HPuSIXJaa9\n"), .lookup("https://openreview.net/pdf?id=HPuSIXJaa9"))
        guard case .lookup(let long) = AddInput(String(repeating: "a", count: 3_000)) else { return XCTFail() }
        XCTAssertEqual(long.count, 2_000)
    }

    func testOutcomesNameTheNextStep() throws {
        let added = AddOutcome.from(try result(#"{"status":"added","route":"doi","paper":{"title":"Attention Is All You Need","year":2017,"source_id":"1706.03762","kind":"arxiv","host":null,"link":null},"link":null,"reason":null,"title":null}"#))
        XCTAssertTrue(added.finished)
        XCTAssertEqual(added.message, "Added “Attention Is All You Need”. It’s being prepared to read.")

        let closed = AddOutcome.from(try result(#"{"status":"closed","route":"doi","paper":{"title":"Optuna","year":2019,"source_id":"openalex:W2963403868","kind":"web","host":null,"link":"https://doi.org/10.1145/3292500.3330701"},"link":"https://doi.org/10.1145/3292500.3330701","reason":null,"title":null}"#))
        XCTAssertEqual(closed.kind, .closed)
        XCTAssertTrue(closed.message.hasPrefix("“Optuna” isn’t openly available."))
        XCTAssertEqual(closed.steps, [.uploadPDF(target: .source("openalex:W2963403868"), title: "Optuna"),
                                      .downloadOnDevice(link: URL(string: "https://doi.org/10.1145/3292500.3330701")!, target: .source("openalex:W2963403868"), title: "Optuna")])

        // A closed paper OpenAlex doesn't know uploads as a paper of its own.
        let unknown = AddOutcome.from(try result(#"{"status":"closed","route":"doi","paper":{"title":"A Workshop Paper","year":2024,"source_id":"doi:10.5555/w.1","kind":"arxiv","host":null,"link":"https://doi.org/10.5555/w.1"},"link":"https://doi.org/10.5555/w.1","reason":null,"title":null}"#))
        XCTAssertEqual(unknown.steps.first, .uploadPDF(target: .newPaper, title: "A Workshop Paper"))

        let blocked = AddOutcome.from(try result(#"{"status":"blocked","route":"link","paper":null,"link":"https://openreview.net/pdf?id=X","reason":"source_blocked","title":null}"#))
        XCTAssertEqual(blocked.kind, .blocked)
        XCTAssertEqual(blocked.message, "The paper’s website blocked the download from our servers. Your device may still be able to download it.")
        XCTAssertEqual(blocked.steps.first, .downloadOnDevice(link: URL(string: "https://openreview.net/pdf?id=X")!, target: .newPaper, title: nil))
        let restricted = AddOutcome.from(try result(#"{"status":"blocked","route":"link","paper":null,"link":"https://publisher.example.com/a","reason":"pdf_restricted","title":null}"#))
        XCTAssertTrue(restricted.message.contains("sign-in or subscription"))

        let linkOnly = AddOutcome.from(try result(#"{"status":"link_only","route":"page","paper":null,"link":"https://files.example.org/d.pdf","reason":null,"title":"A Draft"}"#))
        XCTAssertEqual(linkOnly.steps, [.downloadOnDevice(link: URL(string: "https://files.example.org/d.pdf")!, target: .newPaper, title: "A Draft"),
                                        .uploadPDF(target: .newPaper, title: "A Draft")])

        // A link that isn't https is never offered for a device download.
        let insecure = AddOutcome.from(try result(#"{"status":"link_only","route":"page","paper":null,"link":"http://files.example.org/d.pdf","reason":null,"title":null}"#))
        XCTAssertEqual(insecure.steps, [.uploadPDF(target: .newPaper, title: nil)])

        XCTAssertEqual(AddOutcome.from(try result(#"{"status":"not_found","route":"none","paper":null,"link":null,"reason":null,"title":null}"#)).kind, .notFound)
        XCTAssertEqual(AddOutcome.from(try result(#"{"status":"invalid","route":"none","paper":null,"link":null,"reason":null,"title":null}"#)), .invalidInput)
        XCTAssertEqual(AddOutcome.from(try result(#"{"status":"failed","route":"doi","paper":null,"link":null,"reason":null,"title":null}"#)).kind, .unavailable)
        XCTAssertEqual(AddOutcome.from(try result(#"{"status":"something_new","route":null,"paper":null,"link":null,"reason":null,"title":null}"#)).kind, .unavailable)
    }
}
