import XCTest

/// Settings (owner feedback, build 14 #8/#9) over local fixtures: the Account row and its page, the theme as a visible
/// choice, About with version, data/cost explanation, privacy and acknowledgements. Signing out and deleting for real run against staging
/// (`LiveJourneyTests`) and in `AuthenticationWorkflowTests`.
@MainActor
final class SettingsTests: XCTestCase {
    private let sample = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    override func setUpWithError() throws { continueAfterFailure = false }

    private func openSettings(_ arguments: [String]) -> XCUIApplication {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.buttons[sample].waitForExistence(timeout: 15))
        // The wide iPad layout has no tab bar; Settings is its gear button.
        if app.buttons["tab.settings"].exists { app.show("settings") } else { app.buttons["Settings"].tap() }
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        return app
    }

    private func element(labelContaining text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func attach(_ name: String) {
        let attached = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attached.name = name; attached.lifetime = .keepAlways; add(attached)
    }

    /// Build 57 (owner, 2026-10-16): AI credits and Subscription plan; explanations behind ⓘ; no text-size sliders; Your
    /// assets with Chats and Diagrams; the Admin tools in their own grey section; Privacy says how arXiv is used.
    func testSettingsAreSimplerWithInfoButtonsAndAnAdminSection() {
        let app = openSettings(["--chat-fixture", "--chat-fixture-consented", "--operator-fixture"])
        XCTAssertTrue(app.staticTexts["AI credits"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Each AI answer uses credits based on the question, the conversation, the paper’s length and the answer."].exists,
                       "The explanation is behind ⓘ, not under the section")
        attach("settings-top")
        let info = app.buttons["settings.credits.info"]
        XCTAssertTrue(info.waitForExistence(timeout: 5)); info.tap()
        XCTAssertTrue(element(labelContaining: "Each AI answer uses credits", in: app).waitForExistence(timeout: 5), "ⓘ shows the explanation")
        attach("settings-info-popover")
        // Dismiss the popover.
        #if targetEnvironment(macCatalyst)
        app.typeKey(.escape, modifierFlags: [])
        #else
        app.tap()
        #endif
        if app.descendants(matching: .any)["PopoverDismissRegion"].exists { app.descendants(matching: .any)["PopoverDismissRegion"].tap() }
        XCTAssertFalse(app.staticTexts["Paper text size"].exists || app.staticTexts["Chat text size"].exists, "Text sizes live where you read and chat")
        let chats = app.descendants(matching: .any)["settings.chats"]
        for _ in 0..<4 where !chats.waitForExistence(timeout: 1) { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Your assets"].exists && app.staticTexts["Diagrams"].exists)
        attach("settings-assets")
        // Downloaded papers (owner, build 59): what this device keeps, removable without touching the library.
        let downloads = app.buttons["settings.downloads"]
        XCTAssertTrue(downloads.exists); downloads.tap()
        XCTAssertTrue(app.navigationBars["Downloaded papers"].waitForExistence(timeout: 5))
        attach("settings-downloaded-papers")
        app.navigationBars["Downloaded papers"].buttons.firstMatch.tap()
        let operations = app.descendants(matching: .any)["settings.operations"]
        for _ in 0..<4 where !operations.waitForExistence(timeout: 1) { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Admin"].exists, "Operators see the Admin section")
        attach("settings-admin")
        app.buttons["settings.about"].tap()
        app.buttons["about.privacy"].tap()
        XCTAssertTrue(app.staticTexts["Papers and arXiv"].waitForExistence(timeout: 5) || app.otherElements["Papers and arXiv"].exists)
        XCTAssertTrue(element(labelContaining: "Gradstep’s servers never contact arXiv", in: app).exists)
        attach("settings-privacy-arxiv")
    }

    /// The owner's monitoring is one tap from Settings (docs/architecture/ADMIN_HEALTH.md); readers never see the row.
    func testOperationsDashboardRowIsForOperatorsOnly() {
        var app = openSettings(["--chat-fixture", "--chat-fixture-consented", "--operator-fixture"])
        let row = app.descendants(matching: .any)["settings.operations"]
        // Settings is a few screens tall; the row sits just above About.
        for _ in 0..<5 where !row.waitForExistence(timeout: 1) { app.swipeUp() }
        XCTAssertTrue(row.exists, "An operator sees Operations dashboard")
        XCTAssertTrue(app.staticTexts["Operations dashboard"].exists)
        attach("settings-operations")
        app.terminate()
        app = openSettings(["--chat-fixture", "--chat-fixture-consented"])
        for _ in 0..<5 { app.swipeUp() }
        XCTAssertTrue(app.buttons["settings.about"].exists || app.descendants(matching: .any)["settings.about"].exists, "Scrolled to the bottom")
        XCTAssertFalse(app.descendants(matching: .any)["settings.operations"].exists, "A reader never sees it")
    }

    func testAccountRowOpensAPageWithSyncSignOutAndDelete() {
        let app = openSettings(["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture"])
        let row = app.buttons["account.row"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("draft-fixture@example.invalid"), "The row names the account: \(row.label)")
        // Owner, build 57: how it signs in is "an unnecessary detail" on the row; the Account page still says it.
        XCTAssertFalse(row.label.contains("Signed in with"), "The row says only who and whether synced: \(row.label)")
        XCTAssertFalse(app.buttons["account.signOut"].exists, "Sign out is on the Account page, not Settings")
        XCTAssertFalse(app.buttons["account.delete"].exists, "…and so is Delete account")
        XCTAssertFalse(app.staticTexts["Sync"].exists, "No bare “Sync” row")

        row.tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(labelContaining: "draft-fixture@example.invalid", in: app).exists)
        XCTAssertTrue(element(labelContaining: "Apple", in: app).exists)
        let sync = app.descendants(matching: .any)["account.sync"]
        XCTAssertTrue(sync.exists)
        XCTAssertTrue(["synced", "Not synced yet", "Waiting to sync", "Syncing", "paused"].contains { sync.label.contains($0) }, "Sync in words: \(sync.label)")
        XCTAssertTrue(app.buttons["account.syncNow"].exists && app.buttons["account.signOut"].exists)
        attach("Account page")

        let delete = app.buttons["account.delete"]
        XCTAssertTrue(delete.exists); delete.tap()
        let confirm = app.buttons["account.delete.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "The same Delete account sheet opens")
        XCTAssertFalse(confirm.isEnabled, "Deleting still needs the typed confirmation")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Account"].exists, "Cancel returns to the Account page")
    }

    func testSignedOutSettingsOffersSignIn() {
        let app = openSettings(["--workflow-fixture"])
        XCTAssertTrue(app.buttons["account.signIn"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["account.row"].exists)
    }

    /// Launched with the stored setting "dark" (argument domain, not saved); the only tap chooses Match device, the
    /// default, so no other test inherits a forced theme.
    func testThemeIsAVisibleChoice() {
        let app = openSettings(["--workflow-fixture", "-appearance", "dark"])
        let theme = app.settingsTheme()
        XCTAssertTrue(theme.waitForExistence(timeout: 5))
        XCTAssertEqual(theme.buttons.allElementsBoundByIndex.map(\.label), ["Light", "Dark", "Match device"])
        XCTAssertTrue(theme.buttons["Dark"].isSelected, "The stored setting is shown")
        XCTAssertFalse(app.staticTexts["Appearance"].exists)
        attach("Theme: Dark")
        theme.buttons["Match device"].tap()
        XCTAssertTrue(theme.buttons["Match device"].isSelected, "“system” is Match device")
    }

    func testAboutHoldsVersionPrivacyAndAcknowledgements() {
        let app = openSettings(["--workflow-fixture"])
        XCTAssertFalse(app.buttons["Acknowledgements"].exists, "Not a Settings row any more")
        XCTAssertFalse(app.buttons["Privacy & data"].exists)
        let about = app.buttons["settings.about"]
        for _ in 0..<8 where !(about.exists && about.isHittable) { app.swipeUp() }
        XCTAssertTrue(about.isHittable); about.tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["about.version"].exists)
        XCTAssertTrue(app.buttons["about.howGradstepWorks"].exists)
        XCTAssertTrue(app.buttons["about.privacy"].exists)
        app.buttons["about.howGradstepWorks"].tap()
        XCTAssertTrue(app.navigationBars["How Gradstep works"].waitForExistence(timeout: 5))
        let credit = element(labelContaining: "A credit is a Gradstep usage unit", in: app)
        for _ in 0..<4 where !credit.exists { app.swipeUp() }   // a lazy list: below a phone's first screen
        XCTAssertTrue(credit.exists)
        // arXiv's required acknowledgement (docs/architecture/ARXIV_DEVICE_ONLY.md §7), at the page's end.
        let thanks = element(labelContaining: "Thank you to arXiv for use of its open access interoperability", in: app)
        for _ in 0..<6 where !thanks.exists { app.swipeUp() }
        XCTAssertTrue(thanks.exists, "How Gradstep works carries arXiv's acknowledgement")
        app.navigationBars["How Gradstep works"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["About"].exists)
        app.buttons["about.acknowledgements"].tap()
        XCTAssertTrue(app.navigationBars["Acknowledgements"].waitForExistence(timeout: 5))
        // The reader's own components since the device-only cutover (no Mathpix on a server), and arXiv's acknowledgement.
        XCTAssertTrue(element(labelContaining: "arXiv HTML for the reader on this device", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element(labelContaining: "Mathpix", in: app).exists, "Nothing converts papers on a server")
        XCTAssertFalse(element(labelContaining: "equation-aware readers", in: app).exists, "No “reader” jargon")
        // Search and the Feed's data since the owner's decisions of 2026-10-16: DataCite, no OpenAlex.
        XCTAssertTrue(element(labelContaining: "ML paper search and the shared Feed", in: app).exists)
        XCTAssertFalse(element(labelContaining: "OpenAlex", in: app).exists, "Search no longer uses OpenAlex")
        let acknowledgement = app.descendants(matching: .any)["acknowledgements.arxiv"]
        for _ in 0..<4 where !acknowledgement.exists { app.swipeUp() }
        XCTAssertTrue(element(labelContaining: "Thank you to arXiv", in: app).exists, "arXiv's acknowledgement")
    }
}
