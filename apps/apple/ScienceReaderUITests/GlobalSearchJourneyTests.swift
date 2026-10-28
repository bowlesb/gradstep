import XCTest

/// Global search (docs/architecture/GLOBAL_SEARCH.md; proposal docs/proposals/GLOBAL_SEARCH_AND_MORE.md B.5): typing shows
/// grouped results; a chat result opens the chat at its message; an explanation result opens it in its paper; "In this
/// paper" scopes the search; the last row runs ML paper search. Opened at launch with `--global-search` (the bar's 🔍, Cancel,
/// the words kept and ↑/↓ are in PlacesBarJourneyTests).
/// Fixtures: the encrypted draft account, `--chat-history-fixture`, `--snippets-fixture`, `--search-fixture` (a kept
/// equation explanation). Screenshots: `TEST_RUNNER_GS_SCREENSHOT_DIR`.
@MainActor
final class GlobalSearchJourneyTests: XCTestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let folder = ProcessInfo.processInfo.environment["GS_SCREENSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(device)-\(name).png"))
        }
    }

    private func wait(_ timeout: TimeInterval = 15, _ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: timeout) == .completed
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--draft-fixture", "--reset-draft-fixture", "--chat-history-fixture", "--snippets-fixture", "--search-fixture",
                               "--global-search"] + extra
        app.launch()
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout: 20), "Global search opens")
        return app
    }

    private func type(_ app: XCUIApplication, _ text: String) {
        let field = app.textFields["search.field"]
        field.tap()
        field.typeText(text)
    }

    private func firstRow(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.row.\(prefix)")).firstMatch
    }

    func testTypingShowsGroupedResults() throws {
        let app = launch()
        // Empty: the keyboard is up, and the ⓘ says what is searched.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The keyboard comes up with nothing typed")
        capture(app, "search-empty")
        type(app, "softm")
        // Chats, explanations and snippets each in their group, in the fixed order, as the word is typed.
        let chats = app.descendants(matching: .any)["search.group.chats"]
        let explanations = app.descendants(matching: .any)["search.group.explanations"]
        let snippets = app.descendants(matching: .any)["search.group.snippets"]
        XCTAssertTrue(wait { chats.exists && explanations.exists && snippets.exists }, "Grouped results for a prefix")
        XCTAssertLessThan(chats.frame.minY, explanations.frame.minY)
        XCTAssertLessThan(explanations.frame.minY, snippets.frame.minY)
        XCTAssertTrue(app.buttons["search.chip.chats"].exists, "Chips once there is a query")
        capture(app, "search-typing")
        // All shows a chat once ("+N more in this chat"); its chip lists every match.
        let field = app.textFields["search.field"]
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "dpo ")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", "search.row.message:", "search.row.conversation:"))
        XCTAssertTrue(wait { rows.count >= 1 })
        let collapsed = rows.count
        app.buttons["search.chip.chats"].tap()
        XCTAssertTrue(wait { rows.count > collapsed && rows.count >= 4 }, "The Chats chip lists every message (\(rows.count) after \(collapsed))")
        capture(app, "search-chats-chip")
        app.buttons["search.chip.all"].tap()
        // A typo: the closest word is searched, and the screen says so.
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "atention ")
        XCTAssertTrue(app.descendants(matching: .any)["search.correction"].waitForExistence(timeout: 10), "No exact matches · showing attention")
        capture(app, "search-typo")
    }

    func testAChatResultOpensTheChatAtItsMessage() throws {
        let app = launch()
        type(app, "langevin")
        let row = firstRow(app, "message:")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "A message matched")
        XCTAssertTrue(row.label.contains("Langevin"), row.label)
        let event = String(row.identifier.dropFirst("search.row.message:".count))
        capture(app, "search-chat-result")
        row.tap()
        let message = app.descendants(matching: .any)["chat.message.\(event)"]
        XCTAssertTrue(message.waitForExistence(timeout: 10), "The chat opened at its message")
        XCTAssertTrue(wait(5) { message.isHittable }, "The message is on screen")
        capture(app, "search-chat-landed")
    }

    func testAnExplanationResultOpensItInItsPaper() throws {
        let app = launch()
        type(app, "zanzibar")
        let row = firstRow(app, "equation:")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "The kept explanation matched")
        XCTAssertTrue(row.label.contains("Equation (1)"), row.label)
        capture(app, "search-explanation-result")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["equation.symbol.1"].waitForExistence(timeout: 15), "The kept explanation shows, without a request")
        capture(app, "search-explanation-opened")
    }

    func testInThisPaperScopesTheSearch() throws {
        let app = launch(["--global-search-scoped"])
        let scope = app.buttons["search.scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 10), "In this paper")
        type(app, "attention")
        let passages = app.descendants(matching: .any)["search.group.passages"]
        XCTAssertTrue(passages.waitForExistence(timeout: 15), "The open paper's passages")
        XCTAssertFalse(app.descendants(matching: .any)["search.group.papers"].exists, "Only this paper")
        capture(app, "search-scoped")
        scope.tap()
        XCTAssertTrue(wait { !passages.exists }, "The token removed: everything again")
    }

    /// iPad sideways: the results stay on the left and the picked chat shows on the right (Mail's two slots).
    func testWideShowsTheResultBesideTheList() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("The Wide shape is the iPad's sideways (and the Mac's)") }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--draft-fixture", "--reset-draft-fixture", "--chat-history-fixture", "--snippets-fixture", "--search-fixture",
                               "--global-search"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["search.pickPlaceholder"].waitForExistence(timeout: 5), "The right slot waits for a pick")
        type(app, "dpo")
        let row = firstRow(app, "conversation:").exists ? firstRow(app, "conversation:") : firstRow(app, "message:")
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        capture(app, "search-wide-typing")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.transcript"].waitForExistence(timeout: 10), "The chat beside the results")
        XCTAssertTrue(app.textFields["search.field"].exists, "The results stay")
        capture(app, "search-wide-picked")
    }

    func testTheLastRowSearchesMLPapers() throws {
        let app = launch(["--discover-fixture"])
        type(app, "diffusion policy robot")
        let ml = app.buttons["search.ml"]
        XCTAssertTrue(ml.waitForExistence(timeout: 10))
        XCTAssertTrue(ml.label.contains("diffusion policy robot"), ml.label)
        ml.tap()
        XCTAssertTrue(app.descendants(matching: .any)["discover.result.2610.03011"].waitForExistence(timeout: 10), "ML paper search ran the words")
        XCTAssertFalse(app.textFields["search.field"].exists, "Search closed on the Library's ML results")
        capture(app, "search-ml-handoff")
    }
}
