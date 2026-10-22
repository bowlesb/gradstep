import Foundation
import Testing
@testable import ScienceReaderCore

/// The figure explainer's progress bar (FigureProgress.swift) against the fixture the browser's figure-progress.ts is
/// checked against too (tests/fixtures/figure-progress.json): the same labels and values, exactly.
@Suite struct FigureProgressTests {
    static var fixture: [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try! Data(contentsOf: root.appendingPathComponent("tests/fixtures/figure-progress.json"))
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private static func int(_ value: Any?) -> Int? { (value as? NSNumber).map(\.intValue) }
    private static func double(_ value: Any?) -> Double? { (value as? NSNumber).map(\.doubleValue) }

    @Test func theParametersAreTheFixtures() throws {
        let stated = try #require(Self.fixture["parameters"] as? [String: Any])
        #expect(Set(stated.keys) == Set(FigureProgress.Parameters.all.keys))
        for (name, value) in FigureProgress.Parameters.all { #expect(Self.double(stated[name]) == value, "\(name)") }
    }

    @Test func expectedPartsAreTheFixtures() throws {
        let rows = try #require(Self.fixture["expectedParts"] as? [[Any]])
        #expect(rows.count >= 6)
        for row in rows {
            let subfigures = Self.int(row[0]), letters = try #require(Self.int(row[1])), expected = Self.int(row[2])
            #expect(FigureProgress.expectedParts(subfigures: subfigures, captionLetters: letters) == expected, "\(row)")
        }
    }

    @Test func everyCaseIsTheFixtures() throws {
        let cases = try #require(Self.fixture["cases"] as? [[String: Any]])
        #expect(cases.count >= 17)
        for item in cases {
            let name = item["name"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any]), expected = try #require(item["expected"] as? [String: Any])
            let stage = try #require(FigureProgress.Stage(rawValue: input["stage"] as? String ?? ""))
            let state = FigureProgress.state(FigureProgress.Input(
                stage: stage, summary: input["summary"] as? Bool ?? false, parts: Self.int(input["parts"]) ?? 0,
                characters: Self.int(input["characters"]) ?? 0, charactersAtLast: Self.int(input["charactersAtLast"]) ?? 0,
                expected: Self.int(input["expected"]), previous: Self.double(input["previous"])))
            #expect(state.label == expected["label"] as? String, "\(name): \(state.label)")
            #expect(state.value == Self.double(expected["value"]), "\(name): \(String(describing: state.value))")
        }
    }

    /// A streamed request as the events arrive: stage labels in order, the walkthrough so far growing part by part (each
    /// once, in order), the announced count replacing the estimate, and the final `figure` replacing what was streamed.
    @Test func theTrackerFollowsAStreamedWalkthrough() {
        let a = FigureWalkthrough.Section(label: "(a)", title: "A", text: "First."), b = FigureWalkthrough.Section(label: "(b)", title: "B", text: "Second.")
        var tracker = FigureProgress.Tracker(expected: 3), grew: [Bool] = []
        func step(_ event: ChatStreamEvent) { grew.append(tracker.apply(event)) }
        var labels = [tracker.state().label]
        tracker.opened(); labels.append(tracker.state().label)
        step(.figureProgress(.init(stage: .reading)))
        step(.figureProgress(.init(stage: .writing, characters: 200, parts: 2)))
        let summaryValue = tracker.state()
        #expect(summaryValue == .init(label: "Writing the summary…", value: 0.04))
        step(.figureSummary("What it shows."))
        #expect(tracker.walkthroughSoFar == FigureWalkthrough(summary: "What it shows.", sections: []))
        labels.append(tracker.state().label)
        step(.figureSummary("Another"))
        step(.figureProgress(.init(stage: .writing, characters: 1_250)))
        step(.figureSection(index: 0, section: a))
        step(.figureSection(index: 0, section: b))
        labels.append(tracker.state().label)
        // Characters that go back (a reordered step) never move the bar back.
        let before = tracker.state().value ?? 0
        step(.figureProgress(.init(stage: .reading)))
        step(.figureProgress(.init(stage: .writing, characters: 900)))
        let after = tracker.state().value ?? 0
        #expect(tracker.input.stage == .writing && tracker.input.characters == 1_250 && after >= before)
        step(.figureSection(index: 1, section: b))
        #expect(tracker.walkthroughSoFar?.sections == [a, b])
        labels.append(tracker.state().label)
        #expect(labels == ["Preparing the figure…", "Reading the figure…", "Writing part 1 of 2…", "Writing part 2 of 2…", "Writing part 3…"])
        let final = FigureWalkthrough(summary: "What it shows.", sections: [a])
        step(.figure(final))
        #expect(tracker.walkthroughSoFar == final && tracker.final == final, "the final walkthrough replaces what was streamed")
        step(.figureSection(index: 2, section: b))
        // Grew: the summary once, each part once, nothing after the final walkthrough.
        #expect(grew == [false, false, true, false, false, true, false, false, false, true, false, false])
    }

    /// An older server sends only the final `figure`: reading until it comes, then that walkthrough.
    @Test func theTrackerWorksWithAnOlderServer() {
        var tracker = FigureProgress.Tracker(expected: FigureProgress.expectedParts(subfigures: nil, captionLetters: 0))
        tracker.opened()
        #expect(tracker.walkthroughSoFar == nil)
        let final = FigureWalkthrough(summary: "S.", sections: [.init(label: "", title: "T", text: "x")])
        tracker.apply(.delta("ignored")); tracker.apply(.figure(final))
        let state = tracker.state()
        #expect(state == .init(label: "Reading the figure…", value: nil))
        #expect(tracker.final == final)
    }

    /// The bar never goes back as the parts arrive, and turns indeterminate rather than waiting at a made-up end.
    @Test func aWholeRunOnlyMovesForward() {
        var previous: Double?, shown: [Double] = []
        var input = FigureProgress.Input(stage: .writing, expected: 3)
        for (characters, summary, parts, atLast) in [(100, false, 0, 0), (480, false, 0, 0), (600, true, 0, 520), (1_300, true, 0, 520),
                                                     (2_100, true, 1, 2_050), (2_000, true, 1, 2_050), (3_900, true, 2, 3_700), (4_800, true, 2, 3_700)] {
            input.characters = characters; input.summary = summary; input.parts = parts; input.charactersAtLast = atLast; input.previous = previous
            let state = FigureProgress.state(input)
            previous = state.value
            if let value = state.value { shown.append(value) }
        }
        #expect(shown == shown.sorted() && shown.count == 8 && shown.last! < 1)
        input.parts = 3
        #expect(FigureProgress.state(input) == .init(label: "Writing part 4…", value: nil))
        input.stage = .done
        #expect(FigureProgress.state(input) == .init(label: "Done", value: 1))
    }
}
