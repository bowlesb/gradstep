import XCTest

/// The system edit menu (owner feedback, build 16 #4/#5): selected text and tapped equations in the paper, and
/// selected answer text, offer their actions in it. Its items are found by title (the edit menu's items are menu
/// items on iOS 16+, buttons in some layouts), paging the horizontal menu when an item is past its arrow.
extension XCUIApplication {
    func editMenuItem(_ title: String) -> XCUIElement {
        #if targetEnvironment(macCatalyst)
        return menuItems.matching(NSPredicate(format: "title == %@ OR label == %@", title, title)).firstMatch
        #else
        descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND (elementType == %d OR elementType == %d)",
            title, XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue)).firstMatch
        #endif
    }

    /// Waits for the edit menu to show `title`. The horizontal menu shows the first items and an arrow ("Forward") that
    /// opens the full list; items after the arrow aren't in the hierarchy until then.
    @discardableResult
    func revealEditMenuItem(_ title: String, timeout: TimeInterval = 5) -> XCUIElement {
        let item = editMenuItem(title), copy = editMenuItem("Copy"), forward = buttons["Forward"]
        _ = copy.waitForExistence(timeout: timeout) || editMenuItem("Copy as Text").waitForExistence(timeout: 1) || editMenuItem("Copy LaTeX").exists
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if item.exists, item.isHittable, !forward.exists || item.frame.maxX <= forward.frame.minX + 1 { return item }
            if forward.exists, forward.isHittable {
                forward.tap()
                if item.waitForExistence(timeout: 2) { return item }
            }
            usleep(200_000)
        }
        return item
    }

    /// True while any of the paper's selection actions is offered (the edit menu is open over the paper).
    var paperSelectionMenuShown: Bool { editMenuItem("Explain in Chat").exists }
}

/// The app's places in either layout (audit 2026-10-15: journeys tapped the iPhone tab bar, which the wide layout of a
/// 13-inch iPad and the Mac doesn't have). Narrow layouts (iPhone, an 11-inch iPad in portrait) use the tab bar; the
/// wide one uses its mode control, where the paper's chat sits beside the paper in Reader.
extension XCUIApplication {
    func show(_ place: String) {
        // Phone width (owner, 2026-10-20): Notes took Settings' tab; Settings is the last section of every ⋯ menu.
        if place == "settings", buttons["tab.notes"].waitForExistence(timeout: 2) {
            openSettingsFromMenu()
            return
        }
        let tab = buttons["tab.\(place)"]
        if tab.waitForExistence(timeout: 2) { tab.tap(); return }
        // The wide layout's mode control by its identifier: the Library's search switch also has a "Library" segment.
        // On the Mac it is the window toolbar's segmented control, which accessibility reports as check boxes.
        #if targetEnvironment(macCatalyst)
        let modes = toolbars.checkBoxes
        #else
        let modes = segmentedControls["wide.mode"].buttons
        #endif
        switch place {
        case "feed": modes["Feed"].tap()
        case "library": modes["Library"].tap()
        case "paper": modes["Reader"].tap()
        case "chat":
            // The paper's chat when a paper is open (beside it), else the general chat.
            modes["Reader"].tap()
            if !descendants(matching: .any)["chat.composer"].waitForExistence(timeout: 2) { modes["General Chat"].tap() }
        case "notes": modes["Notes"].tap()
        case "settings": (buttons["Settings"].exists ? buttons["Settings"] : buttons["settings.open"]).tap()
        default: XCTFail("No place named \(place)")
        }
    }

