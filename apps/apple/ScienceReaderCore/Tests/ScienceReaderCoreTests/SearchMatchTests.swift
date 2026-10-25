import Foundation
import Testing
@testable import ScienceReaderCore

/// Match strength and highlights for search results (owner, TestFlight 91 session: "at bare minimum having the match
/// percent"; "it's very difficult for me to know what about it is matching").
@Suite struct SearchMatchTests {
    private func marked(_ snippet: FullTextSnippet) -> [String] {
        let units = Array(snippet.text.utf16)
        return snippet.highlights.map { String(decoding: units[$0], as: UTF16.self) }
    }

    @Test func percentIsTheShareOfWordsFoundAndFieldsAreStrongestFirst() {
        let all = SearchMatch(clauseFields: [.title, .title])
        #expect(all.percent == 100 && all.label == "100% · title")
        #expect(all.spokenLabel == "Matches all 2 search words, in the title")
        let some = SearchMatch(clauseFields: [.fullText, nil, .title])
        #expect(some.matched == 2 && some.total == 3 && some.percent == 67)
        #expect(some.label == "67% · title, full text")
        #expect(some.spokenLabel == "Matches 2 of 3 search words, in the title and the full text")
        let one = SearchMatch(clauseFields: [.abstract])
        #expect(one.label == "100% · abstract" && one.spokenLabel == "Matches your search word, in the abstract")
        let none = SearchMatch(clauseFields: [nil, nil])
        #expect(none.percent == 0 && none.label == "0%")
        #expect(SearchMatch(clauseFields: [.notes, .authors, .tags, .abstract]).fields == [.abstract, .authors, .tags, .notes])
    }

    @Test func evaluateCountsEachWordAtItsStrongestField() {
        let query = FullTextQuery("diffusion transformers scaling ")
        let match = SearchHighlighter.evaluate(query, fields: [
            (.abstract, "We study scaling of diffusion models."),
            (.title, "Diffusion Transformer"),
            (.authors, "A. Person")])
        // "transformers" is found as "Transformer" (plurals fold); "diffusion" counts at the title, not the abstract.
        #expect(match.clauseFields == [.title, .title, .abstract])
        #expect(match.label == "100% · title, abstract")
        let partial = SearchHighlighter.evaluate(FullTextQuery("graph neural chemistry "), fields: [(.title, "Graph networks"), (.abstract, "Neural message passing.")])
        #expect(partial.label == "67% · title, abstract")
    }

    @Test func phrasesCountAsOneWordAndNeedAdjacentWords() {
        let query = FullTextQuery(#""score matching" diffusion "#)
        #expect(SearchHighlighter.evaluate(query, fields: [(.title, "Score matching for diffusion")]).percent == 100)
        #expect(SearchHighlighter.evaluate(query, fields: [(.title, "Matching the score of diffusion")]).clauseFields == [nil, .title])
    }

    @Test func theWordBeingTypedMatchesAsAPrefixAndLooseMatchingFoldsEndings() {
        #expect(SearchHighlighter.evaluate(FullTextQuery("transfo"), fields: [(.title, "Transformers")]).percent == 100)
        #expect(SearchHighlighter.evaluate(FullTextQuery("transfo "), fields: [(.title, "Transformers")]).percent == 0)
        let query = FullTextQuery("learning optimize ")
        let text = "Learned optimizers"
        #expect(SearchHighlighter.evaluate(query, fields: [(.title, text)]).percent == 0)
        #expect(SearchHighlighter.evaluate(query, fields: [(.title, text)], loose: true).percent == 100)
    }

    @Test func anArxivIdentifierMatchesTheResultsID() {
        let match = SearchHighlighter.evaluate(FullTextQuery("arXiv:2106.09685v2"), fields: [(.identifier, "2106.09685"), (.title, "LoRA")])
        #expect(match.label == "100% · ID")
        #expect(SearchHighlighter.evaluate(FullTextQuery("2106.09685"), fields: [(.identifier, "2106.09686")]).percent == 0)
    }

    @Test func highlightsMarkWordsCompoundsAndPhrases() {
        let title = "Self-attention and Café networks"
        let marks = SearchHighlighter.highlights(FullTextQuery("cafe network attention "), in: title)
        let units = Array(title.utf16)
        #expect(marks.map { String(decoding: units[$0], as: UTF16.self) } == ["attention", "Café", "networks"])
        let compound = SearchHighlighter.highlighted(FullTextQuery("selfattention "), in: title)
        #expect(marked(compound) == ["Self-attention"])
        let phrase = SearchHighlighter.highlighted(FullTextQuery(#""café networks""#), in: title)
        #expect(marked(phrase) == ["Café networks"])
        // Unicode before a match keeps UTF-16 offsets right.
        let emoji = SearchHighlighter.highlighted(FullTextQuery("graph "), in: "🙂 naïve graph")
        #expect(marked(emoji) == ["graph"])
    }

    @Test func excerptCentresTheDensestMatchesAndStartsAtTheBeginningWhenClose() throws {
        let early = try #require(SearchHighlighter.excerpt(FullTextQuery("attention "), in: "We revisit attention for long contexts.\n\nMore  text."))
        #expect(early.text == "We revisit attention for long contexts. More text.")
        #expect(marked(early) == ["attention"])
        let filler = String(repeating: "lorem ipsum dolor ", count: 20)
        let text = filler + "a sparse mixture of experts scales " + filler + "experts again and sparse later " + filler
        let late = try #require(SearchHighlighter.excerpt(FullTextQuery("sparse experts "), in: text, length: 80))
        #expect(late.text.hasPrefix("…") && late.text.hasSuffix("…"))
        #expect(marked(late).map { $0.lowercased() } == ["sparse", "experts"])
        #expect(late.text.utf16.count <= 84)
        #expect(SearchHighlighter.excerpt(FullTextQuery("absent "), in: text) == nil)
    }

    @Test func indexHitsRecordEveryFieldAClauseMatched() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fts-match-\(UUID().wire)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FullTextIndexStore(directory: directory, accountID: UUID(), localKey: Data(repeating: 7, count: 32))
        try await index.commit(FullTextIndexStore.prepare([
            FullTextDocument(id: .init(group: "a", part: .metadata), fingerprint: "m", fields: [.title: "Diffusion models", .abstract: "Score matching for images."]),
            FullTextDocument(id: .init(group: "a", part: .body), fingerprint: "b", fields: [.body: "We train diffusion models with score matching and transformers."])]))
        let query = FullTextQuery(#"diffusion "score matching" transformer "#)
        let hit = try #require(try await index.snapshot().search(query)["a"])
        #expect(hit.strongestField(clause: 0) == .title)
        #expect(hit.strongestField(clause: 1) == .abstract)
        #expect(hit.strongestField(clause: 2) == .fullText)
        #expect(hit.fieldClauses[FullTextField.body.rawValue] == 0b111)
    }
}
