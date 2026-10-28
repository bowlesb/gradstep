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

/// The app's places in either shape (docs/DESIGN.md › Tall and Wide). Tall has the bar at the bottom: on iPhone and narrow
/// windows Library · Paper · Chat · More (`tab.more`), whose list holds Feed, Snippets and Settings as rows with the same
/// `tab.*` identifiers; on an iPad upright all six places. 🔍 (`tab.search`) sits beside the bar (owner, 2026-10-25). The iPad
/// sideways (Wide, owner 2026-10-23) has the places menu (`places.menu`) in the window's top-left corner, whose rows keep
/// the `tab.*` identifiers, with 🔍 beside it; there Chat is the general chat and a paper's chat sits beside its paper. The
/// Mac's places are the window toolbar's group, which accessibility reports as check boxes.
extension XCUIApplication {
    /// Tall's bar is showing (iPhone, an iPad upright): its Library item, which every Tall bar has.
    var tallBar: XCUIElement { buttons["tab.library"] }

    /// The compact bar's More (iPhone, narrow windows); absent where every place shows.
    var moreItem: XCUIElement { buttons["tab.more"] }

    /// The More list's row for a place under More (Feed, Snippets, Settings): More is tapped first, which always opens its
    /// list (a second tap from Feed or Snippets returns to it).
    @discardableResult
    func openFromMore(_ place: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(moreItem.waitForExistence(timeout: 5), "The bar has More", file: file, line: line)
        moreItem.tap()
        let row = descendants(matching: .any)["tab.\(place)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "More lists \(place)", file: file, line: line)
        return row
    }

    /// The Wide shape on iPad (the places menu), or the Mac.
    var wideShape: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return buttons["places.menu"].exists
        #endif
    }

    /// The places menu (iPad Wide).
    var placesMenu: XCUIElement { buttons["places.menu"] }

    /// A place's `tab.*` control: the bar's button in Tall, or More's row for a place under More (More is opened first);
    /// in Wide, the places menu's row (the menu is opened first).
    func placeItem(_ place: String) -> XCUIElement {
        let item = descendants(matching: .any)["tab.\(place)"].firstMatch
        #if !targetEnvironment(macCatalyst)
        if !item.exists, placesMenu.exists {
            placesMenu.tap()
            _ = item.waitForExistence(timeout: 3)
        } else if !item.exists, moreItem.exists, ["feed", "notes", "settings"].contains(place) {
            return openFromMore(place)
        }
        #endif
        return item
    }

    /// A place chosen directly (the Mac's toolbar check box, the iPad's places menu row, the capsule's button): unlike
    /// `show("chat")`, Chat here is the general chat on the Mac, and on iPad the conversation last shown (owner,
    /// 2026-10-24), beside All chats in Wide.
    func choosePlace(_ place: String) {
        #if targetEnvironment(macCatalyst)
        let titles = ["feed": "Feed", "library": "Library", "paper": "Paper", "chat": "Chat", "notes": "Snippets"]
        toolbars.checkBoxes[titles[place] ?? place].tap()
        #else
        let item = placeItem(place)
        XCTAssertTrue(item.waitForExistence(timeout: 3), "The places have \(place)")
        item.tap()
        #endif
    }

    /// The current place, as the places menu says it (iPad Wide): "Places, Library" is "Library".
    var currentPlace: String? {
        let label = placesMenu.label
        return label.hasPrefix("Places, ") ? String(label.dropFirst("Places, ".count)) : nil
    }

    func show(_ place: String) {
        // Settings: the iPad's sixth place (its bar upright, its places menu sideways; owner, 2026-10-24); More's third row
        // on iPhone (owner, 2026-10-25); the last section of every ⋯ menu on the Mac.
        if place == "settings" {
            openSettingsFromMenu()
            return
        }
        #if targetEnvironment(macCatalyst)
        let places = toolbars.checkBoxes
        switch place {
        case "feed": places["Feed"].tap()
        case "library": places["Library"].tap()
        case "paper": places["Paper"].tap()
        case "chat":
            // The paper's chat when a paper is open (beside it), else the general chat.
            places["Paper"].tap()
            if !descendants(matching: .any)["chat.composer"].waitForExistence(timeout: 2) { places["Chat"].tap() }
        case "notes": places["Snippets"].tap()
        default: XCTFail("No place named \(place)")
        }
        #else
        if place == "chat", wideShape {
            // Wide: the paper's chat is beside its paper; Chat is the general chat.
            let paper = placeItem("paper")
            if paper.exists, paper.isEnabled {
                paper.tap()
                if descendants(matching: .any)["chat.composer"].waitForExistence(timeout: 2) { return }
            } else if paper.exists {
                placesMenu.tap()   // Paper unavailable: close the menu before choosing Chat.
            }
        }
        let tab = placeItem(place)
        XCTAssertTrue(tab.waitForExistence(timeout: 3), "The places have \(place)")
        tab.tap()
        #endif
    }

