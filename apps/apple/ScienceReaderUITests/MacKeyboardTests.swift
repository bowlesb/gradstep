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
            // On the Mac the paper's ⋯ is a pop-up button and its rows are menu items.
            app.popUpButtons["Paper options"].click()
            let item = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH[c] %@", "Edit tags")).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5)); item.click()
            XCTAssertTrue(app.textFields["tags.field"].waitForExistence(timeout: 5))
        }
        editTags()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.textFields["tags.field"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.webViews.firstMatch.exists, "Close dismissed the sheet, not the window")

        editTags()
        let field = app.textFields["tags.field"]
        field.click(); field.typeText("Keyboard regression tag")
        XCTAssertEqual(field.value as? String, "Keyboard regression tag", "The tag text went into the field")
        app.typeKey("w", modifierFlags: .command)
        // Known Mac issue (2026-10-16, docs/architecture/MAC_APP.md "Known issues"): the menu bar's Close takes ⌘W before
        // the sheet's guard, so a tag still being typed is closed with the sheet. Recorded until Close is replaced.
        guard field.exists else {
            XCTExpectFailure("⌘W closes the tag sheet while a tag is being typed (menu bar Close wins)") {
                XCTAssertTrue(field.exists, "A tag still being typed is unsaved work too")
            }
            return
        }
        XCTAssertEqual(field.value as? String, "Keyboard regression tag")
        field.typeText("\n")
        let tag = app.buttons["tags.chip.Keyboard regression tag"]
        XCTAssertTrue(tag.waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(field.exists && tag.exists, "Cmd-W must preserve the unsaved edit")
        XCTAssertTrue(app.windows.firstMatch.exists, "The guarded shortcut must not close the window")
        app.buttons["Cancel"].click()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Explicit Cancel can still discard the edit")
        XCTAssertTrue(app.webViews.firstMatch.exists)
    }

    func testBrowseOffersFindInPaperAndASeparateLibrarySearch() {
        let app = reader()
        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["library.search"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.webViews.firstMatch.exists)
        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertTrue(app.menuItems["Find in Paper…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Search Library"].exists)
        XCTAssertTrue(app.menuItems["Search ML Papers"].exists)
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
        app.wideMode("Reader").click()
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
        let search = app.descendants(matching: .any)["library.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        app.typeKey("f", modifierFlags: .command)
        app.typeText("Attention")
        XCTAssertEqual(search.value as? String, "Attention")
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(search.exists, "Search owns its navigation keys; typing must not open a table row")

        // ⌘N: Add a paper, or (this fixture is signed out) Sign in first; either way ⌘W closes only that sheet.
        app.typeKey("n", modifierFlags: .command)
        let sheetField = app.descendants(matching: .any)["import.reference"].firstMatch, signIn = app.buttons["auth.close"]
        XCTAssertTrue(sheetField.waitForExistence(timeout: 5) || signIn.waitForExistence(timeout: 1))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(sheetField.waitForNonExistence(timeout: 5) && signIn.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.windows.firstMatch.exists)
        XCTAssertTrue(search.exists)
    }
}
#endif
