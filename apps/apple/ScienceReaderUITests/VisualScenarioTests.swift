import XCTest

/// Named screens for visual checks (docs/VISUAL_CHECK.md): each scenario puts
/// the app into one deterministic state from fixtures and saves a screenshot
/// named "visual__<scenario>". scripts/visual-check.mjs runs them across devices,
/// dark mode and large text and compares before/after. Runs only when the
/// runner names scenarios.
@MainActor
final class VisualScenarioTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"
    /// The real DPO paper (Mathpix renderer fixture): numbered citations, a bibliography, metadata.
    private let mathpixID = "paper.dddddddd-0000-4000-8000-000000000002"

    struct Scenario {
        let arguments: [String]
        let steps: (XCUIApplication) throws -> Void
    }

    private static let chatFixture = ["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture"]
    private static let metadataFixture = ["--workflow-fixture", "--library-metadata-fixture"]
    private static let feedTableFixture = metadataFixture + ["--feed-fixture", "--feed-layout=table"]
    private static let mathpixFixture = ["--offline-reader-fixture", "--reset-offline-reader-fixture", "--mathpix-reader-fixture"]
    private static let historyFixture = chatFixture + ["--chat-history-fixture"]

    /// The catalogue. Keep steps short and deterministic; wait for the state, never for time alone when avoidable.
    private var scenarios: [String: Scenario] {
        [
            "library": Scenario(arguments: ["--workflow-fixture"]) { _ in },
            "feed": Scenario(arguments: ["--workflow-fixture"]) { app in self.go(app, "feed"); sleep(1) },
            "feed-results": Scenario(arguments: ["--workflow-fixture", "--library-metadata-fixture", "--feed-fixture"]) { app in self.go(app, "feed"); sleep(1) },
            // The Feed as the shared paper table; `feed-table-abstract` opens a row's abstract.
            "feed-table": Scenario(arguments: Self.feedTableFixture) { app in self.go(app, "feed"); sleep(1) },
            "feed-table-abstract": Scenario(arguments: Self.feedTableFixture) { app in
                self.go(app, "feed")
                // At accessibility text sizes the Feed shows its List, which has no row to open.
                let row = app.descendants(matching: .any)["feed.table.2610.01234"]
                if row.waitForExistence(timeout: 5) { row.tap() }
                sleep(1)
            },
            "library-search": Scenario(arguments: ["--workflow-fixture"]) { app in
                let search = app.searchFields.firstMatch
                XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("attention")
                sleep(1)
            },
            // Library layouts (owner decisions 2026-10-05/06) over a varied metadata fixture. The table is the
            // shared paper table at every width (more columns where there is room); `library-table-browse` is
            // the iPad's narrow Browse column.
            "library-table": Scenario(arguments: Self.metadataFixture + ["--library-layout=table"]) { _ in sleep(1) },
            "library-table-browse": Scenario(arguments: Self.metadataFixture + ["--library-layout=table"]) { app in
                if app.segmentedControls.buttons["Browse"].exists { app.segmentedControls.buttons["Browse"].tap() }
                sleep(2)
            },
            "library-metadata-list": Scenario(arguments: Self.metadataFixture) { _ in sleep(1) },
            // The table as the reader sets it up (owner request 2026-10-07): the column chooser, quick filters, the tag
            // menu, a failed import's Retry, and that row right after Retry.
            "library-columns": Scenario(arguments: Self.metadataFixture + ["--library-layout=table"]) { app in
                self.tapMenu(app, "Library options")
                let columns = app.buttons["Columns"].firstMatch
                XCTAssertTrue(columns.waitForExistence(timeout: 5)); columns.tap()
                XCTAssertTrue(app.navigationBars["Columns"].waitForExistence(timeout: 5)); sleep(1)
            },
            "library-filter-failed": Scenario(arguments: Self.metadataFixture + ["--slow-import-fixture", "--library-layout=table",
                                                                                 "--library-filter=failed"]) { _ in sleep(1) },
            "library-filter-tag": Scenario(arguments: Self.metadataFixture + ["--library-layout=table", "--library-tag=Language"]) { _ in sleep(1) },
            "library-tag-menu": Scenario(arguments: Self.metadataFixture + ["--library-layout=table"]) { app in
                let tags = app.descendants(matching: .any)["library.filter.tags"].firstMatch
                // The chip row scrolls sideways; Tags is its last chip.
                if tags.waitForExistence(timeout: 5), !tags.isHittable { app.descendants(matching: .any)["library.filters"].firstMatch.swipeLeft() }
                tags.tap(); sleep(1)
            },
            "library-retry": Scenario(arguments: Self.metadataFixture + ["--slow-import-fixture", "--library-layout=table",
                                                                         "--library-filter=failed"]) { app in
                let retry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.import.retry.")).firstMatch
                XCTAssertTrue(retry.waitForExistence(timeout: 5)); retry.tap(); sleep(1)
            },
            // Every column turned on: the width decides which show.
            "library-table-columns-all": Scenario(arguments: Self.metadataFixture + ["--library-layout=table",
                "--library-columns=year,tags,source,pages,added,opened,chats,progress"]) { _ in sleep(1) },
            // Pipeline reliability: an import whose step has run for minutes says it is taking longer than usual.
            // List layout, and the table.
            "library-slow-import": Scenario(arguments: Self.metadataFixture + ["--slow-import-fixture"]) { app in self.showSlowImport(app) },
            "library-slow-import-table": Scenario(arguments: Self.metadataFixture + ["--slow-import-fixture", "--library-layout=table"]) { app in
                self.showSlowImport(app)
            },
            // Import progress (2026-10-07): imports at every step with percent and time left, one taking longer than
            // usual and one from an older server; `-help` opens "Why does this take a minute?" from a row.
            "library-import-progress": Scenario(arguments: Self.metadataFixture + ["--import-progress-fixture"]) { app in
                XCTAssertTrue(app.descendants(matching: .any)["importProgress"].firstMatch.waitForExistence(timeout: 5)); sleep(1)
            },
            "library-import-progress-help": Scenario(arguments: Self.metadataFixture + ["--import-progress-fixture"]) { app in
                let help = app.buttons["importProgress.help"].firstMatch
                XCTAssertTrue(help.waitForExistence(timeout: 5)); help.tap()
                XCTAssertTrue(app.navigationBars["Getting a paper ready"].waitForExistence(timeout: 5)); sleep(1)
            },
            "library-import-progress-table": Scenario(arguments: Self.metadataFixture + ["--import-progress-fixture", "--library-layout=table"]) { _ in
                sleep(2)
            },
            "library-swipe": Scenario(arguments: Self.metadataFixture) { app in
                let row = app.buttons["paper.eeeeeeee-0000-0000-0000-000000000001"]
                XCTAssertTrue(row.waitForExistence(timeout: 5)); row.swipeLeft(); sleep(1)
            },
            "paper": Scenario(arguments: ["--workflow-fixture"]) { app in self.openSample(app) },
            "paper-contents": Scenario(arguments: ["--workflow-fixture"]) { app in
                self.openSample(app)
                app.buttons["Table of contents"].tap()
                XCTAssertTrue(app.navigationBars["Contents"].waitForExistence(timeout: 5))
            },
            "chat-conversation": Scenario(arguments: ["--workflow-fixture"]) { app in
                self.go(app, "chat")
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch.waitForExistence(timeout: 5))
                sleep(1)
            },
            // Floating chrome (2026-10-07): a conversation scrolled part-way, so messages pass under the header,
            // the message box and the tab bar.
            "chat-scrolled": Scenario(arguments: ["--workflow-fixture"]) { app in
                self.go(app, "chat")
                let transcript = app.tables["chat.transcript"]
                XCTAssertTrue(transcript.waitForExistence(timeout: 5)); sleep(1)
                transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                    .press(forDuration: 0.1, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)),
                           withVelocity: .slow, thenHoldForDuration: 0.3)
                sleep(1)
            },
            "chat-keyboard": Scenario(arguments: ["--workflow-fixture"]) { app in
                self.go(app, "chat")
                let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
                XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5)); sleep(1)
            },
            "chat-answer": Scenario(arguments: Self.chatFixture + ["--chat-fixture-mode=answer"]) { app in
                self.ask(app, "Why scale by the square root of d_k?")
                sleep(3); self.dismissKeyboard(app)
            },
            "chat-diagram": Scenario(arguments: Self.chatFixture + ["--chat-fixture-mode=diagram"]) { app in
                self.ask(app, "Draw the attention computation")
                let open = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.diagram.")).firstMatch
                XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
                XCTAssertTrue(app.webViews.firstMatch.staticTexts["Softmax"].waitForExistence(timeout: 10))
            },
            "chat-diagram-failure": Scenario(arguments: Self.chatFixture + ["--chat-fixture-mode=broken_diagram"]) { app in
                self.ask(app, "Draw the attention computation")
                self.dismissKeyboard(app)
                let open = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.diagram.")).firstMatch
                XCTAssertTrue(open.waitForExistence(timeout: 25)); open.tap()
                XCTAssertTrue(app.descendants(matching: .any)["diagram.failed"].firstMatch.waitForExistence(timeout: 20))
            },
            "chat-sources": Scenario(arguments: Self.chatFixture + ["--chat-fixture-mode=sources"]) { app in
                self.ask(app, "What do recent sources say?")
                XCTAssertTrue(app.buttons["chat.source.1"].waitForExistence(timeout: 10))
                self.dismissKeyboard(app)
            },
            "chat-credits": Scenario(arguments: Self.chatFixture + ["--chat-fixture-mode=insufficient_credits"]) { app in
                self.ask(app, "Summarize the method")
                XCTAssertTrue(app.buttons["chat.getCredits"].waitForExistence(timeout: 10))
                self.dismissKeyboard(app)
            },
            "store": Scenario(arguments: Self.chatFixture + ["--chat-fixture-mode=insufficient_credits"]) { app in
                self.ask(app, "Summarize the method")
                XCTAssertTrue(app.buttons["chat.getCredits"].waitForExistence(timeout: 10))
                self.dismissKeyboard(app)
                app.buttons["chat.getCredits"].tap()
                XCTAssertTrue(app.navigationBars["Get credits"].waitForExistence(timeout: 5)); sleep(1)
            },
            // `store` is signed in without a backend (the chat fixture); this is the signed-out store,
            // reached from the metadata fixture's import that is waiting for credits.
            "store-signedout": Scenario(arguments: Self.metadataFixture) { app in
                let getCredits = app.buttons.matching(NSPredicate(format: "label == %@", "Get credits")).firstMatch // the row's identifier replaces the button's
                _ = getCredits.waitForExistence(timeout: 3) // the import may be below the fold
                for _ in 0..<5 where !(getCredits.exists && getCredits.isHittable) { app.swipeUp(); _ = getCredits.waitForExistence(timeout: 1) }
                XCTAssertTrue(getCredits.isHittable)
                getCredits.tap()
                XCTAssertTrue(app.navigationBars["Get credits"].waitForExistence(timeout: 5)); sleep(1)
            },
            // Design audit (owner request 2026-10-05): the layer just below the surface.
            "library-options": Scenario(arguments: ["--workflow-fixture"]) { app in
                self.tapMenu(app, "Library options")
            },
            "library-add": Scenario(arguments: ["--workflow-fixture", "--visual-show-import"]) { app in
                XCTAssertTrue(app.navigationBars["Add a paper"].waitForExistence(timeout: 5)); sleep(1)
            },
            "paper-options": Scenario(arguments: ["--workflow-fixture"]) { app in
                self.openSample(app)
                self.tapMenu(app, "Paper options")
            },
            "paper-selection": Scenario(arguments: ["--workflow-fixture"]) { app in
                self.openSample(app)
                let web = app.webViews.firstMatch
                XCTAssertTrue(web.waitForExistence(timeout: 5))
                app.buttons["Table of contents"].tap()
                let section = app.buttons["1. Start with the question"]
                XCTAssertTrue(section.waitForExistence(timeout: 5)); section.tap()
                let paragraph = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A useful first pass identifies")).firstMatch
                XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
                web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                    dx: paragraph.frame.minX - web.frame.minX + 55, dy: paragraph.frame.minY - web.frame.minY + 18)).press(forDuration: 1)
                XCTAssertTrue(app.buttons["reader.selection.define"].waitForExistence(timeout: 5)); sleep(1)
            },
            // Citations and the publication line (owner feedback, build 11 session).
            "paper-top": Scenario(arguments: Self.mathpixFixture) { app in self.openMathpix(app) },
            // Topic tags (docs/architecture/TAGS.md): chips under the publication line; Edit tags from the paper's options.
            "paper-tags-edit": Scenario(arguments: Self.mathpixFixture) { app in
                self.openMathpix(app); self.tapMenu(app, "Paper options")
                app.buttons["Edit tags"].tap()
                XCTAssertTrue(app.navigationBars["Edit tags"].waitForExistence(timeout: 5)); sleep(1)
            },
            "paper-tags-suggest": Scenario(arguments: Self.mathpixFixture) { app in
                self.openMathpix(app); self.tapMenu(app, "Paper options")
                app.buttons["Edit tags"].tap()
                let field = app.textFields["tags.field"]
                XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("rein")
                XCTAssertTrue(app.buttons["tags.suggestion.Reinforcement learning"].waitForExistence(timeout: 5)); sleep(1)
            },
            "paper-citation": Scenario(arguments: Self.mathpixFixture) { app in
                self.openMathpix(app); self.contents(app, "1 Introduction"); sleep(1)
            },
            "paper-reference": Scenario(arguments: Self.mathpixFixture) { app in
                self.openMathpix(app); self.contents(app, "1 Introduction"); self.followCitation(app, "Reference 11")
            },
            "paper-reference-actions": Scenario(arguments: Self.mathpixFixture) { app in
                self.openMathpix(app); self.contents(app, "1 Introduction"); self.followCitation(app, "Reference 11")
                let entry = app.webViews.firstMatch.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "[11]")).firstMatch
                XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
                XCTAssertTrue(app.buttons["Add to library"].waitForExistence(timeout: 5)); sleep(1)
            },
            "chat-history": Scenario(arguments: Self.chatFixture + ["--chat-fixture-mode=answer"]) { app in
                self.ask(app, "Why scale by the square root of d_k?")
                sleep(3); self.dismissKeyboard(app)
                app.buttons["Chat history"].tap(); sleep(1)
            },
            // All chats as a table (owner request 2026-10-07) over ~30 fixture conversations and one unsent draft;
            // `-search` filters it, `-actions` long-presses a paper chat.
            "chat-history-table": Scenario(arguments: Self.historyFixture) { app in self.openHistory(app, draft: "Compare LoRA ranks across tasks") },
            "chat-history-search": Scenario(arguments: Self.historyFixture) { app in
                self.openHistory(app)
                let search = app.searchFields.firstMatch
                XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("DPO")
                sleep(1)
            },
            "chat-history-actions": Scenario(arguments: Self.historyFixture) { app in
                self.openHistory(app)
                let row = app.buttons["chat.history.c4a7c4a7-0000-4000-8000-000000000004"]
                XCTAssertTrue(row.waitForExistence(timeout: 5)); row.press(forDuration: 1.2)
                sleep(1)
            },
            "chat-paper-menu": Scenario(arguments: Self.historyFixture) { app in
                self.openAttentionChat(app)
                app.buttons["chat.context"].tap()
                XCTAssertTrue(app.buttons["chat.paperChats.all"].waitForExistence(timeout: 5))
            },
            "chat-paper-history": Scenario(arguments: Self.historyFixture) { app in
                self.openAttentionChat(app)
                app.buttons["Chat history"].tap()
                XCTAssertTrue(app.buttons["chat.history.filter.thisPaper"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["chat.history.filter.thisPaper"].isSelected)
                XCTAssertEqual(app.staticTexts["chat.history.count"].label, "3 of 30 chats")
            },
            "signin": Scenario(arguments: ["--authentication-fixture", "--reset-authentication-fixture"]) { app in
                // The wide iPad layout has no tab bar; Settings is its gear button.
                if app.buttons["tab.settings"].exists { app.buttons["tab.settings"].tap() } else { app.buttons["Settings"].tap() }
                let signIn = app.buttons["account.signIn"]
                XCTAssertTrue(signIn.waitForExistence(timeout: 5)); signIn.tap()
                XCTAssertTrue(app.buttons["auth.emailMethod"].waitForExistence(timeout: 5)); sleep(1)
            },
            "settings": Scenario(arguments: ["--workflow-fixture"]) { app in self.go(app, "settings"); sleep(1) },
            "settings-end": Scenario(arguments: ["--workflow-fixture"]) { app in
                self.go(app, "settings")
                for _ in 0..<6 { app.swipeUp() }
                sleep(1)
            },
            // Settings signed in (owner feedback, build 14 #8/#9): the Account row and its page, About and its
            // Acknowledgements; `chat-title` opens a selection-action conversation to show its short title.
            "settings-account": Scenario(arguments: Self.chatFixture) { app in self.go(app, "settings"); sleep(1) },
            "settings-account-end": Scenario(arguments: Self.chatFixture) { app in
                self.go(app, "settings")
                for _ in 0..<6 { app.swipeUp() }
                sleep(1)
            },
            "account": Scenario(arguments: Self.chatFixture) { app in
                self.go(app, "settings")
                let row = app.buttons["account.row"]
                XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
                XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5)); sleep(1)
            },
            "about": Scenario(arguments: ["--workflow-fixture"]) { app in self.openAbout(app) },
            "acknowledgements": Scenario(arguments: ["--workflow-fixture"]) { app in
                self.openAbout(app)
                let row = app.buttons["about.acknowledgements"]
                XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
                XCTAssertTrue(app.navigationBars["Acknowledgements"].waitForExistence(timeout: 5)); sleep(1)
            },
            "chat-title": Scenario(arguments: Self.historyFixture) { app in
                self.openHistory(app)
                let row = app.buttons["chat.history.c4a7c4a7-0000-4000-8000-000000000005"]
                XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
                XCTAssertTrue(app.navigationBars["All chats"].waitForNonExistence(timeout: 5)); sleep(1)
            },
        ]
    }

    /// Tabs on compact layouts; the wide iPad layout's own controls otherwise (paper chat sits beside
    /// the reader there).
    private func go(_ app: XCUIApplication, _ tab: String) {
        if app.buttons["tab.\(tab)"].exists { app.buttons["tab.\(tab)"].tap(); return }
        switch tab {
        case "settings": app.buttons["Settings"].tap()
        case "chat": app.segmentedControls.buttons["Reader"].tap()
        default: app.segmentedControls.buttons[tab.capitalized].tap()
        }
    }

    /// Scrolls the slow import's status into view (large text pushes it below the fold). VoiceOver reads the step and
    /// the time: "Reading equations and figures, 4 minutes, taking longer than usual".
    private func showSlowImport(_ app: XCUIApplication) {
        let status = app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH %@", "minutes, taking longer than usual")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        // Short drags, until it is clear of the tab bar (compact layouts). Element frames don't follow a landscape
        // rotation, so there one drag brings the row (just above the tab bar) into view.
        let drag = { // held at the end, so the list doesn't coast past the row
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        let tab = app.buttons["tab.library"]
        if XCUIDevice.shared.orientation.isLandscape { if tab.exists { drag() } }
        else { for _ in 0..<8 where !status.isHittable || (tab.exists && status.frame.maxY > tab.frame.minY - 24) { drag() } }
        sleep(1)
    }

    /// Settings › About Gradstep (the last row; scrolled to on short screens and at large text).
    private func openAbout(_ app: XCUIApplication) {
        go(app, "settings")
        let about = app.buttons["settings.about"]
        for _ in 0..<8 where !(about.exists && about.isHittable) { app.swipeUp() }
        XCTAssertTrue(about.waitForExistence(timeout: 5)); about.tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5)); sleep(1)
    }

    private func tapMenu(_ app: XCUIApplication, _ label: String) {
        let button = app.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap(); sleep(1)
    }

    private func openSample(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10)); app.buttons[sampleID].tap()
        sleep(2)
    }

    private func openMathpix(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons[mathpixID].waitForExistence(timeout: 10)); app.buttons[mathpixID].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 8))
        sleep(2)
    }

    /// Opens a section from Contents (a real paper's list is longer than the sheet).
    private func contents(_ app: XCUIApplication, _ heading: String) {
        app.buttons["Table of contents"].tap()
        let row = app.buttons[heading]
        for _ in 0..<6 { if row.waitForExistence(timeout: 2) { break }; app.swipeUp() }
        if !row.isHittable { app.swipeUp() }
        row.tap()
        sleep(1)
    }

    private func followCitation(_ app: XCUIApplication, _ label: String) {
        let citation = app.webViews.firstMatch.links[label].firstMatch
        XCTAssertTrue(citation.waitForExistence(timeout: 5)); citation.tap()
        XCTAssertTrue(app.buttons["reader.citation.back"].waitForExistence(timeout: 5))
        usleep(700_000) // the reference is still highlighted
    }

    private func ask(_ app: XCUIApplication, _ question: String) {
        // The wide iPad layout has no tab bar; its general chat is a segment.
        if app.buttons["tab.chat"].exists { app.buttons["tab.chat"].tap() } else { app.segmentedControls.buttons["General Chat"].tap() }
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        input.typeText(question)
        app.buttons["chat.send"].tap()
    }

    /// Opens All chats from the chat's top bar, after leaving an unsent general draft when one is given.
    private func openHistory(_ app: XCUIApplication, draft: String? = nil) {
        if app.buttons["tab.chat"].exists { app.buttons["tab.chat"].tap() } else { app.segmentedControls.buttons["General Chat"].tap() }
        if let draft {
            if app.buttons["chat.context"].exists, app.buttons["chat.context"].value as? String != "General chat" {
                app.buttons["chat.context"].tap()
                if app.buttons["General chat"].waitForExistence(timeout: 5) { app.buttons["General chat"].tap() }
            }
            let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText(draft)
            dismissKeyboard(app)
        }
        let history = app.buttons["Chat history"]
        XCTAssertTrue(history.waitForExistence(timeout: 5)); history.tap()
        XCTAssertTrue(app.navigationBars["All chats"].waitForExistence(timeout: 5))
        // These existing scenarios inspect all thirty conversations. A paper
        // chat now opens on its own paper first; keep their original scope.
        if app.buttons["chat.history.filter.thisPaper"].exists { app.buttons["chat.history.filter.all"].tap() }
        sleep(1)
    }

    private func openAttentionChat(_ app: XCUIApplication) {
        openHistory(app)
        let row = app.buttons["chat.history.c4a7c4a7-0000-4000-8000-000000000001"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.navigationBars["All chats"].waitForNonExistence(timeout: 5))
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        if app.keyboards.count > 0, app.buttons["chat.dismissKeyboard"].exists { app.buttons["chat.dismissKeyboard"].tap() }
        sleep(1)
    }

    func testCaptureScenarios() throws {
        let requested = ProcessInfo.processInfo.environment["SCIENCE_READER_VISUAL_SCENARIOS"] ?? ""
        try XCTSkipIf(requested.isEmpty, "Runs only from scripts/visual-check.mjs")
        let names = requested == "all" ? scenarios.keys.sorted() : requested.split(separator: ",").map(String.init)
        let landscape = ProcessInfo.processInfo.environment["SCIENCE_READER_VISUAL_ORIENTATION"] == "landscape"
        var failures: [String] = []
        for name in names {
            guard let scenario = scenarios[name] else { failures.append("\(name): unknown scenario"); continue }
            XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
            let app = XCUIApplication()
            app.launchArguments = scenario.arguments
            app.launch()
            if scenario.arguments.contains("--offline-reader-fixture") { XCTAssertTrue(app.buttons[mathpixID].waitForExistence(timeout: 15)) }
            else {
                XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 15) || app.buttons["tab.library"].waitForExistence(timeout: 5)
                              || app.descendants(matching: .any)["library.table"].waitForExistence(timeout: 5))
            }
            do { try scenario.steps(app) } catch { failures.append("\(name): \(error)") }
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "visual__\(name)"; attachment.lifetime = .keepAlways; add(attachment)
            app.terminate()
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
