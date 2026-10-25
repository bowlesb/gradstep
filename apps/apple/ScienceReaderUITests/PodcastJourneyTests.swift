import XCTest
import UIKit

/// Paper podcasts over the zero-spend fixture (`--podcast-fixture`: labeled synthetic episodes, tones generated on the
/// device, no network): the Feed's Listen filter, playing, the mini-player above the tab bar (and clear of the chat's
/// message box), a transcript evidence jump into the paper, an offline download that survives relaunch, and a quoted
/// private episode asked for in one step, made while the reader is elsewhere, and waiting in Listen.
/// docs/architecture/PAPER_PODCASTS.md.
@MainActor
final class PodcastJourneyTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"
    private let sampleEpisode = "podcast.episode.fa000000-0000-4000-8000-000000000001"
    private let otherEpisode = "podcast.episode.fa000000-0000-4000-8000-000000000002"

    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String] = [], reset: Bool = true) -> XCUIApplication {
        XCUIDevice.shared.portraitWhereSupported()
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
        if app.buttons["tab.feed"].exists {
            XCTAssertLessThanOrEqual(mini.frame.maxY, app.buttons["tab.feed"].frame.minY + 1, "The mini-player sits above the tab bar")
        } else {
            // The wide layout docks it along the bottom, below every pane (RootView.wideLayout).
            XCTAssertGreaterThan(mini.frame.minY, app.windows.firstMatch.frame.maxY - 140, "The mini-player is docked along the bottom")
        }
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
        // Typing hides the tab bar and the mini-player with it, so neither covers the keyboard's message box. The wide
        // layout has no tab bar: the docked mini-player stays below the panes, clear of the message box.
        let narrow = app.buttons["tab.chat"].exists
        composer.tap()
        if narrow { XCTAssertTrue(mini.waitForNonExistence(timeout: 5)) }
        else { waitFor("The docked mini-player stays clear of the message box while typing") { !mini.exists || composer.frame.maxY <= mini.frame.minY + 1 } }
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
        // Read on a little: a jump made from the very top offers no Back (owner, build 44: nothing to go back to).
        app.webViews.firstMatch.swipeUp()
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

    private let lora = "paper.eeeeeeee-0000-0000-0000-000000000003"
    private let loraTitle = "LoRA: Low-Rank Adaptation of Large Language Models"

    /// The library's LoRA paper → Listen: the sheet asks, with five minutes and the default writer chosen.
    private func askForLoRA(_ app: XCUIApplication) {
        let paper = app.buttons[lora]
        XCTAssertTrue(paper.waitForExistence(timeout: 10))
        #if targetEnvironment(macCatalyst)
        // The Mac's context menu: a secondary click, its items are menu items.
        paper.rightClick()
        let listen = app.windows.menuItems["Listen"].firstMatch
        XCTAssertTrue(listen.waitForExistence(timeout: 5)); listen.click()
        #else
        paper.press(forDuration: 1.2)
        let listen = app.buttons["Listen"]
        XCTAssertTrue(listen.waitForExistence(timeout: 5)); listen.tap()
        #endif
    }

    private func price(_ app: XCUIApplication) -> XCUIElement { app.staticTexts["podcast.generate.price"] }
    private func makeEpisode(_ app: XCUIApplication) -> XCUIElement { app.buttons["podcast.generate.start"] }

    /// Owner, 2026-10-16: "you ask for, it doesnt matter if you leave the page or app, its there for you". One action
    /// with the length and writer preselected and the price said once; then one calm state, no stages; leave; Listen
    /// shows it being made, then ready with New, and a small notice offers Play.
    func testAskThenLeaveAndTheEpisodeIsWaitingInListen() {
        let app = launch(["--library-metadata-fixture", "--podcast-fixture-steps=24"])
        askForLoRA(app)
        let start = makeEpisode(app)
        waitFor("Five minutes is priced at once and Make an episode is ready", timeout: 10) { start.exists && start.isEnabled }
        XCTAssertTrue(price(app).label.hasPrefix("Up to 150 credits."), price(app).label)
        XCTAssertTrue(element(app, "podcast.length.podcast-5min-v1").isSelected, "five minutes by default")
        XCTAssertTrue(app.segmentedControls["podcast.writer"].buttons["DeepSeek V4 Pro"].isSelected, "the default writer")
        let privacy = app.staticTexts["podcast.generate.privacy"]
        XCTAssertTrue(privacy.label.contains("sent to DeepSeek and Google and deleted once the episode is made"), privacy.label)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "source")).count, 0, "No “source” wording")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "(script)")).count, 0, "No provider jargon")
        XCTAssertTrue(start.isHittable, "Make an episode is pinned at the bottom, not below the fold")
        capture(app, "Asking for an episode")
        start.tap()
        let leave = app.staticTexts["podcast.generate.leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 5))
        XCTAssertEqual(leave.label, "You can leave this screen or the app. It’ll be in Listen when it’s ready.")
        XCTAssertEqual(app.staticTexts["podcast.generate.wait"].label, "Usually ready in a few minutes.")
        for stage in ["Waiting to start", "Writing the script", "Recording the two voices", "Holding up to"] {
            XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", stage)).count, 0, "No stages: \(stage)")
        }
        capture(app, "Making the episode")
        app.buttons["podcast.generate.done"].tap()

        // Listen (in the Feed) shows it being made, under Your episodes.
        app.show("feed")
        app.buttons["feed.listen"].tap()
        let making = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "podcast.request.")).firstMatch
        XCTAssertTrue(making.waitForExistence(timeout: 10), "Listen shows the episode being made")
        XCTAssertTrue(making.label.contains(loraTitle) && making.label.contains("Making your episode"), making.label)
        XCTAssertTrue(app.staticTexts["Your episodes"].exists)
        capture(app, "Listen while it's being made")

        // Leave the app, come back: still there, then ready, marked New, with a small notice (never an alert).
        // (The Mac has no Home button; its window simply stays, and Listen keeps checking.)
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        #endif
        let toast = element(app, "podcast.toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 40), "A small notice says it's ready")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Not a modal alert")
        XCTAssertTrue(app.staticTexts["podcast.toast.message"].label.contains("Your episode of “\(loraTitle)” is ready"))
        XCTAssertTrue(making.waitForNonExistence(timeout: 10))
        let ready = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "podcast.episode.", loraTitle)).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 10), "The episode is in Listen")
        XCTAssertTrue(ready.label.contains("new") && ready.label.contains("private"), ready.label)
        capture(app, "Ready in Listen with a notice")
        app.buttons["podcast.toast.action"].tap()
        XCTAssertTrue(app.staticTexts["podcast.player.title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["podcast.player.title"].label, loraTitle, "A private episode is titled from the library")
        waitFor("The ready episode plays") { app.buttons["podcast.player.toggle"].label == "Pause" }
        app.buttons["Done"].tap()
        waitFor("Played: no longer New") { !ready.label.contains("new") }
    }

    /// Owner, 2026-10-21: "Podcasts is missing from defaults in model settings" and "There should be an explainer saying
    /// some considerations when choosing the default for each category". Settings › AI defaults by activity › Podcasts
    /// lists the writers the server offers (its default first); the chosen one is preselected in Make an episode. Each
    /// activity's ⓘ and the section's ⓘ explain what to weigh. Light and dark screenshots for the visual review.
    func testSettingsChoosesWhoWritesNewEpisodes() {
        for appearance in ["light", "dark"] {
            let app = launch(["--chat-fixture", "--chat-fixture-consented", "-appearance", appearance])
            app.show("settings")
            let row = app.buttons["settings.aiScenario.podcasts"]
            for _ in 0..<10 where !(row.exists && row.isHittable) { app.swipeUp() }
            XCTAssertTrue(row.waitForExistence(timeout: 10), "Podcasts sits with the other activities")
            XCTAssertTrue(app.buttons["settings.aiScenario.figures"].exists)
            waitFor("The row names the server's default writer") { row.label.contains("DeepSeek V4 Pro") }
            let sectionGuide = app.buttons["settings.aiDefaults.guide"]
            XCTAssertTrue(sectionGuide.exists, "The section's ⓘ")
            sectionGuide.tap()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "if credits run low (a cheaper one)")).firstMatch.waitForExistence(timeout: 5))
            capture(app, "Settings AI defaults guide \(appearance)")
            app.otherElements["PopoverDismissRegion"].firstMatch.tap()
            sleep(1) // the ⓘ bubble's dimming fades
            capture(app, "Settings AI defaults by activity \(appearance)")
            row.tap()

            let deepseek = app.buttons["settings.podcastWriter.deepseek"], sonnet = app.buttons["settings.podcastWriter.anthropic"]
            XCTAssertTrue(deepseek.waitForExistence(timeout: 10), "Only the writers the server lists")
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.podcastWriter.")).count, 3, "two writers and Use recommended default")
            XCTAssertTrue(deepseek.isSelected, "the server's default until the reader chooses")
            sonnet.tap()
            waitFor("Sonnet is the default now") { sonnet.isSelected && !deepseek.isSelected }
            app.buttons["settings.aiScenario.guide"].tap()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "a long output, so its cost adds up")).firstMatch.waitForExistence(timeout: 5))
            capture(app, "Podcasts default guide \(appearance)")
            app.otherElements["PopoverDismissRegion"].firstMatch.tap()
            sleep(1)
            capture(app, "Podcasts default \(appearance)")
            app.navigationBars["Podcasts"].buttons.firstMatch.tap()
            waitFor("The row names the chosen writer") { row.label.contains("Claude Sonnet 5.5") }
            if appearance == "light" {
                // A chat activity's page has its own ⓘ too.
                app.buttons["settings.aiScenario.equations"].tap()
                app.buttons["settings.aiScenario.guide"].tap()
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "reward careful reasoning")).firstMatch.waitForExistence(timeout: 5))
                capture(app, "Equation explanations guide")
                app.otherElements["PopoverDismissRegion"].firstMatch.tap()
                app.navigationBars["Equation explanations"].buttons.firstMatch.tap()
            }
            // (The Mac's Settings is a window mode with no Done; the app is relaunched below either way.)
            if app.navigationBars["Settings"].buttons["Done"].exists { app.navigationBars["Settings"].buttons["Done"].tap() }

            // Make an episode starts with that writer (the chat fixture has its own library: relaunch on the podcast
            // library, keeping this device's settings).
            app.terminate()
            let library = launch(["--library-metadata-fixture", "-appearance", appearance], reset: false)
            askForLoRA(library)
            let writer = library.segmentedControls["podcast.writer"]
            XCTAssertTrue(writer.waitForExistence(timeout: 10))
            XCTAssertTrue(writer.buttons["Claude Sonnet 5.5"].isSelected, "the default from Settings")
            let start = makeEpisode(library)
            waitFor("Priced with that writer", timeout: 10) { start.exists && start.isEnabled }
            XCTAssertFalse(privacyMentions(library, "DeepSeek"), library.staticTexts["podcast.generate.privacy"].label)
            capture(library, "Make an episode with the Settings default \(appearance)")
            library.terminate()
        }
    }

    private func privacyMentions(_ app: XCUIApplication, _ provider: String) -> Bool {
        let privacy = app.staticTexts["podcast.generate.privacy"]
        return privacy.exists && privacy.label.contains("sent to \(provider)")
    }

    /// Lengths: Short · 5 min · 10 min · 20 min, each with its own maximum; the chosen length is priced as soon as it
    /// is chosen (a quote holds nothing), so Make an episode is the one step.
    func testChoosingTenMinutesPricesItsOwnMaximum() {
        let app = launch(["--library-metadata-fixture"])
        askForLoRA(app)
        let ten = element(app, "podcast.length.podcast-10min-v1")
        XCTAssertTrue(ten.waitForExistence(timeout: 10), "the sheet lists the lengths")
        // DeepSeek's maxima, the default writer (2026-10-14 writer choice; its 20-minute cap is 520).
        for (profile, maximum) in [("podcast-short-v1", 140), ("podcast-5min-v1", 150), ("podcast-10min-v1", 300), ("podcast-20min-v1", 520)] {
            XCTAssertTrue(element(app, "podcast.length.\(profile)").label.contains("up to \(maximum) credits"), "\(profile) shows its own maximum")
        }
        waitFor("Five minutes is priced on opening") { self.price(app).exists && self.price(app).label.hasPrefix("Up to 150 credits") }
        ten.tap()
        XCTAssertTrue(ten.isSelected)
        waitFor("Ten minutes is priced at once") { self.price(app).exists && self.price(app).label.hasPrefix("Up to 300 credits") }
        XCTAssertEqual(app.staticTexts["podcast.generate.lengthLine"].label, "About 10 minutes")
        capture(app, "Ten-minute price")
        // The other writer: its own maximum, priced again.
        app.segmentedControls["podcast.writer"].buttons["Claude Sonnet 5.5"].tap()
        waitFor("Sonnet's ten-minute maximum") { self.price(app).exists && self.price(app).label.hasPrefix("Up to 360 credits") }
        XCTAssertTrue(app.staticTexts["podcast.generate.privacy"].label.contains("sent to Anthropic and Google"))
        element(app, "podcast.length.podcast-short-v1").tap()
        waitFor("Short is priced") { self.price(app).exists && self.price(app).label.hasPrefix("Up to 180 credits") }
        element(app, "podcast.length.podcast-10min-v1").tap()
        let start = makeEpisode(app)
        waitFor("Ten minutes again") { self.price(app).exists && self.price(app).label.hasPrefix("Up to 360 credits") && start.isEnabled }
        start.tap()
        XCTAssertTrue(app.staticTexts["podcast.generate.leave"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["podcast.generate.wait"].label, "This length can take 10 minutes or more.", "What to expect for ten minutes")
    }

    /// With the balance known, lengths whose maximum exceeds it are greyed out with the reason; the affordable chosen
    /// length is still priced at once.
    func testLengthsBeyondTheBalanceAreGreyedOut() {
        let app = launch(["--library-metadata-fixture", "--podcast-fixture-credits=200"])
        askForLoRA(app)
        let ten = element(app, "podcast.length.podcast-10min-v1"), twenty = element(app, "podcast.length.podcast-20min-v1")
        XCTAssertTrue(ten.waitForExistence(timeout: 10))
        XCTAssertFalse(ten.isEnabled, "300 > 200"); XCTAssertFalse(twenty.isEnabled, "520 > 200")
        XCTAssertTrue(ten.label.contains("not enough credits"), ten.label)
        XCTAssertTrue(element(app, "podcast.length.podcast-short-v1").isEnabled)
        XCTAssertTrue(element(app, "podcast.length.podcast-5min-v1").isEnabled)
        waitFor("Five minutes (150) is priced") { self.price(app).exists && self.price(app).label.hasPrefix("Up to 150 credits") }
        XCTAssertTrue(makeEpisode(app).isHittable)
        capture(app, "Lengths beyond the balance")
        element(app, "podcast.length.podcast-short-v1").tap()
        waitFor("Short (140) is priced") { self.price(app).exists && self.price(app).label.hasPrefix("Up to 140 credits") }
    }

    /// An episode that becomes ready after its sheet was closed is offered by name, with Play, in a small notice.
    func testEpisodeReadyAfterTheSheetClosesOffersPlay() {
        let app = launch(["--library-metadata-fixture"])
        askForLoRA(app)
        let start = makeEpisode(app)
        waitFor("Priced", timeout: 10) { start.exists && start.isEnabled }
        start.tap()
        XCTAssertTrue(app.staticTexts["podcast.generate.leave"].waitForExistence(timeout: 5))
        app.buttons["podcast.generate.close"].tap()
        let toast = element(app, "podcast.toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 20), "The ready episode is announced once the sheet is closed")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Not a modal alert")
        XCTAssertTrue(app.staticTexts["podcast.toast.message"].label.contains("Your episode of “\(loraTitle)” is ready"))
        capture(app, "Episode ready while the sheet was closed")
        app.buttons["podcast.toast.action"].tap()
        XCTAssertTrue(app.staticTexts["podcast.player.title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["podcast.player.title"].label, loraTitle)
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
        XCTAssertTrue(five.label.contains("ready"), five.label)
        XCTAssertTrue(element(app, "podcast.length.podcast-10min-v1").isSelected, "the next length still to make is chosen")
        waitFor("The next length is priced at once") { self.price(app).exists && self.price(app).label.hasPrefix("Up to 300 credits") }
        capture(app, "Other lengths")
        five.tap()
        let play = app.buttons["podcast.generate.playReady"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), "a ready length plays instead of being made again")
        XCTAssertFalse(makeEpisode(app).exists, "nothing to make for a ready length")
        play.tap()
        XCTAssertTrue(app.staticTexts["podcast.player.title"].waitForExistence(timeout: 10))
    }

    /// A failure is one plain sentence (no codes) and Try again, in the sheet and in Listen.
    func testFailureSaysSoPlainlyAndOffersTryAgain() {
        let app = launch(["--library-metadata-fixture", "--podcast-fixture-generation=fail"])
        askForLoRA(app)
        let start = makeEpisode(app)
        waitFor("Priced", timeout: 10) { start.exists && start.isEnabled }
        start.tap()
        let failed = app.staticTexts["podcast.generate.failed"]
        XCTAssertTrue(failed.waitForExistence(timeout: 15))
        XCTAssertEqual(failed.label, "We couldn’t make this episode.")
        XCTAssertEqual(app.staticTexts["podcast.generate.charged"].label, "Nothing was charged.")
        XCTAssertFalse(app.buttons["podcast.generate.play"].exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "quality_rejected")).count, 0, "No internal codes")
        capture(app, "Couldn't be made, in the sheet")
        let retry = app.buttons["podcast.generate.retry"]
        XCTAssertTrue(retry.exists); retry.tap()
        waitFor("Try again asks afresh: priced, Make an episode ready") { start.exists && start.isEnabled }
        // The second one fails too; leave it and find it in Listen with Try again.
        start.tap()
        XCTAssertTrue(failed.waitForExistence(timeout: 15))
        app.buttons["podcast.generate.close"].tap()
        app.show("feed")
        app.buttons["feed.listen"].tap()
        let again = app.buttons["podcast.request.retry"]
        XCTAssertTrue(again.waitForExistence(timeout: 10), "Listen shows the episode that couldn't be made")
        XCTAssertTrue(app.staticTexts["Couldn’t make this episode."].exists)
        capture(app, "Couldn't be made, in Listen")
        again.tap()
        waitFor("Try again opens the paper's Listen, priced at the same length", timeout: 10) { start.exists && start.isEnabled }
        XCTAssertTrue(element(app, "podcast.length.podcast-5min-v1").isSelected)
    }

    func testOverlongPaperExplainsBoundaryAndOffersAUsefulRoute() {
        let app = launch(["--library-metadata-fixture", "--podcast-fixture-generation=source-too-large"])
        askForLoRA(app)
        let start = makeEpisode(app)
        waitFor("Priced", timeout: 10) { start.exists && start.isEnabled }
        start.tap()
        let message = app.staticTexts["podcast.generate.sourceTooLarge"]
        XCTAssertTrue(message.waitForExistence(timeout: 15), "The overlong paper gets a plain explanation")
        XCTAssertEqual(message.label, "This paper is too long for an episode.")
        XCTAssertTrue(app.staticTexts["Nothing was charged."].exists)
        XCTAssertTrue(app.buttons["podcast.generate.browseShared"].exists, "The listener can browse already prepared episodes")
        XCTAssertFalse(app.buttons["podcast.generate.retry"].exists, "An impossible request is not presented as a retryable failure")
    }

    func testUnresolvedPreviousOutcomeIsExplainedBeforeAnythingIsHeld() {
        let app = launch(["--library-metadata-fixture", "--podcast-fixture-outcome-pending"])
        askForLoRA(app)
        // The automatic quote is refused: explained at once, with the lengths still offered for another choice.
        let message = app.staticTexts["podcast.generate.error"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertTrue(message.label.hasPrefix("Your previous episode’s charge is still being confirmed."), message.label)
        XCTAssertFalse(makeEpisode(app).exists, "No quote, so nothing to start")
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

    /// Light and dark screenshots of asking, making, Listen while it's made and once it's ready (VISUAL_CHECK.md).
    func testGenerationScreenshotsLightAndDark() {
        for theme in ["Light", "Dark"] {
            let app = launch(["--library-metadata-fixture", "--podcast-fixture-steps=40"])
            app.show("settings")
            let choice = app.settingsTheme().buttons[theme]
            XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
            app.show("library")
            askForLoRA(app)
            let start = makeEpisode(app)
            waitFor("Priced", timeout: 10) { start.exists && start.isEnabled }
            sleep(1); visual("sheet-ask-\(theme.lowercased())")
            start.tap()
            XCTAssertTrue(app.staticTexts["podcast.generate.leave"].waitForExistence(timeout: 5))
            sleep(1); visual("sheet-making-\(theme.lowercased())")
            app.buttons["podcast.generate.done"].tap()
            app.show("feed")
            app.buttons["feed.listen"].tap()
            let making = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "podcast.request.")).firstMatch
            XCTAssertTrue(making.waitForExistence(timeout: 10))
            sleep(1); visual("listen-making-\(theme.lowercased())")
            XCTAssertTrue(element(app, "podcast.toast").waitForExistence(timeout: 60))
            sleep(1); visual("listen-ready-\(theme.lowercased())")
            app.show("settings")
            let match = app.settingsTheme().buttons["System"]
            if match.waitForExistence(timeout: 5) { match.tap() }
            app.terminate()
        }
    }

    /// A named screenshot for the visual check's sheets (`visual__<name>`).
    private func visual(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "visual__\(name)_0_"; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// Light and dark screenshots of the Listen feed, the player and transcript, and the mini-player (VISUAL_CHECK.md).
    func testScreenshotsLightAndDark() {
        let app = launch()
        // The theme is a saved preference: leave it as other suites expect.
        addTeardownBlock { @MainActor in
            if !app.buttons["tab.notes"].exists { return }
            app.show("settings")
            let match = app.settingsTheme().buttons["System"]
            if match.waitForExistence(timeout: 5) { match.tap() }
        }
        for theme in ["Light", "Dark"] {
            app.show("settings")
            let choice = app.settingsTheme().buttons[theme]
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
