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
            "feed": Scenario(arguments: ["--workflow-fixture"]) { app in app.buttons["tab.feed"].tap(); sleep(1) },
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
                app.buttons["tab.chat"].tap()
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch.waitForExistence(timeout: 5))
                sleep(1)
            },
            "chat-keyboard": Scenario(arguments: ["--workflow-fixture"]) { app in
                app.buttons["tab.chat"].tap()
                let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
                XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5)); sleep(1)
            },
            "chat-answer": Scenario(arguments: Self.chatFixture + ["--chat-fixture-mode=answer"]) { app in
                self.ask(app, "Why scale by the square root of d_k?")
                sleep(3)
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
            "settings": Scenario(arguments: ["--workflow-fixture"]) { app in app.buttons["tab.settings"].tap(); sleep(1) },
            "settings-end": Scenario(arguments: ["--workflow-fixture"]) { app in
                app.buttons["tab.settings"].tap()
                for _ in 0..<6 { app.swipeUp() }
                sleep(1)
            },
        ]
    }

    private func openSample(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10)); app.buttons[sampleID].tap()
        sleep(2)
    }

    private func ask(_ app: XCUIApplication, _ question: String) {
        app.buttons["tab.chat"].tap()
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
