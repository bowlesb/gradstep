import XCTest
import UIKit

/// Half a Wide row's height (52 pt): the row's top from its centre line.
private enum WideRow { static let half: CGFloat = 26 }

/// One app, two shapes (docs/DESIGN.md › Tall and Wide). An iPad upright is the iPhone app: the places capsule at the
/// bottom. Turned sideways it is Wide (owner, 2026-10-23): the places are a menu in the window's top-right corner, and each
/// place owns two slots — its list on the left, what was picked from it on the right, on a draggable divider:
/// Library | paper, Feed | abstract (or paper), All chats | conversation, Collections | collection. Paper is the paper as
/// the left primary item (the list toggle), with Contents on its left or a companion on its right (AI Explainer, the
/// equation view, a figure page, the chat). Navigation never adds a row: rows only where a slot has controls of its own,
/// at most 56 pt; the paper's controls float. The paper keeps its place through every move and every turn.
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
            try? upright(shot.image).pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    /// A sideways capture carries its orientation as metadata, which a PNG drops; drawing it again bakes it in (upright).
    private func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat(); format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
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

    /// Sideways: the places menu in the corner.
    private func turnWide(_ app: XCUIApplication) {
        XCUIDevice.shared.orientation = .landscapeLeft
        wait("Landscape") { app.frame.width > app.frame.height }
        wait("The places menu in the corner") { app.placesMenu.exists }
    }

    /// Wide's Library: the sample picked in the list, its paper on the right (still the Library place).
    private func openSampleBesideLibrary(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if app.currentPlace != "Library" { app.show("library") }
        app.buttons[sampleID].tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.staticTexts["An interactive reading sample · 2026"].waitForExistence(timeout: 15), "The paper is ready",
                      file: file, line: line)
        wait("Still the Library place", file: file, line: line) { app.currentPlace == "Library" }
        XCTAssertLessThanOrEqual(app.buttons[sampleID].frame.maxX, web.frame.minX + 1, "The list left, the paper right", file: file, line: line)
        return web
    }

    /// Wide, the sample open as the Paper place (promoted with its list toggle) and read part-way: the paragraph at the
    /// top of the page.
    private func wideSample(_ app: XCUIApplication) throws -> String {
        turnWide(app)
        let web = openSampleBesideLibrary(app)
        let toggle = app.buttons["paper.listToggle"]
        XCTAssertEqual(toggle.label, "Hide library")
        toggle.tap()
        wait("Paper alone") { abs(web.frame.width - app.frame.width) < 2 && app.currentPlace == "Paper" }
        web.swipeUp(); web.swipeUp()
        sleep(1)
        return try XCTUnwrap(topParagraph(app), "A paragraph at the top of the page")
    }

    /// The Wide budget: a row (or floating controls) starts under the status bar, its controls share the places menu's
    /// centre line, and the content starts at most `budget` under the row's top (56 pt for a row, 0 for the paper's
    /// floating controls).
    private func assertOneRow(_ app: XCUIApplication, controls: [XCUIElement], content: XCUIElement, budget: CGFloat = 56,
                              file: StaticString = #filePath, line: UInt = #line) {
        let centre = app.placesMenu.frame.midY
        for control in controls {
            XCTAssertTrue(control.exists, "\(control)", file: file, line: line)
            XCTAssertEqual(control.frame.midY, centre, accuracy: 1.5, "\(control.label) on the row's centre line", file: file, line: line)
        }
        let rowTop = centre - WideRow.half
        XCTAssertLessThanOrEqual(rowTop - app.frame.minY, 32.5, "Only the status bar above the row: \(rowTop)", file: file, line: line)
        XCTAssertLessThanOrEqual(content.frame.minY - rowTop, budget, "Wide chrome above the content: \(content.frame.minY - rowTop) pt",
                                 file: file, line: line)
    }

    /// The places menu stays in the window's top-right corner.
    private func assertPlacesInTheCorner(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let frame = app.placesMenu.frame
        XCTAssertEqual(frame.maxX, app.frame.maxX - 12, accuracy: 2, "The places menu at the right edge", file: file, line: line)
        XCTAssertLessThan(frame.minY, app.frame.minY + 40, "The places menu at the top", file: file, line: line)
    }

    /// A place straight from the places menu (Chat is the general chat there, whatever paper is open).
    private func choose(_ place: String, _ app: XCUIApplication) {
        let item = app.placeItem(place)
        XCTAssertTrue(item.waitForExistence(timeout: 3), "The places menu has \(place)")
        item.tap()
    }

    /// A row of the Feed (the table's, or the list's).
    private func feedRow(_ sourceID: String, _ app: XCUIApplication) -> XCUIElement {
        let table = element("feed.table.\(sourceID)", app)
        return table.exists ? table : element("discover.result.\(sourceID)", app)
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
        XCTAssertFalse(app.placesMenu.exists, "Upright: no places menu")

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

        // Sideways: Discuss. The paper on the left (55%), the chat on the right with the draft; the places in the corner.
        turnWide(app)
        XCTAssertFalse(app.buttons["tab.library"].exists, "No capsule sideways")
        XCTAssertEqual(app.currentPlace, "Paper", "A paper's chat is the Paper place")
        XCTAssertTrue(composer(app).waitForExistence(timeout: 8))
        XCTAssertLessThanOrEqual(web.frame.maxX, composer(app).frame.minX + 1, "Discuss: the paper left, the chat right")
        XCTAssertEqual(web.frame.width / app.frame.width, 0.55, accuracy: 0.03, "The paper's slot is about 55%")
        XCTAssertEqual(composerText(app), draft, "The unsent question came with the chat")
        wait("The same place in the paper (\(place))") { self.inViewport(self.paragraph(app, startingWith: place), app) }
        assertOneRow(app, controls: [app.buttons["paper.contents"], app.buttons["Paper options"], app.buttons["chat.history"],
                                     app.buttons["Chat options"], app.buttons["chat.close"]], content: web, budget: 1)
        assertPlacesInTheCorner(app)
        XCTAssertLessThan(app.buttons["chat.close"].frame.maxX, app.buttons["Chat options"].frame.minX, "The companion's ✕ before its ⋯")
        XCTAssertLessThan(app.buttons["Chat options"].frame.maxX, app.placesMenu.frame.minX, "⋯ just left of the places")
        XCTAssertGreaterThanOrEqual(composer(app).frame.maxY, app.frame.maxY - 90, "The message box at the bottom, nothing under it")
        XCTAssertFalse(app.buttons["Settings"].exists, "No gear: Settings is the last row of ⋯")
        save("\(device)-turn-3-sideways-discuss")

        // Upright again: Discuss is the Chat tab, with its draft and Back to the paper, which kept its place.
        XCUIDevice.shared.orientation = .portrait
        wait("The capsule at the bottom again") { !app.placesMenu.exists && app.buttons["tab.library"].frame.midY > app.frame.height * 0.85 }
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
        turnWide(app)
        wait("Still on Chat") { app.currentPlace == "Chat" }
        XCTAssertEqual(composerText(app), "A general question")
        XCTAssertFalse(app.webViews.firstMatch.exists, "No paper beside a general chat")
        // All chats' row: its search field, or its name while there is nothing to search.
        let search = element("chat.history.search", app).exists ? element("chat.history.search", app) : app.staticTexts["All chats"]
        if !search.waitForExistence(timeout: 5) { save("\(device)-debug-chats") }
        XCTAssertTrue(search.exists, "Chats: All chats on the left")
        XCTAssertLessThan(search.frame.maxX, composer(app).frame.minX, "The list left, the chat right")
        let centre = app.placesMenu.frame.midY
        for control in [search, app.buttons["Chat options"], app.buttons["New chat"]] {
            XCTAssertEqual(control.frame.midY, centre, accuracy: 1.5, "\(control.label) on the row's centre line")
        }
        XCTAssertLessThan(app.buttons["Chat options"].frame.maxX, app.placesMenu.frame.minX, "⋯ just left of the places")
        assertPlacesInTheCorner(app)
        XCTAssertTrue(element("slots.divider", app).exists, "A divider between the slots")
        save("\(device)-view-chats")
        XCUIDevice.shared.orientation = .portrait
        wait("Still on Chat upright") { app.buttons["tab.chat"].isSelected && !app.placesMenu.exists }
        XCTAssertEqual(composerText(app), "A general question")
    }

    // MARK: - The places menu

    /// The places menu: its five places and Search, the current one checked and named by the button; choosing one goes
    /// there, and the button stays in the same corner in every place.
    func testThePlacesMenuSwitchesPlacesAndShowsTheCurrentOne() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        let app = launch(extra: ["--nothing-open"])
        turnWide(app)
        XCTAssertEqual(app.currentPlace, "Library")
        XCTAssertFalse(app.buttons["tab.library"].exists, "No capsule: the places are in the menu")
        let corner = app.placesMenu.frame
        assertPlacesInTheCorner(app)
        app.placesMenu.tap()
        for id in ["feed", "library", "paper", "chat", "notes", "search"] {
            XCTAssertTrue(element("tab.\(id)", app).waitForExistence(timeout: 3), "The menu has \(id)")
        }
        XCTAssertFalse(element("tab.paper", app).isEnabled, "Paper needs a paper")
        save("\(device)-places-menu")
        element("tab.feed", app).tap()
        wait("Feed") { app.currentPlace == "Feed" }
        XCTAssertTrue(app.buttons["Feed options"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.placesMenu.frame, corner, "The same spot")
        choose("chat", app)
        wait("Chat") { app.currentPlace == "Chat" }
        XCTAssertEqual(app.placesMenu.frame, corner, "The same spot")
        app.show("notes")
        wait("Snippets") { app.currentPlace == "Snippets" }
        XCTAssertEqual(app.placesMenu.frame, corner, "The same spot")
        // Search: the Library with its field focused.
        _ = app.placeItem("search"); element("tab.search", app).tap()
        wait("Search is the Library's field") { app.currentPlace == "Library" && app.segmentedControls["library.searchScope"].exists }
        if app.buttons["library.search.cancel"].exists { app.buttons["library.search.cancel"].tap() }
        // ⌘2 with a hardware keyboard: Library; ⌘1: Feed.
        app.typeKey("1", modifierFlags: .command)
        wait("⌘1 is Feed") { app.currentPlace == "Feed" }
        app.typeKey("2", modifierFlags: .command)
        wait("⌘2 is Library") { app.currentPlace == "Library" }
    }

    // MARK: - Library | paper

    /// The Library place: the list on the left from the start, a placeholder on the right; a picked paper opens there and
    /// it is still the Library. The divider moves where it is dragged, and the place keeps it (and across launches).
    func testLibraryListAndPaperWithTheDividerDraggedAndRemembered() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        var app = launch(extra: ["--nothing-open"])
        turnWide(app)
        let placeholder = element("paper.placeholder", app)
        XCTAssertTrue(placeholder.waitForExistence(timeout: 5), "Nothing open: a quiet placeholder on the right")
        let divider = element("slots.divider", app)
        XCTAssertEqual(divider.frame.midX / app.frame.width, 0.4, accuracy: 0.03, "The list on the left from the start, 40%")
        XCTAssertLessThan(app.buttons[sampleID].frame.maxX, placeholder.frame.minX, "The placeholder on the right")
        let options = app.buttons["Library options"]
        assertOneRow(app, controls: [options], content: app.buttons[sampleID])
        XCTAssertLessThan(options.frame.maxX, app.frame.width * 0.5, "The list's ⋯ ends the list's row")
        save("\(device)-library-empty")
        let web = openSampleBesideLibrary(app)
        XCTAssertEqual(web.frame.minX / app.frame.width, 0.4, accuracy: 0.03, "The list takes about 40%")
        assertOneRow(app, controls: [app.buttons["paper.listToggle"], app.buttons["paper.contents"], app.buttons["Paper options"]],
                     content: web, budget: 1)
        XCTAssertLessThan(app.buttons["Paper options"].frame.maxX, app.placesMenu.frame.minX, "The paper's ⋯ just left of the places")
        save("\(device)-library-paper")

        // Drag the divider 160 pt to the right: the list grows.
        let before = web.frame.minX
        XCTAssertTrue(divider.exists)
        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 160, dy: 0)))
        wait("The divider moved") { abs(web.frame.minX - (before + 160)) < 6 }
        save("\(device)-library-divider-dragged")
        // Kept by the place: away to Feed and back.
        app.show("feed")
        wait("Feed") { app.currentPlace == "Feed" }
        app.show("library")
        wait("Library at the dragged divider") { app.webViews.firstMatch.exists && abs(app.webViews.firstMatch.frame.minX - (before + 160)) < 6 }
        // And on this device: a new launch that keeps it.
        app.terminate()
        app = launch(extra: ["--keep-slot-widths", "--nothing-open"])
        wait("The places menu") { app.placesMenu.exists }
        let kept = element("slots.divider", app)
        XCTAssertTrue(kept.waitForExistence(timeout: 5))
        XCTAssertEqual(kept.frame.midX, before + 160, accuracy: 8, "The divider where it was left")
        // Double-tap: the default.
        kept.doubleTap()
        wait("Back to 40%") { abs(kept.frame.midX / app.frame.width - 0.4) < 0.03 }
    }

    /// Paper as the left primary item: the list toggle hides the list and the same paper, at the same place, is the Paper
    /// place; its Show library puts the list back with the paper on the right. Dragging the divider past the list's
    /// minimum also promotes it.
    func testTheListTogglePromotesAndDemotesKeepingThePlace() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        let app = launch()
        turnWide(app)
        let web = openSampleBesideLibrary(app)
        web.swipeUp(); web.swipeUp()
        sleep(1)
        let place = try XCTUnwrap(topParagraph(app))
        let toggle = app.buttons["paper.listToggle"]
        XCTAssertEqual(toggle.label, "Hide library")
        toggle.tap()
        wait("Paper alone") { abs(web.frame.width - app.frame.width) < 2 && app.currentPlace == "Paper" }
        XCTAssertFalse(app.buttons["Library options"].exists, "The list slid away")
        wait("The same place (\(place))") { self.inViewport(self.paragraph(app, startingWith: place), app) }
        assertOneRow(app, controls: [toggle, app.buttons["paper.contents"], app.buttons["Paper options"]], content: web, budget: 1)
        save("\(device)-paper-promoted")
        XCTAssertEqual(toggle.label, "Show library")
        toggle.tap()
        wait("Library | paper") { app.currentPlace == "Library" && app.buttons["Library options"].exists && web.frame.minX > 200 }
        wait("Still the same place") { self.inViewport(self.paragraph(app, startingWith: place), app) }
        // Dragging the divider past the list's minimum: Paper.
        let divider = element("slots.divider", app)
        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -(divider.frame.midX - 20), dy: 0)))
        wait("The drag promoted the paper") { app.currentPlace == "Paper" && abs(web.frame.width - app.frame.width) < 2 }
        wait("And kept its place") { self.inViewport(self.paragraph(app, startingWith: place), app) }
    }

    // MARK: - The paper and its companions

    /// Read ↔ Discuss: the chat opens on the paper's right and closes, the paper keeping its place; the find bar floats.
    /// The paper has no row: its controls float, 0 pt of chrome above the page.
    func testReadAndDiscussKeepThePaperInPlace() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        let app = launch()
        let place = try wideSample(app)
        let web = app.webViews.firstMatch
        XCTAssertEqual(web.frame.width, app.frame.width, accuracy: 2, "Read: the paper alone")
        XCTAssertFalse(composer(app).exists, "No chat column in Read")
        assertOneRow(app, controls: [app.buttons["paper.contents"], app.buttons["Paper options"]], content: web, budget: 1)
        assertPlacesInTheCorner(app)
        save("\(device)-view-read")

        // Find floats over the page: the text doesn't move.
        let anchor = paragraph(app, startingWith: place)
        let before = anchor.frame.minY
        app.buttons["Paper options"].tap()
        app.buttons["paper.find"].tap()
        XCTAssertTrue(app.buttons["paper.find.close"].waitForExistence(timeout: 5), "The find bar")
        sleep(1)
        XCTAssertEqual(anchor.frame.minY, before, accuracy: 1, "The find bar floats; the text stays where it was")
        XCTAssertGreaterThan(app.buttons["paper.find.close"].frame.minY, app.placesMenu.frame.maxY, "The find bar under the floating controls")
        save("\(device)-view-read-find")
        app.buttons["paper.find.close"].tap()
        if !app.buttons["paper.find.close"].waitForNonExistence(timeout: 5) { save("\(device)-debug-find-still-open") }
        XCTAssertFalse(app.buttons["paper.find.close"].exists, "The find bar closes")

        // Ask: Discuss, the chat on the paper's right, the paper at its place.
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

    /// Discuss's paper (the left slot) keeps room after its end: its last lines scroll clear of the floating text size, and
    /// nothing is drawn under the page (no bottom band on Wide).
    func testThePapersLastLinesClearTheTextSizeInDiscuss() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        let app = launch()
        _ = try wideSample(app)
        let web = app.webViews.firstMatch
        app.buttons["Paper options"].tap()
        app.buttons["Ask about this paper"].tap()
        XCTAssertTrue(composer(app).waitForExistence(timeout: 8))
        wait("Paper | Chat") { web.frame.maxX <= self.composer(app).frame.minX + 1 }
        for _ in 0..<14 { web.swipeUp(velocity: .fast) }
        sleep(2)
        save("\(device)-view-discuss-end")
        let control = app.buttons["paper.textSize.smaller"]
        XCTAssertTrue(control.exists)
        let texts = web.staticTexts.allElementsBoundByIndex.filter { $0.frame.height > 0 && $0.frame.minY < web.frame.maxY }
        let lowest = texts.map(\.frame.maxY).max() ?? 0
        XCTAssertLessThanOrEqual(lowest, control.frame.minY + 1, "The last line (\(lowest)) ends above the text size (\(control.frame.minY))")
    }

    /// Search (places menu): the Library with its field focused; a result opens on the right and the list stays.
    func testSearchKeepsTheListAfterOpeningAResult() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        let app = launch()
        _ = try wideSample(app)
        let web = app.webViews.firstMatch
        _ = app.placeItem("search"); element("tab.search", app).tap()
        let scope = app.segmentedControls["library.searchScope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5), "The Library | ML paper search switch under the field")
        XCTAssertEqual(app.currentPlace, "Library")
        XCTAssertLessThanOrEqual(scope.frame.maxX, web.frame.minX + 1, "The list left, the paper right")
        // The field has the focus (the keyboard is up); the list's first rows stay above it.
        let row = app.buttons[sampleID]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(web.waitForExistence(timeout: 8))
        XCTAssertTrue(row.exists && scope.exists, "The list stays after opening a result")
        XCTAssertLessThanOrEqual(row.frame.maxX, web.frame.minX + 1)
        save("\(device)-view-search")
        if app.buttons["library.search.cancel"].exists { app.buttons["library.search.cancel"].tap() }
        wait("The search ends; the list stays") { !scope.exists && app.currentPlace == "Library" }
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
        assertOneRow(app, controls: [app.buttons["sheet.close"], app.buttons["paper.contents"], app.buttons["Paper options"]], content: web,
                     budget: 1)
        let heading = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "3. Check the evaluation")).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        heading.tap()
        wait("The paper goes to the section") { self.inViewport(self.paragraph(app, startingWith: "3. Check the evaluation"), app) }
        XCTAssertTrue(tabs.exists, "Contents stays")
        save("\(device)-view-navigate")
        app.buttons["sheet.close"].tap()
        wait("Read") { !tabs.exists && abs(web.frame.width - app.frame.width) < 2 }
    }

    /// The numbered arXiv fixture paper (figures with explainers, equations, the paper's AI Explainer), Wide, beside the
    /// Library's list.
    private func launchStudyPaperBesideLibrary(_ appearance: String = "light", mode: String = "figure_walkthrough") -> (XCUIApplication, XCUIElement) {
        let app = launch(appearance, extra: ["--chat-fixture-mode=\(mode)", "--study-fixture"], library: false)
        turnWide(app)
        // The fixture opens its paper; give the reader time to prepare it, then show it beside the Library's list.
        let web = app.webViews.firstMatch
        wait("The fixture's paper", timeout: 25) { web.staticTexts["(1)"].firstMatch.exists }
        if app.currentPlace != "Library" {
            if app.buttons["paper.listToggle"].exists && app.buttons["paper.listToggle"].label == "Show library" {
                app.buttons["paper.listToggle"].tap()
            } else { app.show("library") }
        }
        wait("Library | paper") { app.currentPlace == "Library" && web.exists && web.frame.minX > 200 }
        return (app, web)
    }

    /// A helper opened from the paper beside the Library: the paper becomes the Paper place and the helper opens on its
    /// right (a figure page; ✕ closes it and the paper takes the width). Continue in Chat hands its slot to the chat.
    func testAnExplainerFromTheLibraryPromotesThePaperAndOpensOnItsRight() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        let (app, web) = launchStudyPaperBesideLibrary()
        let figure = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open figure")).firstMatch
        for _ in 0..<8 where !(figure.exists && figure.isHittable) { web.swipeUp() }
        if !figure.waitForExistence(timeout: 5) { save("\(device)-debug-no-figure") }
        XCTAssertTrue(figure.exists, "A figure in the paper")
        figure.tap()
        let pane = element("explain.pane", app)
        XCTAssertTrue(pane.waitForExistence(timeout: 5), "The figure's page in the companion slot")
        wait("Paper | figure page") { app.currentPlace == "Paper" && web.frame.minX < 2 && web.frame.maxX <= pane.frame.minX + 1 }
        XCTAssertFalse(app.buttons["Library options"].exists, "The list slid away: never three columns")
        XCTAssertEqual(web.frame.width / app.frame.width, 0.55, accuracy: 0.03, "The paper keeps 55%")
        let close = app.buttons["sheet.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "The companion's ✕")
        XCTAssertLessThan(close.frame.maxX, app.placesMenu.frame.minX, "✕ clear of the places menu")
        XCTAssertTrue(app.placesMenu.isHittable, "The places menu stays usable over the companion")
        sleep(1)
        save("\(device)-paper-figure")
        close.tap()
        XCTAssertTrue(pane.waitForNonExistence(timeout: 5), "✕ closes the companion")
        wait("The paper takes the width") { abs(web.frame.width - app.frame.width) < 2 }
        XCTAssertTrue(figure.exists, "Still at the figure")

        // Chat about the figure, then Continue in Chat: Discuss, the figure's conversation at the top of the chat.
        for _ in 0..<4 where !(figure.exists && figure.isHittable) { web.swipeUp() }
        figure.tap()
        let ask = app.buttons["figureView.askInChat"]
        XCTAssertTrue(ask.waitForExistence(timeout: 5)); ask.tap()
        let context = element("contextChat.composer", app)
        XCTAssertTrue(context.waitForExistence(timeout: 8), "The figure's chat, in the companion")
        context.tap(); context.typeText("Which part matters most?")
        let open = app.buttons["figureView.openInChat"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(element("chat.promotedContext", app).waitForExistence(timeout: 15), "The explainer's content heads the chat")
        XCTAssertTrue(composer(app).waitForExistence(timeout: 5))
        wait("Discuss: the paper left, the chat right") { web.exists && web.frame.maxX <= self.composer(app).frame.minX + 1 }
        XCTAssertTrue(composerText(app).contains("Which part matters most?"), "The question came with it")
    }

    // MARK: - Feed | abstract

    /// The Feed place: the list on the left half, a placeholder on the right; picking a row shows its abstract and details
    /// there, never adding it; the list stays.
    func testTheFeedShowsTheAbstractBesideTheList() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        let app = launch()
        turnWide(app)
        app.show("feed")
        wait("Feed") { app.currentPlace == "Feed" }
        let placeholder = element("feed.abstract.placeholder", app)
        XCTAssertTrue(placeholder.waitForExistence(timeout: 8), "Nothing picked: a quiet placeholder")
        XCTAssertEqual(element("slots.divider", app).frame.midX / app.frame.width, 0.5, accuracy: 0.03, "The list on the left half")
        XCTAssertGreaterThan(placeholder.frame.minX, app.frame.width * 0.5, "The placeholder on the right")
        let options = app.buttons["Feed options"]
        // The list itself starts under the row (its first row then has the list's own 12 pt inset).
        assertOneRow(app, controls: [options], content: app.collectionViews.firstMatch)
        XCTAssertLessThan(options.frame.maxX, app.frame.width * 0.5, "The list's ⋯ ends the list's row")
        save("\(device)-feed-empty")
        let row = feedRow("2610.01234", app)
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        let rowFrame = row.frame
        row.tap()
        let title = element("feed.abstract.title", app)
        XCTAssertTrue(title.waitForExistence(timeout: 5), "The abstract pane")
        XCTAssertEqual(title.label, "Sparse Mixture-of-Experts Scaling Without Load-Balancing Losses")
        XCTAssertTrue(element("feed.abstract.text", app).label.hasPrefix("We show that expert routing"), "The whole abstract")
        XCTAssertTrue(app.buttons["feed.abstract.add"].exists, "Add to library")
        XCTAssertFalse(element("discover.setup.2610.01234", app).exists || element("feed.abstract.setup", app).exists,
                       "Picking a row adds nothing")
        XCTAssertGreaterThanOrEqual(title.frame.minX, app.frame.width * 0.5, "The details on the right")
        XCTAssertEqual(row.frame.minX, rowFrame.minX, accuracy: 1, "The list stays where it was")
        XCTAssertGreaterThan(title.frame.minY, app.placesMenu.frame.maxY, "The title starts below the places menu")
        save("\(device)-feed-abstract")
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
                turnWide(app)
                sleep(1)
                wideViews(app, prefix: "\(device)-sideways-\(appearance)")
            }
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
    }

    /// The owner's set (2026-10-23), light and dark: Library with nothing open, Library | paper, the divider dragged, Paper
    /// promoted, Paper | AI Explainer, Paper | equation view, Paper | chat, Feed | abstract, Feed with nothing picked,
    /// Chats, Snippets and the places menu open.
    func testWideGalleryForTheOwner() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        for appearance in ["light", "dark"] {
            let prefix = "\(device)-\(appearance)"
            let (studyApp, web) = launchStudyPaperBesideLibrary(appearance, mode: "equation")
            var app = studyApp
            save("\(prefix)-02-library-paper")
            // The divider dragged.
            let divider = element("slots.divider", app)
            let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 140, dy: 0)))
            sleep(1)
            save("\(prefix)-03-library-divider-dragged")
            element("slots.divider", app).doubleTap()
            sleep(1)
            // Paper promoted.
            app.buttons["paper.listToggle"].tap()
            wait("Paper alone") { app.currentPlace == "Paper" && abs(web.frame.width - app.frame.width) < 2 }
            sleep(1)
            save("\(prefix)-04-paper-promoted")
            // Paper | equation view.
            let number = web.staticTexts["(1)"].firstMatch
            for _ in 0..<6 where !(number.exists && number.isHittable) { web.swipeUp() }
            number.tap()
            let focus = app.revealEditMenuItem("Focus")
            if focus.exists {
                focus.tap()
                _ = app.buttons["equation.explain"].waitForExistence(timeout: 8)
                sleep(1)
                save("\(prefix)-06-paper-equation")
                if app.buttons["sheet.close"].exists { app.buttons["sheet.close"].tap() }
                _ = element("explain.pane", app).waitForNonExistence(timeout: 5)
            }
            // Paper | AI Explainer.
            app.buttons["Paper options"].tap()
            let explainer = app.buttons["paper.aiExplainer"]
            if explainer.waitForExistence(timeout: 5) {
                explainer.tap()
                _ = element("explain.pane", app).waitForExistence(timeout: 5)
                // Nothing kept yet: the model chooser asks first; this shows the explainer itself.
                if app.buttons["Cancel"].waitForExistence(timeout: 3) { app.buttons["Cancel"].tap() }
                sleep(2)
                save("\(prefix)-05-paper-ai-explainer")
                if app.buttons["sheet.close"].exists { app.buttons["sheet.close"].tap() }
                _ = element("explain.pane", app).waitForNonExistence(timeout: 5)
            } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap() }
            // Paper | chat.
            app.buttons["Paper options"].tap()
            app.buttons["Ask about this paper"].tap()
            _ = composer(app).waitForExistence(timeout: 8)
            sleep(1)
            save("\(prefix)-07-paper-chat")
            // Chats.
            choose("chat", app)
            wait("Chats") { app.currentPlace == "Chat" }
            sleep(1)
            save("\(prefix)-10-chats")
            // Snippets.
            app.show("notes")
            wait("Snippets") { app.currentPlace == "Snippets" }
            sleep(1)
            save("\(prefix)-11-snippets")
            // Feed with nothing picked, then an article picked.
            app.terminate()
            app = launch(appearance, extra: ["--nothing-open"])
            turnWide(app)
            _ = element("paper.placeholder", app).waitForExistence(timeout: 5)
            sleep(1)
            save("\(prefix)-01-library-empty")
            app.placesMenu.tap()
            _ = element("tab.feed", app).waitForExistence(timeout: 3)
            sleep(1)
            save("\(prefix)-12-places-menu")
            element("tab.feed", app).tap()
            wait("Feed") { app.currentPlace == "Feed" }
            _ = element("feed.abstract.placeholder", app).waitForExistence(timeout: 8)
            sleep(1)
            save("\(prefix)-09-feed-empty")
            feedRow("2610.01234", app).tap()
            _ = element("feed.abstract.title", app).waitForExistence(timeout: 5)
            sleep(1)
            save("\(prefix)-08-feed-abstract")
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

    /// The places capsule, once a software keyboard has gone (Tall hides it while one is up).
    private func showCapsule(_ app: XCUIApplication) {
        for _ in 0..<3 where !app.buttons["tab.paper"].exists {
            if app.buttons["chat.dismissKeyboard"].exists { app.buttons["chat.dismissKeyboard"].tap() }
            else if app.keyboards.firstMatch.exists { app.keyboards.buttons["Hide keyboard"].firstMatch.tap() }
            _ = app.buttons["tab.paper"].waitForExistence(timeout: 3)
        }
    }

    /// Tall: the same views one at a time (the iPhone app).
    private func tallViews(_ app: XCUIApplication, prefix: String) {
        showCapsule(app)
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

    /// Wide: each place's arrangement and the paper's views, through the places menu.
    private func wideViews(_ app: XCUIApplication, prefix: String) {
        // Discuss (the paper's chat was open in Tall).
        if !composer(app).exists || app.currentPlace != "Paper" {
            app.show("paper"); sleep(1)
            if !composer(app).exists, app.buttons["Paper options"].exists {
                app.buttons["Paper options"].tap(); app.buttons["Ask about this paper"].tap(); sleep(2)
            }
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
        // A figure page beside the paper.
        let web = app.webViews.firstMatch
        let figure = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open figure")).firstMatch
        for _ in 0..<4 where !(figure.exists && figure.isHittable) { web.swipeUp() }
        if figure.exists {
            figure.tap(); sleep(2)
            save("\(prefix)-explain")
            if app.buttons["sheet.close"].exists { app.buttons["sheet.close"].tap() }
            sleep(1)
        }
        // Library | paper (the list toggle).
        if app.buttons["paper.listToggle"].exists { app.buttons["paper.listToggle"].tap() }
        sleep(2)
        save("\(prefix)-library")
        menu("Library options", app, save: "\(prefix)-library-menu")
        // The places menu.
        _ = app.placeItem("chat"); sleep(1)
        save("\(prefix)-places-menu")
        // Chats.
        choose("chat", app); sleep(2)
        save("\(prefix)-chats")
        menu("Chat options", app, save: "\(prefix)-chats-menu")
        app.show("feed"); sleep(2)
        save("\(prefix)-feed")
        menu("Feed options", app, save: "\(prefix)-feed-menu")
        app.show("notes"); sleep(2)
        save("\(prefix)-snippets")
        menu("Snippets options", app, save: "\(prefix)-snippets-menu")
    }
}
