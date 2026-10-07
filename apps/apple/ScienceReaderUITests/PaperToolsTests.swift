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

    // MARK: - Contents levels (gap 10)

    /// The DPO conversion: Abstract left out, subsections indented under their sections, and the appendix's
    /// "A. 1"… (which Mathpix printed at A's level) indented under A by their numbers.
    func testContentsShowSectionLevels() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(), paperID = "paper.dddddddd-0000-4000-8000-000000000002"
        app.launchArguments = ["--offline-reader-fixture", "--reset-offline-reader-fixture", "--mathpix-reader-fixture"]
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
        XCTAssertGreaterThan(subsection.frame.minX, section.frame.minX + 10, "5.1 is indented under 5")
        XCTAssertEqual(subsection.value as? String, "Level 2")
        capture(app, "Contents with section levels")
        let appendix = app.buttons["A Mathematical Derivations"]
        let appendixSection = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "A. 2 ")).firstMatch
        for _ in 0..<8 where !(appendixSection.exists && appendixSection.isHittable) { app.swipeUp() }
        XCTAssertTrue(appendix.exists && appendixSection.isHittable)
        XCTAssertGreaterThan(appendixSection.frame.minX, appendix.frame.minX + 10, "A.2 is indented under A")
        let references = app.buttons["References"]
        XCTAssertTrue(references.exists, "References stays")
        XCTAssertEqual(appendix.frame.minX, references.frame.minX, accuracy: 1, "A is a top-level section")
        capture(app, "Contents: the appendix nested by its numbering")
        appendixSection.tap()
        let heading = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A. 2 ")).firstMatch
        XCTAssertTrue(wait { heading.exists && abs(heading.frame.minY - web.frame.minY) < 80 }, "The entry jumps to its heading")
    }
}
