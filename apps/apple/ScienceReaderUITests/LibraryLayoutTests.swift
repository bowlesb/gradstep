import XCTest

/// Library layouts (owner decision 2026-10-05): the List stays the default; "Table" is a sortable
/// table where there is room and detailed rows where there isn't. Synthetic fixture, no network.
@MainActor
final class LibraryLayoutTests: XCTestCase {
    private let sample = "aaaaaaaa-0000-0000-0000-000000000001"
    private let attention = "eeeeeeee-0000-0000-0000-000000000001"
    private let dpo = "eeeeeeee-0000-0000-0000-000000000002"
    private let resnet = "eeeeeeee-0000-0000-0000-000000000005"
    private let adam = "eeeeeeee-0000-0000-0000-000000000006"

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "--library-metadata-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["paper.\(sample)"].waitForExistence(timeout: 15), "The List is the default layout")
        return app
    }

    private func choose(_ item: String, in app: XCUIApplication, screenshot: String? = nil) {
        app.buttons["Sort and details"].tap()
        let button = app.buttons[item].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Menu item \(item)")
        if let screenshot {
            let menu = XCTAttachment(screenshot: app.screenshot()); menu.name = screenshot; menu.lifetime = .keepAlways; add(menu)
        }
        button.tap()
    }

    private func cell(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["library.table.paper/\(id)"].firstMatch
    }

    private func header(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[title].firstMatch
        return button.exists ? button : app.staticTexts[title].firstMatch
    }

    /// The table's pinned Title header spans the header row in the accessibility tree, so XCUI
    /// reports the other headers as covered; tap them where they are drawn.
    private func tapHeader(_ title: String, in app: XCUIApplication) {
        let element = header(title, in: app)
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Header \(title)")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func assertAbove(_ upper: XCUIElement, _ lower: XCUIElement, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(upper.waitForExistence(timeout: 5) && lower.exists, message, file: file, line: line)
        XCTAssertLessThan(upper.frame.minY, lower.frame.minY, message, file: file, line: line)
    }

    func testTableSortsByColumnHeadersAndOpensAPaper() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The table needs a wide container")
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        choose("Table", in: app, screenshot: "Sort and details menu (iPad)")
        XCTAssertTrue(app.descendants(matching: .any)["library.table"].waitForExistence(timeout: 5))
        XCTAssertTrue(cell(attention, in: app).waitForExistence(timeout: 5))
        let attached = XCTAttachment(screenshot: app.screenshot()); attached.name = "Library table"; attached.lifetime = .keepAlways; add(attached)

        // Recent first (as the List): Attention was added after DPO.
        assertAbove(cell(attention, in: app), cell(dpo, in: app), "Recent order")

        // Long-press keeps the list's row actions (disabled here: the fixture has no account).
        cell(attention, in: app).press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Remove from library"].waitForExistence(timeout: 5), "Paper row actions")
        let menu = XCTAttachment(screenshot: app.screenshot()); menu.name = "Table row actions"; menu.lifetime = .keepAlways; add(menu)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
        XCTAssertTrue(app.buttons["Remove from library"].waitForNonExistence(timeout: 5))
        app.descendants(matching: .any)["library.table.import/eeeeeeee-0000-0000-0000-000000000021"].firstMatch.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Cancel import"].waitForExistence(timeout: 5), "Import row actions")
        XCTAssertTrue(app.buttons["Retry import"].exists, "A failed import offers Retry")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
        XCTAssertTrue(app.buttons["Cancel import"].waitForNonExistence(timeout: 5))
        tapHeader("Year", in: app)
        assertAbove(cell(dpo, in: app), cell(attention, in: app), "Year: newest first (2023 before 2017)")
        assertAbove(cell(attention, in: app), cell(resnet, in: app), "Year: 2017 before 2015")
        tapHeader("Year", in: app)
        assertAbove(cell(resnet, in: app), cell(attention, in: app), "Year reversed: oldest first")
        tapHeader("Read", in: app)
        assertAbove(cell(resnet, in: app), cell(attention, in: app), "Read: 100% before 60%")
        assertAbove(cell(attention, in: app), cell(dpo, in: app), "Read: 60% before 25%")
        let sorted = XCTAttachment(screenshot: app.screenshot()); sorted.name = "Library table sorted by Read"; sorted.lifetime = .keepAlways; add(sorted)

        // Tapping a row opens it exactly like the list.
        cell(sample, in: app).tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.segmentedControls.buttons["Reader"].isSelected)
        app.segmentedControls.buttons["Library"].tap()
        XCTAssertTrue(cell(sample, in: app).waitForExistence(timeout: 5), "The table layout is kept")
        choose("List", in: app)
        XCTAssertTrue(app.buttons["paper.\(sample)"].waitForExistence(timeout: 5))
    }

    func testDetailedRowsOnPhoneSortAndOpenAPaper() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone portrait is the narrow form")
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        choose("Detailed rows", in: app, screenshot: "Sort and details menu (iPhone)")
        let row = app.buttons["paper.\(attention)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Vaswani, Shazeer +6"), row.label)
        XCTAssertTrue(row.label.contains("60% read"), row.label)
        XCTAssertTrue(row.label.contains("2 chats"), row.label)
        XCTAssertFalse(app.descendants(matching: .any)["library.table"].exists, "No table in a narrow container")

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

    func testPhoneLandscapeShowsTheTable() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone landscape")
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch()
        choose("Detailed rows", in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.descendants(matching: .any)["library.table"].waitForExistence(timeout: 5), "Landscape is wide enough for the table")
        XCTAssertTrue(header("Opened", in: app).exists)
        let attached = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attached.name = "Phone landscape table"; attached.lifetime = .keepAlways; add(attached)
        tapHeader("Read", in: app)
        assertAbove(cell(resnet, in: app), cell(attention, in: app), "Read: 100% before 60%")
        tapHeader("Read", in: app)
        assertAbove(cell(adam, in: app), cell(dpo, in: app), "Read reversed: 8% before 25%")
        tapHeader("Opened", in: app)
        assertAbove(cell(sample, in: app), cell(attention, in: app), "Opened: most recent first")
        cell(sample, in: app).tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
    }
}
