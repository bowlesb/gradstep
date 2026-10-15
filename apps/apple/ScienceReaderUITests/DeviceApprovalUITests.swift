import XCTest

/// Settings › Account › Add a device and the "A new device is waiting" banner over local fixtures
/// (`--device-approval-fixture`: one waiting web browser built from public test keys; "Use test code" stands in for the
/// camera). The fixture approves only when the envelope opens with that browser's key.
@MainActor
final class DeviceApprovalUITests: XCTestCase {
    private let sample = "paper.aaaaaaaa-0000-0000-0000-000000000001"
    /// The fixture browser's number, computed independently in Node from its public test key and challenge.
    private let code = "511852"

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ extra: [String] = [], appearance: String = "light") -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-consented", "--reset-draft-fixture", "--device-approval-fixture",
                               "-appearance", appearance] + extra
        app.launch()
        XCTAssertTrue(app.buttons[sample].waitForExistence(timeout: 15))
        return app
    }

    private func openAddDevice(_ app: XCUIApplication) {
        if app.buttons["tab.settings"].exists { app.show("settings") } else { app.buttons["Settings"].tap() }
        XCTAssertTrue(app.buttons["account.row"].waitForExistence(timeout: 5))
        app.buttons["account.row"].tap()
        let add = app.buttons["account.addDevice"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.navigationBars["Add a device"].waitForExistence(timeout: 5))
    }

    private func attach(_ name: String) {
        let attached = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attached.name = name; attached.lifetime = .keepAlways; add(attached)
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)[id] }

    func testScanningABrowserShowsItsNumberAndApprovesIt() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            openAddDevice(app)
            let scan = app.buttons["addDevice.fixtureScan"]
            XCTAssertTrue(scan.waitForExistence(timeout: 5))
            XCTAssertTrue(element("addDevice.scanner", in: app).exists, "The camera area is the page's main content")
            XCTAssertTrue(app.buttons["addDevice.compareInstead"].exists)
            attach("Add a device (\(appearance))")
            scan.tap()

            let number = app.staticTexts["addDevice.code"]
            XCTAssertTrue(number.waitForExistence(timeout: 5))
            XCTAssertEqual(number.label.filter(\.isNumber), code, "The phone shows the browser's own number (read digit by digit)")
            XCTAssertTrue(app.staticTexts["Add this web browser?"].exists)
            XCTAssertTrue(app.buttons["addDevice.approve"].isHittable)
            attach("Confirm the number (\(appearance))")

            app.buttons["addDevice.approve"].tap()
            XCTAssertTrue(app.buttons["addDevice.done"].waitForExistence(timeout: 5), "The fixture opened the envelope with the browser's key")
            XCTAssertTrue(app.staticTexts["Web browser added"].exists)
            attach("Added (\(appearance))")
            app.buttons["addDevice.done"].tap()
            XCTAssertTrue(app.buttons["account.addDevice"].waitForExistence(timeout: 5), "Done returns to the Account page")
            app.terminate()
        }
    }

    func testAKeySubstitutedByTheServerIsRefused() {
        let app = launch(["--device-approval-fixture-swapped"])
        openAddDevice(app)
        let scan = app.buttons["addDevice.fixtureScan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        scan.tap()
        let message = app.staticTexts["addDevice.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(message.label.contains("doesn’t match the code you scanned"), message.label)
        XCTAssertFalse(app.buttons["addDevice.approve"].exists, "No way to approve a substituted key")
        XCTAssertFalse(app.staticTexts["addDevice.code"].exists)
        attach("Substituted key refused")
        app.buttons["addDevice.retry"].tap()
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
    }

    func testTheBannerReviewsAWaitingDeviceWithoutACamera() {
        let app = launch()
        let review = app.buttons["approvalBanner.review"]
        XCTAssertTrue(review.waitForExistence(timeout: 10), "A waiting request shows the banner")
        XCTAssertTrue(app.staticTexts["A new device is waiting"].exists)
        attach("Banner")
        review.tap()
        let number = app.staticTexts["addDevice.code"]
        XCTAssertTrue(number.waitForExistence(timeout: 5))
        XCTAssertEqual(number.label.filter(\.isNumber), code)
        XCTAssertTrue(app.staticTexts["Add this device?"].exists, "Without a scan the kind is unknown")
        XCTAssertTrue(app.buttons["addDevice.cancel"].label.contains("Not mine"))
        attach("Banner review")
        app.buttons["addDevice.approve"].tap()
        XCTAssertTrue(app.buttons["addDevice.done"].waitForExistence(timeout: 5))
        app.buttons["addDevice.done"].tap()
        XCTAssertTrue(review.waitForNonExistence(timeout: 10), "Nothing is waiting any more")
    }
}
