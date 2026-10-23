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
    private func onScreen(_ element: XCUIElement, in app: XCUIApplication, before pinned: XCUIElement? = nil) -> Bool {
        let window = app.windows.firstMatch.frame
        let right = pinned.map { $0.frame.minX - 12 } ?? (window.maxX - 16)
        return element.exists && element.frame.minX >= window.minX + 15 && element.frame.maxX <= right + 1 && element.isHittable
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
        // Start with the same two choices on both devices; iPad's normal defaults already include Authors.
        app.launchArguments = ["--workflow-fixture", "--library-metadata-fixture", "--feed-fixture", "--feed-columns=topic,published"]
        app.launch()
        if app.buttons["tab.feed"].waitForExistence(timeout: 15) { app.show("feed") } else { app.wideMode("Feed").tap() }
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
            let choices = app.collectionViews.firstMatch
            for _ in 0..<3 where !(toggle.exists && toggle.isHittable && choices.frame.insetBy(dx: 0, dy: 24).contains(toggle.frame)) {
                choices.swipeUp()
            }
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
        let addButton = app.buttons["discover.add.2610.01234"]
        if !onScreen(header("arxiv"), in: app, before: addButton) {
            swipeColumns(feedRow)
            if !onScreen(header("arxiv"), in: app, before: addButton) { swipeColumns(feedRow) }
        }
        waitFor("The whole arXiv header is visible before pinned Add") { self.onScreen(header("arxiv"), in: app, before: addButton) }
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
        let inLibrary = app.descendants(matching: .any)["feed.table.2001.08361"].firstMatch
        XCTAssertTrue(inLibrary.exists, "Already added papers are shown initially")
        options.tap(); app.buttons["feed.hideLibrary"].firstMatch.tap()
        XCTAssertTrue(inLibrary.waitForNonExistence(timeout: 5), "Hide-in-library also hides an import already requested")
        XCTAssertTrue(row.exists, "Papers not added remain")
        options.tap(); app.buttons["feed.hideLibrary"].firstMatch.tap()
        XCTAssertTrue(inLibrary.waitForExistence(timeout: 5), "The filter reverses without refetching")
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
        if app.wideShape { app.wideMode("General Chat").tap() } else { app.show("chat") }
        app.buttons["Chat history"].tap()
        XCTAssertTrue(app.buttons["chat.history.options"].waitForExistence(timeout: 5))
        let header = { (id: String) in app.buttons["chat.history.header.\(id)"] }
        XCTAssertTrue(header("lastUsed").waitForExistence(timeout: 5))
        // Columns: add Kind and Answer length.
        app.buttons["chat.history.options"].tap()
        app.buttons["chat.history.columns"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Columns"].waitForExistence(timeout: 5))
        for id in ["kind", "answerLength"] {
            let toggle = app.switches["chat.history.columns.\(id)"].firstMatch
            // The medium sheet creates its rows lazily; Answer length follows the new Topics option.
            for _ in 0..<3 where !(toggle.exists && toggle.isHittable) { app.collectionViews.firstMatch.swipeUp() }
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            flip(toggle)
            XCTAssertEqual(toggle.value as? String, "1")
        }
        attach(app, "All chats columns")
        app.buttons["chat.history.columns.done"].tap()
        XCTAssertTrue(header("answerLength").waitForExistence(timeout: 5))
        let lastUsedX = header("lastUsed").frame.minX
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertFalse(onScreen(header("answerLength"), in: app, before: header("lastUsed")), "Answer length waits past the edge")
        }
        if !onScreen(header("answerLength"), in: app, before: header("lastUsed")) {
            let firstRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.history.c4a7")).firstMatch
            for _ in 0..<3 where !onScreen(header("answerLength"), in: app, before: header("lastUsed")) { swipeColumns(firstRow) }
            waitFor("Answer length scrolls into view") { self.onScreen(header("answerLength"), in: app, before: header("lastUsed")) }
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

    func testExpandedFeedShowsFullTitleAndAbstractEndingAndScales() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "--feed-fixture", "--feed-full-abstract-fixture", "--feed-layout=table", "--start-tab=feed"]
        app.launch()
        let row = app.descendants(matching: .any)["feed.table.2610.03011"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        let collapsed = row.frame.height
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        let ending = "The final limitation is that results have not been evaluated on physical robots."
        let abstract = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", ending)).firstMatch
        XCTAssertTrue(abstract.waitForExistence(timeout: 5), "The full abstract survives the legacy 700-character preview")
        XCTAssertGreaterThan(abstract.label.count, 700)
        // On a phone the title needs more than two lines; a 13-inch iPad's wide Title column fits it in two already.
        if app.windows.firstMatch.frame.width < 900 {
            waitFor("Expanded title is no longer limited to two lines") { row.frame.height > collapsed + 25 }
        }
        attach(app, "Expanded full Feed title")
        let before = abstract.frame.height
        app.buttons["feed.textSize.larger"].tap(); app.buttons["feed.textSize.larger"].tap()
        waitFor("A+ scales the complete abstract") { abstract.frame.height > before + 20 }
        app.buttons["feed.textSize.smaller"].tap(); app.buttons["feed.textSize.smaller"].tap()
        waitFor("A- restores the complete abstract") { abs(abstract.frame.height - before) < 3 }
        let bottom = app.buttons["tab.feed"].exists ? app.buttons["tab.feed"].frame.minY : app.windows.firstMatch.frame.maxY - 30
        for _ in 0..<6 where abstract.frame.maxY > bottom { app.swipeUp(velocity: .slow) }
        XCTAssertLessThanOrEqual(abstract.frame.maxY, bottom, "The ending can be brought above the floating controls")
        attach(app, "Full Feed abstract ending")
        XCTAssertFalse(app.links["Read the full abstract on arXiv"].exists, "A complete abstract has no excerpt warning")
    }

    func testFeedListExpandsAndCollapsesTheFullAbstract() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "--feed-fixture", "--feed-full-abstract-fixture", "--feed-layout=list", "--start-tab=feed"]
        app.launch()
        let toggle = app.buttons["discover.abstract.2610.03011"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15)); XCTAssertEqual(toggle.label, "Full abstract")
        let abstract = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@",
            "The final limitation is that results have not been evaluated on physical robots.")).firstMatch
        XCTAssertTrue(abstract.exists)
        let collapsed = abstract.frame.height
        toggle.tap()
        waitFor("List abstract expands beyond its two-line preview") { abstract.frame.height > collapsed + 100 }
        XCTAssertEqual(toggle.label, "Less")
        XCTAssertGreaterThan(abstract.label.count, 700)
        attach(app, "List with full Feed abstract")
        for _ in 0..<6 where !toggle.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(toggle.isHittable); toggle.tap()
        XCTAssertEqual(toggle.label, "Full abstract")
        waitFor("Collapsing restores the compact preview") { abs(abstract.frame.height - collapsed) < 3 }
    }

    func testOneWideColumnKeepsItsHeaderAndPinnedAction() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "--library-metadata-fixture", "--feed-fixture",
                               "--feed-layout=table", "--feed-columns=abstract"]
        app.launch()
        if app.buttons["tab.feed"].waitForExistence(timeout: 15) { app.show("feed") } else { app.wideMode("Feed").tap() }
        let abstract = app.descendants(matching: .any)["feed.table.header.abstract"].firstMatch
        let add = app.buttons["discover.add.2610.01234"]
        XCTAssertTrue(abstract.waitForExistence(timeout: 5))
        XCTAssertTrue(onScreen(abstract, in: app, before: add))
        XCTAssertTrue(add.isHittable)
        attach(app, "Feed with one chosen wide column")
        app.terminate()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture", "--chat-history-fixture",
                               "--chat-columns=answerLength"]
        app.launch()
        XCTAssertTrue(app.buttons["paper.\(sample)"].waitForExistence(timeout: 15))
        if app.wideShape { app.wideMode("General Chat").tap() } else { app.show("chat") }
        app.buttons["Chat history"].tap()
        let lastUsed = app.buttons["chat.history.header.lastUsed"], length = app.buttons["chat.history.header.answerLength"]
        XCTAssertTrue(lastUsed.waitForExistence(timeout: 5), "The fixed header remains even when one wide cell fits its viewport")
        XCTAssertTrue(lastUsed.isHittable && onScreen(length, in: app, before: lastUsed))
        attach(app, "All chats with one chosen column")
    }
}
