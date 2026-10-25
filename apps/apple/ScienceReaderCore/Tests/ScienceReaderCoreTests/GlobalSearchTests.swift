import CryptoKit
import Foundation
import Testing
@testable import ScienceReaderCore

/// Global search's engine (docs/architecture/GLOBAL_SEARCH.md): tokenizer v2, typos, the everything index's ranking,
/// grouping and paging, incremental updates, sealing, closing, the ML paper search cache.
@Suite struct GlobalSearchTests {
    private func terms(_ text: String) -> [String] { FullTextTokenizer.tokens(text).map(\.term) }

    // MARK: Tokenizer v2

    @Test func greekLettersAreTheirNamesInEveryForm() {
        for text in ["α", "alpha", "\\alpha", "Α", "𝛼", "\\upalpha"] { #expect(terms(text) == ["alpha"], "\(text)") }
        for text in ["ε", "ϵ", "\\epsilon", "\\varepsilon", "epsilon"] { #expect(terms(text) == ["epsilon"], "\(text)") }
        #expect(terms("ϑ \\vartheta θ") == ["theta", "theta", "theta"])
        #expect(terms("Σ σ ς \\Sigma") == ["sigma", "sigma", "sigma", "sigma"])
        #expect(terms("ϕ φ \\varphi") == ["phi", "phi", "phi"])
        #expect(terms("µ") == ["mu"])
        // A Greek word stays a word.
        #expect(terms("λόγος") == ["λογοσ"])
        // v1's compound with Greek parts keeps its shape.
        #expect(terms("αβ-divergence") == ["αβ", "αβdivergence", "divergence"])
        #expect(terms("α-divergence") == ["alpha", "alphadivergence", "divergence"])
    }

    @Test func layoutCommandsAreDroppedAndSymbolsNamed() {
        #expect(terms(#"\mathrm{softmax}(QK^\top)"#) == ["softmax", "qk"])
        #expect(terms(#"\operatorname{diag}\left(\frac{a}{\sqrt{d_k}}\right) \cdot x"#) == ["diag", "a", "d", "k", "x"])
        #expect(terms(#"\nabla_\theta \log \pi_\theta"#) == ["nabla", "theta", "log", "pi", "theta"])
        #expect(terms("∇θ ∂L ∞ ∑ ∏ ∫") == ["nabla", "theta", "partial", "l", "infinity", "sum", "prod", "integral"])
        #expect(terms(#"\infty \int \partial \sum"#) == ["infinity", "integral", "partial", "sum"])
        // Dropped commands take no position: the words around them stay adjacent.
        let tokens = FullTextTokenizer.tokens(#"\mathrm{softmax}\,\mathbf{x}"#)
        #expect(tokens.map(\.term) == ["softmax", "x"] && tokens.map(\.position) == [0, 1])
        // Positions-only scans agree with term scans (snippets resume by position).
        let text = #"QK^\top \frac{1}{2} α̅ₜ ∇θ self-attention"#
        #expect(FullTextTokenizer.positionCount(text) == (FullTextTokenizer.tokens(text).map(\.position).max() ?? -1) + 1)
    }

    @Test func greekAndLatinSplitAndCompoundsStayAsInVersionOne() {
        #expect(terms("α̅ₜ") == ["alpha", "t"])
        #expect(terms("θ2 βVAE") == ["theta", "2", "beta", "vae"])
        // v1's rules for compounds, IDs and numbers are unchanged.
        #expect(terms("state-of-the-art 2106.09685 GPT-4o Llama-3.1-8B x_t") ==
                ["state", "stateoftheart", "of", "the", "art", "2106.09685", "gpt", "gpt4o", "4o", "llama", "llama3.18b", "3.1", "8b", "x", "t"])
        #expect(terms("self-attention KL-divergence") == ["self", "selfattention", "attention", "kl", "kldivergence", "divergence"])
    }

    @Test func aGreekLetterIsNeverAPrefixWhileTyping() {
        #expect(FullTextQuery("α").clauses[0].sequences == [[.init(terms: ["alpha"], prefix: nil)]])
        #expect(FullTextQuery("alph").clauses[0].sequences == [[.init(terms: ["alph"], prefix: "alph")]])
        #expect(FullTextQuery(#"\alpha"#).clauses[0].sequences == [[.init(terms: ["alpha"], prefix: nil)]])
    }

    // MARK: Typos

    @Test func aWordThatMatchesNothingIsCorrectedToTheClosestCommonWord() async throws {
        let (index, directory) = try everything()
        defer { try? FileManager.default.removeItem(at: directory) }
        let words = ["attention", "softmax", "diffusion", "transformer", "regularization", "retention"]
        var items: [(SearchItem, String)] = []
        for (n, word) in words.enumerated() {
            for copy in 0..<(word == "retention" ? 1 : 3) {
                let item = message("\(word) is discussed here \(n)-\(copy)")
                items.append((item, item.contentFingerprint))
            }
        }
        try await index.commit(items)
        let snapshot = try await index.snapshot().index
        #expect(FullTextTypos.correction(for: "atention", in: [snapshot]) == "attention")
        #expect(FullTextTypos.correction(for: "softmx", in: [snapshot]) == "softmax")
        #expect(FullTextTypos.correction(for: "difusion", in: [snapshot]) == "diffusion")
        #expect(FullTextTypos.correction(for: "transfromer", in: [snapshot]) == "transformer")
        #expect(FullTextTypos.correction(for: "regularisation", in: [snapshot]) == "regularization")
        // Indexed words and short words are left alone; nothing close is nothing.
        #expect(FullTextTypos.correction(for: "attention", in: [snapshot]) == nil)
        #expect(FullTextTypos.correction(for: "atn", in: [snapshot]) == nil)
        #expect(FullTextTypos.correction(for: "zzzzzzzz", in: [snapshot]) == nil)
        let distance = Array("transformer".utf8).withUnsafeBufferPointer { FullTextTypos.distance(Array("transfromer".utf8), $0, limit: 2) }
        #expect(distance == 1)
    }

    // MARK: The everything index

    private func everything(account: UUID = UUID(), key: Data? = nil) throws -> (EverythingIndex, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("everything-\(UUID().wire)", isDirectory: true)
        let key = key ?? Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        return (try EverythingIndex(directory: directory, accountID: account, localKey: key), directory)
    }

    private func message(_ text: String, conversation: UUID = UUID(), paper: UUID? = nil, reader: Bool = false, date: Date? = nil, id: UUID = UUID()) -> SearchItem {
        .message(eventID: id, conversationID: conversation, paperID: paper, text: text, byReader: reader, date: date)
    }

    private func commit(_ index: EverythingIndex, _ items: [SearchItem], removing: [String] = []) async throws {
        try await index.commit(items.map { ($0, $0.contentFingerprint) }, removing: removing)
    }

    private func groups(_ index: EverythingIndex, _ text: String, _ options: EverythingSearch.Options = .init(now: Date())) async throws -> [EverythingSearch.Group] {
        EverythingSearch.search(try await index.snapshot(), query: FullTextQuery(text), options: options)
    }

    @Test func rankingBoostsPhrasesTheReadersWordsAndRecency() async throws {
        let (index, directory) = try everything()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let scattered = message("the gradient of a policy is noisy", date: now.addingTimeInterval(-200 * 86_400))
        let phrase = message("the policy gradient is noisy", date: now.addingTimeInterval(-200 * 86_400))
        let answer = message("Kaleidoscope warmup schedules decay slowly", date: now.addingTimeInterval(-200 * 86_400))
        let question = message("Kaleidoscope warmup schedules decay slowly", reader: true, date: now.addingTimeInterval(-200 * 86_400))
        let old = message("quokka optimizers converge", date: now.addingTimeInterval(-120 * 86_400))
        let recent = message("quokka optimizers converge", date: now.addingTimeInterval(-86_400))
        try await commit(index, [scattered, phrase, answer, question, old, recent])
        let options = EverythingSearch.Options(collapse: false, now: now)
        #expect(try await groups(index, "policy gradient ", options).first?.hits.map(\.id) == [phrase.group, scattered.group])
        #expect(try await groups(index, "kaleidoscope warmup ", options).first?.hits.first?.id == question.group)
        #expect(try await groups(index, "quokka ", options).first?.hits.map(\.id) == [recent.group, old.group])
    }

    @Test func resultsAreGroupedInAFixedOrderAndChatsCollapseByConversation() async throws {
        let (index, directory) = try everything()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chat = UUID(), other = UUID(), paper = UUID()
        let conversation = SearchItem.conversation(id: chat, title: "Why does softmax saturate?", paperID: paper, paperTitle: "Attention", passage: nil, date: Date())
        let messages = (0..<4).map { message("softmax temperature note \($0)", conversation: chat, paper: paper) }
        let elsewhere = (0..<2).map { message("softmax in another chat \($0)", conversation: other) }
        var explanation = EquationAnswer(symbols: EquationSymbols(summary: "Normalises scores with softmax", symbols: [.init(symbol: "σ", latex: #"\sigma"#, meaning: "the softmax", source: .general)]))
        explanation.subject = ExplanationSubject(paperID: paper, paperTitle: "Attention", manifestSHA256: "m", itemID: "eq1", label: "Equation (1)", action: "equation", savedAt: Date())
        let equation = try #require(SearchItem.equation(fileName: "file1", answer: explanation))
        let collection = UUID()
        let snippets = (0..<3).map { n in
            SearchItem.snippet(NoteEntryRecord(noteID: collection, kind: .quote, counter: Int64(n + 1), capturedAt: 0, offsetMinutes: 0, comment: "softmax note \(n)", quote: "a quoted softmax"),
                               collection: "Reading group", paperID: nil, extra: [], recognised: nil, date: Date())
        }
        let diagram = try #require(ChatDiagram(title: "Softmax pipeline", source: "flowchart LR\n A[scores] --> B(softmax)", messageID: nil))
        try await commit(index, [conversation] + messages + elsewhere + [equation, .diagram(id: UUID(), diagram: diagram, conversationID: chat, paperID: paper, date: nil)] + snippets)

        let all = try await groups(index, "softmax")
        #expect(all.map(\.group) == [.chats, .explanations, .snippets, .diagrams])
        let chats = try #require(all.first)
        #expect(chats.total == 7 && chats.containers == 2)
        // The All view: the conversation itself (its title matched) with "+4 more", and the other chat's best message with "+1".
        #expect(chats.hits.count == 2)
        let own = try #require(chats.hits.first { $0.info.kind == .conversation })
        #expect(own.more == 4)
        #expect(chats.hits.contains { $0.info.kind == .message && $0.info.container == other && $0.more == 1 })
        #expect(all[2].hits.count == 1 && all[2].hits[0].more == 2 && all[2].total == 3)

        // A chip ("See all"): every item, uncollapsed, in score order; paging is the caller's slice of it.
        let seeAll = try await groups(index, "softmax", .init(groups: [.chats], collapse: false, now: Date()))
        #expect(seeAll.count == 1 && seeAll[0].hits.count == 7)
        #expect(Array(seeAll[0].hits.prefix(3)).map(\.id) == Array(seeAll[0].hits.map(\.id).prefix(3)))

        // "In this paper": only items about the paper.
        let scoped = try await groups(index, "softmax", .init(paperID: paper, collapse: false, now: Date()))
        #expect(scoped.map(\.group) == [.chats, .explanations, .diagrams])
        #expect(scoped[0].hits.allSatisfy { $0.info.paperID == paper })

        // Some words but not all: nothing, unless partial results are asked for (most words first).
        #expect(try await groups(index, "softmax zebrafish ").isEmpty)
        let partial = try await groups(index, "softmax quoted zebrafish ", .init(groups: [.snippets], collapse: false, partial: true, now: Date()))
        #expect(partial.first?.hits.first?.matched == 2 && partial.first?.hits.first?.match.percent == 67)
    }

    @Test func rowsShowTheTitlesWordsAndAnExcerptWithHighlightRanges() throws {
        let item = SearchItem.message(eventID: UUID(), conversationID: UUID(), paperID: nil,
            text: "**Short answer:** dividing by \\(\\sqrt{d_k}\\) keeps the softmax from saturating [¶12]. Larger logits make the gradient vanish.",
            byReader: false, date: nil)
        #expect(!item.body.contains("**") && !item.body.contains("¶") && item.body.contains("√d_k"))
        let query = FullTextQuery("softmax saturat")
        let shown = EverythingSearch.display(item, title: "Why divide by root dk?", query: query, match: SearchMatch(clauseFields: [.fullText, .fullText]))
        let excerpt = try #require(shown.excerpt)
        let marked = excerpt.highlights.map { String(decoding: Array(excerpt.text.utf16)[$0], as: UTF16.self) }
        #expect(marked == ["softmax", "saturating"])
        #expect(shown.titleHighlights.isEmpty)
    }

    @Test func itemsAreAddedReplacedAndRemovedIncrementally() async throws {
        let (index, directory) = try everything()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), conversation = UUID()
        let first = SearchItem.conversation(id: conversation, title: "Pelican notes", paperID: nil, paperTitle: nil, passage: nil, date: nil)
        let reply = message("about the albatross", conversation: conversation, id: id)
        try await commit(index, [first, reply])
        #expect(try await groups(index, "pelican ").first?.total == 1)
        let fingerprints = await index.fingerprints()
        #expect(fingerprints[first.group] == first.contentFingerprint && fingerprints.count == 2)
        // Renamed: the same group, new words; the old ones no longer match.
        let renamed = SearchItem.conversation(id: conversation, title: "Cormorant notes", paperID: nil, paperTitle: nil, passage: nil, date: nil)
        try await commit(index, [renamed])
        #expect(try await groups(index, "pelican ").isEmpty)
        #expect(try await groups(index, "cormorant ").first?.total == 1)
        // Deleted (a tombstone, or the conversation's deletion): gone.
        try await commit(index, [], removing: [reply.group])
        #expect(try await groups(index, "albatross ").isEmpty)
        #expect(await index.fingerprints().count == 1)
        // Reopened: the same index; unload and reload keeps it.
        await index.unload()
        #expect(try await groups(index, "cormorant ").first?.total == 1)
    }

    @Test func nothingOnDiskIsPlaintextAndTheFilesAreBoundToTheAccount() async throws {
        let account = UUID(), key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let (index, directory) = try everything(account: account, key: key)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = "zanzibarquokka", paper = UUID()
        let items = (0..<50).map { message("\($0) the \(marker) appears in Kaleidoscope answers", paper: paper, reader: $0 % 2 == 0, date: Date()) }
        try await commit(index, items + [.collection(id: UUID(), name: "Marmalade \(marker)", date: nil)])
        index.remember("\(marker) recent query")
        #expect(index.recentSearches() == ["\(marker) recent query"])
        _ = try await index.snapshot()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(Set(files.map(\.lastPathComponent)).isSuperset(of: ["manifest.bin", "recent.bin"]) && files.count >= 3)
        // No text, in UTF-8 or UTF-16, and no paper identifier, in any file.
        for file in files {
            let bytes = try Data(contentsOf: file)
            for word in [marker, "Kaleidoscope", "Marmalade", paper.wire, paper.uuidString] {
                #expect(bytes.range(of: Data(word.utf8)) == nil, "\(file.lastPathComponent) holds \(word)")
                #expect(bytes.range(of: word.data(using: .utf16LittleEndian)!) == nil, "\(file.lastPathComponent) holds \(word) (UTF-16)")
            }
        }
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        await index.close()
        // Another account's key and name, or the Library's namespace, can't open it: it starts empty instead.
        let stranger = try EverythingIndex(directory: directory, accountID: UUID(), localKey: key)
        #expect(await stranger.startedEmpty)
        #expect(stranger.recentSearches().isEmpty)
        await stranger.close()
    }

    @Test func theLibrarysNamespaceCannotOpenTheEverythingIndex() async throws {
        let account = UUID(), key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let (index, directory) = try everything(account: account, key: key)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await commit(index, [message("namespaces differ")])
        await index.close()
        let library = try FullTextIndexStore(directory: directory, accountID: account, localKey: key)
        #expect(await library.startedEmpty)
    }

    @Test func closingStopsSearchesAndRecentSearchesClear() async throws {
        let (index, directory) = try everything()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await commit(index, [message("heron")])
        for query in ["one", "two", "One ", "three"] { index.remember(query) }
        #expect(index.recentSearches() == ["three", "One", "two"])
        index.clearRecentSearches()
        #expect(index.recentSearches().isEmpty)
        await index.close()
        await #expect(throws: FullTextIndexError.closed) { _ = try await index.snapshot() }
    }

    // MARK: Text

    @Test func chatTextIsReadable() {
        let answer = """
        ## Short answer
        The **softmax** turns scores into weights [¶3, ¶4].

        - First, compute $QK^\\top$.
        - Then divide by \\(\\sqrt{d_k}\\).

        $$\\mathrm{Attention}(Q,K,V) = \\mathrm{softmax}\\left(\\frac{QK^\\top}{\\sqrt{d_k}}\\right)V$$

        | Symbol | Meaning |
        |---|---|
        | $\\alpha$ | step size |

        See [the paper](https://arxiv.org/abs/1706.03762).

        Sources:
        1. Attention — https://arxiv.org/abs/1706.03762
        """
        let text = SearchText.chat(answer)
        #expect(!text.contains("**") && !text.contains("##") && !text.contains("¶") && !text.contains("|---") && !text.contains("Sources:"))
        #expect(text.contains("Short answer") && text.contains("QK⊤") && text.contains("√d_k") && text.contains("α · step size"))
        #expect(text.contains("Attention(Q,K,V) = softmax"))
        #expect(text.contains("the paper (https://arxiv.org/abs/1706.03762)"))
        #expect(terms(text).contains("alpha") && !terms(text).contains("top") && !terms(text).contains("mathrm"))
        #expect(SearchText.chat("It costs $5 and $10.") == "It costs $5 and $10.")
        #expect(SearchText.math(#"\frac{\partial L}{\partial \theta}"#) == "∂ L ∂ θ")
    }

    @Test func diagramsGiveTheirLabels() throws {
        let mermaid = try #require(ChatDiagram(title: "Pipeline", source: """
        flowchart LR
          A["Tokenize the input"] --> B(Embed tokens)
          B -->|positional encoding| C{Attention layers}
          %% a comment
        """, messageID: nil))
        let text = SearchText.diagram(mermaid)
        #expect(text.contains("Tokenize the input") && text.contains("Embed tokens") && text.contains("positional encoding") && text.contains("Attention layers"))
        #expect(!text.contains("flowchart") && !text.contains("-->") && !text.contains("comment"))
        let html = try #require(ChatDiagram(title: "Visual", source: "<div><b>Kernel</b> &amp; trick<script>x()</script></div>", messageID: nil, format: ChatDiagram.htmlFormat))
        #expect(SearchText.diagram(html) == "Kernel & trick")
    }

    // MARK: In memory

    @Test func settingsAndTagsMatchByWordStartsOnly() {
        #expect(MemorySearch.prefixMatch("dark mo", in: ["Theme", "dark mode appearance"]))
        #expect(MemorySearch.prefixMatch("THE", in: ["Theme"]))
        #expect(!MemorySearch.prefixMatch("eme", in: ["Theme"]))
        #expect(MemorySearch.prefixMatch("passage underline", in: ["Underline passages with chats"]))
        #expect(MemorySearch.prefixHighlights("und pass", in: "Underline passages") == [0..<9, 10..<18])
    }

    // MARK: ML paper search cache

    @Test func theMLSearchCacheIsSealedAndBoundToItsAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("arxiv-search-\(UUID().wire)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) }), account = UUID()
        let cache = try SealedCacheFiles(directory: directory, accountID: account, localKey: key, namespace: "arxiv-search")
        let results = Data(#"{"at":1,"results":[{"title":"Quokka attention"}]}"#.utf8)
        try cache.write(results, as: "abc123")
        #expect(cache.read("abc123") == results)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("abc123.sealed"))
        #expect(bytes.range(of: Data("Quokka".utf8)) == nil && bytes.range(of: Data("results".utf8)) == nil)
        // Another account, another name, or a path: nothing.
        let other = try SealedCacheFiles(directory: directory, accountID: UUID(), localKey: key, namespace: "arxiv-search")
        #expect(other.read("abc123") == nil)
        try FileManager.default.copyItem(at: directory.appendingPathComponent("abc123.sealed"), to: directory.appendingPathComponent("def456.sealed"))
        #expect(cache.read("def456") == nil)
        #expect(cache.read("../abc123") == nil)
        cache.removeAll()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
