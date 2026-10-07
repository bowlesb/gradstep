import XCTest
import UIKit

/// The reader's navigation tools (owner request 2026-10-07, legacy gaps 5, 6, 7 and 10): find in paper, the
/// Contents sheet's levels, the figure gallery and the iPad chat column.
@MainActor
final class PaperToolsTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    private func openSample(_ arguments: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture"] + arguments
        app.launch()
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
        XCTAssertFalse(app.buttons["reader.selection.define"].exists, "A highlighted match is not a selection")
        sleep(1)
        capture(app, "Find in paper: a match highlighted")

        app.buttons["find.doneButton"].tap()
        XCTAssertTrue(app.buttons["find.doneButton"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tab.chat"].waitForExistence(timeout: 5), "The tab bar returns with the keyboard gone")
        sleep(1) // the page settles at its full height
        // The list item with the match (WebKit reports it as a group with the item's text). Queried once the bar has
        // closed: while find highlights the page, WebKit's accessibility elements can't be resolved.
        let found = web.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Read an ablation as evidence")).firstMatch
        XCTAssertTrue(wait { found.exists && web.frame.contains(CGPoint(x: found.frame.midX, y: found.frame.midY)) },
                      "The page stays at the match")
        XCTAssertFalse(app.buttons["reader.selection.define"].exists, "Closing find leaves no selection")
        let offset = found.frame.minY - web.frame.minY
        capture(app, "Find closed: the page stays at the match")

        // The found place is where reading resumes.
        app.buttons["tab.chat"].tap()
        app.buttons["chat.returnToPaper"].tap()
        XCTAssertTrue(wait { found.exists && abs(found.frame.minY - web.frame.minY - offset) < 6 },
                      "Returns to the found place (\(offset) → \(found.frame.minY - web.frame.minY))")
    }
}
