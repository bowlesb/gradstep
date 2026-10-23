import XCTest
import UIKit

/// Half the Wide row's height (52 pt): the row's top from its centre line.
private enum WideRow { static let half: CGFloat = 26 }

/// One app, two shapes (docs/DESIGN.md › Tall and Wide, owner 2026-10-22). An iPad upright is the iPhone app: the places
/// capsule at the bottom. Turned sideways it is Wide: the same places in one top row of at most 56 pt whose controls share
/// one centre line, and two slots at most, moved between by doing things: Read (the paper alone), Browse (Papers |
/// Paper), Navigate (Contents | Paper), Explain (an explainer in the paper's slot), Discuss (Paper | Chat) and Chats
/// (All chats | Chat). The paper keeps its place through every move and every turn; the find bar never moves the text.
/// Screens are attached, and written to `GS_SCREENSHOT_DIR` when the runner sets it.
@MainActor
final class IPadShapesJourneyTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"
    private let draft = "Keep this question through the turn"

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait; super.tearDown() }

    private func launch(_ appearance: String = "light", extra: [String] = [], library: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture", "--feed-fixture",
                               "-appearance", appearance] + extra
        app.launch()
        if library { XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 15), "The fixture library") }
        return app
    }

    private func wait(_ description: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                      _ condition: @escaping () -> Bool) {
        let met = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)],
                                 timeout: timeout) == .completed
        XCTAssertTrue(met, description, file: file, line: line)
    }

    private var device: String {
        let size = XCUIScreen.main.screenshot().image.size
        let long = max(size.width, size.height)
        return UIDevice.current.userInterfaceIdiom != .pad ? "iphone" : long > 1300 ? "ipad13" : "ipad11"
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let directory = ProcessInfo.processInfo.environment["GS_SCREENSHOT_DIR"], !directory.isEmpty {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    private func composer(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["chat.composer"].firstMatch }
    private func composerText(_ app: XCUIApplication) -> String { (composer(app).value as? String) ?? "" }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// The sample's paragraph nearest the top of the page's viewport (its first words), from one snapshot.
    private func topParagraph(_ app: XCUIApplication) -> String? {
        let web = app.webViews.firstMatch
        guard let snapshot = try? web.snapshot() else { return nil }
        let top = snapshot.frame.minY + 60
        var best: (CGFloat, String)?
        func visit(_ node: XCUIElementSnapshot) {
            if node.elementType == .staticText, node.label.count > 40, node.frame.minY >= top, node.frame.maxY < snapshot.frame.maxY {
                if best == nil || node.frame.minY < best!.0 { best = (node.frame.minY, String(node.label.prefix(30))) }
            }
            node.children.forEach(visit)
        }
        visit(snapshot)
        return best?.1
    }

    private func paragraph(_ app: XCUIApplication, startingWith prefix: String) -> XCUIElement {
        app.webViews.firstMatch.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func inViewport(_ element: XCUIElement, _ app: XCUIApplication) -> Bool {
        let web = app.webViews.firstMatch.frame
        return element.exists && element.frame.minY >= web.minY - 2 && element.frame.minY < web.maxY - 20
    }

    /// Wide, the sample open and read part-way: the paragraph at the top of the page.
    private func wideSample(_ app: XCUIApplication) throws -> String {
        XCUIDevice.shared.orientation = .landscapeLeft
        wait("The places in the top row") { app.buttons["tab.search"].exists }
        app.buttons[sampleID].tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.staticTexts["An interactive reading sample · 2026"].waitForExistence(timeout: 15), "The paper is ready")
        // Opened from the full-width Library: Browse, the list on the left. ✕ closes it: Read.
        XCTAssertTrue(app.buttons["library.panel.close"].waitForExistence(timeout: 5), "Opened from the Library: Browse")
        app.buttons["library.panel.close"].tap()
        wait("Read") { abs(web.frame.width - app.frame.width) < 2 }
        web.swipeUp(); web.swipeUp()
        sleep(1)
        return try XCTUnwrap(topParagraph(app), "A paragraph at the top of the page")
    }

    /// The Wide row's budget: the row starts under the status bar, its controls share one centre line, and the content
    /// starts at most 56 pt under the row's top.
    private func assertOneRow(_ app: XCUIApplication, controls: [XCUIElement], content: XCUIElement,
                              file: StaticString = #filePath, line: UInt = #line) {
        let centre = app.buttons["tab.search"].frame.midY
        for control in controls {
            XCTAssertTrue(control.exists, "\(control)", file: file, line: line)
            XCTAssertEqual(control.frame.midY, centre, accuracy: 1.5, "\(control.label) on the row's centre line", file: file, line: line)
        }
        let rowTop = centre - WideRow.half
        XCTAssertLessThanOrEqual(rowTop - app.frame.minY, 32.5, "Only the status bar above the row: \(rowTop)", file: file, line: line)
        XCTAssertLessThanOrEqual(content.frame.minY - rowTop, 56, "Wide chrome above the content: \(content.frame.minY - rowTop) pt",
                                 file: file, line: line)
    }

    // MARK: - Turning

    /// Upright is the iPhone app; sideways is Wide. A paper's chat on the Chat tab becomes Discuss when turned, with its
    /// draft and the paper's place; turned back, Discuss is the Chat tab with Back to the paper.
    func testTurningAnIPadKeepsTheViewItsDraftAndThePlace() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Tall and Wide on iPad")
        let app = launch()
        let paperTab = app.buttons["tab.paper"]
        XCTAssertTrue(paperTab.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.buttons["tab.library"].frame.midY, app.frame.height * 0.85, "Upright: the capsule at the bottom")
        XCTAssertFalse(app.buttons["tab.search"].exists, "Upright search stays in the Library's field, as on iPhone")

        app.buttons[sampleID].tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.staticTexts["An interactive reading sample · 2026"].waitForExistence(timeout: 15), "The paper is ready")
        web.swipeUp(); web.swipeUp()
        sleep(1)
        let place = try XCTUnwrap(topParagraph(app), "A paragraph at the top of the page")
        save("\(device)-turn-1-upright-paper")
        app.buttons["Paper options"].tap()
        app.buttons["Ask about this paper"].tap()
        XCTAssertTrue(composer(app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["tab.chat"].isSelected, "Upright: the paper's chat is the Chat tab")
        composer(app).tap(); composer(app).typeText(draft)
        if app.buttons["chat.dismissKeyboard"].waitForExistence(timeout: 2) { app.buttons["chat.dismissKeyboard"].tap() }
        save("\(device)-turn-2-upright-chat-draft")

        // Sideways: Discuss. The capsule in the top row, the paper on the left, the chat on the right with the draft.
        XCUIDevice.shared.orientation = .landscapeLeft
        wait("Landscape") { app.frame.width > app.frame.height }
        wait("The places in the top row") { app.buttons["tab.search"].exists && app.buttons["tab.library"].frame.midY < 120 }
        XCTAssertTrue(composer(app).waitForExistence(timeout: 8))
        XCTAssertLessThanOrEqual(web.frame.maxX, composer(app).frame.minX + 1, "Discuss: the paper left, the chat right")
        XCTAssertEqual(web.frame.width / app.frame.width, 0.45, accuracy: 0.03, "The paper's slot is about 45%")
        XCTAssertEqual(composerText(app), draft, "The unsent question came with the chat")
        wait("The same place in the paper (\(place))") { self.inViewport(self.paragraph(app, startingWith: place), app) }
        assertOneRow(app, controls: [app.buttons["paper.contents"], app.buttons["Paper options"], app.buttons["chat.history"],
                                     app.buttons["Chat options"], app.buttons["chat.close"]], content: web)
        XCTAssertGreaterThanOrEqual(composer(app).frame.maxY, app.frame.maxY - 90, "The message box at the bottom, nothing under it")
        XCTAssertFalse(app.buttons["Settings"].exists, "No gear: Settings is the last row of ⋯")
        save("\(device)-turn-3-sideways-discuss")

        // Upright again: Discuss is the Chat tab, with its draft and Back to the paper, which kept its place.
        XCUIDevice.shared.orientation = .portrait
        wait("The capsule at the bottom again") { !app.buttons["tab.search"].exists && app.buttons["tab.library"].frame.midY > app.frame.height * 0.85 }
        wait("The chat on its tab") { app.buttons["tab.chat"].isSelected }
        XCTAssertEqual(composerText(app), draft, "The chat on its tab, with the draft")
        XCTAssertTrue(app.buttons["chat.returnToPaper"].exists, "Back to the paper")
        save("\(device)-turn-4-upright-chat-again")
        app.buttons["chat.returnToPaper"].tap()
        wait("Paper") { paperTab.isSelected }
        wait("The same place in the paper") { self.inViewport(self.paragraph(app, startingWith: place), app) }
    }

    /// A general chat stays on Chat when the iPad turns: Wide shows it beside All chats (Chats, like Messages).
    func testAGeneralChatIsTheChatsViewSideways() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Tall and Wide on iPad")
        let app = launch()
        app.buttons["tab.chat"].tap()
        XCTAssertTrue(composer(app).waitForExistence(timeout: 8))
        if app.buttons["chat.context"].value as? String != "General chat" {
            app.buttons["chat.context"].tap()
            app.buttons["General chat"].tap()
        }
        composer(app).tap(); composer(app).typeText("A general question")
        if app.buttons["chat.dismissKeyboard"].waitForExistence(timeout: 2) { app.buttons["chat.dismissKeyboard"].tap() }
        XCUIDevice.shared.orientation = .landscapeLeft
        wait("The places in the top row") { app.buttons["tab.search"].exists }
        wait("Still on Chat") { app.buttons["tab.chat"].isSelected }
        XCTAssertEqual(composerText(app), "A general question")
        XCTAssertFalse(app.webViews.firstMatch.exists, "No paper beside a general chat")
        // All chats' share of the row: its search field, or its name while there is nothing to search.
        let search = element("chat.history.search", app).exists ? element("chat.history.search", app) : app.staticTexts["All chats"]
        if !search.waitForExistence(timeout: 5) { save("\(device)-debug-chats") }
        XCTAssertTrue(search.exists, "Chats: All chats on the left")
        XCTAssertLessThan(search.frame.maxX, composer(app).frame.minX, "The list left, the chat right")
        let centre = app.buttons["tab.search"].frame.midY
        for control in [search, app.buttons["Chat options"], app.buttons["New chat"]] {
            XCTAssertEqual(control.frame.midY, centre, accuracy: 1.5, "\(control.label) on the row's centre line")
        }
        save("\(device)-view-chats")
        XCUIDevice.shared.orientation = .portrait
        wait("Still on Chat upright") { app.buttons["tab.chat"].isSelected && !app.buttons["tab.search"].exists }
        XCTAssertEqual(composerText(app), "A general question")
    }

    // MARK: - The views

    /// Read ↔ Discuss: the paper glides to the left slot and back, keeping its place; the find bar floats.
    func testReadAndDiscussKeepThePaperInPlace() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        let app = launch()
        let place = try wideSample(app)
        let web = app.webViews.firstMatch
        XCTAssertEqual(web.frame.width, app.frame.width, accuracy: 2, "Read: the paper alone")
        XCTAssertFalse(composer(app).exists, "No chat column in Read")
        assertOneRow(app, controls: [app.buttons["paper.contents"], app.buttons["Paper options"]], content: web)
        save("\(device)-view-read")

        // Find floats over the page: the text doesn't move.
        let anchor = paragraph(app, startingWith: place)
        let before = anchor.frame.minY
        app.buttons["Paper options"].tap()
        app.buttons["paper.find"].tap()
        XCTAssertTrue(app.buttons["paper.find.close"].waitForExistence(timeout: 5), "The find bar")
        sleep(1)
        XCTAssertEqual(anchor.frame.minY, before, accuracy: 1, "The find bar floats; the text stays where it was")
        save("\(device)-view-read-find")
        app.buttons["paper.find.close"].tap()
        if !app.buttons["paper.find.close"].waitForNonExistence(timeout: 5) { save("\(device)-debug-find-still-open") }
        XCTAssertFalse(app.buttons["paper.find.close"].exists, "The find bar closes")

        // Ask: Discuss, the paper in the left slot at its place.
        app.buttons["Paper options"].tap()
        app.buttons["Ask about this paper"].tap()
        XCTAssertTrue(composer(app).waitForExistence(timeout: 8))
        wait("Paper | Chat") { web.frame.maxX <= self.composer(app).frame.minX + 1 }
        wait("Discuss keeps the place (\(place))") { self.inViewport(self.paragraph(app, startingWith: place), app) }
        save("\(device)-view-discuss")
        // ✕: Read again, at the same place.
        app.buttons["chat.close"].tap()
        wait("Read") { !self.composer(app).exists && abs(web.frame.width - app.frame.width) < 2 }
        wait("Read keeps the place") { self.inViewport(self.paragraph(app, startingWith: place), app) }
    }

    /// Browse: Search opens the Papers list on the left; a result opens on the right and the list stays.
    func testBrowseKeepsTheListAfterOpeningAResult() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        let app = launch()
        _ = try wideSample(app)
        let web = app.webViews.firstMatch
        app.buttons["tab.search"].tap()
        let scope = app.segmentedControls["library.searchScope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5), "The Library | ML paper search switch under the field")
        XCTAssertLessThanOrEqual(scope.frame.maxX, web.frame.minX + 1, "The list left, the paper right")
        let row = app.buttons[sampleID]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(web.waitForExistence(timeout: 8))
        XCTAssertTrue(row.exists && scope.exists, "The list stays after opening a result")
        XCTAssertLessThanOrEqual(row.frame.maxX, web.frame.minX + 1)
        assertOneRow(app, controls: [app.buttons["paper.contents"], app.buttons["Paper options"]], content: web)
        save("\(device)-view-browse")
        if app.buttons["library.search.cancel"].exists { app.buttons["library.search.cancel"].tap() }
        if app.buttons["library.panel.close"].waitForExistence(timeout: 2) { app.buttons["library.panel.close"].tap() }
        wait("Read") { abs(web.frame.width - app.frame.width) < 2 }
    }

    /// Navigate: Contents on the left; a heading scrolls the paper beside it, and Contents stays.
    func testNavigateScrollsThePaperBesideContents() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        let app = launch()
        _ = try wideSample(app)
        let web = app.webViews.firstMatch
        app.buttons["paper.contents"].tap()
        let tabs = app.contentsTabs
        XCTAssertTrue(tabs.waitForExistence(timeout: 5), "Contents in the left slot")
        XCTAssertLessThanOrEqual(tabs.frame.maxX, web.frame.minX + 1)
        assertOneRow(app, controls: [app.buttons["sheet.close"], app.buttons["paper.contents"], app.buttons["Paper options"]], content: web)
        let heading = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "3. Check the evaluation")).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        heading.tap()
        wait("The paper goes to the section") { self.inViewport(self.paragraph(app, startingWith: "3. Check the evaluation"), app) }
        XCTAssertTrue(tabs.exists, "Contents stays")
        save("\(device)-view-navigate")
        app.buttons["sheet.close"].tap()
        wait("Read") { !tabs.exists && abs(web.frame.width - app.frame.width) < 2 }
    }

    /// Explain: a figure's page takes the paper's slot (the paper stays loaded beneath; ✕ returns to the same place).
    /// Continue in Chat turns it into Discuss with the explainer's conversation at the top of the chat.
    func testExplainBecomesDiscussWithTheSameContent() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        // The numbered arXiv fixture paper, whose figures have explainers and chats (FigureViewJourneyTests).
        let app = launch(extra: ["--chat-fixture-mode=figure_walkthrough", "--study-fixture"], library: false)
        XCUIDevice.shared.orientation = .landscapeLeft
        wait("The places in the top row") { app.buttons["tab.search"].exists }
        // The fixture opens its paper (the Paper tab upright); give the reader time to prepare it.
        let paperTab = app.buttons["tab.paper"]
        wait("The fixture's paper", timeout: 20) { paperTab.isEnabled }
        paperTab.tap()
        let web = app.webViews.firstMatch
        if !web.staticTexts["(1)"].firstMatch.waitForExistence(timeout: 20) { save("\(device)-debug-paper-not-ready"); paperTab.tap() }
        XCTAssertTrue(web.staticTexts["(1)"].firstMatch.waitForExistence(timeout: 15), "The paper is ready")
        if app.buttons["library.panel.close"].exists { app.buttons["library.panel.close"].tap() }
        let figure = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open figure")).firstMatch
        for _ in 0..<8 where !(figure.exists && figure.isHittable) { web.swipeUp() }
        if !figure.waitForExistence(timeout: 5) { save("\(device)-debug-no-figure") }
        XCTAssertTrue(figure.exists, "A figure in the paper")
        let top = figure.frame.minY
        figure.tap()
        let pane = element("explain.pane", app)
        XCTAssertTrue(pane.waitForExistence(timeout: 5), "Explain: the figure's page in the paper's slot")
        sleep(1)
        save("\(device)-view-explain")
        XCTAssertTrue(app.buttons["tab.search"].isHittable, "The top row stays above the explainer")
        let ask = app.buttons["figureView.askInChat"]
        XCTAssertTrue(ask.waitForExistence(timeout: 5), "The figure page's Chat")
        app.buttons["sheet.close"].tap()
        XCTAssertTrue(pane.waitForNonExistence(timeout: 5), "✕ returns to the paper")
        XCTAssertEqual(figure.frame.minY, top, accuracy: 1, "At the same place")

        // Chat about the figure, then Continue in Chat: Discuss, the figure's conversation at the top of the chat.
        figure.tap()
        XCTAssertTrue(ask.waitForExistence(timeout: 5))
        ask.tap()
        let context = element("contextChat.composer", app)
        XCTAssertTrue(context.waitForExistence(timeout: 8), "The figure's chat, in the explainer")
        context.tap(); context.typeText("Which part matters most?")
        save("\(device)-view-explain-chat")
        let open = app.buttons["figureView.openInChat"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(element("chat.promotedContext", app).waitForExistence(timeout: 15), "The explainer's content heads the chat")
        XCTAssertTrue(composer(app).waitForExistence(timeout: 5))
        wait("Discuss: the paper left, the chat right") { web.exists && web.frame.maxX <= self.composer(app).frame.minX + 1 }
        XCTAssertTrue(composerText(app).contains("Which part matters most?"), "The question came with it")
        save("\(device)-view-discuss-from-explain")
    }

    // MARK: - Gallery

    /// Every view in both shapes, light and dark, with the ⋯ menus: for the owner's eye and later comparisons.
    func testGalleryOfTheViewsInBothShapes() throws {
        for appearance in ["light", "dark"] {
            XCUIDevice.shared.orientation = .portrait
            let app = launch(appearance)
            app.buttons[sampleID].tap()
            XCTAssertTrue(app.webViews.firstMatch.staticTexts["An interactive reading sample · 2026"].waitForExistence(timeout: 15))
            // One answer, so Discuss and Chat show a conversation.
            app.buttons["Paper options"].tap()
            app.buttons["Ask about this paper"].tap()
            XCTAssertTrue(composer(app).waitForExistence(timeout: 8))
            composer(app).tap(); composer(app).typeText("What is the main idea?")
            if app.buttons["chat.dismissKeyboard"].waitForExistence(timeout: 2) { app.buttons["chat.dismissKeyboard"].tap() }
            app.buttons["chat.send"].tap()
            XCTAssertTrue(app.buttons["chat.send"].waitForExistence(timeout: 20), "The answer finished")
            sleep(1)
            tallViews(app, prefix: "\(device)-upright-\(appearance)")
            if UIDevice.current.userInterfaceIdiom == .pad {
                XCUIDevice.shared.orientation = .landscapeLeft
                wait("Sideways") { app.buttons["tab.search"].exists }
                sleep(1)
                wideViews(app, prefix: "\(device)-sideways-\(appearance)")
            }
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
    }

    private func dismissMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
    }

    private func menu(_ label: String, _ app: XCUIApplication, save name: String) {
        let button = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex.first { $0.isHittable }
            ?? app.buttons[label]
        guard button.waitForExistence(timeout: 3) else { return }
        button.tap(); sleep(1)
        save(name)
        dismissMenu(app)
    }

    /// Tall: the same views one at a time (the iPhone app).
    private func tallViews(_ app: XCUIApplication, prefix: String) {
        app.buttons["tab.paper"].tap(); sleep(2)
        save("\(prefix)-read")
        menu("Paper options", app, save: "\(prefix)-paper-menu")
        app.buttons["Table of contents"].tap(); sleep(2)
        save("\(prefix)-navigate")
        if app.buttons["sheet.close"].exists { app.buttons["sheet.close"].tap() } else { app.swipeDown() }
        sleep(1)
        app.buttons["tab.chat"].tap(); sleep(2)
        save("\(prefix)-discuss")
        menu("Chat options", app, save: "\(prefix)-chat-menu")
        app.buttons["tab.library"].tap(); sleep(1)
        save("\(prefix)-browse-library")
        menu("Library options", app, save: "\(prefix)-library-menu")
        app.buttons["tab.feed"].tap(); sleep(2)
        save("\(prefix)-feed")
        menu("Feed options", app, save: "\(prefix)-feed-menu")
        app.buttons["tab.notes"].tap(); sleep(2)
        save("\(prefix)-snippets")
        menu("Snippets options", app, save: "\(prefix)-snippets-menu")
    }

    /// Wide: the six views, then the other places.
    private func wideViews(_ app: XCUIApplication, prefix: String) {
        // Discuss (the paper's chat was open in Tall).
        app.buttons["tab.paper"].tap(); sleep(1)
        if !composer(app).exists, app.buttons["Paper options"].exists {
            app.buttons["Paper options"].tap(); app.buttons["Ask about this paper"].tap(); sleep(2)
        }
        save("\(prefix)-discuss")
        menu("Chat options", app, save: "\(prefix)-discuss-chat-menu")
        if app.buttons["chat.close"].exists { app.buttons["chat.close"].tap() }
        sleep(2)
        save("\(prefix)-read")
        menu("Paper options", app, save: "\(prefix)-paper-menu")
        // Navigate.
        app.buttons["paper.contents"].tap(); sleep(2)
        save("\(prefix)-navigate")
        if app.buttons["sheet.close"].exists { app.buttons["sheet.close"].tap() }
        sleep(1)
        // Explain.
        let web = app.webViews.firstMatch
        let figure = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open figure")).firstMatch
        for _ in 0..<4 where !(figure.exists && figure.isHittable) { web.swipeUp() }
        if figure.exists {
            figure.tap(); sleep(2)
            save("\(prefix)-explain")
            if app.buttons["sheet.close"].exists { app.buttons["sheet.close"].tap() }
            sleep(1)
        }
        // Browse.
        app.buttons["tab.search"].tap(); sleep(1)
        if app.buttons[sampleID].exists { app.buttons[sampleID].tap() }
        sleep(2)
        save("\(prefix)-browse")
        if app.buttons["library.search.cancel"].exists { app.buttons["library.search.cancel"].tap() }
        if app.buttons["library.panel.close"].exists { app.buttons["library.panel.close"].tap() }
        sleep(1)
        // Chats.
        app.buttons["tab.chat"].tap(); sleep(2)
        save("\(prefix)-chats")
        menu("Chat options", app, save: "\(prefix)-chats-menu")
        // The other places.
        app.buttons["tab.library"].tap(); sleep(1)
        save("\(prefix)-library")
        menu("Library options", app, save: "\(prefix)-library-menu")
        app.buttons["tab.feed"].tap(); sleep(2)
        save("\(prefix)-feed")
        menu("Feed options", app, save: "\(prefix)-feed-menu")
        app.buttons["tab.notes"].tap(); sleep(2)
        save("\(prefix)-snippets")
        menu("Snippets options", app, save: "\(prefix)-snippets-menu")
    }
}