    /// The ⋯ menu of whichever screen shows (by its accessibility label).
    var screenOptions: XCUIElement {
        let labels = ["Library options", "Feed options", "Listen options", "Paper options", "Chat options", "Notes options", "Note options"]
        return buttons.matching(NSPredicate(format: "label IN %@", labels)).allElementsBoundByIndex.first { $0.isHittable }
            ?? buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    /// Settings from the current screen's ⋯ menu (its last section), over that screen.
    func openSettingsFromMenu(file: StaticString = #filePath, line: UInt = #line) {
        let options = screenOptions
        XCTAssertTrue(options.waitForExistence(timeout: 5), "The screen has a ⋯ menu", file: file, line: line)
        options.tap()
        // Wait for the menu (the check ran before it appeared), and at accessibility text sizes scroll it: Settings is
        // its last section and starts below the first screen of a long menu.
        let settings = buttons["menu.settings"]
        if !settings.waitForExistence(timeout: 3) || !settings.isHittable {
            for _ in 0..<5 where !(settings.exists && settings.isHittable) { collectionViews.firstMatch.swipeUp() }
        }
        let target = settings.exists ? settings : buttons["Settings"]
        XCTAssertTrue(target.waitForExistence(timeout: 5), "Settings is in the ⋯ menu", file: file, line: line)
        target.tap()
    }
}

extension XCUIApplication {
    /// Settings' Theme control (Reading section). Settings is a lazy list: since the Library and Experimental sections
    /// were added (2026-10-15) the Reading section starts below an iPhone's first screen, so scroll until it exists.
    func settingsTheme() -> XCUIElement {
        let theme = segmentedControls["settings.theme"]
        for _ in 0..<6 where !theme.waitForExistence(timeout: 1) { swipeUp() }
        return theme
    }
}

extension XCUIApplication {
    /// Back to the paper from its chat: the chat's Return to paper on a phone; in the wide layout the paper is beside
    /// the chat, so leave for another view and come back to Reader (the reader restores its place either way).
    func returnToPaper() {
        let back = buttons["chat.returnToPaper"]
        if back.waitForExistence(timeout: 2) { back.tap(); return }
        #if targetEnvironment(macCatalyst)
        toolbars.checkBoxes["Library"].tap(); toolbars.checkBoxes["Reader"].tap()
        #else
        segmentedControls["wide.mode"].buttons["Library"].tap()
        segmentedControls["wide.mode"].buttons["Reader"].tap()
        #endif
    }
}

/// Portrait on iPhone and iPad; the Mac has no device orientation (setting it there throws "Unsupported code path").
extension XCUIDevice {
    func portraitWhereSupported() {
        #if !targetEnvironment(macCatalyst)
        orientation = .portrait
        #endif
    }
}

extension XCUIApplication {
    /// One of the wide layout's modes ("Feed", "Library", "Reader", "Browse", "General Chat"): the iPad's segmented
    /// control, or the Mac window toolbar's, which accessibility reports as check boxes.
    func wideMode(_ title: String) -> XCUIElement {
        #if targetEnvironment(macCatalyst)
        return toolbars.checkBoxes[title]
        #else
        return segmentedControls["wide.mode"].buttons[title]
        #endif
    }
}

extension XCUIElement {
    /// Taps once the element has stopped moving: a tap on a list or transcript still coasting from a swipe (or an
    /// answer's last scroll) only stops it, as iOS does, and the row's button doesn't fire (journeys on the iPhone 17 Pro
    /// Simulator, 2026-10-16: Contents › a heading and an answer's diagram).
    func tapWhenSettled(timeout: TimeInterval = 3) {
        var previous = frame
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            usleep(250_000)
            let current = frame
            if current == previous { break }
            previous = current
        }
        tap()
    }
}

/// An information sheet's one glass top row (docs/DESIGN.md "Sheet top row", owner build 62): Contents' tabs are buttons
/// `contents.tabs.<name>` in the `contents.tabs` capsule; the sheet closes with `sheet.close`; a pushed page goes back
/// with `sheet.back` (or its navigation bar's Back, where a page still has one).
extension XCUIApplication {
    var contentsTabs: XCUIElement { descendants(matching: .any)["contents.tabs"] }
    func contentsTab(_ title: String) -> XCUIElement { buttons["contents.tabs.\(title.lowercased())"] }
    func sheetBack(from title: String) {
        let glass = buttons["sheet.back"]
        if glass.exists, glass.isHittable { glass.tap(); return }
        // A page with no title in its bar (the figure page's top row) is found by the system Back's identifier.
        let titled = navigationBars[title]
        if titled.exists { titled.buttons.firstMatch.tap() } else { navigationBars.buttons["BackButton"].firstMatch.tap() }
    }
}

/// A figure, table or equation page (owner, build 78: "use txt at top Snippet, Chat, AI Explainer… X also not needed"): its
/// top row is words, Snippet first whenever the page belongs to the open paper; on a touch screen the sheet swipes away
/// (the Mac keeps `sheet.close`).
extension XCUIApplication {
    /// A figure or table page's Snippet, there as soon as the page shows.
    var figurePageSnippet: XCUIElement { buttons["figureView.addToNote"] }
    /// Closes the page's sheet: its X on the Mac, otherwise a downward drag starting on `anchor` (an element of its top row).
    func closeInfoSheet(from anchor: XCUIElement) {
        let close = buttons["sheet.close"]
        if close.exists, close.isHittable { close.tap(); return }
        for _ in 0..<2 where anchor.exists {
            // Twice at most: a half-height sheet may first settle at its smaller detent.
            anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)),
                       withVelocity: .fast, thenHoldForDuration: 0)
            if anchor.waitForNonExistence(timeout: 3) { return }
        }
    }
}
