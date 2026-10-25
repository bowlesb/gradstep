import XCTest

/// Search results say how they matched (owner, TestFlight 91 session, iPad: "at bare minimum having the match percent";
/// "it's very difficult for me to know what about it is matching"), and the Library / ML paper search switch keeps what
/// was typed ("I just switched, but the text disappeared… The text should be preserved"). Uses the encrypted draft
/// fixture (a real full-text index on disk) and `--discover-fixture` (ML paper search answers three fixed papers).
@MainActor
final class SearchMatchJourneyTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func wait(_ timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: timeout) == .completed
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--draft-fixture", "--reset-draft-fixture"] + extra
        app.launch()
        // The List's row, or the table's (`--library-layout=table`).
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 15)
                      || app.descendants(matching: .any)["library.table.paper/aaaaaaaa-0000-0000-0000-000000000001"].waitForExistence(timeout: 5))
        app.show("library")
        return app
    }

    private func replace(_ search: XCUIElement, with text: String) {
        search.tap()
        let current = (search.value as? String) ?? ""
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }

    func testLibraryResultsSayHowManyWordsMatchedAndWhere() throws {
        let app = launch()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let row = app.buttons[sampleID]
        // Only the sample's text has this word (it is indexed once opened; the search reruns as the index changes).
        replace(search, with: "compatibility")
        XCTAssertTrue(wait(20) { row.exists && row.label.contains("Matches your search word, in the full text") && row.label.contains("compatibility scores") },
                      "Strength and the text around the match: \(row.exists ? row.label : "no row")")
        capture(app, "Library: a word in the paper's text")
        // Both words are in the abstract: the line says so and shows the abstract around them.
        replace(search, with: "local equations")
        XCTAssertTrue(wait { row.exists && row.label.contains("Matches all 2 search words, in the abstract") && row.label.contains("A local reading fixture") },
                      "Abstract match: \(row.exists ? row.label : "no row")")
        // A title word and a keyword (tags).
        replace(search, with: "machine attention")
        XCTAssertTrue(wait { row.exists && row.label.contains("Matches all 2 search words, in the title and the tags") },
                      "Title and tags: \(row.exists ? row.label : "no row")")
        capture(app, "Library: title and tags")
        // The ⓘ beside the switch says what the line means.
        let info = app.buttons["search.match.info"]
        XCTAssertTrue(info.waitForExistence(timeout: 5))
        info.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "share of your search words")).firstMatch.waitForExistence(timeout: 5))
        capture(app, "Match explained")
    }

    /// The table (the iPad's usual Library layout): the title cell shows the same line, and VoiceOver reads it with the row.
    func testTheTableShowsTheMatchUnderTheTitle() throws {
        let app = launch(["--library-layout=table"])
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("compatibility")
        let row = app.descendants(matching: .any)["library.table.paper/aaaaaaaa-0000-0000-0000-000000000001"].firstMatch
        XCTAssertTrue(wait(20) { row.exists && row.label.contains("Matches your search word, in the full text") && row.label.contains("compatibility scores") },
                      "Table row: \(row.exists ? row.label : "no row")")
        capture(app, "Table: the match under the title")
    }

    func testSwitchingToMLPaperSearchKeepsTheWordsAndSearchesThem() throws {
        let app = launch(["--discover-fixture"])
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let query = "diffusion policy robot"
        search.tap(); search.typeText(query)
        let scope = app.segmentedControls["library.searchScope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        scope.buttons["ML paper search"].tap()
        XCTAssertEqual(search.value as? String, query, "The words stay when switching to ML paper search")
        // Searched at once, no second Return; each result says how it matched.
        let first = app.descendants(matching: .any)["discover.result.2610.03011"]
        XCTAssertTrue(first.waitForExistence(timeout: 5), "ML paper search ran the words")
        let lines = app.descendants(matching: .any).matching(identifier: "search.match")
        XCTAssertTrue(wait { lines.count >= 3 })
        let labels = lines.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(labels.contains("Matches all 3 search words, in the title"), "\(labels)")
        XCTAssertTrue(labels.contains("Matches all 3 search words, in the title and the abstract"), "\(labels)")
        XCTAssertTrue(labels.contains("Matches 1 of 3 search words, in the abstract"), "\(labels)")
        capture(app, "ML paper search: the same words, with match lines")
        // And back: the Library searches the same words.
        scope.buttons["Library"].tap()
        XCTAssertEqual(search.value as? String, query, "The words stay when switching back to the Library")
        XCTAssertTrue(app.staticTexts["No matching papers"].waitForExistence(timeout: 5), "The Library searched the words")
        capture(app, "Library: the same words")
    }
}
