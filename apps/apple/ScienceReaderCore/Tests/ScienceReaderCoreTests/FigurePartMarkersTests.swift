import Testing
@testable import ScienceReaderCore

/// Where an answer's figure part crops go (owner, 2026-10-15: "the crops should be inline").
struct FigurePartMarkersTests {
    let answer = "Figure 2 has two panels.\n\n[[part 1]]\nThe left panel plots reward.\n\n[[part 2]]\nThe right panel plots win rate."

    @Test func markersSplitTheAnswerAtEachPart() {
        #expect(FigurePartMarkers.segments(answer, parts: 2) == [.text("Figure 2 has two panels."), .part(1), .text("The left panel plots reward."),
                                                                 .part(2), .text("The right panel plots win rate.")])
        #expect(FigurePartMarkers.hasMarkers(answer))
        #expect(!FigurePartMarkers.hasMarkers("No parts here. [[ not a marker"))
    }

    @Test func aMarkerPastThePartsAndTextOnItsLineAreHandled() {
        let text = "Intro.\n[[Part 3]] Trailing words.\n[[part 1]]\nOne."
        #expect(FigurePartMarkers.segments(text, parts: 2) == [.text("Intro."), .text("Trailing words."), .part(1), .text("One.")])
    }

    @Test func noPartsLeavesEveryMarkerOut() {
        #expect(FigurePartMarkers.segments("[[part 1]]\nOne.", parts: 0) == [.text("One.")])
    }

    @Test func strippingLeavesNoMarkerAndNoHalfMarkerWhileStreaming() {
        #expect(FigurePartMarkers.stripped(answer) == "Figure 2 has two panels.\n\nThe left panel plots reward.\n\nThe right panel plots win rate.")
        #expect(FigurePartMarkers.stripped("Intro.\n\n[[par", streaming: true) == "Intro.\n")
        #expect(FigurePartMarkers.stripped("Plain [[links]] stay.") == "Plain [[links]] stay.")
    }
}
