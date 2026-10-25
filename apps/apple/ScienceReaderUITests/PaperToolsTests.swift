import XCTest
import UIKit

/// The reader's navigation tools (owner request 2026-10-07, legacy gaps 5, 6, 7 and 10): find in paper, the
/// Contents sheet's levels, the figure gallery and the iPad chat column.
@MainActor
final class PaperToolsTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    private func openSample(_ arguments: [String] = [], appearance: String = "light") -> XCUIApplication {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "-appearance", appearance] + arguments
        app.launch()
        // A podcast playing: once its player has closed to the mini-player over the tab bar.
        if arguments.contains("--podcast-autoplay-mini") {
            XCTAssertTrue(app.descendants(matching: .any)["podcast.miniPlayer"].waitForExistence(timeout: 20), "The mini-player shows")
        }
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        app.buttons[sampleID].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 8))
        let title = app.webViews.firstMatch.staticTexts["An interactive reading sample · 2026"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), "The paper is ready")
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval = 15) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)],
                       timeout: timeout) == .completed
    }

    private func assertChatTitleFits(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let title = app.buttons["chat.context"], history = app.buttons["Chat history"], newChat = app.buttons["New chat"]
        XCTAssertTrue(wait {
            title.exists && title.isHittable && title.frame.width > 44
                && title.frame.minX >= history.frame.maxX && title.frame.maxX <= newChat.frame.minX
        }, "The conversation title stays readable between the toolbar controls", file: file, line: line)
    }

    /// Build 68's actual Hanging report: 105 display equations, not the one-equation sample.
    func testReportedQuantumPaperEquationsFinishAndCanReopen() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent(".artifacts/equations-feedback-20261017/bundles/1805.03662v2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path), "Fetch the pinned device corpus first; no skip")
        let app = XCUIApplication()
        app.launchArguments = ["--offline-reader-fixture", "--reset-offline-reader-fixture", "--reported-equations-fixture", "--visual-open-paper"]
        app.launchEnvironment["REPORTED_EQUATIONS_BUNDLE"] = folder.path
        app.launch()
        XCTAssertTrue(app.buttons["Table of contents"].waitForExistence(timeout: 20))
        app.buttons["Table of contents"].tap()
        XCTAssertTrue(app.contentsTabs.waitForExistence(timeout: 5))
        app.contentsTab("Equations").tap()
        let started = Date()
        let first = app.buttons["contents.equation.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5), "The reported paper must finish loading its equation list")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        capture(app, "Reported 105-equation paper: Contents loaded")
        app.contentsTab("Contents").tap(); app.contentsTab("Equations").tap()
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        first.tap()
        XCTAssertTrue(app.buttons["Table of contents"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.contentsTabs.exists, "Selecting a row returns to that equation in the paper")
        capture(app, "Reported paper: first equation in the reader")
        app.buttons["Table of contents"].tap(); app.contentsTab("Equations").tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
    }

    // MARK: - Find in paper (gap 7)

    /// "Find in paper" shows WebKit's find bar; a match scrolls into view and is highlighted without becoming a
    /// selection, and the place it found is the saved reading position once the bar closes.
    func testFindInPaperGoesToAMatchAndKeepsThatReadingPlace() throws {
        let app = openSample()
        let web = app.webViews.firstMatch
        // The tab bar (iPhone, a narrow iPad) or the wide layout's mode control (a 13-inch iPad, the Mac).
        let narrow = app.buttons["tab.chat"].exists
        app.buttons["Paper options"].tap()
        app.buttons.matching(identifier: "paper.find").firstMatch.tap()
        let result = app.staticTexts["paper.find.count"]
        // The find bar takes the keyboard focus.
        XCTAssertTrue(app.buttons["paper.find.close"].waitForExistence(timeout: 5))
        app.typeText("every claim")
        XCTAssertTrue(wait { result.exists && result.label == "1 of 1" }, "One match: \(result.exists ? result.label : "none")")
        XCTAssertFalse(app.paperSelectionMenuShown, "A highlighted match is not a selection")
        sleep(1)
        capture(app, "Find in paper: a match highlighted")

        app.buttons["paper.find.close"].tap()
        XCTAssertTrue(app.buttons["paper.find.close"].waitForNonExistence(timeout: 5))
        if narrow { XCTAssertTrue(app.buttons["tab.chat"].waitForExistence(timeout: 5), "The tab bar returns with the keyboard gone") }
        sleep(1) // the page settles at its full height
        // The list item with the match (WebKit reports it as a group with the item's text). Queried once the bar has
        // closed: while find highlights the page, WebKit's accessibility elements can't be resolved.
        let found = web.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Read an ablation as evidence")).firstMatch
        // The match is on this wrapping list item's last line. WebKit aligns that line near the top, so the
        // entire item's center can be above the viewport while the searched text remains visible.
        XCTAssertTrue(wait { found.exists && found.frame.maxY > web.frame.minY + 8 && found.frame.maxY < web.frame.maxY },
                      "The matched last line stays in the viewport")
        XCTAssertFalse(app.paperSelectionMenuShown, "Closing find leaves no selection")
        let offset = found.frame.minY - web.frame.minY
        capture(app, "Find closed: the page stays at the match")

        // The found place is where reading resumes: after the chat tab (narrow), or another view (wide).
        app.show("chat")
        app.returnToPaper()
        XCTAssertTrue(wait { found.exists && abs(found.frame.minY - web.frame.minY - offset) < 6 },
                      "Returns to the found place (\(offset) → \(found.frame.minY - web.frame.minY))")
    }

    /// Build 70 feedback: Find must not move the shared tab bar to the top on another tab.
    func testFindBarDockedAfterSearchKeepsTheTabBarAndPageInPlace() throws {
        let app = openSample(), tab = XCUIApplication().buttons["tab.paper"]
        let home = tab.frame
        app.buttons["Paper options"].tap(); app.buttons.matching(identifier: "paper.find").firstMatch.tap()
        XCTAssertTrue(app.textFields["paper.find.input"].waitForExistence(timeout: 5))
        app.typeText("paper\n")
        XCTAssertTrue(wait { app.keyboards.count == 0 })
        app.buttons["paper.find.matches"].tap()
        XCTAssertTrue(app.buttons["paper.find.match.0"].waitForExistence(timeout: 5))
        app.buttons["paper.find.match.0"].tap()
        app.buttons["paper.find.close"].tap()
        for screen in ["feed", "library", "paper"] {
            app.show(screen)
            XCTAssertTrue(wait { abs(tab.frame.minY - home.minY) < 3 && tab.frame.minY > app.frame.height * 0.75 }, "Tab bar stays at bottom on \(screen)")
            capture(app, "After Find: \(screen)")
        }
    }

    func testKeyboardFrameLeftWithNothingThereKeepsTheReaderInPlace() throws {
        let app = openSample(), tab = XCUIApplication().buttons["tab.paper"]
        let home = tab.frame
        app.buttons["Paper options"].tap(); app.buttons.matching(identifier: "paper.find").firstMatch.tap()
        XCTAssertTrue(app.textFields["paper.find.input"].waitForExistence(timeout: 5))
        app.typeText("every claim")
        app.buttons["paper.find.close"].tap()
        app.show("chat")
        let composer = app.descendants(matching: .any)["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5)); composer.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertTrue(wait { composer.frame.maxY <= keyboard.frame.minY + 2 }, "Composer stays above keyboard")
        // The composer's own dismiss button is iPhone-only (build 69); an iPad uses the keyboard's hide key.
        if app.buttons["chat.dismissKeyboard"].exists { app.buttons["chat.dismissKeyboard"].tap() }
        else { let hide = app.keyboards.buttons["Hide keyboard"].firstMatch; hide.exists ? hide.tap() : app.typeText(XCUIKeyboardKey.escape.rawValue) }
        XCTAssertTrue(wait { app.keyboards.count == 0 && abs(tab.frame.minY - home.minY) < 3 })
    }

    // MARK: - Contents levels (gap 10)

    /// The DPO conversion: Abstract left out, subsections indented under their sections, and the appendix's
    /// "A. 1"… (which Mathpix printed at A's level) indented under A by their numbers.
    func testContentsShowSectionLevels() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication(), paperID = "paper.dddddddd-0000-4000-8000-000000000002"
        app.launchArguments = ["--offline-reader-fixture", "--reset-offline-reader-fixture", "--mathpix-reader-fixture", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons[paperID].waitForExistence(timeout: 10))
        app.buttons[paperID].tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 8))
        app.buttons["Table of contents"].tap()
        let introduction = app.buttons["1 Introduction"]
        XCTAssertTrue(introduction.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Abstract"].exists, "Abstract is not a Contents entry")
        let section = app.buttons["5 Theoretical Analysis of DPO"]
        let subsection = app.buttons["5.1 Your Language Model Is Secretly a Reward Model"]
        for _ in 0..<4 where !(subsection.exists && subsection.isHittable) { app.swipeUp() }
        XCTAssertTrue(section.exists && subsection.exists)
        // SwiftUI combines the label into its full-row accessibility button. The semantic level is observable;
        // the visual indentation is reviewed in the attached screenshot, rather than comparing row tap bounds.
        XCTAssertEqual(section.value as? String, "Level 1")
        XCTAssertEqual(subsection.value as? String, "Level 2")
        XCTAssertGreaterThan(subsection.frame.minY, section.frame.minY)
        capture(app, "Contents with section levels")
        let appendix = app.buttons["A Mathematical Derivations"]
        let appendixSection = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "A. 2 ")).firstMatch
        for _ in 0..<8 where !(appendixSection.exists && appendixSection.isHittable) { app.swipeUp() }
        XCTAssertTrue(appendix.exists && appendixSection.isHittable)
        XCTAssertEqual(appendix.value as? String, "Level 1")
        XCTAssertEqual(appendixSection.value as? String, "Level 2")
        XCTAssertGreaterThan(appendixSection.frame.minY, appendix.frame.minY)
        let references = app.buttons["References"]
        XCTAssertTrue(references.exists, "References stays")
        XCTAssertEqual(references.value as? String, "Level 1", "References remains a top-level entry")
        capture(app, "Contents: the appendix nested by its numbering")
        appendixSection.tap()
        let heading = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A. 2 ")).firstMatch
        XCTAssertTrue(wait { heading.exists && abs(heading.frame.minY - web.frame.minY) < 80 }, "The entry jumps to its heading")
    }

    func testContentsOpensAtFullHeightAndRemembersDoubleTapDiscovery() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("Touch discovery belongs to iPhone and iPad; Mac keeps double-click selection")
        #else
        let app = openSample(["--contents-discovery-reset"])
        app.buttons["Table of contents"].tap()
        XCTAssertTrue(app.staticTexts["contents.doubleTapHint"].waitForExistence(timeout: 5))
        XCTAssertLessThan(app.contentsTabs.frame.minY, app.frame.height * 0.25, "Contents starts at full height")
        app.buttons["sheet.close"].tap()
        let text = app.webViews.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Select a few words")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.doubleTap()
        XCTAssertTrue(app.contentsTabs.waitForExistence(timeout: 5), "Two taps in article text open Contents")
        XCTAssertFalse(app.staticTexts["contents.doubleTapHint"].exists)
        capture(app, "Contents after double-tap discovery")
        app.terminate()
        app.launchArguments = ["--workflow-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10)); app.buttons[sampleID].tap()
        XCTAssertTrue(app.buttons["Table of contents"].waitForExistence(timeout: 8)); app.buttons["Table of contents"].tap()
        XCTAssertTrue(app.contentsTabs.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["contents.doubleTapHint"].exists, "Discovery survives relaunch")
        #endif
    }

    /// Build 78 (owner, light mode, deep in a paper after using an equation's menu): "the double tap doesn't bring up table
    /// of contents anymore". In the numbered arXiv fixture: after scrolling, after an equation's menu was dismissed, after
    /// a fling, and with a text selection left elsewhere, two taps on article text still open Contents.
    func testDoubleTapOpensContentsDeepInThePaperAfterAnEquationMenuAndAFling() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("Touch discovery belongs to iPhone and iPad")
        #else
        let app = openSample(appearance: "light")
        let web = app.webViews.firstMatch
        // A paragraph of plain article text in the middle of the screen.
        func paragraphs() -> [XCUIElement] {
            let screen = web.frame.insetBy(dx: 0, dy: web.frame.height * 0.2)
            return web.staticTexts.allElementsBoundByIndex.filter { $0.label.count > 30 && $0.frame.height > 18 && screen.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        }
        func paragraph() -> XCUIElement? { paragraphs().first }
        func doubleTapOpensContents(_ step: String, last: Bool = false) {
            guard let text = last ? paragraphs().last : paragraph() else { return XCTFail("No paragraph on screen (\(step))") }
            text.doubleTap()
            XCTAssertTrue(app.contentsTabs.waitForExistence(timeout: 4), "Two taps open Contents \(step)")
            capture(app, "Double tap: \(step)")
            if app.contentsTabs.exists { app.buttons["sheet.close"].tap(); XCTAssertTrue(app.contentsTabs.waitForNonExistence(timeout: 5)) }
        }
        doubleTapOpensContents("at the top")
        // An equation's menu, dismissed by a tap on the text.
        let equation = web.staticTexts["(1)"].firstMatch
        for _ in 0..<6 where !(equation.exists && equation.isHittable) { web.swipeUp() }
        if equation.exists, equation.isHittable {
            equation.tap()
            XCTAssertTrue(app.revealEditMenuItem("Chat about Equation").exists, "The equation's menu")
            paragraph()?.tap()
            doubleTapOpensContents("after an equation's menu")
        }
        // Deep in the paper after scrolling, then right after a fling.
        web.swipeUp()
        doubleTapOpensContents("after scrolling")
        web.swipeUp(velocity: .fast)
        doubleTapOpensContents("right after a fling")
        // A word selected, then dismissed with a tap as a reader does: the next double tap opens Contents. (A tap while
        // the system's selection is up goes to the selection; the bridge's own rule is covered by PaperWebViewTests.)
        web.swipeDown(velocity: .slow)
        paragraph()?.press(forDuration: 1.0)
        paragraph()?.tap()
        doubleTapOpensContents("after a selection was dismissed")
        #endif
    }

    /// TestFlight 91 (owner): "if you double tap … you should see what section you are in because the part you were
    /// reading is highlighted". Deep in the paper, Contents opens with the section being read marked and in view; the
    /// mark follows the reading.
    func testContentsMarksTheSectionBeingRead() throws {
        let app = openSample(appearance: "dark")
        func openContents() -> XCUIElement {
            app.buttons["Table of contents"].tap()
            XCTAssertTrue(app.contentsTabs.waitForExistence(timeout: 5))
            return app.buttons["contents.reading"]
        }
        // A Contents row puts its heading at the top of the page: that is the section being read, on any screen size.
        func go(to title: String) {
            if !app.contentsTabs.exists { _ = openContents() }
            let row = app.buttons[title]
            XCTAssertTrue(row.waitForExistence(timeout: 5), title)
            row.tap()
            XCTAssertTrue(app.contentsTabs.waitForNonExistence(timeout: 5))
        }
        go(to: "2. Read the equations in context")
        let first = openContents()
        XCTAssertTrue(first.waitForExistence(timeout: 3), "The section being read is marked")
        XCTAssertTrue(first.isHittable, "and in view")
        XCTAssertEqual(first.label, "2. Read the equations in context")
        XCTAssertTrue((first.value as? String ?? "").contains("Reading"))
        capture(app, "Contents: the section being read")
        go(to: "3. Check the evaluation")
        let later = openContents()
        XCTAssertTrue(later.waitForExistence(timeout: 3) && later.isHittable)
        XCTAssertEqual(later.label, "3. Check the evaluation", "The mark follows the reading")
        XCTAssertEqual(app.buttons.matching(identifier: "contents.reading").count, 1, "One section is marked")
        capture(app, "Contents: further on")
        later.tap()
        XCTAssertTrue(app.contentsTabs.waitForNonExistence(timeout: 5), "A marked row still goes to its section")
    }

    /// Contents with Figures, Tables and Equations tabs (owner, build 59): Contents first; each list's rows go into
    /// the paper with Back.
    func testContentsTabsListFiguresTablesAndEquations() throws {
        let app = openSample(appearance: "dark")
        let web = app.webViews.firstMatch
        app.buttons["Table of contents"].tap()
        let tabs = app.contentsTabs
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertTrue(app.contentsTab("Contents").isSelected, "Contents is chosen on opening")
        XCTAssertTrue(app.descendants(matching: .any)["contents.list.contents"].exists)
        // Owner, build 62: one glass row, the tabs and an X; no title (the tab says it), no Done.
        XCTAssertTrue(app.buttons["sheet.close"].exists, "the sheet's X")
        XCTAssertFalse(app.navigationBars["Contents"].exists, "no title")
        XCTAssertFalse(app.buttons["Done"].exists, "no Done")
        XCTAssertEqual(app.buttons["sheet.close"].frame.midY, tabs.frame.midY, accuracy: 4, "the X beside the tabs")
        capture(app, "Contents tab")
        app.contentsTab("Figures").tap()
        let figure = app.buttons["contents.figure.0"]
        XCTAssertTrue(figure.waitForExistence(timeout: 5), "Figures lists the paper's figures")
        XCTAssertTrue(figure.label.hasPrefix("Figure 1 — "), "The number and the caption: \(figure.label)")
        capture(app, "Figures tab")
        // A row opens the figure with its whole caption (owner, build 59), then back to the list.
        figure.tap()
        // The figure's page: its top row (DESIGN.md "Sheet top row"), no title (the caption names it).
        XCTAssertTrue(app.buttons["figures.showInPaper"].waitForExistence(timeout: 5))
        // Build 78: Snippet, Chat and AI Explainer in words, no X on iPhone and iPad (the sheet swipes away); the Mac keeps one.
        #if targetEnvironment(macCatalyst)
        XCTAssertTrue(app.buttons["sheet.close"].exists)
        #endif
        capture(app, "A figure from Contents")
        app.sheetBack(from: "Figure 1")
        // The same tiles as the gallery, from the list; the page's own glass Back and X.
        let tiles = app.buttons["contents.figureTiles"]
        XCTAssertTrue(tiles.waitForExistence(timeout: 5)); tiles.tap()
        XCTAssertTrue(app.buttons["figures.item.0"].waitForExistence(timeout: 5), "The tiles")
        XCTAssertTrue(app.buttons["sheet.back"].exists && app.buttons["sheet.close"].exists)
        capture(app, "Figures as tiles from Contents")
        app.buttons["sheet.back"].tap()
        XCTAssertTrue(app.contentsTab("Tables").waitForExistence(timeout: 5)); app.contentsTab("Tables").tap()
        sleep(1); capture(app, "Tables tab")
        app.contentsTab("Equations").tap()
        let equation = app.buttons["contents.equation.0"]
        XCTAssertTrue(equation.waitForExistence(timeout: 5), "Equations lists the display equations")
        // Owner, build 62: "remove the equation text… Equation 1, Equation 2". The sample's number is drawn inside its
        // picture, so it is named by its section.
        XCTAssertTrue(equation.label == "Equation (1)" || equation.label.hasPrefix("Equation · "), equation.label)
        XCTAssertFalse(equation.label.contains("\\") || equation.label.contains("^"), "no LaTeX: \(equation.label)")
        XCTAssertFalse(app.navigationBars["Equations"].exists, "no title")
        capture(app, "Equations tab")
        equation.tap()
        XCTAssertTrue(tabs.waitForNonExistence(timeout: 5), "A row closes Contents")
        // The full named reference is now one link (build 71 feedback), not a standalone “(1)” text node.
        let reference = web.links["Equation (1)"].firstMatch
        #if targetEnvironment(macCatalyst)
        // Catalyst exposes the rendered formula as one accessibility text element. Its following link can
        // report isHittable=false; assert the formula's actual viewport geometry, not a tap we do not perform.
        XCTAssertTrue(reference.waitForExistence(timeout: 5))
        let display = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "(1) Attention")).firstMatch
        XCTAssertTrue(display.waitForExistence(timeout: 5))
        let landed = NSPredicate { _, _ in
            !display.frame.isEmpty && !reference.frame.isEmpty && web.frame.contains(display.frame)
                && web.frame.contains(reference.frame) && reference.frame.minY > display.frame.maxY
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landed, object: nil)], timeout: 5), .completed,
                       "The complete display equation and following reference are inside the reader viewport")
        #else
        XCTAssertTrue(reference.waitForExistence(timeout: 5) && reference.isHittable, "The equation and its following reference are in view")
        #endif
        XCTAssertTrue(app.buttons["reader.citation.back"].exists, "The equation jump offers a return to the original place")
        capture(app, "An equation from Contents")
    }

    /// Contents › Tables lists the paper's captioned tables (reader revision 16: the index names them; before, only
    /// tables published as images were listed, so most papers said "No tables"). A row opens the table with its whole
    /// caption; Show in paper goes to it with Back.
    func testContentsTablesListsCaptionedTablesAndShowsOneInThePaper() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "--study-fixture"]
        app.launch()
        // The study fixture selects the arXiv HTML paper (compiled by this app's compiler).
        XCTAssertTrue(app.buttons["tab.paper"].waitForExistence(timeout: 10) || app.wideMode("Reader").exists)
        app.show("paper")
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 15))
        app.buttons["Table of contents"].tap()
        let tabs = app.contentsTabs
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        app.contentsTab("Tables").tap()
        let table = app.buttons["contents.table.0"]
        XCTAssertTrue(table.waitForExistence(timeout: 5), "Tables lists the paper's captioned table")
        XCTAssertTrue(table.label.hasPrefix("Table 1 — Values."), table.label)
        XCTAssertFalse(app.buttons["contents.table.1"].exists, "One table in the fixture paper")
        capture(app, "Tables tab: the paper's captioned tables")
        table.tap()
        XCTAssertTrue(app.buttons["figures.showInPaper"].waitForExistence(timeout: 5), "The table's own view")
        // The figure view on a table too (FIGURE_VIEW.md): the arXiv paper on this device can be explained.
        XCTAssertTrue(app.buttons["figureView.explain"].waitForExistence(timeout: 5), "A table can be explained")
        XCTAssertTrue(app.buttons["figureView.askInChat"].exists)
        capture(app, "A table from Contents")
        app.buttons["figures.showInPaper"].tap()
        XCTAssertTrue(tabs.waitForNonExistence(timeout: 5), "Show in paper closes Contents")
        XCTAssertTrue(app.buttons["reader.citation.back"].waitForExistence(timeout: 5), "The paper goes to the table with Back")
        capture(app, "A table from Contents, in the paper")
    }

    /// Contents › Equations › View as tiles (owner, build 62: "a tile view similar to figures"): the equations typeset as
    /// in the paper, each named by its number; a tile goes where its row goes, the paper at that equation with Back.
    func testEquationTilesShowTheEquationsTypesetAndOpenOne() throws {
        let app = openSample(appearance: "light")
        let web = app.webViews.firstMatch
        app.buttons["Table of contents"].tap()
        XCTAssertTrue(app.contentsTabs.waitForExistence(timeout: 5))
        app.contentsTab("Equations").tap()
        let row = app.buttons["contents.equation.0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let name = row.label
        let tilesLink = app.buttons["contents.equationTiles"]
        XCTAssertTrue(tilesLink.waitForExistence(timeout: 5)); tilesLink.tap()
        let tile = app.webViews.buttons[name].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 8), "a tile named by its number")
        XCTAssertTrue(app.buttons["sheet.back"].exists && app.buttons["sheet.close"].exists)
        capture(app, "Equations as tiles (light)")
        tile.tap()
        XCTAssertTrue(app.contentsTabs.waitForNonExistence(timeout: 5), "A tile closes Contents")
        // The full named reference is now one link (build 71 feedback), not a standalone “(1)” text node.
        let reference = web.links["Equation (1)"].firstMatch
        XCTAssertTrue(reference.waitForExistence(timeout: 5) && reference.isHittable, "The equation and its following reference are in view")
        XCTAssertTrue(app.buttons["reader.citation.back"].exists, "The equation jump offers a return to the original place")
    }

    func testEquationTilesInDarkMode() throws {
        let app = openSample(appearance: "dark")
        app.buttons["Table of contents"].tap()
        XCTAssertTrue(app.contentsTabs.waitForExistence(timeout: 5))
        app.contentsTab("Equations").tap()
        let row = app.buttons["contents.equation.0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let name = row.label
        app.buttons["contents.equationTiles"].tap()
        XCTAssertTrue(app.webViews.buttons[name].firstMatch.waitForExistence(timeout: 8))
        sleep(1); capture(app, "Equations as tiles (dark)")
    }

    // MARK: - Figure gallery (gap 6)

    func testFigureGalleryOpensAFigureAndShowsItInThePaperWithBack() throws {
        let app = openSample(appearance: "dark")
        let web = app.webViews.firstMatch
        let title = web.staticTexts["An interactive reading sample · 2026"]
        let start = title.frame.minY - web.frame.minY
        app.buttons["Paper options"].tap()
        app.buttons["paper.figures"].tap()
        let first = app.buttons["figures.item.0"], second = app.buttons["figures.item.1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5)); XCTAssertTrue(second.exists)
        XCTAssertTrue(first.label.hasPrefix("Figure 1. A simplified attention data flow."), first.label)
        XCTAssertTrue(second.label.hasPrefix("Figure 2. A reading checklist"), second.label)
        sleep(1) // thumbnails decode
        capture(app, "Figure gallery")

        second.tap()
        // The figure's page, named by its caption (no title in its top row; build 78: Snippet, Chat, AI Explainer).
        XCTAssertTrue(app.figurePageSnippet.waitForExistence(timeout: 5))
        let detail = app.webViews.allElementsBoundByIndex.last!
        let caption = { (number: String) in detail.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", number)).firstMatch }
        XCTAssertTrue(caption("Figure 2").waitForExistence(timeout: 5))
        XCTAssertTrue(detail.images.firstMatch.waitForExistence(timeout: 5), "The figure's offline image")
        XCTAssertFalse(app.buttons["Next figure"].isEnabled)
        app.buttons["Previous figure"].tap()
        let earlier = app.webViews.allElementsBoundByIndex.last!.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Figure 1")).firstMatch
        XCTAssertTrue(earlier.waitForExistence(timeout: 5))
        capture(app, "A figure from the gallery")

        app.buttons["figures.showInPaper"].tap()
        let back = app.buttons["reader.citation.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Back is offered after Show in paper")
        let figure = web.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open figure: Queries and keys")).firstMatch
        XCTAssertTrue(wait { figure.exists && web.frame.contains(CGPoint(x: figure.frame.midX, y: figure.frame.midY)) },
                      "The figure is shown in the paper")
        capture(app, "Show in paper: the figure highlighted, with Back")
        back.tap()
        XCTAssertTrue(wait { title.exists && abs(title.frame.minY - web.frame.minY - start) < 3 && !back.exists },
                      "Back returns to the place left")
    }

    // MARK: - iPad: full-width paper, resizable chat (gap 5)

    func testTabletReaderHidesAndResizesTheChatColumn() throws {
        // Since 2026-10-22 the iPad's Wide shape has two slots (Read, Discuss, …; IPadShapesJourneyTests) and no permanent
        // chat column; the resizable column is the Mac's (ReaderSplit), whose UI tests need a person at the Mac.
        throw XCTSkip("Superseded on iPad by IPadShapesJourneyTests (two slots)")
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = openSample()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(wait { app.frame.width > app.frame.height }, "Landscape")
        let web = app.webViews.firstMatch, composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(app.wideMode("Reader").waitForExistence(timeout: 5))
        XCTAssertTrue(app.wideMode("Reader").isSelected, "Paper is the place; its chat beside it")
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Chat beside the paper by default")
        let paperWidth = web.frame.width
        assertChatTitleFits(app)
        capture(app, "iPad landscape: paper and chat (default)")

        // Resize: drag the divider left; the chat widens once the drag ends.
        let divider = app.descendants(matching: .any).matching(identifier: "reader.chatDivider").firstMatch
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        let minimumGrip = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        minimumGrip.press(forDuration: 0.2, thenDragTo: minimumGrip.withOffset(CGVector(dx: 160, dy: 0)))
        assertChatTitleFits(app)
        capture(app, "iPad landscape: chat at minimum width")
        divider.doubleTap()
        XCTAssertTrue(wait { abs(web.frame.width - paperWidth) < 12 }, "Default split restored")
        let grip = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.press(forDuration: 0.2, thenDragTo: grip.withOffset(CGVector(dx: -160, dy: 0)))
        XCTAssertTrue(wait { abs(web.frame.width - (paperWidth - 160)) < 12 }, "Paper \(paperWidth) → \(web.frame.width)")
        assertChatTitleFits(app)
        capture(app, "iPad landscape: chat widened")

        // Hide: full-width paper; the paper's ⋯ offers the chat back (owner, 2026-10-22: Show chat is a row of ⋯).
        app.buttons["Paper options"].tap()
        app.buttons["paper.chatColumn"].tap()
        XCTAssertTrue(composer.waitForNonExistence(timeout: 5))
        XCTAssertTrue(wait { abs(web.frame.width - app.frame.width) < 2 }, "Full-width paper")
        XCTAssertTrue(chatOffered(app), "Paper ⋯ › Show chat")
        capture(app, "iPad landscape: full-width paper")
        // ⌘F with a hardware keyboard finds in the paper.
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.buttons["paper.find.close"].waitForExistence(timeout: 5), "⌘F shows the find bar")
        app.buttons["paper.find.close"].tap()

        XCUIDevice.shared.portraitWhereSupported()
        XCTAssertTrue(wait { app.frame.width < app.frame.height }, "Portrait")
        XCTAssertTrue(wait { abs(web.frame.width - app.frame.width) < 2 }, "Still full width after rotating")
        capture(app, "iPad portrait: full-width paper")

        // An 11-inch iPad uses the compact tabs in portrait. Return to the wide Reader before exercising
        // Browse and the persisted split width; the hidden full-width paper above remains valid in both layouts.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(wait { app.frame.width > app.frame.height }, "Landscape again")
        XCTAssertTrue(app.placesMenu.waitForExistence(timeout: 5), "The places menu")

        // Library ⋯ › Show library beside paper: the library's list as the paper's left panel.
        app.showBrowse()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 5), "The library's rows beside the paper")
        XCTAssertTrue(app.webViews.firstMatch.exists)
        app.buttons["Paper options"].tap()
        XCTAssertTrue(app.buttons["paper.find"].waitForExistence(timeout: 5))
        app.buttons["paper.find"].tap() // closes the menu
        app.buttons["paper.find.close"].tap()
        app.buttons["paper.listToggle"].tap()
        XCTAssertTrue(wait { app.buttons["Paper options"].isHittable })
        XCTAssertTrue(chatOffered(app), "The chat stays hidden on Paper")

        // The choice is kept on this device.
        app.terminate()
        app.launchArguments = ["--workflow-fixture", "--keep-reader-chat", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        app.buttons[sampleID].tap()
        XCTAssertTrue(app.buttons["Paper options"].waitForExistence(timeout: 8))
        XCTAssertTrue(chatOffered(app, choose: true), "Still hidden after relaunch")
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(wait { abs(web.frame.width - (paperWidth - 160)) < 12 }, "The chosen split width survives relaunch")
        assertChatTitleFits(app)
        capture(app, "iPad landscape: chat shown again at its chosen width")
    }

    /// Paper ⋯ offers Show chat while the chat is hidden (closing the menu again, or choosing it).
    private func chatOffered(_ app: XCUIApplication, choose: Bool = false) -> Bool {
        app.buttons["Paper options"].tap()
        let row = app.buttons["paper.chatColumn"]
        guard row.waitForExistence(timeout: 3) else { return false }
        let offered = row.label == "Show chat"
        if choose { row.tap() } else { app.buttons["paper.find"].tap(); if app.buttons["paper.find.close"].waitForExistence(timeout: 3) { app.buttons["paper.find.close"].tap() } }
        return offered
    }
}
