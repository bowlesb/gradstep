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
        // File › Close asks the sheet's guard (MacClose): a tag still being typed is unsaved work too.
        XCTAssertTrue(field.exists, "A tag still being typed is unsaved work too")
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

    func testChatWheelScrollAndStreamingKeepTheReadersPlace() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture",
                               "--chat-scroll-audit=stream"]
        app.launch(); app.show("chat")
        let transcript = app.tables["chat.transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        struct Position: Decodable { let id: String; let y: Double; let h: Double }
        struct Geometry: Decodable { let scrollY: Double; let viewport: Double; let visibleText: [Position] }
        func geometry() throws -> Geometry {
            let data = try XCTUnwrap((transcript.value as? String)?.data(using: .utf8))
            return try JSONDecoder().decode(Geometry.self, from: data)
        }
        func anchor(_ state: Geometry) throws -> Position {
            try XCTUnwrap(state.visibleText.first { $0.y > -80 && $0.y < state.viewport - 80 })
        }
        let input = app.descendants(matching: .any)["chat.composer"].firstMatch
        input.click(); input.typeText("Continue with more detail"); app.buttons["chat.send"].click()
        XCTAssertTrue(app.buttons["chat.stop"].waitForExistence(timeout: 5))
        // Actual Catalyst wheel events, first away from the end and then in both directions.
        for _ in 0..<4 { transcript.scroll(byDeltaX: 0, deltaY: 240) }
        let start = try anchor(geometry())
        let wait = expectation(description: "Incoming answer while reading earlier text")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { wait.fulfill() }
        waitForExpectations(timeout: 2)
        let saved = try XCTUnwrap(geometry().visibleText.first { $0.id == start.id })
        XCTAssertEqual(saved.y, start.y, accuracy: 2, "Streaming must not pull wheel scrollback to the end")
        XCTAssertEqual(saved.h, start.h, accuracy: 1)
        var directions = Set<Int>()
        for delta in [90.0, 90.0, -90.0, -90.0] {
            let before = try anchor(geometry())
            transcript.scroll(byDeltaX: 0, deltaY: delta)
            if let text = try geometry().visibleText.first(where: { $0.id == before.id }) {
                let movement = text.y - before.y
                XCTAssertEqual(text.h, before.h, accuracy: 1, "Wheel scrolling cannot resize an unchanged row")
                if abs(movement) > 1 { directions.insert(movement > 0 ? 1 : -1) }
            }
        }
        XCTAssertEqual(directions, [-1, 1], "Both wheel directions must actually move visible text")
        if app.buttons["chat.stop"].exists { app.buttons["chat.stop"].click() }
        let stopped = try anchor(geometry())
        let rest = expectation(description: "Completed transcript at rest")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { rest.fulfill() }
        waitForExpectations(timeout: 2)
        let still = try XCTUnwrap(geometry().visibleText.first { $0.id == stopped.id })
        XCTAssertEqual(still.y, stopped.y, accuracy: 2)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = "Mac wheel scrollback during a streamed answer"
        shot.lifetime = .keepAlways; add(shot)
    }
}
#endif
