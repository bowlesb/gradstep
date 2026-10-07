import XCTest

/// Named screens for visual checks (docs/VISUAL_CHECK.md): each scenario puts
/// the app into one deterministic state from fixtures and saves a screenshot
/// named "visual__<scenario>". scripts/visual-check.mjs runs them across devices,
/// dark mode and large text and compares before/after. Runs only when the
/// runner names scenarios.
@MainActor
final class VisualScenarioTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    struct Scenario {
        let arguments: [String]
        let steps: (XCUIApplication) throws -> Void
    }

    private static let chatFixture = ["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture"]
    private static let metadataFixture = ["--workflow-fixture", "--library-metadata-fixture"]

    /// The catalogue. Keep steps short and deterministic; wait for the state, never for time alone when avoidable.
    private var scenarios: [String: Scenario] {
        [
            "library": Scenario(arguments: ["--workflow-fixture"]) { _ in },
            "feed": Scenario(arguments: ["--workflow-fixture"]) { app in self.go(app, "feed"); sleep(1) },
            "feed-results": Scenario(arguments: ["--workflow-fixture", "--library-metadata-fixture", "--feed-fixture"]) { app in self.go(app, "feed"); sleep(1) },
            "library-search": Scenario(arguments: ["--workflow-fixture"]) { app in
                let search = app.searchFields.firstMatch
                XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("attention")
                sleep(1)
            },
            // Library layouts (owner decision 2026-10-05) over a varied metadata fixture. On iPad
            // library-table is the native table; on iPhone portrait the same layout is detailed rows.
            "library-table": Scenario(arguments: Self.metadataFixture + ["--library-layout=table"]) { _ in sleep(1) },
            "library-detailed": Scenario(arguments: Self.metadataFixture + ["--library-layout=table"]) { app in
                // iPad: the Browse column is narrow, so the table layout shows detailed rows there.
                if app.segmentedControls.buttons["Browse"].exists { app.segmentedControls.buttons["Browse"].tap() }
                sleep(2)
            },
            "library-metadata-list": Scenario(arguments: Self.metadataFixture) { _ in sleep(1) },
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
            "chat-history": Scenario(arguments: Self.chatFixture + ["--chat-fixture-mode=answer"]) { app in
                self.ask(app, "Why scale by the square root of d_k?")
                sleep(3); self.dismissKeyboard(app)
                app.buttons["Chat history"].tap(); sleep(1)
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

    private func tapMenu(_ app: XCUIApplication, _ label: String) {
        let button = app.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap(); sleep(1)
    }

    private func openSample(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10)); app.buttons[sampleID].tap()
        sleep(2)
    }

    private func ask(_ app: XCUIApplication, _ question: String) {
        // The wide iPad layout has no tab bar; its general chat is a segment.
        if app.buttons["tab.chat"].exists { app.buttons["tab.chat"].tap() } else { app.segmentedControls.buttons["General Chat"].tap() }
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        input.typeText(question)
        app.buttons["chat.send"].tap()
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
            XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 15) || app.buttons["tab.library"].waitForExistence(timeout: 5)
                          || app.descendants(matching: .any)["library.table"].waitForExistence(timeout: 5))
            do { try scenario.steps(app) } catch { failures.append("\(name): \(error)") }
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "visual__\(name)"; attachment.lifetime = .keepAlways; add(attachment)
            app.terminate()
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
