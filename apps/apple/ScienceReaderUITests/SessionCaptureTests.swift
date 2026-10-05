import XCTest

/// Records a short test session in the Simulator (docs/SESSION_REVIEW.md):
/// start from Settings, a reading-and-chat journey with a deliberate repeated
/// tap and an error, then Stop. scripts/simulator-session.mjs runs it with a
/// Simulator screen recording and feeds the result to the review tool.
final class SessionCaptureTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    override func setUpWithError() throws { continueAfterFailure = false }

    func testRecordASessionAroundAJourney() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-mode=insufficient_credits", "--chat-fixture-consented", "--reset-draft-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))

        app.buttons["tab.settings"].tap()
        let voice = app.switches["session.voice"]
        for _ in 0..<6 where !(voice.exists && voice.isHittable) { app.swipeUp() }
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        if (voice.value as? String) == "1" { voice.switches.firstMatch.exists ? voice.switches.firstMatch.tap() : voice.tap() }
        app.buttons["session.start"].tap()
        // ReplayKit asks once per launch; accept if it does.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["Record Screen", "Record Screen & Microphone", "Allow"] where springboard.buttons[title].waitForExistence(timeout: 3) {
            springboard.buttons[title].tap(); break
        }
        let stop = app.buttons["session.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15), "The recorder controls appear")

        // A small journey: open the sample, ask a question that fails for credits, tap Get credits.
        app.buttons["tab.library"].tap()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 5)); app.buttons[sampleID].tap()
        sleep(2)
        app.buttons["tab.chat"].tap()
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        input.typeText("What is the main result?")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.buttons["chat.getCredits"].waitForExistence(timeout: 10))
        // A repeated tap on something that does nothing (the message text itself).
        let message = app.staticTexts["chat.answerIssue"]
        for _ in 0..<4 { message.tap() }
        if app.keyboards.count > 0, app.buttons["chat.dismissKeyboard"].exists { app.buttons["chat.dismissKeyboard"].tap() }
        app.buttons["chat.getCredits"].tap()
        XCTAssertTrue(app.navigationBars["Get credits"].waitForExistence(timeout: 5))
        sleep(1)
        app.buttons["Done"].tap()
        app.buttons["tab.settings"].tap()
        sleep(1)

        XCTAssertTrue(stop.waitForExistence(timeout: 5)); stop.tap()
        // The finished session is offered to share (AirDrop on a device).
        let shared = app.otherElements["ActivityListView"].waitForExistence(timeout: 30) || app.buttons["Close"].waitForExistence(timeout: 5)
        XCTAssertTrue(shared, "The share sheet appears with the session")
        if app.buttons["Close"].exists { app.buttons["Close"].tap() } else { app.swipeDown() }
    }
}
