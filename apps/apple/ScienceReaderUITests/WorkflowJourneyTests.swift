import XCTest
import UIKit

@MainActor
final class WorkflowJourneyTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    func testChatScrollAuditAtRest() throws { try chatScrollAudit(streaming: false) }
    func testChatScrollAuditWhileStreaming() throws { try chatScrollAudit(streaming: true) }
    func testChatScrollAuditWithinGrowingAnswer() throws { try chatScrollAudit(streaming: true, growingRow: true) }
    func testChatScrollAuditDetectsLegacyJitter() throws { try chatScrollAudit(streaming: false, legacy: true) }

    private func chatScrollAudit(streaming: Bool, legacy: Bool = false, growingRow: Bool = false) throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture",
                               "--chat-scroll-audit=\(streaming ? "stream" : "static")"]
        if legacy { app.launchArguments.append("--chat-scroll-audit-legacy-rows") }
        if growingRow { app.launchArguments.append("--chat-scroll-audit-growing-row") }
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 15))
        app.show("chat")
        let transcript = app.tables["chat.transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        if streaming {
            let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
            input.tap(); input.typeText("Continue with more detail")
            if app.buttons["chat.dismissKeyboard"].exists { app.buttons["chat.dismissKeyboard"].tap() }
            app.buttons["chat.send"].tap()
            XCTAssertTrue(app.buttons["chat.stop"].waitForExistence(timeout: 5))
            if growingRow {
                let answer = transcript.descendants(matching: .any).matching(NSPredicate(format:
                    "identifier BEGINSWITH %@ AND label CONTAINS %@", "chat.message.text.", "Growing answer")).firstMatch
                XCTAssertTrue(answer.waitForExistence(timeout: 15))
            } else {
                // Read completed messages while the answer continues below the viewport.
                transcript.swipeDown(velocity: .fast)
                transcript.swipeDown(velocity: .fast)
            }
        }
        // Real touch drags in both directions, crossing tall self-sizing rows.
        let frame = transcript.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for direction in [1.0, 1.0, 1.0, -1.0, -1.0, 1.0] {
            let a = origin.withOffset(CGVector(dx: frame.minX + frame.width * 0.55, dy: frame.minY + frame.height * (direction > 0 ? 0.25 : 0.7)))
            let b = origin.withOffset(CGVector(dx: frame.minX + frame.width * 0.55, dy: frame.minY + frame.height * (direction > 0 ? 0.7 : 0.25)))
            a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        for _ in 0..<3 { transcript.swipeDown(velocity: .fast); transcript.swipeUp(velocity: .fast) }
        capture(app, streaming ? "Streaming scroll audit" : "Completed scroll audit")
        let metrics = try XCTUnwrap(transcript.value as? String).data(using: .utf8).map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let audit = try XCTUnwrap(metrics ?? nil)
        XCTAssertGreaterThan(try XCTUnwrap(audit["dragFrames"] as? Int), 150, "The check must sample actual dragging")
        XCTAssertGreaterThan(try XCTUnwrap(audit["trackingSamples"] as? Int), 150)
        if legacy {
            XCTAssertGreaterThan(try XCTUnwrap(audit["maxStableHeightChange"] as? Double), 10,
                                 "The negative control must detect the original height feedback: \(audit)")
            XCTAssertGreaterThan(try XCTUnwrap(audit["maxTrackingError"] as? Double), 10,
                                 "The negative control must detect text losing the finger: \(audit)")
            return
        }
        XCTAssertEqual(audit["reverseJumps"] as? Int, 0, "Text moved against the finger: \(audit)")
        XCTAssertLessThanOrEqual(try XCTUnwrap(audit["maxTrackingError"] as? Double), 3,
                                "Text lost the finger during a drag: \(audit)")
        XCTAssertLessThanOrEqual(try XCTUnwrap(audit["maxStableHeightChange"] as? Double), 1,
                                "An unchanged message resized while scrolling: \(audit)")
        XCTAssertGreaterThan(try XCTUnwrap(audit["idleReadSamples"] as? Int), 30)
        if growingRow { XCTAssertGreaterThan(try XCTUnwrap(audit["growingIdleReadSamples"] as? Int), 30) }
        XCTAssertLessThanOrEqual(try XCTUnwrap(audit["maxIdleShift"] as? Double), 3,
                                "The passage moved after the reader stopped scrolling: \(audit)")
    }

    private func launch(additionalArguments: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture"] + additionalArguments
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        return app
    }

    /// The chat's Paper chat / General chat switch is the title's menu (owner feedback, build 14).
    private func selectChatContext(_ app: XCUIApplication, _ name: String) {
        let menu = app.buttons["chat.context"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.tap()
        let option = app.buttons[name]
        XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
    }

    private func chatContext(_ app: XCUIApplication) -> String? { app.buttons["chat.context"].value as? String }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func finalReply(in app: XCUIApplication) -> XCUIElement {
        app.tables["chat.transcript"].descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "chat.message.text.", "This is a synthetic conversation for layout testing")).firstMatch
    }

    /// The transcript runs under the floating chrome (2026-10-07), so "visible" means clear of it: below the
    /// context switch and above the message box.
    private func assertFinalReplyAtBottom(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let reply = finalReply(in: app), transcript = app.tables["chat.transcript"]
        let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        let visible = NSPredicate { _, _ in
            reply.exists && transcript.exists && composer.exists && reply.frame.maxY <= composer.frame.minY + 2
                && reply.frame.maxY > self.readingTop(app) + 2
                && !app.buttons["chat.latest"].isHittable
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visible, object: nil)], timeout: 5)
        XCTAssertEqual(result, .completed, "Final reply bottom \(reply.frame) should be above the message box \(composer.frame)", file: file, line: line)
    }

    /// Top of the conversation's readable area: below the title bar.
    private func readingTop(_ app: XCUIApplication) -> CGFloat {
        let bar = app.navigationBars.containing(.button, identifier: "chat.context").firstMatch
        return bar.exists ? bar.frame.maxY : app.tables["chat.transcript"].frame.minY
    }

    /// Height of the conversation left readable between the floating chrome above and below it.
    private func readingHeight(_ app: XCUIApplication) -> CGFloat {
        let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        return composer.frame.minY - readingTop(app)
    }

    func testSearchOpenReturnNoMatchesAndSeparateExternalScope() throws {
        let app = launch(), query = "  EVALUATION  "
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText(query)
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 5))
        app.buttons[sampleID].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5))
        app.show("library")
        XCTAssertEqual(search.value as? String, query)
        capture(app, "Library retains query after reading")
        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: query.count) + "no-matching-paper")
        XCTAssertTrue(app.staticTexts["No matching papers"].waitForExistence(timeout: 5))
        app.buttons["search.clear"].tap()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 5))
        // The Library / ML paper search switch belongs to searching: it shows while the field is active.
        // (By its identifier: the wide layout's mode control has a "Library" segment too.)
        let scope = app.segmentedControls["library.searchScope"]
        if !scope.buttons["ML paper search"].exists { search.tap() }
        XCTAssertTrue(scope.buttons["ML paper search"].waitForExistence(timeout: 5))
        scope.buttons["ML paper search"].tap()
        XCTAssertTrue(app.staticTexts["Find papers"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[sampleID].exists, "External search must never relabel local rows")
        scope.buttons["Library"].tap()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 5))
        capture(app, "Library populated and sparse metadata rows")
    }

    /// The search switch's name (owner, 2026-10-16: "Call it ML Paper search") beside "Library", at the default and
    /// the largest text size: whole, on screen and tappable (run on the narrowest iPhone for the screenshots).
    func testSearchScopeNameFitsAtDefaultAndLargestTextSizes() throws {
        for size in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            let app = launch(additionalArguments: ["-UIPreferredContentSizeCategoryName", size.rawValue])
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap()
            let scope = app.segmentedControls["library.searchScope"]
            let external = scope.buttons["ML paper search"]
            XCTAssertTrue(external.waitForExistence(timeout: 5))
            XCTAssertTrue(external.isHittable && scope.buttons["Library"].isHittable)
            XCTAssertLessThanOrEqual(scope.frame.maxX, app.windows.firstMatch.frame.maxX)
            capture(app, "Search switch, \(size.rawValue)")
            external.tap()
            XCTAssertTrue(app.staticTexts["Find papers"].waitForExistence(timeout: 5))
            capture(app, "ML paper search, \(size.rawValue)")
            app.terminate()
        }
    }

    func testChatKeyboardContextHistoryAndReturnPreserveDrafts() throws {
        let app = launch()
        app.show("chat")
        XCTAssertTrue(app.navigationBars["Understanding attention"].waitForExistence(timeout: 5))
        assertFinalReplyAtBottom(app)
        capture(app, "Paper conversation with realistic paragraphs")
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        input.tap(); input.typeText("Paper draft to keep")
        XCTAssertTrue(app.buttons["chat.dismissKeyboard"].waitForExistence(timeout: 5))
        assertFinalReplyAtBottom(app)
        capture(app, "Chat composer and keyboard")
        XCTAssertTrue(app.buttons["chat.context"].isHittable, "Keep the context menu reachable while composing")
        app.buttons["chat.dismissKeyboard"].tap()
        selectChatContext(app, "General chat")
        input.tap(); input.typeText("General draft\nSecond line")
        app.buttons["chat.dismissKeyboard"].tap()
        selectChatContext(app, "Paper chat")
        XCTAssertEqual(input.value as? String, "Paper draft to keep")
        app.buttons["Chat history"].tap()
        XCTAssertTrue(app.buttons["chat.history.options"].waitForExistence(timeout: 5))
        // Close is in All chats' ≡ (owner, build 57).
        app.buttons["chat.history.options"].tap(); app.buttons["chat.history.close"].tap()
        XCTAssertEqual(input.value as? String, "Paper draft to keep")
        // Away and back: the chat's Return to paper (phone), or another view and Reader (wide: the paper is beside).
        app.returnToPaper()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5))
        app.show("chat")
        XCTAssertEqual(input.value as? String, "Paper draft to keep")
        app.buttons["New chat"].tap()
        XCTAssertNotEqual(input.value as? String, "Paper draft to keep")
        app.buttons["Chat history"].tap()
        app.buttons["Understanding attention"].tap()
        XCTAssertEqual(input.value as? String, "Paper draft to keep")
        selectChatContext(app, "General chat")
        XCTAssertEqual(input.value as? String, "General draft\nSecond line")
    }

    /// Floating chrome (2026-10-07): content runs under the tab bar and the message box, and the ends of the
    /// library and the conversation can still scroll clear of them.
    func testContentFlowsBehindFloatingChromeAndStaysReachable() throws {
        let app = launch(additionalArguments: ["--library-metadata-fixture"])
        let tab = app.buttons["tab.library"]
        try XCTSkipUnless(tab.exists, "Compact layout (tab bar)")
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.exists)
        XCTAssertGreaterThan(list.frame.maxY, tab.frame.maxY, "The list runs under the tab bar")
        for _ in 0..<12 { list.swipeUp(velocity: .fast) }
        let rows = list.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "paper.")).allElementsBoundByIndex
            + list.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "import.")).allElementsBoundByIndex
        let last = rows.filter(\.exists).max { $0.frame.maxY < $1.frame.maxY }
        XCTAssertNotNil(last)
        if let last { XCTAssertLessThanOrEqual(last.frame.maxY, tab.frame.minY + 1, "The last row scrolls clear of the tab bar") }

        app.show("chat")
        let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let transcript = app.tables["chat.transcript"]
        XCTAssertLessThan(composer.frame.maxY, app.buttons["tab.chat"].frame.minY, "The message box floats above the tab bar")
        XCTAssertGreaterThan(transcript.frame.maxY, app.buttons["tab.chat"].frame.minY, "The conversation runs under the chrome")
        XCTAssertTrue(app.buttons["chat.send"].exists && app.buttons["Chat history"].exists && app.buttons["New chat"].exists)
        assertFinalReplyAtBottom(app)
    }

    func testChatKeepsLatestVisibleAsComposerGrowsAndKeyboardDismisses() throws {
        let app = launch()
        app.show("chat")
        exerciseLatestReplyWhileComposing(app)
    }

    func testDeletedObservedReplyRetainsEarlierMessagesUntilSiblingIsChosen() throws {
        let app = launch(additionalArguments: ["--branch-fixture"])
        // The fixture's current chat is the general one: the Chat tab, or the wide layout's General Chat.
        if app.buttons["tab.chat"].waitForExistence(timeout: 2) { app.show("chat") } else { app.segmentedControls["wide.mode"].buttons["General Chat"].tap() }
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(chatContext(app), "General chat")
        XCTAssertEqual(input.value as? String, "A separate general draft")
        app.buttons["Chat history"].tap()
        XCTAssertTrue(app.buttons["chat.history.options"].waitForExistence(timeout: 5))
        app.buttons["A retained paper discussion"].tap()

        let transcript = app.tables["chat.transcript"]
        func message(_ text: String) -> XCUIElement {
            transcript.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "chat.message.text.", text)).firstMatch
        }
        let earlier = message("Keep this earlier question visible.")
        let removed = message("This observed reply was removed.")
        let siblingText = "A sibling reply requires an explicit choice."
        let sibling = message(siblingText)
        XCTAssertTrue(app.navigationBars["A retained paper discussion"].waitForExistence(timeout: 5))
        XCTAssertEqual(chatContext(app), "Paper chat")
        XCTAssertEqual(input.value as? String, "Draft for the retained paper discussion")
        XCTAssertTrue(earlier.waitForExistence(timeout: 5))
        XCTAssertTrue(earlier.isHittable)
        XCTAssertFalse(removed.exists)
        XCTAssertFalse(sibling.exists, "A surviving sibling must require an explicit choice")

        let branchPicker = app.buttons["chat.branchPicker"]
        XCTAssertTrue(branchPicker.waitForExistence(timeout: 5))
        branchPicker.tap()
        let earlierOption = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Earlier messages")).firstMatch
        let siblingOption = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", siblingText)).firstMatch
        XCTAssertTrue(earlierOption.waitForExistence(timeout: 5))
        XCTAssertTrue(siblingOption.isHittable)
        capture(app, "Deleted reply retains an explicit earlier-messages branch")
        siblingOption.tap()
        XCTAssertTrue(sibling.waitForExistence(timeout: 5))
        XCTAssertTrue(sibling.isHittable)
        XCTAssertTrue(earlier.exists)
        XCTAssertFalse(removed.exists)
        XCTAssertEqual(input.value as? String, "Draft for the retained paper discussion")
        selectChatContext(app, "General chat")
        XCTAssertEqual(input.value as? String, "A separate general draft")
        selectChatContext(app, "Paper chat")
        XCTAssertTrue(sibling.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "Draft for the retained paper discussion")
        // The way back to its paper: the chat's Return to paper on a phone; beside the chat in the wide layout.
        if app.buttons["tab.chat"].exists { XCTAssertTrue(app.buttons["chat.returnToPaper"].isHittable) }
        else { XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5), "The paper is beside its chat") }
        capture(app, "Explicit sibling choice preserves paper draft and context")
    }

    func testEncryptedDraftsSurviveRelaunchAndSentTextDoesNotReturn() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        let paperDraft = "Explain how attention scales."
        let generalDraft = "Compare retrieval methods."
        app.launchArguments = ["--draft-fixture", "--reset-draft-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        app.show("chat")
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        func assertDraftSaved() {
            let status = app.staticTexts["chat.draftStatus"]
            let saved = NSPredicate { _, _ in status.exists && status.label == "Draft saved on this device" }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: saved, object: nil)], timeout: 8), .completed)
        }
        func assertComposerEmpty() {
            let empty = NSPredicate { _, _ in
                let value = input.value as? String ?? ""
                return (value.isEmpty || value == "Chat") && !app.buttons["chat.send"].isEnabled
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: empty, object: nil)], timeout: 8), .completed)
        }
        func relaunch() {
            app.terminate()
            app.launchArguments = ["--draft-fixture"]
            app.launch()
            XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
            app.show("chat")
        }
        func sentQuestion() -> XCUIElementQuery {
            app.tables["chat.transcript"].descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                "chat.message.text.", "You: \(paperDraft)"))
        }

        XCTAssertEqual(chatContext(app), "Paper chat")
        input.tap(); input.typeText(paperDraft)
        assertDraftSaved()
        app.buttons["chat.dismissKeyboard"].tap()
        selectChatContext(app, "General chat")
        input.tap(); input.typeText(generalDraft)
        assertDraftSaved()
        app.buttons["chat.dismissKeyboard"].tap()

        relaunch()
        XCTAssertEqual(input.value as? String, paperDraft)
        selectChatContext(app, "General chat")
        XCTAssertEqual(input.value as? String, generalDraft)
        selectChatContext(app, "Paper chat")
        XCTAssertEqual(input.value as? String, paperDraft)
        capture(app, "Encrypted paper and general drafts survive process relaunch")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(sentQuestion().firstMatch.waitForExistence(timeout: 8))
        assertComposerEmpty()

        // Restart after the send is locally visible; the transaction must have
        // consumed the captured draft even if a later receipt checkpoint lags.
        relaunch()
        app.buttons["Chat history"].tap()
        XCTAssertTrue(app.buttons["chat.history.options"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[paperDraft].waitForExistence(timeout: 5))
        app.buttons[paperDraft].tap()
        XCTAssertTrue(sentQuestion().firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(sentQuestion().count, 1, "The saved question appears once after relaunch")
        assertComposerEmpty()
        selectChatContext(app, "General chat")
        XCTAssertEqual(input.value as? String, generalDraft)
        selectChatContext(app, "Paper chat")
        assertComposerEmpty()
        capture(app, "Saved question reopens once without resurrecting its draft")
    }

    /// Content anchors for one installed fixture: a Contents heading, the
    /// paragraphs around a numbered display equation, that equation's LaTeX
    /// marker and a nearby figure's accessibility label.
    private struct ReaderJourney {
        let mathpix: Bool
        let heading: String, before: String, after: String, latex: String, figure: String
        static let authored = ReaderJourney(mathpix: false, heading: "2. Read the equations in context",
            before: "Scaled dot-product attention turns", after: "The normalization in Equation",
            latex: #"\begin{equation}"#, figure: "Open figure: Queries and keys")
        // Real DPO paper rendered by timestep-mathpix-mathml-v1 (CC BY 4.0).
        static let mathpix = ReaderJourney(mathpix: true, heading: "5.2 Instability of Actor-Critic Algorithms",
            before: "With some algebra this leads to the optimization objective", after: "This is the same objective optimized in prior works",
            latex: #"\begin{equation*}"#, figure: "Open figure: Figure 2: Left.")
    }

    func testInstalledEncryptedPaperSurvivesRelaunchWithEquationsFiguresAndChat() throws {
        try installedEncryptedReaderJourney(.authored)
    }

    func testRenderedMathpixBundleSurvivesRelaunchWithEquationsFiguresAndChat() throws {
        try installedEncryptedReaderJourney(.mathpix)
    }

    private func installedEncryptedReaderJourney(_ journey: ReaderJourney) throws {
        let mathpix = journey.mathpix
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication(), paperID = "paper.dddddddd-0000-4000-8000-000000000002"
        let variant = mathpix ? ["--mathpix-reader-fixture"] : []
        app.launchArguments = ["--offline-reader-fixture", "--reset-offline-reader-fixture"] + variant
        app.launch()
        XCTAssertTrue(app.buttons[paperID].waitForExistence(timeout: 10))
        if mathpix {
            XCTAssertTrue(app.buttons[paperID].label.contains("Mathpix MathML fixture"), "The fixture must use the explicitly identified new artifact.")
        }
        // Installation is already durable when the fixture publishes its row.
        // The next process does not call the compiled sample loader at all.
        app.terminate()
        app.launchArguments = ["--offline-reader-fixture"] + variant
        app.launch()
        XCTAssertTrue(app.buttons[paperID].waitForExistence(timeout: 10))
        let unopenedRow = app.buttons[paperID]
        XCTAssertTrue(unopenedRow.label.contains("On this device") || unopenedRow.images["On this device"].exists,
                      "A persisted download remains available before its decoded bundle is loaded.")
        capture(app, "Downloaded badge survives relaunch before loading paper")
        app.buttons[paperID].tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 8))
        app.buttons["Table of contents"].tap()
        // The row in Contents' own list: the paper behind the sheet has the same heading, and a tap aimed at it closes
        // the sheet without going anywhere (iPhone 17 Pro, 2026-10-16).
        let list = app.descendants(matching: .any)["contents.list.contents"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let heading = list.buttons[journey.heading]
        // A real paper has more Contents rows than the medium detent shows, and
        // the list realizes rows lazily: scroll until the row exists.
        // Drags inside the list (a swipe can start on the sheet's tabs and move the sheet instead).
        func dragList() {
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        }
        // Well inside the sheet: a row at the very bottom of the half-height sheet counts as hittable, but a tap there
        // lands on the screen's edge, not the row (iPhone 17 Pro, 2026-10-16).
        let bottom = app.windows.firstMatch.frame.maxY - 140
        for _ in 0..<10 where !(heading.exists && heading.isHittable && heading.frame.maxY < bottom) { dragList() }
        XCTAssertTrue(heading.exists)
        heading.tapWhenSettled()
        XCTAssertTrue(list.waitForNonExistence(timeout: 5), "A Contents row closes Contents")
        let before = web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", journey.before)).firstMatch
        let after = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", journey.after)).firstMatch
        let positioned = NSPredicate { _, _ in before.isHittable && after.isHittable && after.frame.minY > before.frame.maxY + 20 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: positioned, object: nil)], timeout: 5), .completed)
        let y = (before.frame.maxY + after.frame.minY) / 2 - web.frame.minY
        web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: web.frame.width / 2, dy: y)).tap()
        let define = app.revealEditMenuItem("Explain in Chat")
        XCTAssertTrue(define.exists, "A tapped equation opens the edit menu")
        let paperOffset = before.frame.minY - web.frame.minY
        capture(app, "Equation actions from the encrypted installed paper after relaunch")
        define.tap()
        let questions = app.tables["chat.transcript"].descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "chat.message.text.", journey.latex))
        let question = questions.firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 8))
        app.buttons["chat.returnToPaper"].tap()
        let returned = NSPredicate { _, _ in before.exists && abs(before.frame.minY - web.frame.minY - paperOffset) < 6 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: returned, object: nil)], timeout: 5), .completed)
        let figure = web.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", journey.figure)).firstMatch
        for _ in 0..<8 {
            if figure.exists, figure.isHittable { break }
            // Small measured drags avoid jumping past the figure and then
            // repeatedly scrolling away from it. Both directions are valid.
            let below = !figure.exists || figure.frame.midY > web.frame.midY
            let from = web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: below ? 0.7 : 0.4))
            let to = web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: below ? 0.4 : 0.7))
            from.press(forDuration: 0.05, thenDragTo: to)
            let visible = NSPredicate { _, _ in figure.exists && figure.isHittable }
            if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visible, object: nil)], timeout: 1) == .completed { break }
        }
        XCTAssertTrue(figure.waitForExistence(timeout: 5)); XCTAssertTrue(figure.isHittable)
        figure.tap()
        // The figure sheet's X (DESIGN.md "Sheet top row").
        let done = app.buttons["sheet.close"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Couldn’t open figure"].exists)
        capture(app, "Figure reopened from encrypted local member bytes")
        done.tap()
        // A second process must recover the saved question as well as the paper.
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons[paperID].waitForExistence(timeout: 10))
        app.buttons[paperID].tap()
        XCTAssertTrue(web.waitForExistence(timeout: 8))
        app.show("chat")
        app.buttons["Chat history"].tap()
        // All chats shows a selection chat by its short title, not the raw LaTeX prompt: an equation's Define asks
        // the explain-equation question, so it reads "Explain · ‹symbols›".
        let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@ OR label CONTAINS %@",
                                                     "Explain · ", "Define · ", journey.latex)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.tap()
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        XCTAssertEqual(questions.count, 1, "The exact equation question is retained once after relaunch")
        capture(app, "Encrypted question restored alongside the installed paper")
    }

    /// A diagram Mermaid can't parse is sent back once ("Fixing the diagram…"); when the correction fails too, its view
    /// says so plainly, with the source collapsed.
    func testABrokenDiagramIsFixedOnceThenExplained() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-mode=broken_diagram", "--chat-fixture-consented", "--reset-draft-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        app.show("chat")
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        input.typeText("Draw the attention computation")
        // Dismiss before sending: the keyboard animation must not consume the
        // fixture's short repair state before the test starts observing it.
        if app.buttons["chat.dismissKeyboard"].waitForExistence(timeout: 2) { app.buttons["chat.dismissKeyboard"].tap() }
        app.buttons["chat.send"].tap()
        let fixing = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label == %@",
            "chat.message.progress", "Fixing the diagram…")).firstMatch
        XCTAssertTrue(fixing.waitForExistence(timeout: 15), "The answer waits while its diagram is redrawn")
        capture(app, "Fixing the diagram")
        let open = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.diagram.")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        XCTAssertFalse(fixing.exists)
        let title = app.buttons["chat.context"]
        XCTAssertGreaterThanOrEqual(title.frame.minX, app.buttons["Chat history"].frame.maxX, "Long titles leave room for history")
        XCTAssertLessThanOrEqual(title.frame.maxX, app.buttons["New chat"].frame.minX, "Long titles leave room for New chat")
        open.tapWhenSettled()
        XCTAssertTrue(app.staticTexts["Couldn’t draw this diagram"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Queries (Q)")).firstMatch.exists,
                       "The source starts collapsed")
        capture(app, "Diagram that couldn't be drawn")
        let source = app.descendants(matching: .any)["diagram.source"].firstMatch
        XCTAssertTrue(source.exists); source.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Queries (Q)")).firstMatch.waitForExistence(timeout: 5))
        capture(app, "Diagram source shown")
    }

    /// Figure parts sit in the answer where it discusses each one (owner, 2026-10-15: "the crops should be inline, right
    /// as the chat discusses each one"); under the answer, the whole figure with the parts outlined.
    func testFigurePartsAreInlineWhereTheAnswerDiscussesThem() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-mode=figure_parts", "--chat-fixture-consented", "--reset-draft-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        app.show("chat")
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        input.typeText("What does Figure 1 show?")
        app.buttons["chat.send"].tap()
        let one = app.descendants(matching: .any)["chat.message.figurePart.1"], two = app.descendants(matching: .any)["chat.message.figurePart.2"]
        XCTAssertTrue(one.waitForExistence(timeout: 15), "Part 1 is in the answer")
        XCTAssertTrue(two.exists)
        XCTAssertEqual(one.label, "Part 1: Left half")
        // In reading order, between the paragraphs that discuss them.
        let text = { (words: String) in app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "chat.message.text.", words)).firstMatch }
        let opening = text("two halves"), left = text("sets up the question")
        XCTAssertTrue(opening.exists && left.exists, "the answer's paragraphs around the parts")
        XCTAssertLessThan(opening.frame.midY, one.frame.minY); XCTAssertLessThan(one.frame.maxY, left.frame.midY + 1)
        XCTAssertLessThan(left.frame.midY, two.frame.minY)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "[[part")).firstMatch.exists, "no marker is shown")
        let whole = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.figureParts.")).firstMatch
        XCTAssertTrue(whole.exists, "the whole figure under the answer")
        XCTAssertLessThan(two.frame.maxY, whole.frame.minY)
        capture(app, "Figure parts inline in the answer: the whole figure under it")
        if app.buttons["chat.dismissKeyboard"].exists { app.buttons["chat.dismissKeyboard"].tap() }
        for _ in 0..<3 where one.frame.minY < 120 { app.swipeDown() }
        capture(app, "Figure parts inline in the answer")
        for _ in 0..<4 where !(whole.isHittable && app.windows.firstMatch.frame.insetBy(dx: 0, dy: 140).contains(CGPoint(x: whole.frame.midX, y: whole.frame.midY))) { app.swipeUp() }
        whole.tap()
        XCTAssertTrue(app.descendants(matching: .any)["figureParts.part.2"].waitForExistence(timeout: 5), "the full view opens")
    }

    /// The equation view (owner, 2026-10-15; EQUATION_VIEW.md): AI Explainer (build 62; it was "Equation") sits right after
    /// Explain in Chat on a tapped equation and opens the view explaining it: the equation large with its size and
    /// sideways scrolling, what it says and each symbol, background on request, a symbol's paragraph with Back, and
    /// Explain in Chat with the equation as the passage, nothing sent. One top row: Explain in Chat and the X.
    /// Owner, 2026-10-21: "Some border basically, when we present them in the equation view": the equation sits inside a
    /// bordered surface with room on every side, light and dark.
    func testEquationViewDrawsTheEquationInsideABorderDark() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-mode=equation", "--chat-fixture-consented", "--reset-draft-fixture", "--study-fixture", "-appearance", "dark"]
        app.launch()
        XCTAssertTrue(app.buttons["tab.paper"].waitForExistence(timeout: 10) || app.segmentedControls["wide.mode"].buttons["Reader"].exists)
        app.show("paper")
        let number = app.webViews.firstMatch.staticTexts["(1)"].firstMatch
        XCTAssertTrue(number.waitForExistence(timeout: 15), "The paper's numbered equation")
        number.tap()
        let item = app.revealEditMenuItem("AI Explainer")
        XCTAssertTrue(item.exists); item.tap()
        XCTAssertTrue(app.buttons["ai.chooseModel"].waitForExistence(timeout: 5)); app.buttons["ai.chooseModel"].tap()
        XCTAssertTrue(app.buttons["ai.chooseCloud"].waitForExistence(timeout: 5)); app.buttons["ai.chooseCloud"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["equation.symbol.1"].waitForExistence(timeout: 8))
        app.buttons["equation.larger"].tap(); app.buttons["equation.larger"].tap()
        capture(app, "Equation view: large, symbols described (dark)")
    }

    func testEquationViewDescribesSymbolsAndLeadsToThePaperAndTheChat() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-mode=equation", "--chat-fixture-consented", "--reset-draft-fixture", "--study-fixture"]
        app.launch()
        // The fixture selects the paper: the Paper tab on a phone, Reader in the wide layout.
        XCTAssertTrue(app.buttons["tab.paper"].waitForExistence(timeout: 10) || app.segmentedControls["wide.mode"].buttons["Reader"].exists)
        app.show("paper")
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 15), "The fixture opens the numbered HTML paper")
        // The display equation's number is part of the equation: a tap on it selects the equation.
        let openEquation = { () -> XCUIElement in
            let number = web.staticTexts["(1)"].firstMatch
            XCTAssertTrue(number.waitForExistence(timeout: 10), "The paper's numbered equation")
            number.tap()
            let item = app.revealEditMenuItem("AI Explainer")
            XCTAssertTrue(item.exists, "AI Explainer is offered on a tapped equation")
            return item
        }
        let item = openEquation()
        let explain = app.editMenuItem("Chat about Equation")
        // Right after Explain in Chat: below it in the menu's list, or beside it in a horizontal menu.
        XCTAssertTrue(explain.exists)
        XCTAssertTrue(explain.frame.maxY <= item.frame.minY + 1 || explain.frame.maxX <= item.frame.minX + 1, "right after Explain in Chat")
        capture(app, "AI Explainer in a tapped equation's menu")
        item.tap()
        XCTAssertTrue(app.buttons["ai.chooseModel"].waitForExistence(timeout: 5)); app.buttons["ai.chooseModel"].tap(); XCTAssertTrue(app.buttons["ai.chooseCloud"].waitForExistence(timeout: 5)); app.buttons["ai.chooseCloud"].tap()
        let heading = app.descendants(matching: .any)["equation.heading"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5)); XCTAssertEqual(heading.label, "Equation (1)", "The view names the equation")
        // AI Explainer is the reader's request: the explanation comes at once (owner, build 62), so the row offers
        // Explain in Chat and the X only; no Done.
        let symbol = app.descendants(matching: .any)["equation.symbol.1"]
        XCTAssertTrue(symbol.waitForExistence(timeout: 8), "The symbols are described")
        let composer = app.descendants(matching: .any).matching(identifier: "contextChat.composer").firstMatch
        XCTAssertTrue(composer.exists, "Follow up in this view")
        XCTAssertTrue(app.buttons["sheet.close"].exists)
        XCTAssertFalse(app.buttons["equation.explain"].exists, "asked already")
        XCTAssertFalse(app.buttons["Done"].exists, "no Done")
        XCTAssertTrue(app.descendants(matching: .any)["equation.symbol.2"].exists)
        XCTAssertTrue(app.staticTexts["equation.summary"].exists)
        XCTAssertTrue(app.buttons["equation.symbolSource.1"].exists, "a symbol the paper defines links to its paragraph")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "General meaning")).firstMatch.exists, "a symbol it doesn't is marked so")
        XCTAssertFalse(app.staticTexts["equation.credits"].exists, "no credit counts in the view (owner, build 59)")
        // Size and sideways scrolling.
        let size = app.staticTexts["equation.sizeValue"]
        XCTAssertEqual(size.label, "160 %")
        app.buttons["equation.larger"].tap(); app.buttons["equation.larger"].tap()
        XCTAssertEqual(size.label, "200 %")
        XCTAssertFalse(app.switches["equation.scroll"].exists, "Overflow pans without a separate mode")
        capture(app, "Equation view: large, symbols described")
        app.buttons["equation.smaller"].tap(); app.buttons["equation.smaller"].tap()
        XCTAssertEqual(size.label, "160 %")
        // Background, only when asked for.
        XCTAssertFalse(app.descendants(matching: .any)["equation.backgroundText"].exists)
        let background = app.buttons["equation.background"]
        for _ in 0..<3 where !background.isHittable { app.swipeUp() }
        background.tap()
        let text = app.descendants(matching: .any)["equation.backgroundText"]
        XCTAssertTrue(text.waitForExistence(timeout: 8), "Background streams in")
        let finished = NSPredicate { _, _ in text.label.contains("synthetic fixture answer") }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: finished, object: nil)], timeout: 8), .completed)
        capture(app, "Equation view: background")
        // A symbol's paragraph: the view closes and the paper goes there (with Back when the reader had moved from the
        // top; this short paper is read from the top, so none is offered).
        for _ in 0..<3 where !app.buttons["equation.symbolSource.1"].isHittable { app.swipeDown() }
        app.buttons["equation.symbolSource.1"].tap()
        XCTAssertTrue(heading.waitForNonExistence(timeout: 5), "The view closes")
        XCTAssertTrue(web.staticTexts["(1)"].firstMatch.waitForExistence(timeout: 5), "The paper is shown")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "doesn’t have")).firstMatch.waitForExistence(timeout: 2),
                       "The paragraph is found")
        capture(app, "A symbol's paragraph in the paper")
        if app.buttons["reader.citation.back"].exists { app.buttons["reader.citation.back"].tap() }
        // Reopened: the answers kept on the device show at once, then Ask in chat.
        openEquation().tap()
        XCTAssertTrue(symbol.waitForExistence(timeout: 3), "kept symbols")
        XCTAssertFalse(app.buttons["ai.chooseDefault"].exists, "A saved explanation needs no new provider choice or request")
        XCTAssertTrue(app.descendants(matching: .any)["equation.backgroundText"].exists, "kept background, no new request")
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Follow-ups stay below the explanation")
        XCTAssertTrue((composer.value as? String ?? "").isEmpty || (composer.value as? String ?? "").hasPrefix("Ask about"))
        capture(app, "Ask in chat from the equation view")
    }

    /// The equation view in the wide layout (iPad landscape, the Mac): a sheet over the reader and its chat column.
    func testEquationViewInTheWideLayout() throws {
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-mode=equation", "--chat-fixture-consented", "--reset-draft-fixture", "--study-fixture"]
        app.launch()
        // The wide layout's Reader mode; a phone's Paper tab.
        app.show("paper")
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 15))
        let number = web.staticTexts["(1)"].firstMatch
        XCTAssertTrue(number.waitForExistence(timeout: 10))
        #if targetEnvironment(macCatalyst)
        number.click()
        defer { app.typeKey(.escape, modifierFlags: []) }
        #else
        number.tap()
        #endif
        let item = app.revealEditMenuItem("AI Explainer")
        #if targetEnvironment(macCatalyst)
        capture(app, "Mac equation action menu")
        #endif
        XCTAssertTrue(item.exists)
        guard item.exists else { return }
        #if targetEnvironment(macCatalyst)
        item.click()
        #else
        item.tap()
        #endif
        XCTAssertTrue(app.buttons["ai.chooseDefault"].waitForExistence(timeout: 5)); app.buttons["ai.chooseDefault"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["equation.symbol.2"].waitForExistence(timeout: 8), "explained at once")
        app.buttons["equation.background"].tap()
        let text = app.descendants(matching: .any)["equation.backgroundText"]
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        let finished = NSPredicate { _, _ in text.label.contains("synthetic fixture answer") }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: finished, object: nil)], timeout: 8), .completed)
        capture(app, "Equation view, wide layout")
        app.buttons["sheet.close"].tap()
        XCTAssertTrue(app.buttons["sheet.close"].waitForNonExistence(timeout: 5))
        XCUIDevice.shared.portraitWhereSupported()
    }

    func testAnAnswerDiagramOpensFromTheAnswerAndFromAllDiagrams() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-mode=diagram", "--chat-fixture-consented", "--reset-draft-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        app.show("chat")
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        input.typeText("Draw the attention computation")
        app.buttons["chat.send"].tap()
        let open = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.diagram.")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        XCTAssertTrue(open.label.contains("Scaled dot-product attention"))
        // The drawing is part of the answer (owner, build 46), not only a button: the preview grows the row.
        let drawn = NSPredicate { _, _ in open.frame.height > 120 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: drawn, object: nil)], timeout: 15), .completed,
                       "the diagram is drawn in the answer (\(open.frame))")
        // Suggested questions wait behind one small control until asked for.
        let suggested = app.buttons["chat.followUps.toggle"]
        XCTAssertTrue(suggested.waitForExistence(timeout: 5))
        XCTAssertTrue(suggested.label.contains("Suggested questions (2)"), suggested.label)
        XCTAssertFalse(app.buttons["Why does the softmax saturate without the scaling?"].exists, "folded until asked for")
        capture(app, "Diagram in the answer, questions folded")
        suggested.tap()
        XCTAssertTrue(app.buttons["Why does the softmax saturate without the scaling?"].waitForExistence(timeout: 5))
        open.tap()
        // Drawn on device by the bundled Mermaid; its SVG labels are readable text. (The diagram's own web view: in
        // the wide layout the paper's is on screen beside the chat.)
        let canvas = app.webViews.containing(NSPredicate(format: "label == %@", "Softmax")).firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertTrue(canvas.staticTexts["Softmax"].waitForExistence(timeout: 10), "The diagram's nodes render")
        XCTAssertFalse(app.staticTexts["Couldn’t draw this diagram"].exists)
        // The whole diagram is on screen and its labels are readable (it used to shrink to ~8 pt text).
        let last = canvas.staticTexts["Weighted values"]
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        XCTAssertTrue(canvas.frame.insetBy(dx: -1, dy: -1).contains(last.frame), "\(last.frame) is inside \(canvas.frame)")
        XCTAssertGreaterThanOrEqual(last.frame.height, 13, "diagram labels are readable")
        capture(app, "Diagram drawn from an answer")
        app.buttons["Done"].tap()
        // The tab bar sits behind the software keyboard, as with system tab bars.
        if app.keyboards.count > 0, app.buttons["chat.dismissKeyboard"].exists { app.buttons["chat.dismissKeyboard"].tap() }
        XCTAssertTrue(app.buttons["tab.library"].waitForExistence(timeout: 5) || app.segmentedControls["wide.mode"].exists)
        app.show("library")
        app.buttons["Library options"].tap()
        app.buttons["All diagrams"].tap()
        let saved = app.buttons["Scaled dot-product attention"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.tap()
        XCTAssertTrue(app.webViews.containing(NSPredicate(format: "label == %@", "Softmax")).firstMatch.waitForExistence(timeout: 10))
        capture(app, "Diagram reopened from All diagrams")
    }

    func testNotEnoughCreditsOffersGetCredits() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-mode=insufficient_credits", "--chat-fixture-consented", "--reset-draft-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        app.show("chat")
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        input.typeText("Summarize the method")
        app.buttons["chat.send"].tap()
        let getCredits = app.buttons["chat.getCredits"]
        XCTAssertTrue(getCredits.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["chat.answerIssue"].label.contains("Not enough credits"))
        XCTAssertTrue(app.buttons["chat.retryAnswer"].exists, "Try again stays next to it")
        if app.keyboards.count > 0, app.buttons["chat.dismissKeyboard"].exists { app.buttons["chat.dismissKeyboard"].tap() }
        getCredits.tap()
        XCTAssertTrue(app.navigationBars["Get credits"].waitForExistence(timeout: 5))
        capture(app, "Get credits from a chat answer")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["chat.retryAnswer"].waitForExistence(timeout: 5))
    }

    /// Signed out, the store is not a dead end: one Sign in button opens sign-in (design audit F4).
    func testSignedOutStoreOffersSignIn() throws {
        // The workflow fixture is signed out; one of its imports is waiting for credits.
        let app = launch(additionalArguments: ["--library-metadata-fixture"])
        let getCredits = app.buttons.matching(NSPredicate(format: "label == %@", "Get credits")).firstMatch // the row's identifier replaces the button's
        _ = getCredits.waitForExistence(timeout: 3) // the import may be below the fold
        for _ in 0..<5 where !(getCredits.exists && getCredits.isHittable) { app.swipeUp(); _ = getCredits.waitForExistence(timeout: 1) }
        XCTAssertTrue(getCredits.isHittable)
        getCredits.tap()
        let signIn = app.buttons["store.signIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["store.restore"].exists, "Restore can't work signed out, so it is hidden")
        capture(app, "Signed-out store offers sign-in")
        signIn.tap()
        let sheet = NSPredicate { _, _ in
            (app.buttons["auth.emailMethod"].exists || app.staticTexts["auth.unavailable"].exists) && !app.navigationBars["Get credits"].exists
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: sheet, object: nil)], timeout: 8), .completed,
                       "The store gives way to the sign-in sheet")
        capture(app, "Sign-in from the store")
        app.buttons["auth.close"].tap()
        XCTAssertTrue(app.buttons["auth.close"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Get credits"].exists)
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 5), "Cancel returns to the Library")
    }

    func testAnswerSourcesShowTheirAddressBeforeOpening() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-mode=sources", "--chat-fixture-consented", "--reset-draft-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        app.show("chat")
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        input.typeText("What do recent sources say about attention?")
        app.buttons["chat.send"].tap()
        let first = app.buttons["chat.source.1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.label.contains("Attention Is All You Need"))
        XCTAssertTrue(app.buttons["chat.source.2"].exists, "A bare address is a source too")
        XCTAssertFalse(app.staticTexts["Sources:"].exists, "The list replaces the raw Sources text")
        if app.keyboards.count > 0, app.buttons["chat.dismissKeyboard"].exists { app.buttons["chat.dismissKeyboard"].tap() }
        first.tap()
        // Nothing opens until the reader has seen the full address.
        XCTAssertTrue(app.staticTexts["Open this source in Safari?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["https://arxiv.org/abs/1706.03762"].exists)
        capture(app, "Source address confirmation")
        // iPhone shows it as a popover without a Cancel button; tapping outside dismisses it.
        // A popover's own dismiss region is the reliable "outside" (the full-height chat moved the old tap point).
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else if app.otherElements["PopoverDismissRegion"].exists { app.otherElements["PopoverDismissRegion"].tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)).tap() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
            object: app.staticTexts["Open this source in Safari?"])], timeout: 5), .completed)
        XCTAssertEqual(app.state, .runningForeground, "Cancel leaves the reader in the app")
    }

    /// Launches the chat fixture in `mode` and asks one question in chat (the
    /// wide iPad layout has no tab bar; its general chat is a segment).
    private func askChatFixture(_ mode: String, _ question: String, extraArguments: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-mode=\(mode)", "--chat-fixture-consented", "--reset-draft-fixture"] + extraArguments
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        if app.buttons["tab.chat"].exists { app.show("chat") } else { app.segmentedControls["wide.mode"].buttons["General Chat"].tap() }
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        input.typeText(question)
        app.buttons["chat.send"].tap()
        return app
    }

    /// Scrolls the transcript until `element` is fully on screen.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, up: Bool) {
        let transcript = app.tables["chat.transcript"]
        let visible = { transcript.frame.insetBy(dx: -1, dy: -1).contains(element.frame) }
        for _ in 0..<8 where !visible() {
            if up { transcript.swipeDown(velocity: .slow) } else { transcript.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(visible(), "\(element.identifier) is on screen")
    }

    /// Audit gap 4: a Markdown table in an answer is a native table, read row by row.
    func testAnswerTableRendersAsATable() throws {
        let app = askChatFixture("research", "Compare the preference optimization objectives")
        let table = app.descendants(matching: .any)["chat.table.1"]
        XCTAssertTrue(table.waitForExistence(timeout: 20))
        XCTAssertTrue(table.label.contains("Table, 4 rows, 4 columns"), table.label)
        XCTAssertEqual(app.descendants(matching: .any)["chat.table.1.header"].label, "Columns: Method, Objective, Reward model, Win rate")
        XCTAssertTrue(app.descendants(matching: .any)["chat.table.1.row.2"].label.hasPrefix("Row 2: Method, DPO; Objective, -\\log"),
                      app.descendants(matching: .any)["chat.table.1.row.2"].label)
        XCTAssertTrue(app.descendants(matching: .any)["chat.table.1.row.4"].label.contains("v(x | y)"), "A pipe inside code stays in its cell")
        XCTAssertFalse(app.descendants(matching: .any)["chat.table.1.row.5"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "|:---")).firstMatch.exists,
                       "No pipe text remains once the answer is complete")
        // The text around the table is still read as the assistant's message, without its "Answer:" label.
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Assistant: This synthetic fixture")).firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Answer:")).firstMatch.exists)
        if app.keyboards.count > 0, app.buttons["chat.dismissKeyboard"].exists { app.buttons["chat.dismissKeyboard"].tap() }
        reveal(table, in: app, up: true)
        capture(app, "Answer table")
    }

    /// Owner feedback #10 and #3 (build 14), #4 (build 16): selecting answer text offers Quote in Chat, Explain and
    /// Define right after Copy; a formula offers Copy LaTeX and Copy as text, then the same actions.
    func testAnswerTextAndFormulasOfferChatActions() throws {
        let app = askChatFixture("answer", "Why scale by the square root of d_k?")
        let answer = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "chat.message.text.", "synthetic fixture answer")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 15))
        if app.keyboards.count > 0, app.buttons["chat.dismissKeyboard"].exists { app.buttons["chat.dismissKeyboard"].tap() }
        sleep(1)
        let item = { (title: String) in app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch }
        // Long-press the first word ("Scaling").
        answer.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 24, dy: 12)).press(forDuration: 1.2)
        XCTAssertTrue(item("Quote in Chat").waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Copy"].exists, "Copy stays first")
        XCTAssertLessThan(app.menuItems["Copy"].frame.minX, item("Quote in Chat").frame.minX)
        XCTAssertTrue(item("Explain").exists) // Define follows (on a narrow screen, after the menu's arrow)
        capture(app, "Answer text selection actions")
        item("Quote in Chat").tap()
        let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        let quoted = NSPredicate(format: "value BEGINSWITH %@", "About “Scaling”: ")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: quoted, object: composer)], timeout: 5), .completed,
                       String(describing: composer.value))
        if app.keyboards.count > 0, app.buttons["chat.dismissKeyboard"].exists { app.buttons["chat.dismissKeyboard"].tap() }
        sleep(1)
        // Long-press the inline formula after "Scaling by ".
        answer.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 112, dy: 12)).press(forDuration: 1.2)
        XCTAssertTrue(item("Copy LaTeX").waitForExistence(timeout: 5))
        XCTAssertTrue(item("Copy as text").exists)
        XCTAssertTrue(item("Quote in Chat").exists, "The same quote action as text")
        capture(app, "Formula actions")
    }

    /// Audit gap 9: while the server searches, a status line says so (in place of
    /// "Thinking…" before any text, then under the partial answer); it goes once text resumes.
    func testSearchProgressShowsUnderTheStreamingAnswer() throws {
        let app = askChatFixture("research", "What followed DPO?")
        let any = app.descendants(matching: .any)
        let thinking = any["chat.message.thinking"]
        XCTAssertTrue(thinking.waitForExistence(timeout: 10))
        let searching = NSPredicate(format: "label CONTAINS %@", "Searching the web for “direct preference optimization follow-ups”")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: searching, object: thinking)], timeout: 5), .completed, thinking.label)
        let progress = any["chat.message.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 20), "The second search shows under the partial answer")
        XCTAssertTrue(progress.label.contains("IPO KTO comparison") || progress.label == "Reading results…", progress.label)
        if app.keyboards.count > 0, app.buttons["chat.dismissKeyboard"].exists { app.buttons["chat.dismissKeyboard"].tap() }
        capture(app, "Search progress under a streaming answer")
        XCTAssertTrue(progress.waitForNonExistence(timeout: 20), "Cleared when text resumes")
        XCTAssertTrue(any["chat.papers"].waitForExistence(timeout: 20))
        XCTAssertFalse(progress.exists)
    }

    /// Audit gap 2: papers an answer names are listed under it, their identifier a link to the abstract page (after
    /// seeing the address), with Add to library; one only in Sources is not repeated.
    func testAnswerPapersCanBeOpenedOrAdded() throws {
        let app = askChatFixture("research", "Which papers should I read next?")
        let papers = app.descendants(matching: .any)["chat.papers"]
        XCTAssertTrue(papers.waitForExistence(timeout: 20))
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["chat.paper.1"].label.contains("Direct Preference Optimization: Your Language Model"), any["chat.paper.1"].label)
        XCTAssertTrue(any["chat.paper.1"].label.contains("arXiv 2305.18290"))
        XCTAssertTrue(any["chat.paper.2"].label.contains("A General Theoretical Paradigm"))
        XCTAssertTrue(any["chat.paper.3"].label.contains("Rank Analysis of Incomplete Block Designs, DOI 10.2307/2334029"), any["chat.paper.3"].label)
        XCTAssertFalse(any["chat.paper.4"].exists, "A paper only in Sources is not listed again")
        // Build 16 #9: no "Open" button; the identifier is the link to the abstract page.
        for number in 1...3 { XCTAssertTrue(app.buttons["chat.paper.\(number).open"].exists) }
        XCTAssertEqual(app.buttons["chat.paper.1.open"].label, "arXiv 2305.18290")
        XCTAssertEqual(app.buttons["chat.paper.3.open"].label, "DOI 10.2307/2334029")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Open", "Open arXiv")).firstMatch.exists)
        XCTAssertTrue(app.buttons["chat.paper.1.add"].exists)
        XCTAssertTrue(app.buttons["chat.paper.3.add"].exists, "A DOI can be added too")
        XCTAssertTrue(any["chat.paper.2.inLibrary"].exists)
        XCTAssertFalse(app.buttons["chat.paper.2.add"].exists, "A paper already in the library has no Add")
        if app.keyboards.count > 0, app.buttons["chat.dismissKeyboard"].exists { app.buttons["chat.dismissKeyboard"].tap() }
        reveal(papers, in: app, up: false)
        capture(app, "Papers in this answer")

        app.buttons["chat.paper.3.open"].tap()
        XCTAssertTrue(app.staticTexts["Open this paper in Safari?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["https://doi.org/10.2307/2334029"].exists)
        capture(app, "Paper address confirmation")
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)).tap() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
            object: app.staticTexts["Open this paper in Safari?"])], timeout: 5), .completed)
        XCTAssertEqual(app.state, .runningForeground)

        // The fixture has no server library: the add reports its outcome on the row.
        app.buttons["chat.paper.1.add"].tap()
        XCTAssertTrue(app.staticTexts["chat.paper.1.notice"].waitForExistence(timeout: 5))
        capture(app, "Add outcome on the row")
    }

    func testAnswerLibraryActionOpensSavedPaperAndRetainsOriginalDraft() throws {
        let app = askChatFixture("research", "A question before opening a saved paper", extraArguments: ["--chat-paper-navigation-fixture=ready"])
        let target = app.buttons["chat.paper.2.inLibrary"]
        XCTAssertTrue(target.waitForExistence(timeout: 20)); XCTAssertEqual(target.label, "Open in Library")
        let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        composer.tap(); composer.typeText("Keep my follow-up draft")
        if app.buttons["chat.dismissKeyboard"].exists { app.buttons["chat.dismissKeyboard"].tap() }
        reveal(target, in: app, up: false)
        capture(app, "Answer paper has an explicit Library action")
        target.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), "The saved paper opens inside the reader")
        if app.buttons["tab.library"].exists { app.show("library") } else { app.segmentedControls["wide.mode"].buttons["Library"].tap() }
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 5)); app.buttons[sampleID].tap()
        // Back to the general conversation the draft is in: the Chat tab, or the wide layout's General Chat (Reader
        // shows the paper's own chat beside it).
        if app.buttons["tab.chat"].exists { app.show("chat") } else { app.segmentedControls["wide.mode"].buttons["General Chat"].tap() }
        XCTAssertEqual(composer.value as? String, "Keep my follow-up draft")
        XCTAssertTrue(app.buttons["chat.paper.2.inLibrary"].waitForExistence(timeout: 5), "The original answer remains in its conversation")
        capture(app, "Original conversation and draft after Library action")
    }

    func testAnswerLibraryActionShowsPendingImportAndRetainsDraft() throws {
        let app = askChatFixture("research", "A question while a paper is importing", extraArguments: ["--chat-paper-navigation-fixture=pending"])
        let target = app.buttons["chat.paper.2.inLibrary"]
        XCTAssertTrue(target.waitForExistence(timeout: 20))
        let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        composer.tap(); composer.typeText("Keep this while it imports")
        if app.buttons["chat.dismissKeyboard"].exists { app.buttons["chat.dismissKeyboard"].tap() }
        reveal(target, in: app, up: false); target.tap()
        let search = app.searchFields["library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); XCTAssertEqual(search.value as? String, "2310.12036")
        // The import's step in the two words the Library uses (owner, 2026-10-15: "Downloading…", then "Adding…").
        let progress = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label CONTAINS[c] %@", "importProgress", "Adding")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5), "A queued paper opens its current progress")
        capture(app, "Answer Library action shows pending import")
        if app.buttons["tab.chat"].exists { app.show("chat") } else { app.segmentedControls["wide.mode"].buttons["General Chat"].tap() }
        XCTAssertEqual(composer.value as? String, "Keep this while it imports")
        XCTAssertTrue(app.buttons["chat.paper.2.inLibrary"].waitForExistence(timeout: 5))
    }

    /// Discovery audit (records every issue, fails on none): Library, reader,
    /// chat with an answer and diagram, the diagram itself, and Settings.
    /// Run with `TEST_RUNNER_SCIENCE_READER_AX_AUDIT=1 xcodebuild test …`; read the `AXAUDIT` lines.
    func testAccessibilityAuditOfMainScreens() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SCIENCE_READER_AX_AUDIT"] == "1", "Opt-in discovery audit")
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-mode=diagram", "--chat-fixture-consented", "--reset-draft-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        var report: [String] = []
        func audit(_ screen: String) throws {
            capture(app, "Audited: \(screen)")
            try app.performAccessibilityAudit { issue in
                let element = issue.element.map { "\($0.elementType.rawValue) id=\($0.identifier) label=\($0.label.prefix(60))" } ?? "-"
                report.append("AXAUDIT \(screen) | \(issue.auditType.rawValue) | \(issue.compactDescription) | \(element)")
                return true
            }
        }
        try audit("Library")
        app.buttons[sampleID].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        try audit("Reader")
        app.show("chat")
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        input.typeText("Draw the attention computation")
        app.buttons["chat.send"].tap()
        let open = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.diagram.")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        if app.keyboards.count > 0, app.buttons["chat.dismissKeyboard"].exists { app.buttons["chat.dismissKeyboard"].tap() }
        try audit("Chat")
        open.tap()
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["Softmax"].waitForExistence(timeout: 10))
        try audit("Diagram")
        app.buttons["Done"].tap()
        app.show("settings")
        try audit("Settings")
        let attachment = XCTAttachment(string: report.joined(separator: "\n"))
        attachment.name = "Accessibility audit"; attachment.lifetime = .keepAlways; add(attachment)
        for line in report { print(line) }
    }

    /// The compact tab bar hides behind the software keyboard; a keyboard closed
    /// in the wide layout must not leave it hidden after rotating back.
    func testTabletTabsReturnAfterKeyboardClosesInTheWideLayout() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Rotation between compact and wide layouts")
        let app = launch()
        // Portrait must be the compact layout (an 11-inch iPad, 834 pt); a 13-inch iPad is wide in both orientations.
        try XCTSkipUnless(app.buttons["tab.chat"].waitForExistence(timeout: 5), "This iPad is wide in portrait too: no tabs to return")
        app.show("chat")
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        input.typeText("Draft while rotating")
        XCTAssertFalse(app.buttons["tab.library"].exists, "Tabs sit behind the software keyboard")
        XCUIDevice.shared.orientation = .landscapeLeft
        let wide = NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: wide, object: nil)], timeout: 5), .completed)
        if app.buttons["chat.dismissKeyboard"].exists { app.buttons["chat.dismissKeyboard"].tap() }
        let closed = NSPredicate { _, _ in app.keyboards.count == 0 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: closed, object: nil)], timeout: 5), .completed)
        XCUIDevice.shared.portraitWhereSupported()
        XCTAssertTrue(app.buttons["tab.library"].waitForExistence(timeout: 5), "Tabs return once no keyboard is shown")
    }

    func testUnsentDraftsCanBeReopenedWithoutReplacingEachOther() throws {
        let app = launch()
        app.show("chat")
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        app.buttons["New chat"].tap()
        input.typeText("First unsent question")
        app.buttons["New chat"].tap()
        input.typeText("Second unsent question")
        for title in ["First unsent question", "Second unsent question"] {
            app.buttons["Chat history"].tap()
            XCTAssertTrue(app.staticTexts["Unsent drafts"].waitForExistence(timeout: 5))
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
            XCTAssertEqual(input.value as? String, title)
        }
    }

    func testTabletSplitChatKeepsLatestVisibleWhileComposing() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad split layout")
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        app.show("chat")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.segmentedControls["wide.mode"].buttons["Reader"].waitForExistence(timeout: 5))
        exerciseLatestReplyWhileComposing(app)
    }

    private func exerciseLatestReplyWhileComposing(_ app: XCUIApplication) {
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        assertFinalReplyAtBottom(app)
        input.tap(); input.typeText("First line")
        XCTAssertTrue(chatKeyboardDismissButton(in: app).waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(readingHeight(app), 80, "Keep a usable reading area above the keyboard")
        assertFinalReplyAtBottom(app)
        let singleLineHeight = input.frame.height
        input.typeText("\nSecond line\nThird line\nFourth line")
        XCTAssertEqual(input.value as? String, "First line\nSecond line\nThird line\nFourth line")
        XCTAssertGreaterThan(input.frame.height, singleLineHeight + 20, "Exercise an actual composer resize")
        XCTAssertGreaterThanOrEqual(readingHeight(app), 80, "Keep a usable reading area above the growing composer")
        assertFinalReplyAtBottom(app)
        capture(app, "Latest reply remains visible above multiline composer")
        chatKeyboardDismissButton(in: app).tap()
        assertFinalReplyAtBottom(app)
    }

    private func chatKeyboardDismissButton(in app: XCUIApplication) -> XCUIElement {
        // The composer has its own dismiss control on iPhone; iPad keeps the keyboard's system key.
        UIDevice.current.userInterfaceIdiom == .pad
            ? app.keyboards.buttons["Hide keyboard"].firstMatch : app.buttons["chat.dismissKeyboard"]
    }

    func testChatPreservesScrollbackThroughKeyboardAndComposerResize() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone keyboard geometry; iPad uses the testTabletSplitChat… variants (fails on iPad at 4d8d4ff too)")
        let app = launch()
        app.show("chat")
        try exerciseScrollbackWhileComposing(app)
    }

    func testChatInteractiveKeyboardDismissalPreservesFinalReadingPosition() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone keyboard geometry; iPad uses the testTabletSplitChat… variants (fails on iPad at 4d8d4ff too)")
        let app = launch()
        app.show("chat")
        let transcript = app.tables["chat.transcript"]
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        input.tap(); input.typeText("Keep this draft")
        assertFinalReplyAtBottom(app)

        // Drag from the transcript through the keyboard so the native gesture
        // changes the reading position and viewport in the same interaction.
        let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.88))
        start.press(forDuration: 0.05, thenDragTo: end)
        let dismissed = NSPredicate { _, _ in app.keyboards.count == 0 && !app.buttons["chat.dismissKeyboard"].isHittable }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: dismissed, object: nil)], timeout: 5), .completed)
        XCTAssertEqual(input.value as? String, "Keep this draft")
        XCTAssertTrue(app.buttons["chat.latest"].isHittable, "The drag leaves the reader in scrollback")

        let visible = transcript.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.text."))
            .allElementsBoundByIndex.first { $0.frame.maxY > transcript.frame.minY && $0.frame.minY < transcript.frame.maxY }
        let passageID = try XCTUnwrap(visible?.identifier, "The final gesture position must contain a readable message")
        let passage = transcript.descendants(matching: .any).matching(identifier: passageID).firstMatch
        let readingOffset = passage.frame.minY - transcript.frame.minY
        input.tap(); input.typeText("\nAnother line\nA third line")
        XCTAssertTrue(app.buttons["chat.dismissKeyboard"].waitForExistence(timeout: 5))
        XCTAssertEqual(passage.frame.minY - transcript.frame.minY, readingOffset, accuracy: 4)
        let editedDraft = input.value as? String ?? ""
        XCTAssertEqual(editedDraft.replacingOccurrences(of: "\nAnother line\nA third line", with: ""), "Keep this draft")
        capture(app, "Interactive dismissal keeps the final reading position")
        app.buttons["chat.dismissKeyboard"].tap()
        XCTAssertEqual(passage.frame.minY - transcript.frame.minY, readingOffset, accuracy: 4)
    }

    func testChatTextSelectionOffersCopyWithoutLosingDraftOrContext() throws {
        let app = launch()
        app.show("chat")
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        input.tap(); input.typeText("Draft survives copying")
        app.buttons["chat.dismissKeyboard"].tap()
        assertFinalReplyAtBottom(app)
        finalReply(in: app).press(forDuration: 1)
        let copy = app.menuItems["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Hosted message text should expose the native Copy action")
        capture(app, "Chat text exposes native Copy")
        copy.tap()
        XCTAssertFalse(copy.isHittable)
        XCTAssertEqual(input.value as? String, "Draft survives copying")
        XCTAssertEqual(chatContext(app), "Paper chat")
        XCTAssertTrue(app.navigationBars["Understanding attention"].exists)
    }

    func testTabletSplitChatPreservesScrollbackWhileComposing() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad split layout")
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        app.show("chat")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.segmentedControls["wide.mode"].buttons["Reader"].waitForExistence(timeout: 5))
        try exerciseScrollbackWhileComposing(app)
    }

    private func exerciseScrollbackWhileComposing(_ app: XCUIApplication) throws {
        let transcript = app.tables["chat.transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        let olderReply = transcript.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "chat.message.text.", "Self-attention compares")).firstMatch
        // Leave the latest message for the older reply. A tall chat column (a 13-inch iPad in landscape) shows the older
        // reply from the bottom: keep scrolling back until Latest is offered.
        let latest = app.buttons["chat.latest"]
        for _ in 0..<6 {
            if olderReply.exists, olderReply.frame.maxY > transcript.frame.minY, olderReply.frame.minY < transcript.frame.maxY,
               latest.exists, latest.isHittable { break }
            transcript.swipeDown()
        }
        try XCTSkipUnless(latest.exists && latest.isHittable, "The whole conversation fits this chat column: nothing to scroll back from")
        XCTAssertTrue(olderReply.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(olderReply.frame.maxY, transcript.frame.minY)
        XCTAssertLessThan(olderReply.frame.minY, transcript.frame.maxY)
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        let readingOffset = olderReply.frame.minY - transcript.frame.minY
        XCTAssertTrue(app.buttons["chat.latest"].isHittable, "Reader deliberately left the latest message")
        input.tap(); input.typeText("A draft while reading")
        XCTAssertTrue(chatKeyboardDismissButton(in: app).waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(readingHeight(app), 80, "Keep the older passage readable while composing")
        XCTAssertEqual(olderReply.frame.minY - transcript.frame.minY, readingOffset, accuracy: 4)
        input.typeText("\nSecond line\nThird line")
        XCTAssertEqual(olderReply.frame.minY - transcript.frame.minY, readingOffset, accuracy: 4)
        capture(app, "Earlier passage stays put while composing")
        chatKeyboardDismissButton(in: app).tap()
        XCTAssertEqual(olderReply.frame.minY - transcript.frame.minY, readingOffset, accuracy: 4)
        app.buttons["chat.latest"].tap()
        assertFinalReplyAtBottom(app)

        // Returning naturally to the end must resume following even when the
        // final visibility callback arrives after the scroll phase becomes idle.
        transcript.swipeDown()
        XCTAssertTrue(app.buttons["chat.latest"].isHittable)
        for _ in 0..<5 {
            if !app.buttons["chat.latest"].isHittable { break }
            transcript.swipeUp()
        }
        assertFinalReplyAtBottom(app)
        input.tap()
        XCTAssertTrue(chatKeyboardDismissButton(in: app).waitForExistence(timeout: 5))
        assertFinalReplyAtBottom(app)
        capture(app, "Natural return to latest resumes keyboard following")
        chatKeyboardDismissButton(in: app).tap()
        assertFinalReplyAtBottom(app)
    }

    func testRepeatedContentsAndPaperChatRestoreReadingLocation() throws {
        let app = launch()
        app.buttons[sampleID].tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 5))
        let headingName = "2. Read the equations in context"
        func jump() {
            app.buttons["Table of contents"].tap()
            let option = app.buttons[headingName]
            XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
        }
        func assertAtHeading() {
            let heading = web.staticTexts[headingName].firstMatch
            let arrived = NSPredicate { _, _ in
                heading.exists && heading.isHittable && abs(heading.frame.minY - web.frame.minY) < 60
            }
            expectation(for: arrived, evaluatedWith: nil)
            waitForExpectations(timeout: 6)
        }
        jump(); assertAtHeading()
        web.swipeUp(); web.swipeUp()
        jump(); assertAtHeading()
        app.show("chat")
        app.returnToPaper()
        XCTAssertTrue(web.waitForExistence(timeout: 5)); assertAtHeading()
        capture(app, "Reader returns to the same passage")
    }

    func testTouchEquationActionsSaveExactMathAndReturnToThePassage() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--draft-fixture", "--reset-draft-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        app.buttons[sampleID].tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 5))
        app.buttons["Table of contents"].tap()
        let headingName = "2. Read the equations in context"
        let headingButton = app.buttons[headingName]
        XCTAssertTrue(headingButton.waitForExistence(timeout: 5)); headingButton.tap()
        let before = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Scaled dot-product attention turns")).firstMatch
        let after = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "The normalization in Equation")).firstMatch
        XCTAssertTrue(before.waitForExistence(timeout: 5)); XCTAssertTrue(after.waitForExistence(timeout: 5))
        let arrived = NSPredicate { _, _ in before.isHittable && after.isHittable && after.frame.minY > before.frame.maxY + 20 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: arrived, object: nil)], timeout: 5), .completed)
        func tapEquation() {
            // This authored fixture has one display equation between these
            // paragraphs. Use a real touch in its measured screen interval.
            let y = (before.frame.maxY + after.frame.minY) / 2 - web.frame.minY
            web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: web.frame.width / 2, dy: y)).tap()
        }
        // Build 16 #4: a tapped equation opens the same edit menu as selected text, beside it.
        let define = app.editMenuItem("Explain in Chat")
        let equationY = (before.frame.maxY + after.frame.minY) / 2 - web.frame.minY
        let right = web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: web.frame.width * 0.8, dy: equationY))
        let left = web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: web.frame.width * 0.2, dy: equationY))
        right.press(forDuration: 0.05, thenDragTo: left)
        XCTAssertFalse(define.exists, "Panning a wide equation must not activate its actions")
        capture(app, "Wide equation pans without activating actions")
        left.press(forDuration: 0.05, thenDragTo: right)
        tapEquation()
        XCTAssertTrue(app.revealEditMenuItem("Explain in Chat").exists, "A touch on SVG math must open the edit menu")
        XCTAssertTrue(app.editMenuItem("Copy LaTeX").exists, "Copy comes first for an equation too")
        let copyLatex = app.editMenuItem("Copy LaTeX").frame
        XCTAssertTrue(copyLatex.minX < define.frame.minX || copyLatex.minY < define.frame.minY, "Copy LaTeX comes first")
        XCTAssertFalse(app.buttons["reader.selection.define"].exists, "No selection bar under the paper")
        capture(app, "Touching an equation offers the edit menu with the paper's actions")
        // Tapping the page outside it closes the menu and unselects the equation.
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(define.waitForNonExistence(timeout: 5))
        let location = before.frame.minY - web.frame.minY
        tapEquation(); XCTAssertTrue(app.revealEditMenuItem("Explain in Chat").exists); define.tap()
        let question = app.tables["chat.transcript"].descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "chat.message.text.", #"\begin{equation}"#)).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 8), "The exact equation environment reaches encrypted local chat")
        XCTAssertEqual(chatContext(app), "Paper chat")
        app.buttons["chat.returnToPaper"].tap()
        XCTAssertTrue(before.waitForExistence(timeout: 5))
        XCTAssertEqual(before.frame.minY - web.frame.minY, location, accuracy: 6)
        XCTAssertFalse(define.exists)
        capture(app, "Equation question returns to the same passage")
    }

    func testFigureSheetUsesOfflineImageAndReturnsToItsReadingPosition() throws {
        let app = launch()
        app.buttons[sampleID].tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 5))
        app.buttons["Table of contents"].tap()
        let section = app.buttons["2. Read the equations in context"]
        XCTAssertTrue(section.waitForExistence(timeout: 5)); section.tap()
        let figure = web.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open figure: Queries and keys")).firstMatch
        for _ in 0..<10 {
            if figure.exists, figure.isHittable, figure.frame.minY >= web.frame.minY, figure.frame.minY < web.frame.maxY - 80 { break }
            web.swipeUp()
        }
        XCTAssertTrue(figure.waitForExistence(timeout: 5)); XCTAssertTrue(figure.isHittable)
        let readingOffset = figure.frame.minY - web.frame.minY
        figure.tap()
        // The figure sheet's X (DESIGN.md "Sheet top row").
        let done = app.buttons["sheet.close"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Couldn’t open figure"].exists)
        let detail = app.webViews.allElementsBoundByIndex.last!
        let image = detail.images.firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(image.frame.minY, done.frame.maxY, "The dismiss control must not cover the figure at large text sizes")
        let caption = detail.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Figure 1. A simplified attention data flow.")).firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 5)); XCTAssertTrue(caption.isHittable)
        capture(app, "Offline figure and readable caption in the detail sheet")
        done.tap()
        XCTAssertTrue(figure.waitForExistence(timeout: 5))
        XCTAssertEqual(figure.frame.minY - web.frame.minY, readingOffset, accuracy: 6)
        capture(app, "Closing the figure preserves the paper position")
    }

    func testTouchTextSelectionKeepsEveryActionReachable() throws {
        let app = launch()
        app.buttons[sampleID].tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 5))
        app.buttons["Table of contents"].tap()
        let section = app.buttons["1. Start with the question"]
        XCTAssertTrue(section.waitForExistence(timeout: 5)); section.tap()
        let paragraph = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A useful first pass identifies")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5)); XCTAssertTrue(paragraph.isHittable)
        let point = web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: paragraph.frame.minX - web.frame.minX + 55, dy: paragraph.frame.minY - web.frame.minY + 18))
        point.press(forDuration: 1)
        // Build 16 #5: the system edit menu, Copy first, then the paper's actions in plain words; no bar under the paper.
        let copy = app.editMenuItem("Copy"), explain = app.editMenuItem("Explain in Chat")
        XCTAssertTrue(explain.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(copy.exists, "Copy stays in the menu")
        XCTAssertTrue(copy.frame.minX < explain.frame.minX || copy.frame.minY < explain.frame.minY, "Copy comes first")
        XCTAssertFalse(app.buttons["reader.selection.define"].exists, "No selection bar under the paper")
        capture(app, "Native text selection with the paper's actions in the edit menu")
        for title in ["Why it matters", "Related papers", "Add paper"] {
            let item = app.revealEditMenuItem(title)
            XCTAssertTrue(item.exists && item.isHittable, "\(title) is reachable in the menu")
        }
        capture(app, "Edit menu, every paper action reachable")
        // Tapping elsewhere closes the menu and the selection: at the text column's right edge, beside the menu (on an
        // iPad the full menu opens under the selection, across the column's middle).
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.15)).tap()
        XCTAssertTrue(app.editMenuItem("Explain in Chat").waitForNonExistence(timeout: 5))
        // An action runs on the passage.
        point.press(forDuration: 1)
        app.revealEditMenuItem("Explain in Chat").tap()
        // Signed out (this fixture), the question waits in the message box behind Sign in.
        let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        let asked = NSPredicate(format: "value BEGINSWITH %@", "Explain in plain terms, including any symbols: useful")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: asked, object: composer)], timeout: 8), .completed,
                       "Explain in Chat asks about the selected passage: " + String(describing: composer.value))
    }

    func testBrowseAskShowsPaperChatOnTablet() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad split layout")
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        app.buttons[sampleID].tap()
        let introduction = app.webViews.firstMatch.staticTexts["An interactive reading sample · 2026"]
        XCTAssertTrue(introduction.waitForExistence(timeout: 5), "Wait for the reader presentation before rotating")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: nil)], timeout: 5) == .completed else {
            capture(app, "Interface did not rotate to landscape")
            XCTFail("The iPad interface remained in \(app.frame) after the device orientation changed")
            return
        }
        let browse = app.segmentedControls["wide.mode"].buttons["Browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 5), "Wait for the landscape layout to finish before selecting Browse")
        browse.tap()
        app.buttons["Paper options"].tap()
        app.buttons["Ask about this paper"].tap()
        XCTAssertTrue(app.segmentedControls["wide.mode"].buttons["Reader"].isSelected)
        // The paper is open beside its conversation, so the chat shows no separate link back to it.
        XCTAssertTrue(app.buttons["chat.context"].waitForExistence(timeout: 5))
        XCTAssertEqual(chatContext(app), "Paper chat")
        XCTAssertFalse(app.buttons["chat.returnToPaper"].exists)
        capture(app, "Browse opens reader and its conversation")
    }
}
