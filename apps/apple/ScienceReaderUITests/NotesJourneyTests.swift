import XCTest

/// Notes and snippets (docs/architecture/NOTES_AND_SNIPPETS.md) over the encrypted draft fixture: a real local account
/// store with public fixture keys and no network. Saves are local commits, so entries say "Waiting to sync".
@MainActor
final class NotesJourneyTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    override func setUpWithError() throws { continueAfterFailure = false }

    /// The phone journeys use the five-item tab bar; the wide layout has its own journey below.
    private func requirePhoneLayout(_ app: XCUIApplication) throws {
        try XCTSkipUnless(app.buttons["tab.notes"].exists, "Phone-width layout (the wide layout's journey is testNotesInTheWideLayout)")
    }

    private func launch(_ extra: [String] = [], appearance: String? = nil) -> XCUIApplication {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--draft-fixture", "--reset-draft-fixture"] + (appearance.map { ["-appearance", $0] } ?? []) + extra
        app.launch()
        current = app
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 15))
        return app
    }

    private func openSample(_ app: XCUIApplication) -> XCUIElement {
        app.buttons[sampleID].tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 8))
        // The paper is ready: its byline at the top, or (a remembered place further down) its first section.
        let ready = web.staticTexts["An interactive reading sample · 2026"].waitForExistence(timeout: 15)
            || web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A useful first pass")).firstMatch.waitForExistence(timeout: 5)
        if !ready { capture("Paper not ready") }
        XCTAssertTrue(ready, "The paper is ready")
        return web
    }

    /// The app under test (the Mac's screenshots are of its window only, never the rest of the desktop).
    private var current: XCUIApplication?

    private func capture(_ name: String) {
        #if targetEnvironment(macCatalyst)
        let shot = current?.windows.firstMatch.screenshot() ?? XCUIScreen.main.screenshot()
        #else
        let shot = XCUIScreen.main.screenshot()
        #endif
        let attachment = XCTAttachment(screenshot: shot)
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
        try requirePhoneLayout(app)
        let web = openSample(app)
        let before = web.staticTexts["An interactive reading sample · 2026"].frame
        drawSnippet(app, web: web, from: CGVector(dx: 0.08, dy: 0.18), to: CGVector(dx: 0.92, dy: 0.42))

        // The composer: the actual crop, a new note (none exist yet: "Quick notes"), an optional comment, the source.
        let save = app.buttons["composer.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(app.images["composer.preview"].waitForExistence(timeout: 10) || app.descendants(matching: .any)["composer.preview"].exists)
        let title = app.textFields["composer.newTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Quick snippets", "First use offers Quick snippets")
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
        XCTAssertTrue(app.staticTexts["entry.comment.1"].label.contains("The early improvement"), "The comment, read as the reader’s own")
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
        menuItem(app, "Rename collection").tap()
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        replaceText(name, with: "Preference learning", app: app)
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Preference learning"].waitForExistence(timeout: 10))
        capture("Renamed note")

        // Owner, build 78: the comment is the one place for the reader's words; no separate writing is added here.
        XCTAssertFalse(app.buttons["note.add"].exists, "No Add text in the stream")

        // Delete, confirmed with the note's name and entry count.
        app.buttons["note.options"].tap()
        menuItem(app, "Delete collection").tap()
        let sheet = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.otherElements.firstMatch
        XCTAssertTrue(app.staticTexts["Delete “Preference learning”?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1 snippet")).firstMatch.exists, "The count is stated")
        _ = sheet
        app.buttons["Delete collection"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Your ideas, collected"].waitForExistence(timeout: 10), "The list is empty again")
        capture("Notes empty after delete")
    }

    /// Owner, 2026-10-21: "In the snippet options when viewing it in a figure, there should be a Chat option to launch and
    /// talk about the snippet." The entry's ⋯ › Chat and the full-size view's Chat open the paper's chat with the crop
    /// attached and the comment as the draft, nothing sent; Back to note returns to the entry.
    func testSnippetChatAttachesTheCropAndReturnsToTheNote() throws {
        let app = launch(["--chat-fixture", "--chat-fixture-consented"])
        try requirePhoneLayout(app)
        let web = openSample(app)
        drawSnippet(app, web: web, from: CGVector(dx: 0.08, dy: 0.18), to: CGVector(dx: 0.92, dy: 0.42))
        let save = app.buttons["composer.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        let comment = app.textFields["composer.comment"].exists ? app.textFields["composer.comment"] : app.textViews["composer.comment"]
        comment.tap(); comment.typeText("Why does it level off?")
        waitFor("Save is ready") { save.isEnabled }
        save.tap()
        XCTAssertTrue(app.buttons["notes.saved.open"].waitForExistence(timeout: 10)); app.buttons["notes.saved.open"].tap()
        XCTAssertTrue(app.buttons["entry.image.1"].waitForExistence(timeout: 10))

        // ⋯ › Chat.
        app.buttons["entry.options.1"].tap()
        let chat = app.buttons["entry.chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5), "The snippet's options offer Chat")
        capture("Snippet options with Chat")
        chat.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.promotedImage"].waitForExistence(timeout: 10), "The crop is attached in the chat")
        XCTAssertTrue(app.staticTexts["chat.promotedImageNote"].label.contains("goes with your questions"), "It is sent with the questions")
        XCTAssertTrue(app.staticTexts["chat.promotedContext"].label.hasPrefix("Snippet"))
        let composer = app.descendants(matching: .any)["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        waitFor("The comment is the draft") { ((composer.value as? String) ?? composer.label).contains("Why does it level off?") }
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.")).count, 0, "Nothing was sent")
        capture("Snippet chat with the crop attached")
        app.buttons["chat.backToNote"].tap()
        XCTAssertTrue(app.buttons["entry.image.1"].waitForExistence(timeout: 10), "Back to note returns to the entry")

        // The full-size view's Chat.
        app.buttons["entry.image.1"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["zoom.image"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["zoom.chat"].exists, "Full size offers Chat")
        capture("Snippet full size with Chat")
        app.buttons["zoom.chat"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.promotedImage"].waitForExistence(timeout: 10))
        app.buttons["chat.backToNote"].tap()
        XCTAssertTrue(app.buttons["entry.image.1"].waitForExistence(timeout: 10))
    }

    /// The selection menu's Add to note keeps the passage as a quotation.
    func testAddSelectionToNote() throws {
        let app = launch()
        try requirePhoneLayout(app)
        let web = openSample(app)
        let paragraph = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A useful first pass identifies")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 20))
        web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: paragraph.frame.minX - web.frame.minX + 55,
                                                                        dy: paragraph.frame.minY - web.frame.minY + 18)).press(forDuration: 1)
        let add = app.revealEditMenuItem("Save snippet")
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Save snippet is in the selection menu")
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
        XCTAssertTrue(app.navigationBars["Quick snippets"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", quoted)).firstMatch.waitForExistence(timeout: 5),
                      "The quotation is in the note")
        capture("Note with a quotation")
    }

    /// A figure page's Add to note starts with the whole figure chosen; Use snippet saves it from the page.
    func testFigurePageAddToNoteStartsWithTheWholeFigure() throws {
        let app = launch()
        try requirePhoneLayout(app)
        let web = openSample(app)
        let figure = web.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open figure:")).firstMatch
        for _ in 0..<6 where !(figure.exists && figure.isHittable) { web.swipeUp() }
        XCTAssertTrue(figure.waitForExistence(timeout: 5)); figure.tap()
        // Add to note is in the figure page's ⋯ (beside the X), with Report this screen.
        let options = app.buttons["sheet.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10), "The figure page has a ⋯")
        options.tap()
        let add = app.buttons["figureView.addToNote"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "The figure page's ⋯ offers Add to note")
        add.tap()
        let use = app.buttons["capture.use"]
        let shown = use.waitForExistence(timeout: 10)
        if !shown { capture("Figure page after Add to note"); print(app.debugDescription) }
        XCTAssertTrue(shown)
        waitFor("The whole figure is already chosen") { use.isEnabled }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Drag corners")).firstMatch.exists)
        capture("Figure page: whole figure chosen")
        use.tap()
        let save = app.buttons["composer.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        waitFor("Prepared") { save.isEnabled }
        save.tap()
        let saved = app.staticTexts["notes.saved"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "Saved, on the figure page")
        capture("Figure page: saved")
        app.buttons["notes.saved.open"].tap()
        XCTAssertTrue(app.buttons["entry.image.1"].waitForExistence(timeout: 10), "Open note leaves the figure page for the note")
    }

    /// Settings › Your assets lists Notes (owner, 2026-10-21) and the row opens the Notes list.
    func testYourAssetsListsNotes() throws {
        let app = launch()
        try requirePhoneLayout(app)
        app.openSettingsFromMenu()
        let row = app.buttons["settings.notes"]
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Your assets has a Notes row")
        capture("Your assets with Notes")
        row.tap()
        XCTAssertFalse(app.navigationBars["Settings"].waitForExistence(timeout: 2), "Settings closes")
        XCTAssertTrue(app.buttons["tab.notes"].isSelected || app.navigationBars["Snippets"].waitForExistence(timeout: 5), "Snippets is shown")
    }

    /// Settings is the last section of every top-right menu and returns to where it was opened.
    func testSettingsFromEveryMenuReturnsToItsOrigin() throws {
        let app = launch()
        try requirePhoneLayout(app)
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
        XCTAssertTrue(app.buttons["Snippets options"].waitForExistence(timeout: 10))
        roundTrip("Notes") { app.buttons["Snippets options"].isHittable }
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

    /// iPad (wide) and Mac: Notes is a destination beside Feed, Library, Reader, Browse and General Chat, with the list and
    /// the open note side by side; capture works from the reader with its chat column; Escape cancels drawing.
    func testNotesInTheWideLayout() throws {
        // `TEST_RUNNER_NOTES_APPEARANCE=dark|light` for the visual review's other theme.
        let app = launch(appearance: ProcessInfo.processInfo.environment["NOTES_APPEARANCE"])
        let notesMode = app.wideMode("Snippets")
        try XCTSkipUnless(notesMode.waitForExistence(timeout: 5), "The wide layout (a 13-inch iPad, the Mac)")
        notesMode.tap()
        XCTAssertTrue(app.staticTexts["Your ideas, collected"].waitForExistence(timeout: 10))
        app.buttons["notes.new"].firstMatch.tap()
        let name = app.alerts.textFields.firstMatch.exists ? app.alerts.textFields.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.typeText("Project: alignment")
        (app.alerts.buttons["Create"].exists ? app.alerts.buttons["Create"] : app.buttons["Create"]).tap()
        // The list and the note, side by side.
        XCTAssertTrue(app.buttons["notes.row.Project: alignment"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["A place for your next idea"].waitForExistence(timeout: 10), "The new collection is open beside the list")
        capture("Wide Notes: list and empty note")

        // Read, draw, save to that note.
        app.wideMode("Library").tap()
        let web = openSample(app)
        #if targetEnvironment(macCatalyst)
        app.menuBars.menuBarItems["Paper"].click()
        app.menuItems["Draw Snippet"].click()
        let overlay = app.descendants(matching: .any)["capture.overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 5), "Escape cancels drawing")
        app.menuBars.menuBarItems["Paper"].click()
        app.menuItems["Draw Snippet"].click()
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.15))
            .press(forDuration: 0.1, thenDragTo: overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.4)))
        XCTAssertTrue(app.buttons["capture.use"].isEnabled)
        capture("Wide: box drawn")
        app.buttons["capture.use"].click()
        #else
        drawSnippet(app, web: web, from: CGVector(dx: 0.1, dy: 0.15), to: CGVector(dx: 0.8, dy: 0.4))
        #endif
        let save = app.buttons["composer.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        // A menu is a button on iOS and a pop-up button on the Mac.
        let destination = app.descendants(matching: .any)["composer.destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        XCTAssertTrue(destination.label.contains("Project: alignment") || (destination.value as? String)?.contains("Project: alignment") == true,
                      "An existing note is preselected: \(destination.label)")
        waitFor("Prepared") { save.isEnabled }
        capture("Wide: composer")
        save.tap()
        let saved = app.staticTexts["notes.saved"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        capture("Wide: saved")
        app.buttons["notes.saved.open"].tap()
        XCTAssertTrue(app.buttons["entry.image.1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["notes.row.Project: alignment"].exists, "The list stays beside the note")
        capture("Wide: note with its snippet")
        // Settings from the note's menu, and back to Notes.
        // Mac menus are pop-up buttons with menu items; iOS menus are buttons.
        app.descendants(matching: .any)["note.options"].firstMatch.tap()
        #if targetEnvironment(macCatalyst)
        let settings = app.menuItems["Settings"].firstMatch
        #else
        let settings = app.buttons["menu.settings"]
        #endif
        XCTAssertTrue(settings.waitForExistence(timeout: 5)); settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.navigationBars["Settings"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["entry.image.1"].waitForExistence(timeout: 10), "Done returns to the note")
    }

    /// Owner, 2026-10-21: "In the notes list each needs a very pleasant border around it, so it looks like a bunch of
    /// cards." Three notes as cards, apart from each other, with their swipe and long-press actions still working; light
    /// and dark screenshots on every layout (the phone's list, the wide layout's list beside the note).
    func testNotesListShowsCards() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let wideMode = app.wideMode("Snippets")
            let wide = !app.buttons["tab.notes"].exists
            if wide { XCTAssertTrue(wideMode.waitForExistence(timeout: 5)); wideMode.tap() } else { app.buttons["tab.notes"].tap() }
            for title in ["Preference learning", "Reading group: alignment", "Open questions"] {
                app.buttons["notes.new"].firstMatch.tap()
                let name = app.alerts.textFields.firstMatch.exists ? app.alerts.textFields.firstMatch : app.textFields.firstMatch
                XCTAssertTrue(name.waitForExistence(timeout: 5)); name.typeText(title)
                (app.alerts.buttons["Create"].exists ? app.alerts.buttons["Create"] : app.buttons["Create"]).tap()
                XCTAssertTrue(app.staticTexts["A place for your next idea"].waitForExistence(timeout: 10), "The new collection opens")
                if !wide { app.navigationBars.buttons.firstMatch.tap() }
            }
            let rows = ["Preference learning", "Reading group: alignment", "Open questions"].map { app.buttons["notes.row.\($0)"] }
            for row in rows { XCTAssertTrue(row.waitForExistence(timeout: 10)) }
            // (A row's accessibility frame is its whole list cell, insets included; the card's edge and gaps are checked
            // in the screenshots below.)
            capture("Notes cards \(appearance)\(wide ? " wide" : "")")
            if appearance == "light" {
                #if !targetEnvironment(macCatalyst)
                // Swipe keeps Delete and Rename (phone and iPad).
                rows[0].swipeLeft()
                XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 5), "Swipe offers Delete")
                XCTAssertTrue(app.buttons["Rename"].exists, "and Rename")
                capture("Notes card swiped")
                rows[0].swipeRight()
                #endif
                // Long-press (the Mac's secondary click) keeps the same actions.
                #if targetEnvironment(macCatalyst)
                rows[1].rightClick()
                #else
                rows[1].press(forDuration: 1.0)
                #endif
                XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 5) || app.menuItems["Rename"].waitForExistence(timeout: 2))
                capture("Notes card actions")
                #if targetEnvironment(macCatalyst)
                app.typeKey(.escape, modifierFlags: [])
                #else
                app.otherElements["PopoverDismissRegion"].firstMatch.exists ? app.otherElements["PopoverDismissRegion"].firstMatch.tap()
                    : app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
                #endif
            }
            app.terminate()
        }
    }

    /// Light and dark screenshots of the Notes list, a note and the composer (visual review).
    func testNotesScreenshotsLightAndDark() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            try requirePhoneLayout(app)
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
            XCTAssertTrue(app.buttons["Snippets options"].waitForExistence(timeout: 10))
            capture("Notes list \(appearance)")
            app.terminate()
        }
    }
}
