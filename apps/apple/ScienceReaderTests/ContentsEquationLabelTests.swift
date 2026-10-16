import XCTest
import ScienceReaderCore
@testable import ScienceReader

/// Contents › Equations rows (owner, build 62: "remove the equation text… Equation 1, Equation 2").
final class ContentsEquationLabelTests: XCTestCase {
    func testAnEquationIsNamedByItsNumberElseItsSection() {
        XCTAssertEqual(PaperContentsSheet.label(number: "(4)", section: "3 Method"), "Equation (4)")
        XCTAssertEqual(PaperContentsSheet.label(number: nil, section: "3.2 Method"), "Equation · 3.2 Method")
        XCTAssertEqual(PaperContentsSheet.label(number: nil, section: nil), "Equation")
    }

    func testABlocksSectionIsTheLastHeadingBeforeIt() throws {
        let json = """
        {"format":"reader-index-v1","title":"T","headings":[{"id":"h1","level":2,"title":"1 Intro"},{"id":"h2","level":2,"title":"2 Method"}],
         "blocks":[{"id":"p0","kind":"paragraph","text":"a"},{"id":"h1","kind":"heading","text":"1 Intro"},{"id":"e1","kind":"equation","text":"x"},
                   {"id":"h2","kind":"heading","text":"2 Method"},{"id":"e2","kind":"equation","text":"y"}],
         "equations":[],"figures":[]}
        """
        let index = try JSONDecoder().decode(ReaderBundleIndex.self, from: Data(json.utf8))
        let sections = PaperContentsSheet.sections(of: index)
        XCTAssertNil(sections["p0"], "before any heading")
        XCTAssertEqual(sections["e1"], "1 Intro")
        XCTAssertEqual(sections["e2"], "2 Method")
    }
}
