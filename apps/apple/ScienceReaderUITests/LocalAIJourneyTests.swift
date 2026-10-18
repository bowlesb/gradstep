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
        let options = app.buttons["ai.localOptions"]
        XCTAssertTrue(options.waitForExistence(timeout: 5)); options.tap()
        let local = app.buttons["ai.chooseLocal.qwen35-4b"]
        XCTAssertTrue(local.waitForExistence(timeout: 5)); local.tap()
    }
    func testCloudFailureExplainsBillingAndLetsTheReaderChangeModelHere() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-consented", "--chat-fixture-mode=provider_billing", "--reset-draft-fixture", "--study-fixture", "-chat.defaultProfile", "sonnet-low-standard"]
        app.launch(); app.show("paper")
        let equation = app.webViews.firstMatch.staticTexts["(1)"].firstMatch
        XCTAssertTrue(equation.waitForExistence(timeout: 15)); equation.tap()
        app.revealEditMenuItem("AI Explainer").tap()
        app.buttons["ai.cloudOptions"].tap()
        let cloud = app.buttons["ai.chooseCloud"]
        XCTAssertTrue(cloud.waitForExistence(timeout: 5))
        XCTAssertTrue(cloud.label.contains("Sonnet"), cloud.label)
        cloud.tap()
        let change = app.buttons["equation.changeAI"]
        XCTAssertTrue(change.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "provider account has insufficient funds")).firstMatch.exists)
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Provider balance failure with inline recovery"; capture.lifetime = .keepAlways; add(capture)
        change.tap()
        app.buttons["ai.cloudOptions"].tap()
        let picker = app.buttons["chat.profile.model.haiku"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.tap()
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
        XCTAssertTrue(app.buttons["ai.localOptions"].waitForExistence(timeout: 5))
        chooseLocal(app)
        XCTAssertTrue(app.descendants(matching: .any)["figureView.description"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["figureView.aiSource"].label.contains("(local)"))
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Local figure explanation"; capture.lifetime = .keepAlways; add(capture)
    }
    func testLocalEquationChoiceKeepsTheEquationAndStreamsAnExplanation() {
        let app = launch()
        app.webViews.firstMatch.staticTexts["(1)"].firstMatch.tap()
        app.revealEditMenuItem("AI Explainer").tap()
        chooseLocal(app)
        XCTAssertTrue(app.descendants(matching: .any)["equation.description"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["equation.aiSource"].label.contains("(local)"))
        // Reopen a sealed local answer without the inference fixture or any downloaded model.
        app.terminate()
        app.launchArguments = ["--chat-fixture", "--study-fixture"]
        app.launch(); app.show("settings")
        let assets = app.buttons["settings.equationExplanations"]
        for _ in 0..<8 where !(assets.exists && assets.isHittable && assets.frame.maxY < app.windows.firstMatch.frame.height - 100) { app.swipeUp() }
        XCTAssertTrue(assets.exists); assets.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "explanations.equation.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["equation.description"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["equation.aiSource"].label.contains("(local)"))
    }
    func testEquationFollowUpsStayBelowTheExplanationAndReopen() {
        let app = launch()
        app.webViews.firstMatch.staticTexts["(1)"].firstMatch.tap(); app.revealEditMenuItem("AI Explainer").tap(); chooseLocal(app)
        XCTAssertTrue(app.descendants(matching: .any)["equation.description"].waitForExistence(timeout: 8))
        let field = app.textViews["contextChat.composer"].exists ? app.textViews["contextChat.composer"] : app.textFields["contextChat.composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("Why squared?"); app.buttons["contextChat.send"].tap()
        let sent = app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@", "About Equation (1): Why squared?")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 8)); XCTAssertTrue(app.descendants(matching: .any)["equation.heading"].exists)
        XCTAssertFalse(app.buttons["Allow and get answer"].exists)
        let answers = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "contextChat.message.", "Assistant:"))
        XCTAssertTrue(answers.element(boundBy: 0).waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["contextChat.stop"].waitForNonExistence(timeout: 8))
        field.tap(); field.typeText("What if x is negative?"); app.buttons["contextChat.send"].tap()
        let follow = app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@", "About Equation (1): What if x is negative?")).firstMatch
        XCTAssertTrue(follow.waitForExistence(timeout: 8))
        let latestAnswer = answers.element(boundBy: 1)
        XCTAssertTrue(latestAnswer.waitForExistence(timeout: 8), "The second answer completes, not just the second question")
        XCTAssertTrue(app.buttons["contextChat.stop"].waitForNonExistence(timeout: 8))
        let visible = NSPredicate { _, _ in latestAnswer.exists && latestAnswer.frame.maxY <= field.frame.minY - 8 && latestAnswer.frame.maxY > 120 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visible, object: nil)], timeout: 5), .completed,
                       "The new turn is in view above the composer, not hidden below the keyboard")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Haiku · Standard · by Qwen")).firstMatch.exists)
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Equation with two local follow-ups"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["sheet.close"].tap()
        app.webViews.firstMatch.staticTexts["(1)"].firstMatch.tap(); app.revealEditMenuItem("Chat about Equation").tap()
        XCTAssertTrue(follow.waitForExistence(timeout: 8), "the same encrypted conversation reopens")
    }

    func testDictationOnlyFillsTheDraftAndModelsLiveInSettings() {
        let app = XCUIApplication(); app.launchArguments = ["--chat-fixture", "--dictation-fixture", "--local-ai-fixture", "--reset-draft-fixture", "--study-fixture"]
        app.launch(); app.show("chat"); app.buttons["chat.dictate"].tap()
        let field = app.textViews["chat.composer"].exists ? app.textViews["chat.composer"] : app.textFields["chat.composer"]
        XCTAssertEqual(field.value as? String, "Explain this result in simpler terms")
        XCTAssertFalse(app.buttons["chat.stop"].exists, "dictation never sends")
        XCTAssertTrue(app.buttons["chat.composerOptions"].exists)
        app.show("settings")
        let models = app.buttons["settings.localModels"]
        for _ in 0..<10 where !(models.exists && models.isHittable) { app.swipeUp() }
        XCTAssertTrue(models.exists); models.tap()
        let downloadedModel = app.buttons["ai.default.qwen35-4b"]
        for _ in 0..<10 where !(downloadedModel.exists && downloadedModel.isHittable) { app.swipeUp() }
        XCTAssertTrue(downloadedModel.exists)
        let evidence = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Device testing")).firstMatch
        for _ in 0..<10 where !(evidence.exists && evidence.isHittable) { app.swipeUp() }
        XCTAssertTrue(evidence.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format:"label CONTAINS[c] %@", "physical iPhone")).firstMatch.exists)
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Local model management and measured compatibility"; capture.lifetime = .keepAlways; add(capture)
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
