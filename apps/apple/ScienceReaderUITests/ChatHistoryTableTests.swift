import XCTest

/// All chats as a table (owner request 2026-10-07) over `--chat-history-fixture`: thirty synthetic conversations in
/// the encrypted fixture store (no network). Newest first; headers sort and reverse; the quick filter, search, open,
/// long-press and delete.
@MainActor
final class ChatHistoryTableTests: XCTestCase {
    private let sample = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    private func launch() -> XCUIApplication {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture", "--chat-history-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[sample].waitForExistence(timeout: 15))
        if app.buttons["tab.chat"].exists { app.show("chat") } else { app.wideMode("General Chat").tap() }
        let history = app.buttons["Chat history"]
        XCTAssertTrue(history.waitForExistence(timeout: 5)); history.tap()
        XCTAssertTrue(options(app).waitForExistence(timeout: 5))
        // All leads the chips and is chosen (owner, build 57), even from the sample paper's chat.
        XCTAssertTrue(app.buttons["chat.history.filter.all"].isSelected)
        XCTAssertTrue(row(1, app).waitForExistence(timeout: 5))
        return app
    }

    /// The ≡ beside the search field (owner, build 57: no title, no Done).
    private func options(_ app: XCUIApplication) -> XCUIElement { app.buttons["chat.history.options"] }
    private func close(_ app: XCUIApplication) {
        options(app).tap()
        let close = app.buttons["chat.history.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()
        XCTAssertTrue(options(app).waitForNonExistence(timeout: 5))
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
        XCTAssertEqual(row(5, app).label, "Explain · Attention(Q, K, V)…", "A selection action's chat: its label and the passage, math readable")
        XCTAssertTrue((row(1, app).value as? String)?.contains("Attention Is All You Need") == true, "VoiceOver reads the paper too")
        attach("All chats, most recently used first")

        header("lastUsed", app).tap()
        XCTAssertEqual(header("lastUsed", app).value as? String, "Sorted ascending")
        // History saved before times were recorded counts as oldest, in the order it reached this device.
        assertAbove(row(29, app), row(30, app), "Untimed history first when reversed")
        assertAbove(row(30, app), row(28, app), "…then the oldest dated conversation")

        header("conversation", app).tap()
        assertAbove(row(27, app), row(17, app), "A–Z: “Batch norm…” before “Bottleneck…”")
        if header("messages", app).isHittable {
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

        let search = app.textFields["chat.history.search"]
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
        XCTAssertTrue(options(app).waitForNonExistence(timeout: 5))
        let reply = app.tables["chat.transcript"].descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "chat.message.text.", "What happens without the scaling?")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5), "The conversation opened")

        let history = app.buttons["Chat history"]
        XCTAssertTrue(history.waitForExistence(timeout: 5)); history.tap()
        // From a paper chat, All chats offers that paper's chats after All.
        XCTAssertTrue(app.buttons["chat.history.filter.thisPaper"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chat.history.filter.all"].isSelected)
        XCTAssertTrue(row(4, app).waitForExistence(timeout: 5))
        row(4, app).press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Delete conversation"].waitForExistence(timeout: 5))
        let openPaper = app.buttons["Open paper"]
        XCTAssertTrue(openPaper.exists)
        attach("All chats row actions")
        openPaper.tap()
        XCTAssertTrue(options(app).waitForNonExistence(timeout: 5))
    }

    /// Owner feedback, build 14 #7: selection-action chats are titled by the action and the passage, in the table and in
    /// the chat itself.
    func testSelectionActionChatsHaveShortTitles() {
        let app = launch()
        XCTAssertTrue(row(8, app).waitForExistence(timeout: 5))
        XCTAssertEqual(row(8, app).label, "Define · m̂_t / (√v̂_t)")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Explain in plain terms")).firstMatch.exists)
        row(8, app).tap()
        XCTAssertTrue(options(app).waitForNonExistence(timeout: 5))
        let title = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Define · m̂_t / (√v̂_t)")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "The chat's title is the short one too")
        attach("Chat titled by its selection action")

        // Further down: a reference, found by searching its text (in all chats, not just this paper's).
        let history = app.buttons["Chat history"]
        XCTAssertTrue(history.waitForExistence(timeout: 5)); history.tap()
        XCTAssertTrue(app.buttons["chat.history.filter.all"].waitForExistence(timeout: 5)); app.buttons["chat.history.filter.all"].tap()
        let search = app.textFields["chat.history.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Wick")
        XCTAssertTrue(row(13, app).waitForExistence(timeout: 5))
        XCTAssertEqual(row(13, app).label, "Add paper · [3] T. D. Lee and G. C. Wick. Negative metric…")
    }

    /// A paper's own conversations (owner request 2026-10-07): the chat's title menu lists the paper's other chats, and
    /// All chats opened from a paper chat or the paper starts on "This paper", with its count.
    func testAPapersOwnChatsFromItsChatAndItsPaper() {
        let app = launch()
        row(1, app).tap()   // "Why scale the dot products…", about Attention Is All You Need (three chats: 1, 11, 22)
        XCTAssertTrue(options(app).waitForNonExistence(timeout: 5))

        let titleMenu = app.buttons["chat.context"]
        XCTAssertTrue(titleMenu.waitForExistence(timeout: 5)); titleMenu.tap()
        let other = app.buttons[String(format: "chat.paperChat.c4a7c4a7-0000-4000-8000-%012ld", 22)]
        XCTAssertTrue(other.waitForExistence(timeout: 5), "The paper's other chats are in the title menu")
        XCTAssertTrue(app.buttons[String(format: "chat.paperChat.c4a7c4a7-0000-4000-8000-%012ld", 11)].exists)
        XCTAssertFalse(app.buttons[String(format: "chat.paperChat.c4a7c4a7-0000-4000-8000-%012ld", 1)].exists, "Not the open one")
        XCTAssertTrue(app.buttons["chat.paperChats.all"].label.contains("All 3 chats about this paper"))
        XCTAssertTrue(app.buttons["Paper chat"].exists && app.buttons["General chat"].exists, "The Paper / General switch stays")
        attach("Chat title menu: chats about this paper")
        other.tap()
        let title = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Multi-head attention: why split into heads?")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "The other chat opened")

        app.buttons["Chat history"].tap()
        XCTAssertTrue(options(app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["All chats"].exists, "No title bar: the search field and ≡ are the top")
        XCTAssertFalse(app.buttons["Done"].exists, "Close is in ≡")
        let thisPaper = app.buttons["chat.history.filter.thisPaper"]
        XCTAssertTrue(thisPaper.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chat.history.filter.all"].isSelected, "All is the default (owner, build 57)")
        XCTAssertLessThan(app.buttons["chat.history.filter.all"].frame.minX, thisPaper.frame.minX, "All leads the chips")
        thisPaper.tap()
        XCTAssertEqual(count(app), "3 of 30 chats", "The count says how many are this paper's")
        XCTAssertLessThanOrEqual(app.buttons["chat.history.filter.general"].frame.maxX, app.windows.firstMatch.frame.maxX - 15,
                                 "All four chips fit on the phone")
        XCTAssertTrue(row(1, app).exists && row(11, app).exists && row(22, app).exists)
        XCTAssertFalse(row(2, app).exists, "Other chats are filtered out")
        assertAbove(row(1, app), row(22, app), "Most recently used first, as everywhere")
        attach("All chats opened from a paper: This paper")
        app.buttons["chat.history.filter.all"].tap()
        XCTAssertEqual(count(app), "30 chats", "One tap shows everything")
        close(app)

        // From the paper itself: its options list its chats, opening on This paper.
        app.show("paper")
        let paperOptions = app.buttons["Paper options"]
        XCTAssertTrue(paperOptions.waitForExistence(timeout: 5)); paperOptions.tap()
        let chats = app.buttons["paper.chats"]
        XCTAssertTrue(chats.waitForExistence(timeout: 5))
        XCTAssertTrue(chats.label.contains("Chats about this paper"), chats.label)
        chats.tap()
        XCTAssertTrue(options(app).waitForExistence(timeout: 5))
        XCTAssertEqual(count(app), "3 of 30 chats", "The paper's own Chats about this paper opens on them")

        // General chat and the Library open All chats unfiltered, without the chip.
        close(app)
        app.show("library")
        app.buttons["Library options"].tap()
        app.buttons["All chats"].tap()
        XCTAssertTrue(options(app).waitForExistence(timeout: 5))
        XCTAssertEqual(count(app), "30 chats")
        XCTAssertFalse(app.buttons["chat.history.filter.thisPaper"].exists)
    }

    /// Delete is on the row's long-press menu; a sideways swipe offers it too while the columns don't scroll sideways
    /// (iPhone portrait with the default columns scrolls them, so the swipe moves the columns there).
    func testDeletingAConversationAsksFirstAndRemovesIt() {
        let app = launch()
        let target = row(3, app)
        let menuDelete = app.buttons["Delete conversation"].firstMatch, swipeDelete = app.buttons["Delete"].firstMatch
        func askToDelete() {
            target.swipeLeft()
            if swipeDelete.waitForExistence(timeout: 2) { swipeDelete.tap(); return }
            target.press(forDuration: 1.2)
            XCTAssertTrue(menuDelete.waitForExistence(timeout: 5)); menuDelete.tap()
        }
        askToDelete()
        let alert = app.alerts["Delete this conversation?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        attach("Delete confirmation")
        alert.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(target.exists, "Cancel keeps it")
        XCTAssertEqual(count(app), "30 chats")

        askToDelete()
        XCTAssertTrue(alert.waitForExistence(timeout: 5)); alert.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(target.waitForNonExistence(timeout: 5))
        XCTAssertEqual(count(app), "29 chats")
    }
}