    /// Wide: the Library with the paper beside it. On iPad that is the Library place itself (owner, 2026-10-23); on the
    /// Mac, Library ⋯ › Show library beside paper (formerly Browse).
    func showBrowse(file: StaticString = #filePath, line: UInt = #line) {
        #if !targetEnvironment(macCatalyst)
        if wideShape {
            if currentPlace != "Library" { show("library") }
            return
        }
        #endif
        // Already there (a paper opened from the Library lands in Browse).
        if segmentedControls["library.searchScope"].exists { return }
        show("library")
        let options = buttons["Library options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5), file: file, line: line)
        options.tap()
        let toggle = descendants(matching: .any)["library.browse"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 3), "Library ⋯ offers the paper beside the library", file: file, line: line)
        toggle.tap()
    }

    /// The ⋯ menu of whichever screen shows (by its accessibility label).
    var screenOptions: XCUIElement {
        let labels = ["Library options", "Feed options", "Listen options", "Paper options", "Chat options", "Snippets options", "Collection options"]
        return buttons.matching(NSPredicate(format: "label IN %@", labels)).allElementsBoundByIndex.first { $0.isHittable }
            ?? buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    /// Settings: on iPad its place (the bar's last item upright, the places menu's last row sideways; in no ⋯ menu, owner
    /// 2026-10-24), on iPhone More's third row (owner, 2026-10-25: over the More list), on the Mac the ⋯ menu's last section.
    func openSettingsFromMenu(file: StaticString = #filePath, line: UInt = #line) {
        let tab = buttons["tab.settings"]
        if tab.exists && tab.isHittable { tab.tap(); return }
        let places = buttons["places.menu"]
        if places.exists && places.isHittable {
            places.tap()
            let settings = descendants(matching: .any)["tab.settings"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings is in the places menu", file: file, line: line)
            settings.tap()
            return
        }
        if moreItem.exists && moreItem.isHittable {
            openFromMore("settings", file: file, line: line).tap()
            return
        }
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
    /// Back to the paper from its chat: the chat's Return to paper in Tall; in Wide the paper is beside the chat, so leave
    /// for another place and come back to Paper (the reader restores its place either way).
    func returnToPaper() {
        let back = buttons["chat.returnToPaper"]
        if back.waitForExistence(timeout: 2) { back.tap(); return }
        #if targetEnvironment(macCatalyst)
        toolbars.checkBoxes["Library"].tap(); toolbars.checkBoxes["Paper"].tap()
        #else
        show("library"); show("paper")
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
    /// A place by its title, older names included ("Reader" is Paper, "General Chat" is Chat): the places capsule's button
    /// on iPhone and the upright iPad, the Mac window toolbar's check box. On the iPad sideways it is the places menu's row,
    /// there only while the menu is open: use `show(_:)` to go there and `currentPlace` to ask where you are.
    func wideMode(_ title: String) -> XCUIElement {
        let place: String
        switch title {
        case "Reader", "Paper": place = "Paper"
        case "General Chat", "Chat": place = "Chat"
        default: place = title
        }
        #if targetEnvironment(macCatalyst)
        return toolbars.checkBoxes[place]
        #else
        let id = ["Feed": "feed", "Library": "library", "Paper": "paper", "Chat": "chat", "Snippets": "notes"][place] ?? place.lowercased()
        return descendants(matching: .any)["tab.\(id)"].firstMatch
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

/// A tapped equation's Focus (owner, build 78; it was AI Explainer, which asked at once) opens the equation view without
/// asking; the view's own AI Explainer asks (then the model choice).
extension XCUIApplication {
    func askEquationExplainer(file: StaticString = #filePath, line: UInt = #line) {
        let explain = buttons["equation.explain"]
        XCTAssertTrue(explain.waitForExistence(timeout: 8), "Focus opens the equation with AI Explainer waiting", file: file, line: line)
        explain.tap()
    }
}
