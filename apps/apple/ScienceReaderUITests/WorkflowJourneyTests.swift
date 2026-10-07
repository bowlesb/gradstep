import XCTest
import UIKit

@MainActor
final class WorkflowJourneyTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    private func launch(additionalArguments: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture"] + additionalArguments
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func finalReply(in app: XCUIApplication) -> XCUIElement {
        app.tables["chat.transcript"].descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "chat.message.text.", "This is a synthetic conversation for layout testing")).firstMatch
    }

    private func assertFinalReplyAtBottom(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let reply = finalReply(in: app), transcript = app.tables["chat.transcript"]
        let visible = NSPredicate { _, _ in
            reply.exists && transcript.exists && reply.frame.maxY <= transcript.frame.maxY + 2
                && reply.frame.maxY > transcript.frame.minY + 2
                && !app.buttons["chat.latest"].isHittable
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visible, object: nil)], timeout: 5)
        XCTAssertEqual(result, .completed, "Final reply bottom \(reply.frame) should be inside transcript \(transcript.frame)", file: file, line: line)
    }

    func testSearchOpenReturnNoMatchesAndSeparateExternalScope() throws {
        let app = launch(), query = "  EVALUATION  "
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText(query)
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 5))
        app.buttons[sampleID].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5))
        app.buttons["tab.library"].tap()
        XCTAssertEqual(search.value as? String, query)
        capture(app, "Library retains query after reading")
        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: query.count) + "no-matching-paper")
        XCTAssertTrue(app.staticTexts["No matching papers"].waitForExistence(timeout: 5))
        app.buttons["search.clear"].tap()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 5))
        // The Library/arXiv switch belongs to searching: it shows while the field is active.
        if !app.segmentedControls.buttons["arXiv"].exists { search.tap() }
        XCTAssertTrue(app.segmentedControls.buttons["arXiv"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["arXiv"].tap()
        XCTAssertTrue(app.staticTexts["Find papers"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[sampleID].exists, "External search must never relabel local rows")
        app.segmentedControls.buttons["Library"].tap()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 5))
        capture(app, "Library populated and sparse metadata rows")
    }

    func testChatKeyboardContextHistoryAndReturnPreserveDrafts() throws {
        let app = launch()
        app.buttons["tab.chat"].tap()
        XCTAssertTrue(app.navigationBars["Understanding attention"].waitForExistence(timeout: 5))
        assertFinalReplyAtBottom(app)
        capture(app, "Paper conversation with realistic paragraphs")
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        input.tap(); input.typeText("Paper draft to keep")
        XCTAssertTrue(app.buttons["chat.dismissKeyboard"].waitForExistence(timeout: 5))
        assertFinalReplyAtBottom(app)
        capture(app, "Chat composer and keyboard")
        XCTAssertTrue(app.segmentedControls.buttons["General chat"].isHittable, "Keep context controls visible while composing")
        app.buttons["chat.dismissKeyboard"].tap()
        app.segmentedControls.buttons["General chat"].tap()
        input.tap(); input.typeText("General draft\nSecond line")
        app.buttons["chat.dismissKeyboard"].tap()
        app.segmentedControls.buttons["Paper chat"].tap()
        XCTAssertEqual(input.value as? String, "Paper draft to keep")
        app.buttons["Chat history"].tap()
        XCTAssertTrue(app.navigationBars["All chats"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertEqual(input.value as? String, "Paper draft to keep")
        app.buttons["chat.returnToPaper"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5))
        app.buttons["tab.chat"].tap()
        XCTAssertEqual(input.value as? String, "Paper draft to keep")
        app.buttons["New chat"].tap()
        XCTAssertNotEqual(input.value as? String, "Paper draft to keep")
        app.buttons["Chat history"].tap()
        app.buttons["Understanding attention"].tap()
        XCTAssertEqual(input.value as? String, "Paper draft to keep")
        app.segmentedControls.buttons["General chat"].tap()
        XCTAssertEqual(input.value as? String, "General draft\nSecond line")
    }

    func testChatKeepsLatestVisibleAsComposerGrowsAndKeyboardDismisses() throws {
        let app = launch()
        app.buttons["tab.chat"].tap()
        exerciseLatestReplyWhileComposing(app)
    }

    func testDeletedObservedReplyRetainsEarlierMessagesUntilSiblingIsChosen() throws {
        let app = launch(additionalArguments: ["--branch-fixture"])
        app.buttons["tab.chat"].tap()
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(app.segmentedControls.buttons["General chat"].isSelected)
        XCTAssertEqual(input.value as? String, "A separate general draft")
        app.buttons["Chat history"].tap()
        XCTAssertTrue(app.navigationBars["All chats"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.segmentedControls.buttons["Paper chat"].isSelected)
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
        app.segmentedControls.buttons["General chat"].tap()
        XCTAssertEqual(input.value as? String, "A separate general draft")
        app.segmentedControls.buttons["Paper chat"].tap()
        XCTAssertTrue(sibling.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "Draft for the retained paper discussion")
        XCTAssertTrue(app.buttons["chat.returnToPaper"].isHittable)
        capture(app, "Explicit sibling choice preserves paper draft and context")
    }

    func testEncryptedDraftsSurviveRelaunchAndSentTextDoesNotReturn() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let paperDraft = "Explain how attention scales."
        let generalDraft = "Compare retrieval methods."
        app.launchArguments = ["--draft-fixture", "--reset-draft-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        app.buttons["tab.chat"].tap()
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        func assertDraftSaved() {
            let status = app.staticTexts["chat.draftStatus"]
            let saved = NSPredicate { _, _ in status.exists && status.label == "Draft saved on this device" }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: saved, object: nil)], timeout: 8), .completed)
        }
        func assertComposerEmpty() {
            let empty = NSPredicate { _, _ in
                let value = input.value as? String ?? ""
                return (value.isEmpty || value == "Ask a question…") && !app.buttons["chat.send"].isEnabled
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: empty, object: nil)], timeout: 8), .completed)
        }
        func relaunch() {
            app.terminate()
            app.launchArguments = ["--draft-fixture"]
            app.launch()
            XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
            app.buttons["tab.chat"].tap()
        }
        func sentQuestion() -> XCUIElementQuery {
            app.tables["chat.transcript"].descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                "chat.message.text.", "You: \(paperDraft)"))
        }

        XCTAssertTrue(app.segmentedControls.buttons["Paper chat"].isSelected)
        input.tap(); input.typeText(paperDraft)
        assertDraftSaved()
        app.buttons["chat.dismissKeyboard"].tap()
        app.segmentedControls.buttons["General chat"].tap()
        input.tap(); input.typeText(generalDraft)
        assertDraftSaved()
        app.buttons["chat.dismissKeyboard"].tap()

        relaunch()
        XCTAssertEqual(input.value as? String, paperDraft)
        app.segmentedControls.buttons["General chat"].tap()
        XCTAssertEqual(input.value as? String, generalDraft)
        app.segmentedControls.buttons["Paper chat"].tap()
        XCTAssertEqual(input.value as? String, paperDraft)
        capture(app, "Encrypted paper and general drafts survive process relaunch")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(sentQuestion().firstMatch.waitForExistence(timeout: 8))
        assertComposerEmpty()

        // Restart after the send is locally visible; the transaction must have
        // consumed the captured draft even if a later receipt checkpoint lags.
        relaunch()
        app.buttons["Chat history"].tap()
        XCTAssertTrue(app.navigationBars["All chats"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[paperDraft].waitForExistence(timeout: 5))
        app.buttons[paperDraft].tap()
        XCTAssertTrue(sentQuestion().firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(sentQuestion().count, 1, "The saved question appears once after relaunch")
        assertComposerEmpty()
        app.segmentedControls.buttons["General chat"].tap()
        XCTAssertEqual(input.value as? String, generalDraft)
        app.segmentedControls.buttons["Paper chat"].tap()
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
        XCUIDevice.shared.orientation = .portrait
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
        XCTAssertTrue(unopenedRow.label.contains("Available offline") || unopenedRow.images["Available offline"].exists,
                      "A persisted download remains available before its decoded bundle is loaded.")
        capture(app, "Downloaded badge survives relaunch before loading paper")
        app.buttons[paperID].tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 8))
        app.buttons["Table of contents"].tap()
        let heading = app.buttons[journey.heading]
        // A real paper has more Contents rows than the medium detent shows, and
        // the list realizes rows lazily: scroll until the row exists.
        for _ in 0..<6 where !heading.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(heading.exists)
        if !heading.isHittable { app.swipeUp() }
        heading.tap()
        let before = web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", journey.before)).firstMatch
        let after = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", journey.after)).firstMatch
        let positioned = NSPredicate { _, _ in before.isHittable && after.isHittable && after.frame.minY > before.frame.maxY + 20 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: positioned, object: nil)], timeout: 5), .completed)
        let y = (before.frame.maxY + after.frame.minY) / 2 - web.frame.minY
        web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: web.frame.width / 2, dy: y)).tap()
        let define = app.buttons["reader.selection.define"]
        XCTAssertTrue(define.waitForExistence(timeout: 5))
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
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Couldn’t open figure"].exists)
        capture(app, "Figure reopened from encrypted local member bytes")
        done.tap()
        // A second process must recover the saved question as well as the paper.
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons[paperID].waitForExistence(timeout: 10))
        app.buttons[paperID].tap()
        XCTAssertTrue(web.waitForExistence(timeout: 8))
        app.buttons["tab.chat"].tap()
        app.buttons["Chat history"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", journey.latex)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.tap()
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        XCTAssertEqual(questions.count, 1, "The exact equation question is retained once after relaunch")
        capture(app, "Encrypted question restored alongside the installed paper")
    }

    func testAnAnswerDiagramOpensFromTheAnswerAndFromAllDiagrams() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-mode=diagram", "--chat-fixture-consented", "--reset-draft-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        app.buttons["tab.chat"].tap()
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        input.typeText("Draw the attention computation")
        app.buttons["chat.send"].tap()
        let open = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.diagram.")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        XCTAssertTrue(open.label.contains("Scaled dot-product attention"))
        open.tap()
        // Drawn on device by the bundled Mermaid; its SVG labels are readable text.
        let canvas = app.webViews.firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertTrue(canvas.staticTexts["Softmax"].waitForExistence(timeout: 10), "The diagram's nodes render")
        XCTAssertFalse(app.staticTexts["This diagram couldn’t be drawn."].exists)
        // The whole diagram is on screen and its labels are readable (it used to shrink to ~8 pt text).
        let last = canvas.staticTexts["Weighted values"]
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        XCTAssertTrue(canvas.frame.insetBy(dx: -1, dy: -1).contains(last.frame), "\(last.frame) is inside \(canvas.frame)")
        XCTAssertGreaterThanOrEqual(last.frame.height, 13, "diagram labels are readable")
        capture(app, "Diagram drawn from an answer")
        app.buttons["Done"].tap()
        // The tab bar sits behind the software keyboard, as with system tab bars.
        if app.keyboards.count > 0, app.buttons["chat.dismissKeyboard"].exists { app.buttons["chat.dismissKeyboard"].tap() }
        XCTAssertTrue(app.buttons["tab.library"].waitForExistence(timeout: 5))
        app.buttons["tab.library"].tap()
        app.buttons["Library options"].tap()
        app.buttons["All diagrams"].tap()
        let saved = app.buttons["Scaled dot-product attention"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.tap()
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["Softmax"].waitForExistence(timeout: 10))
        capture(app, "Diagram reopened from All diagrams")
    }

    func testNotEnoughCreditsOffersGetCredits() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-mode=insufficient_credits", "--chat-fixture-consented", "--reset-draft-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        app.buttons["tab.chat"].tap()
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
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-mode=sources", "--chat-fixture-consented", "--reset-draft-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        app.buttons["tab.chat"].tap()
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
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)).tap() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
            object: app.staticTexts["Open this source in Safari?"])], timeout: 5), .completed)
        XCTAssertEqual(app.state, .runningForeground, "Cancel leaves the reader in the app")
    }

    /// Discovery audit (records every issue, fails on none): Library, reader,
    /// chat with an answer and diagram, the diagram itself, and Settings.
    /// Run with `TEST_RUNNER_SCIENCE_READER_AX_AUDIT=1 xcodebuild test …`; read the `AXAUDIT` lines.
    func testAccessibilityAuditOfMainScreens() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SCIENCE_READER_AX_AUDIT"] == "1", "Opt-in discovery audit")
        XCUIDevice.shared.orientation = .portrait
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
        app.buttons["tab.chat"].tap()
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
        app.buttons["tab.settings"].tap()
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
        app.buttons["tab.chat"].tap()
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
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["tab.library"].waitForExistence(timeout: 5), "Tabs return once no keyboard is shown")
    }

    func testUnsentDraftsCanBeReopenedWithoutReplacingEachOther() throws {
        let app = launch()
        app.buttons["tab.chat"].tap()
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
        app.buttons["tab.chat"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.segmentedControls.buttons["Reader"].waitForExistence(timeout: 5))
        exerciseLatestReplyWhileComposing(app)
    }

    private func exerciseLatestReplyWhileComposing(_ app: XCUIApplication) {
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        assertFinalReplyAtBottom(app)
        input.tap(); input.typeText("First line")
        XCTAssertTrue(app.buttons["chat.dismissKeyboard"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.tables["chat.transcript"].frame.height, 80, "Keep a usable reading area above the keyboard")
        assertFinalReplyAtBottom(app)
        let singleLineHeight = input.frame.height
        input.typeText("\nSecond line\nThird line\nFourth line")
        XCTAssertEqual(input.value as? String, "First line\nSecond line\nThird line\nFourth line")
        XCTAssertGreaterThan(input.frame.height, singleLineHeight + 20, "Exercise an actual composer resize")
        XCTAssertGreaterThanOrEqual(app.tables["chat.transcript"].frame.height, 80, "Keep a usable reading area above the growing composer")
        assertFinalReplyAtBottom(app)
        capture(app, "Latest reply remains visible above multiline composer")
        app.buttons["chat.dismissKeyboard"].tap()
        assertFinalReplyAtBottom(app)
    }

    func testChatPreservesScrollbackThroughKeyboardAndComposerResize() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone keyboard geometry; iPad uses the testTabletSplitChat… variants (fails on iPad at 4d8d4ff too)")
        let app = launch()
        app.buttons["tab.chat"].tap()
        exerciseScrollbackWhileComposing(app)
    }

    func testChatInteractiveKeyboardDismissalPreservesFinalReadingPosition() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone keyboard geometry; iPad uses the testTabletSplitChat… variants (fails on iPad at 4d8d4ff too)")
        let app = launch()
        app.buttons["tab.chat"].tap()
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
        app.buttons["tab.chat"].tap()
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
        XCTAssertTrue(app.segmentedControls.buttons["Paper chat"].isSelected)
        XCTAssertTrue(app.navigationBars["Understanding attention"].exists)
    }

    func testTabletSplitChatPreservesScrollbackWhileComposing() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad split layout")
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        app.buttons["tab.chat"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.segmentedControls.buttons["Reader"].waitForExistence(timeout: 5))
        exerciseScrollbackWhileComposing(app)
    }

    private func exerciseScrollbackWhileComposing(_ app: XCUIApplication) {
        let transcript = app.tables["chat.transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        let olderReply = transcript.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "chat.message.text.", "Self-attention compares")).firstMatch
        for _ in 0..<5 {
            if olderReply.exists, olderReply.frame.maxY > transcript.frame.minY, olderReply.frame.minY < transcript.frame.maxY { break }
            transcript.swipeDown()
        }
        XCTAssertTrue(olderReply.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(olderReply.frame.maxY, transcript.frame.minY)
        XCTAssertLessThan(olderReply.frame.minY, transcript.frame.maxY)
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        let readingOffset = olderReply.frame.minY - transcript.frame.minY
        XCTAssertTrue(app.buttons["chat.latest"].isHittable, "Reader deliberately left the latest message")
        input.tap(); input.typeText("A draft while reading")
        XCTAssertTrue(app.buttons["chat.dismissKeyboard"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(transcript.frame.height, 80, "Keep the older passage readable while composing")
        XCTAssertEqual(olderReply.frame.minY - transcript.frame.minY, readingOffset, accuracy: 4)
        input.typeText("\nSecond line\nThird line")
        XCTAssertEqual(olderReply.frame.minY - transcript.frame.minY, readingOffset, accuracy: 4)
        capture(app, "Earlier passage stays put while composing")
        app.buttons["chat.dismissKeyboard"].tap()
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
        XCTAssertTrue(app.buttons["chat.dismissKeyboard"].waitForExistence(timeout: 5))
        assertFinalReplyAtBottom(app)
        capture(app, "Natural return to latest resumes keyboard following")
        app.buttons["chat.dismissKeyboard"].tap()
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
        app.buttons["tab.chat"].tap()
        app.buttons["chat.returnToPaper"].tap()
        XCTAssertTrue(web.waitForExistence(timeout: 5)); assertAtHeading()
        capture(app, "Reader returns to the same passage")
    }

    func testTouchEquationActionsSaveExactMathAndReturnToThePassage() throws {
        XCUIDevice.shared.orientation = .portrait
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
        let define = app.buttons["reader.selection.define"]
        let equationY = (before.frame.maxY + after.frame.minY) / 2 - web.frame.minY
        let right = web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: web.frame.width * 0.8, dy: equationY))
        let left = web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: web.frame.width * 0.2, dy: equationY))
        right.press(forDuration: 0.05, thenDragTo: left)
        XCTAssertFalse(define.exists, "Panning a wide equation must not activate its actions")
        capture(app, "Wide equation pans without activating actions")
        left.press(forDuration: 0.05, thenDragTo: right)
        tapEquation()
        XCTAssertTrue(define.waitForExistence(timeout: 5), "A touch on SVG math must expose the native actions")
        capture(app, "Touching an equation offers the paper selection actions")
        app.buttons["reader.selection.clear"].tap()
        XCTAssertFalse(define.exists)
        let location = before.frame.minY - web.frame.minY
        tapEquation(); XCTAssertTrue(define.waitForExistence(timeout: 5)); define.tap()
        let question = app.tables["chat.transcript"].descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "chat.message.text.", #"\begin{equation}"#)).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 8), "The exact equation environment reaches encrypted local chat")
        XCTAssertTrue(app.segmentedControls.buttons["Paper chat"].isSelected)
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
        let done = app.buttons["Done"]
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
        XCTAssertTrue(app.buttons["reader.selection.define"].waitForExistence(timeout: 5))
        for action in ["define", "relevance", "similar", "ingest", "clear"] {
            let button = app.buttons["reader.selection." + action]
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertGreaterThanOrEqual(button.frame.minX, 0)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX)
        }
        if app.buttons["reader.selection.relevance"].frame.minY >= app.buttons["reader.selection.define"].frame.maxY {
            for action in ["relevance", "similar", "ingest"] {
                XCTAssertGreaterThanOrEqual(app.buttons["reader.selection." + action].frame.width, app.frame.width - 56,
                    "A full-width fallback row should be tappable across the row")
            }
        }
        capture(app, "Native text selection with all paper actions reachable")
        app.buttons["reader.selection.clear"].tap()
        XCTAssertFalse(app.buttons["reader.selection.define"].exists)
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
        let browse = app.segmentedControls.buttons["Browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 5), "Wait for the landscape layout to finish before selecting Browse")
        browse.tap()
        app.buttons["Paper options"].tap()
        app.buttons["Ask about this paper"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["Reader"].isSelected)
        // The paper is open beside its conversation, so the chat shows no separate link back to it.
        XCTAssertTrue(app.segmentedControls.buttons["Paper chat"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.buttons["Paper chat"].isSelected)
        XCTAssertFalse(app.buttons["chat.returnToPaper"].exists)
        capture(app, "Browse opens reader and its conversation")
    }
}
