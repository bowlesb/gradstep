import XCTest

/// Your AI usage (owner, 2026-10-22) over local fixtures (`AIUsageFixture.swift`; no network, no paid request): a paper
/// question asked here appears first as "Paper chat" with the paper's title from this device's library; the shared
/// fixture's rows say Stopped, Didn't finish and In progress; a row opens to its parts; an activity chip filters with its
/// totals; more rows load as the list scrolls; the period is in ⋯. Light and dark screenshots (GS_SCREENSHOT_DIR).
@MainActor
final class AIUsageJourneyTests: XCTestCase {
    private let sample = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ appearance: String, _ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture", "-appearance", appearance] + extra
        app.launch()
        XCTAssertTrue(app.buttons[sample].waitForExistence(timeout: 15))
        return app
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let directory = ProcessInfo.processInfo.environment["GS_SCREENSHOT_DIR"], !directory.isEmpty {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }
    private func row(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.buttons["usage.row.14400000-0000-4000-8001-\(id)"] }
    private func rows(_ app: XCUIApplication) -> XCUIElementQuery { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "usage.row.")) }

    private func openUsage(_ app: XCUIApplication) {
        app.show("settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let link = app.buttons["settings.aiUsage"]
        for _ in 0..<4 where !(link.waitForExistence(timeout: 1) && link.isHittable) { app.swipeUp() }
        link.tap()
        XCTAssertTrue(app.navigationBars["Your AI usage"].waitForExistence(timeout: 5))
    }

    private func ask(_ app: XCUIApplication) {
        app.buttons[sample].tap()
        app.show("chat")
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap(); composer.typeText("What is the main idea?")
        if app.buttons["chat.dismissKeyboard"].waitForExistence(timeout: 2) { app.buttons["chat.dismissKeyboard"].tap() }
        app.buttons["chat.send"].tap()
        let answer = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "chat.message.text.", "synthetic fixture answer")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["chat.send"].waitForExistence(timeout: 10), "The answer finished")
    }

    func testUsageListsEachRequestWithItsActivityPaperTokensAndCredits() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            ask(app)
            openUsage(app)
            let totals = app.staticTexts["usage.totals"]
            XCTAssertTrue(totals.waitForExistence(timeout: 10))
            XCTAssertTrue(totals.label.contains("requests"), totals.label)
            // This device's question: named from what it knew, with the title from its own library.
            let mine = rows(app).matching(NSPredicate(format: "label BEGINSWITH %@", "Paper chat, Reading machine learning papers")).firstMatch
            XCTAssertTrue(mine.waitForExistence(timeout: 10), "The question asked here, as a paper chat with its paper")
            XCTAssertTrue(mine.label.contains("3 credits") && mine.label.contains("Claude Sonnet 5.5"), mine.label)
            XCTAssertTrue(row("000000000003", app).label.contains("Stopped") && row("000000000003", app).label.contains("1 credit,"))
            XCTAssertTrue(row("000000000004", app).label.contains("Didn’t finish · not charged"))
            XCTAssertTrue(row("000000000005", app).label.contains("Up to 30") && row("000000000005", app).label.contains("In progress"))
            XCTAssertTrue(row("000000000007", app).label.contains("Tags") && row("000000000007", app).label.contains("Free"))
            save("usage-\(device)-\(appearance)-list")

            // A row opens to its parts.
            let passage = row("000000000001", app)
            for _ in 0..<3 where !passage.isHittable { app.swipeUp() }
            passage.tap()
            XCTAssertEqual(passage.value as? String, "Open")
            let parts = app.descendants(matching: .any)["usage.parts.14400000-0000-4000-8001-000000000001"]
            XCTAssertTrue(parts.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Suggested questions"].exists && app.staticTexts["Chat title"].exists)
            XCTAssertTrue(app.staticTexts["1,000 in · 20,000 cached · 700 out"].exists)
            save("usage-\(device)-\(appearance)-parts")
            app.terminate()
        }
    }

    func testChipsPagesAndPeriod() {
        let app = launch("light")
        openUsage(app)
        let totals = app.staticTexts["usage.totals"]
        XCTAssertTrue(row("00000000000b", app).waitForExistence(timeout: 10))
        // An activity chip and its totals.
        let podcast = app.buttons["usage.chip.podcast"]
        XCTAssertTrue(podcast.waitForExistence(timeout: 5)); podcast.tap()
        let only = row("000000000006", app)
        XCTAssertTrue(only.waitForExistence(timeout: 5))
        XCTAssertEqual(rows(app).count, 1, "Only the podcast")
        XCTAssertTrue(totals.label.hasPrefix("55 credits · 1 request"), totals.label)
        XCTAssertFalse(app.buttons["usage.chip.web_search"].exists, "Only activities in the period")
        save("usage-\(device)-light-chip")
        app.buttons["usage.chip.all"].tap()
        XCTAssertTrue(row("00000000000b", app).waitForExistence(timeout: 5))
        // More rows as the list scrolls: 38 in the fixture, 25 a page.
        let last = app.buttons["usage.row.14400000-0000-4000-8003-000000000029"]
        for _ in 0..<20 where !last.exists { app.swipeUp() }
        XCTAssertTrue(last.waitForExistence(timeout: 5), "The second page loaded")
        // The period, in ⋯ (remembered on the device, so this changes it twice and leaves it at 30 days).
        for (days, words) in [(90, "Last 90 days"), (30, "Last 30 days")] {
            app.buttons["usage.options"].tap()
            let period = app.buttons["usage.period"]
            XCTAssertTrue(period.waitForExistence(timeout: 5)); period.tap()
            let choice = app.buttons["usage.period.\(days)"]
            XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
            // A new period starts at the top of its list, its totals first.
            let heading = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", words)).firstMatch
            XCTAssertTrue(heading.waitForExistence(timeout: 5), words)
            XCTAssertTrue(heading.isHittable, "\(words) is on screen")
        }
        save("usage-\(device)-light-period")
    }

    func testEmptyAndAFailureWithTryAgain() {
        var app = launch("light", ["--usage-fixture-empty"])
        openUsage(app)
        XCTAssertTrue(app.staticTexts["No AI usage in the last 30 days"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["usage.chip.all"].exists)
        app.terminate()
        app = launch("light", ["--usage-fixture-fail-once"])
        openUsage(app)
        let retry = app.buttons["usage.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        save("usage-\(device)-light-failed")
        retry.tap()
        XCTAssertTrue(row("00000000000b", app).waitForExistence(timeout: 10))
    }
}
