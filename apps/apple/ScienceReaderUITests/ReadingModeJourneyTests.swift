import XCTest
import UIKit

/// Line width and reading mode on a wide iPad (docs/architecture/READING_MODE.md; the Mac shares the same views, and
/// its UI tests can't run on the build machine): the measure reflows the paper, and reading mode shows the paper alone
/// with its quiet bar, the chat sliding over it, and the split coming back on exit.
@MainActor
final class ReadingModeJourneyTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The wide layout (iPad; the Mac shares it)")
    }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait; super.tearDown() }

    private func openSample(appearance: String = "light") -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        // Each journey starts at the comfortable measure (the choice is otherwise kept per device).
        app.launchArguments = ["--workflow-fixture", "-appearance", appearance, "-reader.lineWidth", "comfortable"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        app.buttons[sampleID].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["An interactive reading sample · 2026"].waitForExistence(timeout: 8), "The paper is ready")
        XCTAssertTrue(wait { app.frame.width > app.frame.height }, "Landscape")
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval = 15) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)],
                       timeout: timeout) == .completed
    }

    /// The column's measure: the width of a plain paragraph of the sample (one snapshot, so a reflow in between can't
    /// leave an element behind).
    private func measure(_ app: XCUIApplication) -> CGFloat {
        guard let snapshot = try? app.webViews.firstMatch.snapshot() else { return 0 }
        var width: CGFloat = 0
        func visit(_ node: XCUIElementSnapshot) {
            if node.elementType == .staticText, node.label.hasPrefix("A useful first pass") { width = max(width, node.frame.width) }
            node.children.forEach(visit)
        }
        visit(snapshot)
        return width
    }

    /// A control in reading mode's bar, bringing the bar back first when it has stepped aside (a tap at the top edge).
    private func barButton(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[id]
        // The top edge's middle: the hidden bar comes back; a shown bar is held (the tap lands on its title).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).tap()
        XCTAssertTrue(button.waitForExistence(timeout: 3), "\(id) in the bar")
        return button
    }

    private func choose(_ width: String, in app: XCUIApplication, menu: String = "paper.lineWidth") {
        let button = menu.hasPrefix("reading.") ? barButton(menu, in: app) : app.buttons[menu]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Line width beside A− / A+")
        button.tap()
        let item = app.buttons[width]
        if !item.waitForExistence(timeout: 5) { capture("menu missing: \(menu) \(width)") }
        XCTAssertTrue(item.exists, "\(width) in the menu")
        item.tap()
    }

    func testLineWidthPutsMoreWordsOnALineAsTheMeasureWidens() {
        let app = openSample()
        // The chat beside the paper hides, so the paper has the room a wider measure needs.
        app.buttons["Paper options"].tap()
        if app.buttons["Hide chat"].waitForExistence(timeout: 3) { app.buttons["Hide chat"].tap() }
        else { app.tap() }
        choose("Comfortable", in: app)
        XCTAssertTrue(wait { self.measure(app) > 200 })
        let comfortable = measure(app)
        capture("iPad landscape: Comfortable")
        choose("Wide", in: app)
        XCTAssertTrue(wait { self.measure(app) > comfortable * 1.15 }, "Wide: \(comfortable) → \(measure(app))")
        capture("iPad landscape: Wide")
        let wide = measure(app)
        choose("Full width", in: app)
        XCTAssertTrue(wait { self.measure(app) > wide + 40 }, "Full width: \(wide) → \(measure(app))")
        capture("iPad landscape: Full width")
        choose("Comfortable", in: app)
        XCTAssertTrue(wait { abs(self.measure(app) - comfortable) < 12 }, "Back to the comfortable measure")
        // The chat column back as it was.
        app.buttons["Paper options"].tap()
        if app.buttons["Show chat"].waitForExistence(timeout: 3) { app.buttons["Show chat"].tap() } else { app.tap() }
    }

    func testReadingModeShowsThePaperAloneTheChatSlidesOverAndTheSplitComesBack() {
        let app = openSample()
        let web = app.webViews.firstMatch, composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(app.wideMode("Reader").waitForExistence(timeout: 5))
        let splitWidth = web.frame.width
        _ = composer
        // Reading mode is a row of the paper's ⋯ (owner, 2026-10-22: one row at the top, everything else in ⋯).
        app.buttons["Paper options"].tap()
        let enter = app.buttons["paper.readingMode"]
        XCTAssertTrue(enter.waitForExistence(timeout: 5), "Reading mode in the paper's ⋯")
        enter.tap()
        let bar = app.descendants(matching: .any)["reading.bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 3), "The quiet bar shows on entering")
        XCTAssertTrue(app.descendants(matching: .any)["reading.section"].exists)
        capture("iPad reading mode: the bar on entering")

        // The paper alone: no places, no chat column.
        XCTAssertTrue(wait { !app.wideMode("Reader").exists }, "The places step aside")
        XCTAssertTrue(wait { abs(web.frame.width - app.frame.width) < 2 }, "The paper takes the screen: \(splitWidth) → \(web.frame.width)")
        XCTAssertFalse(composer.exists, "No chat column")
        // It steps aside after a moment, and a tap near the top edge brings it back.
        XCTAssertTrue(wait({ !bar.exists }, timeout: 8), "The bar steps aside")
        capture("iPad reading mode: reading")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 3), "A tap at the top edge brings the bar back")

        // Ask in chat without leaving: the chat slides over, the paper keeps its width (and place).
        let paperWidth = web.frame.width
        barButton("reading.chat.toggle", in: app).tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "The chat slides over the paper")
        XCTAssertEqual(web.frame.width, paperWidth, accuracy: 2, "The paper doesn't reflow under the chat")
        capture("iPad reading mode: chat over the paper")
        XCTAssertTrue(app.buttons["reading.chat.toggle"].exists, "The bar stays while the chat is over the paper")
        app.buttons["reading.chat.toggle"].tap()
        XCTAssertTrue(wait { !composer.exists }, "The chat slides away")

        // The measure from the bar, then out: the split and its chat come back.
        choose("Full width", in: app, menu: "reading.lineWidth")
        capture("iPad reading mode: full width")
        choose("Comfortable", in: app, menu: "reading.lineWidth")
        barButton("reading.exit", in: app).tap()
        XCTAssertTrue(app.wideMode("Reader").waitForExistence(timeout: 5), "The places are back")
        XCTAssertEqual(web.frame.width, splitWidth, accuracy: 4, "Read as it was")
    }

    func testReadingModeInDarkAppearance() {
        let app = openSample(appearance: "dark")
        app.buttons["Paper options"].tap()
        app.buttons["paper.readingMode"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["reading.bar"].waitForExistence(timeout: 5))
        capture("iPad reading mode: dark")
        app.buttons["reading.exit"].tap()
        XCTAssertTrue(app.wideMode("Reader").waitForExistence(timeout: 5))
    }
}
