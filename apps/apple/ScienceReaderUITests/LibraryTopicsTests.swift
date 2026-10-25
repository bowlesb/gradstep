import XCTest

/// Library › All's topics chart (interest index step 3; owner decision 4, 2026-10-24: "collapsible, slices filter").
/// Synthetic, no network: the public fixture library (38 Feed-pool papers) on the published map, read from the
/// ScienceReaderCore test fixtures through `INTEREST_FIXTURE_DIR`.
@MainActor
final class LibraryTopicsTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ScienceReaderCore/Tests/ScienceReaderCoreTests/Fixtures").path
    /// Fixture papers by index (ReaderModel+Interest.swift): 0 is a KV-cache paper, 7 a multi-agent one.
    private func paper(_ index: Int) -> String { String(format: "ffffffff-0000-0000-0000-%012d", index) }
    /// The fixture's largest topic (KV cache compression; map node 205).
    private let kvTopic = 205

    private func launch(_ extra: [String] = [], expanded: Bool? = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--workflow-fixture"] + extra + (expanded.map { ["-library.topics.collapsed", $0 ? "NO" : "YES"] } ?? [])
        app.launchEnvironment["INTEREST_FIXTURE_DIR"] = Self.fixtures
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["library.topics.toggle"].waitForExistence(timeout: 20), "The topics header")
        return app
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testChartCollapsesAndRemembersIt() throws {
        XCUIDevice.shared.portraitWhereSupported()
        var app = launch()
        let ring = element("library.topics.ring", in: app)
        XCTAssertTrue(ring.waitForExistence(timeout: 10), "Open: the ring")
        XCTAssertTrue(element("library.topics.row.\(kvTopic)", in: app).exists, "Open: the legend")
        XCTAssertTrue(element("library.topics.row.\(kvTopic)", in: app).label.contains("KV Cache Compression"), "Labelled by its terms")
        attach("Library topics open")
        element("library.topics.toggle", in: app).tap()
        XCTAssertTrue(ring.waitForNonExistence(timeout: 5), "Collapsed: no ring")
        XCTAssertEqual(element("library.topics.toggle", in: app).value as? String, "Collapsed")
        attach("Library topics collapsed")
        // Remembered: a new launch (no override) starts collapsed.
        app.terminate()
        app = launch(expanded: nil)
        XCTAssertFalse(element("library.topics.ring", in: app).waitForExistence(timeout: 3), "Still collapsed after relaunch")
        element("library.topics.toggle", in: app).tap()
        XCTAssertTrue(element("library.topics.ring", in: app).waitForExistence(timeout: 5), "Open again")
    }

    func testALegendRowOrSliceFiltersTheList() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = launch(["--library-layout=list"])
        // A list loads only the rows on screen (a phone shows a few): the chosen-topic chip says whether it filters.
        XCTAssertTrue(app.buttons["paper.\(paper(0))"].waitForExistence(timeout: 10), "The list before filtering")
        XCTAssertFalse(element("library.topics.clear", in: app).exists, "No topic chosen yet")
        let row = element("library.topics.row.\(kvTopic)", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(element("library.topics.clear", in: app).waitForExistence(timeout: 5), "The chosen topic shows in the header")
        XCTAssertTrue(app.buttons["paper.\(paper(0))"].waitForExistence(timeout: 5), "The topic's papers")
        XCTAssertFalse(app.buttons["paper.\(paper(7))"].exists, "Other topics' papers are hidden")
        attach("Library filtered to a topic")
        // The same row again shows everything.
        row.tap()
        XCTAssertTrue(element("library.topics.clear", in: app).waitForNonExistence(timeout: 5), "All papers again")
        // A slice: the first (largest) runs clockwise from the top; tap inside it.
        let ring = element("library.topics.ring", in: app)
        let frame = ring.frame, radius = frame.width / 2 * 0.86, angle = 25.0 * .pi / 180
        ring.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: radius * sin(angle), dy: -radius * cos(angle))).tap()
        XCTAssertTrue(element("library.topics.clear", in: app).waitForExistence(timeout: 5), "A slice filters too")
        XCTAssertTrue(app.buttons["paper.\(paper(0))"].exists && !app.buttons["paper.\(paper(7))"].exists)
        // Clearing from the chip.
        element("library.topics.clear", in: app).tap()
        XCTAssertTrue(element("library.topics.clear", in: app).waitForNonExistence(timeout: 5), "The chip clears it")
        // Other opens the smaller groups, including the papers outside every topic.
        element("library.topics.other", in: app).tap()
        XCTAssertTrue(element("library.topics.outside", in: app).waitForExistence(timeout: 5), "Outside topics")
        element("library.topics.outside", in: app).tap()
        XCTAssertTrue(element("library.topics.clear", in: app).waitForExistence(timeout: 5), "Filtered to the papers outside every topic")
        XCTAssertFalse(app.buttons["paper.\(paper(0))"].exists)
        attach("Library outside topics")
    }

    func testTheTableShowsTheChartAndFilters() throws {
        let app = launch(["--library-layout=table"])
        XCTAssertTrue(element("library.table", in: app).waitForExistence(timeout: 10))
        let row = element("library.topics.row.\(kvTopic)", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(element("library.table.paper/\(paper(0))", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("library.table.paper/\(paper(7))", in: app).exists)
        attach("Library table filtered to a topic")
        // A quick filter other than All hides the chart and its filter's chips stay where they were.
        let chips = element("library.filters", in: app)
        let top = chips.frame.minY
        element("library.filter.unread", in: app).tap()
        XCTAssertTrue(element("library.topics.toggle", in: app).waitForNonExistence(timeout: 5), "Only on All")
        XCTAssertEqual(chips.frame.minY, top, accuracy: 1, "The chips don't move")
    }

    /// Filter + related on the public fixture library (owner, TestFlight 92; docs/architecture/INTEREST_INDEX.md "Related
    /// papers for a tag"): “Multi-Agent” is on six papers; Filter + related keeps them first and adds after them the three
    /// untagged papers whose titles or abstracts say "multi-agent", each with its reason. From the Tags menu (Include related
    /// papers) and from a tag chip's own menu.
    func testFilterPlusRelatedAddsRelatedPapersAfterTheTaggedOnes() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = launch(["--library-layout=table", "--library-columns=tags"], expanded: false)
        let tags = element("library.filter.tags", in: app)
        XCTAssertTrue(tags.waitForExistence(timeout: 10))
        func row(_ i: Int) -> XCUIElement { element("library.table.paper/\(paper(i))", in: app) }
        let tagged = [7, 9, 10, 12, 13, 36], related = [8, 11, 37]
        tags.tap()
        let multiAgent = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Multi-Agent")).firstMatch
        XCTAssertTrue(multiAgent.waitForExistence(timeout: 5), "The Tags menu lists Multi-Agent")
        multiAgent.tap()
        XCTAssertEqual(tags.label, "Tag: Multi-Agent")
        XCTAssertTrue(row(7).waitForExistence(timeout: 5))
        // Until the term statistics' keywords arrive a title's named words stand in, Multi-Agent among them for all nine.
        for i in related { XCTAssertTrue(row(i).waitForNonExistence(timeout: 15), "Filter: only the tagged papers (\(i))") }
        attach("Library filtered by a tag")
        tags.tap()
        let include = element("library.tags.related", in: app)
        XCTAssertTrue(include.waitForExistence(timeout: 5), "Include related papers")
        attach("Tags menu with Include related papers")
        include.tap()
        XCTAssertTrue(tags.waitForLabel("with related papers"), tags.label)
        XCTAssertTrue(row(7).waitForExistence(timeout: 5))
        // In order: no related row above a tagged one, before and after scrolling to the end.
        func checkOrder() {
            let taggedY = tagged.map(row).filter(\.exists).map(\.frame.minY), relatedY = related.map(row).filter(\.exists).map(\.frame.minY)
            if let lastTagged = taggedY.max(), let firstRelated = relatedY.min() {
                XCTAssertLessThan(lastTagged, firstRelated, "the related papers come after the tagged ones")
            }
        }
        checkOrder()
        attach("Library tag with related papers")
        let table = element("library.table", in: app)
        table.swipeUp()
        for _ in 0..<3 where !row(37).exists || !row(37).isHittable { table.swipeUp() }
        checkOrder()
        for i in related {
            XCTAssertTrue(row(i).waitForExistence(timeout: 5), "related paper \(i)")
            XCTAssertTrue(row(i).label.contains("Mentions “multi-agent”"), row(i).label)
        }
        for i in [0, 30, 35] { XCTAssertFalse(row(i).exists, "KV-cache, robot and cryo-EM papers stay out (\(i))") }
        attach("Library tag with related papers, the end")
        // The tag's own chip: Filter + related is checked, with Show all papers; Filter takes the related papers away.
        table.swipeDown(); table.swipeDown()
        let chip = app.buttons["library.tagChip.Multi-Agent"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertEqual(chip.value as? String, "Filtered, with related papers")
        chip.tap()
        XCTAssertTrue(app.buttons["library.tag.filter"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["library.tag.clear"].exists, "Show all papers")
        attach("Tag chip menu, Filter + related chosen")
        app.buttons["library.tag.filter"].tap()
        let plain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Tag: Multi-Agent"), object: tags)
        XCTAssertEqual(XCTWaiter().wait(for: [plain], timeout: 5), .completed, tags.label)
        for i in related { XCTAssertTrue(row(i).waitForNonExistence(timeout: 5), "Filter alone: no related papers (\(i))") }
        // Another tag's chip offers its own three, and Filter + related there.
        let other = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@", "library.tagChip.", "library.tagChip.Multi-Agent")).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.tap()
        XCTAssertTrue(app.buttons["library.tag.related"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["library.tag.clear"].exists, "nothing to clear for a tag not chosen")
        attach("Tag chip menu")
        app.buttons["library.tag.related"].tap()
        let chosen = String(other.identifier.dropFirst("library.tagChip.".count))
        XCTAssertTrue(tags.waitForLabel("Tag: \(chosen), with related papers"), tags.label)
    }

    func testRenameAndHideSyncThroughTheRegistry() throws {
        XCUIDevice.shared.portraitWhereSupported()
        let app = launch(["--library-layout=list"])
        let row = element("library.topics.row.\(kvTopic)", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1.0)
        app.buttons["Rename…"].firstMatch.tap()
        // An alert's field doesn't carry its SwiftUI identifier: the Rename topic alert's only field.
        let field = app.alerts["Rename topic"].textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Sparse attention")
        app.buttons["Save"].tap()
        XCTAssertTrue(NSPredicate(format: "label CONTAINS 'Sparse attention'").evaluate(with: row) || row.waitForLabel("Sparse attention"),
                      "The reader's name replaces the terms")
        attach("Library topic renamed")
        row.press(forDuration: 1.0)
        app.buttons["Hide topic"].firstMatch.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "Hidden topics leave the chart")
        element("library.topics.other", in: app).tap()
        XCTAssertTrue(element("library.topics.hidden.\(kvTopic)", in: app).waitForExistence(timeout: 5), "and wait under Other")
    }
}

private extension XCUIElement {
    func waitForLabel(_ text: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
