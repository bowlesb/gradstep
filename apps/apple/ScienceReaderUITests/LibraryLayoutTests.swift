import XCTest

/// Library layouts (owner decisions 2026-10-05/06/07): the Table is the Library's main view (the shared paper table
/// on every size, showing the reader's columns that fit); the List is the alternative. Columns are chosen in Library
/// options › Columns; quick filters and tags sit above the table; a failed import shows Retry. Synthetic fixture, no
/// network. Fixture runs start in the List unless `--library-layout=` names one.
@MainActor
final class LibraryLayoutTests: XCTestCase {
    private let sample = "aaaaaaaa-0000-0000-0000-000000000001"
    private let attention = "eeeeeeee-0000-0000-0000-000000000001"
    private let dpo = "eeeeeeee-0000-0000-0000-000000000002"
    private let lora = "eeeeeeee-0000-0000-0000-000000000003"
    private let resnet = "eeeeeeee-0000-0000-0000-000000000005"
    private let adam = "eeeeeeee-0000-0000-0000-000000000006"
    private let archived = "eeeeeeee-0000-0000-0000-000000000008"
    /// The import that failed for lack of credits.
    private let needsCredits = "import/eeeeeeee-0000-0000-0000-000000000021"
    /// The import whose download failed (`--slow-import-fixture`).
    private let downloadFailed = "import/eeeeeeee-0000-0000-0000-000000000023"

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "--library-metadata-fixture"] + extra
        app.launch()
        if extra.contains("--library-layout=table") {
            XCTAssertTrue(app.descendants(matching: .any)["library.table"].waitForExistence(timeout: 15), "The table")
        } else {
            XCTAssertTrue(app.buttons["paper.\(sample)"].waitForExistence(timeout: 15), "Fixture runs start in the List")
        }
        return app
    }

    /// Layout and sort choices live in the options menu's "View as" and "Sort by" submenus.
    private func choose(_ item: String, in app: XCUIApplication, screenshot: String? = nil) {
        app.buttons["Library options"].tap()
        let submenu = ["List", "Table"].contains(item) ? "View as" : "Sort by"
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

    /// On screen without scrolling the columns sideways (build 16 #3: chosen columns that don't fit scroll in).
    private func onScreen(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let window = app.windows.firstMatch.frame
        return element.exists && element.isHittable && element.frame.maxX <= window.maxX + 1 && element.frame.minX >= window.minX - 1
    }

    private func filter(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["library.filter.\(name)"].firstMatch
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
        for title in ["Title", "Year", "Tags", "Added", "Opened", "Chats", "Progress"] {
            XCTAssertTrue(header(title, in: app).exists, "Wide iPad shows \(title)")
        }
        for title in ["Pages", "Source"] { XCTAssertFalse(header(title, in: app).exists, "\(title) is off by default") }
        XCTAssertEqual(header("Added", in: app).value as? String, "Sorted descending", "Recent order is the Added column, newest first")
        XCTAssertTrue(cell(dpo, in: app).label.contains("Tags: Alignment, RLHF"), "A paper's own tags: \(cell(dpo, in: app).label)")
        XCTAssertTrue(cell(attention, in: app).label.contains("Tags: Natural language processing, Machine learning"), "Topics from categories, in the tag vocabulary's names: \(cell(attention, in: app).label)")
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
        XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 5), "A stopped import can be removed")
        XCTAssertTrue(app.buttons["Get credits"].exists, "A credit-blocked import offers Get credits")
        XCTAssertFalse(app.buttons["Retry"].exists, "Nothing to retry until there are credits")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
        XCTAssertTrue(app.buttons["Remove"].waitForNonExistence(timeout: 5))
        tapHeader("Year", in: app)
        assertAbove(cell(dpo, in: app), cell(attention, in: app), "Year: newest first (2023 before 2017)")
        assertAbove(cell(attention, in: app), cell(resnet, in: app), "Year: 2017 before 2015")
        tapHeader("Year", in: app)
        XCTAssertEqual(header("Year", in: app).value as? String, "Sorted ascending")
        assertAbove(cell(resnet, in: app), cell(attention, in: app), "Year reversed: oldest first")
        tapHeader("Tags", in: app)
        XCTAssertEqual(header("Tags", in: app).value as? String, "Sorted ascending", "Tags A to Z")
        assertAbove(cell(dpo, in: app), cell(attention, in: app), "Alignment before Language")
        tapHeader("Progress", in: app)
        assertAbove(cell(resnet, in: app), cell(attention, in: app), "Progress: 100% before 60%")
        assertAbove(cell(attention, in: app), cell(dpo, in: app), "Progress: 60% before 25%")
        attach(app, "Library table sorted by Progress")

        tapHeader("Opened", in: app)
        assertAbove(cell(sample, in: app), cell(attention, in: app), "Opened: most recent first")
        // Arrow keys and Return (hardware keyboard) aren't checked here: XCUITest's typeKey didn't reach the table's
        // key commands in the Simulator (2026-10-07); they need a real keyboard on a device or the Mac.

        // Tapping a row opens it exactly like the list.
        XCTAssertTrue(cell(sample, in: app).waitForExistence(timeout: 5), "The table layout is kept")
        cell(sample, in: app).tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.segmentedControls.buttons["Reader"].isSelected)
        app.segmentedControls.buttons["Library"].tap()
        XCTAssertTrue(cell(sample, in: app).waitForExistence(timeout: 5), "The table layout is kept")

        // Portrait (11": 834 pt) keeps the table, without the Tags column.
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(header("Opened", in: app).waitForExistence(timeout: 5), "Portrait iPad keeps the table")
        XCTAssertTrue(header("Tags", in: app).exists, "Chosen Tags remains available by scrolling sideways")
        XCTAssertFalse(onScreen(header("Tags", in: app), in: app), "Tags starts past the edge at this width")
        attach(app, "Library table (iPad portrait)")
        choose("List", in: app)
        XCTAssertTrue(app.buttons["paper.\(sample)"].waitForExistence(timeout: 5))
    }

    /// Library options › Columns: turning columns on and off changes the table at once; one that doesn't fit says it
    /// scrolls sideways.
    func testColumnChooserTurnsColumnsOnAndOff() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(["--library-layout=table"])
        XCTAssertTrue(header("Year", in: app).waitForExistence(timeout: 5))
        app.buttons["Library options"].tap()
        let columns = app.buttons["Columns"].firstMatch
        XCTAssertTrue(columns.waitForExistence(timeout: 5)); columns.tap()
        XCTAssertTrue(app.navigationBars["Columns"].waitForExistence(timeout: 5))
        attach(app, "Column chooser")
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        // By identifier, else by the label's first word (iPadOS sheets don't always carry the identifier).
        func columnSwitch(_ id: String, _ title: String) -> XCUIElement {
            app.switches.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "library.columns.\(id)", title)).firstMatch
        }
        let year = columnSwitch("year", "Year"), pages = columnSwitch("pages", "Pages")
        XCTAssertTrue(year.waitForExistence(timeout: 5))
        XCTAssertEqual(year.value as? String, "1")
        toggle(year)
        XCTAssertEqual(year.value as? String, "0")
        // A partially visible row reports hittable even when its trailing switch is below the sheet's edge.
        let choices = app.collectionViews.firstMatch
        for _ in 0..<3 where !(pages.exists && pages.isHittable && choices.frame.insetBy(dx: 0, dy: 24).contains(pages.frame)) {
            choices.swipeUp()
        }
        XCTAssertEqual(pages.value as? String, "0")
        toggle(pages)
        XCTAssertEqual(pages.value as? String, "1")
        if phone {
            XCTAssertTrue(pages.label.contains("Scroll sideways to see it"), "Pages is on but scrolls in: \(pages.label)")
        }
        app.buttons["library.columns.done"].tap()
        XCTAssertTrue(app.navigationBars["Columns"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(header("Added", in: app).waitForExistence(timeout: 5), "Added in Year's place")
        XCTAssertFalse(header("Year", in: app).exists, "Year turned off never shows")
        // Pages scrolls in on a phone in portrait, as the chooser says.
        if phone {
            XCTAssertTrue(header("Pages", in: app).exists, "Every chosen column is in the table")
            XCTAssertFalse(onScreen(header("Pages", in: app), in: app), "Pages is past the edge until the columns scroll")
        }
        attach(app, "Table after choosing columns")

        // Restore defaults brings Year back.
        app.buttons["Library options"].tap()
        app.buttons["Columns"].firstMatch.tap()
        let restore = app.buttons["library.columns.restore"]
        XCTAssertTrue(app.navigationBars["Columns"].waitForExistence(timeout: 5))
        // At half height the sheet ends above Restore defaults.
        for _ in 0..<3 where !(restore.exists && restore.isHittable) { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(restore.waitForExistence(timeout: 5)); restore.tap()
        app.buttons["library.columns.done"].tap()
        XCTAssertTrue(header("Year", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(header("Pages", in: app).exists)
    }

    /// A toggle row's switch sits at its trailing end.
    private func toggle(_ row: XCUIElement) {
        let before = row.value as? String
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        if row.value as? String == before { row.switches.firstMatch.exists ? row.switches.firstMatch.tap() : row.tap() }
    }

    /// Filter chips scroll sideways on a phone: bring the chip into view, then tap it.
    private func tapChip(_ name: String, in app: XCUIApplication) {
        let chip = filter(name, in: app), bar = app.descendants(matching: .any)["library.filters"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "Chip \(name)")
        let window = app.windows.firstMatch.frame
        let visible = { window.contains(CGPoint(x: chip.frame.midX, y: chip.frame.midY)) && chip.frame.maxX <= window.maxX }
        for _ in 0..<2 where !visible() { bar.swipeLeft() }
        for _ in 0..<2 where !visible() { bar.swipeRight() }
        chip.tap()
    }

    /// Quick filters and the tag menu narrow the table; a failed download shows Retry, and Retry shows it running again.
    func testFiltersTagsAndRetryOnAFailedImport() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(["--library-layout=table", "--slow-import-fixture"])
        let failed = filter("failed", in: app)
        XCTAssertTrue(failed.waitForExistence(timeout: 5), "Failed chip")
        XCTAssertEqual(failed.value as? String, "2", "Two failed imports")
        XCTAssertFalse(cell(archived, in: app).exists, "Archived papers are left out of All")
        tapChip("failed", in: app)
        XCTAssertTrue(cell(downloadFailed, in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(cell(needsCredits, in: app).exists)
        XCTAssertFalse(cell(attention, in: app).exists, "Only failed imports")
        XCTAssertTrue(cell(downloadFailed, in: app).label.contains("Couldn’t download this paper"), cell(downloadFailed, in: app).label)
        let retry = app.buttons["library.import.retry.\(downloadFailed)"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "A visible Retry, not only in the menu")
        XCTAssertTrue(retry.isHittable)
        XCTAssertTrue(app.buttons["library.import.get-credits.\(needsCredits)"].exists, "Get credits beside a credit-blocked import")
        attach(app, "Failed filter with Retry")
        retry.tap()
        XCTAssertTrue(retry.waitForNonExistence(timeout: 5), "Retry gives way to the running import")
        let running = NSPredicate(format: "label CONTAINS %@", "Downloading")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: running, object: cell(downloadFailed, in: app))], timeout: 5),
                       .completed, "Downloading again at once: \(cell(downloadFailed, in: app).label)")
        attach(app, "Retried import downloading")

        tapChip("archived", in: app)
        XCTAssertTrue(cell(archived, in: app).waitForExistence(timeout: 5), "Archived papers under Archived")
        XCTAssertFalse(cell(downloadFailed, in: app).exists)
        tapChip("unread", in: app)
        XCTAssertTrue(cell(lora, in: app).waitForExistence(timeout: 5), "LoRA was never opened")
        XCTAssertFalse(cell(attention, in: app).exists, "Attention has been opened")
        tapChip("all", in: app)
        XCTAssertTrue(cell(attention, in: app).waitForExistence(timeout: 5))

        // Tags: the menu lists them, most used first; choosing one narrows the table.
        tapChip("tags", in: app)
        let alignment = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Alignment")).firstMatch
        XCTAssertTrue(alignment.waitForExistence(timeout: 5), "A paper's own tag is listed")
        attach(app, "Tag menu")
        alignment.tap()
        XCTAssertTrue(cell(dpo, in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(cell(attention, in: app).exists, "Only papers tagged Alignment")
        XCTAssertEqual(filter("tags", in: app).label, "Tag: Alignment")
        attach(app, "Tag filter")

        // Search filters the table live, within the filter.
        tapChip("tags", in: app)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "All tags")).firstMatch.tap()
        let search = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        search.tap(); search.typeText("residual")
        XCTAssertTrue(cell(resnet, in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(cell(attention, in: app).exists, "Search narrows the table as you type")
    }

    func testPhoneTableFitsPortraitAndAddsColumnsInLandscape() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone")
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch()
        choose("Table", in: app, screenshot: "Library options menu (iPhone)")
        XCTAssertTrue(app.descendants(matching: .any)["library.table"].waitForExistence(timeout: 5), "A real table in portrait")
        for title in ["Title", "Year", "Progress"] { XCTAssertTrue(onScreen(header(title, in: app), in: app), "Portrait shows \(title)") }
        for title in ["Added", "Opened", "Chats"] {
            XCTAssertFalse(onScreen(header(title, in: app), in: app), "\(title) scrolls in (or shows in landscape)")
        }
        // The order (Recent: the Added column) still shows while its column is hidden.
        let indicator = app.descendants(matching: .any)["library.table.sortIndicator"].firstMatch
        XCTAssertEqual(indicator.label, "Sorted by Added")
        XCTAssertEqual(indicator.value as? String, "Descending")
        // One element per row, reading every chosen column, including those too wide to show.
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
        XCTAssertEqual(header("Progress", in: app).value as? String, "Sorted ascending", "The second tap reverses")
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
