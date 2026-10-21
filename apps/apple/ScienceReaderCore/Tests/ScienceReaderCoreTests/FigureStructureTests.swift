import Foundation
import Testing
@testable import ScienceReaderCore

/// Structure first (FigureStructure.swift; FIGURE_VIEW.md "Structure first") against the shared fixture
/// tests/fixtures/figure-crops/structure.json, which the browser's figure-structure.test.ts reads (and writes) too: the same
/// sub-figures, bands, note, quote and section matches from the same markup.
@Suite struct FigureStructureTests {
    struct Size: Decodable { let width: Int; let height: Int }
    struct Fixture: Decodable {
        struct Part: Decodable { let letter: String?; let caption: String; let label: String; let images: [Int]; let rect: [Double] }
        struct Structure: Decodable { let parts: [Part]; let images: Int; let composed: Int; let width: Int; let height: Int }
        struct Expect: Decodable { let structure: Structure?; let note: String?; let quote: String }
        struct Case: Decodable { let name: String; let markup: String; let assetPaths: [String]; let sizes: [Size?]; let caption: String; let expect: Expect }
        struct Section: Decodable { let label: String; let title: String; let kind: String?; let box: [Double]? }
        struct Match: Decodable { let name: String; let structure: String; let sections: [Section]; let expect: [Int?] }
        struct Sub: Decodable { struct Expect: Decodable { let letter: String; let words: String }; let text: String; let expect: Expect? }
        struct Layout: Decodable { struct Expect: Decodable { let width: Int; let height: Int; let bands: [[Int]] }; let sizes: [Size]; let expect: Expect }
        let parameters: [String: Double]; let cases: [Case]; let matches: [Match]; let subcaptions: [Sub]; let stackLayouts: [Layout]
    }
    static let fixture = try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: FigureCropCompletionTests.directory.appendingPathComponent("structure.json")))

    static func structure(_ c: Fixture.Case) -> FigureStructure? {
        FigureStructure.make(markup: c.markup, assetPaths: c.assetPaths, sizes: c.sizes.map { $0.map { ($0.width, $0.height) } }, caption: c.caption)
    }

    @Test func usesTheParametersTheFixtureStates() {
        #expect(FigureStructure.Parameters.all == Self.fixture.parameters)
    }

    @Test(arguments: fixture.cases.map(\.name)) func readsTheSharedFixture(_ name: String) throws {
        let c = try #require(Self.fixture.cases.first { $0.name == name })
        let s = Self.structure(c)
        #expect((s == nil) == (c.expect.structure == nil), "\(name)")
        if let s, let want = c.expect.structure {
            #expect(s.images == want.images && s.composed == want.composed && s.width == want.width && s.height == want.height, "\(name)")
            #expect(s.parts.count == want.parts.count, "\(name)")
            for (part, w) in zip(s.parts, want.parts) {
                #expect(part.letter == w.letter && part.caption == w.caption && part.label == w.label && part.images == w.images, "\(name): \(part)")
                for (a, b) in zip([part.rect.x0, part.rect.y0, part.rect.x1, part.rect.y1], w.rect) { #expect(abs(a - b) < 1e-9, "\(name) rect") }
            }
            #expect(s.note == c.expect.note, "\(name) note")
        }
        #expect(FigureStructure.quote(caption: c.caption, s) == c.expect.quote, "\(name) quote")
    }

    @Test(arguments: fixture.matches.map(\.name)) func matchesSections(_ name: String) throws {
        let m = try #require(Self.fixture.matches.first { $0.name == name })
        let c = try #require(Self.fixture.cases.first { $0.name == m.structure })
        let sections = m.sections.map { FigureStructure.Section(label: $0.label, title: $0.title, kind: $0.kind, box: $0.box.map { CropRect($0[0], $0[1], $0[2], $0[3]) }) }
        #expect(FigureStructure.match(sections, Self.structure(c)) == m.expect, "\(name)")
    }

    @Test func readsSubcaptionsAndLaysOutTheCompositeAsItIsDrawn() {
        for x in Self.fixture.subcaptions {
            let got = FigureStructure.subcaption(x.text)
            #expect(got?.letter == x.expect?.letter && got?.words == x.expect?.words, "\(x.text)")
        }
        for x in Self.fixture.stackLayouts {
            let got = FigureStructure.stackLayout(x.sizes.map { ($0.width, $0.height) })
            #expect(got.width == x.expect.width && got.height == x.expect.height && got.bands.map { [$0.top, $0.bottom] } == x.expect.bands)
        }
    }

    @Test func keepsAStructureOnlyForTheImageItDescribesAndQuotesWithinTheLimit() throws {
        let s = try #require(Self.structure(Self.fixture.cases[0]))
        #expect(s.fits(width: Int((1568.0 * Double(s.width) / Double(s.height)).rounded()), height: 1568))
        #expect(!s.fits(width: s.width, height: Int(Double(s.height) * 0.8)))
        let long = String(repeating: "x", count: FigureStructure.Parameters.quoteScalars - 50)
        #expect(FigureStructure.quote(caption: long, s) == long)
        // The same markup as the bundle's page holds it: found by its block and read the same way.
        let page = "<p>x</p>" + Self.fixture.cases[0].markup
        #expect(EquationMarkup.block(in: page, blockID: "b-1") == Self.fixture.cases[0].markup)
    }
}
