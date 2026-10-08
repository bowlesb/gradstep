import XCTest

/// Owner feedback on build 21 (docs/architecture/PERSONALIZED_FEED.md): the Feed opens on For you with the reader's own
/// specific topics as chips (broad categories under More topics), says why each paper is suggested, and its table has
/// Topics and Popularity columns, with a Popularity sort that keeps unknown values last. Scripted For you responses
/// (`--feed-for-you-fixture`): no account, network or provider. Screens are attached, and also written to
/// `GS_SCREENSHOT_DIR` when the runner sets it (`TEST_RUNNER_GS_SCREENSHOT_DIR=…`).
@MainActor
final class FeedForYouTests: XCTestCase {
    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }

    private func launch(layout: String, appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "--library-metadata-fixture", "--feed-fixture", "--feed-for-you-fixture",
                               "--start-tab=feed", "--feed-layout=\(layout)", "-appearance", appearance]
        app.launch()
        return app
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let directory = ProcessInfo.processInfo.environment["GS_SCREENSHOT_DIR"], !directory.isEmpty {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func waitFor(_ message: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) {
        let predicate = NSPredicate { _, _ in condition() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout), .completed, message)
    }

    func testForYouTableTopicsPopularityLight() throws { try forYouTable(appearance: "light") }
    func testForYouTableTopicsPopularityDark() throws { try forYouTable(appearance: "dark") }
    func testForYouListWhyLineLight() throws { try forYouList(appearance: "light") }
    func testForYouListWhyLineDark() throws { try forYouList(appearance: "dark") }

    private func forYouTable(appearance: String) throws {
        let app = launch(layout: "table", appearance: appearance)
        let forYou = app.buttons["feed.forYou"]
        XCTAssertTrue(forYou.waitForExistence(timeout: 15), "For you is the first chip")
        XCTAssertTrue(forYou.isSelected, "and the Feed's default")
        for topic in ["RL for reasoning", "Mechanistic interpretability", "Tokenization"] {
            XCTAssertTrue(app.buttons["feed.interest.\(topic)"].exists, "the reader's specific topic \(topic)")
        }
        XCTAssertFalse(app.buttons["feed.topic.cs.LG"].exists, "broad categories are not chips")
        XCTAssertTrue(element(app, "feed.moreTopics").exists, "they are under More topics")
        XCTAssertLessThan(forYou.frame.minX, app.buttons["feed.interest.RL for reasoning"].frame.minX)

        // Rows say why, and read their popularity; unknown is a dash, read as unknown.
        let top = element(app, "feed.table.2610.08448"), unknown = element(app, "feed.table.2610.03543")
        XCTAssertTrue(top.waitForExistence(timeout: 5))
        XCTAssertTrue(top.label.contains("In your tag: byte-level LMs"), top.label)
        XCTAssertTrue(top.label.contains("162 upvotes on Hugging Face Papers"), top.label)
        XCTAssertTrue(unknown.label.contains("Popularity unknown"), unknown.label)
        XCTAssertTrue(element(app, "feed.table.header.popularity").exists, "Popularity is a default column")
        save("feed-foryou-table-\(appearance)")

        // Popularity sorts most upvoted first; the unknown one stays last.
        element(app, "feed.table.header.popularity").tap()
        waitFor("sorted by popularity") { (self.element(app, "feed.table.header.popularity").value as? String) == "Sorted descending" }
        let order = ["2610.08448", "2610.07767", "2610.05030", "2610.09912", "2610.03543"].map { element(app, "feed.table.\($0)").frame.minY }
        XCTAssertEqual(order, order.sorted(), "162, 87, 40, 5, then unknown")
        save("feed-foryou-popularity-sort-\(appearance)")

        // Columns: Popularity and Topics are choices with what they show.
        app.buttons["Feed options"].tap()
        let columns = app.buttons["feed.columns"].firstMatch
        XCTAssertTrue(columns.waitForExistence(timeout: 5)); columns.tap()
        XCTAssertTrue(app.switches["feed.columns.popularity"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["feed.columns.topic"].exists)
        XCTAssertTrue(app.staticTexts["Upvotes on Hugging Face Papers"].exists)
        XCTAssertTrue(app.staticTexts["Topics"].exists)
        save("feed-columns-sheet-\(appearance)")
        app.buttons["feed.columns.done"].tap()

        // A topic chip shows that topic's papers, ranked for the reader.
        app.buttons["feed.interest.Tokenization"].tap()
        waitFor("Tokenization selected") { app.buttons["feed.interest.Tokenization"].isSelected }
        XCTAssertTrue(element(app, "feed.table.2610.08448").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "feed.table.2610.03543").exists)
        XCTAssertFalse(element(app, "feed.table.2610.07767").exists, "papers without the topic are not shown")
        save("feed-topic-chip-\(appearance)")

        // More topics reaches the broad categories, newest first as before.
        element(app, "feed.moreTopics").tap()
        let language = app.buttons["feed.more.cs.CL"].firstMatch
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        save("feed-more-topics-\(appearance)")
        language.tap()
        let chip = app.buttons["feed.topic.cs.CL"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5)); XCTAssertTrue(chip.isSelected)
        XCTAssertTrue(element(app, "feed.table.2610.01234").waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, "feed.table.header.published").value as? String, "Sorted descending", "categories stay newest first")
        app.buttons["feed.forYou"].tap()
        waitFor("back to For you") { app.buttons["feed.forYou"].isSelected && !app.buttons["feed.topic.cs.CL"].exists }
    }

    private func forYouList(appearance: String) throws {
        let app = launch(layout: "list", appearance: appearance)
        XCTAssertTrue(app.buttons["feed.forYou"].waitForExistence(timeout: 15))
        let row = element(app, "discover.result.2610.07767")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Because you added “DeepSeekMath”")).firstMatch.exists,
                      "the why line")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Policy optimization")).firstMatch.exists,
                      "specific topics in the details line")
        save("feed-foryou-list-\(appearance)")
    }
}
