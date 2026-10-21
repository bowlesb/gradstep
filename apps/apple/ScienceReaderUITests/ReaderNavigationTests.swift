import XCTest
import UIKit

@MainActor
final class ReaderNavigationTests: XCTestCase {
    func testLibraryStartsFirstAndReaderWorksOffline() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.searchFields["library.search"].waitForExistence(timeout: 10), "The app starts in the Library")
        if app.buttons["tab.paper"].exists { XCTAssertFalse(app.buttons["tab.paper"].isEnabled) }
        app.buttons["sample.open"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        app.buttons["Table of contents"].tap()
        let equation = app.buttons["2. Read the equations in context"]
        XCTAssertTrue(equation.waitForExistence(timeout: 5))
        equation.tap()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Reader with equation"
        attachment.lifetime = .keepAlways
        add(attachment)
        if app.buttons["tab.library"].exists {
            app.show("library")
            XCTAssertTrue(app.staticTexts["Reading machine learning papers"].firstMatch.waitForExistence(timeout: 5))
            app.show("paper")
            XCTAssertTrue(app.webViews.firstMatch.exists)
        }
    }

    /// Owner report (build 35): "Back to where you were … no longer is there". An HTML paper's own in-page links
    /// (a citation "[1]", a figure reference) jump with Back on this surface, and Back returns to the place left.
    func testHTMLPaperInPageLinksOfferBack() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture", "--study-fixture"]
        app.launch()
        // The fixture selects the HTML paper: read on the Paper tab on a phone, in Reader in the wide layout.
        XCTAssertTrue(app.buttons["tab.paper"].waitForExistence(timeout: 10) || app.segmentedControls["wide.mode"].buttons["Reader"].exists)
        app.show("paper")
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 15), "The study fixture opens the HTML paper")
        let back = app.buttons["reader.citation.back"]
        let citation = web.links["[1]"].firstMatch
        XCTAssertTrue(citation.waitForExistence(timeout: 10), "The paper's citation link is in the page")
        XCTAssertFalse(back.exists, "No Back before any jump")
        citation.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Back is offered after an in-page citation link")
        let jumped = XCTAttachment(screenshot: app.screenshot()); jumped.name = "HTML paper: Back after a citation link"; jumped.lifetime = .keepAlways; add(jumped)
        back.tap()
        XCTAssertTrue(back.waitForNonExistence(timeout: 5), "Back returns and goes away")
        let figure = web.links["Figure 1"].firstMatch
        XCTAssertTrue(figure.waitForExistence(timeout: 5), "The paper's figure reference link is in the page")
        figure.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Back is offered after a figure reference link")
        let atFigure = XCTAttachment(screenshot: app.screenshot()); atFigure.name = "HTML paper: Back after a figure link"; atFigure.lifetime = .keepAlways; add(atFigure)
    }

    /// Owner feedback (build 11 session): citations link to their references, Back returns to the
    /// same place, references offer actions, and the year shows under the authors.
    func testCitationGoesToItsReferenceAndBackReturnsToTheSamePlace() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication(), paperID = "paper.dddddddd-0000-4000-8000-000000000002"
        app.launchArguments = ["--offline-reader-fixture", "--reset-offline-reader-fixture", "--mathpix-reader-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons[paperID].waitForExistence(timeout: 10))
        app.buttons[paperID].tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 8))
        let year = web.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "2023, NeurIPS, arXiv 2305.18290v3")).firstMatch
        XCTAssertTrue(year.waitForExistence(timeout: 8), "The year, venue and source show under the authors")

        app.buttons["Table of contents"].tap()
        let introduction = app.buttons["1 Introduction"]
        for _ in 0..<6 { if introduction.waitForExistence(timeout: 2) { break }; app.swipeUp() }
        introduction.tap()
        let citation = web.links["Reference 11"].firstMatch
        let paragraph = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Large unsupervised language models")).firstMatch
        let placed = NSPredicate { _, _ in citation.exists && citation.isHittable && paragraph.exists && paragraph.isHittable }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: placed, object: nil)], timeout: 8), .completed)
        sleep(1) // let the Contents scroll finish
        let start = paragraph.frame.minY

        citation.tap()
        let back = app.buttons["reader.citation.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Back is offered after following a citation")
        let entry = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "[11]")).firstMatch
        let landed = NSPredicate { _, _ in entry.exists && entry.isHittable && web.frame.contains(CGPoint(x: entry.frame.midX, y: entry.frame.minY)) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landed, object: nil)], timeout: 5), .completed,
                       "The citation lands on reference 11")
        let jumped = XCTAttachment(screenshot: app.screenshot()); jumped.name = "Reference after a citation"; jumped.lifetime = .keepAlways; add(jumped)

        // A reference offers its actions; the reader stays at the reference.
        // The native edit menu beside the entry, Copy first (owner, build 44: "a native style popup like Copy").
        entry.tap()
        let copy = app.editMenuItem("Copy")
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "A reference opens the edit menu")
        let actions = XCTAttachment(screenshot: app.screenshot()); actions.name = "Reference actions"; actions.lifetime = .keepAlways; add(actions)
        XCTAssertTrue(app.editMenuItem("Open on arXiv").isHittable, "Reference 11 names arXiv:2204.02311")
        XCTAssertTrue(app.editMenuItem("Add to library").isHittable)
        XCTAssertTrue(app.editMenuItem("Discuss in chat").isHittable, "All four reference actions are visible without paging")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "[11]")).count, 1,
                       "The reference stays in the paper and is not repeated as a tall menu message")
        if !copy.exists || !copy.isHittable { entry.tap(); _ = copy.waitForExistence(timeout: 5) }
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))

        back.tap()
        let returned = NSPredicate { _, _ in paragraph.exists && abs(paragraph.frame.minY - start) < 3 && !back.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: returned, object: nil)], timeout: 5), .completed,
                       "Back returns to the reading position (\(start) → \(paragraph.frame.minY))")

        // Selecting text still offers the passage actions.
        web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: paragraph.frame.minX - web.frame.minX + 60, dy: paragraph.frame.minY - web.frame.minY + 14)).press(forDuration: 1)
        XCTAssertTrue(app.editMenuItem("Explain in Chat").waitForExistence(timeout: 5), "The edit menu offers the passage actions")
    }

    // MARK: - Owner feedback, build 21

    private func openDPO(appearance: String) -> (XCUIApplication, XCUIElement) {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication(), paperID = "paper.dddddddd-0000-4000-8000-000000000002"
        app.launchArguments = ["--offline-reader-fixture", "--reset-offline-reader-fixture", "--mathpix-reader-fixture", "-appearance", appearance]
        app.launch()
        XCTAssertTrue(app.buttons[paperID].waitForExistence(timeout: 10))
        app.buttons[paperID].tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 8))
        let year = web.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "2023, NeurIPS")).firstMatch
        XCTAssertTrue(year.waitForExistence(timeout: 20), "The paper is ready")
        return (app, web)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 8, _ condition: @escaping () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) {
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: timeout)
        XCTAssertEqual(result, .completed, message, file: file, line: line)
    }

    /// Back after a jump reads "Back to where you were" and sits at the left of the A− / A+ row: clear of it and of
    /// the tab bar (owner feedback, build 21).
    private func assertBackClearOfTextSizeAndTabs(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let back = app.buttons["reader.citation.back"], textSize = app.descendants(matching: .any)["paper.textSize"]
        // VoiceOver hears where Back goes ("Back to 6.1 …"), or "Back to where you were" when the section is unknown.
        XCTAssertTrue(back.label.hasPrefix("Back to "), back.label, file: file, line: line)
        XCTAssertTrue(textSize.exists, file: file, line: line)
        XCTAssertFalse(back.frame.intersects(textSize.frame), "Back \(back.frame) covers A− / A+ \(textSize.frame)", file: file, line: line)
        XCTAssertLessThan(back.frame.midX, textSize.frame.minX, file: file, line: line)
        // The wide layout's line width sits beside A− / A+ (READING_MODE.md): Back keeps clear of it too.
        let lineWidth = app.buttons["paper.lineWidth"]
        if lineWidth.exists { XCTAssertFalse(back.frame.intersects(lineWidth.frame), "Back \(back.frame) covers Line width \(lineWidth.frame)", file: file, line: line) }
        let tab = app.buttons["tab.paper"]
        if tab.exists { XCTAssertLessThanOrEqual(back.frame.maxY, tab.frame.minY, "Back stays above the tab bar", file: file, line: line) }
    }

    /// "Reference at the top of the message isn't needed" and "Needs to be a discuss in chat button … you can
    /// continue typing": a reference opens the native edit menu (build 44: no title row, Copy first); Discuss in chat
    /// opens this paper's chat with the entry quoted in the message box and the keyboard up, nothing sent.
    func testReferenceActionsHaveNoTitleAndDiscussInChatQuotesTheEntry() throws {
        for appearance in ["light", "dark"] {
            let (app, web) = openDPO(appearance: appearance)
            app.buttons["Table of contents"].tap()
            let introduction = app.buttons["1 Introduction"]
            for _ in 0..<6 { if introduction.waitForExistence(timeout: 2) { break }; app.swipeUp() }
            introduction.tap()
            let citation = web.links["Reference 11"].firstMatch
            // By frame: asking a web link's hittability while the page still scrolls can raise instead of answering.
            waitUntil("The citation is on screen") {
                citation.exists && !citation.frame.isEmpty && web.frame.insetBy(dx: 0, dy: 60).contains(CGPoint(x: citation.frame.midX, y: citation.frame.midY))
            }
            sleep(1)
            citation.tap()
            let back = app.buttons["reader.citation.back"]
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            assertBackClearOfTextSizeAndTabs(app)
            let entry = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "[11]")).firstMatch
            waitUntil("The citation lands on reference 11") { entry.exists && entry.isHittable }
            capture("Back to where you were after a citation (\(appearance))")

            entry.tap()
            XCTAssertTrue(app.editMenuItem("Copy").waitForExistence(timeout: 5), "A reference opens the edit menu, Copy first")
            capture("Reference actions in the edit menu (\(appearance))")
            let discuss = app.editMenuItem("Discuss in chat")
            XCTAssertTrue(discuss.exists, "Discuss in chat is one of the reference's actions")
            discuss.tap()
            let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
            XCTAssertTrue(composer.waitForExistence(timeout: 8), "This paper's chat opens")
            waitUntil("The entry is quoted in the message box") { (composer.value as? String)?.hasPrefix("About “A. Chowdhery") == true }
            waitUntil("The cursor is in the message box, ready to type") { app.keyboards.firstMatch.exists }
            XCTAssertTrue((composer.value as? String)?.hasSuffix("”: ") == true, "\(composer.value ?? "")")
            capture("Discuss in chat: the reference quoted, ready to type (\(appearance))")
            app.typeText("Is this the PaLM paper?")
            waitUntil("Typing continues after the quote") { (composer.value as? String)?.hasSuffix("”: Is this the PaLM paper?") == true }
            XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.text.")).firstMatch.exists,
                           "Nothing was sent")
            app.terminate()
        }
    }

    /// "When figures are referenced you should be able to link directly to them … and there should also be a
    /// 'return to reading location' option": "Figure 2" in the text shows the figure with its caption in a sheet;
    /// Go to figure goes there in the paper, and Back to where you were returns to the reference.
    func testFigureReferenceShowsTheFigureAndGoToFigureReturnsWithBack() throws {
        for appearance in ["light", "dark"] {
            let (app, web) = openDPO(appearance: appearance)
            app.buttons["Table of contents"].tap()
            let section = app.buttons["6.1 How well can DPO optimize the RLHF objective?"]
            for _ in 0..<8 { if section.waitForExistence(timeout: 2) && section.isHittable { break }; app.swipeUp() }
            section.tap()
            let link = web.links.matching(NSPredicate(format: "label == %@", "Figure 2")).firstMatch
            waitUntil("The reference is on screen") { link.exists && link.isHittable && link.frame.minY > web.frame.minY + 40 }
            sleep(1)
            let start = link.frame.minY
            capture("Figure references are links (\(appearance))")

            link.tap()
            // The sheet's top row: Snippet, Chat and AI Explainer in words (build 78; no title: the caption names the figure).
            XCTAssertTrue(app.figurePageSnippet.waitForExistence(timeout: 5), "The figure opens in a sheet")
            // The sheet's own web view: the one below the paper's top, in the half-height sheet.
            var detail: XCUIElement?
            waitUntil("The sheet's figure view") {
                detail = app.webViews.allElementsBoundByIndex.first { $0.frame.minY > web.frame.minY + 150 }
                return detail != nil
            }
            let sheet = try XCTUnwrap(detail)
            waitUntil("The figure's offline image") { sheet.images.firstMatch.exists }
            waitUntil("With its caption") { sheet.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Figure 2: Left.")).firstMatch.exists }
            XCTAssertTrue(app.buttons["figureReference.go"].exists && app.buttons["figureReference.go"].label == "Go to figure")
            XCTAssertFalse(app.buttons["reader.citation.back"].exists, "Looking at a figure is not a jump")
            capture("A figure reference's sheet (\(appearance))")

            app.buttons["figureReference.go"].tap()
            let back = app.buttons["reader.citation.back"]
            XCTAssertTrue(back.waitForExistence(timeout: 5), "Back is offered after Go to figure")
            let figure = web.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open figure: Figure 2")).firstMatch
            waitUntil("The figure is shown in the paper") { figure.exists && web.frame.contains(CGPoint(x: figure.frame.midX, y: figure.frame.midY)) }
            assertBackClearOfTextSizeAndTabs(app)
            capture("Go to figure: the figure with Back to where you were (\(appearance))")

            back.tap()
            waitUntil("Back returns to the reference") { link.exists && abs(link.frame.minY - start) < 3 && !back.exists }
            app.terminate()
        }
    }

    func testScreenshotPreviewRedactionAndRemoval() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication(); app.launch()
        app.buttons["sample.open"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        app.buttons["Paper options"].tap()
        app.buttons["Report this screen"].tap()
        XCTAssertTrue(app.navigationBars["Report an issue"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["Screenshot preview"].waitForExistence(timeout: 5))
        app.swipeUp()
        app.buttons["Crop or redact"].tap()
        let canvas = app.otherElements["report.editor.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45))
        start.press(forDuration: 0.1, thenDragTo: end)
        let edited = XCTAttachment(screenshot: app.screenshot()); edited.name = "Screenshot redaction preview"; edited.lifetime = .keepAlways; add(edited)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.images["Screenshot preview"].waitForExistence(timeout: 5))
        app.buttons["Remove screenshot"].tap()
        XCTAssertFalse(app.images["Screenshot preview"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5))
    }

    func testTabletLandscapeReaderAndBrowseArrangement() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad layout check")
        XCUIDevice.shared.portraitWhereSupported()
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(); app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.segmentedControls.firstMatch.waitForExistence(timeout: 5))
        app.buttons["sample.open"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.segmentedControls["wide.mode"].buttons["Reader"].isSelected)
        let reader = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); reader.name = "iPad reader and chat"; reader.lifetime = .keepAlways; add(reader)
        app.segmentedControls["wide.mode"].buttons["Browse"].tap()
        XCTAssertTrue(app.searchFields["library.search"].exists)
        XCTAssertTrue(app.webViews.firstMatch.exists)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5))
    }
}
