import Foundation
import ScienceReaderCore

/// Starter questions for an empty chat (docs/architecture/CHAT.md, chat redesign 2026-10-16; owner, build 57: "a list of
/// good ones, not always the same boring ones"): three different categories from the shared pool (chat-starters.json,
/// the browser's file), at least one about this paper's own structure when it has any, drawn afresh for each new chat
/// from its seed. The same selection as the browser's chat-starters.ts: both reproduce
/// tests/fixtures/chat-starters-cases.json, so a seed gives the same three questions everywhere.
enum ChatStarters {
    struct Paper: Equatable, Sendable { var figures: [String]; var tables: [String]; var equations: Int; var headings: [String] }
    struct Starter: Equatable, Hashable, Sendable { let category: String; let icon: String; let text: String }

    private struct Pool: Decodable {
        struct Category: Decodable { let category: String; let icon: String; let templates: [String] }
        struct General: Decodable { let icon: String; let text: String }
        let paper: [Category]
        let general: [General]
    }
    private static let pool: Pool? = Bundle.main.url(forResource: "chat-starters", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Pool.self, from: $0) }

    /// The paper's inputs from its reading index: figure numbers from the figure captions, table numbers from any caption
    /// or block that starts "Table N", display equations, and the headings in order.
    static func paper(_ index: ReaderBundleIndex) -> Paper {
        Paper(figures: captionNumbers(index.figures.map(\.caption), word: "Figure"),
              tables: captionNumbers(index.figures.map(\.caption) + index.blocks.map(\.text), word: "Table"),
              equations: index.equations.filter(\.display).count, headings: index.headings.map(\.title))
    }

    /// mulberry32: a small 32-bit generator both clients reproduce exactly.
    struct Random {
        private var state: UInt32
        init(seed: UInt32) { state = seed }
        mutating func next() -> Double {
            state = state &+ 0x6D2B_79F5
            var t = (state ^ (state >> 15)) &* (1 | state)
            t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
            return Double(t ^ (t >> 14)) / 4_294_967_296
        }
        mutating func pick(_ count: Int) -> Int { Int((next() * Double(count)).rounded(.down)) }
    }

    private static let skipped = try! NSRegularExpression(pattern: #"^(abstract|introduction|related work|related works|background|preliminar|notation|problem (setup|setting|formulation|statement)|experiment|results|evaluation|discussion|conclusion|limitation|future work|appendix|references|bibliography|acknowledg|broader impact|ethic|summary)"#, options: .caseInsensitive)
    private static let generic = try! NSRegularExpression(pattern: #"^(method|methods|methodology|approach|our approach|proposed method|the proposed method|model|our method|framework)$"#, options: .caseInsensitive)
    private static let numbered = try! NSRegularExpression(pattern: #"^\s*(?:\d+|[IVX]+)\.?\s+(.+?)\s*$"#)

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The paper's method section: the first numbered top-level heading that isn't front or back matter, without its
    /// number; nil when there is none or its name is generic ("Method").
    static func methodHeading(_ headings: [String]) -> String? {
        for raw in headings {
            guard let m = numbered.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let range = Range(m.range(at: 1), in: raw) else { continue }
            let title = String(raw[range])
            if title.first?.isNumber == true || matches(skipped, title) { continue }
            if matches(generic, title) || title.count > 60 { return nil }
            return title
        }
        return nil
    }

    /// "Figure 2: …" → "2": the figures or tables the texts name, in order, unique, the first eight.
    static func captionNumbers(_ texts: [String], word: String) -> [String] {
        let pattern = word == "Figure" ? #"^\s*(?:Figure|Fig\.)\s*(\d{1,3})\b"# : #"^\s*Table\s*(\d{1,3})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        var out: [String] = []
        for text in texts {
            if let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(m.range(at: 1), in: text),
               !out.contains(String(text[range])) { out.append(String(text[range])) }
            if out.count == 8 { break }
        }
        return out
    }

    private static let structure: Set<String> = ["method", "figure", "equation", "table"]

    /// Three starters for a paper (nil: general chat) from `seed`; empty if the pool is missing.
    static func choose(_ paper: Paper?, seed: UInt32) -> [Starter] {
        guard let pool else { return [] }
        return choose(paper, seed: seed, paperPool: pool.paper.map { ($0.category, $0.icon, $0.templates) },
                      generalPool: pool.general.map { ($0.icon, $0.text) })
    }

    static func choose(_ paper: Paper?, seed: UInt32, paperPool: [(category: String, icon: String, templates: [String])],
                       generalPool: [(icon: String, text: String)]) -> [Starter] {
        var random = Random(seed: seed)
        guard let paper else {
            var left = generalPool, out: [Starter] = []
            while out.count < 3 && !left.isEmpty { let g = left.remove(at: random.pick(left.count)); out.append(Starter(category: "general", icon: g.icon, text: g.text)) }
            return out
        }
        let method = methodHeading(paper.headings)
        func usable(_ category: String, _ templates: [String]) -> [String] {
            templates.filter { t in
                (!t.contains("{figure}") || !paper.figures.isEmpty) && (!t.contains("{table}") || !paper.tables.isEmpty)
                    && (!t.contains("{method}") || method != nil) && (category != "equation" || paper.equations > 0)
                    && (category != "figure" || !paper.figures.isEmpty) && (category != "table" || !paper.tables.isEmpty)
            }
        }
        let categories = paperPool.map { (category: $0.category, icon: $0.icon, usable: usable($0.category, $0.templates)) }.filter { !$0.usable.isEmpty }
        let structural = categories.filter { structure.contains($0.category) && ($0.category != "method" || method != nil) }
        var chosen: [(category: String, icon: String, usable: [String])] = []
        if !structural.isEmpty { chosen.append(structural[random.pick(structural.count)]) }
        var rest = categories.filter { c in !chosen.contains { $0.category == c.category } }
        while chosen.count < 3 && !rest.isEmpty { chosen.append(rest.remove(at: random.pick(rest.count))) }
        return chosen.map { c in
            var text = c.usable[random.pick(c.usable.count)]
            if text.contains("{figure}") { text = text.replacingOccurrences(of: "{figure}", with: paper.figures[random.pick(paper.figures.count)]) }
            if text.contains("{table}") { text = text.replacingOccurrences(of: "{table}", with: paper.tables[random.pick(paper.tables.count)]) }
            if text.contains("{method}"), let method { text = text.replacingOccurrences(of: "{method}", with: method) }
            return Starter(category: c.category, icon: c.icon, text: text)
        }
    }
}
