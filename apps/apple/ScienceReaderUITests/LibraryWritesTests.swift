import XCTest

/// Library writes on an upload-capable (full-v5) library (migration 042; owner feedback on
/// build 17: "The Add is all greyed out?"). `--library-v5-fixture` signs in an activated
/// account against a scripted v5 server: no network, hosted account or provider. Screens are
/// attached, and also written to `GS_SCREENSHOT_DIR` when the runner sets it.
@MainActor
final class LibraryWritesTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let directory = ProcessInfo.processInfo.environment["GS_SCREENSHOT_DIR"], !directory.isEmpty {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    private func wait(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 20) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }

    func testFeedAddIsEnabledUnderV5AndTheLibraryShowsTheAddedPaper() {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--library-v5-fixture", "--library-layout=table", "--feed-layout=table",
                               "--feed-columns=topic,published,authors,arxiv"]
        app.launch()

        // The signed-in library (v5) has loaded its saved paper. The tab bar on a phone, the mode control on a wide iPad.
        XCTAssertTrue(app.buttons["tab.library"].waitForExistence(timeout: 30) || app.wideMode("Library").exists)
        app.show("library")
        let saved = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Attention Is All You Need")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 30), "The v5 baseline reached the Library")

        app.show("feed")
        let add = app.buttons["discover.add.2610.01234"]
        XCTAssertTrue(add.waitForExistence(timeout: 20), "The Feed lists the fixture's papers")
        XCTAssertTrue(wait(add, "isEnabled == true"), "Feed Add is enabled under the upload-capable library")
        XCTAssertTrue(app.buttons["discover.add.2610.02287"].isEnabled)
        let row = app.descendants(matching: .any)["feed.table.2610.01234"].firstMatch
        let addX = add.frame.minX
        XCTAssertTrue(row.exists)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)))
        XCTAssertEqual(add.frame.minX, addX, accuracy: 1, "Add stays visible while the selected columns scroll")
        XCTAssertTrue(add.isHittable && add.isEnabled)
        save(app, "library-v5-feed-add-enabled")

        add.tap()
        // While it is set up, the app's loading sign (owner, build 58); a tap on it shows the Library. Once ready, the
        // checkmark ("In library").
        let setup = app.buttons["discover.setup.2610.01234"]
        let added = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "In library")).firstMatch
        XCTAssertTrue(setup.waitForExistence(timeout: 20) || added.exists, "The added paper shows its setup, or is ready")
        XCTAssertTrue(wait(add, "exists == false"))
        save(app, "library-v5-feed-setting-up")
        if setup.exists {
            setup.tap()
            XCTAssertTrue(wait(app.buttons["tab.library"], "isSelected == true") || app.wideMode("Library").isSelected || app.currentPlace == "Library",
                          "The loading sign shows the Library")
        } else {
            app.show("library")
        }
        // List rows expose their title as a child; table rows combine it into the
        // row's label. Query the visible title independently of that accessibility
        // grouping so the journey works with either saved layout preference.
        let title = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@",
            "Sparse Mixture-of-Experts Scaling Without Load-Balancing Losses")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20), "The Library shows the added paper")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier BEGINSWITH 'library.table.import/' OR identifier BEGINSWITH 'import.'")).firstMatch.exists,
            "The title belongs to the Library's imported row")
        XCTAssertFalse(app.staticTexts["Library changes are paused while this app finishes adopting the new sync version. Saved changes are preserved for review."].exists)
        save(app, "library-v5-library-shows-added-paper")
    }
}
