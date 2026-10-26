import XCTest

@MainActor
final class PDFPeekJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait; super.tearDown() }

    private func openReader(imageOnly: Bool = false, largeText: Bool = false) -> (XCUIApplication, XCUIElement) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "--pdf-peek-fixture", "--start-tab=paper"]
        if imageOnly { app.launchArguments.append("--pdf-peek-image-only") }
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["Table of contents"].waitForExistence(timeout: 10))
        app.buttons["Table of contents"].tap()
        let heading = app.buttons["1. Start with the question"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5)); heading.tap()
        let paragraph = app.webViews.firstMatch.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A useful first pass")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
        let button = app.buttons["paper.showInPDF"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            button.exists && button.isEnabled && (largeText || paragraph.frame.intersects(app.webViews.firstMatch.frame))
        }, object: nil)], timeout: 8), .completed)
        return (app, paragraph)
    }

    private func waitForMatch(_ app: XCUIApplication, page: Int = 2) {
        let status = app.staticTexts["pdfPeek.status"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            status.exists && status.label.contains("Page \(page)")
        }, object: nil)], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["pdfPeek.close"].isHittable)
    }

    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testTwoFingerSingleTapOpensFullScreenZoomsFadesAndXPreservesReaderPosition() {
        let (app, paragraph) = openReader()
        app.webViews.firstMatch.pinch(withScale: 1.2, velocity: 1)
        XCTAssertFalse(app.buttons["pdfPeek.close"].exists, "A moving two-finger pinch must not open the PDF")
        let originalY = paragraph.frame.minY
        // One simultaneous two-touch tap. The existing one-finger double tap still opens Contents (separate regression).
        paragraph.tap(withNumberOfTaps: 1, numberOfTouches: 2)
        waitForMatch(app)
        let pdf = app.descendants(matching: .any)["pdfPeek.document"].firstMatch
        XCTAssertTrue(pdf.exists)
        XCTAssertEqual(pdf.frame.width, app.frame.width, accuracy: 2, "The PDF spans the screen, including on iPad")
        XCTAssertGreaterThan(pdf.frame.height, app.frame.height * 0.75)
        XCTAssertFalse(app.buttons["Sheet Grabber"].exists)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (pdf.value as? String)?.contains("outline hidden") == true
        }, object: nil)], timeout: 5), .completed)
        XCTAssertFalse((pdf.value as? String)?.contains("zoom 100%") == true, "The camera has zoomed into the area")
        capture("Full-screen PDF after the outline fades")
        pdf.pinch(withScale: 1.2, velocity: 1)
        pdf.swipeUp(velocity: .slow)
        app.buttons["pdfPeek.close"].tap()
        XCTAssertTrue(app.buttons["pdfPeek.close"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(paragraph.frame.minY, originalY, accuracy: 3)
        // The accessible toolbar entry has the same presentation and the top-row swipe is an alternate way back.
        app.buttons["paper.showInPDF"].tap()
        // The taller iPad viewport's upper quarter is in the next paragraph (PDF page 3), while the two-finger
        // tap above intentionally chose the first paragraph (page 2). The button must use the live viewport.
        waitForMatch(app, page: app.frame.width > 600 ? 3 : 2)
        let status = app.staticTexts["pdfPeek.status"]
        status.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(app.buttons["pdfPeek.close"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(paragraph.frame.minY, originalY, accuracy: 3)
    }

    func testTwoFingerTapUsesTheTouchedParagraphAndReadingModeKeepsItsPlace() {
        let (app, _) = openReader()
        // Tablet reading mode replaces PaperView but keeps the root full-screen presentation host.
        if app.frame.width > 600 {
            XCUIDevice.shared.orientation = .landscapeLeft
            app.buttons["Paper options"].tap()
            let enter = app.buttons["paper.readingMode"]
            XCTAssertTrue(enter.waitForExistence(timeout: 5)); enter.tap()
        }
        let paragraph = app.webViews.firstMatch.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Select a few words")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
        for _ in 0..<4 where !paragraph.isHittable { app.webViews.firstMatch.swipeUp(velocity: .slow) }
        let originalY = paragraph.frame.minY
        paragraph.tap(withNumberOfTaps: 1, numberOfTouches: 2)
        waitForMatch(app, page: 3)
        capture("PDF at the touched second paragraph")
        app.buttons["pdfPeek.close"].tap()
        XCTAssertTrue(app.buttons["pdfPeek.close"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(paragraph.frame.minY, originalY, accuracy: 3)
        if app.frame.width > 600 {
            XCTAssertFalse(app.buttons["Paper options"].exists, "Returning keeps the reader in reading mode")
        }
    }

    func testPDFWithoutSearchableTextRemainsBrowsableWithNoClaimedMatch() {
        let (app, paragraph) = openReader(imageOnly: true)
        paragraph.tap(withNumberOfTaps: 1, numberOfTouches: 2)
        let status = app.staticTexts["pdfPeek.status"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            status.exists && status.label.localizedCaseInsensitiveContains("no searchable text")
        }, object: nil)], timeout: 10), .completed)
        XCTAssertTrue(app.descendants(matching: .any)["pdfPeek.document"].exists)
        XCTAssertFalse(status.label.contains("Estimated"))
        app.buttons["pdfPeek.close"].tap()
        XCTAssertTrue(app.buttons["paper.showInPDF"].waitForExistence(timeout: 5))
    }

    func testRotationLargeTextAndBackgroundDismissal() {
        let (app, _) = openReader(largeText: true)
        app.buttons["paper.showInPDF"].tap()
        XCTAssertTrue(app.staticTexts["pdfPeek.status"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["pdfPeek.document"].exists)
        XCTAssertTrue(app.buttons["pdfPeek.close"].isHittable)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["pdfPeek.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["pdfPeek.close"].isHittable)
        let pdf = app.descendants(matching: .any)["pdfPeek.document"].firstMatch
        XCTAssertGreaterThan(pdf.frame.height, app.frame.height * 0.5, "The status must not consume the PDF viewport at large text sizes")
        capture("Full-screen PDF landscape at largest text")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["pdfPeek.close"].waitForNonExistence(timeout: 5), "Backgrounding clears the preview and index")
        XCTAssertTrue(app.buttons["paper.showInPDF"].waitForExistence(timeout: 5))
        app.buttons["paper.showInPDF"].tap()
        XCTAssertTrue(app.staticTexts["pdfPeek.status"].waitForExistence(timeout: 10))
        app.buttons["pdfPeek.close"].tap()
    }
}
