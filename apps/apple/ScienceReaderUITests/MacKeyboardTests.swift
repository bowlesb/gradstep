#if targetEnvironment(macCatalyst)
import XCTest

/// Real command-key routing in the local Catalyst fixture. No live account, provider or phone.
@MainActor
final class MacKeyboardTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func reader() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--offline-reader-fixture", "--reset-offline-reader-fixture",
                               "--mathpix-reader-fixture", "--visual-open-paper"]
        app.launch()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15))
        return app
    }

    func testCommandWPreservesDirtyTagsAndTheWindowButClosesACleanSheet() {
        let app = reader()
        func editTags() {
            app.buttons["Paper options"].tap()
            app.buttons["Edit tags"].tap()
            XCTAssertTrue(app.textFields["tags.field"].waitForExistence(timeout: 5))
        }
        editTags()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.textFields["tags.field"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.webViews.firstMatch.exists, "Close dismissed the sheet, not the window")

        editTags()
        let field = app.textFields["tags.field"]
        field.tap(); field.typeText("Keyboard regression tag")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(field.exists, "A tag still being typed is unsaved work too")
        XCTAssertEqual(field.value as? String, "Keyboard regression tag")
        field.typeText("\n")
        let tag = app.buttons["tags.chip.Keyboard regression tag"]
        XCTAssertTrue(tag.waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(field.exists && tag.exists, "Cmd-W must preserve the unsaved edit")
        XCTAssertTrue(app.windows.firstMatch.exists, "The guarded shortcut must not close the window")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Explicit Cancel can still discard the edit")
        XCTAssertTrue(app.webViews.firstMatch.exists)
    }

    func testBrowseOffersFindInPaperAndASeparateLibrarySearch() {
        let app = reader()
        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(app.searchFields["library.search"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.webViews.firstMatch.exists)
        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertTrue(app.menuItems["Find in Paper…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Search Library"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testChatColumnShortcutAndSettingsReturnKeepThePaper() {
        let app = reader()
        app.typeKey("3", modifierFlags: .command)
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        app.typeKey("h", modifierFlags: [.command, .control])
        XCTAssertTrue(composer.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.webViews.firstMatch.exists)
        app.typeKey("h", modifierFlags: [.command, .control])
        XCTAssertTrue(composer.waitForExistence(timeout: 5))

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Theme"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["Reader"].click()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(composer.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Mac Reader after chat shortcut and Settings return"; screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testLibrarySearchOwnsTypingAndAddShortcutClosesOnlyItsSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "--library-metadata-fixture", "--add-paper-fixture"]
        app.launch()
        let search = app.searchFields["library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        app.typeKey("f", modifierFlags: .command)
        app.typeText("Attention")
        XCTAssertEqual(search.value as? String, "Attention")
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(search.exists, "Search owns its navigation keys; typing must not open a table row")

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textFields["import.reference"].waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.textFields["import.reference"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.windows.firstMatch.exists)
        XCTAssertTrue(search.exists)
    }
}
#endif
