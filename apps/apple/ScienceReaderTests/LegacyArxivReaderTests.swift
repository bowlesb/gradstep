import XCTest
import ScienceReaderCore
@testable import ScienceReader

/// Owner report 2026-10-14: papers that were in the library before the HTML-first reader "don't work". A legacy
/// arXiv item (a server-processed bundle, no source membership) now opens through the same on-device HTML reader as
/// any other arXiv paper, and the library says so.
@MainActor
final class LegacyArxivReaderTests: XCTestCase {
    private func paper(sourceID: String?, revision: Int?, membership: SourcePaperReference? = nil, artifact: UUID? = UUID()) -> Paper {
        var paper = Paper(id: UUID(), title: "T", authors: "A", year: 2024, abstract: "", keywords: [], fileURL: nil, artifactID: artifact)
        paper.sourceID = sourceID; paper.sourceRevision = revision; paper.sourceMembership = membership
        return paper
    }

    func testALegacyArxivItemReadsFromItsExactOfficialHTML() throws {
        let legacy = paper(sourceID: "2305.18290", revision: 3)
        let source = try XCTUnwrap(legacy.legacyArxivSource)
        XCTAssertEqual(source.sourceID, "2305.18290"); XCTAssertEqual(source.revision, 3)
        XCTAssertEqual(legacy.arxivReaderSource, source)
        XCTAssertEqual(source.htmlURL.absoluteString, "https://arxiv.org/html/2305.18290v3")
    }

    func testOnlyArxivItemsWithARevisionQualify() throws {
        XCTAssertNil(paper(sourceID: "openalex:W2488247662", revision: 1).legacyArxivSource, "a web paper has no arXiv HTML")
        XCTAssertNil(paper(sourceID: "upload:abc", revision: 1).legacyArxivSource)
        XCTAssertNil(paper(sourceID: "2305.18290", revision: nil).legacyArxivSource, "no revision, no exact source")
        XCTAssertNil(paper(sourceID: nil, revision: 3).legacyArxivSource)
        var local = paper(sourceID: "2305.18290", revision: 3); local.isLocalPDF = true
        XCTAssertNil(local.legacyArxivSource, "a PDF on this device is read as a PDF")
        var sample = paper(sourceID: "2305.18290", revision: 3); sample.isSample = true
        XCTAssertNil(sample.legacyArxivSource)
    }

    func testAMembershipKeepsItsOwnSourceAndIsNotLegacy() throws {
        let reference = try SourcePaperReference(membershipID: UUID(), sourceID: "2305.18290", revision: 3)
        let member = paper(sourceID: "2305.18290", revision: 3, membership: reference, artifact: nil)
        XCTAssertNil(member.legacyArxivSource)
        XCTAssertEqual(member.arxivReaderSource, try reference.arxivSource)
    }

    func testTheLibrarySaysAnArxivPaperOpensFromArxivUntilItIsOnThisDevice() throws {
        let model = ReaderModel(configuration: nil)
        let legacy = paper(sourceID: "2305.18290", revision: 3)
        XCTAssertEqual(model.libraryStatus(for: .paper(legacy)), .info("Opens from arXiv"))
        var unconverted = legacy; unconverted.canReadStructured = false
        XCTAssertEqual(model.libraryStatus(for: .paper(unconverted)), .info("Opens from arXiv"), "no server bundle is needed for an arXiv paper")
        var web = paper(sourceID: "openalex:W1", revision: 1); web.canReadStructured = false
        XCTAssertEqual(model.libraryStatus(for: .paper(web)), .problem("Reader unavailable"))
        XCTAssertEqual(model.libraryStatus(for: .paper(paper(sourceID: "openalex:W1", revision: 1))), .info("Not downloaded"))
        XCTAssertEqual(model.offlineStatus(for: legacy), .none)
    }
}
