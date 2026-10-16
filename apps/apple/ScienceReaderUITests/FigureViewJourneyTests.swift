import XCTest

/// The figure view (owner, build 59; docs/architecture/FIGURE_VIEW.md): a figure page offers Explain and Ask in chat;
/// Explain walks through the figure part by part with a crop where a part points at a detail; a part's menu explains it
/// more simply (inline), shows it in the paper, or asks about it in chat. Kept answers show again without a request.
@MainActor
final class FigureViewJourneyTests: XCTestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func wait(_ timeout: TimeInterval = 8, _ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: timeout) == .completed
    }

    /// A menu's item: a button by identifier or title (iPhone, iPad), a menu item on the Mac.
    private func menuItem(_ app: XCUIApplication, _ identifier: String, _ title: String) -> XCUIElement {
        let byID = app.buttons[identifier]
        if byID.waitForExistence(timeout: 2) { return byID }
        let byTitle = app.buttons[title]
        if byTitle.exists { return byTitle }
        return app.menuItems[title]
    }

    /// A part's menu: a button on iPhone and iPad, a pop-up button on the Mac.
    private func partMenu(_ app: XCUIApplication, _ number: Int) -> XCUIElement {
        let id = "figureView.section.\(number).menu"
        let button = app.buttons[id]
        if button.exists { return button }
        let popUp = app.popUpButtons[id]
        if popUp.exists { return popUp }
        return app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func launch(appearance: String = "light") -> XCUIApplication {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-mode=figure_walkthrough", "--chat-fixture-consented", "--reset-draft-fixture", "--study-fixture",
                               "-appearance", appearance]
        app.launch()
        // The fixture selects its arXiv paper: the Paper tab on a phone, Reader in the wide layout.
        XCTAssertTrue(app.buttons["tab.paper"].waitForExistence(timeout: 10) || app.wideMode("Reader").exists)
        app.show("paper")
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 15), "The fixture opens the numbered HTML paper")
        XCTAssertTrue(web.staticTexts["(1)"].firstMatch.waitForExistence(timeout: 10), "The paper is ready")
        return app
    }

    /// Contents › Figures › Figure 1: the figure's own page.
    private func openFigureOne(_ app: XCUIApplication) {
        app.buttons["Table of contents"].tap()
        XCTAssertTrue(app.contentsTabs.waitForExistence(timeout: 5))
        app.contentsTab("Figures").tap()
        let row = app.buttons["contents.figure.0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.navigationBars["Figure 1"].waitForExistence(timeout: 5))
    }

    func testExplainWalksThroughAFigureWithCropsAndEachPartsMenu() throws {
        let app = launch()
        openFigureOne(app)
        // Owner, build 59 (as the equation view): nothing is asked of the AI on opening; Explain and Ask in chat side by side.
        let explain = app.buttons["figureView.explain"], ask = app.buttons["figureView.askInChat"]
        XCTAssertTrue(explain.waitForExistence(timeout: 5)); XCTAssertTrue(ask.exists)
        XCTAssertEqual(explain.frame.midY, ask.frame.midY, accuracy: 2, "side by side")
        XCTAssertFalse(app.descendants(matching: .any)["figureView.section.1"].exists)
        capture(app, "Figure page: Explain and Ask in chat")

        explain.tap()
        let first = app.descendants(matching: .any)["figureView.section.1"]
        XCTAssertTrue(first.waitForExistence(timeout: 8), "The walkthrough's parts")
        // Contents opens at half height on a phone; the walkthrough takes the full height.
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertTrue(wait(5) { app.navigationBars["Figure 1"].frame.minY < app.windows.firstMatch.frame.height * 0.25 },
                          "full height: \(app.navigationBars["Figure 1"].frame)")
        }
        XCTAssertTrue(app.descendants(matching: .any)["figureView.section.3"].exists, "every part")
        XCTAssertTrue(app.descendants(matching: .any)["figureView.summary"].exists, "what it shows")
        XCTAssertTrue(app.images["figureView.section.1.crop"].exists, "the left half, cropped from the paper's own image")
        XCTAssertFalse(app.images["figureView.section.2.crop"].exists, "a part without a box has no crop")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "credit")).firstMatch.exists, "no credit counts")
        capture(app, "Figure walkthrough")

        // "Back up a bit": the part again, more simply, under it.
        partMenu(app, 1).tap()
        menuItem(app, "figureView.simpler", "Explain more simply").tap()
        let simpler = app.descendants(matching: .any)["figureView.section.1.simpler"]
        XCTAssertTrue(simpler.waitForExistence(timeout: 8))
        XCTAssertTrue(wait { simpler.label.contains("synthetic fixture answer") }, "The simpler explanation streams in: \(simpler.label)")
        capture(app, "A part, more simply")

        // Show in the paper: the part's paragraph, the sheet gone.
        let second = partMenu(app, 2)
        #if targetEnvironment(macCatalyst)
        let page = app.scrollViews["figureView.walkthrough"]
        for _ in 0..<3 where !second.isHittable { page.scroll(byDeltaX: 0, deltaY: -300) }
        #else
        for _ in 0..<3 where !second.isHittable { app.swipeUp() }
        #endif
        second.tap()
        menuItem(app, "figureView.showInPaper", "Show in the paper").tap()
        XCTAssertTrue(app.navigationBars["Figure 1"].waitForNonExistence(timeout: 5), "The figure's sheet closes")
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["(1)"].firstMatch.waitForExistence(timeout: 5), "The paper is shown")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "doesn’t have")).firstMatch.waitForExistence(timeout: 2),
                       "The paragraph is found")
        if app.buttons["reader.citation.back"].exists { app.buttons["reader.citation.back"].tap() }

        // Reopened: the walkthrough and the simpler part kept on the device show at once, no new request.
        openFigureOne(app)
        app.buttons["figureView.explain"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 3), "kept walkthrough")
        XCTAssertTrue(app.descendants(matching: .any)["figureView.section.1.simpler"].exists, "kept simpler part")
        XCTAssertFalse(app.descendants(matching: .any)["figureView.loading"].exists)

        // Ask in chat about one part: the paper's chat, the part's text as the passage, nothing sent.
        partMenu(app, 1).tap()
        menuItem(app, "figureView.askAbout", "Ask in chat about this").tap()
        let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "The chat opens")
        XCTAssertTrue(wait(5) { (composer.value as? String ?? "").hasPrefix("About Figure 1, Left half [¶4]") },
                      "The composer starts with the part: \(composer.value as? String ?? "")")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.text.")).firstMatch.exists,
                       "nothing is sent")
        capture(app, "Ask in chat about a part")
    }

    /// The figure page's own Ask in chat: the figure's caption is the passage (in dark mode, with the walkthrough seen first).
    func testAskInChatFromTheFigurePage() throws {
        let app = launch(appearance: "dark")
        openFigureOne(app)
        capture(app, "Figure page, dark")
        app.buttons["figureView.explain"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["figureView.section.1"].waitForExistence(timeout: 8))
        capture(app, "Figure walkthrough, dark")
        app.navigationBars["Figure 1"].buttons.firstMatch.tap()
        let ask = app.buttons["figureView.askInChat"]
        XCTAssertTrue(ask.waitForExistence(timeout: 5)); ask.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "The chat opens")
        XCTAssertTrue(wait(5) { (composer.value as? String ?? "").hasPrefix("About Figure 1 [¶6]") },
                      "The composer starts with the figure: \(composer.value as? String ?? "")")
        capture(app, "Ask in chat from a figure")
    }
}
