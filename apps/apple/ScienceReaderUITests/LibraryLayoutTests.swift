import XCTest

/// Library layouts (owner decisions 2026-10-05/06): the List stays the default; "Detailed rows" adds this device's
/// activity; "Table" is the shared paper table on every size, showing the columns that fit. Synthetic fixture,
/// no network.
@MainActor
final class LibraryLayoutTests: XCTestCase {
    private let sample = "aaaaaaaa-0000-0000-0000-000000000001"
    private let attention = "eeeeeeee-0000-0000-0000-000000000001"
    private let dpo = "eeeeeeee-0000-0000-0000-000000000002"
    private let resnet = "eeeeeeee-0000-0000-0000-000000000005"
    private let adam = "eeeeeeee-0000-0000-0000-000000000006"
    /// The import that failed for lack of credits.
    private let needsCredits = "import/eeeeeeee-0000-0000-0000-000000000021"

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "--library-metadata-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["paper.\(sample)"].waitForExistence(timeout: 15), "The List is the default layout")
        return app
    }

    /// Layout and sort choices live in the options menu's "View as" and "Sort by" submenus.
    private func choose(_ item: String, in app: XCUIApplication, screenshot: String? = nil) {
        app.buttons["Library options"].tap()
        let submenu = ["List", "Table", "Detailed rows"].contains(item) ? "View as" : "Sort by"
        let opener = app.buttons[submenu].firstMatch
        XCTAssertTrue(opener.waitForExistence(timeout: 5), "Submenu \(submenu)"); opener.tap()
        let button = app.buttons[item].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Menu item \(item)")
        if let screenshot {
            let menu = XCTAttachment(screenshot: app.screenshot()); menu.name = screenshot; menu.lifetime = .keepAlways; add(menu)
        }
        button.tap()
    }

    private func cell(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["library.table.\(id.hasPrefix("import/") ? id : "paper/" + id)"].firstMatch
    }

    /// A column header (a button when the column sorts), by its title.
    private func header(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["library.table.header.\(title.lowercased())"].firstMatch
    }

    private func tapHeader(_ title: String, in app: XCUIApplication) {
        let element = header(title, in: app)
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Header \(title)")
        element.tap()
    }

    private func assertAbove(_ upper: XCUIElement, _ lower: XCUIElement, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(upper.waitForExistence(timeout: 5) && lower.exists, message, file: file, line: line)
        XCTAssertLessThan(upper.frame.minY, lower.frame.minY, message, file: file, line: line)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attached = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attached.name = name; attached.lifetime = .keepAlways; add(attached)
    }

    func testTableSortsByColumnHeadersAndOpensAPaper() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad; the phone has its own test")
        // Landscape is the wide layout (segments, Reader beside the chat); portrait is checked at the end.
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch()
        choose("Table", in: app, screenshot: "Library options menu (iPad)")
        XCTAssertTrue(app.descendants(matching: .any)["library.table"].waitForExistence(timeout: 5))
        XCTAssertTrue(cell(attention, in: app).waitForExistence(timeout: 5))
        for title in ["Title", "Year", "Topics", "Added", "Opened", "Chats", "Progress"] {
            XCTAssertTrue(header(title, in: app).exists, "Wide iPad shows \(title)")
        }
        XCTAssertEqual(header("Added", in: app).value as? String, "Sorted descending", "Recent order is the Added column, newest first")
        attach(app, "Library table")

        // Recent first (as the List): Attention was added after DPO.
        assertAbove(cell(attention, in: app), cell(dpo, in: app), "Recent order")

        // Long-press keeps the list's row actions (disabled here: the fixture has no account).
        cell(attention, in: app).press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Remove from library"].waitForExistence(timeout: 5), "Paper row actions")
        attach(app, "Table row actions")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
        XCTAssertTrue(app.buttons["Remove from library"].waitForNonExistence(timeout: 5))
        cell(needsCredits, in: app).press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Cancel import"].waitForExistence(timeout: 5), "Import row actions")
        XCTAssertTrue(app.buttons["Retry import"].exists, "A failed import offers Retry")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
        XCTAssertTrue(app.buttons["Cancel import"].waitForNonExistence(timeout: 5))
        tapHeader("Year", in: app)
        assertAbove(cell(dpo, in: app), cell(attention, in: app), "Year: newest first (2023 before 2017)")
        assertAbove(cell(attention, in: app), cell(resnet, in: app), "Year: 2017 before 2015")
        tapHeader("Year", in: app)
        XCTAssertEqual(header("Year", in: app).value as? String, "Sorted ascending")
        assertAbove(cell(resnet, in: app), cell(attention, in: app), "Year reversed: oldest first")
        tapHeader("Progress", in: app)
        assertAbove(cell(resnet, in: app), cell(attention, in: app), "Progress: 100% before 60%")
        assertAbove(cell(attention, in: app), cell(dpo, in: app), "Progress: 60% before 25%")
        attach(app, "Library table sorted by Progress")

        // Tapping a row opens it exactly like the list.
        cell(sample, in: app).tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.segmentedControls.buttons["Reader"].isSelected)
        app.segmentedControls.buttons["Library"].tap()
        XCTAssertTrue(cell(sample, in: app).waitForExistence(timeout: 5), "The table layout is kept")

        // Portrait (11": 834 pt) keeps the table, without the Topics column (it used to fall back to rows).
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(header("Opened", in: app).waitForExistence(timeout: 5), "Portrait iPad keeps the table")
        XCTAssertFalse(header("Topics", in: app).exists, "Topics needs a wider screen")
        attach(app, "Library table (iPad portrait)")
        choose("List", in: app)
        XCTAssertTrue(app.buttons["paper.\(sample)"].waitForExistence(timeout: 5))
    }

    func testDetailedRowsOnPhoneSortAndOpenAPaper() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone")
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        choose("Detailed rows", in: app, screenshot: "Library options menu (iPhone)")
        let row = app.buttons["paper.\(attention)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Vaswani, Shazeer +6"), row.label)
        XCTAssertTrue(row.label.contains("60% read"), row.label)
        XCTAssertTrue(row.label.contains("2 chats"), row.label)
        XCTAssertFalse(app.descendants(matching: .any)["library.table"].exists, "Detailed rows aren't the table")

        choose("Year", in: app)
        assertAbove(app.buttons["paper.\(dpo)"], row, "Year: newest first")
        choose("Progress", in: app)
        assertAbove(app.buttons["paper.\(resnet)"], row, "Progress: most read first")
        app.buttons["paper.\(sample)"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        app.buttons["tab.library"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        choose("List", in: app)
        XCTAssertTrue(app.buttons["paper.\(sample)"].waitForExistence(timeout: 5))
    }

    func testPhoneTableFitsPortraitAndAddsColumnsInLandscape() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone")
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch()
        choose("Table", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["library.table"].waitForExistence(timeout: 5), "A real table in portrait")
        for title in ["Title", "Year", "Progress"] { XCTAssertTrue(header(title, in: app).exists, "Portrait shows \(title)") }
        for title in ["Added", "Opened", "Chats"] { XCTAssertFalse(header(title, in: app).exists, "\(title) needs landscape") }
        // The order (Recent: the Added column) still shows while its column is hidden.
        let indicator = app.descendants(matching: .any)["library.table.sortIndicator"].firstMatch
        XCTAssertEqual(indicator.label, "Sorted by Added")
        XCTAssertEqual(indicator.value as? String, "Descending")
        // One element per row, reading every column, including those too wide to show.
        let row = cell(attention, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        for part in ["Attention Is All You Need", "Vaswani et al.", "2017", "Added today", "2 chats", "60 percent read"] {
            XCTAssertTrue(row.label.contains(part), "\(part) in \(row.label)")
        }
        attach(app, "Phone portrait table")

        tapHeader("Progress", in: app)
        XCTAssertEqual(header("Progress", in: app).value as? String, "Sorted descending")
        assertAbove(cell(resnet, in: app), cell(attention, in: app), "Progress: 100% before 60%")
        tapHeader("Progress", in: app)
        assertAbove(cell(adam, in: app), cell(dpo, in: app), "Progress reversed: 8% before 25%")

        // An import that needs credits opens the store from its row.
        let blocked = cell(needsCredits, in: app)
        for _ in 0..<4 where !(blocked.exists && blocked.isHittable) { app.swipeUp() }   // rows load as they scroll in
        XCTAssertTrue(blocked.waitForExistence(timeout: 5))
        XCTAssertTrue(blocked.label.contains("Not enough credits"), blocked.label)
        blocked.tap()
        XCTAssertTrue(app.navigationBars["Get credits"].waitForExistence(timeout: 5), "The row opens Get credits")
        app.navigationBars["Get credits"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Get credits"].waitForNonExistence(timeout: 5))
        for _ in 0..<4 where !cell(sample, in: app).exists { app.swipeDown() }

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(header("Opened", in: app).waitForExistence(timeout: 5), "Landscape adds the dates and chats")
        XCTAssertTrue(header("Chats", in: app).exists)
        attach(app, "Phone landscape table")
        tapHeader("Opened", in: app)
        assertAbove(cell(sample, in: app), cell(attention, in: app), "Opened: most recent first")
        cell(sample, in: app).tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
    }

    /// The Feed's Table layout is the same table: chosen from the Feed's "…" menu, sorted by its headers; a row's
    /// tap shows its abstract.
    func testFeedTableSortsAndShowsAnAbstract() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "--library-metadata-fixture", "--feed-fixture"]
        app.launch()
        if app.buttons["tab.feed"].waitForExistence(timeout: 15) { app.buttons["tab.feed"].tap() }
        else { app.segmentedControls.buttons["Feed"].tap() }
        XCTAssertTrue(app.buttons["Feed options"].waitForExistence(timeout: 5))
        app.buttons["Feed options"].tap()
        let viewAs = app.buttons["View as"].firstMatch
        XCTAssertTrue(viewAs.waitForExistence(timeout: 5)); viewAs.tap()
        let table = app.buttons["Table"].firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5)); table.tap()

        let feed = app.descendants(matching: .any)["feed.table"].firstMatch
        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        let row = { (id: String) in app.descendants(matching: .any)["feed.table.\(id)"].firstMatch }
        XCTAssertEqual(app.buttons["feed.table.header.published"].value as? String, "Sorted descending", "Newest first")
        assertAbove(row("2610.03011"), row("2609.11890"), "Published: newest first")
        XCTAssertTrue(row("2610.01234").label.contains("Lin et al."), row("2610.01234").label)
        XCTAssertTrue(app.buttons["discover.add.2610.01234"].exists, "Add stays in its own column")
        app.buttons["feed.table.header.title"].tap()
        assertAbove(row("2609.11890"), row("2610.01234"), "Title: Calibrated before Sparse")
        attach(app, "Feed table sorted by title")

        let abstract = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "We show that expert routing")).firstMatch
        XCTAssertFalse(abstract.exists, "Abstracts are tucked away")
        row("2610.01234").tap()
        XCTAssertTrue(abstract.waitForExistence(timeout: 5), "A row's tap shows its abstract")
        attach(app, "Feed table abstract")
        row("2610.01234").tap()
        XCTAssertTrue(abstract.waitForNonExistence(timeout: 5))
    }
}
