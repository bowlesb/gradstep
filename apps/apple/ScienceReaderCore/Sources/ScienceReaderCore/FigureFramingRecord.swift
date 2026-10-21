import Foundation

// The framing interaction record (owner, 2026-10-21: "we could even log the data (later) from zoom behavior and build a
// training dataset"; FIGURE_VIEW.md "Parts as viewports" › "Future opt-in training signal; not collected"). When a part
// card is shown, expanded, zoomed or panned, one structured, geometry-only record per card is kept here, in memory only:
// never sent, never stored, cleared on sign-out. It is the single place a future opt-in, consented upload would attach to
// (DECISIONS.md proposal: opt-in only, geometry only, public arXiv figures only, no account linkage). Only figures of arXiv
// papers are recorded (their public identity); nothing for local PDFs or snippets. The browser's figure-framing-record.ts
// is the same record.

/// A public arXiv figure: the paper's id and revision and the figure's number as the paper names it ("Figure 3").
public struct ArxivFigure: Equatable, Sendable {
    public let sourceID: String, revision: Int, figure: String
    public init(sourceID: String, revision: Int, figure: String) { self.sourceID = sourceID; self.revision = revision; self.figure = figure }
}

public struct FigureFramingRecord: Equatable, Sendable {
    public enum Surface: String, Sendable { case walkthrough, detail, chat }
    public let figure: ArxivFigure
    public let surface: Surface
    /// The part's place in its set (0-based) and the set's size.
    public let part: Int, parts: Int
    public let level: FigureFraming.Level
    /// The AI's box, the completed region and the frame shown at first: fractions of the figure.
    public let box: CropRect, region: CropRect, frame: CropRect
    /// The view the reader left the card at (the frame when untouched), and what they did.
    public internal(set) var finalView: CropRect
    public internal(set) var zoomed = false, panned = false, expanded = false

    public init(figure: ArxivFigure, surface: Surface, part: Int, parts: Int, level: FigureFraming.Level, box: CropRect, region: CropRect, frame: CropRect) {
        func r(_ c: CropRect) -> CropRect { CropRect(round4(c.x0), round4(c.y0), round4(c.x1), round4(c.y1)) }
        self.figure = figure; self.surface = surface; self.part = part; self.parts = parts; self.level = level
        self.box = r(box); self.region = r(region); self.frame = r(frame); finalView = r(frame)
    }
}

private func round4(_ v: Double) -> Double { (v * 1e4).rounded() / 1e4 }

/// The records of this session, by card. Thread-safe; at most 200 records, oldest first out.
public final class FigureFramingRecorder: @unchecked Sendable {
    public static let shared = FigureFramingRecorder()
    public static let limit = 200
    private let lock = NSLock()
    private var order: [String] = []
    private var records: [String: FigureFramingRecord] = [:]

    public init() {}

    /// A card was shown (`key` names it: figure, surface, part). Nothing without an arXiv identity; kept once per card.
    public func shown(_ key: String, _ record: FigureFramingRecord?) {
        guard let record else { return }
        lock.lock(); defer { lock.unlock() }
        guard records[key] == nil else { return }
        records[key] = record; order.append(key)
        while order.count > Self.limit { records[order.removeFirst()] = nil }
    }

    /// The reader zoomed or panned the card (`view`: where it now shows, fractions of the figure), or expanded it.
    public func changed(_ key: String, view: CropRect? = nil, zoomed: Bool = false, panned: Bool = false, expanded: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard var record = records[key] else { return }
        if let view { record.finalView = CropRect(round4(view.x0), round4(view.y0), round4(view.x1), round4(view.y1)) }
        if zoomed { record.zoomed = true }
        if panned { record.panned = true }
        if expanded { record.expanded = true }
        records[key] = record
    }

    /// What is kept, oldest first (for a future consented upload, and tests).
    public var all: [FigureFramingRecord] { lock.lock(); defer { lock.unlock() }; return order.compactMap { records[$0] } }

    /// Signing out forgets every record.
    public func clear() { lock.lock(); defer { lock.unlock() }; records = [:]; order = [] }
}
