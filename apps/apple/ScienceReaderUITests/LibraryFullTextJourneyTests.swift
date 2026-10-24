import XCTest

/// Library search over the paper's own text (docs/architecture/NATIVE_LIBRARY_SEARCH.md, "Full-text index"): a word only
/// the sample's body contains finds the sample with one line of that text under its title; opening it shows the paper
/// with Find in paper already searching for the word. Uses the encrypted draft fixture (a real index on disk).
@MainActor
final class LibraryFullTextJourneyTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func wait(_ timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: timeout) == .completed
    }

    func testBodyWordFindsThePaperWithASnippetAndOpensFindOnIt() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--draft-fixture", "--reset-draft-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 15))
        app.show("library")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        // "compatibility" is in the sample's text only (not its title, abstract or keywords). The sample is indexed
        // in the background once opened; the query reruns as the index changes.
        search.tap(); search.typeText("compatibility")
        let row = app.buttons[sampleID]
        XCTAssertTrue(wait(20) { row.exists && row.label.contains("compatibility scores") },
                      "The row shows the matched text: \(row.exists ? row.label : "no row")")
        capture("Library search: snippet under the title")
        row.tap()
        let input = app.textFields["paper.find.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, "compatibility")
        let count = app.staticTexts["paper.find.count"]
        XCTAssertTrue(wait { count.exists && count.label.hasPrefix("1 of ") }, "Find found the word: \(count.exists ? count.label : "none")")
        XCTAssertEqual(app.keyboards.count, 0, "Opening a result leaves the keyboard down")
        capture("Paper opened with Find on the matched word")
    }
}
