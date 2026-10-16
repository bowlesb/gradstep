import Foundation
import Testing
@testable import ScienceReader

/// Starter questions (chat redesign 2026-10-16): the native selection reproduces every case the browser's
/// chat-starters.ts generated (tests/fixtures/chat-starters-cases.json), from the pool the app ships.
struct ChatStartersTests {
    private struct Fixture: Decodable {
        struct Random: Decodable { let seed: UInt32; let first: [Double] }
        struct Input: Decodable { let captions: [String]; let tableCaptions: [String] }
        struct Paper: Decodable { let figures: [String]; let tables: [String]; let equations: Int; let headings: [String] }
        struct Case: Decodable { let name: String; let seed: UInt32; let input: Input?; let paper: Paper?; let expected: [Expected] }
        struct Expected: Decodable { let category: String; let icon: String; let text: String }
        let random: Random
        let methodHeadings: [MethodCase]
        let cases: [Case]
    }
    private struct MethodCase: Decodable {
        let headings: [String]; let expected: String?
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            headings = try c.decode([String].self); expected = try c.decodeIfPresent(String.self)
        }
    }
    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../tests/fixtures/chat-starters-cases.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test func everySharedCaseIsReproduced() throws {
        let fixture = try fixture()
        var random = ChatStarters.Random(seed: fixture.random.seed)
        #expect([random.next(), random.next(), random.next()] == fixture.random.first)
        for item in fixture.methodHeadings { #expect(ChatStarters.methodHeading(item.headings) == item.expected) }
        for item in fixture.cases {
            if let input = item.input, let paper = item.paper {
                #expect(ChatStarters.captionNumbers(input.captions, word: "Figure") == paper.figures)
                #expect(ChatStarters.captionNumbers(input.tableCaptions, word: "Table") == paper.tables)
            }
            let paper = item.paper.map { ChatStarters.Paper(figures: $0.figures, tables: $0.tables, equations: $0.equations, headings: $0.headings) }
            let chosen = ChatStarters.choose(paper, seed: item.seed)
            #expect(chosen.map(\.text) == item.expected.map(\.text), "\(item.name) seed \(item.seed)")
            #expect(chosen.map(\.icon) == item.expected.map(\.icon) && chosen.map(\.category) == item.expected.map(\.category))
        }
    }
}
