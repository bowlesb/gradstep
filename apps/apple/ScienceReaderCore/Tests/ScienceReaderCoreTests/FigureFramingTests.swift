import CoreGraphics
import Foundation
import Testing
@testable import ScienceReaderCore

/// Part framing (FigureFraming.swift; FIGURE_VIEW.md "Parts as viewports") against the shared fixture
/// tests/fixtures/figure-crops/framing.json, which the browser's figure-framing.test.ts reads too: the same parameters,
/// levels, scores, reasons, frames and regions on the same real figures. And the local framing record.
@Suite struct FigureFramingTests {
    struct Fixture: Decodable {
        struct Part: Decodable {
            let level: String; let score: Double; let reasons: [String]; let extra: Bool; let veil: Double; let outlined: Bool
            let framePixels: [Double]; let regionPixels: [Double]
        }
        struct Expect: Decodable { let coverage: Double?; let parts: [Part] }
        struct Case: Decodable {
            let name: String; let image: String; let width: Int; let height: Int; let unchecked: Bool; let boxes: [[Double]]; let labels: [String]
            let caption: String; let detector: [Double?]?; let expect: Expect
        }
        struct Letters: Decodable { let caption: String; let letters: [String] }
        struct Label: Decodable { let label: String; let letter: String? }
        let parameters: [String: Double]; let tolerancePixels: Double; let toleranceScore: Double
        let cases: [Case]; let captionLetters: [Letters]; let labelLetters: [Label]
    }
    static let fixture = try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: FigureCropCompletionTests.directory.appendingPathComponent("framing.json")))

    static func framed(_ c: Fixture.Case) throws -> (parts: [FramedPart], coverage: Double?) {
        let ink = c.unchecked ? nil : try FigureCropCompletionTests.ink(c.image)
        return FigureFraming.frame(ink, width: c.width, height: c.height, boxes: c.boxes.map { CropRect($0[0], $0[1], $0[2], $0[3]) },
                                   caption: c.caption, labels: c.labels, detector: c.detector)
    }

    @Test func usesTheParametersTheFixtureStates() {
        #expect(FigureFraming.Parameters.all == Self.fixture.parameters)
    }

    @Test(arguments: fixture.cases.map(\.name)) func matchesTheSharedFixture(_ name: String) throws {
        let c = try #require(Self.fixture.cases.first { $0.name == name })
        let result = try Self.framed(c)
        if let coverage = c.expect.coverage { #expect(abs((result.coverage ?? -1) - coverage) < 1e-4, "\(name) coverage") }
        else { #expect(result.coverage == nil) }
        #expect(result.parts.count == c.expect.parts.count)
        let W = Double(c.width), H = Double(c.height)
        for (part, want) in zip(result.parts, c.expect.parts) {
            #expect(part.level.rawValue == want.level, "\(name)")
            #expect(part.reasons.map(\.rawValue) == want.reasons, "\(name)")
            #expect(part.extra == want.extra && part.veil == want.veil && part.outlined == want.outlined, "\(name)")
            #expect(abs(part.score - want.score) <= Self.fixture.toleranceScore, "\(name): \(part.score) vs \(want.score)")
            for (a, b) in zip([part.frame.x0 * W, part.frame.y0 * H, part.frame.x1 * W, part.frame.y1 * H], want.framePixels) {
                #expect(abs(a - b) <= Self.fixture.tolerancePixels, "\(name) frame: \(part.frame) vs \(want.framePixels)")
            }
            for (a, b) in zip([part.region.x0 * W, part.region.y0 * H, part.region.x1 * W, part.region.y1 * H], want.regionPixels) {
                #expect(abs(a - b) <= Self.fixture.tolerancePixels, "\(name) region: \(part.region) vs \(want.regionPixels)")
            }
        }
    }

    @Test func readsPanelLettersFromCaptionsAndLabels() {
        for item in Self.fixture.captionLetters { #expect(FigureFraming.captionLetters(item.caption) == item.letters, "\(item.caption)") }
        for item in Self.fixture.labelLetters { #expect(FigureFraming.labelLetter(item.label) == item.letter, "\(item.label)") }
    }

    @Test func keepsOnlyTheCaptionsPanelsLetteredOnesFirst() {
        #expect(FigureFraming.keptParts(["(a)", "(b)", "Legend"], letters: ["a", "b"]) == [true, true, false])
        #expect(FigureFraming.keptParts(["Legend", "(b)", "(a)"], letters: ["a", "b"]) == [false, true, true])
        #expect(FigureFraming.keptParts(["Left", "Middle", "Right"], letters: ["a", "b"]) == [true, true, false])
        #expect(FigureFraming.keptParts(["(a)", "(a)", "Right"], letters: ["a", "b"]) == [true, false, true])
        #expect(FigureFraming.keptParts(["x", "y", "z"], letters: []) == [true, true, true])
    }

    @Test func revealsContextOnceTheReaderZoomsOrPans() throws {
        let c = try #require(Self.fixture.cases.first { $0.name == "imprecise-box-reaches-neighbour" })
        let parts = try Self.framed(c).parts
        #expect(parts[0].look(revealed: false) == (1, false))
        #expect(parts[0].look(revealed: true) == (FigureFraming.Parameters.veilRevealed, true))
        #expect(abs(parts[0].aspect(width: c.width, height: c.height) - 684.0 / 504.0) < 1e-3)
    }

    /// A tight frame at rest renders as the crop did: the completed crop on its margin of white, nothing else of the figure.
    @Test func aTightFrameRendersAsTheCropDid() throws {
        let c = try #require(Self.fixture.cases.first { $0.name == "imprecise-box-reaches-neighbour" })
        let image = try FigureCropCompletionTests.image(c.image), parts = try Self.framed(c).parts
        let tight = try #require(parts[0].renderFrame(image, outline: CGColor(red: 0.31, green: 0.32, blue: 0.81, alpha: 1), lineWidth: 2))
        #expect(tight.width == 684 && tight.height == 504)
        let cut = try #require(PresentedCrop(ink: c.width, c.height, crop: CropRect(8, 8, 672, 492)).image(from: image))
        #expect(cut.width == tight.width && cut.height == tight.height)
        // The loose frame keeps its aspect and shows the part with some of the left plot around it (outlined).
        let loose = try #require(parts[1].renderFrame(image, outline: CGColor(red: 0.31, green: 0.32, blue: 0.81, alpha: 1), lineWidth: 2))
        #expect(abs(Double(loose.width) / Double(loose.height) - parts[1].aspect(width: c.width, height: c.height)) < 0.01)
    }

    @Test func recordsGeometryOnlyForArxivFiguresAndForgetsOnClear() {
        let recorder = FigureFramingRecorder()
        recorder.shown("a", nil)
        #expect(recorder.all.isEmpty, "nothing without an arXiv identity")
        let record = FigureFramingRecord(figure: ArxivFigure(sourceID: "2305.18290", revision: 3, figure: "Figure 2"), surface: .walkthrough, part: 1, parts: 2,
                                         level: .medium, box: CropRect(0.45, 0.1, 0.99, 0.9), region: CropRect(0.45, 0.031936, 0.994118, 0.99002),
                                         frame: CropRect(0.352059, -0.01996, 1.007353, 1.01996))
        recorder.shown("a", record)
        recorder.shown("a", record)
        recorder.changed("a", view: CropRect(0.123456, 0, 1, 1), zoomed: true)
        recorder.changed("a", expanded: true)
        recorder.changed("unknown", expanded: true)
        let kept = recorder.all
        #expect(kept.count == 1)
        #expect(kept[0].finalView == CropRect(0.1235, 0, 1, 1) && kept[0].zoomed && !kept[0].panned && kept[0].expanded)
        #expect(kept[0].frame == CropRect(0.3521, -0.02, 1.0074, 1.02))
        for i in 0..<(FigureFramingRecorder.limit + 5) { recorder.shown("k\(i)", record) }
        #expect(recorder.all.count == FigureFramingRecorder.limit)
        recorder.clear()
        #expect(recorder.all.isEmpty)
    }
}
