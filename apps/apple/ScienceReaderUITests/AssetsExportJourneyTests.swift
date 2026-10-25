import XCTest

/// Settings › Your assets › Download your assets (owner, build 82: "Need a download assets button") over the encrypted
/// draft fixture: a collection is made, the zip is put together on the device and offered with the share sheet. The zip's
/// own contents are checked byte for byte by the Core tests (AssetsExportTests); here the fixture build reports the paths
/// it wrote, so the journey checks that the collection made here is in it.
@MainActor
final class AssetsExportJourneyTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"
    private var current: XCUIApplication?

    override func setUpWithError() throws { continueAfterFailure = false }

    private func capture(_ name: String) {
        #if targetEnvironment(macCatalyst)
        let shot = current?.windows.firstMatch.screenshot() ?? XCUIScreen.main.screenshot()
        #else
        let shot = XCUIScreen.main.screenshot()
        #endif
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let folder = ProcessInfo.processInfo.environment["GS_SCREENSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }

    func testDownloadYourAssetsSharesAZipWithTheSnippets() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--draft-fixture", "--reset-draft-fixture"]
        app.launch()
        current = app
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 15))

        // A collection to find in the zip.
        let wide = app.wideShape
        app.show("notes")
        app.buttons["notes.new"].firstMatch.tap()
        let name = app.alerts.textFields.firstMatch.exists ? app.alerts.textFields.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.typeText("Export check")
        (app.alerts.buttons["Create"].exists ? app.alerts.buttons["Create"] : app.buttons["Create"]).tap()
        XCTAssertTrue(app.staticTexts["A place for your next idea"].waitForExistence(timeout: 10), "The new collection opens")
        if !wide { app.navigationBars.buttons.firstMatch.tap() }

        app.openSettingsFromMenu()
        let download = app.buttons["settings.downloadAssets"]
        for _ in 0..<8 where !(download.exists && download.isHittable) { app.swipeUp() }
        XCTAssertTrue(download.waitForExistence(timeout: 5), "Your assets ends with Download your assets")
        XCTAssertTrue(app.buttons["settings.notes"].exists, "Snippets is still in Your assets")
        XCTAssertTrue(app.buttons["settings.downloadAssets.info"].exists, "The ⓘ explains what is in it")
        capture("Your assets with Download your assets")

        download.tap()
        // The share sheet (the Mac's save panel is its own window).
        #if targetEnvironment(macCatalyst)
        let offered = app.sheets.firstMatch.waitForExistence(timeout: 30) || app.dialogs.firstMatch.waitForExistence(timeout: 5)
        #else
        let sheet = app.otherElements["ActivityListView"]
        let offered = sheet.waitForExistence(timeout: 30) || app.navigationBars["UIActivityContentView"].waitForExistence(timeout: 5)
            || app.buttons["Close"].waitForExistence(timeout: 5)
        #endif
        capture("Download your assets: offered")
        XCTAssertTrue(offered, "The zip is offered to share or save")

        let paths = (download.value as? String ?? "").components(separatedBy: "\n")
        XCTAssertTrue(paths.contains { $0.hasPrefix("Gradstep export ") && $0.hasSuffix("/README.md") }, "README first: \(paths)")
        XCTAssertTrue(paths.contains { $0.hasSuffix("/snippets/Export check.md") }, "The collection is in the zip: \(paths)")
        XCTAssertFalse(paths.contains { $0.lowercased().hasSuffix(".pdf") }, "No paper files")

        #if targetEnvironment(macCatalyst)
        app.typeKey(.escape, modifierFlags: [])
        #else
        if app.buttons["Close"].exists { app.buttons["Close"].tap() } else { app.swipeDown(velocity: .fast) }
        #endif
        XCTAssertTrue(download.waitForExistence(timeout: 10), "Back in Settings")
        XCTAssertTrue(download.isEnabled, "Ready for another export")
    }

    /// A chat's figure breakdown comes with its parts' pictures, cut here from this device's copy of the paper (owner,
    /// TestFlight 92: "Does this mean we don't sync picture content on our servers? Do we sync it across devices?"); the ⓘ
    /// says how, and nothing is said in a footer.
    func testFigureBreakdownsComeWithTheirPictures() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-mode=figure_parts", "--chat-fixture-consented", "--reset-draft-fixture"]
        app.launch()
        current = app
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 15))
        app.show("chat")
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        input.typeText("What does Figure 1 show?")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.message.figurePart.2"].waitForExistence(timeout: 15), "The breakdown's parts")
        if app.buttons["chat.dismissKeyboard"].exists { app.buttons["chat.dismissKeyboard"].tap() }

        app.openSettingsFromMenu()
        let download = app.buttons["settings.downloadAssets"]
        for _ in 0..<8 where !(download.exists && download.isHittable) { app.swipeUp() }
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        let info = app.buttons["settings.downloadAssets.info"]
        XCTAssertTrue(info.exists)
        info.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "each device cuts them from its own copy of the paper")).firstMatch
            .waitForExistence(timeout: 5), "The ⓘ answers whether pictures sync")
        capture("Download your assets: the ⓘ on figure breakdowns")
        app.tap(); app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()

        download.tap()
        #if targetEnvironment(macCatalyst)
        let offered = app.sheets.firstMatch.waitForExistence(timeout: 30) || app.dialogs.firstMatch.waitForExistence(timeout: 5)
        #else
        let offered = app.otherElements["ActivityListView"].waitForExistence(timeout: 30) || app.buttons["Close"].waitForExistence(timeout: 5)
        #endif
        XCTAssertTrue(offered, "The zip is offered")
        let paths = (download.value as? String ?? "").components(separatedBy: "\n")
        XCTAssertTrue(paths.contains { $0.contains("/breakdowns/") && $0.hasSuffix(".md") }, "The breakdown: \(paths)")
        XCTAssertEqual(paths.filter { $0.contains("/breakdowns/images/") && $0.hasSuffix(".png") }.count, 2, "Both parts' pictures: \(paths)")
        #if targetEnvironment(macCatalyst)
        app.typeKey(.escape, modifierFlags: [])
        #else
        if app.buttons["Close"].exists { app.buttons["Close"].tap() } else { app.swipeDown(velocity: .fast) }
        #endif
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["settings.downloadAssets.skipped"].exists, "Nothing left out is said as a footer")
        capture("Download your assets after a download with breakdowns")
    }
}
