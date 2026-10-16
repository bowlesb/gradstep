import XCTest

/// Model, effort and length in the chat, answer labels and topic titles (owner requests 2026-10-08), over
/// `--chat-fixture`: synthetic answers and the server's published profile table, no network or provider. Screens are
/// attached, and also written to `GS_SCREENSHOT_DIR` when the runner sets it (`TEST_RUNNER_GS_SCREENSHOT_DIR=…`).
@MainActor
final class ChatControlsTests: XCTestCase {
    private let sample = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    override func setUp() { continueAfterFailure = false }

    private func launch(_ appearance: String, _ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture",
                               "-appearance", appearance, "-chat.defaultProfile", "sonnet-low-standard"] + extra
        app.launch()
        XCTAssertTrue(app.buttons[sample].waitForExistence(timeout: 15))
        app.show("chat")
        return app
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let directory = ProcessInfo.processInfo.environment["GS_SCREENSHOT_DIR"], !directory.isEmpty {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    private func any(_ identifier: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func device() -> String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    /// Keyboard focus in the message box (a starter already gives it; a second tap on iPad can take it away).
    private func focus(_ field: XCUIElement) {
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        // A sheet that just closed can still take the first tap on iPad: try again until the field has the focus.
        for _ in 0..<4 where XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: field)], timeout: 2) != .completed {
            field.tap()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: field)], timeout: 3), .completed, "The message box takes the focus")
    }

    private func answerOptions(_ app: XCUIApplication) {
        let menu = app.buttons["Chat options"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap()
        let item = app.buttons["chat.profile"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Answer options are in the chat's ⋯ menu (owner, build 57)"); item.tap()
    }

    /// Chat redesign (owner, build 57, 2026-10-16): an empty chat offers three starters above one pill message box; the
    /// ⋯ menu holds Answer options (model and length only; DeepSeek when the server lists it) and Study mode; About AI
    /// chat options shows the credit detail; the answer names model and length; All chats has search and ≡ on top.
    func testStartersAnswerOptionsAndTheTopicTitle() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance, ["--chat-fixture-auto-profiles"])
            let starters = app.descendants(matching: .any).matching(identifier: "chat.starters").firstMatch
            XCTAssertTrue(starters.waitForExistence(timeout: 10), "An empty chat shows starters")
            let first = app.buttons["chat.starter.0"]
            XCTAssertTrue(first.exists && app.buttons["chat.starter.1"].exists && app.buttons["chat.starter.2"].exists)
            XCTAssertFalse(app.buttons["chat.study.start"].exists, "Study moved to the ⋯ menu")
            let composer = any("chat.composer", app)
            XCTAssertEqual(composer.placeholderValue, "Ask anything about the paper")
            XCTAssertLessThan(first.frame.maxY, composer.frame.minY + 1, "The starters sit above the message box")
            save("\(device())-\(appearance)-empty-chat-starters")
            let question = first.label
            first.tap()
            XCTAssertEqual(composer.value as? String, question, "A starter fills the message box")
            XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.text.")).firstMatch.exists,
                           "Nothing is sent until the reader sends")
            if app.buttons["chat.dismissKeyboard"].waitForExistence(timeout: 2) {
                let dismiss = app.buttons["chat.dismissKeyboard"]
                XCTAssertLessThan(dismiss.frame.maxX, composer.frame.minX + 2, "Inside the pill, before the question")
                XCTAssertGreaterThan(app.buttons["chat.send"].frame.minX, composer.frame.maxX - 2, "Send inside the pill, after it")
                save("\(device())-\(appearance)-composer-with-keyboard")
                dismiss.tap()
            }
            // Clear the starter for the question below.
            focus(composer)
            composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: question.count + 2))
            if app.buttons["chat.dismissKeyboard"].waitForExistence(timeout: 2) { app.buttons["chat.dismissKeyboard"].tap() }

            answerOptions(app)
            let model = app.segmentedControls["chat.profile.model"]
            XCTAssertTrue(model.waitForExistence(timeout: 10))
            XCTAssertTrue(model.buttons["DeepSeek"].exists, "DeepSeek, as the server's table lists it")
            XCTAssertFalse(app.segmentedControls["chat.profile.effort"].exists, "Effort is chosen per question")
            XCTAssertFalse(app.staticTexts["chat.profile.estimate"].exists, "The estimate lives in About AI chat options")
            XCTAssertTrue(app.staticTexts["chat.profile.isDefault"].exists, "A new chat starts with the defaults")
            save("\(device())-\(appearance)-answer-options")
            model.buttons["DeepSeek"].tap()
            app.segmentedControls["chat.profile.length"].buttons["Detailed"].tap()
            XCTAssertEqual(app.staticTexts["chat.profile.model.detail"].label, "Low cost; processed by DeepSeek")
            XCTAssertTrue(app.buttons["chat.profile.makeDefault"].exists, "A chat that differs from the defaults can become them")
            app.buttons["chat.profile.about"].tap()
            XCTAssertTrue(app.navigationBars["About AI chat options"].waitForExistence(timeout: 5))
            let row = app.descendants(matching: .any).matching(identifier: "settings.aiChat.sonnet.standard").firstMatch
            for _ in 0..<4 where !row.waitForExistence(timeout: 1) { app.swipeUp() }
            XCTAssertTrue(row.exists)
            XCTAssertTrue(row.label.contains("Usually 4–24 credits · up to 41"), row.label)
            save("\(device())-\(appearance)-about-ai-chat-options")
            app.navigationBars["About AI chat options"].buttons.firstMatch.tap()
            app.buttons["chat.profile.done"].tap()
            XCTAssertTrue(model.waitForNonExistence(timeout: 5))

            focus(composer)
            composer.typeText("Why scale the attention logits?")
            if app.buttons["chat.dismissKeyboard"].waitForExistence(timeout: 2) { app.buttons["chat.dismissKeyboard"].tap() }
            app.buttons["chat.send"].tap()
            let label = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.answeredBy.")).firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 20), "The answer names the settings it was written with")
            XCTAssertEqual(label.label, "Answered with DeepSeek · Detailed")
            let title = app.buttons["chat.context"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertEqual(title.label, "Conversation: Scaling in dot-product attention", "The chat is titled by its topic")
            save("\(device())-\(appearance)-answer-label-and-title")

            app.buttons["Chat history"].tap()
            XCTAssertTrue(app.buttons["chat.history.options"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Done"].exists, "No Done: Close is in ≡")
            let chat = app.buttons.matching(NSPredicate(format: "label == %@", "Scaling in dot-product attention")).firstMatch
            XCTAssertTrue(chat.waitForExistence(timeout: 5), "All chats shows the topic title")
            save("\(device())-\(appearance)-all-chats")
            app.terminate()
        }
    }

    /// Settings › Default options for new chats (owner, build 59): the model and length right in Settings, the credit
    /// detail behind ⓘ (About AI chat options); new chats start with them.
    func testDefaultOptionsInSettings() {
        let app = launch("light", ["--chat-fixture-auto-profiles"])
        app.show("settings")
        XCTAssertTrue(app.staticTexts["Default options for new chats"].waitForExistence(timeout: 10) ||
                      app.otherElements["Default options for new chats"].exists)
        let model = app.segmentedControls["chat.profile.model"]
        XCTAssertTrue(model.waitForExistence(timeout: 10), "The model choice is in Settings itself")
        XCTAssertTrue(model.buttons["Sonnet"].isSelected)
        model.buttons["Haiku"].tap()
        app.segmentedControls["chat.profile.length"].buttons["Brief"].tap()
        save("\(device())-light-settings-default-options")
        app.buttons["settings.aiChatInfo"].tap()
        XCTAssertTrue(app.navigationBars["About AI chat options"].waitForExistence(timeout: 5))
        let haikuBrief = app.descendants(matching: .any).matching(identifier: "settings.aiChat.haiku.brief").firstMatch
        XCTAssertTrue(haikuBrief.waitForExistence(timeout: 5))
        XCTAssertTrue(haikuBrief.label.contains("Usually 1–2 credits · up to 2"), haikuBrief.label)
        save("\(device())-light-about-ai-chat-options")
        let deepseek = app.descendants(matching: .any).matching(identifier: "settings.aiChat.deepseek.standard").firstMatch
        for _ in 0..<5 where !deepseek.waitForExistence(timeout: 1) { app.swipeUp() }
        XCTAssertTrue(deepseek.exists, "DeepSeek's credits, as the server lists it")
        app.navigationBars["About AI chat options"].buttons.firstMatch.tap()
        app.show("chat")
        app.buttons["New chat"].tap()
        answerOptions(app)
        XCTAssertTrue(app.segmentedControls["chat.profile.model"].buttons["Haiku"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["chat.profile.model"].buttons["Haiku"].isSelected, "A new chat starts with the defaults")
        XCTAssertTrue(app.segmentedControls["chat.profile.length"].buttons["Brief"].isSelected)
    }

    /// A server without profiles: the options say they couldn't load, and answers are asked exactly as before.
    func testWithoutTheServersTableNothingChanges() {
        let app = launch("light", ["--chat-fixture-no-profiles"])
        answerOptions(app)
        XCTAssertTrue(app.buttons["chat.profile.retry"].waitForExistence(timeout: 10))
        save("\(device())-light-controls-unavailable")
        app.buttons["chat.profile.done"].tap()
        XCTAssertTrue(app.buttons["chat.profile.retry"].waitForNonExistence(timeout: 5))
        let composer = any("chat.composer", app)
        composer.tap(); composer.typeText("Why scale the attention logits?")
        if app.buttons["chat.dismissKeyboard"].waitForExistence(timeout: 2) { app.buttons["chat.dismissKeyboard"].tap() }
        app.buttons["chat.send"].tap()
        let answer = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "chat.message.text.", "synthetic fixture answer")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["chat.send"].waitForExistence(timeout: 10), "The answer finished")
        let label = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.answeredBy.")).firstMatch
        XCTAssertFalse(label.exists, "An older server reports no labels; none are invented")
        XCTAssertEqual(app.buttons["chat.context"].label, "Conversation: Why scale the attention logits?", "No title was asked for")
    }
}
