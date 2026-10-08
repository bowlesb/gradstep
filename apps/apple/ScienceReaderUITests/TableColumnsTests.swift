import XCTest

/// Build 16 #3 and build 17: the Library, Feed and All chats tables show every column the reader chooses; when they
/// don't fit, they scroll sideways while the title stays in place. Also build 16 #6 (A− / A+). Synthetic fixtures, no
/// network.
@MainActor
final class TableColumnsTests: XCTestCase {
    private let sample = "aaaaaaaa-0000-0000-0000-000000000001"
    private let attention = "eeeeeeee-0000-0000-0000-000000000001"

    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attached = XCTAttachment(screenshot: app.screenshot()); attached.name = name; attached.lifetime = .keepAlways; add(attached)
    }

    /// On screen: inside the window, and not cut off at the table's edge.
    private func onScreen(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let window = app.windows.firstMatch.frame
        return element.exists && element.frame.minX >= window.minX - 1 && element.frame.maxX <= window.maxX + 1 && element.isHittable
    }

    /// A sideways swipe across `element` (a row), right to left.
    private func swipeColumns(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: element.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)))
    }

    /// Turns a column chooser toggle on or off (its switch sits at the trailing end).
    private func flip(_ toggle: XCUIElement) {
        let before = toggle.value as? String
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        if toggle.value as? String == before { toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap() }
    }

    private func waitFor(_ message: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) {
        let predicate = NSPredicate { _, _ in condition() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout), .completed, message)
    }

    func testLibraryColumnsScrollSidewaysUnderAPinnedTitle() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone portrait is where the default columns overflow")
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "--library-metadata-fixture", "--library-layout=table"]
        app.launch()
        let header = { (id: String) in app.descendants(matching: .any)["library.table.header.\(id)"].firstMatch }
        XCTAssertTrue(header("year").waitForExistence(timeout: 15))
        // At rest it looks as before: Title, Year, Progress; the dates and chats are past the edge.
        XCTAssertTrue(onScreen(header("year"), in: app)); XCTAssertTrue(onScreen(header("progress"), in: app))
        XCTAssertFalse(onScreen(header("chats"), in: app), "Chats waits past the edge")
        let title = header("title"), titleX = title.frame.minX
        let row = app.descendants(matching: .any)["library.table.paper/\(attention)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        for part in ["Attention Is All You Need", "2017", "Added today", "2 chats", "60 percent read"] {
            XCTAssertTrue(row.label.contains(part), "VoiceOver reads every chosen column: \(part) in \(row.label)")
        }
        attach(app, "Library table at rest (iPhone portrait)")

        // A sideways swipe on the rows brings the other columns in; the title stays.
        swipeColumns(row)
        waitFor("Chats scrolls into view") { self.onScreen(header("chats"), in: app) }
        XCTAssertEqual(title.frame.minX, titleX, accuracy: 1, "The title column stays pinned")
        attach(app, "Library table scrolled sideways")
        // A tap still opens a paper (the sample has its reading bundle on the device).
        let sampleRow = app.descendants(matching: .any)["library.table.paper/\(sample)"].firstMatch
        XCTAssertTrue(sampleRow.isHittable)
        sampleRow.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
    }

    func testFeedColumnChooserFilterAndSideways() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "--library-metadata-fixture", "--feed-fixture"]
        app.launch()
        if app.buttons["tab.feed"].waitForExistence(timeout: 15) { app.buttons["tab.feed"].tap() } else { app.segmentedControls.buttons["Feed"].tap() }
        let options = app.buttons["Feed options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5)); options.tap()
        app.buttons["View as"].firstMatch.tap()
        app.buttons["Table"].firstMatch.tap()
        let header = { (id: String) in app.descendants(matching: .any)["feed.table.header.\(id)"].firstMatch }
        XCTAssertTrue(header("published").waitForExistence(timeout: 5))

        // Columns: Authors, arXiv ID and Abstract can be added; changes show at once.
        options.tap()
        let columns = app.buttons["feed.columns"].firstMatch
        XCTAssertTrue(columns.waitForExistence(timeout: 5)); columns.tap()
        XCTAssertTrue(app.navigationBars["Columns"].waitForExistence(timeout: 5))
        for id in ["authors", "arxiv"] {
            let toggle = app.switches["feed.columns.\(id)"].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "0")
            flip(toggle)
            XCTAssertEqual(toggle.value as? String, "1")
        }
        attach(app, "Feed columns")
        app.buttons["feed.columns.done"].tap()
        XCTAssertTrue(header("arxiv").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["discover.add.2610.01234"].isHittable, "Add stays at the trailing edge")
        let feedRow = app.descendants(matching: .any)["feed.table.2610.01234"].firstMatch
        let addX = app.buttons["discover.add.2610.01234"].frame.minX
        if !onScreen(header("arxiv"), in: app) {
            swipeColumns(feedRow)
            if !onScreen(header("arxiv"), in: app) { swipeColumns(feedRow) }
        }
        waitFor("arXiv ID scrolls into view") { self.onScreen(header("arxiv"), in: app) }
        XCTAssertEqual(app.buttons["discover.add.2610.01234"].frame.minX, addX, accuracy: 1)
        XCTAssertTrue(app.buttons["discover.add.2610.01234"].isHittable, "Add stays put while the columns scroll")
        attach(app, "Feed table scrolled sideways")

        // Sort by, from the menu.
        options.tap()
        let sortBy = app.buttons["Sort by"].firstMatch
        XCTAssertTrue(sortBy.waitForExistence(timeout: 5)); sortBy.tap()
        app.buttons["Title"].firstMatch.tap()
        XCTAssertEqual(header("title").value as? String, "Sorted ascending")

        // Text size: A+ makes the Feed's text larger, A− back.
        let row = app.descendants(matching: .any)["feed.table.2610.01234"].firstMatch
        let before = row.frame.height
        let larger = app.buttons["feed.textSize.larger"]
        XCTAssertTrue(larger.waitForExistence(timeout: 5))
        larger.tap(); larger.tap()
        waitFor("Larger text makes the row taller") { row.frame.height > before + 2 }
        attach(app, "Feed with larger text")
        app.buttons["feed.textSize.smaller"].tap(); app.buttons["feed.textSize.smaller"].tap()
        waitFor("And back") { abs(row.frame.height - before) < 2 }
        restoreColumns(app, options: options, menuItem: "feed.columns", prefix: "feed.columns")
    }

    /// Choices are kept on the device: put the defaults back for other tests.
    private func restoreColumns(_ app: XCUIApplication, options: XCUIElement, menuItem: String, prefix: String) {
        options.tap()
        app.buttons[menuItem].firstMatch.tap()
        let restore = app.buttons["\(prefix).restore"]
        XCTAssertTrue(app.navigationBars["Columns"].waitForExistence(timeout: 5))
        for _ in 0..<3 where !(restore.exists && restore.isHittable) { app.collectionViews.firstMatch.swipeUp() }
        restore.tap()
        app.buttons["\(prefix).done"].tap()
    }

    func testAllChatsColumnsAndSidewaysScroll() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture", "--chat-history-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["paper.\(sample)"].waitForExistence(timeout: 15))
        if app.buttons["tab.chat"].exists { app.buttons["tab.chat"].tap() } else { app.segmentedControls.buttons["General Chat"].tap() }
        app.buttons["Chat history"].tap()
        XCTAssertTrue(app.navigationBars["All chats"].waitForExistence(timeout: 5))
        let header = { (id: String) in app.buttons["chat.history.header.\(id)"] }
        XCTAssertTrue(header("lastUsed").waitForExistence(timeout: 5))
        // Columns: add Kind and Answer length.
        app.buttons["chat.history.options"].tap()
        app.buttons["chat.history.columns"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Columns"].waitForExistence(timeout: 5))
        for id in ["kind", "answerLength"] {
            let toggle = app.switches["chat.history.columns.\(id)"].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            for _ in 0..<2 where !toggle.isHittable { app.collectionViews.firstMatch.swipeUp() }
            flip(toggle)
            XCTAssertEqual(toggle.value as? String, "1")
        }
        attach(app, "All chats columns")
        app.buttons["chat.history.columns.done"].tap()
        XCTAssertTrue(header("answerLength").waitForExistence(timeout: 5))
        let lastUsedX = header("lastUsed").frame.minX
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertFalse(onScreen(header("answerLength"), in: app), "Answer length waits past the edge")
            let firstRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.history.c4a7")).firstMatch
            for _ in 0..<3 where !onScreen(header("answerLength"), in: app) { swipeColumns(firstRow) }
            waitFor("Answer length scrolls into view") { self.onScreen(header("answerLength"), in: app) }
        }
        XCTAssertEqual(header("lastUsed").frame.minX, lastUsedX, accuracy: 1, "Last used stays at the trailing edge")
        attach(app, "All chats scrolled sideways")
        // Sorting by a new column.
        header("answerLength").tap()
        XCTAssertEqual(header("answerLength").value as? String, "Sorted descending", "Longest answers first")
        restoreColumns(app, options: app.buttons["chat.history.options"], menuItem: "chat.history.columns", prefix: "chat.history.columns")
    }

    func testPaperTextSizeControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["paper.\(sample)"].waitForExistence(timeout: 15)); app.buttons["paper.\(sample)"].tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        let paragraph = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A useful first pass identifies")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 20))
        let larger = app.buttons["paper.textSize.larger"], smaller = app.buttons["paper.textSize.smaller"]
        XCTAssertTrue(larger.isHittable && smaller.isHittable)
        if app.buttons["tab.paper"].exists {
            XCTAssertLessThan(larger.frame.maxY, app.buttons["tab.paper"].frame.minY, "Above the tab bar")
        }
        XCTAssertGreaterThan(larger.frame.minX, app.windows.firstMatch.frame.midX, "At the bottom right")
        let height = paragraph.frame.height
        larger.tap(); larger.tap()
        waitFor("Larger paper text") { paragraph.frame.height > height + 4 }
        attach(app, "Paper with larger text")
        smaller.tap(); smaller.tap()
        waitFor("And back") { abs(paragraph.frame.height - height) < 2 }
    }
}
