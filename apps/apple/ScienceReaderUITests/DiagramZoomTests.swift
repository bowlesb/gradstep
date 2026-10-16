import XCTest

/// A diagram at full size zooms with two fingers (owner, build 62: "Zooming with two fingers should work well here but it
/// doesn't"): it opens at its own size or fitted to the width, never off the left edge, and pinches up to 8×.
@MainActor
final class DiagramZoomTests: XCTestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testAFullSizeDiagramPinchesToZoom() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-mode=diagram", "--chat-fixture-consented", "--reset-draft-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["paper.aaaaaaaa-0000-0000-0000-000000000001"].waitForExistence(timeout: 10))
        app.show("chat")
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        input.typeText("Draw the attention computation")
        app.buttons["chat.send"].tap()
        let open = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.diagram.")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        XCTAssertTrue(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in open.frame.height > 120 }, object: nil)],
                                       timeout: 15) == .completed)
        open.tap()
        let canvas = app.webViews.containing(NSPredicate(format: "label == %@", "Softmax")).firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        let label = canvas.staticTexts["Softmax"]
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        let before = label.frame
        XCTAssertGreaterThanOrEqual(before.minX, canvas.frame.minX - 1, "nothing starts off the left edge")
        capture(app, "Diagram full size, before zooming")
        canvas.pinch(withScale: 3, velocity: 2)
        sleep(1)
        let after = canvas.staticTexts["Softmax"].frame
        XCTAssertGreaterThan(after.height, before.height * 1.6, "two fingers zoom in: \(before) → \(after)")
        capture(app, "Diagram zoomed in")
        canvas.pinch(withScale: 0.2, velocity: -2)
        sleep(1)
        let back = canvas.staticTexts["Softmax"].frame
        XCTAssertLessThan(back.height, after.height * 0.8, "and back out: \(after) → \(back)")
    }
}
