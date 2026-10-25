import XCTest

/// Owner feedback on build 21 (docs/architecture/PERSONALIZED_FEED.md): the Feed opens on For you with the reader's own
/// specific topics as chips (broad categories under More topics), says why each paper is suggested, and its table has
/// Topics and Popularity columns, with a Popularity sort that keeps unknown values last. Scripted For you responses
/// (`--feed-for-you-fixture`): no account, network or provider. Screens are attached, and also written to
/// `GS_SCREENSHOT_DIR` when the runner sets it (`TEST_RUNNER_GS_SCREENSHOT_DIR=…`).
@MainActor
final class FeedForYouTests: XCTestCase {
    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }

    private func launch(layout: String, appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "--library-metadata-fixture", "--feed-fixture", "--feed-for-you-fixture",
                               "--start-tab=feed", "--feed-layout=\(layout)", "-appearance", appearance] + extra
        app.launch()
        return app
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let directory = ProcessInfo.processInfo.environment["GS_SCREENSHOT_DIR"], !directory.isEmpty {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func waitFor(_ message: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) {
        let predicate = NSPredicate { _, _ in condition() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout), .completed, message)
    }

    func testForYouTableTopicsPopularityLight() throws { try forYouTable(appearance: "light") }
    func testForYouTableTopicsPopularityDark() throws { try forYouTable(appearance: "dark") }
    func testForYouListWhyLineLight() throws { try forYouList(appearance: "light") }
    func testForYouListWhyLineDark() throws { try forYouList(appearance: "dark") }

    private func forYouTable(appearance: String) throws {
        // Build 21's columns (Why, since 2026-10-24, has its own test): Popularity beside the title, the why line under it.
        let app = launch(layout: "table", appearance: appearance, extra: ["--feed-columns=popularity,topic,published"])
        let forYou = app.buttons["feed.forYou"]
        XCTAssertTrue(forYou.waitForExistence(timeout: 15), "For you is the first chip")
        XCTAssertTrue(forYou.isSelected, "and the Feed's default")
        for topic in ["RL for reasoning", "Mechanistic interpretability", "Tokenization"] {
            XCTAssertTrue(app.buttons["feed.interest.\(topic)"].exists, "the reader's specific topic \(topic)")
        }
        XCTAssertFalse(app.buttons["feed.topic.cs.LG"].exists, "broad categories are not chips")
        XCTAssertTrue(element(app, "feed.moreTopics").exists, "they are under More topics")
        XCTAssertLessThan(forYou.frame.minX, app.buttons["feed.interest.RL for reasoning"].frame.minX)

        // Rows say why, and read their popularity; unknown is a dash, read as unknown.
        let top = element(app, "feed.table.2610.08448"), unknown = element(app, "feed.table.2610.03543")
        XCTAssertTrue(top.waitForExistence(timeout: 5))
        XCTAssertTrue(top.label.contains("In your tag: byte-level LMs"), top.label)
        XCTAssertTrue(top.label.contains("162 upvotes on Hugging Face Papers"), top.label)
        XCTAssertTrue(unknown.label.contains("Popularity unknown"), unknown.label)
        XCTAssertTrue(element(app, "feed.table.header.popularity").exists, "Popularity is a default column")
        save("feed-foryou-table-\(appearance)")

        // Popularity sorts most upvoted first; the unknown one stays last.
        element(app, "feed.table.header.popularity").tap()
        waitFor("sorted by popularity") { (self.element(app, "feed.table.header.popularity").value as? String) == "Sorted descending" }
        let order = ["2610.08448", "2610.07767", "2610.05030", "2610.09912"].map { element(app, "feed.table.\($0)").frame.minY }
        XCTAssertEqual(order, order.sorted(), "162, 87, 40, 5")
        save("feed-foryou-popularity-sort-\(appearance)")
        // The unknown one is last (eight papers since 2026-10-24: it may be below the window's end).
        let unknownRow = element(app, "feed.table.2610.03543"), lowest = element(app, "feed.table.2610.02119")
        for _ in 0..<3 where !(unknownRow.exists && unknownRow.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertGreaterThan(unknownRow.frame.minY, lowest.frame.minY, "▲ 3, then unknown")

        // Columns: Popularity and Topics are choices with what they show.
        app.buttons["Feed options"].tap()
        let columns = app.buttons["feed.columns"].firstMatch
        XCTAssertTrue(columns.waitForExistence(timeout: 5)); columns.tap()
        XCTAssertTrue(app.switches["feed.columns.popularity"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["feed.columns.topic"].exists)
        XCTAssertTrue(app.switches["feed.columns.why"].exists, "Why (owner, 2026-10-24) is a choice too")
        XCTAssertTrue(app.staticTexts["Why For you suggests it (For you and your topics)"].exists)
        // Popularity says what it shows, or (on a phone, where Why takes the place beside the title) that it scrolls in.
        XCTAssertTrue(app.staticTexts["Upvotes on Hugging Face Papers"].exists || app.staticTexts["Scroll sideways to see it"].exists)
        XCTAssertTrue(app.staticTexts["Topics"].exists)
        save("feed-columns-sheet-\(appearance)")
        app.buttons["feed.columns.done"].tap()

        // A topic chip shows that topic's papers, ranked for the reader.
        app.buttons["feed.interest.Tokenization"].tap()
        waitFor("Tokenization selected") { app.buttons["feed.interest.Tokenization"].isSelected }
        XCTAssertTrue(element(app, "feed.table.2610.08448").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "feed.table.2610.03543").exists)
        XCTAssertFalse(element(app, "feed.table.2610.07767").exists, "papers without the topic are not shown")
        save("feed-topic-chip-\(appearance)")

        // More topics reaches the broad categories, newest first as before.
        element(app, "feed.moreTopics").tap()
        let language = app.buttons["feed.more.cs.CL"].firstMatch
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        save("feed-more-topics-\(appearance)")
        language.tap()
        let chip = app.buttons["feed.topic.cs.CL"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5)); XCTAssertTrue(chip.isSelected)
        XCTAssertTrue(element(app, "feed.table.2610.01234").waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, "feed.table.header.published").value as? String, "Sorted descending", "categories stay newest first")
        app.buttons["feed.forYou"].tap()
        waitFor("back to For you") { app.buttons["feed.forYou"].isSelected && !app.buttons["feed.topic.cs.CL"].exists }
    }

    private func forYouList(appearance: String) throws {
        let app = launch(layout: "list", appearance: appearance)
        XCTAssertTrue(app.buttons["feed.forYou"].waitForExistence(timeout: 15))
        let row = element(app, "discover.result.2610.07767")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Because you added “DeepSeekMath”")).firstMatch.exists,
                      "the why line")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Policy optimization")).firstMatch.exists,
                      "specific topics in the details line")
        save("feed-foryou-list-\(appearance)")
    }

    // MARK: Grouped by why (owner, 2026-10-24: "Let's try having a column in Table for the reason and having grouped lists
    // in list view"); the List's group headings went after TestFlight 92 ("Like papers you added not needed")

    func testForYouListInWhyOrderWithoutHeadingsLight() throws { try listInWhyOrder(appearance: "light") }
    func testForYouTableWhyColumnLight() throws { try whyColumn(appearance: "light") }
    func testForYouGroupedSidewaysOnIPad() throws { try groupedSideways() }

    /// A List heading (removed after TestFlight 92): a section's identifier, or a group's name.
    private func anyHeading(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed.section.")).count > 0
            || app.staticTexts.matching(NSPredicate(format: "label IN %@", ["Like papers you added", "From authors you read",
                "Popular this week", "By category", "Something different", "Your tags", "More for you"])).count > 0
    }

    private func flip(_ toggle: XCUIElement) {
        let before = toggle.value as? String
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        if toggle.value as? String == before { toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap() }
    }

    /// The List keeps the order by why (the reader's tag, papers like theirs, an author, popular, a category, something
    /// different) with no headings: each card says why in the server's whole sentence.
    private func listInWhyOrder(appearance: String) throws {
        let app = launch(layout: "list", appearance: appearance)
        XCTAssertTrue(app.buttons["feed.forYou"].waitForExistence(timeout: 15))
        let first = element(app, "discover.result.2610.08448"), second = element(app, "discover.result.2610.06120")
        let added = element(app, "discover.result.2610.07767")
        XCTAssertTrue(first.waitForExistence(timeout: 5) && second.exists && added.exists)
        XCTAssertFalse(anyHeading(app), "no group headings")
        // Reading order: above, or beside on the same row (an upright iPad lays cards two per row).
        func before(_ a: XCUIElement, _ b: XCUIElement) -> Bool {
            a.frame.minY < b.frame.minY || (a.frame.minY == b.frame.minY && a.frame.minX < b.frame.minX)
        }
        // The tag's second paper moves up after its first; the server's order is kept within each group.
        XCTAssertTrue(before(first, second), "\(first.frame) before \(second.frame)")
        XCTAssertTrue(before(second, added), "the tag's papers, then papers like the reader's")
        // Each card says why in full, the tag included (no heading says it now).
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "In your tag: byte-level LMs")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Because you added “DeepSeekMath”")).firstMatch.exists)
        save("feed-why-list-top-\(appearance)")
        let list = app.collectionViews.firstMatch, explore = element(app, "discover.result.2610.09912")
        let category = element(app, "discover.result.2610.02119")
        for _ in 0..<6 where !(explore.exists && explore.isHittable) { list.swipeUp(velocity: .slow) }
        XCTAssertTrue(explore.exists && category.exists)
        XCTAssertTrue(before(category, explore), "Something different comes last")
        XCTAssertFalse(anyHeading(app), "no group headings further down")
        save("feed-why-list-bottom-\(appearance)")

        // A category chip's papers have no reasons, and keep the server's order.
        element(app, "feed.moreTopics").tap()
        let language = app.buttons["feed.more.cs.CL"].firstMatch
        XCTAssertTrue(language.waitForExistence(timeout: 5)); language.tap()
        XCTAssertTrue(element(app, "discover.result.2610.01234").waitForExistence(timeout: 5))
        XCTAssertFalse(anyHeading(app))
    }

    private func whyColumn(appearance: String) throws {
        let app = launch(layout: "table", appearance: appearance)
        XCTAssertTrue(app.buttons["feed.forYou"].waitForExistence(timeout: 15))
        let header = element(app, "feed.table.header.why")
        XCTAssertTrue(header.waitForExistence(timeout: 5), "Why is a default column for For you")
        let top = element(app, "feed.table.2610.08448")
        XCTAssertTrue(top.waitForExistence(timeout: 5))
        XCTAssertEqual(top.label.components(separatedBy: "In your tag: byte-level LMs").count, 2, "said once, by the column: \(top.label)")
        save("feed-why-table-\(appearance)")

        // Sorting by Why groups the rows: the tag's papers, the papers like the reader's, the author, popular, category.
        header.tap()
        waitFor("sorted by why") { (header.value as? String) == "Sorted ascending" }
        let order = ["2610.08448", "2610.06120", "2610.07767", "2610.03543", "2610.05030"].map { element(app, "feed.table.\($0)").frame.minY }
        XCTAssertEqual(order, order.sorted(), "grouped by why, the server's order within")
        save("feed-why-table-sorted-\(appearance)")

        // Hidden, the reason returns to the title's second line.
        app.buttons["Feed options"].tap()
        let columns = app.buttons["feed.columns"].firstMatch
        XCTAssertTrue(columns.waitForExistence(timeout: 5)); columns.tap()
        let why = app.switches["feed.columns.why"]
        XCTAssertTrue(why.waitForExistence(timeout: 5))
        XCTAssertEqual(why.value as? String, "1")
        flip(why)
        waitFor("Why off") { (why.value as? String) == "0" }
        app.buttons["feed.columns.done"].tap()
        waitFor("no Why column") { !header.exists }
        XCTAssertTrue(element(app, "feed.table.2610.08448").label.contains("In your tag: byte-level LMs"), "back in the title's second line")
        app.buttons["Feed options"].tap()
        XCTAssertTrue(columns.waitForExistence(timeout: 5)); columns.tap()
        XCTAssertTrue(why.waitForExistence(timeout: 5))
        flip(why)
        app.buttons["feed.columns.done"].tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5))

        // A category chip has no reasons: no Why column.
        element(app, "feed.moreTopics").tap()
        let language = app.buttons["feed.more.cs.CL"].firstMatch
        XCTAssertTrue(language.waitForExistence(timeout: 5)); language.tap()
        XCTAssertTrue(element(app, "feed.table.2610.01234").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "feed.table.header.why").exists, "no Why column without reasons")
    }

    // MARK: What the reasons mean (owner, TestFlight 91: "If I click on why… maybe have like a little info icon that says
    // what that even means… you press it and then it shows you a pop-up"; "I can't make any sense of that CS AI")

    func testTheWhyColumnExplainsItselfLight() throws { try whyExplained(appearance: "light") }
    func testTheWhyColumnExplainsItselfDark() throws { try whyExplained(appearance: "dark") }
    func testAboutForYouExplainsTheWhyLinesLight() throws { try aboutForYou(appearance: "light") }
    func testAboutForYouExplainsTheWhyLinesDark() throws { try aboutForYou(appearance: "dark") }

    private func whyExplained(appearance: String) throws {
        let app = launch(layout: "table", appearance: appearance)
        XCTAssertTrue(app.buttons["feed.forYou"].waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "feed.table.header.why").waitForExistence(timeout: 5))
        save("feed-why-explained-table-\(appearance)")
        // Popularity says what it counts.
        let upvotes = element(app, "feed.table.header.popularity")
        if upvotes.exists { XCTAssertEqual(upvotes.label, "Upvotes", "the ▲ column is named for what it counts") }
        // The ⓘ beside Why opens a small popover: what each reason means, and the ▲.
        let info = app.buttons["feed.why.info"]
        XCTAssertTrue(info.waitForExistence(timeout: 5), "an ⓘ beside the Why header")
        XCTAssertLessThan(abs(info.frame.midY - element(app, "feed.table.header.why").frame.midY), 12, "in the header row")
        info.tap()
        let text = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Readers are adding")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5), "the popover explains the reasons")
        for words in ["New in", "Hugging Face Papers", "▲", "Your tag", "Explore"] {
            XCTAssertTrue(text.label.contains(words), "it explains \(words): \(text.label)")
        }
        XCTAssertFalse(text.label.contains("cs."), "no arXiv codes")
        sleep(1)
        save("feed-why-explained-popover-\(appearance)")
        // The category row reads its field by name, never its code.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        XCTAssertTrue(text.waitForNonExistence(timeout: 5), "a tap outside closes it")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Category: cs")).firstMatch.exists,
                       "no raw arXiv codes in the Why column")
    }

    /// The List's headings had an ⓘ each; since they went, Feed ⋯ › About For you says what every why line means (owner,
    /// TestFlight 92; JUDGMENT_LOG 30). Offered where papers say why; a category chip's papers don't.
    private func aboutForYou(appearance: String) throws {
        let app = launch(layout: "list", appearance: appearance)
        XCTAssertTrue(element(app, "discover.result.2610.08448").waitForExistence(timeout: 15))
        app.buttons["Feed options"].tap()
        let about = app.buttons["feed.aboutForYou"].firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 5), "Feed ⋯ offers About For you")
        about.tap()
        let text = element(app, "feed.aboutForYou.text")
        XCTAssertTrue(text.waitForExistence(timeout: 5), "a bubble at the ⋯ button")
        for words in ["In your tag", "Because you added", "By …", "Hugging Face Papers", "▲", "New in", "Something different"] {
            XCTAssertTrue(text.label.contains(words), "it explains \(words): \(text.label)")
        }
        XCTAssertFalse(text.label.contains("cs."), "no arXiv codes")
        sleep(1)
        save("feed-about-for-you-\(appearance)")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertTrue(text.waitForNonExistence(timeout: 5), "a tap outside closes it")

        // A category chip's papers say no why: nothing to explain.
        element(app, "feed.moreTopics").tap()
        let language = app.buttons["feed.more.cs.CL"].firstMatch
        XCTAssertTrue(language.waitForExistence(timeout: 5)); language.tap()
        XCTAssertTrue(element(app, "discover.result.2610.01234").waitForExistence(timeout: 5))
        app.buttons["Feed options"].tap()
        XCTAssertTrue(app.buttons["Refresh feed"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["feed.aboutForYou"].exists, "not for a category")
    }

    /// Sideways iPad: the grouped List and the Why table still pick a paper into the abstract pane.
    private func groupedSideways() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Wide on iPad")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for layout in ["list", "table"] {
            let app = launch(layout: layout, appearance: "light")
            waitFor("landscape", timeout: 10) { app.frame.width > app.frame.height }
            XCTAssertTrue(app.buttons["feed.forYou"].waitForExistence(timeout: 15))
            if layout == "list" { XCTAssertTrue(element(app, "discover.result.2610.08448").waitForExistence(timeout: 5)) }
            else { XCTAssertTrue(element(app, "feed.table.header.why").waitForExistence(timeout: 5)) }
            let row = element(app, layout == "list" ? "discover.result.2610.07767" : "feed.table.2610.07767")
            XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
            let title = element(app, "feed.abstract.title")
            XCTAssertTrue(title.waitForExistence(timeout: 5), "the abstract pane")
            XCTAssertEqual(title.label, "Verifier-Guided GRPO Scales Mathematical Reasoning")
            XCTAssertGreaterThan(title.frame.minX, app.frame.width * 0.4, "beside the list")
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Because you added “DeepSeekMath”")).firstMatch.exists,
                          "the pane keeps the whole sentence")
            save("feed-why-ipad-sideways-\(layout)")
            app.terminate()
        }
    }
}
