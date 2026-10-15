import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// Line width and reading mode (docs/architecture/READING_MODE.md): the sections J / K step through, the measure kept per
/// device, and reading mode entering and leaving cleanly.
@MainActor
final class ReadingModeTests: XCTestCase {
    private let headings = [(id: "b-3", title: "Abstract"), (id: "b-5", title: "1 Introduction"), (id: "b-12", title: "2 Method"),
                            (id: "missing", title: "Not in the blocks")]
    private let blocks = (0..<20).map { "b-\($0)" }

    func testSectionsAreTheHeadingsInBlockOrderAndTheCurrentOneIsTheLastAtOrBeforeTheReadingPlace() {
        let sections = ReadingSections.sections(headings: headings, blockIDs: blocks)
        XCTAssertEqual(sections.map(\.title), ["Abstract", "1 Introduction", "2 Method"], "a heading outside the blocks is left out")
        XCTAssertEqual(sections.map(\.block), [3, 5, 12])
        XCTAssertNil(ReadingSections.current(sections, block: 1), "before the first heading there is no section")
        XCTAssertEqual(ReadingSections.current(sections, block: 5)?.title, "1 Introduction")
        XCTAssertEqual(ReadingSections.current(sections, block: 11)?.title, "1 Introduction")
        XCTAssertEqual(ReadingSections.current(sections, block: 19)?.title, "2 Method")
        XCTAssertNil(ReadingSections.current(sections, block: nil))
    }

    func testStepGoesToTheNextOrPreviousSectionAndStopsAtTheEnds() {
        let sections = ReadingSections.sections(headings: headings, blockIDs: blocks)
        XCTAssertEqual(ReadingSections.step(sections, from: 7, by: 1)?.title, "2 Method")
        XCTAssertEqual(ReadingSections.step(sections, from: 7, by: -1)?.title, "Abstract")
        XCTAssertNil(ReadingSections.step(sections, from: 15, by: 1), "after the last section there is nowhere further")
        XCTAssertNil(ReadingSections.step(sections, from: 3, by: -1))
        XCTAssertEqual(ReadingSections.step(sections, from: 0, by: 1)?.title, "Abstract", "before the first heading, the first")
        XCTAssertEqual(ReadingSections.step(sections, from: nil, by: 1)?.title, "Abstract")
        XCTAssertNil(ReadingSections.step([], from: 4, by: 1))
    }

    func testLineWidthIsKeptPerDeviceAndUnknownValuesFallBackToComfortable() {
        let key = "reader.lineWidth", saved = UserDefaults.standard.string(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set("nonsense", forKey: key)
        XCTAssertEqual(ReaderModel(configuration: nil).paperLineWidth, .comfortable)
        let model = ReaderModel(configuration: nil)
        model.paperLineWidth = .full
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "full")
        XCTAssertEqual(ReaderModel(configuration: nil).paperLineWidth, .full, "the next launch reads with the same measure")
        // The bridge's names, one per stop.
        XCTAssertEqual(ReaderLineWidth.allCases.map(\.rawValue), ["comfortable", "wide", "full"])
        XCTAssertEqual(ReaderLineWidth.allCases.map(\.menuTitle), ["Comfortable", "Wide", "Full Width"])
    }

    func testTheBridgeAppliesTheMeasureAsTheHostsStyleNeverTheBundles() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "reader-bridge", withExtension: "js"))
        let bridge = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(bridge.contains("window.__scienceReaderSetLineWidth"))
        XCTAssertTrue(bridge.contains("html[data-sr-line-width=full] body:not(.reader-figure-detail){max-width:none"))
        XCTAssertTrue(PaperWebView.keyScript.contains("'next'") && PaperWebView.keyScript.contains("Escape"))
    }

    func testReadingModeNeedsAPaperAndLeavesWithoutTheChat() {
        let model = ReaderModel(configuration: nil)
        model.enterReadingMode()
        XCTAssertFalse(model.readingMode, "nothing to read: reading mode doesn't begin")
        model.exitReadingMode()
        XCTAssertFalse(model.readingMode)
    }

    #if targetEnvironment(simulator)
    func testReadingModeEntersAndLeavesAndJKStepFromTheReportedPlace() async throws {
        let model = ReaderModel(configuration: nil)
        try await model.configureDurableDraftFixture(reset: true)
        let paper = try XCTUnwrap(model.selectedPaper)
        let bundle = try XCTUnwrap(paper.readerBundle)
        model.enterReadingMode()
        XCTAssertTrue(model.readingMode)
        XCTAssertFalse(model.readingChatShown)
        model.readingChatShown = true
        model.exitReadingMode()
        XCTAssertFalse(model.readingMode); XCTAssertFalse(model.readingChatShown, "the chat slide-over goes with reading mode")

        let sections = ReadingSections.sections(in: bundle.index)
        try XCTSkipIf(sections.count < 2, "The fixture paper needs two sections")
        let first = sections[0]
        model.noteReadingPosition(PaperReadingLocation(blockIndex: first.block, blockFraction: 0, blockHeight: 100, scrollY: 0), paperID: paper.id)
        XCTAssertEqual(model.readingSectionTitle, first.title)
        model.stepSection(1)
        XCTAssertEqual(model.paperJump?.headingID, sections[1].id)
        XCTAssertEqual(model.paperJump?.locationKey, model.readingLocationKey(for: paper))
        // Another paper's report never moves this one.
        model.noteReadingPosition(PaperReadingLocation(blockIndex: sections[1].block, blockFraction: 0, blockHeight: 100, scrollY: 0), paperID: UUID())
        XCTAssertEqual(model.readingSectionTitle, first.title)
    }
    #endif
}
