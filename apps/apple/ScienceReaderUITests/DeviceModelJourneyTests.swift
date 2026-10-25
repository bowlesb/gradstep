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
        app.launchArguments = ["--workflow-fixture", "--device-model-fixture", "-appearance", "light", "-reader.deviceModel", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        app.buttons[sampleID].tap()
        let original = app.webViews.firstMatch.staticTexts["An interactive reading sample · 2026"]
        XCTAssertTrue(original.waitForExistence(timeout: 10), "The paper opens in its own reading first")

        app.buttons["Paper options"].tap()
        let read = app.buttons["paper.deviceModel"]
        XCTAssertTrue(read.waitForExistence(timeout: 5), "The options offer the on-device model when the PDF is here")
        read.tap()
        // The models are a separate download (DEVICE_PDF_ROUTE.md "The models as a download"): the same place offers it
        // first when they are not on this device, then the reading starts by itself.
        let progress = app.descendants(matching: .any)["deviceModel.progress"]
        let banner = app.descendants(matching: .any)["deviceModel.banner"]
        let download = app.buttons["deviceModel.download"]
        /// The first of these to show, polled (a two-page reading can come and go between two waits).
        func first(of elements: [XCUIElement], within seconds: TimeInterval) -> XCUIElement? {
            let end = Date().addingTimeInterval(seconds)
            repeat { if let shown = elements.first(where: \.exists) { return shown } } while Date() < end
            return nil
        }
        var shown = first(of: [download, progress, banner], within: 10)
        if shown == download {
            XCTAssertTrue(download.label.contains("Download PDF reading model (about "), download.label)
            XCTAssertTrue(app.buttons["deviceModel.downloadCancel"].exists, "The offer can be dismissed")
            capture("Download the PDF reading model")
            download.tap()
            // The Simulator serves the pack from the build folder in a second or two; on a phone this is minutes.
            if app.staticTexts["Downloading PDF reading model"].exists { capture("Downloading the PDF reading model") }
            shown = first(of: [progress, banner], within: 600)
            XCTAssertNotNil(shown, "The reading starts once the model is in")
        }
        if shown == progress {
            XCTAssertTrue(app.buttons["deviceModel.stop"].exists || banner.exists, "A bar says what the model is doing and offers to stop")
            capture("On-device model at work")
        }

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

        // Settings › Experimental: one row (TestFlight 91 session), on now that the model is here; turning it off removes
        // the model (so the next run downloads again), and turning it on again asks before downloading.
        app.openSettingsFromMenu()
        let reader = app.switches["settings.deviceModel"]
        for _ in 0..<6 where !(reader.exists && reader.isHittable) { app.swipeUp() }
        XCTAssertTrue(reader.waitForExistence(timeout: 5), "Settings has the reader's row")
        XCTAssertEqual(reader.value as? String, "1", "On: chosen, and the model is on this device")
        capture("Settings: the reader is on")
        let control = reader.switches.firstMatch
        (control.exists ? control : reader).tap()
        XCTAssertEqual(reader.value as? String, "0")
        (control.exists ? control : reader).tap()
        XCTAssertTrue(app.alerts["Download the on-device PDF reader?"].waitForExistence(timeout: 5), "Removed, it asks to download again")
        app.alerts.buttons["Cancel"].firstMatch.tap()
        capture("Settings: the model is removed")
    }
}
