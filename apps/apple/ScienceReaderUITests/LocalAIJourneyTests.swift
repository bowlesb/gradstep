import XCTest

@MainActor final class LocalAIJourneyTests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--local-ai-fixture", "--reset-draft-fixture", "--study-fixture"]
        app.launch(); app.show("paper")
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["(1)"].firstMatch.waitForExistence(timeout: 15))
        return app
    }
    private func chooseLocal(_ app: XCUIApplication) {
        let local = app.buttons["ai.chooseLocal"]
        XCTAssertTrue(local.waitForExistence(timeout: 5)); local.tap()
    }
    func testCloudFailureExplainsBillingAndLetsTheReaderChangeModelHere() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-consented", "--chat-fixture-mode=provider_billing", "--reset-draft-fixture", "--study-fixture", "-chat.defaultProfile", "sonnet-low-standard"]
        app.launch(); app.show("paper")
        let equation = app.webViews.firstMatch.staticTexts["(1)"].firstMatch
        XCTAssertTrue(equation.waitForExistence(timeout: 15)); equation.tap()
        app.revealEditMenuItem("AI Explainer").tap()
        let cloud = app.buttons["ai.chooseCloud"]
        XCTAssertTrue(cloud.waitForExistence(timeout: 5))
        XCTAssertTrue(cloud.label.contains("Sonnet"), cloud.label)
        cloud.tap()
        let change = app.buttons["equation.changeAI"]
        XCTAssertTrue(change.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "provider account has insufficient funds")).firstMatch.exists)
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Provider balance failure with inline recovery"; capture.lifetime = .keepAlways; add(capture)
        change.tap()
        let picker = app.buttons["ai.cloudModel"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.tap(); app.buttons["Haiku"].tap()
        XCTAssertTrue(cloud.label.contains("Haiku"), cloud.label); cloud.tap()
        XCTAssertTrue(app.staticTexts["equation.summary"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["equation.aiSource"].label.contains("Haiku"))
    }

    func testLocalFigureChoiceReadsInTheExistingExplainerWithoutCloudConsent() {
        let app = launch()
        app.buttons["Table of contents"].tap()
        XCTAssertTrue(app.contentsTabs.waitForExistence(timeout: 5))
        app.contentsTab("Figures").tap()
        app.buttons["contents.figure.0"].tap()
        app.buttons["figureView.explain"].tap()
        XCTAssertTrue(app.buttons["ai.chooseCloud"].waitForExistence(timeout: 5))
        chooseLocal(app)
        XCTAssertTrue(app.descendants(matching: .any)["figureView.description"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["figureView.aiSource"].label.contains("Local AI"))
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Local figure explanation"; capture.lifetime = .keepAlways; add(capture)
    }
    func testLocalEquationChoiceKeepsTheEquationAndStreamsAnExplanation() {
        let app = launch()
        app.webViews.firstMatch.staticTexts["(1)"].firstMatch.tap()
        app.revealEditMenuItem("AI Explainer").tap()
        chooseLocal(app)
        XCTAssertTrue(app.descendants(matching: .any)["equation.description"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["equation.aiSource"].label.contains("Local AI"))
        // Reopen a sealed local answer without the inference fixture or any downloaded model.
        app.terminate()
        app.launchArguments = ["--chat-fixture", "--study-fixture"]
        app.launch(); app.show("settings")
        let assets = app.buttons["settings.equationExplanations"]
        for _ in 0..<8 where !(assets.exists && assets.isHittable) { app.swipeUp() }
        XCTAssertTrue(assets.exists); assets.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "explanations.equation.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["equation.description"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["equation.aiSource"].label.contains("Local AI"))
    }
    func testLocalChatChoiceThenSendNeedsNoCloudConsent() {
        let app = launch(); app.show("chat")
        let choice = app.buttons["ai.selection"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap(); chooseLocal(app)
        let field = app.textFields["chat.composer"].exists ? app.textFields["chat.composer"] : app.textViews["chat.composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("What is this paper about?")
        app.buttons["chat.send"].tap()
        let answer = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "This answer was generated on this device")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 8))
    }
}
