import XCTest

/// All chats as a table (owner request 2026-10-07) over `--chat-history-fixture`: thirty synthetic conversations in
/// the encrypted fixture store (no network). Newest first; headers sort and reverse; the quick filter, search, open,
/// long-press and delete.
@MainActor
final class ChatHistoryTableTests: XCTestCase {
    private let sample = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture", "--chat-history-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[sample].waitForExistence(timeout: 15))
        if app.buttons["tab.chat"].exists { app.buttons["tab.chat"].tap() } else { app.segmentedControls.buttons["General Chat"].tap() }
        let history = app.buttons["Chat history"]
        XCTAssertTrue(history.waitForExistence(timeout: 5)); history.tap()
        XCTAssertTrue(app.navigationBars["All chats"].waitForExistence(timeout: 5))
        XCTAssertTrue(row(1, app).waitForExistence(timeout: 5))
        return app
    }

    /// Fixture conversation `n`'s row.
    private func row(_ n: Int, _ app: XCUIApplication) -> XCUIElement {
        app.buttons[String(format: "chat.history.c4a7c4a7-0000-4000-8000-%012ld", n)]
    }

    private func header(_ field: String, _ app: XCUIApplication) -> XCUIElement {
        app.buttons["chat.history.header.\(field)"]
    }

    private func count(_ app: XCUIApplication) -> String { app.staticTexts["chat.history.count"].label }

    private func assertAbove(_ upper: XCUIElement, _ lower: XCUIElement, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(upper.waitForExistence(timeout: 5) && lower.waitForExistence(timeout: 5), message, file: file, line: line)
        XCTAssertLessThan(upper.frame.minY, lower.frame.minY, message, file: file, line: line)
    }

    private func attach(_ name: String) {
        let attached = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attached.name = name; attached.lifetime = .keepAlways; add(attached)
    }

    func testMostRecentlyUsedFirstAndHeadersSortAndReverse() {
        let app = launch()
        XCTAssertEqual(count(app), "30 chats")
        assertAbove(row(1, app), row(2, app), "Used 2 minutes ago before 35 minutes ago")
        assertAbove(row(2, app), row(3, app), "…before 2 hours ago")
        XCTAssertEqual(header("lastUsed", app).value as? String, "Sorted descending")
        XCTAssertEqual(row(1, app).label, "Why scale the dot products by the square root of d_k?", "The question is the row's label")
        XCTAssertTrue((row(1, app).value as? String)?.contains("Attention Is All You Need") == true, "VoiceOver reads the paper too")
        attach("All chats, most recently used first")

        header("lastUsed", app).tap()
        XCTAssertEqual(header("lastUsed", app).value as? String, "Sorted ascending")
        // History saved before times were recorded counts as oldest, in the order it reached this device.
        assertAbove(row(29, app), row(30, app), "Untimed history first when reversed")
        assertAbove(row(30, app), row(28, app), "…then the oldest dated conversation")

        header("conversation", app).tap()
        assertAbove(row(27, app), row(17, app), "A–Z: “Batch norm…” before “Bottleneck…”")
        if header("messages", app).exists {
            header("messages", app).tap()
            assertAbove(row(4, app), row(18, app), "Most messages first; equal counts by recency")
        }
    }

    func testFilterAndSearchNarrowTheTable() {
        let app = launch()
        app.buttons["chat.history.filter.general"].tap()
        XCTAssertEqual(count(app), "8 of 30 chats")
        XCTAssertFalse(row(1, app).exists, "A paper chat is hidden")
        XCTAssertTrue(row(2, app).exists)
        app.buttons["chat.history.filter.paper"].tap()
        XCTAssertEqual(count(app), "22 of 30 chats")
        app.buttons["chat.history.filter.all"].tap()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("DPO")
        let narrowed = NSPredicate { _, _ in app.staticTexts["chat.history.count"].label == "4 of 30 chats" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: narrowed, object: nil)], timeout: 5), .completed)
        XCTAssertTrue(row(4, app).exists && row(2, app).exists && row(15, app).exists && row(24, app).exists)
        attach("All chats searched for DPO")
        search.typeText(" transformer")
        XCTAssertTrue(app.staticTexts["No Results for “DPO transformer”"].waitForExistence(timeout: 5)
                      || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "No Results")).firstMatch.exists)
    }

    func testTapOpensTheConversationAndLongPressOffersItsPaper() {
        let app = launch()
        row(1, app).tap()
        XCTAssertTrue(app.navigationBars["All chats"].waitForNonExistence(timeout: 5))
        let reply = app.tables["chat.transcript"].descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "chat.message.text.", "What happens without the scaling?")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5), "The conversation opened")

        let history = app.buttons["Chat history"]
        XCTAssertTrue(history.waitForExistence(timeout: 5)); history.tap()
        XCTAssertTrue(row(4, app).waitForExistence(timeout: 5))
        row(4, app).press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Delete conversation"].waitForExistence(timeout: 5))
        let openPaper = app.buttons["Open paper"]
        XCTAssertTrue(openPaper.exists)
        attach("All chats row actions")
        openPaper.tap()
        XCTAssertTrue(app.navigationBars["All chats"].waitForNonExistence(timeout: 5))
    }

    func testDeletingAConversationAsksFirstAndRemovesIt() {
        let app = launch()
        let target = row(3, app)
        target.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5)); delete.tap()
        let alert = app.alerts["Delete this conversation?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        attach("Delete confirmation")
        alert.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(target.exists, "Cancel keeps it")
        XCTAssertEqual(count(app), "30 chats")

        target.swipeLeft()
        XCTAssertTrue(delete.waitForExistence(timeout: 5)); delete.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5)); alert.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(target.waitForNonExistence(timeout: 5))
        XCTAssertEqual(count(app), "29 chats")
    }
}
