import Foundation
import Testing
@testable import ScienceReaderCore

/// Snippets' search (NOTES_AND_SNIPPETS.md "Search", owner feedback on TestFlight 91): every text field of a snippet,
/// the reading's text and LaTeX under a drawn region, recognised text, folded and matched as word prefixes.
@Suite struct NoteSearchTests {
    private let manifest = String(repeating: "ab", count: 32)

    private func state(_ notes: [(NoteRecord, [NoteEntryRecord])]) throws -> NotesState {
        var state = PrivateState()
        let device = UUID()
        for (note, entries) in notes {
            try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: try NotesRecord.note(note).event(createdAt: note.createdAt)))
            for entry in entries {
                try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: try NotesRecord.entry(entry).event(createdAt: entry.capturedAt)))
            }
        }
        return NotesState(state)
    }

    private func entry(_ note: UUID, _ counter: Int64, kind: NoteEntryRecord.Kind = .quote, comment: String = "", quote: String? = "Words",
                       source: NoteSource? = nil, anchor: NoteAnchor? = nil) -> NoteEntryRecord {
        NoteEntryRecord(noteID: note, kind: kind, counter: counter, capturedAt: 1_760_000_000_000 + counter, offsetMinutes: 0,
                        comment: comment, source: source, anchor: anchor, quote: quote)
    }

    @Test func termsAreFoldedAndDeduplicated() {
        #expect(NoteSearch.terms("  Café  CAFE résumé ") == ["cafe", "resume"])
        #expect(NoteSearch.terms("2106.09685") == ["2106.09685"])
        #expect(NoteSearch.terms("   ").isEmpty)
    }

    @Test func prefixesMatchDiacriticAndCaseInsensitively() {
        let words = NoteSearch.words(["Scaled Dot-Product Attention", "Café table"])
        #expect(NoteSearch.matches(["atten"], in: words))
        #expect(NoteSearch.matches(["cafe", "tab"], in: words))
        #expect(NoteSearch.matches(NoteSearch.terms("CAFÉ"), in: words))
        #expect(NoteSearch.matches(["dotprod"], in: words), "a hyphenated compound also matches joined")
        #expect(!NoteSearch.matches(["tention"], in: words), "prefixes, not substrings")
        #expect(!NoteSearch.matches(["cafe", "chair"], in: words), "every word must match")
    }

    @Test func recordTextCoversEveryField() {
        let source = NoteSource(kind: .arxiv, title: "Scaling Laws", authors: ["Jared Kaplan"], sourceID: "2001.08361", revision: 1,
                                section: "3 Empirical results", label: "Figure 2")
        let anchor = NoteAnchor(manifestSHA256: manifest, rendererRevision: 1, blockIDs: [], rects: [], viewport: nil, quote: "anchored words")
        let record = entry(UUID(), 1, comment: "my comment", quote: "quoted words", source: source, anchor: anchor)
        let words = NoteSearch.words(NoteSearch.recordText(record))
        for term in ["comment", "quoted", "anchored", "scaling", "kaplan", "2001.08361", "empirical", "figure", "2"] {
            #expect(NoteSearch.matches([term], in: words), "\(term)")
        }
        // A pasted PDF's identity (a document's own ID) is not a word anyone types.
        let document = NoteSource(kind: .document, title: "Notes", sourceID: "aaaaaaaa-0000-0000-0000-000000000001")
        #expect(!NoteSearch.matches(["aaaaaaaa"], in: NoteSearch.words(NoteSearch.recordText(entry(UUID(), 1, source: document)))))
    }

    @Test func bundleTextIsTheBlocksUnderTheRegion() throws {
        let json = """
        {"format":"x","title":"T","headings":[],
         "blocks":[{"id":"b1","kind":"paragraph","text":"Scaled dot-product attention"},{"id":"b2","kind":"equation","text":"\\\\frac{QK}{\\\\sqrt{d_k}}"},
                   {"id":"b3","kind":"figure","text":""},{"id":"b9","kind":"paragraph","text":"Elsewhere entirely"}],
         "equations":[{"id":"e1","block_id":"b2","latex":"\\\\operatorname{softmax}","display":true,"source_form":"tex"}],
         "figures":[{"id":"f1","block_id":"b3","asset_paths":[],"caption":"Figure 1: Kaleidoscope","alt":"diagram of heads"}],
         "tables":[]}
        """
        let index = try JSONDecoder().decode(ReaderBundleIndex.self, from: Data(json.utf8))
        let anchor = NoteAnchor(manifestSHA256: manifest, rendererRevision: 1, blockIDs: ["b1", "b2", "b3"], rects: [], viewport: nil, quote: nil)
        let words = NoteSearch.words(NoteSearch.bundleText(anchor, in: index))
        for term in ["attention", "sqrt", "d_k", "softmax", "kaleido", "heads"] {
            #expect(NoteSearch.matches(NoteSearch.terms(term), in: words), "\(term)")
        }
        #expect(!NoteSearch.matches(["elsewhere"], in: words), "only the blocks under the region")
    }

    @Test func collectionsMatchByNameOrOneSnippetWithTheName() throws {
        let quick = NoteRecord(title: "Quick snippets", createdAt: 1_760_000_000_000)
        let group = NoteRecord(title: "Reading group", createdAt: 1_760_000_000_001)
        let empty = NoteRecord(title: "Ideas", createdAt: 1_760_000_000_002)
        let a = entry(quick.noteID, 1, comment: "Why the square root?"), b = entry(quick.noteID, 2, quote: "softmax saturates")
        let c = entry(group.noteID, 1, comment: "Thursday")
        let state = try state([(quick, [a, b]), (group, [c]), (empty, [])])
        func ids(_ query: String, extra: (NoteEntryRecord) -> [String] = { _ in [] }) -> [UUID]? {
            NoteSearch.search(state, query: query, extra: extra)?.map(\.noteID)
        }
        #expect(NoteSearch.search(state, query: " ") == nil, "an empty query shows everything")
        #expect(ids("ide") == [empty.noteID], "a name, even of an empty collection")
        #expect(ids("square") == [quick.noteID])
        #expect(ids("quick satur") == [quick.noteID], "the name and one snippet")
        #expect(ids("square satur") == [], "two snippets' words don't combine")
        #expect(ids("thurs") == [group.noteID])
        let match = try #require(NoteSearch.search(state, query: "softm")?.first)
        #expect(match.entryIDs == [b.entryID], "the snippet that matches, to open at")
        // What the app adds (the reading under a region, recognised text) is searched as the record is.
        #expect(ids("kaleido", extra: { $0.entryID == c.entryID ? ["Kaleidoscope schedule"] : [] }) == [group.noteID])
        let cache = NoteSearch.WordCache()
        #expect(NoteSearch.search(state, query: "square", cache: cache)?.map(\.noteID) == [quick.noteID])
        #expect(NoteSearch.search(state, query: "kaleido", extra: { _ in ["kaleidoscope"] }, cache: cache)?.count == 2,
                "new extra text replaces the cached words (both collections with snippets)")
    }

    @Test func recognisedTextIsSealedAndBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("snippet-text-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID(), key = Data(repeating: 9, count: 32)
        let store = try SnippetTextStore(directory: directory, accountID: account, localKey: key)
        #expect(store.load().isEmpty)
        let a = UUID(), b = UUID()
        try store.save([a: "Kaleidoscope schedule", b: "", UUID(): String(repeating: "é", count: 5_000)])
        let loaded = try SnippetTextStore(directory: directory, accountID: account, localKey: key).load()
        #expect(loaded[a] == "Kaleidoscope schedule")
        #expect(loaded[b] == "", "nothing found is kept, so the image is read once")
        #expect(loaded.values.allSatisfy { $0.utf8.count <= SnippetTextStore.maximumTextBytes })
        let raw = try Data(contentsOf: directory.appendingPathComponent("recognised.sealed"))
        #expect(raw.range(of: Data("Kaleidoscope".utf8)) == nil, "sealed, never plain text")
        #expect(try SnippetTextStore(directory: directory, accountID: UUID(), localKey: key).load().isEmpty, "another account's binding")
        #expect(try SnippetTextStore(directory: directory, accountID: account, localKey: Data(repeating: 1, count: 32)).load().isEmpty)
        store.removeAll()
        #expect(store.load().isEmpty)
    }
}

/// The Snippets list's row (owner, TestFlight 91): the name, then the count; an empty collection says so once.
@Suite struct NoteCollectionLineTests {
    @Test func countsWithoutDateOrPapers() {
        #expect(NoteCollectionLine.detail(entryCount: 0) == "No snippets yet", "never also “0 snippets”")
        #expect(NoteCollectionLine.detail(entryCount: 1) == "1 snippet")
        #expect(NoteCollectionLine.detail(entryCount: 111) == "111 snippets")
    }
}
