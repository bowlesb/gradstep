import XCTest
import UIKit

@MainActor
final class ReaderNavigationTests: XCTestCase {
    func testLibraryStartsFirstAndReaderWorksOffline() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        if app.buttons["tab.paper"].exists { XCTAssertFalse(app.buttons["tab.paper"].isEnabled) }
        app.buttons["Open an offline sample"].tap()
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

    func testScreenshotPreviewRedactionAndRemoval() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launch()
        app.buttons["Open an offline sample"].tap()
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
        app.buttons["Open an offline sample"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.segmentedControls.buttons["Reader"].isSelected)
        let reader = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); reader.name = "iPad reader and chat"; reader.lifetime = .keepAlways; add(reader)
        app.segmentedControls.buttons["Browse"].tap()
        XCTAssertTrue(app.navigationBars["Library"].exists)
        XCTAssertTrue(app.webViews.firstMatch.exists)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5))
    }
}
