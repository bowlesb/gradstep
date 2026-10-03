import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct ArxivReferenceTests {
    @Test func pastedLinksAndVersionedAliasesKeepOnlyCanonicalIdentity() throws {
        for input in ["1706.03762v2", " arXiv:1706.03762v2 ", "https://arxiv.org/abs/1706.03762v2",
                      "https://arxiv.org:443/abs/1706.03762v2", "HTTP://WWW.ARXIV.ORG:80/pdf/1706.03762V2.PDF",
                      "http://export.arxiv.org/pdf/1706.03762v2.pdf?token=discard#page=3", "\u{FEFF}1706.03762v2\u{00A0}"] {
            let reference = try ArxivReference(input)
            #expect(reference.sourceID == "1706.03762")
            #expect(reference.revision == 2)
            #expect(reference.identifier == "1706.03762v2")
            #expect(reference.abstractURL.absoluteString == "https://arxiv.org/abs/1706.03762v2")
        }
        #expect(try ArxivReference("arXiv:math.CA/0611800v2") == ArxivReference(sourceID: "math/0611800", revision: 2))
        #expect(try ArxivReference("HEP-TH/9901001").identifier == "hep-th/9901001")
        #expect(try ArxivReference("0704.0001").revision == nil)
        #expect(try ArxivReference("1501.00001").identifier == "1501.00001")
        #expect(try ArxivReference("1706.03762v2147483647").revision == 2_147_483_647)
    }

    @Test func invalidSourceDatesVersionsOriginsAndEncodedPathsAreRejected() {
        let invalid = ["", "1700.03762", "1713.03762", "1706.3762", "0703.0001", "1412.00001", "1501.0001", "1706.00000",
            "hep-th/0712001", "hep-th/9101001", "hep-th/8801001", "hep-th/9901000", "math.evil/0301001", "hep-ſh/9901001",
            "1706.03762v0", "1706.03762v01", "1706.03762v2147483648", "1706.03762vv2", "1706.03762\nmalicious",
            "https://arxiv.org.evil.test/abs/1706.03762", "https://evil.test/arxiv.org/abs/1706.03762",
            "https://arxiv.org@evil.test/abs/1706.03762", "https://name:secret@arxiv.org/abs/1706.03762",
            "https://arxiv.org:8080/abs/1706.03762", "file:///abs/1706.03762",
            "https://arxiv.org/abs/1706%2e03762", "https://arxiv.org/search/1706.03762",
            "https://arxiv.org/abs/%2e%2e/abs/1706.03762", "https://arxiv.org/abs/../abs/1706.03762",
            "https://arxiv.org/abs/1706.03762/extra", "https://arxiv.org\\@evil.test/abs/1706.03762",
            "\u{0085}1706.03762", "1706.03762\u{0000}", "https://arxiv.org/pdf/1706.03762.pdf/",
            String(repeating: "a", count: 129) + "/9901001", String(repeating: " ", count: 2_049)]
        for value in invalid {
            #expect(throws: ArxivReferenceError.invalidReference) { try ArxivReference(value) }
        }
    }

    @Test func storedFieldsCannotSilentlyChangeTheRequestedVersionOrSource() throws {
        #expect(try ArxivReference(sourceID: "1706.03762", revision: nil).identifier == "1706.03762")
        for source in ["1706.03762v2", "https://arxiv.org/abs/1706.03762", "HEP-TH/9901001", "math.CA/0611800"] {
            #expect(throws: ArxivReferenceError.invalidReference) { try ArxivReference(sourceID: source, revision: nil) }
        }
        #expect(throws: ArxivReferenceError.invalidReference) { try ArxivReference(sourceID: "1706.03762", revision: -1) }
    }
}
