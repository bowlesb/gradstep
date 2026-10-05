import XCTest

/// End-to-end journey against hosted staging with a synthetic account created
/// by `scripts/live-journey.mjs`. Skipped unless that runner supplies
/// credentials; it may incur real (budget-capped) provider costs.
final class LiveJourneyTests: XCTestCase {
    private var environment: [String: String] {
        ["SCIENCE_READER_LIVE_JOURNEY_EMAIL": ProcessInfo.processInfo.environment["SCIENCE_READER_LIVE_JOURNEY_EMAIL"] ?? "",
         "SCIENCE_READER_LIVE_JOURNEY_PASSWORD": ProcessInfo.processInfo.environment["SCIENCE_READER_LIVE_JOURNEY_PASSWORD"] ?? ""]
    }
    private var arxivID: String { ProcessInfo.processInfo.environment["SCIENCE_READER_LIVE_JOURNEY_ARXIV"] ?? "2305.18290" }
    private var titlePrefix: String { ProcessInfo.processInfo.environment["SCIENCE_READER_LIVE_JOURNEY_TITLE"] ?? "Direct Preference Optimization" }
    private var question: String? { ProcessInfo.processInfo.environment["SCIENCE_READER_LIVE_JOURNEY_QUESTION"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(environment.values.contains(""), "Live journey credentials are supplied only by scripts/live-journey.mjs")
    }

    private func launch(_ app: XCUIApplication) {
        app.launchEnvironment = environment
        app.launch()
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func paperRow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'paper.' AND label CONTAINS %@", titlePrefix)).firstMatch
    }

    func testAddConvertDownloadReadAskAndRelaunch() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        launch(app)

        // New synthetic account: save the recovery code to finish device setup.
        let saved = app.switches["I saved this code somewhere safe"]
        if saved.waitForExistence(timeout: 30) {
            saved.tap()
            app.buttons["Continue"].tap()
        }
        let library = app.buttons["tab.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 30)); library.tap()
        capture(app, "Signed-in library")

        // Add the paper through the existing Library + flow.
        let add = app.buttons["Add a paper"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        let addEnabled = NSPredicate(format: "isEnabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: addEnabled, object: add)], timeout: 60), .completed)
        add.tap()
        let reference = app.textFields["import.reference"]
        XCTAssertTrue(reference.waitForExistence(timeout: 10)); reference.tap(); reference.typeText(arxivID)
        app.buttons["import.add"].tap()
        capture(app, "Import queued")

        // Conversion runs on the server; refresh until the readable paper appears.
        let row = paperRow(app)
        let deadline = Date().addingTimeInterval(600)
        while !row.exists && Date() < deadline {
            sleep(10)
            let options = app.buttons["Library options"]
            if options.exists { options.tap(); let refresh = app.buttons["Refresh library"]; if refresh.waitForExistence(timeout: 3) { refresh.tap() } }
            let pending = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'import.'")).firstMatch
            if pending.exists, pending.label.contains("Not enough credits") || pending.label.contains("Couldn’t") || pending.label.contains("failed") {
                capture(app, "Import failed"); XCTFail("Import failed: \(pending.label)"); return
            }
        }
        XCTAssertTrue(row.exists, "Converted paper did not appear within ten minutes")
        capture(app, "Converted paper in library")

        // Opening downloads, verifies and installs the reader, then shows it.
        row.tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 120), "Reader did not open after download")
        let heading = web.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Preference")).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 30))
        capture(app, "Downloaded reader")
        app.buttons["Table of contents"].tap()
        sleep(1); capture(app, "Contents"); app.swipeDown()

        if let question {
            app.buttons["tab.chat"].tap()
            let composer = app.textViews["chat.composer"].exists ? app.textViews["chat.composer"] : app.textFields["chat.composer"]
            XCTAssertTrue(composer.waitForExistence(timeout: 10)); composer.tap(); composer.typeText(question)
            app.buttons["chat.send"].tap()
            // First paid request on this account asks for cloud-processing consent.
            let consent = app.buttons["chat.consent.accept"]
            if consent.waitForExistence(timeout: 10) { capture(app, "Consent"); consent.tap() }
            let answered = NSPredicate(format: "count >= 2")
            let messages = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chat.message.text.'"))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: answered, object: messages)], timeout: 180), .completed)
            sleep(5); capture(app, "Answer")
        }

        // Relaunch: the installed reader (and any answer) survive offline storage.
        app.terminate()
        launch(app)
        XCTAssertTrue(app.buttons["tab.library"].waitForExistence(timeout: 30)); app.buttons["tab.library"].tap()
        XCTAssertTrue(paperRow(app).waitForExistence(timeout: 60))
        paperRow(app).tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))
        capture(app, "Reader after relaunch")
        if question != nil {
            app.buttons["tab.chat"].tap()
            let messages = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chat.message.text.'"))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count >= 2"), object: messages)], timeout: 30), .completed)
            capture(app, "Answer after relaunch")
        }
    }
}
