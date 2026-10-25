import XCTest

/// A Feed card's details (owner, 2026-10-24: "if you click on the rest of the card, nothing happens. Instead I want the
/// screen to fill with a panel showing details of that paper that you can easily push down when done. Async, it could
/// start a search for related papers below"). Tall (iPhone, iPad upright): a tap anywhere on the card but its Full
/// abstract, Add and links opens a large sheet, swiped down when done. Wide (iPad sideways): the right slot shows the same
/// details. Related papers come from the Feed results on the device in fixture runs (no index, no network). Also the iPad's
/// upright List in two columns ("take the whole screen"). Screens are attached, and written to `GS_SCREENSHOT_DIR` when the
/// runner sets it.
@MainActor
final class FeedDetailTests: XCTestCase {
    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    private let opened = "2610.08448", openedTitle = "Cross-Tokenizer On-Policy Distillation for Reasoning Models"

    private func launch(layout: String, appearance: String = "light") -> XCUIApplication {
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

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    // MARK: Tall

    func testTallCardOpensDetailsWithRelatedPapersAndSwipesDownLight() throws { try tallDetails(appearance: "light") }
    func testTallCardOpensDetailsWithRelatedPapersAndSwipesDownDark() throws { try tallDetails(appearance: "dark") }

    private func tallDetails(appearance: String) throws {
        let app = launch(layout: "list", appearance: appearance)
        let card = element(app, "discover.result.\(opened)")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        save("\(device)-feed-list-\(appearance)")

        // Full abstract still expands in place: no details.
        let toggle = app.buttons["discover.abstract.\(opened)"]
        XCTAssertTrue(toggle.exists); toggle.tap()
        waitFor("expanded in place") { toggle.label == "Less" }
        XCTAssertFalse(element(app, "feed.detail").exists, "the abstract's control keeps its own tap")
        toggle.tap()
        waitFor("collapsed") { toggle.label == "Full abstract" }

        // The rest of the card opens the details, filling the screen.
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.1)).tap()
        let title = element(app, "feed.abstract.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the details")
        XCTAssertEqual(title.label, openedTitle)
        XCTAssertGreaterThan(element(app, "feed.detail").frame.height, app.frame.height * 0.85, "a large sheet")
        XCTAssertTrue(element(app, "feed.detail.authors").label.contains("Ana Costa"), "every author")
        XCTAssertTrue(element(app, "feed.detail.reason").label.contains("In your tag: byte-level LMs"), "why, the whole sentence")
        XCTAssertTrue(element(app, "feed.abstract.text").exists, "the whole abstract")
        XCTAssertTrue(app.buttons["feed.abstract.add"].exists, "Add")
        XCTAssertTrue(element(app, "feed.abstract.arxiv").exists, "View on arXiv")
        XCTAssertFalse(element(app, "discover.setup.\(opened)").exists, "opening adds nothing")

        // Related papers below, from the Feed results here: a shared author, then a shared specific topic.
        let related = element(app, "feed.related.2610.06120"), topic = element(app, "feed.related.2610.03543")
        for _ in 0 ..< 4 where !(related.exists && related.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(related.waitForExistence(timeout: 5), "related papers")
        XCTAssertTrue(related.label.contains("Same authors: Ana Costa") || app.staticTexts["Same authors: Ana Costa"].exists, related.label)
        XCTAssertTrue(topic.exists, "shares Tokenization")
        XCTAssertGreaterThan(topic.frame.minY, related.frame.minY, "best first")
        XCTAssertFalse(element(app, "feed.related.2610.04476").exists, "only generic topics shared: not related")
        save("\(device)-feed-detail-related-\(appearance)")

        // A related paper replaces the details; Back returns.
        topic.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
        waitFor("the related paper's details") { title.label == "Selective State Spaces Without Tokenizers" }
        let back = app.buttons["sheet.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 3), "Back to the paper before")
        back.tap()
        waitFor("back") { title.label == self.openedTitle }
        XCTAssertFalse(back.exists)
        app.swipeDown(velocity: .slow) // to the top of the details
        save("\(device)-feed-detail-\(appearance)")

        // Swiped down: the Feed again.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        waitFor("dismissed") { !self.element(app, "feed.detail").exists }
        XCTAssertTrue(card.isHittable, "the list as it was")
    }

    /// The table's rows open the same details; their abstract under the row is in the long-press menu.
    func testTallTableRowOpensDetails() throws {
        let app = launch(layout: "table")
        let row = element(app, "feed.table.2610.07767")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        let title = element(app, "feed.abstract.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Verifier-Guided GRPO Scales Mathematical Reasoning")
        XCTAssertTrue(element(app, "feed.related").exists)
        app.buttons["sheet.close"].tap()
        waitFor("closed") { !self.element(app, "feed.detail").exists }
    }

    // MARK: Wide

    func testWideShowsTheDetailsAndRelatedPapersInTheRightSlot() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        XCUIDevice.shared.orientation = .landscapeLeft
        for layout in ["list", "table"] {
            let app = launch(layout: layout)
            waitFor("landscape", timeout: 10) { app.frame.width > app.frame.height }
            let row = element(app, layout == "list" ? "discover.result.\(opened)" : "feed.table.\(opened)")
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).tap()
            let title = element(app, "feed.abstract.title")
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertEqual(title.label, openedTitle)
            XCTAssertGreaterThan(title.frame.minX, app.frame.width * 0.45, "in the right slot")
            XCTAssertFalse(app.buttons["sheet.close"].exists, "no sheet in Wide")
            let topic = element(app, "feed.related.2610.03543")
            for _ in 0 ..< 4 where !(topic.exists && topic.isHittable) {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.7)).press(forDuration: 0.05,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3)))
            }
            XCTAssertTrue(topic.waitForExistence(timeout: 5), "related papers in the pane")
            if layout == "list" { save("ipad-wide-feed-detail-related") }
            topic.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
            waitFor("the related paper") { title.label == "Selective State Spaces Without Tokenizers" }
            let back = app.buttons["feed.detail.back"]
            XCTAssertTrue(back.waitForExistence(timeout: 3)); back.tap()
            waitFor("back") { title.label == self.openedTitle }
            app.terminate()
        }
    }

    // MARK: iPad upright: the whole width

    func testIPadUprightListUsesTheWholeWidthLight() throws { try uprightGrid(appearance: "light") }
    func testIPadUprightListUsesTheWholeWidthDark() throws { try uprightGrid(appearance: "dark") }

    private func uprightGrid(appearance: String) throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad upright")
        let app = launch(layout: "list", appearance: appearance)
        waitFor("portrait", timeout: 10) { app.frame.width < app.frame.height }
        // A section of two papers sits side by side ("byte-level LMs": 2610.08448 and 2610.06120).
        let first = element(app, "discover.result.2610.08448"), second = element(app, "discover.result.2610.06120")
        XCTAssertTrue(first.waitForExistence(timeout: 15)); XCTAssertTrue(second.exists)
        XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 2, "two columns")
        XCTAssertLessThan(first.frame.minX, app.frame.width * 0.1, "no empty column on the left")
        XCTAssertGreaterThan(second.frame.maxX, app.frame.width * 0.85, "nor on the right")
        XCTAssertGreaterThan(first.frame.width, 360, "each about an iPhone row's width")
        save("ipad-portrait-feed-list-\(appearance)")
        // A card still opens its details.
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.1)).tap()
        XCTAssertTrue(element(app, "feed.abstract.title").waitForExistence(timeout: 5))
        save("ipad-portrait-feed-detail-\(appearance)")
    }
}
