import XCTest

/// ⋯ › Reader version details (owner, build 62: "a message you can access in top right… the version reader number for
/// this paper, the current version, and if it's more, the option to update it"), in place of a banner over the paper.
final class ReaderVersionTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testReaderVersionDetailsNameThisPapersAndTheAppsVersion() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        // The study fixture selects the arXiv HTML paper, compiled by this app's compiler.
        app.launchArguments = ["--workflow-fixture", "--study-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["tab.paper"].waitForExistence(timeout: 10) || app.segmentedControls["wide.mode"].buttons["Reader"].exists)
        app.show("paper")
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.descendants(matching: .any)["paper.fallbackNotice"].exists, "no banner over the paper")
        let options = app.buttons["Paper options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5)); options.tap()
        let details = app.buttons["paper.readerVersion"]
        XCTAssertTrue(details.waitForExistence(timeout: 5)); details.tap()
        let paperVersion = app.staticTexts["readerVersion.paper"], appVersion = app.staticTexts["readerVersion.app"]
        XCTAssertTrue(paperVersion.waitForExistence(timeout: 5))
        // The row reads as one element ("This paper, Version 16"): compare the version numbers.
        let number = { (label: String) in label.split(separator: " ").last.map(String.init) ?? "" }
        XCTAssertTrue(paperVersion.label.contains("Version "), paperVersion.label)
        XCTAssertEqual(number(paperVersion.label), number(appVersion.label), "the fixture paper was prepared by this app's reader")
        XCTAssertTrue(app.descendants(matching: .any)["readerVersion.latest"].exists, "nothing to update")
        XCTAssertFalse(app.buttons["readerVersion.update"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Reader version details"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["readerVersion.close"].tap()
        XCTAssertTrue(paperVersion.waitForNonExistence(timeout: 5))
    }
}
