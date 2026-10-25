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
        XCTAssertTrue(app.buttons["paper.\(paper(29))"].waitForExistence(timeout: 5) || app.buttons["paper.\(paper(37))"].exists,
                      "Papers outside every topic")
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
