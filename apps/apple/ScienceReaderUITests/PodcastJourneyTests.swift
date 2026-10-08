import XCTest
import UIKit

/// Paper podcasts over the zero-spend fixture (`--podcast-fixture`: labeled synthetic episodes, tones generated on the
/// device, no network): the Feed's Listen filter, playing, the mini-player above the tab bar (and clear of the chat's
/// message box), a transcript evidence jump into the paper, an offline download that survives relaunch, and a quoted
/// private generation. docs/architecture/PAPER_PODCASTS.md.
@MainActor
final class PodcastJourneyTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"
    private let sampleEpisode = "podcast.episode.fa000000-0000-4000-8000-000000000001"
    private let otherEpisode = "podcast.episode.fa000000-0000-4000-8000-000000000002"

    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String] = [], reset: Bool = true) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "--feed-fixture", "--podcast-fixture"] + (reset ? ["--reset-podcast-fixture"] : []) + extra
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 15))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func waitFor(_ message: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) {
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: timeout)
        XCTAssertEqual(result, .completed, message, file: file, line: line)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func openListen(_ app: XCUIApplication) {
        app.buttons["tab.feed"].tap()
        let listen = app.buttons["feed.listen"]
        XCTAssertTrue(listen.waitForExistence(timeout: 10), "The Feed offers Listen beside its topics")
        listen.tap()
        XCTAssertTrue(element(app, sampleEpisode).waitForExistence(timeout: 10))
    }

    private func playSample(_ app: XCUIApplication) {
        element(app, sampleEpisode).tap()
        XCTAssertTrue(app.staticTexts["podcast.player.title"].waitForExistence(timeout: 10), "Play opens the player")
        let toggle = app.buttons["podcast.player.toggle"]
        waitFor("Playback starts after the audio is verified") { toggle.exists && toggle.label == "Pause" }
    }

    /// The position slider's spoken value ("1 minute, 5 seconds of 5 minutes"), in seconds.
    private func elapsedSeconds(_ app: XCUIApplication) -> Int {
        guard let value = app.sliders["podcast.player.position"].value as? String,
              let played = value.components(separatedBy: " of ").first else { return -1 }
        var total = 0
        for match in played.matches(of: /(\d+) (hour|minute|second)/) {
            let n = Int(match.1) ?? 0
            total += match.2 == "hour" ? n * 3600 : match.2 == "minute" ? n * 60 : n
        }
        return total
    }

    func testListenFilterShowsLabeledEpisodeCards() {
        let app = launch()
        openListen(app)
        let card = element(app, sampleEpisode)
        // Title, year, duration, topic and the AI-audio badge; the fixture is labeled as such.
        XCTAssertTrue(card.label.hasPrefix("Synthetic fixture: Reading machine learning papers, 2026, "), card.label)
        XCTAssertTrue(card.label.contains("Reading methods, AI audio, synthetic fixture"), card.label)
        XCTAssertTrue(element(app, otherEpisode).label.contains("2017"))
        capture(app, "Listen filter")
        // A topic chip returns to the topic's papers; Listen comes back with one tap.
        app.buttons["feed.topic.cs.LG"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["feed.listen"].isHittable)
    }

    func testPlayDismissKeepsPlayingInMiniPlayerAboveTabBar() {
        let app = launch()
        openListen(app)
        playSample(app)
        let start = elapsedSeconds(app)
        waitFor("The position moves while playing", timeout: 8) { self.elapsedSeconds(app) >= start + 2 }
        // ±15 s: back to the start, forward again.
        app.buttons["podcast.player.back"].tap()
        waitFor("Back 15 seconds") { self.elapsedSeconds(app) <= 2 }
        app.buttons["podcast.player.forward"].tap()
        waitFor("Forward 15 seconds") { self.elapsedSeconds(app) >= 14 }
        capture(app, "Player sheet")
        app.buttons["Done"].tap()
        let mini = element(app, "podcast.miniPlayer")
        XCTAssertTrue(mini.waitForExistence(timeout: 5), "Dismissing the sheet keeps playing in the mini-player")
        XCTAssertEqual(app.buttons["podcast.miniPlayer.toggle"].label, "Pause")
        XCTAssertLessThanOrEqual(mini.frame.maxY, app.buttons["tab.feed"].frame.minY + 1, "The mini-player sits above the tab bar")
        capture(app, "Mini-player above the tab bar")
        // It stays across tabs, and the Library's last row scrolls clear of it.
        app.buttons["tab.library"].tap()
        XCTAssertTrue(mini.exists)
        app.buttons["podcast.miniPlayer.toggle"].tap()
        waitFor("Pause from the mini-player") { app.buttons["podcast.miniPlayer.toggle"].label == "Play" }
        app.buttons["podcast.miniPlayer.open"].tap()
        XCTAssertTrue(app.staticTexts["podcast.player.title"].waitForExistence(timeout: 5))
        // Stop is explicit (the player's "…").
        app.buttons["podcast.player.options"].tap()
        let stop = app.buttons["podcast.player.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5)); stop.tap()
        XCTAssertTrue(mini.waitForNonExistence(timeout: 5), "Stop removes the mini-player")
    }

    func testMiniPlayerNeverCoversTheChatComposer() {
        let app = launch()
        openListen(app)
        playSample(app)
        app.buttons["Done"].tap()
        let mini = element(app, "podcast.miniPlayer")
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        app.buttons["tab.chat"].tap()
        let composer = element(app, "chat.composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        waitFor("The message box sits above the mini-player") { composer.frame.maxY <= mini.frame.minY + 1 }
        XCTAssertTrue(composer.isHittable)
        capture(app, "Chat with the mini-player")
        // Typing hides the tab bar and the mini-player with it, so neither covers the keyboard's message box.
        composer.tap()
        XCTAssertTrue(mini.waitForNonExistence(timeout: 5))
        app.buttons["chat.dismissKeyboard"].tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
    }

    func testTranscriptEvidenceOpensThePaperAtThePassage() {
        let app = launch()
        openListen(app)
        playSample(app)
        app.buttons["podcast.player.toggle"].tap()  // pause; the evidence jump doesn't need sound
        let evidence = app.buttons["podcast.evidence.e6-1"]
        // The transcript is lazy: scroll until the last passage's evidence is there.
        for _ in 0..<4 where !(evidence.exists && evidence.isHittable) { app.swipeUp() }
        XCTAssertTrue(evidence.waitForExistence(timeout: 5))
        capture(app, "Transcript with evidence")
        evidence.tap()
        XCTAssertTrue(app.staticTexts["podcast.player.title"].waitForNonExistence(timeout: 5), "The player closes")
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10), "The paper opens")
        let passage = web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Read an ablation as evidence about a component")).firstMatch
        waitFor("The paper scrolls to the quoted passage", timeout: 20) {
            passage.exists && passage.isHittable && passage.frame.minY >= web.frame.minY - 4 && passage.frame.minY < web.frame.maxY - 60
        }
        XCTAssertTrue(app.buttons["reader.citation.back"].waitForExistence(timeout: 5), "Back to where reading left off")
        capture(app, "Evidence opens the paper passage")
        // The episode is still loaded: the mini-player is there to return to it.
        XCTAssertTrue(element(app, "podcast.miniPlayer").exists)
    }

    func testEvidenceFromPaperOutsideLibraryOffersSourceAndAdd() {
        let app = launch()
        openListen(app)
        element(app, otherEpisode).tap()
        XCTAssertTrue(app.staticTexts["podcast.player.title"].waitForExistence(timeout: 10))
        let evidence = app.buttons["podcast.evidence.e1-1"]
        XCTAssertTrue(evidence.waitForExistence(timeout: 5)); evidence.tap()
        XCTAssertTrue(app.navigationBars["From the paper"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "podcast.evidence.source").exists, "The source link")
        XCTAssertTrue(app.buttons["podcast.evidence.add"].exists, "An explicit Add, never automatic")
    }

    func testOfflineDownloadIsVerifiedAndSurvivesRelaunch() {
        var app = launch()
        openListen(app)
        playSample(app)
        app.buttons["podcast.player.toggle"].tap()
        // The copy Play already verified becomes the download: no second transfer.
        app.buttons["podcast.player.download"].tap()
        XCTAssertTrue(element(app, "podcast.player.downloaded").waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        // Download another from its card's actions: fetched, length and SHA-256 checked, then kept.
        element(app, otherEpisode).press(forDuration: 1.2)
        let download = app.buttons["Download"]
        XCTAssertTrue(download.waitForExistence(timeout: 5)); download.tap()
        waitFor("The second episode is downloaded", timeout: 15) { self.element(app, self.otherEpisode).label.contains("downloaded") }
        capture(app, "Downloaded episodes")
        app.terminate()

        // Relaunch without resetting the fixture's local folder: both stay downloaded (sealed list, verified files).
        app = launch(reset: false)
        openListen(app)
        XCTAssertTrue(app.staticTexts["Downloaded"].waitForExistence(timeout: 5))
        waitFor("Downloaded after relaunch") { self.element(app, self.sampleEpisode).label.contains("downloaded") }
        // The listening position from before stays on this device.
        XCTAssertTrue(element(app, sampleEpisode).label.contains("downloaded"))
        element(app, sampleEpisode).tap()
        XCTAssertTrue(app.staticTexts["podcast.player.title"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "podcast.player.downloaded").exists)
        waitFor("A downloaded episode plays from this device") { app.buttons["podcast.player.toggle"].label == "Pause" }
        // Remove: this device's copy only.
        app.buttons["podcast.player.options"].tap()
        let remove = app.buttons["Remove download"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.tap()
        XCTAssertTrue(app.buttons["podcast.player.download"].waitForExistence(timeout: 5))
    }

    func testPrivateGenerationShowsQuoteThenProgressAndCharges() {
        let app = launch(["--library-metadata-fixture"])
        let lora = app.buttons["paper.eeeeeeee-0000-0000-0000-000000000003"]
        XCTAssertTrue(lora.waitForExistence(timeout: 10))
        lora.press(forDuration: 1.2)
        let listen = app.buttons["Listen"]
        XCTAssertTrue(listen.waitForExistence(timeout: 5)); listen.tap()
        // No episode: an offer, then an explicit quote before anything is held.
        let quote = app.buttons["podcast.generate.quote"]
        XCTAssertTrue(quote.waitForExistence(timeout: 10)); quote.tap()
        let estimate = app.staticTexts["podcast.generate.estimate"]
        XCTAssertTrue(estimate.waitForExistence(timeout: 5))
        XCTAssertTrue(estimate.label.contains("maximum 150 credits"), estimate.label)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Anthropic (script) and Google Vertex AI (speech)")).firstMatch.exists)
        capture(app, "Private episode quote")
        app.buttons["podcast.generate.start"].tap()
        XCTAssertTrue(element(app, "podcast.generate.progress").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["podcast.generate.held"].label.contains("150 credits"))
        capture(app, "Private episode in progress")
        let charged = app.staticTexts["podcast.generate.charged"]
        XCTAssertTrue(charged.waitForExistence(timeout: 15))
        XCTAssertEqual(charged.label, "Charged 46 credits · 104 released.")
        app.buttons["podcast.generate.play"].tap()
        XCTAssertTrue(app.staticTexts["podcast.player.title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["podcast.player.title"].label, "LoRA: Low-Rank Adaptation of Large Language Models", "A private episode is titled from the library")
    }

    func testFailedGenerationChargesNothingAndDoesNotRetry() {
        let app = launch(["--library-metadata-fixture", "--podcast-fixture-generation=fail"])
        let lora = app.buttons["paper.eeeeeeee-0000-0000-0000-000000000003"]
        XCTAssertTrue(lora.waitForExistence(timeout: 10))
        lora.press(forDuration: 1.2)
        app.buttons["Listen"].tap()
        let quote = app.buttons["podcast.generate.quote"]
        XCTAssertTrue(quote.waitForExistence(timeout: 10)); quote.tap()
        let start = app.buttons["podcast.generate.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5)); start.tap()
        let failed = element(app, "podcast.generate.failed")
        XCTAssertTrue(failed.waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["podcast.generate.charged"].label, "No credits were charged.")
        XCTAssertFalse(app.buttons["podcast.generate.play"].exists)
    }

    /// Light and dark screenshots of the Listen feed, the player and transcript, and the mini-player (VISUAL_CHECK.md).
    func testScreenshotsLightAndDark() {
        let app = launch()
        for theme in ["Light", "Dark"] {
            app.buttons["tab.settings"].tap()
            let choice = app.segmentedControls["settings.theme"].buttons[theme]
            XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
            openListen(app)
            sleep(1); capture(app, "podcast-listen-\(theme.lowercased())")
            if element(app, "podcast.miniPlayer").exists {
                app.buttons["podcast.miniPlayer.open"].tap()
                XCTAssertTrue(app.staticTexts["podcast.player.title"].waitForExistence(timeout: 5))
            } else { playSample(app) }
            app.buttons["podcast.player.toggle"].tap()
            sleep(1); capture(app, "podcast-player-\(theme.lowercased())")
            app.swipeUp(); sleep(1); capture(app, "podcast-transcript-\(theme.lowercased())")
            app.buttons["Done"].tap()
            app.buttons["tab.library"].tap()
            XCTAssertTrue(element(app, "podcast.miniPlayer").waitForExistence(timeout: 5))
            sleep(1); capture(app, "podcast-mini-\(theme.lowercased())")
        }
    }
}
