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
    /// `--figure-view`: Contents › Figures › the first figure › Explain, against the staging chat (FIGURE_VIEW.md).
    private var explainsFigure: Bool { ProcessInfo.processInfo.environment["SCIENCE_READER_LIVE_JOURNEY_FIGURE_VIEW"] == "1" }
    private var searchQuery: String? { ProcessInfo.processInfo.environment["SCIENCE_READER_LIVE_JOURNEY_SEARCH"] }
    private var deletesAccount: Bool { ProcessInfo.processInfo.environment["SCIENCE_READER_LIVE_JOURNEY_DELETE"] == "1" }
    private var openTiming: [String] { (ProcessInfo.processInfo.environment["SCIENCE_READER_LIVE_JOURNEY_OPEN_TIMING"] ?? "").split(separator: "|").map(String.init) }
    /// `scripts/live-journey.mjs --store`: Get credits must list every product (no purchase).
    private var checksStore: Bool { ProcessInfo.processInfo.environment["SCIENCE_READER_LIVE_JOURNEY_STORE"] == "1" }
    /// `scripts/live-journey.mjs --reference=11:PaLM`: follow citation 11 and add its paper.
    private var reference: (number: String, title: String)? {
        let parts = (ProcessInfo.processInfo.environment["SCIENCE_READER_LIVE_JOURNEY_REFERENCE"] ?? "").split(separator: ":", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }
    /// `scripts/live-journey.mjs --pdf-only --arxiv=2610.20399 --title=Cortex`: a paper arXiv has no HTML for opens its PDF.
    private var pdfOnly: Bool { ProcessInfo.processInfo.environment["SCIENCE_READER_LIVE_JOURNEY_PDF_ONLY"] == "1" }
    private var runsSomethingElse: Bool { deletesAccount || !openTiming.isEmpty || checksStore || reference != nil || pdfOnly }

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
        // The list's row, or the table's (the phone's Library is a table since 2026-10-15).
        app.buttons.matching(NSPredicate(format: "(identifier BEGINSWITH 'paper.' OR identifier BEGINSWITH 'library.table.paper/') AND label CONTAINS %@", titlePrefix)).firstMatch
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
                XCTAssertTrue(app.buttons["recovery.saveToPasswords"].exists, "The code can be saved to Passwords")
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
        try XCTSkipIf(runsSomethingElse, "This run does something else")
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        launch(app)
        waitForSignedInAccount(app)

        // Add the paper through the existing Library + flow.
        let add = app.buttons["Add a paper"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        let addEnabled = NSPredicate(format: "isEnabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: addEnabled, object: add)], timeout: 60), .completed)
        if let searchQuery {
            // Discover through the Library's ML paper search and add from results.
            app.segmentedControls.buttons["ML paper search"].tap()
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText(searchQuery + "\n")
            let addResult = app.buttons["discover.add.\(arxivID)"]
            XCTAssertTrue(addResult.waitForExistence(timeout: 60), "Search did not return \(arxivID)")
            capture(app, "arXiv search results")
            addResult.tap()
            let added = NSPredicate(format: "exists == false")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: added, object: addResult)], timeout: 30), .completed)
            capture(app, "Added from search")
            app.segmentedControls["wide.mode"].buttons["Library"].tap()
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
        if explainsFigure {
            // The figure view's walkthrough from the app itself: the request the server checks, the sections it relays.
            app.segmentedControls["contents.tabs"].buttons["Figures"].tap()
            let figure = app.buttons["contents.figure.0"]
            XCTAssertTrue(figure.waitForExistence(timeout: 10)); figure.tap()
            let explain = app.buttons["figureView.explain"]
            XCTAssertTrue(explain.waitForExistence(timeout: 10)); explain.tap()
            let consent = app.buttons["chat.consent.accept"]
            if consent.waitForExistence(timeout: 10) { capture(app, "Consent"); consent.tap() }
            let first = app.descendants(matching: .any)["figureView.section.1"]
            XCTAssertTrue(first.waitForExistence(timeout: 120), "The walkthrough's first part")
            XCTAssertFalse(app.descendants(matching: .any)["figureView.failure"].exists)
            sleep(2); capture(app, "Figure walkthrough (live)")
            app.swipeUp(); sleep(1); capture(app, "Figure walkthrough, further down (live)")
            // Back to the figure, then its X closes the sheet (DESIGN.md "Sheet top row").
            app.navigationBars.buttons["BackButton"].firstMatch.tap()
            XCTAssertTrue(explain.waitForExistence(timeout: 10))
            app.buttons["sheet.close"].tap()
        }
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 5) { done.tap() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: done)], timeout: 10), .completed)

        if let question {
            app.show("chat")
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
        XCTAssertTrue(app.buttons["tab.library"].waitForExistence(timeout: 30)); app.show("library")
        XCTAssertTrue(paperRow(app).waitForExistence(timeout: 60))
        paperRow(app).tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))
        capture(app, "Reader after relaunch")
        if let question {
            // A relaunch starts a fresh chat; the saved conversation is in history.
            app.show("chat")
            let history = app.buttons["Chat history"]
            XCTAssertTrue(history.waitForExistence(timeout: 10)); history.tap()
            let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", String(question.prefix(20)))).firstMatch
            XCTAssertTrue(saved.waitForExistence(timeout: 30), "Saved conversation missing from history after relaunch"); saved.tap()
            let messages = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chat.message.text.'"))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count >= 2"), object: messages)], timeout: 30), .completed)
            capture(app, "Answer after relaunch")
        }
    }

    /// Build 57 (2610.20399): arXiv has no HTML for the paper. The screen says so and Open PDF downloads the PDF from
    /// arXiv to this device and shows it, where it used to offer only Try again.
    func testAPaperWithoutArxivHTMLOpensItsPDF() throws {
        try XCTSkipIf(!pdfOnly, "Runs with --pdf-only")
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        launch(app)
        waitForSignedInAccount(app)
        let add = app.buttons["Add a paper"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: add)], timeout: 60), .completed)
        add.tap()
        let field = app.textFields["import.reference"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText(arxivID)
        app.buttons["import.add"].tap()
        let row = paperRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 120), "The added paper did not appear")
        row.tap()
        // One screen for any paper the reader can't show (owner, build 62): its PDF, or the on-device model; no Try again.
        let screen = app.staticTexts["Read this paper as its PDF"]
        XCTAssertTrue(screen.waitForExistence(timeout: 120), "The screen did not offer the paper's PDF")
        XCTAssertTrue(app.staticTexts["arXiv has no web version of this paper."].exists, "The reason, in one line")
        XCTAssertFalse(app.buttons["Try again"].exists, "Trying again can't help a paper arXiv has no HTML for")
        capture(app, "No web version")
        let openPDF = app.buttons["paper.openPDF"]
        XCTAssertTrue(openPDF.exists); openPDF.tap()
        XCTAssertTrue(app.buttons["pdf.contents"].waitForExistence(timeout: 120), "The PDF did not open")
        sleep(2); capture(app, "PDF on this device")
    }

    /// Settings › Delete account… against staging; the runner checks the server
    /// afterwards. Runs only when the runner asks for it (it ends the account).
    func testDeleteAccountFromSettings() throws {
        try XCTSkipUnless(deletesAccount && openTiming.isEmpty && !checksStore && reference == nil, "Runs only with scripts/live-journey.mjs --delete")
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        launch(app)
        waitForSignedInAccount(app)
        app.show("settings")

        // Get credits lists the plans and the pack (App Store sandbox products).
        let getCredits = app.buttons["settings.getCredits"]
        for _ in 0..<3 where !getCredits.isHittable { app.swipeUp() }
        XCTAssertTrue(getCredits.waitForExistence(timeout: 10)); getCredits.tap()
        XCTAssertTrue(app.staticTexts["store.balance"].waitForExistence(timeout: 10))
        _ = app.staticTexts["Pro"].waitForExistence(timeout: 20)
        capture(app, "Get credits")
        // Which products appear depends on App Store Connect (sandbox), so they are recorded, not asserted.
        print("Store products shown:", ["Pro", "Standard", "400 Credits"].filter { app.staticTexts[$0].exists })
        app.buttons["Done"].tap()

        // Settings › Account (the first row) › Delete account… (owner feedback, build 14 #8).
        let account = app.buttons["account.row"]
        for _ in 0..<4 where !(account.exists && account.isHittable) { app.swipeDown() }
        XCTAssertTrue(account.waitForExistence(timeout: 10)); account.tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 10))
        capture(app, "Account page")
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
        app.show("settings")
        XCTAssertTrue(app.buttons["account.signIn"].waitForExistence(timeout: 10), "Settings should show the signed-out state")
        capture(app, "Signed out after deletion")
    }

    /// Settings › Get credits lists every App Store product (no purchase). Catches an app without a
    /// price or products stuck in MISSING_METADATA, which leave the sheet without products. The
    /// API check `store.products` (scripts/workflow-checks.mjs) reads the same states directly.
    func testGetCreditsListsEveryProduct() throws {
        try XCTSkipUnless(checksStore, "Runs only with scripts/live-journey.mjs --store")
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        launch(app)
        waitForSignedInAccount(app)
        app.show("settings")
        let getCredits = app.buttons["settings.getCredits"]
        for _ in 0..<3 where !getCredits.isHittable { app.swipeUp() }
        XCTAssertTrue(getCredits.waitForExistence(timeout: 10)); getCredits.tap()
        XCTAssertTrue(app.staticTexts["store.balance"].waitForExistence(timeout: 15), "The balance shows")
        let expected = ["Pro", "Standard", "400 Credits"]
        let listed = NSPredicate { _, _ in expected.allSatisfy { app.staticTexts[$0].exists } }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: listed, object: nil)], timeout: 30)
        capture(app, "Get credits")
        XCTAssertEqual(result, .completed, "Get credits lists \(expected.filter { app.staticTexts[$0].exists }) of \(expected)")
    }

    /// Reader → a citation → its reference → Add to library: the reader's notice names the paper,
    /// the import appears in the Library and becomes readable. The runner adds the citing paper
    /// first (`--reference=11:PaLM` with the default DPO paper; PaLM is a shared conversion).
    func testReferenceAddToLibraryImportsThePaper() throws {
        guard let reference else { throw XCTSkip("Runs only with scripts/live-journey.mjs --reference=N:Title") }
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        launch(app)
        waitForSignedInAccount(app)
        XCTAssertTrue(paperRow(app).waitForExistence(timeout: 60), "The citing paper is in the library")
        paperRow(app).tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 120), "Reader did not open")
        app.buttons["Table of contents"].tap()
        let introduction = app.buttons["1 Introduction"]
        for _ in 0..<6 { if introduction.waitForExistence(timeout: 2) { break }; app.swipeUp() }
        introduction.tap()
        let citation = web.links["Reference \(reference.number)"].firstMatch
        XCTAssertTrue(citation.waitForExistence(timeout: 15), "Citation \(reference.number) is a link")
        citation.tap()
        let entry = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "[\(reference.number)]")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        let add = app.buttons["Add to library"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "The reference offers Add to library")
        capture(app, "Reference actions")
        add.tap()
        // No chat and no credits: the reader shows the outcome, naming the paper (never silently).
        let outcome = app.staticTexts.matching(NSPredicate(format: "identifier == 'reader.reference.notice' AND (label BEGINSWITH 'Added' OR label CONTAINS 'already in your library')")).firstMatch
        XCTAssertTrue(outcome.waitForExistence(timeout: 30), "Add to library ended without saying what it added")
        XCTAssertTrue(outcome.label.contains(reference.title), "The outcome names \(reference.title): \(outcome.label.suffix(200))")
        capture(app, "Add to library outcome")
        // The import shows in the Library and becomes a readable paper.
        app.show("library")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'paper.' AND label CONTAINS %@", reference.title)).firstMatch
        let deadline = Date().addingTimeInterval(300)
        while !row.exists && Date() < deadline {
            sleep(5)
            let options = app.buttons["Library options"]
            if options.exists { options.tap(); let refresh = app.buttons["Refresh library"]; if refresh.waitForExistence(timeout: 3) { refresh.tap() } }
        }
        XCTAssertTrue(row.exists, "\(reference.title) did not become readable within five minutes")
        capture(app, "Added paper in library")
        row.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 120), "The added paper opens")
        capture(app, "Added paper open")
    }

    /// Opens already-converted papers twice each (first open downloads, the second reads the local
    /// copy) while a test session records the timeline; the runner prints each step's time.
    func testOpenTimingsOfConvertedPapers() throws {
        try XCTSkipIf(openTiming.isEmpty, "Runs only with scripts/live-journey.mjs --open-timing")
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        launch(app)
        waitForSignedInAccount(app)
        app.show("settings")
        let voice = app.switches["session.voice"]
        for _ in 0..<6 where !(voice.exists && voice.isHittable) { app.swipeUp() }
        if (voice.value as? String) == "1" { voice.switches.firstMatch.exists ? voice.switches.firstMatch.tap() : voice.tap() }
        app.buttons["session.start"].tap()
        XCTAssertTrue(app.buttons["session.stop"].waitForExistence(timeout: 20))
        let opening = NSPredicate { _, _ in
            !app.activityIndicators["Opening paper…"].exists && !app.otherElements["paper.openingLocalCopy"].exists
                && app.webViews.firstMatch.exists && app.webViews.firstMatch.staticTexts.count > 3
        }
        for title in openTiming {
            for attempt in ["first", "second"] {
                app.show("library")
                let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'paper.' AND label CONTAINS %@", title)).firstMatch
                XCTAssertTrue(row.waitForExistence(timeout: 30), "\(title) is in the library")
                let started = Date()
                row.tap()
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: opening, object: nil)], timeout: 60), .completed)
                print("OPEN-TIMING \(attempt) \(title): \(String(format: "%.1f", Date().timeIntervalSince(started))) s (UI-observed)")
                capture(app, "\(attempt) open \(title)")
            }
        }
        app.buttons["session.stop"].tap()
        sleep(8) // The runner copies the session out while the app is still installed.
    }
}
