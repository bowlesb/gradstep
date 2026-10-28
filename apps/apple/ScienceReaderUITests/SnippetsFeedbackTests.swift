import XCTest

/// Owner feedback on TestFlight 91 (iPad upright, 2026-10-24) over the seeded collections (`--snippets-fixture`: "Quick
/// snippets" with six snippets, "Reading group" with two, an empty "New collection"): renaming in place, what search
/// covers, Collapse all, the empty collection and the rows, and the capture overlay. Every shape: the iPhone, the iPad
/// upright (Tall) and, where noted, sideways (Wide). `TEST_RUNNER_SNIPPETS_LANDSCAPE=1` runs the iPad sideways.
@MainActor
final class SnippetsFeedbackTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"
    private var current: XCUIApplication?

    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDown() {
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = .portrait
        #endif
        super.tearDown()
    }

    private var landscape: Bool { ProcessInfo.processInfo.environment["SNIPPETS_LANDSCAPE"] == "1" }

    private func launch(appearance: String = "light") -> XCUIApplication {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--draft-fixture", "--reset-draft-fixture", "--snippets-fixture", "-appearance", appearance]
        app.launch()
        current = app
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 15))
        #if !targetEnvironment(macCatalyst)
        if landscape, UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            _ = app.placesMenu.waitForExistence(timeout: 5)
        }
        #endif
        return app
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

    private func openSnippets(_ app: XCUIApplication) {
        app.show("notes")
        XCTAssertTrue(app.buttons["notes.row.Quick snippets"].waitForExistence(timeout: 10))
    }

    private func openCollection(_ app: XCUIApplication, _ title: String) {
        openSnippets(app)
        app.buttons["notes.row.\(title)"].tap()
    }

    private func titleField(_ app: XCUIApplication) -> XCUIElement { app.textFields["note.title"].firstMatch }

    /// Puts the caret at the end of `field` (a tap at its trailing edge), deletes what is there and types `text`.
    private func replace(_ field: XCUIElement, with text: String) {
        let old = (field.value as? String) ?? ""
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + text)
    }

    // MARK: 1. Rename in place

    /// "If I click on this here… I should be able to just relabel it right in place there." The collection's name where it
    /// is shown is a field: Return saves, leaving the field saves, Escape puts the name back, and ⋯ › Rename collection
    /// puts the caret there instead of an alert.
    func testRenameCollectionInPlace() throws {
        let app = launch()
        openCollection(app, "Quick snippets")
        let field = titleField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "The name is a field where it is shown")
        XCTAssertEqual(field.value as? String, "Quick snippets")
        capture("Rename: the name in its header")

        // Return saves. (A tap puts the caret where it lands: at the field's end, then the old name is deleted.)
        replace(field, with: "Reading list\n")
        waitFor("Renamed in the list too") { app.buttons["notes.row.Reading list"].exists || !app.buttons["notes.row.Quick snippets"].exists }
        XCTAssertEqual(titleField(app).value as? String, "Reading list")
        XCTAssertFalse(app.alerts.firstMatch.exists, "No alert")
        capture("Rename: saved with Return")

        // Escape puts the name back — with a hardware keyboard. With the on-screen keyboard (this Simulator's default) a
        // synthesized Escape never reaches the app, so there the touch path is checked: an emptied name puts it back.
        titleField(app).coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        if app.keyboards.count == 0 {
            titleField(app).typeText(" draft")
            XCTAssertEqual(titleField(app).value as? String, "Reading list draft")
            titleField(app).typeKey(.escape, modifierFlags: [])
            waitFor("Escape restores the name") { (self.titleField(app).value as? String) == "Reading list" }
        } else {
            titleField(app).typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Reading list".count) + "\n")
            waitFor("An empty name puts the name back") { (self.titleField(app).value as? String) == "Reading list" }
        }
        XCTAssertTrue(app.buttons["notes.row.Reading list"].exists || app.navigationBars["Reading list"].exists, "Nothing was saved")

        // Leaving the field saves: ⋯ › Rename collection puts the caret in it; scrolling the stream ends editing.
        let options = app.buttons["note.options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 5)); options.tap()
        menuItem(app, "Rename collection").tap()
        waitFor("Rename collection focuses the name") { (self.titleField(app).value(forKey: "hasKeyboardFocus") as? Bool) == true }
        // The caret is at the end of the name.
        titleField(app).typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Reading list".count) + "Ideas to test")
        app.descendants(matching: .any)["entry.card.1"].firstMatch.swipeUp(velocity: .slow)
        waitFor("Leaving the field ends editing") { (self.titleField(app).value(forKey: "hasKeyboardFocus") as? Bool) != true }
        waitFor("Leaving the field saves") { (self.titleField(app).value as? String) == "Ideas to test" }
        app.show("notes")
        if !app.wideShape {
            // Tall: back to the list.
            let back = app.navigationBars.buttons.firstMatch
            if back.exists, !app.buttons["notes.row.Ideas to test"].exists { back.tap() }
        }
        XCTAssertTrue(app.buttons["notes.row.Ideas to test"].waitForExistence(timeout: 10), "The list shows the new name")
        capture("Rename: saved on leaving the field")
    }

    // MARK: 2. Search

    /// "What in the snippets does it actually search? Is it as good as it possibly can be?" The field says what it covers;
    /// it finds words only in a snippet's image (recognised on this device), in the reading under a drawn region (an
    /// equation's LaTeX), a comment's word without its accent, and word beginnings.
    func testSearchCoversEveryTextOfASnippet() throws {
        let app = launch()
        openSnippets(app)
        let field = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields["notes.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.placeholderValue, "Names, comments, text, papers", "The field says what it searches")
        let quick = app.buttons["notes.row.Quick snippets"], group = app.buttons["notes.row.Reading group"]
        func search(_ text: String) {
            field.tap()
            if let value = field.value as? String, !value.isEmpty, value != field.placeholderValue {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
            }
            field.typeText(text)
        }
        // A word that is only in a snippet's pixels (Vision, on this device, once per image).
        search("KALEIDO")
        waitFor("Recognised text in an image is searched", timeout: 30) { quick.exists && !group.exists }
        capture("Search: recognised text")
        // The reading under a drawn region: an equation's LaTeX (its words: tokenizer v2, 2026-10-25, drops layout
        // commands such as \operatorname, keeping their arguments).
        search("softmax")
        waitFor("The equation under the region is searched") { quick.exists && !group.exists }
        // Without the comment's accent, by a word's beginning.
        search("cafe tab")
        waitFor("Diacritics and case fold; words match from their start") { quick.exists && !group.exists }
        search("thurs")
        waitFor("A comment") { group.exists && !quick.exists }
        search("table 1")
        waitFor("A figure or table label") { group.exists }
        search("zzzz")
        XCTAssertTrue(app.staticTexts["No matching snippets"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Searches collection names")).firstMatch.exists,
                      "With nothing found, it says in full what it searched")
        capture("Search: nothing found says what it searched")
    }

    // MARK: 4 and 5. Rows and the empty collection

    /// "you have this duplicate… it says No snippets yet, and 0 snippets" and "You just need two lines there, the title
    /// and then the number of snippets… remove the date too". A row is its name and its count; an empty collection says
    /// so once, and its stream says so once.
    func testRowsAreNameAndCountAndAnEmptyCollectionSaysSoOnce() throws {
        let app = launch()
        openSnippets(app)
        XCTAssertEqual(app.buttons["notes.row.Quick snippets"].label, "Quick snippets, 6 snippets")
        XCTAssertEqual(app.buttons["notes.row.Reading group"].label, "Reading group, 2 snippets")
        XCTAssertEqual(app.buttons["notes.row.New collection"].label, "New collection, No snippets yet")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Snippet from")).firstMatch.exists, "No papers")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "0 snippets")).firstMatch.exists)
        capture("Rows: name and count")
        app.buttons["notes.row.New collection"].tap()
        XCTAssertTrue(app.staticTexts["A place for your next idea"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@ OR label CONTAINS %@", "No snippets yet", "0 snippets"))
                       .allElementsBoundByIndex.filter { $0.isHittable && !self.isInList($0, app) }.count, 0,
                       "The empty collection says it once")
        capture("Empty collection")
    }

    private func isInList(_ element: XCUIElement, _ app: XCUIApplication) -> Bool {
        // Wide shows the list beside the collection; its row legitimately says "No snippets yet".
        let row = app.buttons["notes.row.New collection"]
        return row.exists && row.frame.intersects(element.frame)
    }

    // MARK: 3. Collapse all

    /// "Collapse all… there was some jaggedy… it happened at multiple stages, and why is there this black thing at the
    /// top?" The first Collapse all after opening Snippets, scrolled part-way: one step, every card at once, the top of
    /// the stream never uncovered (no dark band under the bar while it happens), and the stream still there after.
    func testFirstCollapseAllIsOneCleanStep() throws {
        let app = launch(appearance: "light")
        openCollection(app, "Quick snippets")
        XCTAssertTrue(app.buttons["entry.image.1"].waitForExistence(timeout: 10))
        // Part-way down, as the owner was.
        app.swipeUp(velocity: .slow)
        sleep(1)
        let options = app.buttons["note.options"].firstMatch
        options.tap()
        menuItem(app, "Collapse all").tap()
        var shots: [XCUIScreenshot] = []
        for _ in 0..<6 { shots.append(XCUIScreen.main.screenshot()) }
        for (index, shot) in shots.enumerated() {
            let attachment = XCTAttachment(screenshot: shot); attachment.name = "Collapse all frame \(index)"
            attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertNil(Self.darkBand(in: shot.image), "Frame \(index): nothing dark is uncovered at the top")
        }
        waitFor("Every card collapsed") {
            (1...6).allSatisfy { app.descendants(matching: .any)["entry.collapsed.\($0)"].exists }
        }
        XCTAssertTrue(app.descendants(matching: .any)["entry.collapsed.1"].isHittable || app.descendants(matching: .any)["entry.collapsed.6"].isHittable,
                      "The collapsed stream is in view")
        if !app.wideShape {
            // The stream keeps its column, centred in the window (a first fix that anchored the scroll position shifted it).
            let card = app.descendants(matching: .any)["entry.card.1"].firstMatch
            XCTAssertEqual(card.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 4, "The collapsed cards stay centred")
        }
        capture("Collapse all: done")
        options.tap()
        menuItem(app, "Expand all").tap()
        XCTAssertTrue(app.buttons["entry.image.1"].waitForExistence(timeout: 5) || app.buttons["entry.image.6"].waitForExistence(timeout: 5))
    }

    /// The first pixel row (from the top, below the status bar) that is almost entirely near-black, in a light-appearance
    /// screenshot; nil when there is none.
    static func darkBand(in image: UIImage) -> Int? {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        // The top 40% of the screen, past the status bar; the middle 80% of each row.
        let top = Int(Double(height) * 0.04), bottom = Int(Double(height) * 0.4)
        for y in stride(from: top, to: bottom, by: 2) {
            var dark = 0, total = 0
            for x in stride(from: width / 10, to: width * 9 / 10, by: 4) {
                let i = (y * width + x) * 4
                let luminance = 0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])
                if luminance < 40 { dark += 1 }
                total += 1
            }
            if total > 0, Double(dark) / Double(total) > 0.9 { return y }
        }
        return nil
    }

    // MARK: 6. The capture overlay

    /// "you just need the button, Use snippet… put it in the bottom right… you don't need the enclosure. None of this
    /// other stuff": the box with its corners and Use snippet in the corner; no size, no instructions, no Full page or
    /// Adjust edges. The keyboard keeps a way to choose the whole page, and the save flow after it is unchanged.
    func testCaptureIsTheBoxAndUseSnippet() throws {
        let app = launch()
        app.buttons[sampleID].tap()
        if app.wideShape, !app.buttons["Paper options"].exists { app.choosePlace("paper") }
        let options = app.buttons["Paper options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        options.tap()
        menuItem(app, "Draw snippet").tap()
        let overlay = app.descendants(matching: .any)["capture.overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        let use = app.buttons["capture.use"]
        XCTAssertTrue(use.exists)
        XCTAssertFalse(use.isEnabled, "Nothing drawn yet")
        for gone in ["capture.whole", "capture.edges", "capture.status"] {
            XCTAssertFalse(app.descendants(matching: .any)[gone].exists, "\(gone) is gone")
        }
        for words in ["Drag corners", "Draw a box", "Full page", "Whole page", "Adjust edges", "Drag around"] {
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", words)).allElementsBoundByIndex
                .contains { $0.frame.width > 1 && $0.frame.height > 1 }, "No “\(words)”")
            // (⌘A's keyboard-only button is zero-sized: nothing on screen.)
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", words)).allElementsBoundByIndex
                .contains { $0.frame.width > 1 && $0.frame.height > 1 }, "No “\(words)” button")
        }
        capture("Capture: ready")
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.25))
            .press(forDuration: 0.05, thenDragTo: overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)))
        waitFor("A drawn box can be used") { use.isEnabled }
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "×")).firstMatch.exists, "No size readout")
        // In the bottom-right corner of the page.
        let page = overlay.frame
        XCTAssertEqual(use.frame.maxX, page.maxX - 16, accuracy: 4, "At the trailing edge")
        XCTAssertEqual(use.frame.maxY, page.maxY - 16, accuracy: 4, "At the bottom")
        capture("Capture: box drawn")
        use.tap()
        let save = app.buttons["composer.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), "The save flow is unchanged")
        waitFor("Prepared") { save.isEnabled }
        save.tap()
        XCTAssertTrue(app.staticTexts["notes.saved"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["notes.saved.open"].exists, "Saved · Open")
        capture("Capture: saved")
    }

    /// A hardware keyboard: ⌘A chooses the whole page, then Use snippet takes it (iPad).
    func testCaptureKeyboardChoosesTheWholePage() throws {
        #if !targetEnvironment(macCatalyst)
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "A hardware keyboard on iPad")
        #endif
        let app = launch()
        app.buttons[sampleID].tap()
        if app.wideShape, !app.buttons["Paper options"].exists { app.choosePlace("paper") }
        let options = app.buttons["Paper options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 10)); sleep(2)
        options.tap()
        menuItem(app, "Draw snippet").tap()
        let overlay = app.descendants(matching: .any)["capture.overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        sleep(1)
        // (The Simulator sometimes drops the first synthesized shortcut after a menu closes: one retry.)
        for _ in 0..<2 where !app.buttons["capture.use"].isEnabled {
            app.typeKey("a", modifierFlags: .command)
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"),
                                                               object: app.buttons["capture.use"])], timeout: 3)
        }
        waitFor("⌘A takes the whole page") { app.buttons["capture.use"].isEnabled }
        app.buttons["capture.use"].tap()
        XCTAssertTrue(app.buttons["composer.save"].waitForExistence(timeout: 10), "The whole page is used")
    }
}
