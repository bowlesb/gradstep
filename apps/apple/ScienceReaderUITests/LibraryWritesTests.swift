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
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--library-v5-fixture"]
        app.launch()

        // The signed-in library (v5) has loaded its saved paper.
        let library = app.buttons["tab.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 30))
        library.tap()
        let saved = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Attention Is All You Need")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 30), "The v5 baseline reached the Library")

        let feed = app.buttons["tab.feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        feed.tap()
        let add = app.buttons["discover.add.2610.01234"]
        XCTAssertTrue(add.waitForExistence(timeout: 20), "The Feed lists the fixture's papers")
        XCTAssertTrue(wait(add, "isEnabled == true"), "Feed Add is enabled under the upload-capable library")
        XCTAssertTrue(app.buttons["discover.add.2610.02287"].isEnabled)
        save(app, "library-v5-feed-add-enabled")

        add.tap()
        let added = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "In library")).firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 20), "The added paper is marked In library")
        XCTAssertTrue(wait(add, "exists == false"))
        save(app, "library-v5-feed-in-library")

        library.tap()
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
