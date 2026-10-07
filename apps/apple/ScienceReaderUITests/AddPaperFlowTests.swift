import XCTest

/// Adding papers by any identifier or link, from a PDF file, and on this device when a website blocks
/// our servers (docs/architecture/PDF_UPLOADS.md). Scripted server outcomes (`--add-paper-fixture`):
/// no account, network or provider. Screens are attached, and also written to `GS_SCREENSHOT_DIR` when
/// the runner sets it (`TEST_RUNNER_GS_SCREENSHOT_DIR=…`).
@MainActor
final class AddPaperFlowTests: XCTestCase {
    private static let closedDOI = "10.1145/3292500.3330701"
    private static let openDOI = "10.48550/arXiv.1706.03762"
    private static let blockedLink = "https://openreview.net/pdf?id=HPuSIXJaa9"

    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "--library-metadata-fixture", "--add-paper-fixture"] + extra
        app.launch()
        return app
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let directory = ProcessInfo.processInfo.environment["GS_SCREENSHOT_DIR"], !directory.isEmpty {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    /// Replaces the field's text: Select All from the edit menu (a tap puts the caret mid-text).
    private func replace(_ field: XCUIElement, with text: String, in app: XCUIApplication) {
        field.tap()
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            field.press(forDuration: 1.2)
            let selectAll = app.menuItems["Select All"].exists ? app.menuItems["Select All"] : app.buttons["Select All"]
            if selectAll.waitForExistence(timeout: 3) { selectAll.tap() }
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        field.typeText(text)
    }

    func testAddByDOIAndLink() {
        let app = launch(["--visual-show-import"])
        XCTAssertTrue(app.navigationBars["Add a paper"].waitForExistence(timeout: 10))
        let field = app.textFields["import.reference"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        // A DOI with no open copy: the reader is told why and offered the PDF upload.
        replace(field, with: Self.closedDOI, in: app)
        app.buttons["import.add"].tap()
        let outcome = app.staticTexts["add.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 5))
        XCTAssertTrue(outcome.label.contains("isn’t openly available"), outcome.label)
        save("add-doi-closed")

        // A website that blocks our servers (OpenReview).
        replace(field, with: Self.blockedLink, in: app)
        XCTAssertFalse(outcome.exists, "editing the link clears the previous outcome")
        app.buttons["import.add"].tap()
        XCTAssertTrue(outcome.waitForExistence(timeout: 5))
        XCTAssertTrue(outcome.label.contains("blocked the download"), outcome.label)
        save("add-link-blocked")

        // A DOI with an arXiv copy is queued and the sheet closes.
        replace(field, with: Self.openDOI, in: app)
        app.buttons["import.add"].tap()
        let closed = app.navigationBars["Add a paper"].waitForNonExistence(timeout: 5)
        if !closed { save("add-open-doi-stuck") }
        XCTAssertTrue(closed)
    }
}
