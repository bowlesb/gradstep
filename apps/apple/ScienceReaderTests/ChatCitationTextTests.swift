import XCTest
@testable import ScienceReader

/// `[¶N]` citations in answers and the figure view (ChatSelectableText.withCitations).
@MainActor
final class ChatCitationTextTests: XCTestCase {
    func testTouchingCitationsReadAsTwoLinks() {
        let text = ChatSelectableText.withCitations(NSAttributedString(string: "the RL phase [¶23][¶24]. Then [¶8]."), size: 17)
        XCTAssertEqual(text.string, "the RL phase ¶23\u{2009}¶24. Then ¶8.", "a thin space between citations that touch")
        let first = (text.string as NSString).range(of: "¶23"), gap = NSRange(location: first.upperBound, length: 1)
        XCTAssertEqual(text.attribute(.link, at: first.location, effectiveRange: nil) as? URL, URL(string: "\(ChatSelectableText.citeScheme)://23"))
        XCTAssertNil(text.attribute(.link, at: gap.location, effectiveRange: nil), "the space is not part of a link")
    }
}
