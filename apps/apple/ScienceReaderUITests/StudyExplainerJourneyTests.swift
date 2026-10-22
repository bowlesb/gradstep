import XCTest

/// Study mode, reworked (2026-10-22), and the paper's AI Explainer (docs/proposals/LEARNING_GUIDE.md), on the fixture
/// backend with the numbered fixture paper (`--study-fixture`): Enter Study Mode from the empty chat → a tutor turn → Hint
/// → Stop → the suggestions offer Study Mode again; Paper › … › AI Explainer streamed with its progress bar → a
/// background paragraph and Back → the diagram full size → Open in Chat; Settings › Your assets › Paper explanations
/// reopens it. Screenshots go to `GS_SCREENSHOT_DIR` (TEST_RUNNER_GS_SCREENSHOT_DIR) as well as the result bundle.
@MainActor
final class StudyExplainerJourneyTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let directory = ProcessInfo.processInfo.environment["GS_SCREENSHOT_DIR"], !directory.isEmpty {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
    private func device() -> String {
        #if targetEnvironment(macCatalyst)
        return "mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
    }
    private var appearance: String { ProcessInfo.processInfo.environment["GS_APPEARANCE"] ?? "light" }

    private func launch(reset: Bool = true, _ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-consented", "--study-fixture", "-appearance", appearance,
                               "-chat.defaultProfile", "sonnet-low-standard"] + (reset ? ["--reset-draft-fixture"] : []) + extra
        app.launch()
        XCTAssertTrue(app.buttons["tab.paper"].waitForExistence(timeout: 10) || app.wideMode("Reader").exists)
        return app
    }

    private func any(_ identifier: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    /// Answer text (selectable text views, or static texts): a narrow query, since the whole tree includes the paper's page.
    private func labelled(_ text: String, _ app: XCUIApplication) -> XCUIElement {
        let match = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
        let views = app.textViews.matching(match).firstMatch
        return views.waitForExistence(timeout: 1) ? views : app.staticTexts.matching(match).firstMatch
    }
    private func waitLabelled(_ text: String, _ app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat { if labelled(text, app).exists { return true } } while Date() < deadline
        return false
    }
    private func waitEnabled(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isEnabled == true"), object: element)],
                       timeout: timeout) == .completed
    }

    /// Moves a scrolling page: a swipe on a touch screen, the scroll wheel on the Mac.
    private func scroll(_ element: XCUIElement, down: Bool) {
        #if targetEnvironment(macCatalyst)
        element.scroll(byDeltaX: 0, deltaY: down ? -300 : 300)
        #else
        if down { element.swipeUp() } else { element.swipeDown() }
        #endif
    }

    /// The explainer's scrolling page (its scroll view, which has a hit point wherever it is scrolled).
    private func page(_ app: XCUIApplication) -> XCUIElement {
        app.scrollViews.containing(.any, identifier: "paperExplainer.paperTitle").firstMatch
    }

    /// The numbered fixture paper's chat: the Chat tab on a phone, the chat beside the paper in the wide layout.
    private func openPaperChat(_ app: XCUIApplication) {
        if app.buttons["tab.chat"].waitForExistence(timeout: 2) { app.buttons["tab.chat"].tap() } else { app.show("paper") }
    }

    func testStudyModeFromTheEmptyChatHintStopAndTheSuggestions() throws {
        let app = launch()
        openPaperChat(app)
        let entry = app.buttons["chat.starter.study"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Enter Study Mode is offered after the starters")
        XCTAssertTrue(entry.label.contains("Enter Study Mode"), entry.label)
        save("\(device())-\(appearance)-study-entry")
        entry.tap()
        // One tap sends the opening turn; the slim study row replaces the knowledge-map bar.
        XCTAssertTrue(any("chat.study.row", app).waitForExistence(timeout: 8), "the study row")
        XCTAssertTrue(waitLabelled("keep from the HTML", app), "the tutor's first question")
        XCTAssertFalse(labelled("check numbered blocks", app).exists, "the hidden notes never show")
        XCTAssertFalse(any("chat.study.view", app).exists, "no knowledge map")
        let hint = app.buttons["chat.study.hint"]
        XCTAssertTrue(waitEnabled(hint), "Hint once the tutor has asked")
        save("\(device())-\(appearance)-study-row")
        hint.tap()
        XCTAssertTrue(waitLabelled("Hint: think about what the paper says is numbered", app), "the tutor's hint")
        let explain = app.buttons["chat.study.explain"]
        XCTAssertTrue(waitEnabled(explain))
        explain.tap()
        XCTAssertTrue(waitLabelled("Is a figure’s caption one block or several", app), "the explanation and a light check")
        XCTAssertTrue(waitEnabled(app.buttons["chat.study.stop"]))
        save("\(device())-\(appearance)-study-explained")
        app.buttons["chat.study.stop"].tap()
        XCTAssertTrue(any("chat.study.row", app).waitForNonExistence(timeout: 5), "Stop leaves Study mode")
        // The newest answer offers Study Mode again, among the suggestions.
        let suggested = app.buttons["chat.followUps.toggle"]
        XCTAssertTrue(suggested.waitForExistence(timeout: 5))
        XCTAssertTrue(suggested.label.contains("Suggested questions (1)"), suggested.label)
        suggested.tap()
        XCTAssertTrue(app.buttons["chat.followUps.study"].waitForExistence(timeout: 5))
        save("\(device())-\(appearance)-study-stopped-suggestions")
    }

    func testAnAnswerSuggestsOnePictureAndStudyMode() throws {
        let app = launch()
        openPaperChat(app)
        let input = any("chat.composer", app)
        XCTAssertTrue(input.waitForExistence(timeout: 8)); input.tap(); input.typeText("Why scale by the square root of d_k?")
        app.buttons["chat.send"].tap()
        let suggested = app.buttons["chat.followUps.toggle"]
        XCTAssertTrue(suggested.waitForExistence(timeout: 15))
        XCTAssertTrue(suggested.label.contains("Suggested questions (4)"), suggested.label)
        suggested.tap()
        XCTAssertTrue(app.buttons["Create a diagram explaining the background of scaled dot-product attention"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Draw a diagram"].exists, "the model's own picture replaces the generic rows")
        XCTAssertFalse(app.buttons["Create a visual explanation"].exists)
        XCTAssertTrue(app.buttons["chat.followUps.study"].exists)
        save("\(device())-\(appearance)-suggestions-visual-and-study")
    }

    func testThePaperExplainerStreamsCitesDrawsAndOpensInChat() throws {
        var app = launch(["--paper-fixture-step-ms=450"])
        app.show("paper")
        #if targetEnvironment(macCatalyst)
        // On the Mac the paper's ⋯ is a pop-up button and its rows are menu items.
        let options = app.popUpButtons["Paper options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 10)); options.click()
        let item = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH[c] %@", "AI Explainer")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.click()
        #else
        let options = app.buttons["Paper options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 10)); options.tap()
        let item = app.buttons["paper.aiExplainer"]
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
        #endif
        // Nothing kept: the model is chosen first, as for a figure (the page's own "Explain this paper" asks again).
        if !app.buttons["ai.chooseModel"].waitForExistence(timeout: 8), app.buttons["paperExplainer.start"].exists { app.buttons["paperExplainer.start"].tap() }
        XCTAssertTrue(app.buttons["ai.chooseModel"].waitForExistence(timeout: 8)); app.buttons["ai.chooseModel"].tap()
        XCTAssertTrue(app.buttons["ai.chooseCloud"].waitForExistence(timeout: 5)); app.buttons["ai.chooseCloud"].tap()
        let progress = any("paperExplainer.progress", app)
        XCTAssertTrue(progress.waitForExistence(timeout: 8), "the progress bar shows at once")
        XCTAssertTrue(any("paperExplainer.background.1", app).waitForExistence(timeout: 15), "entries arrive as they are written")
        save("\(device())-\(appearance)-paper-explainer-streaming")
        XCTAssertTrue(progress.waitForNonExistence(timeout: 20), "the bar fades once it is done")
        let diagram = any("paperExplainer.diagram", app)
        XCTAssertTrue(diagram.waitForExistence(timeout: 10), "how it fits together")
        XCTAssertTrue(any("paperExplainer.idea.2", app).exists)
        sleep(2)
        save("\(device())-\(appearance)-paper-explainer-done")
        for _ in 0..<6 where !diagram.isHittable { scroll(page(app), down: true) }
        // Tapped once drawn (the drawing grows the card as it arrives).
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'drawn'"), object: diagram)], timeout: 20) == .completed,
                      "the diagram is drawn on the device")
        for _ in 0..<4 where !diagram.isHittable { scroll(page(app), down: true) }
        sleep(1)
        save("\(device())-\(appearance)-paper-explainer-diagram")
        diagram.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 8), "the diagram full size")
        sleep(2); save("\(device())-\(appearance)-paper-explainer-diagram-full")
        app.buttons["Done"].tap()
        // A background paragraph closes the explainer and lands in the paper, with a way back.
        let cite = app.buttons["paperExplainer.background.1.cite.4"]
        for _ in 0..<6 where !cite.isHittable { scroll(page(app), down: false) }
        XCTAssertTrue(cite.waitForExistence(timeout: 5)); cite.tap()
        let back = app.buttons["reader.explainer.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Back to AI Explainer")
        XCTAssertTrue(back.label.contains("AI Explainer"), back.label)
        back.tap()
        XCTAssertTrue(any("paperExplainer.background.1", app).waitForExistence(timeout: 10), "the kept explainer, without asking again")
        XCTAssertFalse(any("paperExplainer.progress", app).exists)
        // Open in Chat: the explainer's conversation continues in the paper's Chat.
        let open = app.buttons["paperExplainer.openInChat"]
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
        XCTAssertTrue(any("chat.contextExplanation", app).waitForExistence(timeout: 10), "the explanation goes with the chat")
        // The same cards follow into the chat (build 82): the summary, Key concepts with ¶ links, the drawn diagram.
        XCTAssertTrue(any("chat.paperExplainer.summary", app).waitForExistence(timeout: 5), "the summary card")
        XCTAssertTrue(any("chat.paperExplainer.background.1", app).exists, "Key concepts: the background first")
        XCTAssertTrue(any("chat.paperExplainer.idea.1", app).exists, "and the paper's own ideas in the same card")
        XCTAssertTrue(app.buttons["chat.paperExplainer.background.1.cite.4"].exists, "its ¶ links")
        sleep(1); save("\(device())-\(appearance)-paper-explainer-open-in-chat")
        let chatDiagram = any("chat.paperExplainer.diagram", app)
        let chatScroll = app.scrollViews.containing(.any, identifier: "chat.paperExplainer.summary").firstMatch
        for _ in 0..<6 where !(chatDiagram.exists && chatDiagram.isHittable) { scroll(chatScroll, down: true) }
        XCTAssertTrue(chatDiagram.waitForExistence(timeout: 5), "and the diagram")
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'drawn'"), object: chatDiagram)], timeout: 20) == .completed,
                      "drawn in the chat too")
        sleep(1); save("\(device())-\(appearance)-paper-explainer-open-in-chat-diagram")

        // Settings › Your assets › Paper explanations reopens it after a relaunch.
        app.terminate()
        app = launch(reset: false)
        app.show("settings")
        let row = app.buttons["settings.paperExplanations"]
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        for _ in 0..<8 where !(row.exists && row.isHittable) { scroll(list, down: true) }
        XCTAssertTrue(row.exists); XCTAssertFalse(row.label.contains("None"), row.label)
        row.tap()
        let kept = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "explanations.paper.")).firstMatch
        XCTAssertTrue(kept.waitForExistence(timeout: 8), "the kept explainer is listed")
        save("\(device())-\(appearance)-your-assets-paper-explanations")
        kept.tap()
        XCTAssertTrue(any("paperExplainer.background.1", app).waitForExistence(timeout: 20), "the paper opens with its kept explainer")
        save("\(device())-\(appearance)-paper-explainer-from-assets")
    }
}
