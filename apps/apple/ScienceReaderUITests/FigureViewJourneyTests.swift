import XCTest

/// The figure view (owner, build 59; docs/architecture/FIGURE_VIEW.md): a figure page offers Explain and Ask in chat;
/// Explain walks through the figure part by part with a crop where a part points at a detail; a part's menu explains it
/// more simply (inline), shows it in the paper, or asks about it in chat. Kept answers show again without a request.
@MainActor
final class FigureViewJourneyTests: XCTestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func wait(_ timeout: TimeInterval = 8, _ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: timeout) == .completed
    }

    /// A menu's item: a button by identifier or title (iPhone, iPad), a menu item on the Mac.
    private func menuItem(_ app: XCUIApplication, _ identifier: String, _ title: String) -> XCUIElement {
        let byID = app.buttons[identifier]
        if byID.waitForExistence(timeout: 2) { return byID }
        let byTitle = app.buttons[title]
        if byTitle.exists { return byTitle }
        return app.menuItems[title]
    }

    /// A part's menu: a button on iPhone and iPad, a pop-up button on the Mac.
    private func partMenu(_ app: XCUIApplication, _ number: Int) -> XCUIElement {
        let id = "figureView.section.\(number).menu"
        let button = app.buttons[id]
        if button.exists { return button }
        let popUp = app.popUpButtons[id]
        if popUp.exists { return popUp }
        return app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func launch(appearance: String = "light", extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-mode=figure_walkthrough", "--chat-fixture-consented", "--reset-draft-fixture", "--study-fixture",
                               "-appearance", appearance] + extra
        app.launch()
        // The fixture selects its arXiv paper: the Paper tab on a phone, Reader in the wide layout.
        XCTAssertTrue(app.buttons["tab.paper"].waitForExistence(timeout: 10) || app.wideMode("Reader").exists)
        app.show("paper")
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 15), "The fixture opens the numbered HTML paper")
        XCTAssertTrue(web.staticTexts["(1)"].firstMatch.waitForExistence(timeout: 10), "The paper is ready")
        return app
    }

    /// Contents › Figures › Figure 1: the figure's own page.
    private func openFigureOne(_ app: XCUIApplication) {
        app.buttons["Table of contents"].tap()
        XCTAssertTrue(app.contentsTabs.waitForExistence(timeout: 5))
        app.contentsTab("Figures").tap()
        let row = app.buttons["contents.figure.0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.buttons["figureView.askInChat"].waitForExistence(timeout: 5), "The figure's page")
    }

    func testExplainWalksThroughAFigureWithCropsAndEachPartsMenu() throws {
        let app = launch()
        openFigureOne(app)
        // Owner, build 78 (DESIGN.md "Sheet top row"): one row at the top, Snippet, Chat and AI Explainer in words, in that
        // order; no ⋯, no Report, no X on a touch screen (the sheet swipes away), no Done; nothing is asked on opening.
        let explain = app.buttons["figureView.explain"], ask = app.buttons["figureView.askInChat"], snippet = app.figurePageSnippet
        XCTAssertTrue(explain.waitForExistence(timeout: 5)); XCTAssertTrue(ask.exists); XCTAssertTrue(snippet.exists)
        XCTAssertEqual(explain.label, "AI Explainer"); XCTAssertEqual(ask.label, "Chat about Figure"); XCTAssertEqual(snippet.label, "Snippet")
        XCTAssertEqual(explain.frame.midY, ask.frame.midY, accuracy: 4, "one row")
        XCTAssertEqual(snippet.frame.midY, ask.frame.midY, accuracy: 4, "one row")
        XCTAssertLessThan(snippet.frame.maxX, ask.frame.minX, "Snippet, then Chat")
        XCTAssertLessThan(ask.frame.maxX, explain.frame.minX, "Chat, then AI Explainer")
        XCTAssertFalse(app.buttons["sheet.close"].exists, "no X")
        XCTAssertFalse(app.buttons["sheet.options"].exists, "no ⋯ (Report this screen isn't needed here)")
        XCTAssertFalse(app.buttons["Done"].exists, "no Done")
        XCTAssertFalse(app.descendants(matching: .any)["figureView.section.1"].exists)
        capture(app, "Figure page: the top row")

        explain.tap()
        XCTAssertTrue(app.buttons["ai.chooseModel"].waitForExistence(timeout: 5)); app.buttons["ai.chooseModel"].tap(); XCTAssertTrue(app.buttons["ai.chooseCloud"].waitForExistence(timeout: 5)); app.buttons["ai.chooseCloud"].tap()
        let first = app.descendants(matching: .any)["figureView.section.1"]
        XCTAssertTrue(first.waitForExistence(timeout: 8), "The walkthrough's parts")
        // Contents opens at half height on a phone; the walkthrough takes the full height.
        if UIDevice.current.userInterfaceIdiom == .phone {
            let heading = app.descendants(matching: .any)["figureView.heading"].firstMatch
            XCTAssertTrue(wait(5) { heading.exists && heading.frame.minY < app.windows.firstMatch.frame.height * 0.3 },
                          "full height: \(heading.frame)")
        }
        XCTAssertTrue(app.descendants(matching: .any)["figureView.section.3"].exists, "every part")
        // The walkthrough's own row: Explain in Chat and the X; its heading names the figure, a menu of the others.
        XCTAssertTrue(app.descendants(matching: .any)["contextChat.composer"].exists)
        XCTAssertFalse(app.buttons["figureView.walkthrough.explain"].exists, "asked already: no AI Explainer")
        XCTAssertEqual(app.descendants(matching: .any)["figureView.heading"].firstMatch.label, "Figure 1")
        XCTAssertTrue(app.descendants(matching: .any)["figureView.summary"].exists, "what it shows")
        XCTAssertTrue(app.descendants(matching: .any)["figureView.section.1.crop"].exists, "the left half, cropped from the paper's own image")
        XCTAssertFalse(app.descendants(matching: .any)["figureView.section.2.crop"].exists, "a part without a box has no crop")
        XCTAssertTrue(app.staticTexts["figureView.coverageFallback"].exists, "An incomplete split keeps the whole figure, without claiming extraction is complete")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "credit")).firstMatch.exists, "no credit counts")
        capture(app, "Figure walkthrough")
        let fullscreen = app.buttons["figureView.fullscreen"].firstMatch
        let readerWindow = app.windows.allElementsBoundByIndex.map(\.frame).max { $0.width * $0.height < $1.width * $1.height }!
        XCTAssertTrue(fullscreen.exists); fullscreen.tap()
        XCTAssertTrue(app.buttons["figureView.fullscreen.close"].waitForExistence(timeout: 5))
        let fullscreenImage = app.descendants(matching: .any)["figureView.fullscreen.image"].firstMatch
        capture(app, "Figure fullscreen before zoom")
        XCTAssertTrue(fullscreenImage.waitForExistence(timeout: 5))
        let imageFrame = fullscreenImage.frame
        let viewerWindow = app.windows.containing(.button, identifier: "figureView.fullscreen.close").firstMatch
        XCTAssertTrue(viewerWindow.exists)
        XCTAssertTrue(viewerWindow.frame.insetBy(dx: -2, dy: -2).contains(imageFrame),
            "The image must fit its visible window, not overflow a small clipped sheet")
        XCTAssertTrue(app.buttons["figureView.fullscreen.close"].isHittable, "Close must be visible and clickable")
        XCTAssertGreaterThanOrEqual(imageFrame.width, readerWindow.width * 0.9,
            "Fullscreen must use the app window, not another small sheet: image \(imageFrame), window \(readerWindow)")
        XCTAssertGreaterThanOrEqual(imageFrame.height, readerWindow.height * 0.75,
            "Fullscreen image viewport: \(imageFrame), window \(readerWindow)")
        app.buttons["figureView.fullscreen.close"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5), "Fullscreen preserves the explanation")
        #if targetEnvironment(macCatalyst)
        for shortcut in ["escape", "close"] {
            fullscreen.tap()
            let imageClose = app.buttons["figureView.fullscreen.close"]
            XCTAssertTrue(imageClose.waitForExistence(timeout: 5))
            if shortcut == "escape" { app.typeKey(.escape, modifierFlags: []) }
            else { app.typeKey("w", modifierFlags: .command) }
            XCTAssertTrue(wait(5) { !imageClose.exists }, "\(shortcut) closes the image, not its explainer")
            XCTAssertTrue(first.exists)
        }
        #endif

        // "Back up a bit": the part again, more simply, under it. Owner, 2026-10-21: no "Extract the subfigure and more
        // context" — the walkthrough is the one AI result; a part's card zooms and expands to look closer.
        partMenu(app, 1).tap()
        XCTAssertTrue(menuItem(app, "figureView.simpler", "Explain more simply").exists)
        XCTAssertFalse(app.buttons["figureView.extract"].exists || app.buttons["Extract the subfigure and more context"].exists
                       || app.menuItems["Extract the subfigure and more context"].exists, "no Extract the subfigure")
        menuItem(app, "figureView.simpler", "Explain more simply").tap()
        let simpler = app.descendants(matching: .any)["figureView.section.1.simpler"]
        XCTAssertTrue(simpler.waitForExistence(timeout: 8))
        XCTAssertTrue(wait { simpler.label.contains("synthetic fixture answer") }, "The simpler explanation streams in: \(simpler.label)")
        capture(app, "A part, more simply")

        let second = partMenu(app, 2)
        #if targetEnvironment(macCatalyst)
        let page = app.scrollViews["figureView.walkthrough"]
        #endif

        // Show in the paper: the part's paragraph, the sheet gone.
        #if targetEnvironment(macCatalyst)
        // Clear of the sheet's top row too: content scrolls behind the bar, and a click there lands on the bar.
        for _ in 0..<4 where !(second.isHittable && second.frame.minY > page.frame.minY + 60) {
            page.scroll(byDeltaX: 0, deltaY: second.frame.minY > page.frame.midY ? -150 : 150)
        }
        #else
        let composerBar = app.descendants(matching: .any)["contextChat.composer"].firstMatch
        for _ in 0..<4 where !(second.isHittable && second.frame.maxY < composerBar.frame.minY) {
            second.frame.minY > app.windows.firstMatch.frame.midY ? app.swipeUp(velocity: .slow) : app.swipeDown(velocity: .slow)
        }
        #endif
        second.tap()
        menuItem(app, "figureView.showInPaper", "Show in the paper").tap()
        XCTAssertTrue(app.buttons["figureView.askInChat"].waitForNonExistence(timeout: 5), "The figure's sheet closes")
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["(1)"].firstMatch.waitForExistence(timeout: 5), "The paper is shown")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "doesn’t have")).firstMatch.waitForExistence(timeout: 2),
                       "The paragraph is found")
        // Return directly to the same saved explainer, without a model picker or another request.
        XCTAssertTrue(app.buttons["reader.explainer.back"].waitForExistence(timeout: 5)); app.buttons["reader.explainer.back"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 3), "kept walkthrough")
        XCTAssertTrue(app.descendants(matching: .any)["figureView.section.1.simpler"].exists, "kept simpler part")
        XCTAssertFalse(app.descendants(matching: .any)["figureView.loading"].exists)

        // The ordinary figure page also reopens its saved explainer directly (owner feedback, build 71).
        app.closeInfoSheet(from: app.buttons["figureView.openInChat"])
        openFigureOne(app)
        app.buttons["figureView.explain"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5), "the existing explanation opens directly")
        XCTAssertFalse(app.buttons["ai.chooseDefault"].exists, "a saved answer needs no model choice")
        XCTAssertFalse(app.descendants(matching: .any)["figureView.loading"].exists, "no new generation")

        // Ask in chat about one part: the paper's chat, the part's text as the passage, nothing sent.
        partMenu(app, 1).tap()
        menuItem(app, "figureView.askAbout", "Ask about this part").tap()
        let composer = app.descendants(matching: .any).matching(identifier: "contextChat.composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "The chat opens")
        XCTAssertTrue(wait(5) { (composer.value as? String ?? "").contains("Left half") },
                      "The composer starts with the part: \(composer.value as? String ?? "")")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.text.")).firstMatch.exists,
                       "nothing is sent")
        capture(app, "Ask in chat about a part")
        app.buttons["figureView.openInChat"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.promotedContext"].waitForExistence(timeout: 5))
        // Build 73 (AHYZ): the figure's chat is named for the figure, never "New chat".
        let chatTitle = app.buttons["chat.context"].label
        XCTAssertTrue(chatTitle.contains("Figure") && !chatTitle.contains("New chat"), chatTitle)
        let promotedComposer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(promotedComposer.waitForExistence(timeout: 5))
        XCTAssertTrue((promotedComposer.value as? String ?? "").contains("Left half"), "Promotion preserves the draft")
        // No tap: the newly opened destination must accept typing as soon as its sheet closes.
        app.typeText(" Follow-up")
        XCTAssertTrue((promotedComposer.value as? String ?? "").hasSuffix(" Follow-up"), "Promotion focuses the retained composer")
        capture(app, "Continue the same figure conversation in Chat")
    }

    /// A real two-plot figure whose boxes clip titles, tick labels and axis titles, as models write them (owner,
    /// 2026-10-21: "ALWAYS include all pixels of the figure when it breaks it up into subplots"): each part's crop is
    /// completed on the device and shown with a margin of background; no coverage note, since the crops hold all ink.
    func testCropsOfARealTwoPlotFigureAreCompleteWithMargins() throws { completeCrops(appearance: "light") }
    func testCropsOfARealTwoPlotFigureAreCompleteWithMarginsDark() throws { completeCrops(appearance: "dark") }

    private func completeCrops(appearance: String) {
        let app = launch(appearance: appearance, extra: ["--figure-fixture-panels"])
        openFigureOne(app)
        capture(app, "Two-plot figure page (\(appearance))")
        app.buttons["figureView.explain"].tap()
        XCTAssertTrue(app.buttons["ai.chooseModel"].waitForExistence(timeout: 5)); app.buttons["ai.chooseModel"].tap()
        XCTAssertTrue(app.buttons["ai.chooseCloud"].waitForExistence(timeout: 5)); app.buttons["ai.chooseCloud"].tap()
        let left = app.descendants(matching: .any)["figureView.section.1.crop"], right = app.descendants(matching: .any)["figureView.section.2.crop"]
        XCTAssertTrue(left.waitForExistence(timeout: 10), "the left plot, cropped"); XCTAssertTrue(right.waitForExistence(timeout: 5), "the right plot, cropped")
        XCTAssertFalse(app.staticTexts["figureView.coverageFallback"].exists, "the completed crops hold all of the figure's ink")
        // Completed on the 1360×501 image sent: the left crop is [8, 8, 672, 492] plus 10 px of background on every side
        // (684 × 504, aspect 1.36); the clipped box with the old 2 % margin was 626 × 416 (1.50).
        XCTAssertEqual(left.frame.width / left.frame.height, 684.0 / 504.0, accuracy: 0.04, "left crop \(left.frame)")
        XCTAssertEqual(right.frame.width / right.frame.height, (1352.0 - 704 + 20) / (496.0 - 16 + 20), accuracy: 0.04, "right crop \(right.frame)")
        // Each crop whole on screen, above the composer, for the screenshots.
        let composer = app.descendants(matching: .any)["contextChat.composer"].firstMatch
        let inView = { (crop: XCUIElement) in crop.isHittable && crop.frame.minY > 120 && crop.frame.maxY < composer.frame.minY - 8 }
        #if targetEnvironment(macCatalyst)
        let page = app.scrollViews["figureView.walkthrough"]
        for _ in 0..<6 where !inView(left) { page.scroll(byDeltaX: 0, deltaY: left.frame.maxY >= composer.frame.minY ? -120 : 120) }
        #else
        for _ in 0..<6 where !inView(left) { left.frame.maxY >= composer.frame.minY - 8 ? app.swipeUp(velocity: .slow) : app.swipeDown(velocity: .slow) }
        #endif
        capture(app, "Two-plot walkthrough: left plot (\(appearance))")
        #if targetEnvironment(macCatalyst)
        for _ in 0..<6 where !inView(right) { page.scroll(byDeltaX: 0, deltaY: right.frame.maxY >= composer.frame.minY ? -120 : 120) }
        #else
        for _ in 0..<6 where !inView(right) { right.frame.maxY >= composer.frame.minY - 8 ? app.swipeUp(velocity: .slow) : app.swipeDown(velocity: .slow) }
        #endif
        capture(app, "Two-plot walkthrough: right plot (\(appearance))")
    }

    /// Owner, 2026-10-21: "we present it as a crop of the whole thing, that they can expand, rather than an actual crop".
    /// Parts are viewports into the whole figure, framed by confidence (FIGURE_VIEW.md "Parts as viewports"): the precise
    /// left box tight (as a crop looked), the deliberately imprecise right box (it starts inside the left plot) loosely with
    /// the part outlined.
    /// A tap expands a card to the whole figure; pinching out of a card reveals what is around the part.
    /// `TEST_RUNNER_FIGURE_FRAMING_STAGE=before` takes only the screenshots (a build without viewports).
    func testPartsAreFramedByConfidenceAndExpandToTheWholeFigure() throws { framedParts(appearance: "light") }
    func testPartsAreFramedByConfidenceAndExpandToTheWholeFigureDark() throws { framedParts(appearance: "dark") }

    private func framedParts(appearance: String) {
        let after = ProcessInfo.processInfo.environment["FIGURE_FRAMING_STAGE"] != "before"
        let app = launch(appearance: appearance, extra: ["--figure-fixture-panels", "--figure-fixture-loose"])
        openFigureOne(app)
        app.buttons["figureView.explain"].tap()
        XCTAssertTrue(app.buttons["ai.chooseModel"].waitForExistence(timeout: 5)); app.buttons["ai.chooseModel"].tap()
        XCTAssertTrue(app.buttons["ai.chooseCloud"].waitForExistence(timeout: 5)); app.buttons["ai.chooseCloud"].tap()
        let left = app.descendants(matching: .any)["figureView.section.1.crop"], right = app.descendants(matching: .any)["figureView.section.2.crop"]
        XCTAssertTrue(left.waitForExistence(timeout: 10), "the left plot"); XCTAssertTrue(right.waitForExistence(timeout: 5), "the right plot")
        let composer = app.descendants(matching: .any)["contextChat.composer"].firstMatch
        let inView = { (card: XCUIElement) in card.isHittable && card.frame.minY > 120 && card.frame.maxY < composer.frame.minY - 8 }
        func reveal(_ card: XCUIElement) {
            #if targetEnvironment(macCatalyst)
            let page = app.scrollViews["figureView.walkthrough"]
            for _ in 0..<8 where !inView(card) { page.scroll(byDeltaX: 0, deltaY: card.frame.maxY >= composer.frame.minY ? -120 : 120) }
            #else
            for _ in 0..<8 where !inView(card) { card.frame.maxY >= composer.frame.minY - 8 ? app.swipeUp(velocity: .slow) : app.swipeDown(velocity: .slow) }
            #endif
        }
        reveal(left)
        capture(app, "Framing: precise left box (\(appearance))")
        reveal(right)
        capture(app, "Framing: imprecise right box (\(appearance))")
        if after {
            // Tight: the completed crop and its margin, 684 × 504; loose: [478.8, −10, 1370, 511] of the 1360 × 501 image.
            XCTAssertEqual(left.frame.width / left.frame.height, 684.0 / 504.0, accuracy: 0.04, "left card \(left.frame)")
            XCTAssertEqual(right.frame.width / right.frame.height, (1370 - 478.8) / 521.0, accuracy: 0.05, "right card \(right.frame)")
            XCTAssertEqual(left.label, "Detail of Figure 1: Left plot", "the label keeps its meaning")
            // Pinching out of the tight card shows what is around the part (the part outlined); a double tap returns.
            reveal(left)
            let before = left.value as? String
            left.pinch(withScale: 0.5, velocity: -1)
            XCTAssertTrue(wait { (left.value as? String) != before }, "pinching out reveals the figure around the part")
            capture(app, "Framing: pinched out of the left card (\(appearance))")
            left.doubleTap()
            XCTAssertTrue(wait { (left.value as? String) == "100%" }, "a double tap returns to the frame")
            // A tap expands the imprecise part to the whole figure with the part outlined; Show part frames it again.
            reveal(right)
            right.tap()
            let full = app.descendants(matching: .any)["figureView.fullscreen.image"]
            XCTAssertTrue(full.waitForExistence(timeout: 5), "the whole figure, fullscreen")
            sleep(1)
            capture(app, "Framing: expanded to the whole figure (\(appearance))")
            let showPart = app.buttons["Show part"]
            XCTAssertTrue(showPart.waitForExistence(timeout: 3)); showPart.tap()
            sleep(1)
            capture(app, "Framing: expanded, the part framed (\(appearance))")
            app.buttons["figureView.fullscreen.close"].tap()
            XCTAssertTrue(right.waitForExistence(timeout: 5))
        } else {
            reveal(right)
            app.buttons.matching(identifier: "figureView.fullscreen").element(boundBy: 2).tap()
            sleep(1)
            capture(app, "Framing: fullscreen (\(appearance))")
            app.buttons["figureView.fullscreen.close"].tap()
        }
    }

    /// Structure first (FIGURE_VIEW.md "Structure first"): a real multi-image arXiv figure (2610.22353v1 Figure 3, three
    /// images with sub-captions (a)–(c)), compiled on this Mac by the device compiler
    /// (`node scripts/reader-device-compile.mjs --ids=2610.22353v1 --out=<dir>`) and passed as
    /// `TEST_RUNNER_FIGURE_STRUCTURE_BUNDLE=<dir>/2610.22353v1`. The walkthrough's parts (a), (b) (boxed on its band) and (c)
    /// are the figure's own sub-figures: exact, tight on their bands. Grouped, "(a) and (b)" plus (c) are two parts for three
    /// sub-figures (count disagreement): the group shows the whole figure, outlined, while (c) stays exact.
    func testARealMultiImageFiguresPartsAreItsOwnSubfigures() throws { try subfigures(appearance: "light", grouped: false) }
    func testARealMultiImageFiguresPartsAreItsOwnSubfiguresDark() throws { try subfigures(appearance: "dark", grouped: false) }
    func testGroupedPartsOfARealMultiImageFigureShowTheWholeFigure() throws { try subfigures(appearance: "light", grouped: true) }

    private func subfigures(appearance: String, grouped: Bool) throws {
        guard let bundle = ProcessInfo.processInfo.environment["FIGURE_STRUCTURE_BUNDLE"], !bundle.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_FIGURE_STRUCTURE_BUNDLE to a compiled 2610.22353v1 bundle")
        }
        XCUIDevice.shared.portraitWhereSupported()
        let app = XCUIApplication()
        app.launchArguments = ["--chat-fixture", "--chat-fixture-mode=figure_walkthrough", "--chat-fixture-consented", "--reset-draft-fixture", "--study-fixture",
                               "--figure-fixture-bundle=\(bundle)", "--figure-fixture-subfigures", "-appearance", appearance] + (grouped ? ["--figure-fixture-grouped"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["tab.paper"].waitForExistence(timeout: 10) || app.wideMode("Reader").exists)
        app.show("paper")
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20), "the real paper opens")
        XCTAssertTrue(app.buttons["Table of contents"].waitForExistence(timeout: 20))
        app.buttons["Table of contents"].tap()
        XCTAssertTrue(app.contentsTabs.waitForExistence(timeout: 5))
        app.contentsTab("Figures").tap()
        let row = app.buttons["contents.figure.2"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.buttons["figureView.explain"].waitForExistence(timeout: 5), "Figure 3's page")
        capture(app, "Real multi-image figure page (\(appearance))")
        app.buttons["figureView.explain"].tap()
        XCTAssertTrue(app.buttons["ai.chooseModel"].waitForExistence(timeout: 5)); app.buttons["ai.chooseModel"].tap()
        XCTAssertTrue(app.buttons["ai.chooseCloud"].waitForExistence(timeout: 5)); app.buttons["ai.chooseCloud"].tap()
        let composer = app.descendants(matching: .any)["contextChat.composer"].firstMatch
        let inView = { (card: XCUIElement) in card.isHittable && card.frame.minY > 120 && card.frame.maxY < composer.frame.minY - 8 }
        func reveal(_ card: XCUIElement) {
            #if targetEnvironment(macCatalyst)
            let page = app.scrollViews["figureView.walkthrough"]
            for _ in 0..<10 where !inView(card) { page.scroll(byDeltaX: 0, deltaY: card.frame.maxY >= composer.frame.minY ? -120 : 120) }
            #else
            for _ in 0..<10 where !inView(card) { card.frame.maxY >= composer.frame.minY - 8 ? app.swipeUp(velocity: .slow) : app.swipeDown(velocity: .slow) }
            #endif
        }
        func card(_ number: Int) -> XCUIElement { app.descendants(matching: .any)["figureView.section.\(number).crop"] }
        // The sent image is the three images composed (1187 × 2342), scaled to 763 × 1506; each band plus 15 px of margin.
        let bandA = (763.0 + 30) / (0.33006 * 1506 + 30), bandB = (763.0 + 30) / ((0.659693 - 0.340307) * 1506 + 30)
        if grouped {
            let group = card(2), c = card(3)
            XCTAssertTrue(group.waitForExistence(timeout: 10)); XCTAssertTrue(c.waitForExistence(timeout: 5))
            XCTAssertEqual(group.label, "Figure 3, whole, for (a) and (b)", "two parts for three sub-figures: the group shows the whole figure")
            XCTAssertEqual(c.label, "Detail of Figure 3: (c)", "(c) is still the figure's own sub-figure")
            XCTAssertEqual(c.frame.width / c.frame.height, bandA, accuracy: 0.05, "(c) on its band \(c.frame)")
            reveal(group); capture(app, "Grouped parts: the group on the whole figure (\(appearance))")
            reveal(c); capture(app, "Grouped parts: (c) exact (\(appearance))")
            return
        }
        let a = card(2), b = card(3), c = card(4)
        XCTAssertTrue(a.waitForExistence(timeout: 10), "(a), with no box, is the figure's own sub-figure")
        XCTAssertTrue(b.waitForExistence(timeout: 5)); XCTAssertTrue(c.waitForExistence(timeout: 5))
        XCTAssertFalse(card(1).exists, "the concept card has no image")
        for (element, name) in [(a, "(a)"), (b, "(b)"), (c, "(c)")] { XCTAssertEqual(element.label, "Detail of Figure 3: \(name)") }
        XCTAssertEqual(a.frame.width / a.frame.height, bandA, accuracy: 0.05, "(a) on its band \(a.frame)")
        XCTAssertEqual(b.frame.width / b.frame.height, bandB, accuracy: 0.05, "(b) on its band \(b.frame)")
        XCTAssertEqual(c.frame.width / c.frame.height, bandA, accuracy: 0.05, "(c) on its band \(c.frame)")
        XCTAssertFalse(app.staticTexts["figureView.coverageFallback"].exists, "the three sub-figures hold the whole figure")
        reveal(a); capture(app, "Real multi-image walkthrough: (a) (\(appearance))")
        reveal(b); capture(app, "Real multi-image walkthrough: (b) (\(appearance))")
        reveal(c); capture(app, "Real multi-image walkthrough: (c) (\(appearance))")
        // A tap expands the part to the whole figure, the part outlined.
        b.tap()
        XCTAssertTrue(app.descendants(matching: .any)["figureView.fullscreen.image"].waitForExistence(timeout: 5), "the whole figure, fullscreen")
        sleep(1); capture(app, "Real multi-image: (b) expanded to the whole figure (\(appearance))")
        app.buttons["figureView.fullscreen.close"].tap()
    }

    /// Report this screen on the sheets that had no "…" (where the builds 66–76 feedback was given), with the app's own
    /// snapshot, returning to the same sheet; the two explain actions are peers and a table's says "Chat about Table".
    func testReportThisScreenFromContentsAndAFigurePage() throws {
        let app = launch()
        app.buttons["Table of contents"].tap()
        XCTAssertTrue(app.contentsTabs.waitForExistence(timeout: 5))
        let report = app.buttons["contents.report"]
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        for _ in 0..<6 where !report.isHittable { app.descendants(matching: .any)["contents.list.contents"].swipeUp() }
        report.tap()
        let composer = app.navigationBars["Report an issue"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "the report opens over Contents")
        XCTAssertTrue(app.images["Screenshot preview"].waitForExistence(timeout: 5), "with the app's own snapshot")
        capture(app, "Report this screen from Contents")
        composer.buttons["Cancel"].tap()
        XCTAssertTrue(app.contentsTabs.waitForExistence(timeout: 5), "Contents is still open")
        app.contentsTab("Tables").tap()
        if app.buttons["contents.table.0"].waitForExistence(timeout: 3) {
            app.buttons["contents.table.0"].tap()
            XCTAssertTrue(app.buttons["figureView.askInChat"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons["figureView.askInChat"].label, "Chat about Table", "build 76: a table's sheet names the table")
            app.navigationBars.buttons["BackButton"].firstMatch.tap()
        }
        app.contentsTab("Figures").tap()
        let row = app.buttons["contents.figure.0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.buttons["figureView.askInChat"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["figureView.askInChat"].label, "Chat about Figure")
        capture(app, "Figure page: Snippet, Chat and AI Explainer alike")
        // Build 78: "The report this screen isn't needed" on this page: no ⋯ (Settings › Report a problem remains).
        XCTAssertFalse(app.buttons["sheet.options"].exists, "no ⋯ on the figure page")
    }

    /// The figure page's own Ask in chat: the figure's caption is the passage (in dark mode, with the walkthrough seen first).
    func testAskInChatFromTheFigurePage() throws {
        let app = launch(appearance: "dark")
        openFigureOne(app)
        capture(app, "Figure page, dark")
        app.buttons["figureView.explain"].tap()
        XCTAssertTrue(app.buttons["ai.chooseModel"].waitForExistence(timeout: 5)); app.buttons["ai.chooseModel"].tap(); XCTAssertTrue(app.buttons["ai.chooseCloud"].waitForExistence(timeout: 5)); app.buttons["ai.chooseCloud"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["figureView.section.1"].waitForExistence(timeout: 8))
        capture(app, "Figure walkthrough, dark")
        // Back (the sheet bar's system Back) to the figure's page.
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        let ask = app.buttons["figureView.askInChat"]
        XCTAssertTrue(ask.waitForExistence(timeout: 5)); ask.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "contextChat.composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "The chat opens")
        XCTAssertTrue(wait(5) { (composer.value as? String ?? "").isEmpty },
                      "The composer starts with the figure: \(composer.value as? String ?? "")")
        capture(app, "Ask in chat from a figure")
    }
}
