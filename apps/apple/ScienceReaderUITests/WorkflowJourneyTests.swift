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
        app.segmentedControls.buttons["arXiv"].tap()
        XCTAssertTrue(app.staticTexts["arXiv search is not connected"].waitForExistence(timeout: 5))
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
        let app = launch()
        app.buttons["tab.chat"].tap()
        exerciseScrollbackWhileComposing(app)
    }

    func testChatInteractiveKeyboardDismissalPreservesFinalReadingPosition() throws {
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

    func testBrowseAskShowsPaperChatOnTablet() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad split layout")
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        app.buttons[sampleID].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.segmentedControls.buttons["Browse"].tap()
        app.buttons["Paper options"].tap()
        app.buttons["Ask about this paper"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["Reader"].isSelected)
        XCTAssertTrue(app.buttons["chat.returnToPaper"].waitForExistence(timeout: 5))
        capture(app, "Browse opens reader and its conversation")
    }
}
