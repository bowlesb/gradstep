import XCTest

/// Passage-linked conversations (docs/DECISIONS.md, "Passage-linked conversations"), over the encrypted local chat
/// fixture and the offline sample paper: select → Explain → back to the paper → the passage is underlined → a tap on
/// it opens its chat → Go to passage from the chat's menu and from All chats lands on it with Back.
@MainActor
final class PassageJourneyTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func waitFor(_ message: String, timeout: TimeInterval = 15, _ condition: @escaping () -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) {
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: timeout)
        XCTAssertEqual(result, .completed, message, file: file, line: line)
    }

    func testSelectionChatIsLinkedToItsPassage() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 15))
        let phone = app.buttons["tab.chat"].exists
        app.buttons[sampleID].tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 8))
        // The sample's first section is on its first screen.
        let paragraph = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A useful first pass identifies")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 20)); XCTAssertTrue(paragraph.isHittable)
        // A word in the paragraph, at the same place in it each time.
        func word() -> XCUICoordinate {
            web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: paragraph.frame.minX - web.frame.minX + 55, dy: paragraph.frame.minY - web.frame.minY + 18))
        }
        let passageVisible = { paragraph.exists && paragraph.isHittable && paragraph.frame.minY >= web.frame.minY - 4
            && paragraph.frame.minY < web.frame.maxY - 60 }

        // 1. Select → Explain: a chat titled by the action and the passage.
        word().press(forDuration: 1)
        let explain = app.buttons["reader.selection.define"]
        XCTAssertTrue(explain.waitForExistence(timeout: 5)); explain.tap()
        let title = app.buttons["chat.context"]
        waitFor("The question is saved as \"Explain · …\"", timeout: 10) { title.exists && title.label.hasPrefix("Conversation: Explain · ") }
        let conversationTitle = String(title.label.dropFirst("Conversation: ".count))
        let answer = app.tables["chat.transcript"].descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.text.")).element(boundBy: 1)
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "The fixture answers")
        capture(app, "Explain chat from a passage")

        // 2. Back to the paper: the passage is underlined (screenshot), and a tap on it opens its chat.
        if phone {
            app.buttons["chat.returnToPaper"].tap()
            waitFor("The paper returns to the passage", passageVisible)
        } else {
            // The chat is beside the paper; start another so the tap visibly brings this one back.
            app.buttons["New chat"].tap()
            waitFor("A new chat") { title.label == "Conversation: New chat" }
        }
        XCTAssertFalse(explain.exists)
        capture(app, "Passage with a chat is underlined")
        word().tap()
        if phone { XCTAssertTrue(app.buttons["chat.context"].waitForExistence(timeout: 5), "The chat tab opens") }
        waitFor("The mark opens its conversation") { title.exists && title.label == "Conversation: \(conversationTitle)" }
        XCTAssertFalse(explain.exists, "A tap on a mark is not a selection")

        // 3. Go to passage from the chat's "…" menu, after reading elsewhere.
        if phone { app.buttons["tab.paper"].tap() }
        XCTAssertTrue(web.waitForExistence(timeout: 5))
        waitFor("The paper is open at the passage", passageVisible)
        web.swipeUp(); web.swipeUp(); web.swipeUp()
        waitFor("Read on, away from the passage") { !passageVisible() }
        if phone { app.buttons["tab.chat"].tap() }
        app.buttons["Chat options"].tap()
        let go = app.buttons["Go to passage"]
        XCTAssertTrue(go.waitForExistence(timeout: 5)); go.tap()
        waitFor("Go to passage lands on it", timeout: 15, passageVisible)
        let back = app.buttons["reader.citation.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Back to where reading left off")
        capture(app, "Go to passage lands on the passage with Back")
        back.tap()
        waitFor("Back returns to where reading left off") { !passageVisible() && !back.exists }

        // 4. Go to passage from All chats (long-press the row).
        if phone { app.buttons["tab.chat"].tap() }
        let history = app.buttons["Chat history"]
        XCTAssertTrue(history.waitForExistence(timeout: 5)); history.tap()
        XCTAssertTrue(app.navigationBars["All chats"].waitForExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "chat.history.", conversationTitle)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        capture(app, "All chats with the passage chat")
        row.press(forDuration: 1.2)
        let goFromHistory = app.buttons["Go to passage"]
        XCTAssertTrue(goFromHistory.waitForExistence(timeout: 5)); goFromHistory.tap()
        XCTAssertTrue(app.navigationBars["All chats"].waitForNonExistence(timeout: 5))
        waitFor("All chats › Go to passage lands on it", timeout: 15, passageVisible)
        XCTAssertTrue(back.waitForExistence(timeout: 5))

        // 5. The underline in dark mode.
        if phone {
            app.buttons["tab.settings"].tap()
            let dark = app.segmentedControls["settings.theme"].buttons["Dark"]
            XCTAssertTrue(dark.waitForExistence(timeout: 5)); dark.tap()
            app.buttons["tab.paper"].tap()
            waitFor("The paper keeps the passage it went to", passageVisible)
            capture(app, "Passage with a chat is underlined (dark)")
            app.buttons["tab.settings"].tap()
            app.segmentedControls["settings.theme"].buttons["Match device"].tap()
        }
    }
}
