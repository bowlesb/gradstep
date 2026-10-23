import XCTest
import UIKit

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

    func testSelectionChatIsLinkedToItsPassage() throws { try journey(.portrait) }

    /// The iPad split: the chat is beside the paper.
    func testTabletSplitLinksChatAndPassage() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Tablet split layout")
        try journey(.landscapeLeft)
        XCUIDevice.shared.portraitWhereSupported()
    }

    private func journey(_ orientation: UIDeviceOrientation) throws {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 15))
        // The phone's path (Tall); Wide has the paper beside its chat.
        let phone = !app.wideShape
        app.buttons[sampleID].tap()
        // Wide: opened from the Library it is Browse; ✕ closes the list (Read), as the journey began before.
        if !phone, app.buttons["library.panel.close"].waitForExistence(timeout: 3) { app.buttons["library.panel.close"].tap() }
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
        // The edit menu pages its items: "Explain in Chat" can be past its arrow.
        let explain = app.revealEditMenuItem("Explain in Chat")
        XCTAssertTrue(explain.waitForExistence(timeout: 5)); explain.tap()
        let title = app.buttons["chat.context"]
        let answer = app.tables["chat.transcript"].descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.text.")).element(boundBy: 1)
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "The fixture answers")
        // Titled by the action ("Explain · …"), or by the server's topic title once the chat's profiles have loaded
        // (2026-10-14; always so beside the paper on a wide screen, where the chat is already on screen).
        waitFor("The question is saved under a title", timeout: 10) {
            title.exists && (title.label.hasPrefix("Conversation: Explain · ") || title.label == "Conversation: Explainer for a persona paper")
        }
        let conversationTitle = String(title.label.dropFirst("Conversation: ".count))
        capture(app, "Explain chat from a passage")

        // 2. Back to the paper: the passage is underlined (screenshot), and a tap on it opens its chat.
        if phone {
            app.buttons["chat.returnToPaper"].tap()
            waitFor("The paper returns to the passage", passageVisible)
        } else {
            // Wide: Discuss. ✕ closes the chat (Read), so the tap on the mark visibly brings this conversation back.
            app.buttons["chat.close"].tap()
            waitFor("Read") { !title.exists }
            waitFor("The paper still shows the passage", passageVisible)
        }
        XCTAssertFalse(explain.exists)
        capture(app, "Passage with a chat is underlined")
        word().tap()
        if phone { XCTAssertTrue(app.buttons["chat.context"].waitForExistence(timeout: 5), "The chat tab opens") }
        waitFor("The mark opens its conversation") { title.exists && title.label == "Conversation: \(conversationTitle)" }
        XCTAssertFalse(explain.exists, "A tap on a mark is not a selection")

        // 3. Go to passage from the chat's "…" menu, after reading elsewhere.
        if phone { app.show("paper") }
        XCTAssertTrue(web.waitForExistence(timeout: 5))
        waitFor("The paper is open at the passage", passageVisible)
        web.swipeUp(); web.swipeUp(); web.swipeUp()
        waitFor("Read on, away from the passage") { !passageVisible() }
        if phone { app.show("chat") }
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
        if phone { app.show("chat") }
        let history = app.buttons["Chat history"]
        XCTAssertTrue(history.waitForExistence(timeout: 5)); history.tap()
        XCTAssertTrue(app.buttons["chat.history.options"].waitForExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "chat.history.", conversationTitle)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        capture(app, "All chats with the passage chat")
        row.press(forDuration: 1.2)
        let goFromHistory = app.buttons["Go to passage"]
        XCTAssertTrue(goFromHistory.waitForExistence(timeout: 5)); goFromHistory.tap()
        XCTAssertTrue(app.buttons["chat.history.options"].waitForNonExistence(timeout: 5))
        waitFor("All chats › Go to passage lands on it", timeout: 15, passageVisible)
        XCTAssertTrue(back.waitForExistence(timeout: 5))

        // 5. The underline in dark mode.
        if phone {
            app.show("settings")
            let dark = app.settingsTheme().buttons["Dark"]
            XCTAssertTrue(dark.waitForExistence(timeout: 5)); dark.tap()
            app.show("paper")
            waitFor("The paper keeps the passage it went to", passageVisible)
            capture(app, "Passage with a chat is underlined (dark)")
            app.show("settings")
            app.settingsTheme().buttons["Match device"].tap()
        }
    }
}
