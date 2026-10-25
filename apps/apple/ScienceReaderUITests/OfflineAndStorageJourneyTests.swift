import XCTest

/// No network and a full disk (docs/reviews/OFFLINE_AND_STORAGE_20261025.md): what is on the device keeps working, each
/// failure is one short line with a way on, nothing spins forever, and nothing is lost or asked twice. Faults are
/// Debug-only fixtures: `--network-offline[=<seconds>]` (every request fails as offline, then the network returns),
/// `--storage-full-fixture[=<seconds>]` (every local save fails as a full disk, then there is room) and
/// `--device-model-download-fixture=fail_once|full`. The Mac's own network stays on. Screenshots are attached and also
/// written to `GS_SCREENSHOT_DIR` when the runner sets it (`TEST_RUNNER_GS_SCREENSHOT_DIR=…`).
@MainActor
final class OfflineAndStorageJourneyTests: XCTestCase {
    private let downloaded = "paper.dddddddd-0000-4000-8000-000000000002"
    private let unprepared = "paper.dddddddd-0000-4000-8000-000000000009"
    private let sample = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ arguments: [String], waitFor row: String) -> XCUIApplication {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.buttons[row].waitForExistence(timeout: 20), "The library opens")
        return app
    }

    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = "Offline and storage · " + name; attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["GS_SCREENSHOT_DIR"], !directory.isEmpty {
            let file = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: file)
        }
    }

    private func text(containing value: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    // MARK: Reading

    /// Cold launch with no network, a paper downloaded earlier: the library and the paper open, with no error.
    func testOfflineLaunchOpensADownloadedPaper() {
        var app = launch(["--offline-reader-fixture", "--reset-offline-reader-fixture", "--network-offline"], waitFor: downloaded)
        app.terminate()
        app = launch(["--offline-reader-fixture", "--network-offline"], waitFor: downloaded)
        app.buttons[downloaded].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), "The downloaded paper reads offline")
        XCTAssertFalse(app.alerts["Gradstep"].exists, "No error for being offline")
        XCTAssertFalse(text(containing: "Couldn’t reach", in: app).exists)
        capture("offline-launch-downloaded-paper")
    }

    /// A paper whose reading isn't on this device, opened offline: "Couldn’t reach arXiv · You’re offline…" with Try
    /// again, never "Read this paper as its PDF" (its PDF needs the network too); Try again ends again, it doesn't spin.
    func testOpeningAPaperThatIsntDownloadedOfflineSaysSoWithTryAgain() {
        let app = launch(["--offline-reader-fixture", "--reset-offline-reader-fixture", "--network-offline", "--offline-reader-unprepared"],
                         waitFor: unprepared)
        app.buttons[unprepared].tap()
        let title = app.staticTexts["Couldn’t reach arXiv"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "The open ends with the network screen")
        XCTAssertTrue(text(containing: "You’re offline. This paper downloads from arXiv when you’re back online", in: app).exists)
        XCTAssertFalse(app.buttons["paper.openPDF"].exists, "No PDF offered: it would need the network too")
        let retry = app.buttons["paper.retryOpen"]
        XCTAssertTrue(retry.exists)
        capture("offline-open-not-downloaded")
        retry.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 15), "Try again ends again (no endless spinner)")
        // The downloaded paper still opens.
        app.show("library")
        app.buttons[downloaded].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
    }

    // MARK: Feed

    /// The Feed's last page is kept on the device across launches (owner, 2026-10-25): with nothing kept, an offline
    /// launch says so; once For you has loaded online, an offline cold start shows the same papers at once with one
    /// quiet line, "Offline · from …", instead of an empty Feed.
    func testAnOfflineLaunchShowsTheFeedsLastPage() {
        let feed = ["--draft-fixture", "--feed-fixture", "--feed-for-you-fixture"]
        var app = launch(feed + ["--reset-draft-fixture", "--network-offline"], waitFor: sample)
        app.show("feed")
        XCTAssertTrue(text(containing: "You’re offline.", in: app).waitForExistence(timeout: 10), "Nothing kept yet: offline says so")
        app.terminate()

        app = launch(feed, waitFor: sample)
        app.show("feed")
        XCTAssertTrue(text(containing: "Verifier-Guided GRPO", in: app).waitForExistence(timeout: 10), "For you loads online")
        XCTAssertFalse(app.descendants(matching: .any)["feed.offline"].exists)
        app.terminate()

        app = launch(feed + ["--network-offline"], waitFor: sample)
        app.show("feed")
        XCTAssertTrue(text(containing: "Verifier-Guided GRPO", in: app).waitForExistence(timeout: 10), "The kept papers, offline")
        let line = app.descendants(matching: .any)["feed.offline"]
        XCTAssertTrue(line.waitForExistence(timeout: 5), "One quiet line says so")
        XCTAssertTrue(line.label.hasPrefix("Offline · from "), line.label)
        XCTAssertFalse(app.staticTexts["Feed unavailable"].exists)
        XCTAssertFalse(app.staticTexts["feed.stale"].exists, "No banner")
        capture("feed-offline-launch-kept-page")
    }

    // MARK: Chat

    private func ask(_ question: String, in app: XCUIApplication) {
        app.show("chat")
        let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8)); composer.tap(); composer.typeText(question)
        app.buttons["chat.send"].tap()
    }

    private func questions(_ question: String, in app: XCUIApplication) -> Int {
        app.tables["chat.transcript"].descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "chat.message.text.", question)).count
    }

    /// Sent offline: the question is kept and the line says so (not "interrupted"); back online, Try again answers it,
    /// and the question is in the conversation once.
    func testAChatSentOfflineIsKeptAndAnsweredOnceBackOnline() {
        let started = Date()
        let app = launch(["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture", "--network-offline=20"], waitFor: sample)
        let question = "Why does the scaling factor matter offline?"
        ask(question, in: app)
        let issue = text(containing: "You’re offline. Your question is saved; try again when you’re connected.", in: app)
        XCTAssertTrue(issue.waitForExistence(timeout: 10), "Said as offline, not as an interrupted answer")
        capture("chat-sent-offline")
        // Back online: the fixture's window ends 20 s after the app started (a little after `started`); a Try again
        // made just before then fails offline again, harmlessly, and is tried once more.
        let wait = 21 - Date().timeIntervalSince(started)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        let answer = text(containing: "This is a synthetic fixture answer", in: app)
        for _ in 0..<6 where !answer.exists {
            app.buttons["chat.retryAnswer"].tap()
            if answer.waitForExistence(timeout: 6) { break }
        }
        XCTAssertTrue(answer.exists, "Answered once online")
        XCTAssertFalse(issue.exists)
        XCTAssertEqual(questions(question, in: app), 1, "The question isn't duplicated by the retry")
        capture("chat-answered-back-online")
    }

    /// A full disk while sending: the line says how much to free, the question stays in the box (nothing lost, nothing
    /// asked); once there is room, Send asks it, once.
    func testAChatOnAFullDiskKeepsTheQuestionAndSendsOnceThereIsRoom() {
        let started = Date()
        let app = launch(["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture", "--storage-full-fixture=25"], waitFor: sample)
        let question = "What does Figure 1 show about memory?"
        ask(question, in: app)
        let alert = app.alerts["Gradstep"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "The save failed and says why")
        XCTAssertTrue(text(containing: "This device is out of space. Free up 120 MB and try again.", in: app).exists)
        capture("chat-disk-full")
        alert.buttons.firstMatch.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue((composer.value as? String ?? "").contains(question), "The question stays in the box: \(String(describing: composer.value))")
        XCTAssertEqual(questions(question, in: app), 0, "Nothing was sent")
        // The fixture's window ends 25 s after the store opened (a little after `started`): a Send just before then is
        // refused again, harmlessly, and is tried once more.
        let wait = 26 - Date().timeIntervalSince(started)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        let answer = text(containing: "This is a synthetic fixture answer", in: app)
        for _ in 0..<6 where !answer.exists {
            app.buttons["chat.send"].tap()
            if answer.waitForExistence(timeout: 6) { break }
            if alert.exists { alert.buttons.firstMatch.tap() }
        }
        XCTAssertTrue(answer.exists, "Sent and answered once there is room")
        XCTAssertEqual(questions(question, in: app), 1)
    }

    // MARK: The on-device model (365 MB)

    private func openModelSetting(_ fixture: String) -> (XCUIApplication, XCUIElement) {
        let app = launch(["--workflow-fixture", "--device-model-download-fixture=\(fixture)"], waitFor: sample)
        app.show("settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let reader = app.switches["settings.deviceModel"]
        for _ in 0..<6 where !(reader.exists && reader.isHittable) { app.swipeUp() }
        XCTAssertTrue(reader.waitForExistence(timeout: 5))
        return (app, reader)
    }

    private func flipAndDownload(_ reader: XCUIElement, in app: XCUIApplication) {
        let control = reader.switches.firstMatch
        if control.exists { control.tap() } else { reader.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }
        let download = app.alerts.buttons["Download"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 5)); download.tap()
    }

    /// The download drops partway: the reason under the row, the switch off; the next try downloads cleanly from the start.
    func testAnInterruptedModelDownloadRestartsCleanly() {
        let (app, reader) = openModelSetting("fail_once")
        flipAndDownload(reader, in: app)
        let note = app.staticTexts["settings.deviceModelNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 15))
        XCTAssertTrue(note.label.contains("The download stopped. Check the connection and try again."), note.label)
        XCTAssertEqual(reader.value as? String, "0")
        capture("model-download-interrupted")
        flipAndDownload(reader, in: app)
        XCTAssertTrue(app.staticTexts["settings.deviceModelProgress"].waitForExistence(timeout: 5), "It starts again")
        let on = expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: reader)
        wait(for: [on], timeout: 15)
        XCTAssertFalse(note.exists, "The failure line goes once it worked")
    }

    /// 200 MB free: refused before any of the 365 MB is fetched, saying how much to free; the switch stays off.
    func testAFullDiskIsSaidBeforeTheModelDownloads() {
        let (app, reader) = openModelSetting("full")
        flipAndDownload(reader, in: app)
        let note = app.staticTexts["settings.deviceModelNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        XCTAssertTrue(note.label.contains("This device is out of space. Free up 583 MB and try again."), note.label)
        XCTAssertFalse(app.staticTexts["settings.deviceModelProgress"].exists, "Nothing was downloaded")
        XCTAssertEqual(reader.value as? String, "0")
        capture("model-download-disk-full")
    }
}
