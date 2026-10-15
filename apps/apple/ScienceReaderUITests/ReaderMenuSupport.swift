import XCTest

/// The system edit menu (owner feedback, build 16 #4/#5): selected text and tapped equations in the paper, and
/// selected answer text, offer their actions in it. Its items are found by title (the edit menu's items are menu
/// items on iOS 16+, buttons in some layouts), paging the horizontal menu when an item is past its arrow.
extension XCUIApplication {
    func editMenuItem(_ title: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND (elementType == %d OR elementType == %d)",
            title, XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue)).firstMatch
    }

    /// Waits for the edit menu to show `title`. The horizontal menu shows the first items and an arrow ("Forward") that
    /// opens the full list; items after the arrow aren't in the hierarchy until then.
    @discardableResult
    func revealEditMenuItem(_ title: String, timeout: TimeInterval = 5) -> XCUIElement {
        let item = editMenuItem(title), copy = editMenuItem("Copy"), forward = buttons["Forward"]
        _ = copy.waitForExistence(timeout: timeout) || editMenuItem("Copy LaTeX").waitForExistence(timeout: 1)
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
        let tab = buttons["tab.\(place)"]
        if tab.waitForExistence(timeout: 2) { tab.tap(); return }
        let modes = segmentedControls.buttons
        switch place {
        case "feed": modes["Feed"].tap()
        case "library": modes["Library"].tap()
        case "paper": modes["Reader"].tap()
        case "chat":
            // The paper's chat when a paper is open (beside it), else the general chat.
            modes["Reader"].tap()
            if !descendants(matching: .any)["chat.composer"].waitForExistence(timeout: 2) { modes["General Chat"].tap() }
        case "settings": (buttons["Settings"].exists ? buttons["Settings"] : buttons["settings.open"]).tap()
        default: XCTFail("No place named \(place)")
        }
    }
}
