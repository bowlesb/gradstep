import Foundation

// The figure explainer's progress bar (FIGURE_VIEW.md "Progress", owner 2026-10-22: "it needs a progress bar"). The same
// rules and numbers as the browser's apps/web/src/lib/figure-progress.ts; both reproduce tests/fixtures/figure-progress.json.
// Honest by construction: a stage label always; a determinate value only while the number of parts is known (the figure's
// own sub-figures, else the panels its caption letters, else none) and not yet exceeded; the value never goes back and
// never waits at a made-up 99 %: when the estimate runs out it turns indeterminate ("Writing part 4…") until it is done.

public enum FigureProgress {
    /// Where the request is: `preparing` (this device makes the image and request), `reading` (the server asked the model;
    /// it is reading the figure), `writing` (the walkthrough's characters are arriving), `done`.
    public enum Stage: String, Equatable, Sendable { case preparing, reading, writing, done }

    public struct Input: Equatable, Sendable {
        public var stage: Stage
        /// The summary has arrived.
        public var summary: Bool
        /// Parts that have arrived.
        public var parts: Int
        /// The walkthrough's characters written so far (the latest `figure_progress`), 0 before any.
        public var characters: Int
        /// `characters` when the summary or the latest part arrived (what the current part has written is the difference).
        public var charactersAtLast: Int
        /// How many parts to expect, when known (sub-figures, else caption panels, at least 2); nil when not.
        public var expected: Int?
        /// The value last shown (the bar never goes back); nil when it was indeterminate or nothing was shown.
        public var previous: Double?
        public init(stage: Stage, summary: Bool = false, parts: Int = 0, characters: Int = 0, charactersAtLast: Int = 0,
                    expected: Int? = nil, previous: Double? = nil) {
            self.stage = stage; self.summary = summary; self.parts = parts; self.characters = characters
            self.charactersAtLast = charactersAtLast; self.expected = expected; self.previous = previous
        }
    }

    public struct State: Equatable, Sendable {
        public let label: String
        /// 0–1, or nil while indeterminate.
        public let value: Double?
        public init(label: String, value: Double?) { self.label = label; self.value = value }
    }

    /// Measured walkthrough sizes (Gemini 3.8 Flash at low effort, four real figures, 2026-10-22): the summary's JSON about
    /// 500 characters, a part's about 1,500 (its text, label, title, citations and box).
    public enum Parameters {
        public static let summaryChars = 500.0, partChars = 1_500.0, summaryShare = 0.1, partCap = 0.9
        /// As the fixture states them (`parameters`).
        public static var all: [String: Double] {
            ["summaryChars": summaryChars, "partChars": partChars, "summaryShare": summaryShare, "partCap": partCap]
        }
    }

    /// The expected number of parts: the figure's own sub-figures when there are two or more, else the panels its caption
    /// letters when there are two or more, else unknown.
    public static func expectedParts(subfigures: Int?, captionLetters: Int) -> Int? {
        if let subfigures, subfigures >= 2 { return subfigures }
        return captionLetters >= 2 ? captionLetters : nil
    }

    public static func state(_ input: Input) -> State {
        switch input.stage {
        case .preparing: return State(label: "Preparing the figure…", value: nil)
        case .reading: return State(label: "Reading the figure…", value: nil)
        case .done: return State(label: "Done", value: 1)
        case .writing: break
        }
        let p = Parameters.self
        let opening = !input.summary && input.parts == 0
        let known = input.expected.map { $0 >= 1 && input.parts < $0 } ?? false
        let label = opening ? "Writing the summary…"
            : known ? "Writing part \(input.parts + 1) of \(input.expected!)…" : "Writing part \(input.parts + 1)…"
        guard known, let n = input.expected else { return State(label: label, value: nil) }
        let current = Double(max(0, input.characters - input.charactersAtLast))
        let value = opening
            ? p.summaryShare * min(p.partCap, current / p.summaryChars)
            : p.summaryShare + (1 - p.summaryShare) * (Double(input.parts) + min(p.partCap, current / p.partChars)) / Double(n)
        return State(label: label, value: round(min(1, max(input.previous ?? 0, value))))
    }

    /// One walkthrough request as its events arrive: the walkthrough so far (the summary, then the parts in order, each
    /// once), the progress bar's inputs, and the final `figure` once it comes (which replaces what was streamed). Works the
    /// same with an older server that sends only the final `figure`.
    public struct Tracker: Sendable {
        public private(set) var input: Input
        public private(set) var summary: String?
        public private(set) var sections: [FigureWalkthrough.Section] = []
        /// The final walkthrough (`figure`): what is shown and kept once the request is done.
        public private(set) var final: FigureWalkthrough?

        /// `expected`: `FigureProgress.expectedParts` for the figure (the model's announced count replaces it).
        public init(expected: Int?) { input = Input(stage: .preparing, expected: expected) }

        /// What to show while the walkthrough is written: the final one once it came, else the summary and parts so far.
        public var walkthroughSoFar: FigureWalkthrough? {
            final ?? (summary == nil && sections.isEmpty ? nil : FigureWalkthrough(summary: summary ?? "", sections: sections))
        }

        /// The request is with the server (an older server says nothing more until the walkthrough is written).
        public mutating func opened() { advance(.reading) }

        /// Applies one event; true when the walkthrough so far changed (a summary or a part arrived).
        @discardableResult public mutating func apply(_ event: ChatStreamEvent) -> Bool {
            switch event {
            case .figureProgress(let step):
                switch step.stage {
                case .reading: advance(.reading)
                case .writing:
                    if let parts = step.parts { input.expected = parts }
                    if let characters = step.characters { input.characters = max(input.characters, characters) }
                    advance(.writing)
                }
                return false
            case .figureSummary(let text):
                guard final == nil, summary == nil else { return false }
                summary = text
                input.summary = true; input.charactersAtLast = input.characters
                advance(.writing)
                return true
            case .figureSection(let index, let section):
                // In order, each once: its index is its place in the final walkthrough.
                guard final == nil, index >= sections.count, sections.count < FigureWalkthrough.maximumSections else { return false }
                sections.append(section)
                input.parts = sections.count; input.charactersAtLast = input.characters
                advance(.writing)
                return true
            case .figure(let walkthrough):
                final = walkthrough
                return false
            default: return false
            }
        }

        /// The bar now (and remembered, so it never goes back).
        public mutating func state() -> State {
            let state = FigureProgress.state(input)
            input.previous = state.value
            return state
        }

        /// The stage moves forward only: preparing → reading → writing.
        private mutating func advance(_ stage: Stage) {
            let order: [Stage] = [.preparing, .reading, .writing, .done]
            if order.firstIndex(of: stage)! > order.firstIndex(of: input.stage)! { input.stage = stage }
        }
    }

    /// Four decimals, as the browser rounds (`Math.round(v * 10000) / 10000`; values here are never negative).
    static func round(_ v: Double) -> Double { (v * 10_000).rounded(.toNearestOrAwayFromZero) / 10_000 }
}
