#if targetEnvironment(macCatalyst)
import XCTest

/// The chat redesign on the Mac (owner, builds 57–59): starters in the paper's chat column above the one-pill message
/// box, a click fills the box without sending; the chat's ⋯ menu holds Answer options (Model and Length only, DeepSeek
/// as the server lists it). (Study mode joins the menu for a paper numbered on the device; the sample isn't.)
@MainActor
final class MacChatRedesignTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func save(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testStartersAndAnswerOptionsOnTheMac() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture", "--chat-fixture-auto-profiles",
                               "-chat.defaultProfile", "sonnet-low-standard"]
        app.launch()
        XCTAssertTrue(app.buttons["paper.aaaaaaaa-0000-0000-0000-000000000001"].waitForExistence(timeout: 15))
        app.wideMode("Reader").click()
        let first = app.buttons["chat.starter.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10), "The paper's empty chat shows starters")
        XCTAssertTrue(app.buttons["chat.starter.2"].exists)
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        XCTAssertEqual(composer.placeholderValue, "Ask anything about the paper")
        XCTAssertLessThan(first.frame.maxY, composer.frame.minY, "Starters sit above the message box")
        save(app, "mac-empty-chat-starters")
        let question = first.label
        first.click()
        XCTAssertEqual(composer.value as? String, question, "A starter fills the message box")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.text.")).firstMatch.exists,
                       "Nothing is sent until the reader sends")

        app.popUpButtons["Chat options"].click()
        let options = app.menuItems["Answer options…"]
        XCTAssertTrue(options.waitForExistence(timeout: 5), "Answer options are in the chat's ⋯ menu")
        options.click()
        let model = app.segmentedControls["chat.profile.model"]
        XCTAssertTrue(model.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["chat.profile.model.deepseek"].exists, "DeepSeek, as the server lists it")
        XCTAssertFalse(app.segmentedControls["chat.profile.effort"].exists, "Effort is chosen per question")
        XCTAssertTrue(app.buttons["chat.profile.model.sonnet"].isSelected)
        app.buttons["chat.profile.length.detailed"].click()
        XCTAssertTrue(app.buttons["chat.profile.makeDefault"].waitForExistence(timeout: 5), "A chat that differs from the defaults can become them")
        save(app, "mac-answer-options")
        app.buttons["chat.profile.done"].click()
        XCTAssertTrue(model.waitForNonExistence(timeout: 5))
    }
}
#endif
