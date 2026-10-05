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
    private var searchQuery: String? { ProcessInfo.processInfo.environment["SCIENCE_READER_LIVE_JOURNEY_SEARCH"] }
    private var deletesAccount: Bool { ProcessInfo.processInfo.environment["SCIENCE_READER_LIVE_JOURNEY_DELETE"] == "1" }

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

    /// New synthetic account: sign-in and key setup can take a while on a fresh
    /// install. Wait for the recovery sheet (then save the code) or for the
    /// signed-in library; never tap through the sheet.
    private func waitForSignedInAccount(_ app: XCUIApplication) {
        let saved = app.switches["I saved this code somewhere safe"]
        let signedInLibrary = app.buttons["Add a paper"]
        let setupDeadline = Date().addingTimeInterval(120)
        var recovered = false
        while Date() < setupDeadline {
            if saved.exists {
                capture(app, "Recovery code")
                if (saved.value as? String) != "1" { saved.switches.firstMatch.exists ? saved.switches.firstMatch.tap() : saved.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
                let proceed = app.buttons["Continue"]
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: proceed)], timeout: 10), .completed)
                proceed.tap(); recovered = true
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: saved)], timeout: 30), .completed)
                break
            }
            if recovered == false && signedInLibrary.exists && !app.buttons["Sign in to sync"].exists && !app.switches.firstMatch.exists { sleep(3); if !saved.exists { break } }
            sleep(1)
        }
        let library = app.buttons["tab.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 30)); library.tap()
        XCTAssertFalse(app.buttons["Sign in to sync"].exists, "Synthetic account did not stay signed in")
        capture(app, "Signed-in library")
    }

    func testAddConvertDownloadReadAskAndRelaunch() throws {
        try XCTSkipIf(deletesAccount, "This run deletes the account instead")
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        launch(app)
        waitForSignedInAccount(app)

        // Add the paper through the existing Library + flow.
        let add = app.buttons["Add a paper"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        let addEnabled = NSPredicate(format: "isEnabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: addEnabled, object: add)], timeout: 60), .completed)
        if let searchQuery {
            // Discover through the Library's arXiv search and add from results.
            app.segmentedControls.buttons["arXiv"].tap()
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText(searchQuery + "\n")
            let addResult = app.buttons["discover.add.\(arxivID)"]
            XCTAssertTrue(addResult.waitForExistence(timeout: 60), "Search did not return \(arxivID)")
            capture(app, "arXiv search results")
            addResult.tap()
            let added = NSPredicate(format: "exists == false")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: added, object: addResult)], timeout: 30), .completed)
            capture(app, "Added from search")
            app.segmentedControls.buttons["Library"].tap()
        } else {
            add.tap()
            let reference = app.textFields["import.reference"]
            XCTAssertTrue(reference.waitForExistence(timeout: 10)); reference.tap(); reference.typeText(arxivID)
            app.buttons["import.add"].tap()
        }
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
        let titleWord = titlePrefix.split(separator: " ").map(String.init).max(by: { $0.count < $1.count }) ?? titlePrefix
        let heading = web.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", titleWord)).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 30))
        capture(app, "Downloaded reader")
        app.buttons["Table of contents"].tap()
        sleep(1); capture(app, "Contents")
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 5) { done.tap() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: done)], timeout: 10), .completed)

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
        if let question {
            // A relaunch starts a fresh chat; the saved conversation is in history.
            app.buttons["tab.chat"].tap()
            let history = app.buttons["Chat history"]
            XCTAssertTrue(history.waitForExistence(timeout: 10)); history.tap()
            let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", String(question.prefix(20)))).firstMatch
            XCTAssertTrue(saved.waitForExistence(timeout: 30), "Saved conversation missing from history after relaunch"); saved.tap()
            let messages = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chat.message.text.'"))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count >= 2"), object: messages)], timeout: 30), .completed)
            capture(app, "Answer after relaunch")
        }
    }

    /// Settings › Delete account… against staging; the runner checks the server
    /// afterwards. Runs only when the runner asks for it (it ends the account).
    func testDeleteAccountFromSettings() throws {
        try XCTSkipUnless(deletesAccount, "Runs only with scripts/live-journey.mjs --delete")
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        launch(app)
        waitForSignedInAccount(app)
        app.buttons["tab.settings"].tap()
        let delete = app.buttons["account.delete"]
        for _ in 0..<4 where !delete.isHittable { app.swipeUp() }
        XCTAssertTrue(delete.waitForExistence(timeout: 10)); delete.tap()
        let confirm = app.buttons["account.delete.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertFalse(confirm.isEnabled, "Deleting needs the typed confirmation")
        let field = app.textFields["account.delete.confirmation"]
        field.tap(); field.typeText("DELETE")
        XCTAssertTrue(confirm.isEnabled)
        XCTAssertTrue(confirm.isHittable, "The button comes into view above the keyboard")
        capture(app, "Delete account confirmation")
        confirm.tap()
        let notice = app.alerts["Account deleted"]
        XCTAssertTrue(notice.waitForExistence(timeout: 60), "No deletion notice")
        capture(app, "Account deleted")
        notice.buttons["OK"].tap()
        // Signing out returns to the Library, as an ordinary sign-out does.
        XCTAssertTrue(app.buttons["Sign in to sync"].waitForExistence(timeout: 10), "The app should be signed out")
        app.buttons["tab.settings"].tap()
        XCTAssertTrue(app.buttons["account.signIn"].waitForExistence(timeout: 10), "Settings should show the signed-out state")
        capture(app, "Signed out after deletion")
    }
}
