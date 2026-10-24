import SwiftUI
import UIKit
import XCTest
@testable import ScienceReader

/// The table's width while its slot narrows (owner, 2026-10-24, iPad: "the column of the titles gets over the left side of
/// the screen when using real time live update … using the vertical divider slider to the left"). The table is hosted
/// in a window and narrowed step by step, as a divider drag does; every row must stay inside the width it is offered:
/// its leading edge at the margin, its pinned trailing column inside the trailing margin.
@MainActor
final class PaperTableWidthTests: XCTestCase {
    private struct Row: Identifiable { let id: Int }

    private static let margin = DesignMetrics.margin

    /// Five columns, more than fit a narrow slot (so they scroll sideways), and a pinned control at the end, as the
    /// Library's and Feed's tables have.
    private static let columns: [PaperTableColumn<String>] = [
        .init(id: "year", title: "Year", priority: 1, width: 60, sortKey: "year"),
        .init(id: "added", title: "Added", priority: 2, width: 90, sortKey: "added"),
        .init(id: "opened", title: "Opened", priority: 3, width: 90, sortKey: "opened"),
        .init(id: "chats", title: "Chats", priority: 4, width: 60, sortKey: "chats"),
        .init(id: "progress", title: "Progress", priority: 0, width: 120, sortKey: "progress"),
        .init(id: "add", title: "", priority: 0, width: 44, isControl: true),
    ]

    private struct Harness: View {
        let slot: Slot
        let probes: Probes
        @State private var sort = PaperTableSort(key: "title", ascending: true)

        var body: some View {
            PaperTable(rows: (0..<4).map(Row.init), titleColumn: .init(id: "title", title: "Title", sortKey: "title", ascendingFirst: true),
                       columns: PaperTableWidthTests.columns, sort: $sort, horizontalScroll: true, identifier: "probe.table",
                       rowIdentifier: { "probe.table.\($0.id)" },
                       title: { PaperTableTitle(title: "Paper \($0.id): a title long enough to wrap onto a second line", subtitle: "Vaswani et al.") },
                       cell: { row, id in
                           Text(id).frame(maxWidth: .infinity).probe(id == "add" ? "add.\(row.id)" : nil, probes)
                       },
                       spoken: { _, _ in nil }, primaryAction: { _ in nil },
                       menu: { _ in EmptyView() }, swipe: { _ in EmptyView() },
                       // Under each row, as wide as the row is offered: its leading edge is the row's.
                       detail: { row, _ in Color.clear.frame(height: 1).probe("lead.\(row.id)", probes) },
                       top: { EmptyView() })
                // The slot: its own width, at the window's leading edge, as TwoSlotLayout's list slot.
                .frame(width: slot.width)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func host(_ slot: Slot, _ probes: Probes) throws -> (UIWindow, () -> Void) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Harness(slot: slot, probes: probes))
        window.makeKeyAndVisible()
        return (window, { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() })
    }

    /// Lets SwiftUI and the List settle (state set by a geometry change is laid out on a later pass).
    private func settle(_ window: UIWindow, turns: Int = 6) async throws {
        for _ in 0..<turns {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
    }

    /// Every row inside the slot: its leading edge at the margin (never past the slot's, the window's, left edge), its
    /// pinned column inside the trailing margin.
    private func assertInside(_ probes: Probes, width: CGFloat, _ moment: String, file: StaticString = #filePath, line: UInt = #line) {
        let leads = probes.frames.filter { $0.key.hasPrefix("lead.") }, adds = probes.frames.filter { $0.key.hasPrefix("add.") }
        XCTAssertFalse(leads.isEmpty, "Rows are shown (\(moment))", file: file, line: line)
        for (key, frame) in leads {
            XCTAssertEqual(frame.minX, Self.margin, accuracy: 0.5, "\(key)'s leading edge at \(width) pt (\(moment))", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, width - Self.margin + 0.5, "\(key) no wider than the slot at \(width) pt (\(moment))",
                                     file: file, line: line)
        }
        for (key, frame) in adds {
            XCTAssertLessThanOrEqual(frame.maxX, width - Self.margin + 0.5, "\(key) inside the slot at \(width) pt (\(moment))",
                                     file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minX, Self.margin, "\(key) at \(width) pt (\(moment))", file: file, line: line)
        }
    }

    /// A divider dragged left: the slot narrows a few points at a time, as on every frame of a live drag, from all the
    /// columns fitting to the list's 280 pt minimum, then widens again. The table follows every step.
    func testTheTableFollowsItsSlotAsItNarrowsAndWidens() async throws {
        let probes = Probes(), start: CGFloat = 760
        let slot = Slot(start)
        let (window, close) = try host(slot, probes)
        defer { close() }
        try await settle(window)
        assertInside(probes, width: start, "at rest")

        var widths = Array(stride(from: start, through: 280, by: -12)) + [280]
        widths += Array(stride(from: 292, through: start, by: 24))
        for width in widths {
            slot.width = width
            // One frame later: whatever the table has measured so far, nothing is left of the slot's leading margin.
            try await settle(window, turns: 1)
            for (key, frame) in probes.frames where key.hasPrefix("lead.") {
                XCTAssertGreaterThanOrEqual(frame.minX, Self.margin - 0.5, "\(key) one frame after \(width) pt")
            }
            try await settle(window, turns: 2)
            assertInside(probes, width: width, "dragging")
        }
    }

    /// The width source itself: content laid out wider than the slot (the columns of the previous width) still reports
    /// the slot's width, and starts at its leading edge. The plain flexible frame it replaced reports the content's.
    func testTheMeasuredWidthIsTheOfferedOneNotTheContents() async throws {
        let probes = Probes()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        let measured = Measured()
        window.rootViewController = UIHostingController(rootView: VStack(alignment: .leading, spacing: 0) {
            Color.red.frame(width: 900, height: 10).probe("offered.content", probes)
                .offeredWidth { measured.offered = $0 }
            Color.blue.frame(width: 900, height: 10)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured.flexible = $0 }
                .frame(width: 400, alignment: .leading)   // (so it doesn't widen the stack the other one is in)
        }
        .frame(width: 400).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await settle(window)
        XCTAssertEqual(measured.offered, 400, "The offered width")
        XCTAssertEqual(probes.frames["offered.content"]?.minX, 0, "Wider content starts at the leading edge")
        XCTAssertEqual(measured.flexible, 900, "A flexible frame with no minimum takes its content's width (the bug's cause)")
    }

    /// A single large jump (a turn, VoiceOver's 5% steps, Stage Manager): the same.
    func testTheTableFitsAfterAJump() async throws {
        let probes = Probes()
        let slot = Slot(900)
        let (window, close) = try host(slot, probes)
        defer { close() }
        try await settle(window)
        for width: CGFloat in [300, 700, 280, 520] {
            slot.width = width
            try await settle(window)
            assertInside(probes, width: width, "after a jump")
        }
    }
}

private extension View {
    /// Records this view's frame in window coordinates under `key` (nil records nothing).
    func probe(_ key: String?, _ probes: Probes) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            if let key { probes.frames[key] = frame }
        }
    }
}

/// The slot's width, changed as a divider drag changes it.
@Observable fileprivate final class Slot { var width: CGFloat = 0; init(_ width: CGFloat) { self.width = width } }

private final class Measured { var offered: CGFloat = 0; var flexible: CGFloat = 0 }

/// Where the probes inside the table are, in window coordinates.
private final class Probes { var frames: [String: CGRect] = [:] }
