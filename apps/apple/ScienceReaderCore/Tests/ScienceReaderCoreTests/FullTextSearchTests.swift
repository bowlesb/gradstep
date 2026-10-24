import CryptoKit
import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct FullTextSearchTests {
    private func terms(_ text: String) -> [String] { FullTextTokenizer.tokens(text).map(\.term) }

    // MARK: Tokenizer

    @Test func tokenizerFoldsCaseDiacriticsWidthAndLigatures() {
        #expect(terms("Café NAÏVE Ｗｉｄｅ ﬁne Straße") == ["cafe", "naive", "wide", "fine", "strasse"])
        #expect(terms("Schrödinger's équation") == ["schrodinger", "equation"])
        #expect(terms("αβ-divergence") == ["αβ", "αβdivergence", "divergence"])
    }

    @Test func tokenizerJoinsHyphenatedCompoundsAndKeepsNumbers() {
        let tokens = FullTextTokenizer.tokens("state-of-the-art self‑attention 2106.09685 0,5 x-")
        #expect(tokens.map(\.term) == ["state", "stateoftheart", "of", "the", "art", "self", "selfattention", "attention", "2106.09685", "0,5", "x"])
        // Parts take consecutive positions; the joined form shares its first part's.
        #expect(tokens.map(\.position) == [0, 0, 1, 2, 3, 4, 4, 5, 6, 7, 8])
        #expect(tokens[1].joined && !tokens[0].joined)
        // A soft hyphen (line-break hyphenation) is not a break.
        #expect(terms("trans\u{00AD}former") == ["transformer"])
        // Byte ranges point at the original text.
        let text = "Ünïcode words"
        let token = FullTextTokenizer.tokens(text)[0]
        #expect(String(decoding: Array(text.utf8)[token.start..<token.end], as: UTF8.self) == "Ünïcode")
    }

    @Test func tokenizerStemsPluralsLightly() {
        #expect(terms("networks studies matches classes boxes analysis this models bus") ==
                ["network", "study", "match", "class", "box", "analysis", "this", "model", "bus"])
        #expect(FullTextTokenizer.tokens("networks", stem: false).map(\.term) == ["networks"])
    }

    @Test func queryParsesPhrasesPrefixAndCompounds() {
        let query = FullTextQuery(#"diffusion "score matching" transfo"#)
        #expect(query.clauses.map(\.text) == ["diffusion", "score matching", "transfo"])
        #expect(query.clauses[0].sequences == [[.init(terms: ["diffusion"], prefix: nil)]])
        #expect(query.clauses[1].phrase && query.clauses[1].sequences == [[.init(terms: ["score"], prefix: nil), .init(terms: ["matching"], prefix: nil)]])
        #expect(query.clauses[2].sequences == [[.init(terms: ["transfo"], prefix: "transfo")]])
        // A finished word (space after it) is exact; an open quote's last word is a prefix.
        #expect(FullTextQuery("transfo ").clauses[0].sequences[0][0].prefix == nil)
        #expect(FullTextQuery(#""attention is al"#).clauses[0].sequences[0].last?.prefix == "al")
        // Hyphenated: its parts as a phrase, or the joined word.
        let compound = FullTextQuery("self-attention ").clauses[0]
        #expect(compound.sequences == [[.init(terms: ["self"], prefix: nil), .init(terms: ["attention"], prefix: nil)],
                                       [.init(terms: ["selfattention"], prefix: nil)]])
        // Punctuation-only words keep their clause (metadata substring matching still applies).
        #expect(FullTextQuery("C++ +").clauses.map(\.text) == ["C++", "+"])
        #expect(FullTextQuery("+").clauses[0].sequences.isEmpty)
    }

    // MARK: Index and query

    private func paper(_ group: String, title: String, abstract: String = "", body: String? = nil, tags: String = "") -> [FullTextDocument] {
        var out = [FullTextDocument(id: .init(group: group, part: .metadata), fingerprint: "m-\(title)",
                                    fields: [.title: title, .abstract: abstract, .tags: tags])]
        if let body { out.append(FullTextDocument(id: .init(group: group, part: .body), fingerprint: "b-\(body.hashValue)", fields: [.body: body])) }
        return out
    }

    private func store() throws -> (FullTextIndexStore, URL, Data, UUID) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fts-\(UUID().wire)", isDirectory: true)
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) }), account = UUID()
        return (try FullTextIndexStore(directory: directory, accountID: account, localKey: key), directory, key, account)
    }

    private func matches(_ snapshot: FullTextSnapshot, _ text: String) -> [String] {
        let query = FullTextQuery(text)
        let all: UInt64 = query.clauses.count == 64 ? .max : (1 << UInt64(query.clauses.count)) - 1
        return snapshot.search(query).values.filter { $0.clauses == all }.sorted { $0.score > $1.score }.map(\.group)
    }

    @Test func phrasesMatchOnlyAdjacentWordsWithinOneField() async throws {
        let (index, directory, _, _) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await index.commit(FullTextIndexStore.prepare(
            paper("a", title: "Denoising methods", body: "We study score matching for diffusion models.")
            + paper("b", title: "Matching markets", body: "A score is computed; matching follows later.")
            + paper("c", title: "Score", abstract: "matching appears in the abstract only")))
        let snapshot = try await index.snapshot()
        #expect(matches(snapshot, #""score matching""#) == ["a"])
        #expect(Set(matches(snapshot, "score matching ")) == ["a", "b", "c"])
        // "Score" ends the title and "matching" starts the abstract: no phrase across fields.
        #expect(!matches(snapshot, #""score matching""#).contains("c"))
        #expect(matches(snapshot, #""diffusion model""#) == ["a"], "stemmed phrase")
    }

    @Test func lastWordMatchesAsPrefixAndCompoundsMatchEitherWay() async throws {
        let (index, directory, _, _) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await index.commit(FullTextIndexStore.prepare(
            paper("a", title: "Paper A", body: "Transformers use self-attention everywhere.")
            + paper("b", title: "Paper B", body: "Transfer learning with selfattention and pre-training.")))
        let snapshot = try await index.snapshot()
        #expect(Set(matches(snapshot, "transf")) == ["a", "b"])
        #expect(matches(snapshot, "transfo") == ["a"])
        #expect(matches(snapshot, "transfo ").isEmpty, "a finished word is exact")
        #expect(matches(snapshot, "transformer ") == ["a"], "singular finds the plural")
        #expect(Set(matches(snapshot, "self-attention ")) == ["a", "b"])
        #expect(Set(matches(snapshot, "selfattention ")) == ["a", "b"])
        #expect(matches(snapshot, "pretraining ") == ["b"])
        #expect(matches(snapshot, "self attention ") == ["a"], "two words: both required")
    }

    @Test func bm25RanksTitleAboveAbstractAboveBodyAndRareAboveCommon() async throws {
        let (index, directory, _, _) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let filler = Array(repeating: "general words about learning", count: 40).joined(separator: " ")
        try await index.commit(FullTextIndexStore.prepare(
            paper("body", title: "Something else", body: filler + " quantization " + filler)
            + paper("abstract", title: "Other topic", abstract: "We apply quantization to models.", body: filler)
            + paper("title", title: "Quantization of networks", body: filler)
            + paper("many", title: "Unrelated", body: Array(repeating: "quantization", count: 30).joined(separator: " ") + filler)))
        let snapshot = try await index.snapshot()
        let order = matches(snapshot, "quantization ")
        #expect(order.first == "title")
        #expect(order.firstIndex(of: "abstract")! < order.firstIndex(of: "body")!)
        #expect(order.firstIndex(of: "many")! < order.firstIndex(of: "body")!, "more occurrences rank higher in the same field")
        // A word every paper has adds less than a rare one.
        let hits = snapshot.search(FullTextQuery("learning quantization "))
        #expect(hits["body"]!.score > 0)
        #expect(FullTextRanking.idf(documents: 4, frequency: 4) < FullTextRanking.idf(documents: 4, frequency: 1))
    }

    @Test func documentsAreAddedReplacedAndRemovedIncrementally() async throws {
        let (index, directory, _, _) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await index.commit(FullTextIndexStore.prepare(paper("a", title: "Alpha", body: "graphene superconductivity")))
        try await index.commit(FullTextIndexStore.prepare(paper("b", title: "Beta", body: "protein folding")))
        var snapshot = try await index.snapshot()
        #expect(matches(snapshot, "graphene ") == ["a"]); #expect(matches(snapshot, "protein ") == ["b"])
        // Replace a's body: the old words go, the new ones arrive; b is untouched.
        try await index.commit(FullTextIndexStore.prepare([FullTextDocument(id: .init(group: "a", part: .body), fingerprint: "b2",
                                                                            fields: [.body: "topological insulators"])]))
        snapshot = try await index.snapshot()
        #expect(matches(snapshot, "graphene ").isEmpty); #expect(matches(snapshot, "topological ") == ["a"])
        #expect(matches(snapshot, "alpha ") == ["a"], "metadata kept")
        try await index.commit(FullTextIndexStore.prepare([]), removing: [.init(group: "b", part: .metadata), .init(group: "b", part: .body)])
        snapshot = try await index.snapshot()
        #expect(matches(snapshot, "protein ").isEmpty); #expect(snapshot.documentCount == 1)
        let fingerprints = await index.fingerprints()
        #expect(fingerprints[.init(group: "a", part: .body)] == "b2" && fingerprints.count == 2)
        // Many small commits merge into a few segments without losing anything.
        for n in 0..<30 { try await index.commit(FullTextIndexStore.prepare(paper("p\(n)", title: "Paper \(n)", body: "shared word unique\(n)"))) }
        snapshot = try await index.snapshot()
        #expect(snapshot.segments.count <= FullTextIndexStore.maximumSegments)
        #expect(matches(snapshot, "shared ").count == 30)
        #expect(matches(snapshot, "unique17 ") == ["p17"])
        #expect(matches(snapshot, "topological ") == ["a"])
        // Reopening reads the same index from disk.
        let reopened = try FullTextIndexStore(directory: directory, accountID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000")), localKey: Data(repeating: 1, count: 32))
        #expect(await reopened.startedEmpty, "another account's key cannot read it")
    }

    @Test func reopeningKeepsTheIndexAndAVersionChangeEmptiesIt() async throws {
        let (index, directory, key, account) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await index.commit(FullTextIndexStore.prepare(paper("a", title: "Alpha", body: "graphene")))
        let again = try FullTextIndexStore(directory: directory, accountID: account, localKey: key)
        #expect(await !again.startedEmpty)
        #expect(matches(try await again.snapshot(), "graphene ") == ["a"])
        // Rewrite the manifest as an older version: the next open starts empty and removes the old files.
        var manifest = try JSONDecoder().decode(FullTextIndexStore.Manifest.self, from: FullTextIndexStore.open(
            Data(contentsOf: directory.appendingPathComponent("manifest.bin")), key: SymmetricKey(data: key), aad: FullTextIndexStore.manifestAAD(account)))
        manifest.version -= 1
        let sealed = try AES.GCM.seal(JSONEncoder().encode(manifest), using: SymmetricKey(data: key), authenticating: FullTextIndexStore.manifestAAD(account)).combined!
        try sealed.write(to: directory.appendingPathComponent("manifest.bin"))
        let rebuilt = try FullTextIndexStore(directory: directory, accountID: account, localKey: key)
        #expect(await rebuilt.startedEmpty)
        #expect(await rebuilt.fingerprints().isEmpty)
        #expect(try await rebuilt.snapshot().documentCount == 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files == ["manifest.bin"])
    }

    @Test func nothingOnDiskIsPlaintext() async throws {
        let (index, directory, _, _) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = "zanzibarquokka", other = "xylophonemarmalade"
        let body = Array(repeating: "\(secret) appears with \(other) in this body", count: 200).joined(separator: ". ")
        try await index.commit(FullTextIndexStore.prepare(paper("paper", title: "Title \(other)", abstract: secret, body: body)))
        _ = try await index.snapshot()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count >= 3)
        for file in files {
            let bytes = try Data(contentsOf: file)
            for word in [secret, other, "appears", "Title"] { #expect(bytes.range(of: Data(word.utf8)) == nil, "\(file.lastPathComponent) holds \(word)") }
        }
        #if os(iOS)
        let protection = try FileManager.default.attributesOfItem(atPath: directory.path)[.protectionKey] as? FileProtectionType
        #expect(protection == .complete)
        #endif
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func snippetsShowTheDensestBodyMatchWithHighlights() async throws {
        let (index, directory, _, _) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let filler = Array(repeating: "Unrelated sentence about other things.", count: 30).joined(separator: " ")
        let body = filler + " A lone diffusion mention. " + filler + " Here score matching trains the diffusion model well. " + filler
        try await index.commit(FullTextIndexStore.prepare(paper("a", title: "Paper", body: body)))
        let snapshot = try await index.snapshot()
        let hit = try #require(snapshot.search(FullTextQuery(#""score matching" diffusion"#))["a"])
        let snippet = try #require(snapshot.snippet(for: hit))
        #expect(snippet.text.contains("score matching trains the diffusion model"))
        #expect(snippet.text.hasPrefix("…") && snippet.text.hasSuffix("…"))
        let highlighted = snippet.highlights.map { String(decoding: Array(snippet.text.utf16)[$0], as: UTF16.self) }
        #expect(highlighted == ["score matching", "diffusion"])
        #expect(snippet.firstMatch == "score matching")
        #expect(snippet.text.count <= FullTextSnapshot.snippetLength + 60)
        // A title-only match has no snippet.
        let title = try #require(snapshot.search(FullTextQuery("paper "))["a"])
        #expect(title.bodyClauses == 0 && snapshot.snippet(for: title) == nil)
    }

    @Test func statisticsExposeDocumentAndTermFrequencies() async throws {
        let (index, directory, _, _) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await index.commit(FullTextIndexStore.prepare(
            paper("a", title: "Graphs", body: "graph neural networks on graphs")
            + paper("b", title: "Other", body: "neural fields")))
        let snapshot = try await index.snapshot()
        #expect(snapshot.documentFrequency("neural") == 2)
        #expect(snapshot.documentFrequency("graph") == 1)
        #expect(snapshot.termFrequencies(group: "a", fields: [.body]) == ["graph": 2, "neural": 1, "network": 1, "on": 1])
        #expect(snapshot.termFrequencies(group: "a")["graph"] == 3)
        #expect(snapshot.documentFrequencies()["neural"] == 2)
    }

    @Test func libraryDocumentsUseTheReadingTextWithoutMarkers() {
        let index = ReaderBundleIndex(format: "test", title: "T", headings: [.init(id: "h", level: 1, title: "Intro")],
            blocks: [.init(id: "h", kind: "heading", text: "Intro"), .init(id: "p", kind: "paragraph", text: "Results in 12 runs."),
                     .init(id: "f", kind: "figure", text: "")],
            equations: [], figures: [.init(id: "fig", blockID: "f", assetPaths: [], caption: "Figure 1: a plot", alt: "")], tables: nil)
        let text = FullTextLibrary.bodyText(index)
        #expect(text == "Intro\n\nResults in 12 runs.\n\nFigure 1: a plot")
        #expect(!text.contains("¶") && !text.contains("#"))
        let a = FullTextLibrary.metadata(group: "g", title: "T", authors: "A", tags: ["x"], abstract: "", notes: "")
        let b = FullTextLibrary.metadata(group: "g", title: "T", authors: "A", tags: ["x"], abstract: "", notes: "a note")
        #expect(a.fingerprint != b.fingerprint && a.fingerprint == FullTextLibrary.metadata(group: "g", title: "T", authors: "A", tags: ["x"], abstract: "", notes: "").fingerprint)
    }

    @Test func segmentsRoundTripThroughTheirEncoding() throws {
        let segment = FullTextSegment.build(paper("a", title: "Alpha beta", body: "gamma delta gamma") + paper("b", title: "Beta", body: "epsilon"))
        let decoded = try FullTextSegment.decode(segment.encoded())
        #expect(decoded.docs == segment.docs && decoded.termBytes == segment.termBytes && decoded.postings == segment.postings)
        #expect(throws: FullTextIndexError.self) { try FullTextSegment.decode(segment.encoded().dropLast()) }
        let (merged, mapping) = FullTextSegment.merge([segment, decoded]) { s, d in !(s == 0 && d == 0) }
        #expect(merged.docs.count == 7 && mapping[0][0] == nil && mapping[1][0] == 3)
        #expect(merged.find("gamma") != nil)
    }
}
