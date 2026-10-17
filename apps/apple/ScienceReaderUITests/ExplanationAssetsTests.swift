import XCTest

/// Settings › Your assets › Equation explanations and Figure explanations (owner, build 62): the explanations kept on
/// this device, each with its paper; a row opens the paper at that equation or figure, where the kept explanation shows
/// without a new request.
@MainActor
final class ExplanationAssetsTests: XCTestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func launch(_ mode: String, reset: Bool) -> XCUIApplication {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-mode=\(mode)", "--chat-fixture-consented", "--study-fixture"]
            + (reset ? ["--reset-draft-fixture"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["tab.paper"].waitForExistence(timeout: 10) || app.wideMode("Reader").exists)
        return app
    }

    /// The first of these that exists (names that other work may change).
    private func first(_ candidates: [XCUIElement], timeout: TimeInterval = 5) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let found = candidates.first(where: { $0.exists }) { return found }
            usleep(200_000)
        } while Date() < deadline
        return candidates[0]
    }

    /// Settings › Your assets › the list (Settings is a lazy list: scroll until the row exists).
    private func openList(_ app: XCUIApplication, _ identifier: String) {
        app.show("settings")
        let row = app.buttons[identifier]
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.exists, "\(identifier) in Your assets"); row.tap()
    }

    func testAnEquationExplanationIsListedAndOpensItsEquation() throws {
        var app = launch("equation", reset: true)
        app.show("paper")
        let web = app.webViews.firstMatch
        let number = web.staticTexts["(1)"].firstMatch
        XCTAssertTrue(number.waitForExistence(timeout: 15)); number.tap()
        // "Equation" in the menu, "AI Explainer" once renamed (owner, build 62).
        var item = app.revealEditMenuItem("AI Explainer", timeout: 2)
        if !item.exists { item = app.revealEditMenuItem("Equation") }
        XCTAssertTrue(item.exists); item.tap()
        XCTAssertTrue(app.buttons["ai.chooseCloud"].waitForExistence(timeout: 5)); app.buttons["ai.chooseCloud"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["equation.symbol.1"].waitForExistence(timeout: 10), "The explanation")

        // A new launch keeps what this device kept.
        app.terminate()
        app = launch("equation", reset: false)
        openList(app, "settings.equationExplanations")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "explanations.equation.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "The kept explanation is listed")
        XCTAssertTrue(row.label.contains("Equation (1)"), row.label)
        capture(app, "Your assets: equation explanations")
        row.tap()
        sleep(3); capture(app, "After tapping an equation explanation")
        XCTAssertTrue(app.descendants(matching: .any)["equation.symbol.1"].waitForExistence(timeout: 15),
                      "The paper opens at the equation, its kept explanation shown without asking again")
        capture(app, "An equation explanation from Your assets")
    }

    func testAFigureExplanationIsListedAndOpensItsFigure() throws {
        var app = launch("figure_walkthrough", reset: true)
        app.show("paper")
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["(1)"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["Table of contents"].tap()
        XCTAssertTrue(app.contentsTabs.waitForExistence(timeout: 5))
        app.contentsTab("Figures").tap()
        let figure = app.buttons["contents.figure.0"]
        XCTAssertTrue(figure.waitForExistence(timeout: 5)); figure.tap()
        let explain = first([app.buttons["figureView.explain"], app.buttons["AI Explainer"]])
        XCTAssertTrue(explain.exists); explain.tap()
        XCTAssertTrue(app.buttons["ai.chooseCloud"].waitForExistence(timeout: 5)); app.buttons["ai.chooseCloud"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["figureView.section.1"].waitForExistence(timeout: 10), "The walkthrough")

        app.terminate()
        app = launch("figure_walkthrough", reset: false)
        openList(app, "settings.figureExplanations")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "explanations.figure.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "The kept walkthrough is listed")
        XCTAssertTrue(row.label.contains("Figure 1"), row.label)
        capture(app, "Your assets: figure explanations")
        row.tap()
        // The paper opens with that figure's page (its AI Explainer shows the kept walkthrough).
        XCTAssertTrue(first([app.buttons["figureView.explain"], app.buttons["AI Explainer"]], timeout: 15).exists,
                      "The paper opens at the figure")
        capture(app, "A figure explanation from Your assets")
    }

    func testEmptyListsSayNone() throws {
        let app = launch("answer", reset: true)
        app.show("settings")
        let row = app.buttons["settings.equationExplanations"]
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.label.contains("None"), row.label)
        XCTAssertTrue(app.buttons["settings.figureExplanations"].label.contains("None"))
        capture(app, "Your assets: no explanations yet")
    }
}
