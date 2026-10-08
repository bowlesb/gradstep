import XCTest

/// Model, effort and length in the chat, answer labels and topic titles (owner requests 2026-10-08), over
/// `--chat-fixture`: synthetic answers and the server's published profile table, no network or provider. Screens are
/// attached, and also written to `GS_SCREENSHOT_DIR` when the runner sets it (`TEST_RUNNER_GS_SCREENSHOT_DIR=…`).
@MainActor
final class ChatControlsTests: XCTestCase {
    private let sample = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    override func setUp() { continueAfterFailure = false }

    private func launch(_ appearance: String, _ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture",
                               "-appearance", appearance, "-chat.defaultProfile", "sonnet-low-standard"] + extra
        app.launch()
        XCTAssertTrue(app.buttons[sample].waitForExistence(timeout: 15))
        app.buttons["tab.chat"].tap()
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

    /// Open the control, change model, effort and length and watch the estimate follow; send; the answer names its
    /// settings, the chat gets its topic title, and All chats shows it; rename it there.
    func testChoosingModelEffortAndLengthAndTheTopicTitle() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            let control = app.buttons["chat.profile"]
            XCTAssertTrue(control.waitForExistence(timeout: 10))
            XCTAssertEqual(control.value as? String, "Sonnet · Low · Standard")
            let composer = any("chat.composer", app)
            XCTAssertLessThan(abs(control.frame.minX - composer.frame.minX), 40, "The control sits in the message box, under the text")
            control.tap()

            let estimate = app.staticTexts["chat.profile.estimate"]
            XCTAssertTrue(estimate.waitForExistence(timeout: 10), "The server's estimate shows once the table loads")
            XCTAssertEqual(estimate.label, "Usually 4–24 credits · up to 37")
            XCTAssertTrue(app.staticTexts["Answers in this chat"].exists)
            save("\(device())-\(appearance)-controls-default")

            app.segmentedControls["chat.profile.model"].buttons["Opus"].tap()
            XCTAssertEqual(estimate.label, "Usually 8–47 credits · up to 74")
            XCTAssertEqual(app.staticTexts["chat.profile.model.detail"].label, "Most capable; costs the most")
            app.segmentedControls["chat.profile.effort"].buttons["High"].tap()
            app.segmentedControls["chat.profile.length"].buttons["Detailed"].tap()
            XCTAssertEqual(estimate.label, "Usually 24–63 credits · up to 114")
            XCTAssertTrue(app.buttons["chat.profile.makeDefault"].exists, "A chat that differs from the defaults can become them")
            save("\(device())-\(appearance)-controls-opus")
            app.buttons["chat.profile.done"].tap()
            XCTAssertTrue(estimate.waitForNonExistence(timeout: 5))
            XCTAssertEqual(control.value as? String, "Opus · High · Detailed")

            composer.tap()
            composer.typeText("Why scale the attention logits?")
            if app.buttons["chat.dismissKeyboard"].waitForExistence(timeout: 2) { app.buttons["chat.dismissKeyboard"].tap() }
            app.buttons["chat.send"].tap()
            let label = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.answeredBy.")).firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 20), "The answer names the settings it was written with")
            XCTAssertEqual(label.label, "Answered with Opus · High · Detailed")
            let title = app.buttons["chat.context"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertEqual(title.label, "Conversation: Scaling in dot-product attention", "The chat is titled by its topic")
            XCTAssertEqual(control.value as? String, "Opus · High · Detailed", "The chat keeps its choice")
            save("\(device())-\(appearance)-answer-label-and-title")

            app.buttons["Chat history"].tap()
            XCTAssertTrue(app.navigationBars["All chats"].waitForExistence(timeout: 5))
            let row = app.buttons.matching(NSPredicate(format: "label == %@", "Scaling in dot-product attention")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "All chats shows the topic title")
            save("\(device())-\(appearance)-all-chats")
            if appearance == "light" {
                row.press(forDuration: 1.0)
                let rename = app.buttons["Rename…"]
                XCTAssertTrue(rename.waitForExistence(timeout: 5)); rename.tap()
                let field = app.alerts["Rename chat"].textFields.firstMatch
                XCTAssertTrue(field.waitForExistence(timeout: 5))
                field.tap()
                if let current = field.value as? String, !current.isEmpty {
                    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
                }
                field.typeText("My attention notes")
                app.alerts["Rename chat"].buttons["Save"].firstMatch.tap()
                XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "My attention notes")).firstMatch.waitForExistence(timeout: 5),
                              "A renamed chat shows its new title")
            }
            app.terminate()
        }
    }

    /// Settings › Chat defaults: new chats start with them; the row shows the choice.
    func testChatDefaultsInSettings() {
        let app = launch("light")
        app.buttons["tab.settings"].tap()
        let row = app.buttons["settings.chatDefaults"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("Sonnet · Low · Standard"))
        row.tap()
        XCTAssertTrue(app.navigationBars["Chat defaults"].waitForExistence(timeout: 5))
        let model = app.segmentedControls["chat.profile.model"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        model.buttons["Haiku"].tap()
        app.segmentedControls["chat.profile.length"].buttons["Brief"].tap()
        XCTAssertTrue(app.staticTexts["chat.profile.estimate"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["chat.profile.estimate"].label, "Usually 1–2 credits · up to 2")
        save("\(device())-light-chat-defaults")
        app.navigationBars["Chat defaults"].buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Haiku · Low · Brief"))
        app.buttons["tab.chat"].tap()
        app.buttons["New chat"].tap()
        XCTAssertEqual(app.buttons["chat.profile"].value as? String, "Haiku · Low · Brief", "A new chat starts with the defaults")
    }

    /// A server without profiles: the control says the choices couldn't load, and answers are asked exactly as before.
    func testWithoutTheServersTableNothingChanges() {
        let app = launch("light", ["--chat-fixture-no-profiles"])
        let control = app.buttons["chat.profile"]
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        control.tap()
        XCTAssertTrue(app.buttons["chat.profile.retry"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["chat.profile.estimate"].exists, "No estimates without the server's table")
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
