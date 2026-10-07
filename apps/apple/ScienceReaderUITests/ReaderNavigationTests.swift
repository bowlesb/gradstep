import XCTest
import UIKit

@MainActor
final class ReaderNavigationTests: XCTestCase {
    func testLibraryStartsFirstAndReaderWorksOffline() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.searchFields["library.search"].waitForExistence(timeout: 10), "The app starts in the Library")
        if app.buttons["tab.paper"].exists { XCTAssertFalse(app.buttons["tab.paper"].isEnabled) }
        app.buttons["sample.open"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        app.buttons["Table of contents"].tap()
        let equation = app.buttons["2. Read the equations in context"]
        XCTAssertTrue(equation.waitForExistence(timeout: 5))
        equation.tap()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Reader with equation"
        attachment.lifetime = .keepAlways
        add(attachment)
        if app.buttons["tab.library"].exists {
            app.buttons["tab.library"].tap()
            XCTAssertTrue(app.staticTexts["Reading machine learning papers"].firstMatch.waitForExistence(timeout: 5))
            app.buttons["tab.paper"].tap()
            XCTAssertTrue(app.webViews.firstMatch.exists)
        }
    }

    /// Owner feedback (build 11 session): citations link to their references, Back returns to the
    /// same place, references offer actions, and the year shows under the authors.
    func testCitationGoesToItsReferenceAndBackReturnsToTheSamePlace() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(), paperID = "paper.dddddddd-0000-4000-8000-000000000002"
        app.launchArguments = ["--offline-reader-fixture", "--reset-offline-reader-fixture", "--mathpix-reader-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[paperID].waitForExistence(timeout: 10))
        app.buttons[paperID].tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 8))
        let year = web.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "2023, NeurIPS, arXiv 2305.18290v3")).firstMatch
        XCTAssertTrue(year.waitForExistence(timeout: 8), "The year, venue and source show under the authors")

        app.buttons["Table of contents"].tap()
        let introduction = app.buttons["1 Introduction"]
        for _ in 0..<6 { if introduction.waitForExistence(timeout: 2) { break }; app.swipeUp() }
        introduction.tap()
        let citation = web.links["Reference 11"].firstMatch
        let paragraph = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Large unsupervised language models")).firstMatch
        let placed = NSPredicate { _, _ in citation.exists && citation.isHittable && paragraph.exists && paragraph.isHittable }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: placed, object: nil)], timeout: 8), .completed)
        sleep(1) // let the Contents scroll finish
        let start = paragraph.frame.minY

        citation.tap()
        let back = app.buttons["reader.citation.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Back is offered after following a citation")
        let entry = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "[11]")).firstMatch
        let landed = NSPredicate { _, _ in entry.exists && entry.isHittable && web.frame.contains(CGPoint(x: entry.frame.midX, y: entry.frame.minY)) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landed, object: nil)], timeout: 5), .completed,
                       "The citation lands on reference 11")
        let jumped = XCTAttachment(screenshot: app.screenshot()); jumped.name = "Reference after a citation"; jumped.lifetime = .keepAlways; add(jumped)

        // A reference offers its actions; the reader stays at the reference.
        entry.tap()
        XCTAssertTrue(app.buttons["Add to library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Copy"].exists)
        XCTAssertTrue(app.buttons["Open on arXiv"].exists, "Reference 11 names arXiv:2204.02311")
        let actions = XCTAttachment(screenshot: app.screenshot()); actions.name = "Reference actions"; actions.lifetime = .keepAlways; add(actions)
        app.buttons["Copy"].tap()
        XCTAssertTrue(app.buttons["Copy"].waitForNonExistence(timeout: 5))

        back.tap()
        let returned = NSPredicate { _, _ in paragraph.exists && abs(paragraph.frame.minY - start) < 3 && !back.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: returned, object: nil)], timeout: 5), .completed,
                       "Back returns to the reading position (\(start) → \(paragraph.frame.minY))")

        // Selecting text still offers the passage actions.
        web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: paragraph.frame.minX - web.frame.minX + 60, dy: paragraph.frame.minY - web.frame.minY + 14)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["reader.selection.define"].waitForExistence(timeout: 5))
    }

    func testScreenshotPreviewRedactionAndRemoval() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launch()
        app.buttons["sample.open"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        app.buttons["Paper options"].tap()
        app.buttons["Report this screen"].tap()
        XCTAssertTrue(app.navigationBars["Report an issue"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["Screenshot preview"].waitForExistence(timeout: 5))
        app.swipeUp()
        app.buttons["Crop or redact"].tap()
        let canvas = app.otherElements["report.editor.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45))
        start.press(forDuration: 0.1, thenDragTo: end)
        let edited = XCTAttachment(screenshot: app.screenshot()); edited.name = "Screenshot redaction preview"; edited.lifetime = .keepAlways; add(edited)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.images["Screenshot preview"].waitForExistence(timeout: 5))
        app.buttons["Remove screenshot"].tap()
        XCTAssertFalse(app.images["Screenshot preview"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5))
    }

    func testTabletLandscapeReaderAndBrowseArrangement() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad layout check")
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(); app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.segmentedControls.firstMatch.waitForExistence(timeout: 5))
        app.buttons["sample.open"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.segmentedControls.buttons["Reader"].isSelected)
        let reader = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); reader.name = "iPad reader and chat"; reader.lifetime = .keepAlways; add(reader)
        app.segmentedControls.buttons["Browse"].tap()
        XCTAssertTrue(app.searchFields["library.search"].exists)
        XCTAssertTrue(app.webViews.firstMatch.exists)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5))
    }
}
