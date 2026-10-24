import XCTest
import UIKit

/// The owner's iPad feedback on TestFlight 88 (2026-10-24), on iPad and iPhone:
/// - Upright (Tall), the AI Explainer, the equation view and a figure page cover the page as on iPhone ("no need for a UX
///   difference there"); sideways (Wide) they stay beside the paper.
/// - A text selection's menu is Copy · Explain in Chat · Save snippet: no Why it matters, Related papers, Add paper,
///   Draw snippet, nor the system's Look Up, Translate, Search Web or Share.
/// - A tapped equation's menu is Chat about Equation · Focus · Copy as Text.
/// - A reference opens the system's pull-down menu (a vertical list with symbols) at the entry, not an action sheet.
/// - The Feed opens as a table, as the Library; a picked row shows its abstract beside it in Wide, and Add → loading →
///   checkmark never moves a row.
/// Screens are attached, and written to `GS_SCREENSHOT_DIR` when the runner sets it.
@MainActor
final class MenusJourneyTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"
    private let dpoID = "paper.dddddddd-0000-4000-8000-000000000002"
    /// Items the paper's menus no longer offer.
    private let removed = ["Why it matters", "Related papers", "Related", "Add paper", "Draw snippet", "Look Up", "Translate",
                           "Search Web", "Share…", "Share", "Speak", "Writing Tools", "Select All"]

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.portraitWhereSupported()
    }
    override func tearDown() { XCUIDevice.shared.portraitWhereSupported(); super.tearDown() }

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let directory = ProcessInfo.processInfo.environment["GS_SCREENSHOT_DIR"], !directory.isEmpty {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? upright(shot.image).pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    /// A sideways capture carries its orientation as metadata, which a PNG drops; drawing it again bakes it in.
    private func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat(); format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
    }

    private func wait(_ description: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                      _ condition: @escaping () -> Bool) {
        let met = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)],
                                 timeout: timeout) == .completed
        XCTAssertTrue(met, description, file: file, line: line)
    }

    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// None of the removed items, in the horizontal menu nor in its expanded list (iOS 26's arrow, "Forward", shows the
    /// whole menu as a list even when every item fits): `expanded` names a capture of that list.
    private func assertNoneOfTheRemovedItems(_ app: XCUIApplication, expanded: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        for title in removed {
            XCTAssertFalse(app.editMenuItem(title).exists, "\(title) is not offered", file: file, line: line)
        }
        let forward = app.buttons["Forward"]
        guard forward.exists, forward.isHittable else { return }
        forward.tap()
        sleep(1)
        for title in removed {
            XCTAssertFalse(app.editMenuItem(title).exists, "\(title) is not in the expanded menu", file: file, line: line)
        }
        if let expanded { save(expanded) }
    }

    // MARK: - Tall: explainers cover the page

    private func turnWide(_ app: XCUIApplication) {
        XCUIDevice.shared.orientation = .landscapeLeft
        wait("Landscape") { app.frame.width > app.frame.height }
        wait("The places menu in the corner") { app.placesMenu.exists }
    }

    private func turnUpright(_ app: XCUIApplication) {
        XCUIDevice.shared.orientation = .portrait
        wait("Portrait") { app.frame.width < app.frame.height }
    }

    /// The numbered arXiv fixture paper, upright.
    private func launchStudyPaper(mode: String = "equation") -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture", "--chat-fixture-mode=\(mode)",
                               "--study-fixture", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["tab.paper"].waitForExistence(timeout: 15))
        app.show("paper")
        let web = app.webViews.firstMatch
        wait("The fixture's paper", timeout: 25) { web.staticTexts["(1)"].firstMatch.exists }
        return (app, web)
    }

    /// The sheet's own bar (the one holding `id`) spans the window: the page is covered as on iPhone.
    private func assertCovers(_ id: String, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let bar = app.navigationBars.containing(NSPredicate(format: "identifier == %@", id)).firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 8), "\(id)'s bar", file: file, line: line)
        wait("The sheet covers the window's width (\(bar.frame) in \(app.frame))", file: file, line: line) {
            abs(bar.frame.width - app.frame.width) < 2 && bar.frame.minX < 1
        }
    }

    /// Owner, 2026-10-24: "I was just using the vertical view on iPad and I noticed the AI explainer doesn't cover the
    /// whole page. Please make it like iPhone no need for a UX difference there." The AI Explainer, the equation view and a
    /// figure page; turned sideways the AI Explainer moves beside the paper, and upright again it covers the page.
    func testUprightExplainersCoverThePageAsOnIPhone() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Tall on iPad (the iPhone's sheet already covers)")
        let (app, web) = launchStudyPaper()

        // The paper's AI Explainer.
        app.buttons["Paper options"].tap()
        let explainer = app.buttons["paper.aiExplainer"]
        XCTAssertTrue(explainer.waitForExistence(timeout: 5)); explainer.tap()
        if app.buttons["Cancel"].waitForExistence(timeout: 3) { app.buttons["Cancel"].tap() }
        let page = element("paperExplainer.page", app)
        XCTAssertTrue(page.waitForExistence(timeout: 8), "The AI Explainer")
        wait("The explainer's page spans the window (\(page.frame))") { abs(page.frame.width - app.frame.width) < 2 }
        sleep(1)
        save("ipad-portrait-ai-explainer-covers")

        // Sideways: beside the paper (the companion slot). Upright again: covering the page.
        // (Nothing explained yet, the explainer asks for a model again each time it appears: Cancel.)
        turnWide(app)
        let pane = element("explain.pane", app)
        XCTAssertTrue(pane.waitForExistence(timeout: 8), "Wide: the explainer beside the paper")
        if app.buttons["Cancel"].waitForExistence(timeout: 3) { app.buttons["Cancel"].tap() }
        wait("Paper | explainer") { web.exists && web.frame.maxX <= pane.frame.minX + 1 }
        sleep(1)
        save("ipad-wide-ai-explainer-beside")
        turnUpright(app)
        if app.buttons["Cancel"].waitForExistence(timeout: 3) { app.buttons["Cancel"].tap() }
        wait("Upright: the explainer covers the page again", timeout: 10) {
            page.exists && abs(page.frame.width - app.frame.width) < 2 && !pane.exists
        }
        sleep(1)
        save("ipad-portrait-ai-explainer-after-turn")
        // A sheet swipes away, as on iPhone.
        app.closeInfoSheet(from: app.buttons["paperExplainer.openInChat"])
        XCTAssertTrue(page.waitForNonExistence(timeout: 5), "The explainer closes")

        // The equation view (Focus).
        let number = web.staticTexts["(1)"].firstMatch
        for _ in 0..<6 where !(number.exists && number.isHittable) { web.swipeUp() }
        number.tap()
        app.revealEditMenuItem("Focus").tap()
        assertCovers("equation.explain", app)
        save("ipad-portrait-equation-view-covers")
        app.closeInfoSheet(from: app.buttons["equation.explain"])
        XCTAssertTrue(app.buttons["equation.explain"].waitForNonExistence(timeout: 5))

        // A figure page.
        let figure = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open figure")).firstMatch
        for _ in 0..<8 where !(figure.exists && figure.isHittable) { web.swipeUp() }
        XCTAssertTrue(figure.exists, "A figure in the paper")
        figure.tap()
        assertCovers("figureView.addToNote", app)
        save("ipad-portrait-figure-page-covers")
    }

    // MARK: - Prompts as on iPhone

    /// Owner, 2026-10-24: "In the ai explainer it again put the prompt in the middle of the screen over the two left and
    /// right underneath please fix that, make the UX same as iPhone". Sideways, the AI Explainer beside the paper asks for
    /// a model in its own slot: the prompt rises from that slot's bottom edge and the paper beside it stays usable. The
    /// figure page's AI Explainer asks the same way. On iPhone (and upright) the prompt is the system's sheet.
    func testAnExplainersPromptCoversItsSlotOnly() throws {
        let (app, web) = launchStudyPaper()
        let wide = UIDevice.current.userInterfaceIdiom == .pad
        if wide { turnWide(app) }
        app.buttons["Paper options"].tap()
        let explainer = app.buttons["paper.aiExplainer"]
        XCTAssertTrue(explainer.waitForExistence(timeout: 5)); explainer.tap()
        let choose = app.buttons["ai.chooseModel"]
        XCTAssertTrue(choose.waitForExistence(timeout: 8), "The explainer asks for a model")
        sleep(1)
        if wide {
            let pane = element("explain.pane", app), prompt = element("slot.sheet", app)
            XCTAssertTrue(pane.exists && prompt.exists, "The prompt in the explainer's slot")
            XCTAssertGreaterThanOrEqual(prompt.frame.minX, pane.frame.minX - 1, "Within the slot (\(prompt.frame) in \(pane.frame))")
            XCTAssertLessThanOrEqual(prompt.frame.maxX, pane.frame.maxX + 1, "Within the slot")
            XCTAssertGreaterThan(prompt.frame.minY, pane.frame.minY, "Rising from the slot's bottom edge")
            XCTAssertGreaterThanOrEqual(choose.frame.minX, pane.frame.minX, "Its rows in the slot")
            XCTAssertTrue(web.isHittable, "The paper beside it stays usable")
            save("ipad-wide-explainer-prompt-in-slot")
        } else {
            save("iphone-explainer-prompt")
        }
        app.buttons["Cancel"].tap()
        XCTAssertTrue(choose.waitForNonExistence(timeout: 5), "Cancel closes the prompt")
        guard wide else { return }
        // The figure page's AI Explainer, in the same slot.
        if app.buttons["sheet.close"].exists { app.buttons["sheet.close"].tap() }
        let figure = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open figure")).firstMatch
        for _ in 0..<8 where !(figure.exists && figure.isHittable) { web.swipeUp() }
        XCTAssertTrue(figure.exists, "A figure in the paper")
        figure.tap()
        let ask = app.buttons["figureView.explain"]
        XCTAssertTrue(ask.waitForExistence(timeout: 8), "The figure page's AI Explainer")
        ask.tap()
        let pane = element("explain.pane", app), prompt = element("slot.sheet", app)
        if choose.waitForExistence(timeout: 5) {
            sleep(1)
            XCTAssertTrue(prompt.exists, "The figure's prompt in its slot")
            XCTAssertGreaterThanOrEqual(prompt.frame.minX, pane.frame.minX - 1, "Within the slot")
            XCTAssertTrue(web.isHittable, "The paper beside it stays usable")
            save("ipad-wide-figure-prompt-in-slot")
            // A tap on the dimmed slot above the prompt closes it, as on iPhone.
            pane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).withOffset(CGVector(dx: 0, dy: 4)).tap()
            XCTAssertTrue(choose.waitForNonExistence(timeout: 5), "A tap on the dimmed slot closes the prompt")
        }
    }

    /// An app-level sheet upright on iPad (Settings) is the iPhone's sheet scaled up: the window's width.
    func testAnAppSheetUprightSpansTheWindow() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Tall on iPad")
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        app.openSettingsFromMenu()
        let bar = app.navigationBars["Settings"]
        XCTAssertTrue(bar.waitForExistence(timeout: 8), "Settings")
        wait("Settings spans the window (\(bar.frame) in \(app.frame))") { abs(bar.frame.width - app.frame.width) < 2 }
        sleep(1)
        save("ipad-portrait-settings-sheet")
        bar.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5))

        // Sideways: Settings is the places menu's last row, under Search (owner, 2026-10-24), and opens as a page-sized
        // sheet (an app-level sheet in Wide), never the small form sheet.
        turnWide(app)
        app.placesMenu.tap()
        let search = app.buttons["tab.search"].exists ? app.buttons["tab.search"] : app.buttons["Search"]
        let settings = app.buttons["menu.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings in the places menu")
        if search.exists { XCTAssertGreaterThan(settings.frame.minY, search.frame.minY, "Settings under Search") }
        sleep(1)
        save("ipad-wide-places-menu-settings")
        settings.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 8), "Settings")
        wait("A page-sized sheet (\(bar.frame) in \(app.frame))") { bar.frame.width > 650 && bar.frame.width < app.frame.width - 100 }
        sleep(1)
        save("ipad-wide-settings-sheet")
    }

    // MARK: - Text selection

    /// Owner, 2026-10-24: "it's a long horizontal list, many of the options suck… translate, related papers on a random
    /// text selection? It needs to be better thought out." Copy · Explain in Chat · Save snippet, and nothing else.
    func testTextSelectionOffersCopyExplainAndSaveSnippetOnly() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        app.buttons[sampleID].tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 5))
        app.buttons["Table of contents"].tap()
        let section = app.buttons["1. Start with the question"]
        XCTAssertTrue(section.waitForExistence(timeout: 5)); section.tap()
        let paragraph = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A useful first pass identifies")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5)); XCTAssertTrue(paragraph.isHittable)
        web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: paragraph.frame.minX - web.frame.minX + 55, dy: paragraph.frame.minY - web.frame.minY + 18)).press(forDuration: 1)
        let copy = app.editMenuItem("Copy"), explain = app.editMenuItem("Explain in Chat"), snippet = app.editMenuItem("Save snippet")
        XCTAssertTrue(explain.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(copy.exists && copy.isHittable, "Copy")
        XCTAssertTrue(snippet.exists && snippet.isHittable, "Save snippet, without paging")
        XCTAssertTrue(copy.frame.maxX <= explain.frame.minX + 1 || copy.frame.maxY <= explain.frame.minY + 1, "Copy, then Explain in Chat")
        XCTAssertTrue(explain.frame.maxX <= snippet.frame.minX + 1 || explain.frame.maxY <= snippet.frame.minY + 1, "then Save snippet")
        sleep(1)
        save("\(device)-text-selection-menu")
        assertNoneOfTheRemovedItems(app, expanded: "\(device)-text-selection-menu-expanded")
        // The paper's ⋯ still offers Draw snippet, where nothing is selected.
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.15)).tap()
        XCTAssertTrue(explain.waitForNonExistence(timeout: 5))
        app.buttons["Paper options"].tap()
        XCTAssertTrue(app.buttons["paper.drawSnippet"].waitForExistence(timeout: 5), "Draw snippet in the paper's ⋯")
    }

    #if targetEnvironment(macCatalyst)
    /// The Mac: a right-click on selected text offers Copy, Explain in Chat and Save snippet (the system's Look Up,
    /// Translate, Search With…, Share, Speech and Services removed); a right-click with nothing selected offers Draw
    /// snippet only. (No screenshot: a Mac capture is the whole screen.)
    func testMacRightClickMenus() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--offline-reader-fixture", "--reset-offline-reader-fixture", "--mathpix-reader-fixture",
                               "--visual-open-paper", "-appearance", "light"]
        app.launch()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 15))
        // The year and venue line under the authors.
        let paragraph = web.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "2023, NeurIPS")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 20), "The paper is ready")
        let word = paragraph.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 14, dy: paragraph.frame.height / 2))
        word.doubleClick()
        sleep(1)
        word.rightClick()
        for title in ["Copy", "Explain in Chat", "Save snippet"] {
            XCTAssertTrue(app.editMenuItem(title).waitForExistence(timeout: 5), "\(title) in the right-click menu")
        }
        // Shown items only: the query also finds the menu bar's closed menus (Edit › Select All, Gradstep › Services).
        for title in removed + ["Search With Google", "Services", "Speech", "Inspect Element"] {
            let item = app.editMenuItem(title)
            XCTAssertFalse(item.exists && item.isHittable, "\(title) is not offered")
        }
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        // Nothing selected: a click in the margin clears the selection; a right-click there offers Draw snippet.
        let margin = web.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.6))
        margin.click()
        sleep(1)
        margin.rightClick()
        XCTAssertTrue(app.editMenuItem("Draw snippet").waitForExistence(timeout: 5), "Draw snippet with nothing selected")
        XCTAssertFalse(app.editMenuItem("Explain in Chat").exists, "No selection actions with nothing selected")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }
    #endif

    // MARK: - Equation

    /// A tapped equation: Chat about Equation · Focus · Copy as Text (owner: "find related papers in response to an
    /// equation just doesn't really make sense").
    func testATappedEquationOffersChatFocusAndCopyAsText() throws {
        let (app, web) = launchStudyPaper()
        let number = web.staticTexts["(1)"].firstMatch
        for _ in 0..<6 where !(number.exists && number.isHittable) { web.swipeUp() }
        number.tap()
        let chat = app.revealEditMenuItem("Chat about Equation")
        XCTAssertTrue(chat.exists, "The equation's menu")
        let focus = app.editMenuItem("Focus"), copyText = app.editMenuItem("Copy as Text")
        XCTAssertTrue(focus.exists && focus.isHittable && copyText.exists && copyText.isHittable, "All three without paging")
        XCTAssertTrue(chat.frame.maxX <= focus.frame.minX + 1 || chat.frame.maxY <= focus.frame.minY + 1, "Chat, then Focus")
        XCTAssertTrue(focus.frame.maxX <= copyText.frame.minX + 1 || focus.frame.maxY <= copyText.frame.minY + 1, "then Copy as Text")
        sleep(1)
        save("\(device)-equation-menu")
        assertNoneOfTheRemovedItems(app, expanded: "\(device)-equation-menu-expanded")
    }

    // MARK: - References

    /// Owner, 2026-10-24: "the list of options when clicking on references doesn't follow the native iOS style." The
    /// system's pull-down menu at the entry: Copy, Open on arXiv, Add to library, Discuss in chat, one above the other,
    /// no Cancel row; a tap outside or a scroll closes it, and an item runs.
    func testAReferenceOpensTheSystemsMenuAtTheEntry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--offline-reader-fixture", "--reset-offline-reader-fixture", "--mathpix-reader-fixture", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons[dpoID].waitForExistence(timeout: 10))
        app.buttons[dpoID].tap()
        let web = app.webViews.firstMatch
        let year = web.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "2023, NeurIPS")).firstMatch
        XCTAssertTrue(year.waitForExistence(timeout: 20), "The paper is ready")
        app.buttons["Table of contents"].tap()
        let introduction = app.buttons["1 Introduction"]
        for _ in 0..<6 { if introduction.waitForExistence(timeout: 2) { break }; app.swipeUp() }
        introduction.tap()
        let citation = web.links["Reference 11"].firstMatch
        wait("The citation is on screen") {
            citation.exists && !citation.frame.isEmpty && web.frame.insetBy(dx: 0, dy: 60).contains(CGPoint(x: citation.frame.midX, y: citation.frame.midY))
        }
        sleep(1)
        citation.tap()
        let entry = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "[11]")).firstMatch
        wait("The citation lands on reference 11") { entry.exists && entry.isHittable }
        sleep(1)

        func openMenu() {
            entry.tap()
            XCTAssertTrue(app.editMenuItem("Copy").waitForExistence(timeout: 5), "A reference opens its menu")
        }
        openMenu()
        let titles = ["Copy", "Open on arXiv", "Add to library", "Discuss in chat"]
        let items = titles.map { app.editMenuItem($0) }
        for (title, item) in zip(titles, items) { XCTAssertTrue(item.exists && item.isHittable, "\(title) in the menu") }
        for (above, below) in zip(items, items.dropFirst()) {
            XCTAssertLessThanOrEqual(above.frame.maxY, below.frame.minY + 1, "One above the other, as a menu's list")
            XCTAssertEqual(above.frame.minX, below.frame.minX, accuracy: 1, "One column")
        }
        XCTAssertFalse(app.buttons["Cancel"].exists, "Not an action sheet")
        XCTAssertFalse(app.sheets.firstMatch.exists, "Not an action sheet")
        sleep(1)
        save("\(device)-reference-menu")

        // A tap outside closes it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(items[3].waitForNonExistence(timeout: 5), "A tap outside closes the menu")
        // A scroll closes it.
        wait("The entry again") { entry.exists && entry.isHittable }
        openMenu()
        web.swipeUp()
        XCTAssertTrue(items[3].waitForNonExistence(timeout: 5), "A scroll closes the menu")
        // An item runs: Discuss in chat quotes the entry.
        web.swipeDown()
        wait("The entry again") { entry.exists && entry.isHittable }
        openMenu()
        items[3].tap()
        let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "This paper's chat opens")
        wait("The entry is quoted in the message box") { (composer.value as? String)?.hasPrefix("About “A. Chowdhery") == true }
    }

    // MARK: - Feed

    /// Owner, 2026-10-24: "Why is the feed default view not a table like the library." With no saved choice the Feed is
    /// the table (`--feed-layout=table` stands for that default: fixture runs reset to the List otherwise, as the
    /// Library's do). Wide: a picked row shows its abstract on the right. Add → loading → checkmark keeps every row's
    /// frame, in the table and in the List.
    func testTheFeedTableInWideAndAddNeverMovesARow() throws {
        for layout in ["table", "list"] {
            let app = XCUIApplication()
            app.launchArguments = ["--library-v5-fixture", "--feed-layout=\(layout)", "-appearance", "light"]
            app.launch()
            XCTAssertTrue(app.buttons["tab.library"].waitForExistence(timeout: 30) || app.wideMode("Library").exists)
            let wide = UIDevice.current.userInterfaceIdiom == .pad
            if wide { turnWide(app) }
            app.show("feed")
            let id = "2610.01234", next = "2610.02287"
            let row = { (sourceID: String) -> XCUIElement in
                layout == "table" ? self.element("feed.table.\(sourceID)", app) : self.element("discover.result.\(sourceID)", app)
            }
            XCTAssertTrue(row(id).waitForExistence(timeout: 20), "The Feed's \(layout)")
            let add = app.buttons["discover.add.\(id)"]
            wait("Add is enabled") { add.exists && add.isEnabled }
            sleep(1)
            if layout == "table" { save("\(device)\(wide ? "-wide" : "")-feed-table") }
            if wide {
                // A table row picked: its abstract on the right, as a List row does.
                row(next).coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
                let title = element("feed.abstract.title", app)
                XCTAssertTrue(title.waitForExistence(timeout: 5), "The abstract pane (\(layout))")
                XCTAssertGreaterThanOrEqual(title.frame.minX, app.frame.width * 0.45, "The details on the right")
                XCTAssertFalse(element("discover.setup.\(next)", app).exists, "Picking a row adds nothing")
                sleep(1)
                if layout == "table" { save("ipad-wide-feed-table-picked") }
            }
            let before = row(id).frame, after = row(next).frame
            add.tap()
            // The loading sign while the fixture sets the paper up, then (when it finishes) the checkmark: the row's frame
            // and the next row's are the same at each.
            let setup = app.buttons["discover.setup.\(id)"]
            let added = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "In library")).firstMatch
            let started = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in setup.exists || added.exists },
                                                                         object: nil)], timeout: 20) == .completed
            if !started { save("\(device)\(wide ? "-wide" : "")-feed-\(layout)-add-debug") }
            XCTAssertTrue(started, "Loading or the checkmark (\(layout))")
            // The row's top and height (its separators, the title's wrapping) and the next row's whole frame. (The row's
            // own accessibility frame is its elements' union: the spinner, centred in the room Add's capsule keeps, ends a
            // point or two before the capsule's edge without anything moving.)
            for moment in ["loading", "a moment later", "settled"] {
                let now = row(id).frame
                XCTAssertEqual(now.minY, before.minY, accuracy: 0.5, "Add → \(moment) keeps the row's top (\(layout))")
                XCTAssertEqual(now.height, before.height, accuracy: 0.5, "Add → \(moment) keeps the row's height (\(layout))")
                XCTAssertEqual(row(next).frame, after, "The next row stays put (\(moment), \(layout))")
                if moment == "loading" { save("\(device)\(wide ? "-wide" : "")-feed-\(layout)-loading") }
                if moment != "settled" { _ = added.waitForExistence(timeout: moment == "loading" ? 2 : 10) }
            }
            if added.exists { save("\(device)\(wide ? "-wide" : "")-feed-\(layout)-added") }
            app.terminate()
            XCUIDevice.shared.portraitWhereSupported()
        }
    }
}
