import XCTest

/// Notes and snippets (docs/architecture/NOTES_AND_SNIPPETS.md) over the encrypted draft fixture: a real local account
/// store with public fixture keys and no network. Saves are local commits, so entries say "Waiting to sync".
@MainActor
final class NotesJourneyTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ extra: [String] = [], appearance: String? = nil) -> XCUIApplication {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--draft-fixture", "--reset-draft-fixture"] + (appearance.map { ["-appearance", $0] } ?? []) + extra
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 15))
        return app
    }

    private func openSample(_ app: XCUIApplication) -> XCUIElement {
        app.buttons[sampleID].tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 8))
        XCTAssertTrue(web.staticTexts["An interactive reading sample · 2026"].waitForExistence(timeout: 15), "The paper is ready")
        return web
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func waitFor(_ description: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                         _ condition: @escaping () -> Bool) {
        let met = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)],
                                 timeout: timeout) == .completed
        XCTAssertTrue(met, description, file: file, line: line)
    }

    private func menuItem(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", title, title)).firstMatch
    }

    private func replaceText(_ field: XCUIElement, with text: String, app: XCUIApplication) {
        field.tap()
        #if targetEnvironment(macCatalyst)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
        #else
        if let value = field.value as? String, !value.isEmpty, value != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText(text)
        #endif
    }

    /// Paper ⋯ › Draw snippet; draw a box from `from` to `to` (fractions of the page view); Use snippet.
    private func drawSnippet(_ app: XCUIApplication, web: XCUIElement, from: CGVector, to: CGVector) {
        app.buttons["Paper options"].tap()
        let draw = menuItem(app, "Draw snippet")
        XCTAssertTrue(draw.waitForExistence(timeout: 5)); draw.tap()
        let overlay = app.descendants(matching: .any)["capture.overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 5), "Capture mode covers the page")
        XCTAssertTrue(app.buttons["capture.cancel"].exists, "Cancel replaces the bar's controls")
        XCTAssertFalse(app.buttons["tab.notes"].isHittable && app.buttons["tab.notes"].exists, "The tab bar steps aside while drawing")
        capture("Draw snippet: ready")
        let area = app.descendants(matching: .any)["Snippet area"].exists ? app.descendants(matching: .any)["Snippet area"] : overlay
        area.coordinate(withNormalizedOffset: from).press(forDuration: 0.05, thenDragTo: area.coordinate(withNormalizedOffset: to))
        let use = app.buttons["capture.use"]
        waitFor("A drawn box can be used") { use.isEnabled }
        capture("Draw snippet: box drawn")
        use.tap()
    }

    // MARK: - Journeys

    /// Draw snippet → save to a new note → Open note → edit the comment → rename the note → delete it.
    func testDrawSnippetSaveToNewNoteThenEditRenameAndDelete() throws {
        let app = launch()
        let web = openSample(app)
        let before = web.staticTexts["An interactive reading sample · 2026"].frame
        drawSnippet(app, web: web, from: CGVector(dx: 0.08, dy: 0.18), to: CGVector(dx: 0.92, dy: 0.42))

        // The composer: the actual crop, a new note (none exist yet: "Quick notes"), an optional comment, the source.
        let save = app.buttons["composer.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(app.images["composer.preview"].waitForExistence(timeout: 10) || app.descendants(matching: .any)["composer.preview"].exists)
        let title = app.textFields["composer.newTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Quick notes", "First use offers Quick notes")
        replaceText(title, with: "Alignment ideas", app: app)
        let comment = app.textFields["composer.comment"].exists ? app.textFields["composer.comment"] : app.textViews["composer.comment"]
        comment.tap(); comment.typeText("The early improvement is the interesting part.")
        XCTAssertTrue(app.staticTexts["composer.source"].exists, "The quiet source line")
        capture("Composer: new note with a comment")
        waitFor("Save is ready") { save.isEnabled }
        save.tap()

        // Back on the paper where it was, with the confirmation and Open note.
        let saved = app.staticTexts["notes.saved"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        XCTAssertTrue(saved.label.hasPrefix("Saved to Alignment ideas"), saved.label)
        XCTAssertTrue(saved.label.contains("Waiting to sync"), "Nothing syncs from the fixture")
        XCTAssertFalse(app.descendants(matching: .any)["capture.overlay"].exists)
        XCTAssertEqual(web.staticTexts["An interactive reading sample · 2026"].frame.minY, before.minY, accuracy: 2, "The reading position stays")
        capture("Saved to note")
        app.buttons["notes.saved.open"].tap()

        // The note's stream: the crop, the comment, the source line and its sync state.
        XCTAssertTrue(app.navigationBars["Alignment ideas"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["entry.image.1"].waitForExistence(timeout: 10), "The snippet's image shows")
        XCTAssertTrue(app.staticTexts["entry.comment.1"].label.hasPrefix("The early improvement"))
        XCTAssertTrue(app.descendants(matching: .any)["entry.sync.1"].exists, "Saved on this device · Waiting to sync")
        capture("Note stream with a snippet")

        // Full size.
        app.buttons["entry.image.1"].tap()
        XCTAssertTrue(app.buttons["zoom.done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["zoom.image"].waitForExistence(timeout: 10))
        capture("Snippet full size")
        app.buttons["zoom.done"].tap()

        // Edit comment: a new revision; the capture itself is unchanged.
        app.buttons["entry.options.1"].tap()
        menuItem(app, "Edit comment").tap()
        let text = app.textViews["note.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.typeText(" Compare with the smaller model.")
        app.buttons["note.text.save"].tap()
        waitFor("The edited comment shows") { app.staticTexts["entry.comment.1"].label.hasSuffix("Compare with the smaller model.") }

        // Rename from the note's ⋯.
        app.buttons["note.options"].tap()
        menuItem(app, "Rename note").tap()
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        replaceText(name, with: "Preference learning", app: app)
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Preference learning"].waitForExistence(timeout: 10))
        capture("Renamed note")

        // Add text: the reader's own writing, no source.
        app.buttons["note.add"].tap()
        let writing = app.textViews["note.text"]
        XCTAssertTrue(writing.waitForExistence(timeout: 5))
        writing.typeText("Next: compare with IPO.")
        app.buttons["note.text.save"].tap()
        XCTAssertTrue(app.staticTexts["entry.comment.2"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["entry.comment.2"].label, "Next: compare with IPO.")

        // Delete, confirmed with the note's name and entry count.
        app.buttons["note.options"].tap()
        menuItem(app, "Delete note").tap()
        let sheet = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.otherElements.firstMatch
        XCTAssertTrue(app.staticTexts["Delete “Preference learning”?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 entries")).firstMatch.exists, "The count is stated")
        _ = sheet
        app.buttons["Delete note"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Your ideas, collected"].waitForExistence(timeout: 10), "The list is empty again")
        capture("Notes empty after delete")
    }

    /// The selection menu's Add to note keeps the passage as a quotation.
    func testAddSelectionToNote() throws {
        let app = launch()
        let web = openSample(app)
        let paragraph = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A useful first pass identifies")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 20))
        web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: paragraph.frame.minX - web.frame.minX + 55,
                                                                        dy: paragraph.frame.minY - web.frame.minY + 18)).press(forDuration: 1)
        let add = app.revealEditMenuItem("Add to note")
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Add to note is in the selection menu")
        XCTAssertTrue(app.editMenuItem("Explain in Chat").exists || app.editMenuItem("Copy").exists, "The existing actions stay")
        add.tap()
        let quote = app.staticTexts["composer.quote"]
        XCTAssertTrue(quote.waitForExistence(timeout: 10))
        let quoted = quote.label
        XCTAssertFalse(quoted.isEmpty)
        capture("Composer: quotation")
        app.buttons["composer.save"].tap()
        XCTAssertTrue(app.staticTexts["notes.saved"].waitForExistence(timeout: 10))
        app.buttons["notes.saved.open"].tap()
        XCTAssertTrue(app.navigationBars["Quick notes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", quoted)).firstMatch.waitForExistence(timeout: 5),
                      "The quotation is in the note")
        capture("Note with a quotation")
    }

    /// Settings is the last section of every top-right menu and returns to where it was opened.
    func testSettingsFromEveryMenuReturnsToItsOrigin() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["tab.notes"].exists, "Notes is the fifth tab")
        XCTAssertFalse(app.buttons["tab.settings"].exists, "Settings is no longer a tab")
        func roundTrip(_ place: String, back: @escaping () -> Bool) {
            app.openSettingsFromMenu()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Settings from \(place)")
            capture("Settings over \(place)")
            app.navigationBars["Settings"].buttons["Done"].tap()
            waitFor("Back on \(place)", back)
        }
        // Library.
        roundTrip("Library") { app.buttons[self.sampleID].isHittable }
        // Feed.
        app.buttons["tab.feed"].tap()
        XCTAssertTrue(app.buttons["Feed options"].waitForExistence(timeout: 10))
        roundTrip("Feed") { app.buttons["Feed options"].isHittable && app.buttons["tab.feed"].isSelected }
        // Paper (reading position kept).
        app.buttons["tab.library"].tap()
        let web = openSample(app)
        roundTrip("Paper") { web.staticTexts["An interactive reading sample · 2026"].exists && app.buttons["Paper options"].isHittable }
        // Chat.
        app.buttons["tab.chat"].tap()
        XCTAssertTrue(app.buttons["Chat options"].waitForExistence(timeout: 10))
        roundTrip("Chat") { app.buttons["Chat options"].isHittable }
        // Notes list, then a note.
        app.buttons["tab.notes"].tap()
        XCTAssertTrue(app.buttons["Notes options"].waitForExistence(timeout: 10))
        roundTrip("Notes") { app.buttons["Notes options"].isHittable }
        app.buttons["notes.new"].tap()
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.typeText("Reading for Friday")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.navigationBars["Reading for Friday"].waitForExistence(timeout: 10))
        roundTrip("a note") { app.navigationBars["Reading for Friday"].exists }
        // Report this screen stays just above Settings.
        app.buttons["note.options"].tap()
        XCTAssertTrue(menuItem(app, "Report this screen").waitForExistence(timeout: 5))
        let report = menuItem(app, "Report this screen").frame, settings = app.buttons["menu.settings"].frame
        XCTAssertLessThan(report.minY, settings.minY, "Settings is the last section")
        capture("Note menu with Settings last")
    }

    /// Light and dark screenshots of the Notes list, a note and the composer (visual review).
    func testNotesScreenshotsLightAndDark() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let web = openSample(app)
            drawSnippet(app, web: web, from: CGVector(dx: 0.06, dy: 0.2), to: CGVector(dx: 0.94, dy: 0.5))
            XCTAssertTrue(app.buttons["composer.save"].waitForExistence(timeout: 10))
            waitFor("Prepared") { app.buttons["composer.save"].isEnabled }
            capture("Composer \(appearance)")
            app.buttons["composer.save"].tap()
            XCTAssertTrue(app.staticTexts["notes.saved"].waitForExistence(timeout: 10))
            capture("Saved banner \(appearance)")
            app.buttons["notes.saved.open"].tap()
            XCTAssertTrue(app.buttons["entry.image.1"].waitForExistence(timeout: 10))
            capture("Note stream \(appearance)")
            app.buttons["tab.notes"].tap()
            app.buttons["tab.notes"].tap()
            XCTAssertTrue(app.buttons["Notes options"].waitForExistence(timeout: 10))
            capture("Notes list \(appearance)")
            app.terminate()
        }
    }
}
