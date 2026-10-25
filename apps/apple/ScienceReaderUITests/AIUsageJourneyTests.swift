import XCTest

/// Your AI usage (owner, 2026-10-22) over local fixtures (`AIUsageFixture.swift`; no network, no paid request): a paper
/// question asked here appears first as "Paper chat" with the paper's title from this device's library; the shared
/// fixture's rows say Stopped, Didn't finish and In progress; a row opens to its parts; the All view's ring of credits by
/// activity, whose legend chooses a chip; an activity chip filters with its totals; more rows load as the list scrolls; Day,
/// Week, Month and Year at the top drive the totals, the ring and the list, which is in days (TestFlight 92); a row's
/// "Open chat" goes back to its conversation. Light and dark screenshots (GS_SCREENSHOT_DIR).
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
    /// A row further down: the list is lazy (the ring and earlier runs' answers can push it below the fold).
    private func revealed(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        let element = row(id, app)
        for _ in 0..<12 where !(element.exists && element.isHittable) { app.swipeUp() }
        return element
    }
    private func rows(_ app: XCUIApplication) -> XCUIElementQuery { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "usage.row.")) }

    private func openUsage(_ app: XCUIApplication) {
        app.show("settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let link = app.buttons["settings.aiUsage"]
        for _ in 0..<4 where !(link.waitForExistence(timeout: 1) && link.isHittable) { app.swipeUp() }
        link.tap()
        XCTAssertTrue(app.navigationBars["Your AI usage"].waitForExistence(timeout: 5))
        // The range is remembered on the device: these journeys read the default month.
        let month = app.segmentedControls["usage.range"].buttons["Month"]
        if month.waitForExistence(timeout: 5), !month.isSelected { month.tap() }
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
            save("usage-\(device)-\(appearance)-list")
            // In list order (newest first), scrolling down only.
            let tags = revealed("000000000007", app)
            XCTAssertTrue(tags.label.contains("Tags") && tags.label.contains("Free"), tags.label)
            let running = revealed("000000000005", app)
            XCTAssertTrue(running.label.contains("Up to 30") && running.label.contains("In progress"), running.label)
            XCTAssertTrue(revealed("000000000004", app).label.contains("Didn’t finish · not charged"))
            let stopped = revealed("000000000003", app)
            XCTAssertTrue(stopped.label.contains("Stopped") && stopped.label.contains("1 credit,"), stopped.label)

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

    func testChipsAndPages() {
        let app = launch("light")
        openUsage(app)
        let totals = app.staticTexts["usage.totals"]
        XCTAssertTrue(row("00000000000b", app).waitForExistence(timeout: 10))
        // Credits by activity, in the All view (owner, build 82): the ring in words, a legend row per named segment.
        let ring = app.descendants(matching: .any)["usage.ring"]
        XCTAssertTrue(ring.waitForExistence(timeout: 5))
        XCTAssertTrue(ring.label.hasPrefix("Credits by activity: ") && ring.label.contains("Podcast 55 credits"), ring.label)
        save("usage-\(device)-light-ring")
        // A legend row chooses its activity's chip, as the chip itself does; a filtered list has no ring.
        let legend = app.buttons["usage.legend.podcast"]
        XCTAssertTrue(legend.exists); legend.tap()
        let podcast = app.buttons["usage.chip.podcast"]
        XCTAssertTrue(podcast.waitForExistence(timeout: 5))
        XCTAssertTrue(podcast.isSelected, "The legend chose the podcast chip")
        let only = row("000000000006", app)
        XCTAssertTrue(only.waitForExistence(timeout: 5))
        XCTAssertEqual(rows(app).count, 1, "Only the podcast")
        XCTAssertTrue(totals.label.hasPrefix("55 credits · 1 request"), totals.label)
        XCTAssertFalse(app.buttons["usage.chip.web_search"].exists, "Only activities in the period")
        XCTAssertFalse(ring.exists, "The ring is the All view's")
        save("usage-\(device)-light-chip")
        app.buttons["usage.chip.all"].tap()
        XCTAssertTrue(row("00000000000b", app).waitForExistence(timeout: 5))
        XCTAssertTrue(ring.waitForExistence(timeout: 5))
        // More rows as the list scrolls: 38 in the fixture, 25 a page.
        let last = app.buttons["usage.row.14400000-0000-4000-8003-000000000029"]
        for _ in 0..<20 where !last.exists { app.swipeUp() }
        XCTAssertTrue(last.waitForExistence(timeout: 5), "The second page loaded")
    }

    /// Day, Week, Month and Year (owner, TestFlight 92: "a view last day, last week, last month"): one control at the top
    /// drives the totals, the ring and the list, which is broken into days, newest first. The fixture's rows: minutes ago,
    /// thirty an hour apart from two hours ago, and two from 4 and 12 days ago. The choice is remembered on the device, so
    /// this ends on Month, the default.
    func testRangeDrivesTotalsRingAndDays() {
        let app = launch("light")
        openUsage(app)
        let range = app.segmentedControls["usage.range"]
        XCTAssertTrue(range.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["usage.period"].exists, "The period is no longer in ⋯")
        let totals = app.staticTexts["usage.totals"]
        XCTAssertTrue(row("00000000000b", app).waitForExistence(timeout: 10))
        let today = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "usage.section.")).firstMatch
        XCTAssertTrue(today.exists, "The list is in days")
        XCTAssertEqual(today.label, "Today")
        /// The range chosen, then its number of requests from the totals line.
        func choose(_ title: String) -> Int {
            // Back to the top, where the control and the totals are (the list is lazy).
            let bar = app.navigationBars["Your AI usage"]
            for _ in 0..<16 where !(range.exists && range.isHittable && totals.exists && range.frame.minY >= bar.frame.maxY - 1) { app.swipeDown() }
            let before = totals.label
            let segment = range.buttons[title]
            segment.tap()
            // A tap while the list still settles can be lost: once more.
            if !segment.isSelected { _ = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: segment)], timeout: 2) }
            if !segment.isSelected { segment.tap() }
            XCTAssertTrue(segment.isSelected, title)
            let changed = NSPredicate(format: "label != %@ AND label != %@", before, "Loading…")
            _ = XCTWaiter.wait(for: [expectation(for: changed, evaluatedWith: totals)], timeout: 5)
            let words = totals.label.components(separatedBy: " · ").first { $0.hasSuffix("requests") } ?? ""
            return Int(words.components(separatedBy: " ").first?.replacingOccurrences(of: ",", with: "") ?? "") ?? -1
        }
        // The last 24 hours: the shared rows and the hourly ones from 2 to 23 or 24 hours ago, not those 25 to 31 hours ago.
        let day = choose("Day")
        XCTAssertTrue(app.descendants(matching: .any)["usage.ring"].waitForExistence(timeout: 5), "The ring follows the range")
        save("usage-\(device)-light-day")
        let last = app.buttons["usage.row.14400000-0000-4000-8003-000000000029"]
        for _ in 0..<14 where !last.exists { app.swipeUp() }
        XCTAssertFalse(last.exists, "31 hours ago is not in the last day")
        // A week has every row but the one from 12 days ago, as days with their headings.
        let week = choose("Week")
        XCTAssertTrue((8...9).contains(week - day), "Day \(day), week \(week)")
        let related = app.buttons["usage.row.14400000-0000-4000-8004-000000000001"]
        for _ in 0..<20 where !related.exists { app.swipeUp() }
        XCTAssertTrue(related.exists, "4 days ago")
        let headings = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "usage.section."))
        XCTAssertGreaterThanOrEqual(headings.count, 1)
        save("usage-\(device)-light-week-days")
        XCTAssertFalse(app.buttons["usage.row.14400000-0000-4000-8004-000000000002"].exists, "12 days ago is not in the week")
        let month = choose("Month")
        XCTAssertEqual(month, week + 1, "12 days ago is in the month")
        XCTAssertTrue(range.buttons["Month"].isSelected)
    }

    /// A row goes back to what it was for (owner, TestFlight 92: "a link here to the original resource in context"): the
    /// question asked here opens its conversation, Settings giving way; a row whose resource isn't here has no link.
    func testARowOpensItsConversation() {
        let app = launch("light")
        ask(app)
        openUsage(app)
        let mine = rows(app).matching(NSPredicate(format: "label BEGINSWITH %@", "Paper chat, Reading machine learning papers")).firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 10))
        let id = mine.identifier.replacingOccurrences(of: "usage.row.", with: "")
        let link = app.buttons["usage.link.\(id)"]
        XCTAssertTrue(link.exists, "Open chat under the row")
        XCTAssertTrue(link.label.hasPrefix("Open chat"), link.label)
        XCTAssertFalse(app.buttons["usage.link.14400000-0000-4000-8001-000000000007"].exists, "Free tags from another device: nothing to open")
        save("usage-\(device)-light-link")
        link.tap()
        XCTAssertTrue(app.navigationBars["Your AI usage"].waitForNonExistence(timeout: 5), "Settings gave way")
        let answer = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "chat.message.text.", "synthetic fixture answer")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "The conversation it was for")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "What is the main idea?")).firstMatch.exists)
        save("usage-\(device)-light-link-opened")
    }

    func testEmptyAndAFailureWithTryAgain() {
        var app = launch("light", ["--usage-fixture-empty"])
        openUsage(app)
        XCTAssertTrue(app.staticTexts["No AI usage in the last 30 days"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["usage.chip.all"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["usage.ring"].exists)
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
