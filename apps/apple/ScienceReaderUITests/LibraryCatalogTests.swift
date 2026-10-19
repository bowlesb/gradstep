import XCTest

final class LibraryCatalogTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testCreateRenameSwitchAndMoveCatalogThroughLibraryMenu() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--library-v5-fixture"]
        app.launch(); app.show("library")
        let options = app.buttons["Library options"]
        XCTAssertTrue(options.waitForExistence(timeout: 15)); options.tap()
        app.buttons["Catalogs"].tap()
        XCTAssertTrue(app.buttons["catalog.create"].waitForExistence(timeout: 8))
        app.buttons["Options for Default"].tap(); app.buttons["Rename"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3)); field.tap()
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 9))
        XCTAssertTrue((field.value as? String) == "" || field.value as? String == field.placeholderValue)
        field.typeText("Reading")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Options for Reading"].waitForExistence(timeout: 5))
        app.buttons["catalog.create"].tap()
        XCTAssertTrue(app.alerts.textFields.firstMatch.waitForExistence(timeout: 3))
        app.alerts.textFields.firstMatch.typeText("Research"); app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Options for Research"].waitForExistence(timeout: 5))
        app.buttons["Options for Research"].tap(); app.buttons["Make default"].tap()
        app.buttons["Close catalogs"].tap()
        XCTAssertTrue(app.buttons["library.catalog"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Attention Is All You Need"].exists)
        options.tap(); app.buttons["Catalogs"].tap()
        app.buttons["Options for Reading"].tap(); app.buttons["Delete catalog…"].tap()
        XCTAssertTrue(app.buttons["catalog.deleteConfirm"].waitForExistence(timeout: 5))
        app.buttons["catalog.deleteConfirm"].tap()
        XCTAssertTrue(app.buttons["Close catalogs"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Options for Reading"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Named catalogs after moving papers"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Close catalogs"].tap()
        XCTAssertTrue(app.staticTexts["Attention Is All You Need"].waitForExistence(timeout: 5))
    }
}
