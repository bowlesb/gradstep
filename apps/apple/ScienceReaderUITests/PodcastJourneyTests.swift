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
        app.show("feed")
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
        // The Feed's chips are shown, none selected, while Listen is (For you when offered, else the categories).
        let feedChip = app.buttons["feed.forYou"].exists ? app.buttons["feed.forYou"] : app.buttons["feed.topic.cs.LG"]
        XCTAssertTrue(feedChip.exists)
        XCTAssertFalse(feedChip.isSelected, "Listen deselects the Feed's chips")
        XCTAssertTrue(app.buttons["feed.listen"].isSelected)
        feedChip.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["feed.listen"].isHittable)
        XCTAssertFalse(app.buttons["feed.listen"].isSelected)
        // The signed-out fixture can't reload a feed (its header then shows "Feed unavailable" without chips); when the
        // chips are there, the chosen one is selected again.
        if feedChip.exists { XCTAssertTrue(feedChip.isSelected, "The chosen Feed chip is selected again") }
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
        // The transport controls are pinned above the transcript: scrolling the transcript (and follow-along's own
        // scrolling) never moves them away.
        let content = element(app, "podcast.player.content"), controls = element(app, "podcast.player.controls")
        XCTAssertTrue(content.exists); XCTAssertTrue(controls.exists)
        content.swipeUp(); content.swipeUp()
        XCTAssertTrue(app.buttons["podcast.player.toggle"].isHittable, "Play/pause stays in reach while the transcript scrolls")
        XCTAssertTrue(app.sliders["podcast.player.position"].isHittable)
        XCTAssertTrue(app.buttons["podcast.player.back"].isHittable && app.buttons["podcast.player.forward"].isHittable)
        XCTAssertTrue(element(app, "podcast.player.pane").isHittable, "The Transcript/Chapters/About picker stays too")
        XCTAssertLessThanOrEqual(controls.frame.maxY, content.frame.minY + 1, "The controls sit above the scrolling pane")
        capture(app, "Player sheet, transcript scrolled")
        app.buttons["Done"].tap()
        let mini = element(app, "podcast.miniPlayer")
        XCTAssertTrue(mini.waitForExistence(timeout: 5), "Dismissing the sheet keeps playing in the mini-player")
        XCTAssertEqual(app.buttons["podcast.miniPlayer.toggle"].label, "Pause")
        XCTAssertLessThanOrEqual(mini.frame.maxY, app.buttons["tab.feed"].frame.minY + 1, "The mini-player sits above the tab bar")
        capture(app, "Mini-player above the tab bar")
        // It stays across tabs, and the Library's last row scrolls clear of it.
        app.show("library")
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
        app.show("chat")
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
        // Read the paper first (a listener comes from somewhere): this also lets WebKit's first page load on a freshly
        // booted Simulator finish before the timed jump.
        app.buttons[sampleID].tap()
        let firstPass = app.webViews.firstMatch.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A useful first pass identifies")).firstMatch
        XCTAssertTrue(firstPass.waitForExistence(timeout: 60))
        openListen(app)
        playSample(app)
        app.buttons["podcast.player.toggle"].tap()  // pause; the evidence jump doesn't need sound
        let evidence = app.buttons["podcast.evidence.e6-1"]
        // The transcript is lazy: scroll its own pane until the last passage's evidence is there.
        let content = element(app, "podcast.player.content")
        for _ in 0..<4 where !(evidence.exists && evidence.isHittable) { content.swipeUp() }
        XCTAssertTrue(evidence.waitForExistence(timeout: 5))
        capture(app, "Transcript with evidence")
        evidence.tap()
        XCTAssertTrue(app.staticTexts["podcast.player.title"].waitForNonExistence(timeout: 5), "The player closes")
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10), "The paper opens")
        let passage = web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Read an ablation as evidence about a component")).firstMatch
        waitFor("The paper scrolls to the quoted passage", timeout: 30) {
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
        // No episode: the chosen length (five minutes) is quoted at once; nothing is held before Create.
        let estimate = app.staticTexts["podcast.generate.estimate"]
        XCTAssertTrue(estimate.waitForExistence(timeout: 10))
        XCTAssertTrue(estimate.label.contains("maximum 150 credits"), estimate.label)
        XCTAssertFalse(app.buttons["podcast.generate.quote"].exists, "No separate estimate step")
        // The default writer's script provider (DeepSeek since 2026-10-14) and the speech provider are named.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "(script) and Google Vertex AI (speech)")).firstMatch.exists)
        let start = app.buttons["podcast.generate.start"]
        XCTAssertTrue(start.isHittable, "Create is pinned at the bottom, not below the fold")
        XCTAssertTrue(start.label.contains("150 credits"))
        capture(app, "Private episode quote")
        start.tap()
        XCTAssertTrue(element(app, "podcast.generate.progress").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["podcast.generate.held"].label.contains("150 credits"))
        XCTAssertEqual(app.staticTexts["podcast.generate.wait"].label, "Usually ready in a few minutes.", "What to expect for five minutes")
        capture(app, "Private episode in progress")
        let charged = app.staticTexts["podcast.generate.charged"]
        XCTAssertTrue(charged.waitForExistence(timeout: 15))
        XCTAssertEqual(charged.label, "Charged 46 credits · 104 released.")
        app.buttons["podcast.generate.play"].tap()
        XCTAssertTrue(app.staticTexts["podcast.player.title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["podcast.player.title"].label, "LoRA: Low-Rank Adaptation of Large Language Models", "A private episode is titled from the library")
    }

    /// Lengths: Short · 5 min · 10 min · 20 min, each with its own maximum (the serving-limit profiles staging serves);
    /// the chosen length is quoted as soon as it is chosen (a quote holds nothing), so Create is the one confirm step.
    func testChoosingTenMinutesQuotesItsOwnMaximum() {
        let app = launch(["--library-metadata-fixture"])
        let lora = app.buttons["paper.eeeeeeee-0000-0000-0000-000000000003"]
        XCTAssertTrue(lora.waitForExistence(timeout: 10))
        lora.press(forDuration: 1.2)
        let listen = app.buttons["Listen"]
        XCTAssertTrue(listen.waitForExistence(timeout: 5)); listen.tap()
        let ten = element(app, "podcast.length.podcast-10min-v1")
        XCTAssertTrue(ten.waitForExistence(timeout: 10), "the sheet lists the lengths")
        for (profile, maximum) in [("podcast-short-v1", 140), ("podcast-5min-v1", 150), ("podcast-10min-v1", 300), ("podcast-20min-v1", 530)] {
            XCTAssertTrue(element(app, "podcast.length.\(profile)").label.contains("up to \(maximum) credits"), "\(profile) shows its own maximum")
        }
        XCTAssertTrue(element(app, "podcast.length.podcast-5min-v1").isSelected, "five minutes by default")
        let estimate = app.staticTexts["podcast.generate.estimate"]
        waitFor("Five minutes is quoted on opening") { estimate.exists && estimate.label.contains("maximum 150 credits") }
        ten.tap()
        XCTAssertTrue(ten.isSelected)
        waitFor("Ten minutes is quoted at once") { estimate.exists && estimate.label.contains("maximum 300 credits") }
        XCTAssertTrue(app.staticTexts["podcast.generate.quotedLength"].label.hasPrefix("10 min episode"))
        XCTAssertTrue(app.buttons["podcast.generate.start"].label.contains("300 credits"))
        capture(app, "Ten-minute quote")
        // Another length: its own quote at once.
        element(app, "podcast.length.podcast-short-v1").tap()
        waitFor("Short is quoted") { estimate.exists && estimate.label.contains("maximum 140 credits") }
        XCTAssertTrue(app.staticTexts["podcast.generate.quotedLength"].label.hasPrefix("Short episode"))
        element(app, "podcast.length.podcast-10min-v1").tap()
        waitFor("Ten minutes again") { estimate.exists && estimate.label.contains("maximum 300 credits") }
        app.buttons["podcast.generate.start"].tap()
        XCTAssertTrue(element(app, "podcast.generate.progress").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["podcast.generate.held"].label.contains("300 credits"), "the ten-minute hold")
        XCTAssertEqual(app.staticTexts["podcast.generate.wait"].label, "This length can take 10 minutes or more.", "What to expect for ten minutes")
    }

    /// With the balance known, it is shown at the top before any quote, and lengths whose maximum exceeds it are greyed
    /// out with the reason; the affordable chosen length is still quoted at once.
    func testLengthsBeyondTheBalanceAreGreyedOut() {
        let app = launch(["--library-metadata-fixture", "--podcast-fixture-credits=200"])
        let lora = app.buttons["paper.eeeeeeee-0000-0000-0000-000000000003"]
        XCTAssertTrue(lora.waitForExistence(timeout: 10))
        lora.press(forDuration: 1.2)
        let listen = app.buttons["Listen"]
        XCTAssertTrue(listen.waitForExistence(timeout: 5)); listen.tap()
        let available = app.staticTexts["podcast.generate.available"]
        XCTAssertTrue(available.waitForExistence(timeout: 10))
        XCTAssertEqual(available.label, "Available: 200 credits")
        let ten = element(app, "podcast.length.podcast-10min-v1"), twenty = element(app, "podcast.length.podcast-20min-v1")
        XCTAssertFalse(ten.isEnabled, "300 > 200"); XCTAssertFalse(twenty.isEnabled, "530 > 200")
        XCTAssertTrue(ten.label.contains("Not enough credits"), ten.label)
        XCTAssertTrue(element(app, "podcast.length.podcast-short-v1").isEnabled)
        XCTAssertTrue(element(app, "podcast.length.podcast-5min-v1").isEnabled)
        let estimate = app.staticTexts["podcast.generate.estimate"]
        waitFor("Five minutes (150) is quoted") { estimate.exists && estimate.label.contains("maximum 150 credits") }
        XCTAssertTrue(app.buttons["podcast.generate.start"].isHittable)
        capture(app, "Lengths beyond the balance")
        element(app, "podcast.length.podcast-short-v1").tap()
        waitFor("Short (140) is quoted") { estimate.exists && estimate.label.contains("maximum 140 credits") }
    }

    /// An episode that becomes ready after its sheet was closed is offered by name, with Play.
    func testEpisodeReadyAfterTheSheetClosesOffersPlay() {
        let app = launch(["--library-metadata-fixture"])
        let lora = app.buttons["paper.eeeeeeee-0000-0000-0000-000000000003"]
        XCTAssertTrue(lora.waitForExistence(timeout: 10))
        lora.press(forDuration: 1.2)
        let listen = app.buttons["Listen"]
        XCTAssertTrue(listen.waitForExistence(timeout: 5)); listen.tap()
        let start = app.buttons["podcast.generate.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); start.tap()
        XCTAssertTrue(element(app, "podcast.generate.progress").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["podcast.generate.held"].label.contains("you’ll be offered Play in the app when it’s ready"))
        app.buttons["podcast.generate.close"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "The ready episode is announced once the sheet is closed")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Your episode of “LoRA: Low-Rank Adaptation of Large Language Models” is ready")).firstMatch.exists)
        capture(app, "Episode ready while the sheet was closed")
        alert.buttons["Play"].tap()
        XCTAssertTrue(app.staticTexts["podcast.player.title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["podcast.player.title"].label, "LoRA: Low-Rank Adaptation of Large Language Models")
        waitFor("The ready episode plays") { app.buttons["podcast.player.toggle"].label == "Pause" }
    }

    /// The playback speed is a device preference: chosen once, it is the speed the next episode (and the next launch) starts at.
    func testPlaybackSpeedSurvivesRelaunch() {
        var app = launch()
        openListen(app)
        playSample(app)
        let speed = app.buttons["podcast.player.speed"]
        XCTAssertEqual(speed.value as? String, "1×")
        speed.tap()
        let faster = app.buttons["1.5×"]
        XCTAssertTrue(faster.waitForExistence(timeout: 5)); faster.tap()
        waitFor("The speed is 1.5×") { speed.value as? String == "1.5×" }
        app.terminate()
        app = launch(reset: false)
        openListen(app)
        playSample(app)
        XCTAssertEqual(app.buttons["podcast.player.speed"].value as? String, "1.5×", "Restored on the next launch")
        // Leave 1× behind for the next journey (its reset would do the same).
        app.buttons["podcast.player.speed"].tap()
        let normal = app.buttons["1×"]
        XCTAssertTrue(normal.waitForExistence(timeout: 5)); normal.tap()
        waitFor("Back to 1×") { app.buttons["podcast.player.speed"].value as? String == "1×" }
    }

    /// A paper with a ready five-minute episode: Other lengths offers to play it (no credits) or to make another length.
    func testOtherLengthsOffersTheReadyEpisodeOrANewLength() {
        let app = launch()
        openListen(app)
        playSample(app)
        app.buttons["podcast.player.toggle"].tap()
        app.buttons["podcast.player.options"].tap()
        let lengths = app.buttons["podcast.player.lengths"]
        XCTAssertTrue(lengths.waitForExistence(timeout: 5)); lengths.tap()
        let five = element(app, "podcast.length.podcast-5min-v1")
        XCTAssertTrue(five.waitForExistence(timeout: 10))
        XCTAssertTrue(five.label.contains("Ready"), five.label)
        XCTAssertTrue(element(app, "podcast.length.podcast-10min-v1").isSelected, "the next length still to make is chosen")
        let estimate = app.staticTexts["podcast.generate.estimate"]
        waitFor("The next length is quoted at once") { estimate.exists && estimate.label.contains("maximum 300 credits") }
        capture(app, "Other lengths")
        five.tap()
        let play = app.buttons["podcast.generate.playReady"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), "a ready length plays instead of being made again")
        XCTAssertFalse(app.buttons["podcast.generate.start"].exists, "nothing to create for a ready length")
        play.tap()
        XCTAssertTrue(app.staticTexts["podcast.player.title"].waitForExistence(timeout: 10))
    }

    func testFailedGenerationChargesNothingAndDoesNotRetry() {
        let app = launch(["--library-metadata-fixture", "--podcast-fixture-generation=fail"])
        let lora = app.buttons["paper.eeeeeeee-0000-0000-0000-000000000003"]
        XCTAssertTrue(lora.waitForExistence(timeout: 10))
        lora.press(forDuration: 1.2)
        app.buttons["Listen"].tap()
        let start = app.buttons["podcast.generate.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); start.tap()
        let failed = element(app, "podcast.generate.failed")
        XCTAssertTrue(failed.waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["podcast.generate.charged"].label, "No credits were charged.")
        XCTAssertFalse(app.buttons["podcast.generate.play"].exists)
    }

    func testOverlongPaperExplainsBoundaryAndOffersAUsefulRoute() {
        let app = launch(["--library-metadata-fixture", "--podcast-fixture-generation=source-too-large"])
        let lora = app.buttons["paper.eeeeeeee-0000-0000-0000-000000000003"]
        XCTAssertTrue(lora.waitForExistence(timeout: 10))
        lora.press(forDuration: 1.2)
        app.buttons["Listen"].tap()
        let start = app.buttons["podcast.generate.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); start.tap()
        let message = element(app, "podcast.generate.sourceTooLarge")
        XCTAssertTrue(message.waitForExistence(timeout: 15), "The overlong source gets an actionable explanation")
        XCTAssertTrue(message.label.contains("too long for a full-paper episode at any available length"), message.label)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Nothing was charged")).firstMatch.exists)
        XCTAssertTrue(app.buttons["podcast.generate.browseShared"].exists, "The listener can browse already prepared episodes")
        XCTAssertFalse(app.buttons["podcast.generate.retry"].exists, "An impossible request is not presented as a retryable failure")
    }

    func testUnresolvedPreviousOutcomeIsExplainedBeforeAnythingIsHeld() {
        let app = launch(["--library-metadata-fixture", "--podcast-fixture-outcome-pending"])
        let lora = app.buttons["paper.eeeeeeee-0000-0000-0000-000000000003"]
        XCTAssertTrue(lora.waitForExistence(timeout: 10))
        lora.press(forDuration: 1.2)
        app.buttons["Listen"].tap()
        // The automatic quote is refused: explained at once, with the lengths still offered for another choice.
        let message = app.staticTexts["podcast.generate.error"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertTrue(message.label.hasPrefix("Your previous episode’s charge is still being confirmed."), message.label)
        XCTAssertFalse(app.buttons["podcast.generate.start"].exists, "No quote, so nothing to start")
        XCTAssertTrue(element(app, "podcast.length.podcast-short-v1").exists, "Another length can still be chosen")
    }

    /// The iPad's wide layout (no tab bar): the player docks along the bottom, below every pane, so the chat column's
    /// message box stays above it.
    func testWideLayoutDocksThePlayerBelowThePanes() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide iPad layout")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "--feed-fixture", "--podcast-fixture", "--reset-podcast-fixture", "--start-tab=feed",
                               "--podcast-listen", "--podcast-autoplay", "--podcast-autoplay-mini"]
        app.launch()
        let mini = element(app, "podcast.miniPlayer")
        XCTAssertTrue(mini.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(mini.frame.minY, app.windows.firstMatch.frame.maxY - 120, "Docked at the bottom")
        capture(app, "iPad wide layout with the docked player")
        // The Reader (paper beside its chat column), playing.
        app.terminate()
        app.launchArguments = ["--workflow-fixture", "--feed-fixture", "--podcast-fixture", "--reset-podcast-fixture", "--start-tab=chat",
                               "--podcast-autoplay", "--podcast-autoplay-mini"]
        app.launch()
        XCTAssertTrue(mini.waitForExistence(timeout: 20))
        let composer = element(app, "chat.composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        waitFor("The chat column's message box is above the docked player") { composer.frame.maxY <= mini.frame.minY + 1 }
        capture(app, "iPad reader and chat with the docked player")
    }

    /// Light and dark screenshots of the Listen feed, the player and transcript, and the mini-player (VISUAL_CHECK.md).
    func testScreenshotsLightAndDark() {
        let app = launch()
        // The theme is a saved preference: leave it as other suites expect.
        addTeardownBlock { @MainActor in
            if !app.buttons["tab.settings"].exists { return }
            app.show("settings")
            let match = app.segmentedControls["settings.theme"].buttons["Match device"]
            if match.waitForExistence(timeout: 5) { match.tap() }
        }
        for theme in ["Light", "Dark"] {
            app.show("settings")
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
            app.show("library")
            XCTAssertTrue(element(app, "podcast.miniPlayer").waitForExistence(timeout: 5))
            sleep(1); capture(app, "podcast-mini-\(theme.lowercased())")
        }
    }
}
