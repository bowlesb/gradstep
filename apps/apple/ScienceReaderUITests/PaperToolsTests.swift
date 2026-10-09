import XCTest
import UIKit

/// The reader's navigation tools (owner request 2026-10-07, legacy gaps 5, 6, 7 and 10): find in paper, the
/// Contents sheet's levels, the figure gallery and the iPad chat column.
@MainActor
final class PaperToolsTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    private func openSample(_ arguments: [String] = [], appearance: String = "light") -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
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

    // MARK: - Find in paper (gap 7)

    /// "Find in paper" shows WebKit's find bar; a match scrolls into view and is highlighted without becoming a
    /// selection, and the place it found is the saved reading position once the bar closes.
    func testFindInPaperGoesToAMatchAndKeepsThatReadingPlace() throws {
        let app = openSample()
        let web = app.webViews.firstMatch
        app.buttons["Paper options"].tap()
        app.buttons.matching(identifier: "paper.find").firstMatch.tap()
        let result = app.staticTexts["find.resultLabel"]
        // The find bar takes the keyboard focus.
        XCTAssertTrue(app.buttons["find.doneButton"].waitForExistence(timeout: 5))
        app.typeText("every claim")
        XCTAssertTrue(wait { result.exists && result.label == "1 of 1" }, "One match: \(result.exists ? result.label : "none")")
        XCTAssertFalse(app.paperSelectionMenuShown, "A highlighted match is not a selection")
        sleep(1)
        capture(app, "Find in paper: a match highlighted")

        app.buttons["find.doneButton"].tap()
        XCTAssertTrue(app.buttons["find.doneButton"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tab.chat"].waitForExistence(timeout: 5), "The tab bar returns with the keyboard gone")
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

        // The found place is where reading resumes.
        app.buttons["tab.chat"].tap()
        app.buttons["chat.returnToPaper"].tap()
        XCTAssertTrue(wait { found.exists && abs(found.frame.minY - web.frame.minY - offset) < 6 },
                      "Returns to the found place (\(offset) → \(found.frame.minY - web.frame.minY))")
    }

    // MARK: - A keyboard frame left behind (TestFlight build 21)

    /// Each appearance, with and without a podcast's mini-player riding on the tab bar.
    private let chromeVariants: [(appearance: String, arguments: [String], name: String)] = ["light", "dark"].flatMap { appearance in
        [(appearance, [], appearance),
         (appearance, ["--feed-fixture", "--podcast-fixture", "--reset-podcast-fixture", "--podcast-autoplay", "--podcast-autoplay-mini"],
          "\(appearance), mini-player")]
    }

    /// "Somehow I ended up with this": the tab bar and A−/A+ ~170 pt up, the page cut off above an empty band. Search in the
    /// find bar hides the keyboard and leaves the bar docked, a hidden keyboard's frame still on screen. The tab bar sits
    /// just above the bar and the page keeps its room above the tab bar; Done puts both back.
    func testFindBarDockedAfterSearchKeepsTheTabBarAndPageInPlace() throws {
        for variant in chromeVariants {
            let app = openSample(variant.arguments, appearance: variant.appearance)
            let web = app.webViews.firstMatch, tab = app.buttons["tab.paper"], done = app.buttons["find.doneButton"]
            let home = (tab: tab.frame, web: web.frame)
            app.buttons["Paper options"].tap()
            app.buttons.matching(identifier: "paper.find").firstMatch.tap()
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            app.typeText("every claim")
            app.typeText("\n")
            XCTAssertTrue(wait { app.keyboards.count == 0 && tab.exists }, "Search hides the keyboard; the tab bar shows")
            sleep(1)
            capture(app, "Find bar docked after Search (\(variant.name))")
            XCTAssertTrue(done.exists, "The find bar stays")
            let bar = tab.frame.insetBy(dx: 0, dy: -4) // the capsule: 4 pt of glass around its items
            XCTAssertLessThanOrEqual(bar.maxY, done.frame.minY, "The tab bar is above the find bar")
            XCTAssertLessThan(done.frame.minY - bar.maxY, 60, "… just above it, with no empty band (\(bar) / \(done.frame))")
            XCTAssertEqual(tab.frame.minY - web.frame.maxY, home.tab.minY - home.web.maxY, accuracy: 1,
                           "The page runs to the room kept above the tab bar")

            done.tap()
            XCTAssertTrue(wait { !done.exists && abs(tab.frame.minY - home.tab.minY) < 1 && abs(web.frame.maxY - home.web.maxY) < 1 },
                          "Done puts the tab bar and page back (\(tab.frame), \(web.frame))")
            capture(app, "Find closed (\(variant.name))")
            app.terminate()
        }
    }

    /// What the device showed: the find session over (the page no longer dimmed), nothing at the bottom, and the hidden
    /// keyboard's frame still a keyboard safe area. `--find-bar-gone` counts the docked bar as gone, keeping its real
    /// frame. The tab bar stays at the bottom and the page runs to it; the message box still rises with the next keyboard.
    func testKeyboardFrameLeftWithNothingThereKeepsTheReaderInPlace() throws {
        for variant in chromeVariants {
            let app = openSample(["--find-bar-gone"] + variant.arguments, appearance: variant.appearance)
            let web = app.webViews.firstMatch, tab = app.buttons["tab.paper"], done = app.buttons["find.doneButton"]
            let home = (tab: tab.frame, web: web.frame)
            app.buttons["Paper options"].tap()
            app.buttons.matching(identifier: "paper.find").firstMatch.tap()
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            app.typeText("every claim")
            app.typeText("\n")
            XCTAssertTrue(wait { app.keyboards.count == 0 && tab.exists }, "Search hides the keyboard; the tab bar shows")
            sleep(1)
            capture(app, "Keyboard frame left on screen (\(variant.name))")
            XCTAssertEqual(tab.frame.minY, home.tab.minY, accuracy: 1, "The tab bar stays at the bottom")
            XCTAssertEqual(web.frame.maxY, home.web.maxY, accuracy: 1, "The page runs to the tab bar's room")
            done.tap()
            XCTAssertTrue(done.waitForNonExistence(timeout: 5))

            app.buttons["tab.chat"].tap()
            let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            composer.tap()
            let keyboard = app.keyboards.firstMatch
            // With the mini-player showing, the first tap here doesn't focus the message box (also without this change,
            // 2026-10-08): tap again.
            if !keyboard.waitForExistence(timeout: 4) { composer.tap() }
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            XCTAssertTrue(wait { composer.frame.maxY <= keyboard.frame.minY }, "The message box rises above the keyboard")
            capture(app, "Message box above the keyboard (\(variant.name))")
            app.buttons["chat.dismissKeyboard"].tap()
            XCTAssertTrue(wait { app.keyboards.count == 0 && tab.exists && abs(tab.frame.minY - home.tab.minY) < 1 }, "The tab bar returns in place")
            app.terminate()
        }
    }

    // MARK: - Contents levels (gap 10)

    /// The DPO conversion: Abstract left out, subsections indented under their sections, and the appendix's
    /// "A. 1"… (which Mathpix printed at A's level) indented under A by their numbers.
    func testContentsShowSectionLevels() throws {
        XCUIDevice.shared.orientation = .portrait
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
        XCTAssertTrue(app.navigationBars["Figure 2"].waitForExistence(timeout: 5))
        let detail = app.webViews.allElementsBoundByIndex.last!
        XCTAssertTrue(detail.images.firstMatch.waitForExistence(timeout: 5), "The figure's offline image")
        XCTAssertFalse(app.buttons["Next figure"].isEnabled)
        app.buttons["Previous figure"].tap()
        XCTAssertTrue(app.navigationBars["Figure 1"].waitForExistence(timeout: 5))
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
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad layout")
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = openSample()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(wait { app.frame.width > app.frame.height }, "Landscape")
        let web = app.webViews.firstMatch, composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(app.segmentedControls.buttons["Reader"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.buttons["Reader"].isSelected)
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

        // Hide: full-width paper; the paper's bar offers the chat back.
        app.buttons["Paper options"].tap()
        app.buttons["paper.chatColumn"].tap()
        XCTAssertTrue(composer.waitForNonExistence(timeout: 5))
        XCTAssertTrue(wait { abs(web.frame.width - app.frame.width) < 2 }, "Full-width paper")
        XCTAssertTrue(app.buttons["paper.showChat"].exists)
        capture(app, "iPad landscape: full-width paper")
        // ⌘F with a hardware keyboard finds in the paper.
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.buttons["find.doneButton"].waitForExistence(timeout: 5), "⌘F shows the find bar")
        app.buttons["find.doneButton"].tap()

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(wait { app.frame.width < app.frame.height }, "Portrait")
        XCTAssertTrue(wait { abs(web.frame.width - app.frame.width) < 2 }, "Still full width after rotating")
        capture(app, "iPad portrait: full-width paper")

        // An 11-inch iPad uses the compact tabs in portrait. Return to the wide Reader before exercising
        // Browse and the persisted split width; the hidden full-width paper above remains valid in both layouts.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(wait { app.frame.width > app.frame.height }, "Landscape again")
        XCTAssertTrue(app.segmentedControls.buttons["Browse"].waitForExistence(timeout: 5))

        // Browse keeps the library beside the paper and has no chat column to hide.
        app.segmentedControls.buttons["Browse"].tap()
        XCTAssertTrue(app.searchFields["library.search"].waitForExistence(timeout: 5))
        app.buttons["Paper options"].tap()
        XCTAssertTrue(app.buttons["paper.find"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["paper.chatColumn"].exists)
        app.buttons["paper.find"].tap() // closes the menu
        app.buttons["find.doneButton"].tap()
        app.segmentedControls.buttons["Reader"].tap()
        XCTAssertTrue(app.buttons["paper.showChat"].waitForExistence(timeout: 5))

        // The choice is kept on this device.
        app.terminate()
        app.launchArguments = ["--workflow-fixture", "--keep-reader-chat", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        app.buttons[sampleID].tap()
        XCTAssertTrue(app.buttons["paper.showChat"].waitForExistence(timeout: 8), "Still hidden after relaunch")
        app.buttons["paper.showChat"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(wait { abs(web.frame.width - (paperWidth - 160)) < 12 }, "The chosen split width survives relaunch")
        assertChatTitleFits(app)
        capture(app, "iPad landscape: chat shown again at its chosen width")
    }
}
