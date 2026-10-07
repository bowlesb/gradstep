import XCTest
import UIKit

/// Synthetic, local sign-in journeys. These do not test Apple/Google services,
/// mail delivery, hosted Auth configuration, or recovery-key enrollment.
@MainActor
final class AuthenticationWorkflowTests: XCTestCase {
    private let sampleID = "paper.aaaaaaaa-0000-0000-0000-000000000001"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ scenario: [String] = [], accessibility: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--authentication-fixture", "--reset-authentication-fixture"] + scenario + [
            "-appearance", accessibility ? "dark" : "light",
            "-UIPreferredContentSizeCategoryName", accessibility
                ? UIContentSizeCategory.accessibilityExtraLarge.rawValue : UIContentSizeCategory.large.rawValue
        ]
        app.launch()
        XCTAssertTrue(app.buttons[sampleID].waitForExistence(timeout: 10))
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Local auth fixture · " + name
        attachment.lifetime = .keepAlways; add(attachment)
    }

    private func wait(_ description: String, timeout: TimeInterval = 6,
                      file: StaticString = #filePath, line: UInt = #line,
                      _ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       description, file: file, line: line)
    }

    private func settings(_ app: XCUIApplication) {
        if app.buttons["tab.settings"].exists { app.buttons["tab.settings"].tap() }
        else {
            XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
            app.buttons["Settings"].tap()
        }
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    private func openFromSettings(_ app: XCUIApplication) {
        settings(app)
        let signIn = app.buttons["account.signIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5)); signIn.tap()
        XCTAssertTrue(app.buttons["auth.emailMethod"].waitForExistence(timeout: 5))
        wait("The sheet's actual window enables the provider controls") {
            app.buttons["auth.apple"].isEnabled && app.buttons["auth.google"].isEnabled
        }
        // One shape for every method (design audit F12) and Cancel on the left of a task sheet (F9).
        // (Compared with each other: iOS 26 draws a medium-height sheet slightly scaled, so 50 pt measures ~48.)
        if !app.launchArguments.contains(UIContentSizeCategory.accessibilityExtraLarge.rawValue) {
            let apple = app.buttons["auth.apple"].frame.height
            XCTAssertGreaterThanOrEqual(apple, 44)
            for identifier in ["auth.google", "auth.emailMethod"] {
                XCTAssertEqual(app.buttons[identifier].frame.height, apple, accuracy: 0.5, "\(identifier) matches the Apple button's height")
            }
        }
        XCTAssertLessThan(app.buttons["auth.close"].frame.midX, app.buttons["auth.google"].frame.midX, "Cancel sits on the left")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        let scroll = app.scrollViews.containing(.any, identifier: element.identifier).firstMatch
        for _ in 0..<5 {
            if element.isHittable { break }
            guard scroll.exists else { break }
            let above = element.frame.midY < scroll.frame.midY
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.3 : 0.75))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.75 : 0.3))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable, file: file, line: line)
    }

    private func replace(_ field: XCUIElement, with text: String, in app: XCUIApplication) {
        reveal(field, in: app); field.tap()
        let current = field.value as? String ?? ""
        if !current.isEmpty {
            // Deleting an empty field's placeholder is harmless, and avoids
            // depending on the platform's localized Select All edit menu.
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: min(current.count, 320)))
        }
        field.typeText(text)
    }

    private func beginEmail(_ app: XCUIApplication, address: String = "reader@example.invalid") {
        app.buttons["auth.emailMethod"].tap()
        replace(app.textFields["auth.email"], with: address, in: app)
        reveal(app.buttons["auth.sendCode"], in: app); app.buttons["auth.sendCode"].tap()
        XCTAssertTrue(app.textFields["auth.code"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["auth.codeEmail"].label, address)
        XCTAssertFalse(app.buttons["auth.resend"].isEnabled, "Initial resend has a separate cooldown")
    }

    private func enterCode(_ value: String, in app: XCUIApplication) {
        replace(app.textFields["auth.code"], with: value, in: app)
        reveal(app.buttons["auth.verify"], in: app)
    }

    private func acceptAfterCorrection(_ app: XCUIApplication) {
        beginEmail(app)
        enterCode("000000", in: app)
        app.buttons["auth.verify"].tap()
        let issue = app.staticTexts["auth.issue"]
        XCTAssertTrue(issue.waitForExistence(timeout: 5))
        XCTAssertTrue(issue.label.contains("code wasn’t accepted"))
        XCTAssertEqual(app.textFields["auth.code"].value as? String, "000000",
                       "A rejected code remains editable in the same owned challenge")
        reveal(issue, in: app)
        capture("Rejected code remains correctable")
        enterCode("654321", in: app)
        XCTAssertTrue(app.buttons["auth.verify"].isEnabled)
        app.buttons["auth.verify"].tap()
        XCTAssertTrue(app.staticTexts["Restore your private library"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["auth.close"].exists, "Recovery follows accepted sheet dismissal")
        XCTAssertFalse(app.staticTexts["Save your recovery code"].exists, "Existing key state must not create fresh keys")
        XCTAssertTrue(app.buttons["recovery.fromPasswords"].exists, "A code saved in Passwords can fill the recovery field")
        _ = recoverySignOut(app)
        capture("Accepted nil-email account requires recovery")
    }

    private func recoverySignOut(_ app: XCUIApplication,
                                file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        // Settings also has this identifier. Require the recovery sheet's own
        // toolbar, and allow its presentation transition to finish before tap.
        let signOut = app.navigationBars["Private library"].buttons["account.signOut"]
        let predicate = NSPredicate { _, _ in signOut.exists && signOut.isEnabled && signOut.isHittable }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 6)
        if result != .completed {
            capture("Recovery toolbar did not become interactive")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Synthetic recovery hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        XCTAssertEqual(result, .completed, "Recovery must provide an interactive Sign out action", file: file, line: line)
        return signOut
    }

    private func signOutFromRecovery(_ app: XCUIApplication) {
        recoverySignOut(app).tap()
        wait("Recovery closes after local account retirement") { !app.navigationBars["Private library"].exists }
        settings(app)
        XCTAssertTrue(app.buttons["account.signIn"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["account.signOut"].exists)
    }

    func testEmailCodeCorrectionAcceptsNilEmailAndRecoverySignOut() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone layout; iPad is covered by testTabletAuthenticationUsesABoundedReadableSheet (fails on iPad at 4d8d4ff too)")
        let app = launch(); defer { app.terminate() }
        openFromSettings(app)
        capture("Compact provider choices")
        acceptAfterCorrection(app)
        // The same synthetic account must resume through the real Keychain
        // session on launch, without a second token exchange or new keyring.
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-authentication-fixture" }
        app.launch()
        XCTAssertTrue(app.staticTexts["Restore your private library"].waitForExistence(timeout: 10))
        _ = recoverySignOut(app)
        signOutFromRecovery(app)
    }

    func testChangingEmailAndClosingPreservesTheOriginatingPaperDraft() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone layout; iPad is covered by testTabletAuthenticationUsesABoundedReadableSheet (fails on iPad at 4d8d4ff too)")
        let app = launch(); defer { app.terminate() }
        app.buttons[sampleID].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Paper options"].tap(); app.buttons["Ask about this paper"].tap()
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let draft = "A paper question to preserve while choosing how to sign in."
        input.tap(); input.typeText(draft)
        app.buttons["chat.dismissKeyboard"].tap()
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.buttons["auth.emailMethod"].waitForExistence(timeout: 5))
        beginEmail(app)
        replace(app.textFields["auth.code"], with: "123", in: app)
        reveal(app.buttons["auth.changeEmail"], in: app); app.buttons["auth.changeEmail"].tap()
        XCTAssertEqual(app.textFields["auth.email"].value as? String, "reader@example.invalid")
        replace(app.textFields["auth.email"], with: "another@example.invalid", in: app)
        reveal(app.buttons["auth.sendCode"], in: app); app.buttons["auth.sendCode"].tap()
        XCTAssertTrue(app.textFields["auth.code"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["auth.codeEmail"].label, "another@example.invalid")
        XCTAssertNotEqual(app.textFields["auth.code"].value as? String, "123")
        XCTAssertFalse(app.buttons["auth.verify"].isEnabled)
        app.buttons["auth.close"].tap()
        wait("Closing sign-in returns to the paper draft") { input.exists && input.value as? String == draft }
        XCTAssertTrue(app.segmentedControls.buttons["Paper chat"].isSelected)
        capture("Closing preserves the paper question")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.buttons["auth.emailMethod"].waitForExistence(timeout: 5))
        app.buttons["auth.emailMethod"].tap()
        XCTAssertTrue(app.textFields["auth.email"].waitForExistence(timeout: 5))
        XCTAssertFalse((app.textFields["auth.email"].value as? String ?? "").contains("@"),
                       "A new presentation must not retain the previous address or code")
        app.buttons["auth.close"].tap()
        XCTAssertTrue(app.buttons["chat.returnToPaper"].waitForExistence(timeout: 5))
        app.buttons["chat.returnToPaper"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5))
        capture("Closing returns to the original offline sample")
    }

    func testProviderCancellationAndFailureReturnToMethodChoices() {
        let app = launch(["--authentication-apple-cancel", "--authentication-google-fail"])
        defer { app.terminate() }
        openFromSettings(app)
        app.buttons["auth.apple"].tap()
        wait("Synthetic Apple cancellation returns to choices") {
            app.buttons["auth.google"].exists && app.buttons["auth.google"].isEnabled
        }
        XCTAssertFalse(app.staticTexts["auth.issue"].exists, "Provider cancellation is not an error alert")
        app.buttons["auth.google"].tap()
        XCTAssertTrue(app.staticTexts["auth.issue"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["auth.issue"].label.contains("Couldn’t open sign-in"))
        XCTAssertTrue(app.buttons["auth.apple"].isEnabled)
        XCTAssertTrue(app.buttons["auth.emailMethod"].isHittable)
        capture("Provider failure keeps all methods and Close available")
        app.buttons["auth.emailMethod"].tap()
        XCTAssertTrue(app.textFields["auth.email"].waitForExistence(timeout: 5))
        app.buttons["auth.close"].tap()
        XCTAssertTrue(app.buttons["account.signIn"].waitForExistence(timeout: 5))
    }

    func testEmailCodeAndRecoveryAtAccessibilityExtraLargeInDarkMode() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Phone layout; iPad is covered by testTabletAuthenticationUsesABoundedReadableSheet (fails on iPad at 4d8d4ff too)")
        // Compare actual rendered text in this same Simulator, not merely the
        // launch argument or the minimum button height (which is always 44pt).
        let introduction = "Keep your library and conversations in sync."
        let normalTextHeight: CGFloat = {
            let normal = launch(); defer { normal.terminate() }
            openFromSettings(normal)
            XCTAssertTrue(normal.staticTexts[introduction].waitForExistence(timeout: 5))
            return normal.staticTexts[introduction].frame.height
        }()
        XCTAssertGreaterThan(normalTextHeight, 0)
        let app = launch(accessibility: true); defer { app.terminate() }
        openFromSettings(app)
        XCTAssertTrue(app.staticTexts[introduction].waitForExistence(timeout: 5))
        let accessibleTextHeight = app.staticTexts[introduction].frame.height
        let sizes = XCTAttachment(string: "Normal text height: \(normalTextHeight)pt\nAccessibility text height: \(accessibleTextHeight)pt")
        sizes.name = "Rendered authentication text scaling"; sizes.lifetime = .keepAlways; add(sizes)
        XCTAssertGreaterThan(accessibleTextHeight, normalTextHeight * 1.5,
                             "The AX journey must actually render larger text, including its line wrapping")
        for identifier in ["auth.apple", "auth.google", "auth.emailMethod"] {
            let control = app.buttons[identifier]
            reveal(control, in: app)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            XCTAssertGreaterThanOrEqual(control.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX)
        }
        capture("Accessibility Extra Large dark provider choices")
        acceptAfterCorrection(app)
        signOutFromRecovery(app)
    }

    func testTabletAuthenticationUsesABoundedReadableSheet() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad sheet width")
        let app = launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        wait("The iPad interface actually rotates before checking sheet width") { app.frame.width > app.frame.height }
        openFromSettings(app)
        let google = app.buttons["auth.google"]
        XCTAssertGreaterThanOrEqual(google.frame.height, 44)
        XCTAssertLessThanOrEqual(google.frame.width, 470, "The form remains bounded inside an iPad sheet")
        capture("iPad bounded provider choices")
        beginEmail(app, address: "a.long.synthetic.research.address.for.sheet.wrapping@example.invalid")
        let address = app.staticTexts["auth.codeEmail"]
        XCTAssertTrue(address.isHittable)
        XCTAssertGreaterThanOrEqual(address.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(address.frame.maxX, app.frame.maxX)
        XCTAssertTrue(app.buttons["auth.close"].isHittable)
        capture("iPad code and captured email")
        app.buttons["auth.close"].tap()
    }
}
