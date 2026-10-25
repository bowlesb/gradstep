import XCTest
import UIKit

/// Half a Wide row's height (52 pt): the row's top from its centre line.
private enum WideRow { static let half: CGFloat = 26 }

/// One app, two shapes (docs/DESIGN.md › Tall and Wide). An iPad upright is the iPhone app: the places capsule at the
/// bottom. Turned sideways it is Wide (owner, 2026-10-23): the places are a menu in the window's top-left corner, and each
/// place owns two slots — its list on the left, what was picked from it on the right, on a draggable divider (a double tap
/// lets the list cover the window, as on iPhone):
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
        // A long library (`--long-library-fixture`) has the sample in its middle, below the window's end.
        let list = app.collectionViews.firstMatch
        for _ in 0..<8 where !(app.buttons[sampleID].exists && app.buttons[sampleID].isHittable) { list.swipeUp(velocity: .slow) }
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

    /// The places menu stays in the window's top-left corner (owner correction, 2026-10-23).
    private func assertPlacesInTheCorner(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let frame = app.placesMenu.frame
        XCTAssertEqual(frame.minX, app.frame.minX + 12, accuracy: 2, "The places menu at the left edge", file: file, line: line)
        XCTAssertLessThan(frame.minY, app.frame.minY + 40, "The places menu at the top", file: file, line: line)
    }

    /// No control of the leftmost slot's row sits under the places menu (one snapshot).
    private func assertNothingUnderThePlaces(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let places = app.placesMenu.frame
        guard let snapshot = try? app.snapshot() else { return XCTFail("A snapshot", file: file, line: line) }
        var under: [String] = []
        func visit(_ node: XCUIElementSnapshot) {
            // (The places menu's own button reports its frame without its identifier.)
            if [.button, .textField, .searchField, .segmentedControl].contains(node.elementType), node.identifier != "places.menu",
               node.frame != places, node.frame.width > 0, node.frame.intersects(places.insetBy(dx: 2, dy: 2)) {
                under.append("\(node.identifier.isEmpty ? node.label : node.identifier) \(node.elementType.rawValue) \(node.frame)")
            }
            node.children.forEach(visit)
        }
        visit(snapshot)
        XCTAssertTrue(under.isEmpty, "Under the places menu: \(under)", file: file, line: line)
    }

    /// A slot's ⋯ at that slot's top-right: here the window's right edge.
    private func assertAtTheRightEdge(_ control: XCUIElement, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(control.frame.maxX, app.frame.maxX - 12, accuracy: 2, "\(control.label) at the right edge", file: file, line: line)
    }

    /// The leftmost slot's first control starts after the places menu.
    private func assertAfterThePlaces(_ control: XCUIElement, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(control.frame.minX, app.placesMenu.frame.maxX + 4, "\(control.label) after the places menu",
                                    file: file, line: line)
    }

    /// A place straight from the places menu (Chat is the conversation last shown, beside All chats; owner, 2026-10-24).
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
        XCTAssertEqual(web.frame.width / app.frame.width, 0.5, accuracy: 0.03, "The paper's slot is about half")
        XCTAssertEqual(composerText(app), draft, "The unsent question came with the chat")
        wait("The same place in the paper (\(place))") { self.inViewport(self.paragraph(app, startingWith: place), app) }
        assertOneRow(app, controls: [app.buttons["paper.contents"], app.buttons["Paper options"], app.buttons["chat.history"],
                                     app.buttons["Chat options"], app.buttons["chat.close"]], content: web, budget: 1)
        assertPlacesInTheCorner(app)
        XCTAssertLessThan(app.buttons["chat.close"].frame.maxX, app.buttons["Chat options"].frame.minX, "The companion's ✕ before its ⋯")
        assertAtTheRightEdge(app.buttons["Chat options"], app)
        assertAfterThePlaces(app.buttons["paper.contents"], app)
        XCTAssertGreaterThanOrEqual(composer(app).frame.maxY, app.frame.maxY - 90, "The message box at the bottom, nothing under it")
        XCTAssertFalse(app.buttons["Settings"].exists, "No gear: Settings is in the places menu")
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
        assertAtTheRightEdge(app.buttons["Chat options"], app)
        assertAfterThePlaces(search, app)
        assertPlacesInTheCorner(app)
        XCTAssertTrue(element("slots.divider", app).exists, "A divider between the slots")
        save("\(device)-view-chats")
        XCUIDevice.shared.orientation = .portrait
        wait("Still on Chat upright") { app.buttons["tab.chat"].isSelected && !app.placesMenu.exists }
        XCTAssertEqual(composerText(app), "A general question")
    }

    // MARK: - The places menu

    /// The places menu: the five places and Settings beside Snippets (owner, 2026-10-24: "put Settings here beside Snippets";
    /// no Search: "if I want a search, I could just go and search the library"), the current one checked and named by the
    /// button; choosing one goes there, and the button stays in the same corner in every place.
    func testThePlacesMenuSwitchesPlacesAndShowsTheCurrentOne() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        let app = launch(extra: ["--nothing-open"])
        turnWide(app)
        XCTAssertEqual(app.currentPlace, "Library")
        XCTAssertFalse(app.buttons["tab.library"].exists, "No capsule: the places are in the menu")
        let corner = app.placesMenu.frame
        assertPlacesInTheCorner(app)
        assertNothingUnderThePlaces(app)
        app.placesMenu.tap()
        let ids = ["feed", "library", "paper", "chat", "notes", "settings"]
        for id in ids {
            XCTAssertTrue(element("tab.\(id)", app).waitForExistence(timeout: 3), "The menu has \(id)")
        }
        for (above, below) in zip(ids, ids.dropFirst()) {
            XCTAssertLessThan(element("tab.\(above)", app).frame.minY, element("tab.\(below)", app).frame.minY, "\(above) above \(below)")
        }
        XCTAssertFalse(element("tab.paper", app).isEnabled, "Paper needs a paper")
        XCTAssertFalse(element("tab.search", app).exists, "No Search place: the Library's field searches")
        XCTAssertFalse(app.buttons["Search"].exists, "No Search row")
        XCTAssertFalse(app.buttons["menu.settings"].exists, "Settings is a place row, not a section of its own")
        save("\(device)-places-menu")
        // Settings opens over the place, as before; Done returns.
        element("tab.settings", app).tap()
        let settingsBar = app.navigationBars["Settings"]
        XCTAssertTrue(settingsBar.waitForExistence(timeout: 8), "Settings")
        settingsBar.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(settingsBar.waitForNonExistence(timeout: 5))
        wait("Still the Library") { app.currentPlace == "Library" }
        element("tab.feed", app).tap()
        wait("Feed") { app.currentPlace == "Feed" }
        XCTAssertTrue(app.buttons["Feed options"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.placesMenu.frame, corner, "The same spot"); assertNothingUnderThePlaces(app)
        app.buttons["Feed options"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["Report this screen"].firstMatch.waitForExistence(timeout: 3), "The ⋯ menu is open")
        XCTAssertFalse(app.buttons["menu.settings"].exists, "No Settings in a ⋯ menu here: it is in the places menu")
        // A tap outside closes it (Escape reaches a menu only with a hardware keyboard attached, which the Simulator's
        // runner doesn't guarantee): on the right slot's placeholder, which a tap doesn't change.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.6)).tap()
        wait("The ⋯ menu closed") { !app.descendants(matching: .any)["Report this screen"].firstMatch.exists }
        choose("chat", app)
        wait("Chat") { app.currentPlace == "Chat" }
        XCTAssertEqual(app.placesMenu.frame, corner, "The same spot"); assertNothingUnderThePlaces(app)
        app.show("notes")
        wait("Snippets") { app.currentPlace == "Snippets" }
        XCTAssertEqual(app.placesMenu.frame, corner, "The same spot"); assertNothingUnderThePlaces(app)
        // Search: the Library's own field.
        choose("library", app)
        wait("Library") { app.currentPlace == "Library" }
        element("library.search", app).tap()
        wait("Searching the Library") { app.segmentedControls["library.searchScope"].exists }
        // The hardware keyboard first, in the focused field: on the Simulator the first key event of a launch never runs a
        // keyboard shortcut (⌘1 failed on 3 of 3 fresh launches with nothing typed before it, while typed letters arrive),
        // which made this check flaky. A letter that reaches the field proves later keys are delivered (⌘1 then passed 4 of 4).
        let field = element("library.search", app)
        app.typeKey("x", modifierFlags: [])
        wait("A typed letter reaches the search field") { (field.value as? String) == "x" }
        app.buttons["library.search.cancel"].tap()
        wait("Search ended") { !app.segmentedControls["library.searchScope"].exists }
        // ⌘2 with a hardware keyboard: Library; ⌘1: Feed.
        app.typeKey("1", modifierFlags: .command)
        wait("⌘1 is Feed") { app.currentPlace == "Feed" }
        app.typeKey("2", modifierFlags: .command)
        wait("⌘2 is Library") { app.currentPlace == "Library" }
    }

    /// The places menu is one list (owner, TestFlight 91: "why is there a larger space between snippets and search? That
    /// seems a little bit confusing"): Settings follows Snippets at the same spacing as the places (no Search row, owner
    /// 2026-10-24).
    func testThePlacesMenuIsOneList() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        for appearance in ["light", "dark"] {
            let app = launch(appearance, extra: ["--nothing-open"])
            turnWide(app)
            app.placesMenu.tap()
            let ids = ["tab.feed", "tab.library", "tab.paper", "tab.chat", "tab.notes", "tab.settings"]
            for id in ids { XCTAssertTrue(element(id, app).waitForExistence(timeout: 3), "The menu has \(id)") }
            sleep(1)
            save("\(device)-places-menu-one-list-\(appearance)")
            let frames = ids.map { element($0, app).frame }
            let gaps = zip(frames, frames.dropFirst()).map { $1.minY - $0.maxY }
            let usual = gaps[0]
            for (index, gap) in gaps.enumerated() {
                XCTAssertEqual(gap, usual, accuracy: 1.5, "\(ids[index]) → \(ids[index + 1]): \(gaps)")
            }
            app.terminate()
        }
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
        XCTAssertEqual(divider.frame.midX / app.frame.width, 0.5, accuracy: 0.03, "The list on the left from the start, half")
        XCTAssertLessThan(app.buttons[sampleID].frame.maxX, placeholder.frame.minX, "The placeholder on the right")
        let options = app.buttons["Library options"]
        assertOneRow(app, controls: [options], content: app.buttons[sampleID])
        XCTAssertLessThan(options.frame.maxX, app.frame.width * 0.5, "The list's ⋯ ends the list's row")
        assertAfterThePlaces(element("library.search", app), app)
        save("\(device)-library-empty")
        let web = openSampleBesideLibrary(app)
        XCTAssertEqual(web.frame.minX / app.frame.width, 0.5, accuracy: 0.03, "The list takes about half")
        assertOneRow(app, controls: [app.buttons["paper.listToggle"], app.buttons["paper.contents"], app.buttons["Paper options"]],
                     content: web, budget: 1)
        assertAtTheRightEdge(app.buttons["Paper options"], app)
        XCTAssertGreaterThan(app.buttons["paper.listToggle"].frame.minX, web.frame.minX, "The paper's controls in its own slot")
        save("\(device)-library-paper")

        // Drag the divider 160 pt to the right: the list grows with it (both slots follow the finger) and stays there.
        let before = web.frame.minX
        XCTAssertTrue(divider.exists)
        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 160, dy: 0)), withVelocity: 300,
                    thenHoldForDuration: 0.3)
        wait("The divider moved") { abs(web.frame.minX - (before + 160)) < 6 }
        XCTAssertEqual(divider.frame.midX, web.frame.minX, accuracy: 4, "The divider at the paper's edge")
        save("\(device)-library-divider-dragged")
        // Dragged past the list's minimum (280 pt) but short of closing it: the list stops at its minimum, the paper stays.
        let drag = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        drag.press(forDuration: 0.1, thenDragTo: drag.withOffset(CGVector(dx: -(divider.frame.midX - 280 + 20), dy: 0)))
        wait("The list at its minimum") { abs(web.frame.minX - 281) < 6 }
        XCTAssertEqual(app.currentPlace, "Library", "Still the Library: the list didn't close")
        let back = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        back.press(forDuration: 0.1, thenDragTo: back.withOffset(CGVector(dx: before + 160 - divider.frame.midX, dy: 0)))
        wait("The divider back where it was dragged") { abs(web.frame.minX - (before + 160)) < 6 }
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
        // Double-tap (owner, 2026-10-23: "have the list be right over the entire paper, the same way as the iphone"): the
        // list covers the window, the places menu still in its corner; the grabber at the far edge brings the slots back.
        kept.doubleTap()
        let uncover = element("slots.uncover", app)
        XCTAssertTrue(uncover.waitForExistence(timeout: 5), "The list covers the window, with a grabber at its edge")
        wait("No divider while covering") { !kept.exists }
        assertAtTheRightEdge(app.buttons["Library options"], app)
        assertPlacesInTheCorner(app)
        // (XCUITest still lists the covered slot's UIKit-hosted elements; VoiceOver's modal rule is not visible here.)
        XCTAssertFalse(element("paper.placeholder", app).isHittable, "The right slot beneath the list")
        XCTAssertGreaterThan(uncover.frame.midX, app.frame.width - 40, "The grabber at the right edge")
        uncover.tap()
        wait("The two slots again, at the kept divider") { kept.exists && abs(kept.frame.midX - (before + 160)) < 8 }
        XCTAssertTrue(element("paper.placeholder", app).exists, "The right slot again")
    }

    /// The Library's and the Feed's tables while the divider narrows their slot (owner, 2026-10-24: "the column of the
    /// titles gets over the left side of the screen when using real time live update … using the vertical divider slider
    /// to the left"). The divider is dragged left slowly in steps, the finger held at each, down to the list's minimum, then
    /// back. XCUITest can't look while the finger is down, so the table is checked each time it rests (each step is the
    /// same live drag); PaperTableWidthTests checks every few points of a drag in a hosted table.
    func testTablesStayInsideTheirSlotWhileTheDividerNarrowsThem() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        let app = launch(extra: ["--nothing-open", "--library-layout=table", "--feed-layout=table"], library: false)
        turnWide(app)
        for (place, table) in [("library", "library.table"), ("feed", "feed.table")] {
            if app.currentPlace?.lowercased() != place { app.show(place) }
            let title = element("\(table).header.title", app)
            XCTAssertTrue(title.waitForExistence(timeout: 15), "The \(place) table")
            let divider = element("slots.divider", app)
            XCTAssertTrue(divider.waitForExistence(timeout: 5))
            let minimum: CGFloat = 281   // the list's 280 pt and the hairline
            save("\(device)-\(place)-table-divider-start")
            assertTableInsideItsSlot(table, divider: divider, app, "\(place) at rest")
            var step = 0
            while divider.frame.midX > minimum + 2, step < 12 {
                step += 1
                let from = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                // The last step goes past the minimum: the list stops there (nothing is open, so it doesn't close).
                let distance = min(90, divider.frame.midX - minimum + 30)
                from.press(forDuration: 0.2, thenDragTo: from.withOffset(CGVector(dx: -distance, dy: 0)), withVelocity: 60,
                           thenHoldForDuration: 1.0)
                sleep(1)
                save("\(device)-\(place)-table-divider-step\(step)")
                assertTableInsideItsSlot(table, divider: divider, app, "\(place) step \(step)")
            }
            XCTAssertEqual(divider.frame.midX, minimum, accuracy: 3, "The \(place) list at its minimum")
            // And back to the middle, widening it again.
            let back = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            back.press(forDuration: 0.2, thenDragTo: back.withOffset(CGVector(dx: app.frame.width / 2 - divider.frame.midX, dy: 0)),
                       withVelocity: 120, thenHoldForDuration: 0.5)
            sleep(1)
            save("\(device)-\(place)-table-divider-back")
            assertTableInsideItsSlot(table, divider: divider, app, "\(place) back in the middle")
        }
    }

    /// The table's title header and its rows' titles (the row itself when every column fits) inside the list's slot: from
    /// the window's left edge to the divider. (Columns scrolling sideways may run under the region's clip, so only the
    /// title column is measured.)
    private func assertTableInsideItsSlot(_ table: String, divider: XCUIElement, _ app: XCUIApplication, _ moment: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        guard let snapshot = try? app.snapshot() else { return XCTFail("A snapshot", file: file, line: line) }
        let edge = divider.frame.midX, left = app.frame.minX
        var titles: [(String, CGRect)] = []
        func visit(_ node: XCUIElementSnapshot) {
            let id = node.identifier
            if id == "\(table).header.title" || (id.hasPrefix("\(table).") && !id.hasPrefix("\(table).header.")
                                                  && id != "\(table).sortIndicator" && id != table),
               node.frame.height > 0 {
                titles.append((id, node.frame))
            }
            node.children.forEach(visit)
        }
        visit(snapshot)
        XCTAssertTrue(titles.contains { $0.0 == "\(table).header.title" }, "The title header (\(moment))", file: file, line: line)
        XCTAssertGreaterThan(titles.count, 1, "Rows (\(moment))", file: file, line: line)
        for (id, frame) in titles where frame.maxY > app.frame.minY && frame.minY < app.frame.maxY {
            // The title header sits inside the row's margin; a row reports its whole cell, from the slot's edge.
            let start = id == "\(table).header.title" ? left + 8 : left - 0.5
            XCTAssertGreaterThanOrEqual(frame.minX, start, "\(id) starts inside the window's left edge: \(frame) (\(moment))",
                                        file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, edge + 1, "\(id) ends before the divider at \(edge): \(frame) (\(moment))",
                                     file: file, line: line)
        }
    }

    /// The list covering the window (a double tap on the divider) splits again when a paper is picked: the paper on its
    /// right, the list at the divider's place.
    func testPickingFromAListCoveringTheWindowSplitsItAgain() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        let app = launch(extra: ["--nothing-open"])
        turnWide(app)
        let divider = element("slots.divider", app)
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        divider.doubleTap()
        let uncover = element("slots.uncover", app)
        XCTAssertTrue(uncover.waitForExistence(timeout: 5), "The list covers the window")
        sleep(1)
        save("\(device)-library-covering")
        let row = app.buttons[sampleID]
        assertAtTheRightEdge(app.buttons["Library options"], app)
        XCTAssertFalse(element("paper.placeholder", app).isHittable, "The right slot beneath the list")
        row.tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.staticTexts["An interactive reading sample · 2026"].waitForExistence(timeout: 15), "The paper is ready")
        wait("Split again: the list left, the paper right") { !uncover.exists && divider.exists && web.frame.minX > 200 }
        XCTAssertEqual(web.frame.minX / app.frame.width, 0.5, accuracy: 0.03, "At the divider's place")
        XCTAssertLessThanOrEqual(row.frame.maxX, web.frame.minX + 1, "The list left, the paper right")
        XCTAssertEqual(app.currentPlace, "Library", "Still the Library")
        // Covering again and picking the same paper again also splits.
        divider.doubleTap()
        XCTAssertTrue(uncover.waitForExistence(timeout: 5))
        row.tap()
        wait("The same paper picked again: split") { !uncover.exists && divider.exists && web.frame.minX > 200 }
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
        // A live drag (the paper reflowing under the finger) keeps the paragraph at the top of the page.
        let top = paragraph(app, startingWith: place).frame.minY - web.frame.minY
        let handle = element("slots.divider", app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        handle.press(forDuration: 0.1, thenDragTo: handle.withOffset(CGVector(dx: 200, dy: 0)), withVelocity: 200, thenHoldForDuration: 0.3)
        wait("The paper narrower") { web.frame.minX > app.frame.width * 0.6 }
        sleep(1)
        XCTAssertEqual(paragraph(app, startingWith: place).frame.minY - web.frame.minY, top, accuracy: 60,
                       "The same paragraph at the top of the page after the drag")
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

    /// Search (the Library's field): a result opens on the right and the list stays.
    func testSearchKeepsTheListAfterOpeningAResult() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        let app = launch()
        _ = try wideSample(app)
        let web = app.webViews.firstMatch
        app.buttons["paper.listToggle"].tap()
        wait("The Library beside the paper") { app.currentPlace == "Library" }
        element("library.search", app).tap()
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
    private func launchStudyPaperBesideLibrary(_ appearance: String = "light", mode: String = "figure_walkthrough",
                                               extra: [String] = []) -> (XCUIApplication, XCUIElement) {
        let app = launch(appearance, extra: ["--chat-fixture-mode=\(mode)", "--study-fixture"] + extra, library: false)
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
        XCTAssertEqual(web.frame.width / app.frame.width, 0.5, accuracy: 0.03, "The paper keeps half")
        let close = app.buttons["sheet.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "The companion's ✕")
        XCTAssertGreaterThan(close.frame.minX, pane.frame.minX, "✕ in the companion's own row")
        XCTAssertLessThan(app.placesMenu.frame.maxX, web.frame.maxX, "The places menu over the paper's corner, not the companion's")
        assertAfterThePlaces(app.buttons["paper.listToggle"], app)
        XCTAssertTrue(app.placesMenu.isHittable, "The places menu stays usable beside the companion")
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

    // MARK: - Chats: continuity (owner session 2026-10-24, TestFlight 91)

    /// The selected row of the Chat place's list (All chats beside the conversation).
    private func selectedChatRow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND selected == true", "chat.history.")).firstMatch
    }

    /// F6: Continue in Chat from a figure's AI Explainer leaves the keyboard down ("wait for the person to click on the
    /// keyboard before bringing the keyboard up"); a tap in the message box brings it up. F7: Chat in the places menu then
    /// shows that same conversation beside All chats, its row selected and in view ("it needs to take me to the chat that I
    /// was just looking at, and that specific chat should be selected… on the left").
    func testContinueInChatWaitsForATapAndChatShowsThatChatSelected() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        let (app, web) = launchStudyPaperBesideLibrary()
        let figure = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open figure")).firstMatch
        for _ in 0..<8 where !(figure.exists && figure.isHittable) { web.swipeUp() }
        XCTAssertTrue(figure.waitForExistence(timeout: 5), "A figure in the paper")
        figure.tap()
        // As in the session: the figure's AI Explainer, its walkthrough read, nothing typed.
        let explain = app.buttons["figureView.explain"]
        XCTAssertTrue(explain.waitForExistence(timeout: 5)); explain.tap()
        if app.buttons["ai.chooseModel"].waitForExistence(timeout: 5) {
            app.buttons["ai.chooseModel"].tap()
            XCTAssertTrue(app.buttons["ai.chooseCloud"].waitForExistence(timeout: 5)); app.buttons["ai.chooseCloud"].tap()
        }
        XCTAssertTrue(element("figureView.section.1", app).waitForExistence(timeout: 15), "The walkthrough")
        wait("The walkthrough is done", timeout: 20) { !self.element("figureView.progress", app).exists }
        XCTAssertTrue(element("contextChat.composer", app).waitForExistence(timeout: 8), "The figure's chat, in the companion")
        XCTAssertEqual(app.keyboards.count, 0, "Nothing typed in the explainer")
        save("\(device)-f6-explainer")
        let open = app.buttons["figureView.openInChat"]
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
        XCTAssertTrue(element("chat.promotedContext", app).waitForExistence(timeout: 15), "The explainer's content heads the chat")
        XCTAssertTrue(composer(app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 2), "Continue in Chat leaves the keyboard down")
        XCTAssertFalse((composer(app).value(forKey: "hasKeyboardFocus") as? Bool) ?? false, "The message box waits for a tap")
        save("\(device)-f6-continue-in-chat")

        // A tap brings the keyboard; the question saves the conversation.
        composer(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "A tap in the message box brings the keyboard")
        composer(app).typeText("Which part matters most?")
        app.buttons["chat.send"].tap()
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "You: Which part matters most?")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 15), "The question is in the conversation")
        let hide = app.keyboards.buttons["Hide keyboard"].firstMatch
        if hide.exists { hide.tap() }
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        sleep(2)

        // Chat from the places menu: the same conversation, its row selected in the list beside it.
        choose("chat", app)
        wait("Chat") { app.currentPlace == "Chat" }
        XCTAssertTrue(element("chat.history.table", app).waitForExistence(timeout: 5), "All chats on the left")
        XCTAssertTrue(element("chat.promotedContext", app).waitForExistence(timeout: 5), "The figure's conversation, not a new chat")
        XCTAssertNotEqual(app.buttons["chat.context"].label, "Conversation: New chat")
        let row = selectedChatRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The conversation is selected in the list")
        XCTAssertTrue(row.isHittable, "…and in view")
        XCTAssertLessThan(row.frame.maxX, composer(app).frame.minX + 1, "The list left, the chat right")
        XCTAssertEqual(app.keyboards.count, 0, "Going to Chat leaves the keyboard down")
        save("\(device)-f7-chat-keeps-the-conversation")

        // Another place and back: still that conversation.
        app.show("library")
        wait("Library") { app.currentPlace == "Library" }
        choose("chat", app)
        wait("Chat again") { app.currentPlace == "Chat" }
        XCTAssertTrue(element("chat.promotedContext", app).waitForExistence(timeout: 5), "Still the figure's conversation")
        XCTAssertTrue(selectedChatRow(app).waitForExistence(timeout: 5), "Still selected")
    }

    /// F8: beside the list, All chats is not in the chat's ⋯ (it opened a centred sheet duplicating the list: "we're never
    /// gonna have this middle thing show up"); the list's own ⋯ has Sort by ("Why are those options not on the list on the
    /// left?"). Picking a row selects it there.
    func testAllChatsIsTheListBesideTheChatWithItsOwnSortBy() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        let app = launch(extra: ["--chat-history-fixture"])
        turnWide(app)
        choose("chat", app)
        wait("Chat") { app.currentPlace == "Chat" }
        func row(_ n: Int) -> XCUIElement { app.buttons[String(format: "chat.history.c4a7c4a7-0000-4000-8000-%012ld", n)] }
        XCTAssertTrue(row(1).waitForExistence(timeout: 8), "The fixture's chats in the list")

        app.buttons["Chat options"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["Report this screen"].firstMatch.waitForExistence(timeout: 3), "The chat's ⋯ is open")
        XCTAssertFalse(app.buttons["All chats"].exists, "No All chats in the chat's ⋯ beside the list")
        save("\(device)-f8-chat-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        wait("The ⋯ menu closed") { !app.descendants(matching: .any)["Report this screen"].firstMatch.exists }

        // The list's own ⋯: Sort by.
        let options = app.buttons["chat.history.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5), "The list has its options")
        XCTAssertGreaterThan(options.frame.minX, element("chat.history.search", app).frame.maxX, "⋯ after the search field")
        XCTAssertLessThan(options.frame.maxX, composer(app).frame.minX, "…in the list's slot")
        options.tap()
        let sortBy = app.buttons["chat.history.sort"].exists ? app.buttons["chat.history.sort"]
            : app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sort by")).firstMatch
        XCTAssertTrue(sortBy.waitForExistence(timeout: 3), "Sort by in the list's ⋯")
        save("\(device)-f8-list-menu")
        sortBy.tap()
        let byName = app.buttons["Conversation"].firstMatch
        XCTAssertTrue(byName.waitForExistence(timeout: 3)); byName.tap()
        XCTAssertTrue(row(27).waitForExistence(timeout: 5) && row(17).waitForExistence(timeout: 5))
        XCTAssertLessThan(row(27).frame.minY, row(17).frame.minY, "A–Z: “Batch norm…” before “Bottleneck…”")
        save("\(device)-f8-list-sorted")

        // Picking a row opens it beside the list, selected there.
        row(27).tap()
        wait("The picked row is selected") { row(27).isSelected }
        XCTAssertEqual(app.currentPlace, "Chat", "Still the Chat place")
    }

    // MARK: - Navigation after TestFlight 91 (owner session 2026-10-24)

    /// G5: upright, the iPad's bar has six places, Settings beside Snippets on the right ("on the iPad we could actually have
    /// six along the bottom"), and no ⋯ menu has Settings ("we're going to move that so we don't see it there anymore").
    /// Settings opens over the screen as before and Done returns. G17: the Feed's ⋯ has no "Hide papers in your library".
    /// Upright, All chats is still the sheet (no list beside the chat in Tall).
    func testUprightTheBarHasSixPlacesWithSettingsBesideSnippets() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Tall on iPad")
        let app = launch(extra: ["--chat-history-fixture"])
        let ids = ["feed", "library", "paper", "chat", "notes", "settings"]
        let items = ids.map { app.buttons["tab.\($0)"] }
        for (id, item) in zip(ids, items) { XCTAssertTrue(item.waitForExistence(timeout: 5), "The bar has \(id)") }
        for (left, right) in zip(items, items.dropFirst()) {
            XCTAssertEqual(left.frame.midY, right.frame.midY, accuracy: 1, "One row")
            XCTAssertLessThan(left.frame.maxX, right.frame.minX + 1, "\(left.label) before \(right.label)")
        }
        XCTAssertGreaterThan(items[5].frame.midY, app.frame.height * 0.85, "At the bottom")
        XCTAssertFalse(app.placesMenu.exists, "Upright: no places menu")
        save("\(device)-tall-bar-six")
        // Settings opens over the Library; Done returns there.
        items[5].tap()
        let bar = app.navigationBars["Settings"]
        XCTAssertTrue(bar.waitForExistence(timeout: 8), "Settings")
        save("\(device)-tall-settings")
        bar.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
        wait("Back on the Library") { app.buttons["tab.library"].isSelected && app.buttons[self.sampleID].isHittable }
        // No Settings in the Library's ⋯; its All chats is still the sheet upright.
        app.buttons["Library options"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["Report this screen"].firstMatch.waitForExistence(timeout: 3), "The ⋯ menu is open")
        XCTAssertFalse(app.buttons["menu.settings"].exists, "No Settings in the Library's ⋯")
        save("\(device)-tall-library-menu")
        app.buttons["All chats"].firstMatch.tap()
        let listOptions = app.buttons["chat.history.options"]
        XCTAssertTrue(listOptions.waitForExistence(timeout: 5), "All chats upright")
        listOptions.tap()
        XCTAssertTrue(app.buttons["chat.history.close"].waitForExistence(timeout: 3), "…the sheet, with its Close")
        app.buttons["chat.history.close"].tap()
        XCTAssertTrue(listOptions.waitForNonExistence(timeout: 5))
        // The Feed's ⋯: neither Settings nor the hide-library option.
        app.buttons["tab.feed"].tap()
        let options = app.buttons["Feed options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10)); options.tap()
        XCTAssertTrue(app.descendants(matching: .any)["Report this screen"].firstMatch.waitForExistence(timeout: 3), "The ⋯ menu is open")
        XCTAssertFalse(app.buttons["menu.settings"].exists, "No Settings in the Feed's ⋯")
        XCTAssertFalse(app.descendants(matching: .any)["feed.hideLibrary"].firstMatch.exists, "Hiding library papers is not an option")
        save("\(device)-tall-feed-menu")
    }

    /// G6: no Search place on iPad ("if I want a search, I could just go and search the library"): sideways, the Library's
    /// own field searches the library and, with its switch, ML papers, as on iPhone.
    func testTheLibrarysFieldSearchesMLPapersSideways() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        let app = XCUIApplication()
        app.launchArguments = ["--library-v5-fixture", "-appearance", "light"]
        app.launch()
        turnWide(app)
        wait("Library") { app.currentPlace == "Library" }
        app.placesMenu.tap()
        XCTAssertTrue(element("tab.library", app).waitForExistence(timeout: 3))
        XCTAssertFalse(element("tab.search", app).exists, "No Search place")
        element("tab.library", app).tap()
        let field = element("library.search", app)
        XCTAssertTrue(field.waitForExistence(timeout: 15)); field.tap()
        let scope = app.segmentedControls["library.searchScope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5), "The Library | ML paper search switch under the field")
        scope.buttons["ML paper search"].tap()
        field.typeText("sparse experts\n")
        XCTAssertTrue(element("discover.result.2610.01234", app).waitForExistence(timeout: 15), "ML papers from the Library's field")
        XCTAssertEqual(app.currentPlace, "Library", "Still the Library place")
        save("\(device)-library-ml-search")
    }

    /// Owner, 2026-10-24: "remove the middle pop up window and make [them] go on top of their side panel for consistency".
    /// Sideways, every route to All chats shows the list in the Chat place's left slot beside the conversation — on This
    /// paper when the route comes from a paper — never a centred sheet: the Library's ⋯, a paper's "Chats about this paper",
    /// Discuss's clock, the chat's ⋯ beside the paper, and Settings › Your assets › Chats.
    func testEveryRouteToAllChatsShowsTheListBesideTheChat() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        let app = launch(extra: ["--chat-history-fixture"])
        turnWide(app)
        let table = element("chat.history.table", app)
        func assertBeside(_ route: String, thisPaper: Bool, line: UInt = #line) {
            wait("\(route): the Chat place", line: line) { app.currentPlace == "Chat" }
            XCTAssertTrue(table.waitForExistence(timeout: 5), "\(route): the list", line: line)
            XCTAssertTrue(composer(app).waitForExistence(timeout: 5), "\(route): the conversation", line: line)
            XCTAssertLessThan(table.frame.maxX, composer(app).frame.minX + 1, "\(route): the list on the left", line: line)
            XCTAssertLessThan(table.frame.minX, app.frame.minX + 2, "\(route): in the left slot, not a centred sheet", line: line)
            let chip = app.buttons["chat.history.filter.\(thisPaper ? "thisPaper" : "all")"]
            XCTAssertTrue(chip.waitForExistence(timeout: 5), "\(route): the chip", line: line)
            wait("\(route): \(thisPaper ? "This paper" : "All") chosen", line: line) { chip.isSelected }
        }
        func discuss() {
            app.show("library")
            wait("Library") { app.currentPlace == "Library" }
            app.buttons["Paper options"].tap()
            app.buttons["Ask about this paper"].tap()
            wait("Discuss") { app.currentPlace == "Paper" && self.composer(app).exists }
        }
        // The Library's ⋯.
        if app.currentPlace != "Library" { app.show("library") }
        app.buttons["Library options"].tap()
        app.buttons["All chats"].firstMatch.tap()
        assertBeside("The Library's ⋯", thisPaper: false)
        save("\(device)-all-chats-from-library")
        // A paper's ⋯ › Chats about this paper.
        _ = openSampleBesideLibrary(app)
        app.buttons["Paper options"].tap()
        let paperChats = app.buttons["paper.chats"]
        XCTAssertTrue(paperChats.waitForExistence(timeout: 5), "The sample has chats"); paperChats.tap()
        assertBeside("Chats about this paper", thisPaper: true)
        save("\(device)-all-chats-from-paper")
        // Discuss's clock.
        discuss()
        let clock = app.buttons["chat.history"]
        XCTAssertTrue(clock.waitForExistence(timeout: 5)); clock.tap()
        assertBeside("Discuss's clock", thisPaper: true)
        save("\(device)-all-chats-from-discuss")
        // The chat's ⋯ beside the paper.
        discuss()
        app.buttons["Chat options"].tap()
        let all = app.buttons["All chats"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 3)); all.tap()
        assertBeside("The chat's ⋯", thisPaper: true)
        // Settings › Your assets › Chats: Settings closes; the list on All.
        app.openSettingsFromMenu()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8))
        let chatsRow = app.descendants(matching: .any)["settings.chats"]
        for _ in 0..<6 where !(chatsRow.exists && chatsRow.isHittable) { app.swipeUp() }
        chatsRow.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 5), "Settings closes")
        assertBeside("Settings › Chats", thisPaper: false)
        save("\(device)-all-chats-from-settings")
    }

    /// A figure opened from the paper beside the Library goes straight to Paper | figure page (owner, TestFlight 91: "there
    /// was an animation that was kind of weird… maybe it might work just not to have an animation, just to go there"): no
    /// slide of the list out, the paper across or the page in. The slots' own animation is slowed twelvefold
    /// (`--slot-animation-slow`), so a slide would still be under way at the first look after the tap. Closing it is
    /// instant too; the list toggle still animates.
    func testAFigureOpensBesideThePaperAtOnce() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        for appearance in ["light", "dark"] {
            let (app, web) = launchStudyPaperBesideLibrary(appearance, extra: ["--slot-animation-slow=12"])
            let figure = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open figure")).firstMatch
            for _ in 0..<8 where !(figure.exists && figure.isHittable) { web.swipeUp() }
            XCTAssertTrue(figure.waitForExistence(timeout: 5), "A figure in the paper")
            save("\(device)-figure-before-tap-\(appearance)")
            let tapped = Date()
            figure.tap()
            let pane = element("explain.pane", app)
            XCTAssertTrue(pane.waitForExistence(timeout: 2), "The figure's page in the companion slot")
            // One look, as soon as the page exists: everything is already where it ends.
            let paperFrame = web.frame, paneFrame = pane.frame, window = app.frame
            let looked = Date().timeIntervalSince(tapped)
            save("\(device)-figure-at-once-\(appearance)")
            XCTAssertEqual(paperFrame.minX, window.minX, accuracy: 2, "The paper is already at the left (\(paperFrame), \(looked) s)")
            XCTAssertEqual(paperFrame.width / window.width, 0.5, accuracy: 0.03, "and at half the width (\(paperFrame))")
            XCTAssertEqual(paneFrame.minX, paperFrame.maxX, accuracy: 3, "The figure page is already beside it (\(paneFrame))")
            XCTAssertEqual(paneFrame.maxX, window.maxX, accuracy: 2, "to the window's edge (\(paneFrame))")
            XCTAssertFalse(app.buttons["Library options"].exists, "The list is gone")
            XCTAssertEqual(app.currentPlace, "Paper")

            // ✕: the paper takes the width at once as well.
            let close = app.buttons["sheet.close"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            close.tap()
            XCTAssertTrue(pane.waitForNonExistence(timeout: 2), "✕ closes the companion")
            let widened = web.frame
            XCTAssertEqual(widened.width, window.width, accuracy: 2, "The paper takes the width at once (\(widened))")
            app.terminate()
        }
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
        // Text size floats over nothing in Wide (TestFlight 90 follow-up: A− / A+ sat over the Feed's rows): it is in the ⋯.
        XCTAssertFalse(app.buttons["feed.textSize.larger"].exists, "No A− / A+ floating over the Feed's list")
        options.tap()
        let larger = app.buttons["feed.textSize.larger"].firstMatch
        XCTAssertTrue(larger.waitForExistence(timeout: 3), "Larger text is in the Feed's ⋯")
        XCTAssertTrue(app.buttons["feed.textSize.smaller"].firstMatch.exists, "Smaller text is in the Feed's ⋯")
        // A tap on the right slot's placeholder closes the menu without changing anything.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.6)).tap()
        wait("The ⋯ menu closed") { !app.buttons["feed.textSize.larger"].firstMatch.exists }
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
        XCTAssertGreaterThan(title.frame.minY, app.placesMenu.frame.maxY, "The title starts below the rows")
        assertNothingUnderThePlaces(app)
        save("\(device)-feed-abstract")
    }

    // MARK: - Turning upright

    /// The Library with a paper beside it, turned upright (owner, 2026-10-23: "make sure that the paper we were just reading
    /// appears in the middle of the list, and it's initially highlighted"; "and then it dims"): the full-screen list (its
    /// rows, then its table) has the paper's row in its middle, tinted and selected, and the tint goes on its own.
    /// Sideways again, the same paper is on the right. (The tint is slowed for the test with `--row-reveal-slow`.)
    func testTurningUprightCentresAndHighlightsTheOpenPaper() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Tall and Wide on iPad")
        for layout in ["list", "table"] {
            XCUIDevice.shared.orientation = .portrait
            let app = launch(extra: ["--nothing-open", "--long-library-fixture", "--row-reveal-slow=12", "--library-layout=\(layout)"],
                             library: false)
            turnWide(app)
            XCTAssertTrue(element("library.search", app).waitForExistence(timeout: 15), "The library")
            // The sample is in the middle of the long library: below the window's end at first.
            let row = layout == "table" ? element("library.table.paper/aaaaaaaa-0000-0000-0000-000000000001", app) : app.buttons[sampleID]
            let list = app.collectionViews.firstMatch
            for _ in 0..<8 where !(row.exists && row.isHittable) { list.swipeUp(velocity: .slow) }
            row.tap()
            let web = app.webViews.firstMatch
            XCTAssertTrue(web.staticTexts["An interactive reading sample · 2026"].waitForExistence(timeout: 15), "The paper (\(layout))")
            wait("Beside the Library") { app.currentPlace == "Library" && web.frame.minX > 200 }
            XCUIDevice.shared.orientation = .portrait
            wait("Upright") { app.frame.height > app.frame.width && !app.placesMenu.exists }
            wait("The Library tab") { app.buttons["tab.library"].isSelected }
            wait("The paper's row, selected (\(layout))") { row.exists && row.isSelected }
            sleep(1)
            let frame = list.frame
            XCTAssertTrue(row.isHittable, "The row is visible (\(layout))")
            XCTAssertEqual(row.frame.midY, frame.midY, accuracy: frame.height * 0.12, "The row near the list's middle (\(layout))")
            save("\(device)-turn-upright-library-reveal-\(layout)")
            // The tint goes on its own (12 × (0.9 + 1) s here), and the row is no longer selected.
            wait("The highlight fades away (\(layout))", timeout: 40) { !row.isSelected }
            // Sideways again: the same paper on the right.
            turnWide(app)
            wait("The paper beside the Library again (\(layout))") { app.currentPlace == "Library" && web.exists && web.frame.minX > 200 }
            XCTAssertTrue(web.staticTexts["An interactive reading sample · 2026"].exists, "The same paper (\(layout))")
            app.terminate()
        }
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
            // A double tap: the list covers the window (owner, 2026-10-23); its grabber brings the paper back.
            element("slots.divider", app).doubleTap()
            _ = element("slots.uncover", app).waitForExistence(timeout: 5)
            sleep(1)
            save("\(prefix)-03b-library-covering")
            element("slots.uncover", app).tap()
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
            app = launch(appearance, extra: ["--nothing-open", "--long-library-fixture", "--row-reveal-slow=12"], library: false)
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
            // The Library with the sample beside it, turned upright: its row centred and tinted (before the tint fades).
            _ = openSampleBesideLibrary(app)
            XCUIDevice.shared.orientation = .portrait
            wait("Upright") { app.frame.height > app.frame.width && !app.placesMenu.exists }
            sleep(2)
            save("\(prefix)-13-upright-library-reveal")
            XCUIDevice.shared.orientation = .landscapeLeft
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
