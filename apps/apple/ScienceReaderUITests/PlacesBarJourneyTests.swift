import XCTest

/// The bar with More and 🔍 (owner, 2026-10-25: Slack's "three at the bottom, a [fourth] icon with the words More… For the
/// fifth, it's a search icon"; docs/proposals/GLOBAL_SEARCH_AND_MORE.md A; JUDGMENT_LOG 13–16). iPhone: Library · Paper ·
/// Chat · More in the capsule, 🔍 its own circle beside it; More lists Feed, Snippets and Settings; Feed and Snippets open as
/// places with More highlighted, and More again returns to its list; Settings opens over the list. iPad upright: all six
/// places and 🔍 (IPadShapesJourneyTests covers the full bar and the Wide 🔍); a narrow iPad window: the iPhone's bar.
/// Screens are attached, and written to `GS_SCREENSHOT_DIR` when the runner sets it.
@MainActor
final class PlacesBarJourneyTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"
    private var phone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait; super.tearDown() }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture", "--feed-fixture",
                               "-appearance", "light"] + extra
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 15), "The fixture library")
        return app
    }

    private func wait(_ description: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                      _ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, description, file: file, line: line)
    }

    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let directory = ProcessInfo.processInfo.environment["GS_SCREENSHOT_DIR"], !directory.isEmpty {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let image = shot.image
            let format = UIGraphicsImageRendererFormat(); format.scale = image.scale
            let upright = image.imageOrientation == .up ? image
                : UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
            try? upright.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    private var device: String { phone ? "iphone" : "ipad" }

    /// The four-item capsule and the 🔍 circle: one row at the bottom, in this order, 🔍 its own circle 8 pt after More.
    private func assertCompactBar(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let ids = ["library", "paper", "chat", "more"]
        let items = ids.map { app.buttons["tab.\($0)"] }
        for (id, item) in zip(ids, items) { XCTAssertTrue(item.waitForExistence(timeout: 5), "The bar has \(id)", file: file, line: line) }
        for (left, right) in zip(items, items.dropFirst()) {
            XCTAssertEqual(left.frame.midY, right.frame.midY, accuracy: 1, "One row", file: file, line: line)
            XCTAssertLessThan(left.frame.maxX, right.frame.minX + 1, "\(left.label) before \(right.label)", file: file, line: line)
        }
        let search = app.buttons["tab.search"]
        XCTAssertTrue(search.exists, "🔍 beside the bar", file: file, line: line)
        XCTAssertEqual(search.label, "Search", file: file, line: line)
        XCTAssertEqual(search.frame.midY, items[3].frame.midY, accuracy: 2, "On the bar's row", file: file, line: line)
        // The capsule's 4 pt padding, then the 8 pt gap.
        XCTAssertEqual(search.frame.minX - items[3].frame.maxX, 12, accuracy: 3, "Its own circle, 8 pt after the capsule", file: file, line: line)
        XCTAssertEqual(search.frame.width, search.frame.height, accuracy: 1, "A circle", file: file, line: line)
        XCTAssertLessThanOrEqual(search.frame.maxX, app.frame.maxX - 15, "Inside the margin", file: file, line: line)
        for place in ["feed", "notes", "settings"] {
            XCTAssertFalse(app.buttons["tab.\(place)"].exists, "\(place) is under More, not in the bar", file: file, line: line)
        }
        XCTAssertEqual(items[3].label, "More", file: file, line: line)
    }

    // MARK: - iPhone

    func testThePhoneBarIsThreePlacesMoreAndSearch() throws {
        try XCTSkipUnless(phone, "The iPhone's bar (a narrow iPad window: testANarrowIPadWindowUsesThePhoneBar)")
        let app = launch()
        assertCompactBar(app)
        XCTAssertTrue(app.buttons["tab.library"].isSelected, "The app opens to the Library")
        XCTAssertFalse(app.buttons["tab.search"].isSelected)
        save("\(device)-bar")
        // Settings is in no ⋯ menu (JUDGMENT_LOG 15).
        app.buttons["Library options"].tap()
        XCTAssertTrue(element("Report this screen", app).waitForExistence(timeout: 5), "The ⋯ is open")
        XCTAssertFalse(app.buttons["menu.settings"].exists, "No Settings in the Library's ⋯")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        wait("The ⋯ closed") { !self.element("Report this screen", app).exists }
    }

    /// More lists Feed, Snippets and Settings; each opens; More stays highlighted (VoiceOver: "More, Feed"); More again
    /// returns to the list; Settings opens over the list and Done returns to it.
    func testMoreListsThreeAndOpensEach() throws {
        try XCTSkipUnless(phone, "The iPhone's More")
        let app = launch()
        let more = app.moreItem
        more.tap()
        let list = element("more.list", app)
        XCTAssertTrue(list.waitForExistence(timeout: 5), "More's list")
        XCTAssertTrue(app.navigationBars["More"].exists, "Titled More")
        wait("More is selected") { more.isSelected }
        let rows = ["feed", "notes", "settings"].map { app.buttons["tab.\($0)"] }
        for row in rows { XCTAssertTrue(row.waitForExistence(timeout: 3), "More lists \(row.identifier)") }
        XCTAssertEqual(rows.map(\.label), ["Feed", "Snippets", "Settings"], "One word each")
        for (above, below) in zip(rows, rows.dropFirst()) { XCTAssertLessThan(above.frame.minY, below.frame.minY) }
        XCTAssertGreaterThanOrEqual(rows[0].frame.height, 50, "Rows at least 52 pt (\(rows[0].frame.height))")
        save("\(device)-more")

        // Feed: the place, More still highlighted.
        rows[0].tap()
        XCTAssertTrue(app.buttons["Feed options"].waitForExistence(timeout: 10), "The Feed")
        XCTAssertFalse(list.exists, "Not pushed under More: the Feed itself")
        XCTAssertTrue(more.isSelected, "More stays highlighted")
        XCTAssertEqual(more.value as? String, "Feed", "VoiceOver reads More, Feed")
        XCTAssertFalse(app.buttons["tab.library"].isSelected)
        save("\(device)-feed-from-more")
        // More again: its list.
        more.tap()
        XCTAssertTrue(list.waitForExistence(timeout: 5), "More again returns to the list")
        XCTAssertFalse(app.buttons["Feed options"].exists)

        // Snippets.
        app.buttons["tab.notes"].tap()
        XCTAssertTrue(app.buttons["Snippets options"].waitForExistence(timeout: 10), "Snippets")
        XCTAssertTrue(more.isSelected)
        XCTAssertEqual(more.value as? String, "Snippets")
        more.tap()
        XCTAssertTrue(list.waitForExistence(timeout: 5))

        // Settings over the list; Done returns to it.
        app.buttons["tab.settings"].tap()
        let settings = app.navigationBars["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8), "Settings")
        save("\(device)-settings-from-more")
        settings.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
        XCTAssertTrue(list.waitForExistence(timeout: 5), "Done returns to More's list")
        XCTAssertTrue(more.isSelected)

        // Another place, then More: always its list.
        app.buttons["tab.chat"].tap()
        XCTAssertTrue(app.buttons["Chat options"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["tab.chat"].isSelected)
        XCTAssertFalse(more.isSelected)
        more.tap()
        XCTAssertTrue(list.waitForExistence(timeout: 5), "From another place More opens its list")
    }

    /// 🔍 is a place: selected while it shows, and the places take over again when chosen.
    func testSearchIsItsOwnCircle() throws {
        try XCTSkipUnless(phone, "The iPhone's bar")
        let app = launch()
        let search = app.buttons["tab.search"]
        search.tap()
        wait("🔍 selected") { search.isSelected }
        XCTAssertFalse(app.buttons["tab.library"].isSelected)
        XCTAssertFalse(app.moreItem.isSelected)
        save("\(device)-search")
        app.buttons["tab.library"].tap()
        wait("The Library again") { app.buttons["tab.library"].isSelected && !search.isSelected }
        XCTAssertTrue(app.buttons[sampleID].isHittable)
    }

    /// A phone sideways is still Tall, with the same bar (A.6).
    func testAPhoneSidewaysKeepsTheBar() throws {
        try XCTSkipUnless(phone, "iPhone landscape")
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        wait("Landscape") { app.frame.width > app.frame.height }
        sleep(1)
        assertCompactBar(app)
        save("\(device)-bar-landscape")
    }

    /// The largest accessibility text: the bar keeps its size (capped at xxxLarge, the Large Content Viewer shows more), its
    /// words stay whole, and More's rows grow.
    func testTheLargestTextKeepsTheBarWhole() throws {
        try XCTSkipUnless(phone, "The iPhone's bar")
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        assertCompactBar(app)
        let library = app.buttons["tab.library"]
        XCTAssertEqual(library.label, "Library")
        XCTAssertLessThanOrEqual(library.frame.height, 60, "The bar keeps its height")
        save("\(device)-bar-ax5")
        app.moreItem.tap()
        let feed = app.buttons["tab.feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(feed.frame.height, 60, "More's rows grow with the text (\(feed.frame.height))")
        save("\(device)-more-ax5")
    }

    // MARK: - iPad

    /// Too narrow for six (a Split View or Slide Over window, simulated by `--narrow-window=`): the iPhone's bar, More
    /// included. Settings is under More there too.
    func testANarrowIPadWindowUsesThePhoneBar() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "An iPad window")
        let app = launch(["--narrow-window=600"])
        assertCompactBar(app)
        XCTAssertFalse(app.placesMenu.exists, "Tall")
        save("\(device)-narrow-bar")
        app.moreItem.tap()
        XCTAssertTrue(element("more.list", app).waitForExistence(timeout: 5))
        app.buttons["tab.feed"].tap()
        XCTAssertTrue(app.buttons["Feed options"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.moreItem.isSelected)
        save("\(device)-narrow-feed-from-more")
    }

    /// Upright and full width: six places and 🔍 (the full bar), no More; ⌘1…⌘5, ⌘, and ⌘K work upright too (they were the
    /// Wide places menu's, so upright they did nothing).
    func testUprightIPadKeysChoosePlaces() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad upright")
        let app = launch()
        XCTAssertTrue(app.buttons["tab.settings"].waitForExistence(timeout: 5), "Six places")
        XCTAssertTrue(app.buttons["tab.search"].exists, "and 🔍")
        XCTAssertFalse(app.moreItem.exists, "No More")
        save("\(device)-upright-bar")
        // The first key event of a launch never runs a shortcut on the Simulator (IPadShapesJourneyTests): a letter first.
        element("library.search", app).tap()
        app.typeKey("x", modifierFlags: [])
        wait("A typed letter reaches the search field") { (self.element("library.search", app).value as? String) == "x" }
        app.buttons["library.search.cancel"].tap()
        app.typeKey("1", modifierFlags: .command)
        wait("⌘1 is Feed") { app.buttons["tab.feed"].isSelected }
        app.typeKey("5", modifierFlags: .command)
        wait("⌘5 is Snippets") { app.buttons["tab.notes"].isSelected }
        app.typeKey("k", modifierFlags: .command)
        wait("⌘K is Search") { app.buttons["tab.search"].isSelected }
        app.typeKey("2", modifierFlags: .command)
        wait("⌘2 is Library") { app.buttons["tab.library"].isSelected }
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8), "⌘, opens Settings upright")
        app.navigationBars["Settings"].buttons["Done"].firstMatch.tap()
    }

    /// Sideways: the places menu holds all six, so no More; 🔍 sits beside it and is selected while Search shows, the
    /// places button then showing ≡ ("Places, Search").
    func testSidewaysSearchSitsBesideThePlaces() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad sideways")
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        wait("The places menu in the corner") { app.placesMenu.exists }
        let search = app.buttons["tab.search"]
        XCTAssertTrue(search.exists, "🔍 beside the places button")
        XCTAssertFalse(app.moreItem.exists, "No More sideways")
        search.tap()
        wait("Search is the place") { app.currentPlace == "Search" && search.isSelected }
        save("\(device)-wide-search")
        app.show("library")
        wait("The Library again") { app.currentPlace == "Library" && !search.isSelected }
    }
}
