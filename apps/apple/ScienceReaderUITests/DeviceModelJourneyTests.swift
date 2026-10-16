import XCTest

/// The experimental on-device PDF reader (docs/architecture/DEVICE_PDF_ROUTE.md) as a reader meets it: the paper's
/// options offer it, a bar shows what it is doing and how long it has taken, the reading opens in the same reader under
/// a banner that says what it is, and the banner leads back to the reading the paper had. The Simulator's PDF is a
/// generated two-page paper (`--device-model-fixture`); the recogniser does not load in the Simulator, so formulas would
/// show as images there.
@MainActor
final class DeviceModelJourneyTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testReadingAPaperWithTheOnDeviceModelAndGoingBack() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "--device-model-fixture", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        app.buttons[sampleID].tap()
        let original = app.webViews.firstMatch.staticTexts["An interactive reading sample · 2026"]
        XCTAssertTrue(original.waitForExistence(timeout: 10), "The paper opens in its own reading first")

        app.buttons["Paper options"].tap()
        let read = app.buttons["paper.deviceModel"]
        XCTAssertTrue(read.waitForExistence(timeout: 5), "The options offer the on-device model when the PDF is here")
        read.tap()
        let progress = app.descendants(matching: .any)["deviceModel.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 10), "A bar says what the model is doing")
        XCTAssertTrue(app.buttons["deviceModel.stop"].exists, "and offers to stop")
        capture("On-device model at work")

        let banner = app.descendants(matching: .any)["deviceModel.banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 180), "The model's reading opens under its banner")
        XCTAssertFalse(progress.exists)
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Introduction")).firstMatch.waitForExistence(timeout: 15),
                      "The reading is the PDF's own text")
        XCTAssertTrue(banner.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "pages in")).firstMatch.exists, "The banner says what it did")
        capture("Read by the on-device model")

        app.buttons["deviceModel.options"].tap()
        XCTAssertTrue(app.buttons["Report a problem with this reading"].waitForExistence(timeout: 5))
        app.buttons["Show the HTML reading"].tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 10), "Back to the paper's own reading")
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        capture("Back to the original reading")
    }
}
