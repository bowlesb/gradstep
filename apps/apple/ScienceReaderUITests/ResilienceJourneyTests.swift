import XCTest

/// docs/architecture/RESILIENCE.md, "journeys that must stay usable": one failing dependency costs its own feature,
/// with an honest message, never the app. Faults come from Debug-only fixtures: the chat fixture's
/// `throttled|overloaded|stall` modes, the feed and podcast fixture faults, and `--backend-fault=` for backend requests.
@MainActor
final class ResilienceJourneyTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ arguments: [String], waitForSample: Bool = true) -> XCUIApplication {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        if waitForSample { XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 15)) }
        return app
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Resilience · " + name; shot.lifetime = .keepAlways; add(shot)
    }

    private func text(containing value: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    private func ask(_ question: String, in app: XCUIApplication) {
        app.show("chat")
        let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8)); composer.tap(); composer.typeText(question)
        app.buttons["chat.send"].tap()
    }

    /// On iPhone the tab bar steps aside while the keyboard is up: put the keyboard away before leaving chat.
    private func leaveChat(_ app: XCUIApplication, to place: String) {
        if app.keyboards.firstMatch.exists {
            let dismiss = app.buttons["chat.dismissKeyboard"]
            if dismiss.exists { dismiss.tap() } else { app.tables["chat.transcript"].swipeDown() }
            _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
        }
        app.show(place)
    }

    /// Anthropic overloaded: the answer fails with its own message and a retry; the paper and the library are untouched.
    func testAnOverloadedAIServiceFailsTheAnswerOnly() {
        let app = launch(["--chat-fixture", "--chat-fixture-mode=overloaded", "--chat-fixture-consented", "--reset-draft-fixture"])
        app.buttons[sampleID].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), "The paper opens")
        ask("Why is the scaling factor needed?", in: app)
        XCTAssertTrue(text(containing: "The AI service couldn’t finish this answer", in: app).waitForExistence(timeout: 10))
        capture("Chat overloaded")
        leaveChat(app, to: "paper")
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5), "Reading continues")
        app.show("library")
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 5), "The library is untouched")
    }

    /// The server rate limits: the answer says so; nothing else changes.
    func testARateLimitedAnswerSaysToWait() {
        let app = launch(["--chat-fixture", "--chat-fixture-mode=throttled", "--chat-fixture-consented", "--reset-draft-fixture"])
        ask("What is the main result?", in: app)
        XCTAssertTrue(text(containing: "Too many requests right now", in: app).waitForExistence(timeout: 10))
        leaveChat(app, to: "library")
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 5))
    }

    /// Who pays for an early end (2026-10-16): the provider cutting an answer short costs nothing, and says so under the
    /// kept part; the reader's own Stop is charged for the part written.
    func testAnInterruptedAnswerSaysItWasNotCharged() {
        let app = launch(["--chat-fixture", "--chat-fixture-mode=interrupt", "--chat-fixture-consented", "--reset-draft-fixture"])
        ask("What is the main result?", in: app)
        let note = app.descendants(matching: .any)["chat.message.interrupted"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 15))
        XCTAssertEqual(note.label, "Interrupted · not charged")
        capture("Interrupted, not charged")
    }

    func testAStoppedAnswerSaysItWasChargedForThePartWritten() {
        let app = launch(["--chat-fixture", "--chat-fixture-mode=slow", "--chat-fixture-consented", "--reset-draft-fixture"])
        ask("What is the main result?", in: app)
        let stop = app.buttons["chat.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        sleep(2) // some of the answer is written
        stop.tap()
        let note = app.descendants(matching: .any)["chat.message.interrupted"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 15))
        XCTAssertEqual(note.label, "Stopped · charged for the part written")
        capture("Stopped by the reader")
    }

    /// A stream that goes silent ends by itself (the idle deadline) instead of spinning forever.
    func testASilentAnswerEndsAsInterrupted() {
        let app = launch(["--chat-fixture", "--chat-fixture-mode=stall", "--chat-fixture-consented", "--reset-draft-fixture",
                          "--chat-idle-deadline=3"])
        ask("Summarize section 3.", in: app)
        XCTAssertTrue(text(containing: "The connection was interrupted before the answer finished", in: app).waitForExistence(timeout: 15),
                      "The spinner has an end")
        capture("Chat stalled, then ended")
    }

    /// The feed service fails on refresh: the papers already shown stay, said as of then; the library works.
    func testAFailedFeedRefreshKeepsTheLastPage() {
        let app = launch(["--workflow-fixture", "--library-metadata-fixture", "--feed-fixture", "--feed-for-you-fixture", "--feed-fixture-fault"])
        app.show("feed")
        let paper = text(containing: "Verifier-Guided GRPO", in: app)
        XCTAssertTrue(paper.waitForExistence(timeout: 10), "The first page loads")
        // Pull to refresh (the menu's Refresh feed needs a signed-in account; pulling works in any state).
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertTrue(app.staticTexts["feed.stale"].waitForExistence(timeout: 8), "A failed refresh says so")
        XCTAssertTrue(app.staticTexts["feed.stale"].label.contains("Couldn’t refresh. These are the papers from"))
        XCTAssertTrue(text(containing: "Verifier-Guided GRPO", in: app).exists, "…and keeps the papers")
        capture("Feed refresh failed, last page kept")
        app.show("library")
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 5))
    }

    /// Checking for new episodes fails: the episodes already listed stay, said as of then; the library works.
    func testAFailedEpisodeCheckKeepsTheList() {
        let app = launch(["--workflow-fixture", "--feed-fixture", "--podcast-fixture", "--reset-podcast-fixture",
                          "--podcast-fixture-catalog-fault=after-first"])
        app.show("feed")
        let listen = app.buttons["feed.listen"]
        XCTAssertTrue(listen.waitForExistence(timeout: 10)); listen.tap()
        let episode = app.descendants(matching: .any)["podcast.episode.fa000000-0000-4000-8000-000000000001"]
        XCTAssertTrue(episode.waitForExistence(timeout: 10), "The list loads")
        app.buttons["Listen options"].tap()
        let check = app.buttons["Check for new episodes"]
        XCTAssertTrue(check.waitForExistence(timeout: 5)); check.tap()
        XCTAssertTrue(app.staticTexts["podcast.stale"].waitForExistence(timeout: 5), "A failed check says so")
        XCTAssertTrue(episode.exists, "…and keeps the episodes")
        capture("Episode check failed, list kept")
        app.show("library")
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 5))
    }

    /// The episode catalog is down from the start: Listen says so; reading and the library are unaffected.
    func testListenDownLeavesTheRestWorking() {
        let app = launch(["--workflow-fixture", "--feed-fixture", "--podcast-fixture", "--reset-podcast-fixture",
                          "--podcast-fixture-catalog-fault=always"])
        app.show("feed")
        let listen = app.buttons["feed.listen"]
        XCTAssertTrue(listen.waitForExistence(timeout: 10)); listen.tap()
        XCTAssertTrue(app.staticTexts["Episodes unavailable"].waitForExistence(timeout: 10))
        app.show("library")
        app.buttons[sampleID].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), "Reading is unaffected")
    }

    /// Signing in on a new device while Gradstep's key service can't be reached: "couldn't reach Gradstep, trying again",
    /// never the recovery sheet (which would ask for a recovery code the reader doesn't need).
    func testANewDeviceThatCantReachGradstepIsNotSentToRecovery() {
        let app = launch(["--authentication-fixture", "--reset-authentication-fixture", "--backend-fault=rest/v1/rpc/v1_key_state:503"])
        app.show("settings")
        let signIn = app.buttons["account.signIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5)); signIn.tap()
        XCTAssertTrue(app.buttons["auth.emailMethod"].waitForExistence(timeout: 5)); app.buttons["auth.emailMethod"].tap()
        let email = app.textFields["auth.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5)); email.tap(); email.typeText("reader@example.invalid")
        app.buttons["auth.sendCode"].tap()
        let code = app.textFields["auth.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5)); code.tap(); code.typeText("654321")
        app.buttons["auth.verify"].tap()
        let issue = app.staticTexts["account.preparationIssue"]
        let restore = app.staticTexts["Restore your private library"]
        let settled = NSPredicate { _, _ in issue.exists || restore.exists }
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 4)
        XCTAssertFalse(restore.exists, "A connection failure is not a key problem")
        if !issue.exists { app.show("settings") }
        XCTAssertTrue(issue.waitForExistence(timeout: 8))
        XCTAssertTrue(issue.label.contains("Couldn’t reach Gradstep"), issue.label)
        capture("New device, Gradstep unreachable")
    }

    /// Sign-in emails are being refused (Resend or Supabase limit): the wait is said plainly and Apple and Google remain.
    func testEmailCodesLimitedLeaveAppleAndGoogle() {
        let app = launch(["--authentication-fixture", "--reset-authentication-fixture", "--backend-fault=auth/v1/otp:429"])
        app.show("settings")
        let signIn = app.buttons["account.signIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5)); signIn.tap()
        XCTAssertTrue(app.buttons["auth.emailMethod"].waitForExistence(timeout: 5)); app.buttons["auth.emailMethod"].tap()
        let email = app.textFields["auth.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5)); email.tap(); email.typeText("reader@example.invalid")
        app.buttons["auth.sendCode"].tap()
        XCTAssertTrue(app.staticTexts["auth.issue"].waitForExistence(timeout: 8), "The limit is said")
        capture("Email codes limited")
        // The other ways in are one tap away and work without email.
        app.buttons["auth.methods"].tap()
        XCTAssertTrue(app.buttons["auth.google"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["auth.apple"].exists || app.descendants(matching: .any)["auth.apple"].exists, "Sign in with Apple stays offered")
    }
}
