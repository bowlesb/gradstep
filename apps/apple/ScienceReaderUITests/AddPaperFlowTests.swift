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

    /// Replaces the field's text: Select All from the edit menu (a tap puts the caret mid-text). An iPad's long press
    /// shows no edit menu here: the caret goes to the end of these short links instead, and every character is deleted.
    private func replace(_ field: XCUIElement, with text: String, in app: XCUIApplication) {
        field.tap()
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            let selectAll = app.menuItems["Select All"].exists ? app.menuItems["Select All"] : app.buttons["Select All"]
            field.press(forDuration: 1.2)
            if selectAll.waitForExistence(timeout: 3) {
                selectAll.tap()
                field.typeText(XCUIKeyboardKey.delete.rawValue)
            } else {
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
            }
            XCTAssertTrue(((field.value as? String) ?? "").isEmpty || field.value as? String == field.placeholderValue, "The old text is gone")
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

    /// Add › Choose a PDF (the fixture picks a sample PDF for the system picker): PDFs stay on this device (2026-10-13),
    /// so it is saved here, never sent: the sheet closes, the Library says so and lists it under the PDF's own title.
    func testUploadAPDFFromFiles() {
        let app = launch(["--visual-show-import"])
        XCTAssertTrue(app.navigationBars["Add a paper"].waitForExistence(timeout: 10))
        save("add-sheet")
        app.buttons["add.choosePDF"].tap()
        XCTAssertTrue(app.navigationBars["Add a paper"].waitForNonExistence(timeout: 5), "the sheet closes once the PDF is saved")
        let notice = app.staticTexts["upload.notice"]
        if !notice.waitForExistence(timeout: 5) { save("upload-debug"); print(app.debugDescription) }
        XCTAssertEqual(notice.label, "Saved “Sparse Attention, Revisited: A Workshop Draft” on this device.")
        XCTAssertFalse(app.staticTexts["upload.status"].exists, "Nothing is uploaded")
        XCTAssertTrue(app.staticTexts["Sparse Attention, Revisited: A Workshop Draft"].waitForExistence(timeout: 5), "the PDF is in the library")
        save("upload-added")
    }

    /// Device fallback: a website that blocked our servers; this device downloads the PDF and keeps it here (PDFs
    /// stay on the device since 2026-10-13): the import then offers Open PDF instead of the download.
    func testDownloadOnThisDeviceForABlockedImport() {
        let app = launch()
        let filter = app.buttons["library.filter.failed"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10)); filter.tap()
        let download = app.buttons.matching(NSPredicate(format: "label == %@", "Download on this device")).firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        save("library-blocked-import")
        download.tap()
        let status = app.staticTexts["device.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("on this device"), status.label)
        save("device-download-progress")
        XCTAssertTrue(app.staticTexts["upload.notice"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["upload.notice"].label.hasSuffix("on this device."), app.staticTexts["upload.notice"].label)
        XCTAssertTrue(download.waitForNonExistence(timeout: 5), "the PDF is here: no download offered again")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Open PDF")).firstMatch.waitForExistence(timeout: 5), "the saved PDF opens")
        save("device-download-added")
    }

    /// A link this device can't download either: what to try next (Safari, or the PDF from Files).
    func testDeviceDownloadThatIsBlockedToo() {
        let app = launch(["--visual-show-import"])
        let field = app.textFields["import.reference"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        replace(field, with: Self.blockedLink, in: app)
        app.buttons["import.add"].tap()
        let device = app.buttons["add.next.device"]
        XCTAssertTrue(device.waitForExistence(timeout: 5))
        save("add-link-blocked-steps")
        device.tap()
        let issue = app.staticTexts["device.issue"]
        XCTAssertTrue(issue.waitForExistence(timeout: 10))
        XCTAssertTrue(issue.label.contains("blocked this device too"), issue.label)
        XCTAssertTrue(app.buttons["device.upload"].exists)
        save("device-download-blocked")
    }

    /// Share › Gradstep: the extension saved a PDF and a link (fixture inbox); on launch the PDF is saved on this
    /// device and the link opens Add, already looked up.
    func testSharedItemsAreAddedOnLaunch() {
        let app = launch(["--share-inbox-fixture"])
        XCTAssertTrue(app.navigationBars["Add a paper"].waitForExistence(timeout: 10), "the shared link opens Add")
        let outcome = app.staticTexts["add.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 5))
        XCTAssertTrue(outcome.label.contains("blocked the download"), outcome.label)
        save("share-link-outcome")
        app.buttons["Cancel"].tap()
        // Saved on this device at launch, before the Add sheet even opened (its six-second notice may be gone by now):
        // the Library lists it under the PDF's own title.
        XCTAssertTrue(app.staticTexts["Sparse Attention, Revisited: A Workshop Draft"].waitForExistence(timeout: 15), "the shared PDF is saved on this device")
        XCTAssertFalse(app.staticTexts["upload.status"].exists, "Nothing is uploaded")
        save("share-pdf-added")
    }

    /// A paper that isn't openly available: Add says so and offers the upload, which attaches to that paper.
    func testUploadForAPaperThatIsNotOpen() {
        let app = launch(["--visual-show-import"])
        let field = app.textFields["import.reference"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        replace(field, with: Self.closedDOI, in: app)
        app.buttons["import.add"].tap()
        let upload = app.buttons["add.next.upload"]
        XCTAssertTrue(upload.waitForExistence(timeout: 5))
        upload.tap()
        XCTAssertTrue(app.navigationBars["Add a paper"].waitForNonExistence(timeout: 5))
        let notice = app.staticTexts["upload.notice"]
        if !notice.waitForExistence(timeout: 10) { save("upload-closed-debug"); print(app.debugDescription) }
        XCTAssertTrue(notice.exists)
        XCTAssertTrue(notice.label.hasSuffix("on this device."), notice.label)
        // The failed import in the library also offers it inline (Add PDF: it stays on this device).
        app.buttons["library.filter.failed"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label == %@", "Add PDF")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        save("library-upload-action")
    }
}
