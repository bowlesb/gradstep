import XCTest

final class LibraryCatalogTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testCreateRenameSwitchAndMoveCatalogThroughLibraryMenu() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--library-v5-fixture"]
        app.launch(); app.show("library")
        func menu(_ label: String) -> XCUIElement {
            #if targetEnvironment(macCatalyst)
            return app.popUpButtons[label]
            #else
            return app.buttons[label]
            #endif
        }
        func command(_ label: String) -> XCUIElement {
            #if targetEnvironment(macCatalyst)
            return app.editMenuItem(label)
            #else
            return app.buttons[label]
            #endif
        }
        let options = menu("Library options")
        XCTAssertTrue(options.waitForExistence(timeout: 15)); options.tap()
        command("Catalogs").tap()
        XCTAssertTrue(app.buttons["catalog.create"].waitForExistence(timeout: 8))
        menu("Options for Default").tap(); command("Rename").tap()
        // Catalyst presents the prompt as a sheet; iOS exposes an alert. Its field has the same placeholder.
        let field = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Catalog name")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3)); field.tap()
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 9))
        XCTAssertTrue((field.value as? String) == "" || field.value as? String == field.placeholderValue)
        field.typeText("Reading")
        app.buttons["Save"].tap()
        XCTAssertTrue(menu("Options for Reading").waitForExistence(timeout: 5))
        app.buttons["catalog.create"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("Research"); app.buttons["Save"].tap()
        XCTAssertTrue(menu("Options for Research").waitForExistence(timeout: 5))
        menu("Options for Research").tap(); command("Make default").tap()
        // Build 75 (AExY): a quick local change shows no "Saving…" and leaves the rows as they were.
        XCTAssertFalse(app.descendants(matching: .any)["catalog.saving"].exists)
        XCTAssertTrue(menu("Options for Research").isEnabled)
        #if !targetEnvironment(macCatalyst)
        // Build 75 (ACLs): the catalog as CSV through the share sheet (Save to Files, Mail…).
        menu("Options for Research").tap(); command("Export as CSV…").tap()
        let share = app.otherElements["ActivityListView"]
        XCTAssertTrue(share.waitForExistence(timeout: 8), "the share sheet offers the CSV")
        let exportShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); exportShot.name = "Catalog CSV share sheet"
        exportShot.lifetime = .keepAlways; add(exportShot)
        // Outside the share sheet, above it, dismisses it (its own close button varies by system version).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(share.waitForNonExistence(timeout: 10))
        #endif
        app.buttons["Close catalogs"].tap()
        XCTAssertTrue(menu("library.catalog").waitForExistence(timeout: 5))
        // Build 75 (AHI8): the catalog left of the search field; Add is the first row of Library options.
        let search = app.descendants(matching: .any)["library.search"]
        XCTAssertLessThan(menu("library.catalog").frame.maxX, search.frame.minX)
        XCTAssertFalse(app.buttons["Add a paper"].exists, "no + beside the search field")
        let placement = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); placement.name = "Catalog left of search"
        placement.lifetime = .keepAlways; add(placement)
        options.tap(); XCTAssertTrue(command("Add paper…").waitForExistence(timeout: 3)); command("Add paper…").tap()
        XCTAssertTrue(app.navigationBars["Add a paper"].waitForExistence(timeout: 5)); app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Add a paper"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Attention Is All You Need"].exists)
        options.tap(); command("Catalogs").tap()
        menu("Options for Reading").tap(); command("Delete catalog…").tap()
        #if targetEnvironment(macCatalyst)
        // Catalyst's compact form lazily creates rows below the destination picker.
        let forms = app.collectionViews
        XCTAssertGreaterThan(forms.count, 0)
        let form = forms.element(boundBy: forms.count - 1)
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        for _ in 0..<3 where !app.buttons["catalog.deleteConfirm"].exists { form.scroll(byDeltaX: 0, deltaY: -220) }
        #endif
        XCTAssertTrue(app.buttons["catalog.deleteConfirm"].waitForExistence(timeout: 5))
        app.buttons["catalog.deleteConfirm"].tap()
        XCTAssertTrue(app.buttons["Close catalogs"].waitForExistence(timeout: 5))
        XCTAssertFalse(menu("Options for Reading").exists)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = "Named catalogs after moving papers"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Close catalogs"].tap()
        XCTAssertTrue(app.staticTexts["Attention Is All You Need"].waitForExistence(timeout: 5))
    }
}
