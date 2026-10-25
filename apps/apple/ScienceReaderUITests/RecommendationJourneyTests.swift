import XCTest

/// AI recommendations (docs/architecture/AI_RECOMMENDATIONS.md): a Library row's Recommend similar papers › Add 3
/// papers adds them at once and shows why each was chosen; Remove takes one back, Undo the rest, and the Library no
/// longer lists them. Scripted function events (`--recommend-fixture`): no account, network or provider. Screens are
/// attached, and also written to `GS_SCREENSHOT_DIR` when the runner sets it (`TEST_RUNNER_GS_SCREENSHOT_DIR=…`).
@MainActor
final class RecommendationJourneyTests: XCTestCase {
    private let attention = "eeeeeeee-0000-0000-0000-000000000001"
    private let added = ["2004.05150": "fb000000-0000-4000-8000-000000000001", "2001.04451": "fb000000-0000-4000-8000-000000000002",
                         "2006.04768": "fb000000-0000-4000-8000-000000000003"]

    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.portraitWhereSupported() }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "--library-metadata-fixture", "--recommend-fixture"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["paper.\(attention)"].waitForExistence(timeout: 15), "The fixture Library")
        return app
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let directory = ProcessInfo.processInfo.environment["GS_SCREENSHOT_DIR"], !directory.isEmpty {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// Long-press the paper, open Recommend similar papers and choose a count; the price is said before the tap.
    private func recommend(_ count: Int, in app: XCUIApplication, screenshot: String? = nil) {
        app.buttons["paper.\(attention)"].press(forDuration: 1.2)
        let menu = app.buttons["Recommend similar papers"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Under Find similar papers")
        XCTAssertTrue(app.buttons["Find similar papers"].exists)
        menu.tap()
        let choice = app.buttons[count == 1 ? "Add 1 paper" : "Add \(count) papers"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 credit"].exists, "The price before the tap")
        if let screenshot { save(screenshot) }
        choice.tap()
    }

    func testRecommendAddsThreeShowsWhyAndUndoRemovesThem() {
        let app = launch()
        recommend(3, in: app, screenshot: "recommend-menu-\(device)")
        XCTAssertTrue(app.navigationBars["Recommended papers"].waitForExistence(timeout: 5), "The sheet")
        let status = element("recommend.status", app)
        XCTAssertTrue(status.waitForExistence(timeout: 3), "Status while it runs")
        XCTAssertTrue(status.label.contains("Finding papers like") || status.label.contains("Choosing"), status.label)
        XCTAssertTrue(app.staticTexts["Like “Attention Is All You Need”"].exists)
        save("recommend-running-\(device)")

        // Each paper as it is added, with its reason; then what it cost.
        XCTAssertTrue(element("recommend.row.2004.05150", app).waitForExistence(timeout: 8))
        let footer = element("recommend.footer", app)
        XCTAssertTrue(footer.waitForExistence(timeout: 8))
        XCTAssertEqual(footer.label, "Added 3 papers · 1 credit")
        // The phone's sheet opens at half height; pull it up to see every row. A quick swipe sometimes doesn't take
        // (the sheet stays at half height, its last row past the screen's edge), so drag the bar to the top until the
        // sheet is large.
        if device == "iphone" {
            let bar = app.navigationBars["Recommended papers"]
            let large = NSPredicate { _, _ in bar.frame.minY < app.frame.height * 0.3 }
            for _ in 0..<3 where !large.evaluate(with: nil) {
                bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)))
                _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: large, object: nil)], timeout: 3)
            }
            XCTAssertTrue(large.evaluate(with: nil), "The sheet is pulled up (its bar at \(bar.frame.minY) pt)")
        }
        XCTAssertTrue(element("recommend.row.2006.04768", app).waitForExistence(timeout: 5))
        for source in added.keys { XCTAssertTrue(element("recommend.row.\(source)", app).exists, source) }
        XCTAssertTrue(app.staticTexts["Same attention, made sparse so it reaches long documents"].exists, "Why it was chosen")
        XCTAssertTrue(app.staticTexts["Replaces its dot-product attention with hashing to save memory"].exists)
        XCTAssertTrue(app.buttons["recommend.undo"].exists)
        // They are in the Library already (as imports being prepared).
        for id in added.values { XCTAssertTrue(element("import.\(id)", app).exists, "Library lists \(id)") }
        save("recommend-added-\(device)")

        // Remove one: its row says so and the Library no longer has it.
        app.buttons["recommend.remove.2004.05150"].tap()
        XCTAssertTrue(element("recommend.row.2004.05150", app).staticTexts["Removed"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("import.\(added["2004.05150"]!)", app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("import.\(added["2001.04451"]!)", app).exists, "Only that one")
        save("recommend-removed-one-\(device)")

        // Undo the rest, then Done: the Library is as before.
        app.buttons["recommend.undo"].tap()
        for source in ["2001.04451", "2006.04768"] {
            XCTAssertTrue(element("recommend.row.\(source)", app).staticTexts["Removed"].waitForExistence(timeout: 5), source)
        }
        XCTAssertTrue(app.buttons["recommend.undo"].waitForNonExistence(timeout: 5), "Nothing left to undo")
        save("recommend-undone-\(device)")
        app.buttons["recommend.done"].tap()
        XCTAssertTrue(app.navigationBars["Recommended papers"].waitForNonExistence(timeout: 5))
        for id in added.values { XCTAssertFalse(element("import.\(id)", app).exists, "Removed from the Library: \(id)") }
        XCTAssertTrue(app.buttons["paper.\(attention)"].exists, "The paper it started from stays")
    }

    /// The request's card sits directly under the sheet's title and stays where it is as the papers arrive (owner,
    /// TestFlight 92: "Little box appears too far down").
    func testTheCardSitsUnderTheTitleAndStaysPut() {
        let app = launch()
        recommend(3, in: app)
        let bar = app.navigationBars["Recommended papers"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let subtitle = app.staticTexts["Like “Attention Is All You Need”"]
        XCTAssertTrue(element("recommend.status", app).waitForExistence(timeout: 3), "Still running")
        XCTAssertTrue(subtitle.exists)
        let top = subtitle.frame.minY
        save("recommend-card-running-\(device)")
        // From the title's words (the bar's own frame reaches further down, under its scroll edge).
        let title = bar.staticTexts["Recommended papers"].firstMatch
        let gap = top - (title.exists ? title.frame.maxY : bar.frame.maxY)
        XCTAssertLessThan(gap, 48, "The card's first line is right under the title (\(gap) pt)")
        XCTAssertTrue(element("recommend.footer", app).waitForExistence(timeout: 8), "The papers arrived")
        XCTAssertTrue(element("recommend.row.2004.05150", app).exists)
        XCTAssertEqual(subtitle.frame.minY, top, accuracy: 1, "Nothing above the results moved")
        save("recommend-card-done-\(device)")
    }

    /// Closing the sheet early never stops the request: its papers still arrive in the Library.
    func testClosingTheSheetKeepsTheRequestRunning() {
        let app = launch(["-appearance", "dark"])
        recommend(1, in: app)
        XCTAssertTrue(app.navigationBars["Recommended papers"].waitForExistence(timeout: 5))
        app.buttons["recommend.done"].tap()
        XCTAssertTrue(app.navigationBars["Recommended papers"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("import.\(added["2004.05150"]!)", app).waitForExistence(timeout: 8), "Added with the sheet closed")
        save("recommend-library-after-close-dark-\(device)")
    }

    /// Twenty requests a day: said plainly, nothing to undo.
    func testDailyLimitIsSaidPlainly() {
        let app = launch(["--recommend-fixture-mode=daily_limit"])
        recommend(1, in: app)
        let footer = element("recommend.footer", app)
        XCTAssertTrue(footer.waitForExistence(timeout: 5))
        XCTAssertEqual(footer.label, "You’ve asked for recommendations 20 times today. Try again tomorrow.")
        XCTAssertFalse(app.buttons["recommend.undo"].exists); XCTAssertFalse(app.buttons["recommend.retry"].exists)
        XCTAssertTrue(element("recommend.row.2004.05150", app).waitForNonExistence(timeout: 1))
        save("recommend-daily-limit-\(device)")
        app.buttons["recommend.done"].tap()
        XCTAssertTrue(app.navigationBars["Recommended papers"].waitForNonExistence(timeout: 5))
    }
}
