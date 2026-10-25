import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// The Library search over the encrypted full-text index (docs/architecture/NATIVE_LIBRARY_SEARCH.md, "Full-text index"):
/// body matches join metadata matches, metadata substring matching never gets worse, relevance orders the default
/// sort, and body matches bring snippets.
final class LibraryFullTextSearchTests: XCTestCase {
    private var directory: URL!
    private var store: FullTextIndexStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("library-fts-\(UUID().uuidString)", isDirectory: true)
        store = try FullTextIndexStore(directory: directory, accountID: UUID(), localKey: Data(repeating: 7, count: 32))
        let documents = [
            FullTextLibrary.metadata(group: "a", title: "Graph networks for chemistry", authors: "Ada Lovelace", tags: ["Graphs"],
                                     abstract: "Message passing on molecules.", notes: ""),
            FullTextLibrary.body(group: "a", fingerprint: "s:a", text: "We measure superconducting qubits in a dilution refrigerator. "
                                 + String(repeating: "Unrelated filler text about experiments. ", count: 30)),
            FullTextLibrary.metadata(group: "b", title: "Qubits: an overview", authors: "Grace Hopper", tags: [], abstract: "A survey.", notes: ""),
            FullTextLibrary.metadata(group: "c", title: "Cooking with lasers", authors: "Someone Else", tags: [], abstract: "", notes: "remember the qubit idea"),
        ]
        try await store.commit(FullTextIndexStore.prepare(documents))
    }

    override func tearDown() async throws {
        await store.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func candidates() -> [LibrarySearchCandidate] {
        [LibrarySearchCandidate(id: "paper/a", title: "Graph networks for chemistry", fields: ["Graph networks for chemistry", "Ada Lovelace", "Message passing on molecules."],
                                recentSequence: 1, position: 0, fullTextKey: "a", fieldKinds: [.title, .authors, .abstract]),
         LibrarySearchCandidate(id: "paper/b", title: "Qubits: an overview", fields: ["Qubits: an overview", "Grace Hopper", "A survey."],
                                recentSequence: 3, position: 1, fullTextKey: "b", fieldKinds: [.title, .authors, .abstract]),
         LibrarySearchCandidate(id: "paper/c", title: "Cooking with lasers", fields: ["Cooking with lasers", "Someone Else"],
                                recentSequence: 2, position: 2, fullTextKey: "c"),
         LibrarySearchCandidate(id: "import/x", title: "Pending superconducting import", fields: ["Pending superconducting import"],
                                recentSequence: 4, position: 3)]
    }

    private func run(_ query: String, sort: LibrarySearchSort = .recent) async throws -> LibrarySearchOutput {
        let key = LibrarySearchKey(sessionID: UUID(), accountID: nil, sourceRevision: 1, query: query, sort: sort)
        return try await LibrarySearchEngine.run(LibrarySearchInput(ticket: .init(key: key), candidates: candidates(), fullText: store))
    }

    /// Each result says how it matched (owner, TestFlight 91 session): the share of words at their strongest fields, the
    /// title's matched words, and one excerpt of where else it matched.
    func testResultsCarryTheirMatchStrengthTitleMarksAndExcerpt() async throws {
        let mixed = try await run("graph superconducting ")
        let a = try XCTUnwrap(mixed.matches["paper/a"])
        XCTAssertEqual(a.match.label, "100% · title, full text")
        XCTAssertEqual(a.titleHighlights, [0..<5])
        XCTAssertEqual(a.excerptField, .fullText)
        XCTAssertTrue(a.excerpt?.text.contains("superconducting qubits") == true)
        // A clause matched by the metadata substring rule counts at that field's kind (the import's only field: title).
        let substring = try await run("superconducting ")
        XCTAssertEqual(substring.matches["import/x"]?.match.label, "100% · title")
        // In the abstract: the excerpt is the abstract around the word.
        let abstract = try await run("molecules ")
        XCTAssertEqual(abstract.matches["paper/a"]?.match.label, "100% · abstract")
        XCTAssertEqual(abstract.matches["paper/a"]?.excerptField, .abstract)
        XCTAssertEqual(abstract.matches["paper/a"]?.excerpt?.firstMatch, "molecules")
        // Every word in the title: the title shows them, no excerpt.
        let title = try await run("qubits overview ")
        XCTAssertEqual(title.matches["paper/b"]?.match.label, "100% · title")
        XCTAssertNil(title.matches["paper/b"]?.excerpt)
        // In a note only.
        let notes = try await run("qubit ")
        XCTAssertEqual(notes.matches["paper/c"]?.match.label, "100% · notes")
        XCTAssertEqual(notes.matches["paper/b"]?.match.label, "100% · title")
        // No query, no match lines.
        let all = try await run("")
        XCTAssertTrue(all.matches.isEmpty)
    }

    func testBodyMatchesJoinMetadataMatchesWithASnippet() async throws {
        let body = try await run("superconducting ")
        XCTAssertEqual(Set(body.rowIDs), ["paper/a", "import/x"], "the paper by its text, the import by its metadata as before")
        let snippet = try XCTUnwrap(body.snippets["paper/a"])
        XCTAssertTrue(snippet.text.contains("superconducting qubits"))
        XCTAssertEqual(snippet.firstMatch, "superconducting")
        XCTAssertNil(body.snippets["import/x"])
        // One word from the title, one from the body: both required, both satisfied.
        let rows1 = try await run("graph superconducting").rowIDs
        XCTAssertEqual(rows1, ["paper/a"])
        let rows2 = try await run("\"dilution refrigerator\"").rowIDs
        XCTAssertEqual(rows2, ["paper/a"])
        let rows3 = try await run("\"refrigerator dilution\"").rowIDs
        XCTAssertTrue(rows3.isEmpty)
    }

    func testMetadataSubstringMatchingStillApplies() async throws {
        // "raph" is inside "Graph": not a word or prefix, but the metadata substring rule keeps finding it.
        let rows4 = try await run("raph").rowIDs
        XCTAssertEqual(rows4, ["paper/a"])
        let rows5 = try await run("HOPPER").rowIDs
        XCTAssertEqual(rows5, ["paper/b"])
        let rows6 = try await run("nothing-matches-this").rowIDs
        XCTAssertTrue(rows6.isEmpty)
        // Without an index, the same metadata-only rows.
        let key = LibrarySearchKey(sessionID: UUID(), accountID: nil, sourceRevision: 1, query: "raph", sort: .recent)
        XCTAssertEqual(try LibrarySearchEngine.search(LibrarySearchInput(ticket: .init(key: key), candidates: candidates())), ["paper/a"])
    }

    func testRelevanceOrdersTheDefaultSortAndOtherSortsStay() async throws {
        // "qubit": b's title, a's body, c's notes. Title first, then notes above body.
        let ranked = try await run("qubit ")
        XCTAssertEqual(ranked.rowIDs, ["paper/b", "paper/c", "paper/a"])
        XCTAssertEqual(Set(ranked.snippets.keys), ["paper/a"], "only the body match has a snippet")
        // An explicit order is kept: Title A→Z.
        let rows7 = try await run("qubit ", sort: .title).rowIDs
        XCTAssertEqual(rows7, ["paper/c", "paper/a", "paper/b"])
        // The last word is a prefix while typing.
        let rows8 = try await run("qub").rowIDs
        XCTAssertEqual(Set(rows8), ["paper/a", "paper/b", "paper/c"])
    }
}
