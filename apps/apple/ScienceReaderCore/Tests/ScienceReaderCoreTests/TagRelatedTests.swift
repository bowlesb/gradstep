import Foundation
import Testing
@testable import ScienceReaderCore

/// "Filter + related" for a Library tag (owner, TestFlight 92): untagged papers join the tagged ones when their public
/// fingerprint is very close to a tagged paper's, or when their title or abstract uses the tag's words as a phrase.
/// Design and measurements: docs/architecture/INTEREST_INDEX.md ("Related papers for a tag").
@Suite struct TagRelatedTests {
    /// A unit vector at cosine `similarity` to the first basis vector, pointing elsewhere along dimension `axis`.
    private func vector(_ similarity: Float, axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 384)
        v[0] = similarity; v[axis] = (1 - similarity * similarity).squareRoot()
        return v
    }

    @Test func phraseMatchesAcrossHyphensCaseAndPlurals() throws {
        let opd = try #require(TagPhrase("On-policy distillation"))
        #expect(opd.words == ["on", "policy", "distillation"] && opd.quoted == "on-policy distillation")
        #expect(opd.occurs(title: "Branching On-Policy Distillation", abstract: ""))
        #expect(opd.occurs(title: "MiniLLM", abstract: "We study on policy distillations of large models."))
        #expect(opd.occurs(title: "", abstract: "…the student (ON–POLICY  distillation)…"))
        #expect(!opd.occurs(title: "Off-policy distillation", abstract: "policy distillation on hardware"), "the words in order, whole")
        let kv = try #require(TagPhrase("KV cache compression"))
        #expect(kv.quoted == "KV cache compression", "an acronym keeps its capitals")
        #expect(kv.occurs(title: "", abstract: "Low-rank KV-cache compression for long contexts"))
        #expect(try #require(TagPhrase("Diffusion models")).occurs(title: "A diffusion model for chemistry", abstract: ""))
        #expect(TagPhrase("Large language models") == nil, "generic: its words are in most papers")
        #expect(try #require(TagPhrase("Strategy")).occurs(title: "Two Strategies for Search", abstract: ""))
        #expect(try #require(TagPhrase("Losses")).occurs(title: "A contrastive loss", abstract: ""))
        #expect(TagPhrase.forms("approaches").contains("approach") && TagPhrase.forms("box").contains("boxes"))
        #expect(TagPhrase.forms("corpus") == ["corpus", "corpuses"], "not a plural")
        #expect(TagPhrase("Café résumé")?.occurs(title: "CAFE RESUME", abstract: "") == true, "diacritics and case folded")
    }

    @Test func oneWordTagsMatchOnlyTitlesAndGenericTagsNever() throws {
        let radar = try #require(TagPhrase("Radar"))
        #expect(radar.occurs(title: "Radar Point Clouds for Tracking", abstract: ""))
        #expect(!radar.occurs(title: "Tracking People", abstract: "We use radar returns."), "a single word in an abstract says little")
        #expect(!radar.occurs(title: "Radargrams", abstract: ""), "whole words")
        #expect(TagPhrase("Machine learning") == nil && TagPhrase("Reasoning") == nil && TagPhrase("AI") == nil)
        #expect(TagPhrase("Go") == nil, "one word under three letters")
        #expect(TagPhrase("  ") == nil)
    }

    @Test func papersCloseToTwoTaggedPapersJoinWithHowManyTheyAreCloseTo() {
        let tagged = [TagRelated.Paper(id: "t1", title: "A", abstract: "", vector: vector(1, axis: 1)),
                      TagRelated.Paper(id: "t2", title: "B", abstract: "", vector: vector(0.95, axis: 2)),
                      TagRelated.Paper(id: "upload", title: "C", abstract: "", vector: nil)]
        let candidates = [
            TagRelated.Paper(id: "both", title: "Near both", abstract: "", vector: vector(0.97, axis: 3)),      // 0.97 to t1, ≈0.92 to t2
            TagRelated.Paper(id: "one", title: "Near one", abstract: "", vector: vector(0.92, axis: 4)),         // 0.92 to t1, ≈0.874 to t2
            TagRelated.Paper(id: "far", title: "Far", abstract: "", vector: vector(0.86, axis: 5)),
            TagRelated.Paper(id: "words", title: "Sparse Attention for Video", abstract: "", vector: nil),
            TagRelated.Paper(id: "nothing", title: "Graph kernels", abstract: "sparse methods with attention", vector: nil),
        ]
        let related = TagRelated.select(tag: "Sparse attention", tagged: tagged, candidates: candidates)
        #expect(Set(related.keys) == ["both", "words"], "close to one tagged paper isn't enough, however close")
        #expect(related["both"] == TagRelated.Reason(closeTo: 2, mentions: nil))
        #expect(related["words"] == TagRelated.Reason(closeTo: 0, mentions: "sparse attention"), "an upload joins by its words")
        #expect(related["both"]?.text == "Related to 2 tagged papers")
        #expect(related["words"]?.text == "Mentions “sparse attention”")
        #expect(TagRelated.Reason(closeTo: 3, mentions: "sparse attention").text == "Mentions “sparse attention” · related to 3 tagged papers")
        #expect(TagRelated.Reason(closeTo: 1, mentions: nil).text == "Related to 1 tagged paper")
        // One tagged paper with a fingerprint: only words count.
        #expect(Set(TagRelated.select(tag: "Sparse attention", tagged: [tagged[0], tagged[2]], candidates: candidates).keys) == ["words"])
        // The thresholds are settings (the Feed's "Close in topic", 0.88; two tagged papers).
        var loose = TagRelated.Settings(); loose.closeSimilarity = 0.85; loose.closeCount = 1
        let looser = TagRelated.select(tag: "Sparse attention", tagged: tagged, candidates: candidates, settings: loose)
        #expect(looser["far"]?.closeTo == 1 && looser["one"]?.closeTo == 2)
        #expect(TagRelated.Settings().closeSimilarity == RelatedPapers.Settings().closeSimilarity)
    }

    @Test func commonPhrasesInThePoolDontJoinByWords() throws {
        let terms = try InterestTerms(InterestArtifact(gzipped: InterestTopicsTests.resource("interest-terms-fixture", "gsi")))
        let kv = try #require(TagPhrase("KV cache"))
        let share = try #require(kv.poolShare(terms))
        #expect(share > 0 && share < 0.05)
        let papers = [TagRelated.Paper(id: "p", title: "Paging the KV cache", abstract: "", vector: nil)]
        #expect(TagRelated.select(tag: "KV cache", tagged: [], candidates: papers, terms: terms).count == 1)
        var strict = TagRelated.Settings(); strict.commonPhraseShare = share / 2
        #expect(TagRelated.select(tag: "KV cache", tagged: [], candidates: papers, terms: terms, settings: strict).isEmpty,
                "a phrase in more of the pool than the setting allows")
        #expect(TagPhrase("Not a phrase in any paper here")?.poolShare(terms) == nil, "unlisted: rare, or longer than three words")
        #expect(TagPhrase("Fine-tuning") == nil, "one of the Feed's most common topics")
    }

    // MARK: The public fixture library

    /// The Library's tags for a fixture paper, as `LibraryTags` makes them (the app target): the term layer's first four
    /// keywords, then the first two vocabulary names, without repeats.
    static func tags(_ model: InterestLibraryModel, key: String, title: String, abstract: String) -> [String] {
        let derived = PaperKeywords.derive(title: title, abstract: abstract)
        let specific = model.keywords(for: key, title: title, abstract: abstract)
        guard !specific.isEmpty else { return derived }
        var seen = Set<String>(), merged: [String] = []
        for name in specific.prefix(4) + derived.prefix(2) where seen.insert(name.lowercased()).inserted { merged.append(name) }
        return merged
    }

    struct Measured { let tag: String; let tagged: [String]; let added: [(id: String, reason: TagRelated.Reason)] }

    /// Every tag on two or more papers, and what Filter + related adds to it.
    static func measure(papers: [(key: String, title: String, abstract: String, vector: [Float]?)], tags: [String: [String]],
                        terms: InterestTerms?, settings: TagRelated.Settings = TagRelated.Settings(), minimumTagged: Int = 2) -> [Measured] {
        var counts: [String: Int] = [:]
        for list in tags.values { for tag in Set(list) { counts[tag, default: 0] += 1 } }
        let rows = papers.map { TagRelated.Paper(id: $0.key, title: $0.title, abstract: $0.abstract, vector: $0.vector) }
        return counts.filter { $0.value >= minimumTagged }.keys.sorted().map { tag in
            let tagged = rows.filter { tags[$0.id]?.contains(tag) == true }
            let candidates = rows.filter { tags[$0.id]?.contains(tag) != true }
            let related = TagRelated.select(tag: tag, tagged: tagged, candidates: candidates, terms: terms, settings: settings)
            return Measured(tag: tag, tagged: tagged.map(\.id), added: related.map { ($0.key, $0.value) }.sorted { $0.id < $1.id })
        }
    }

    static func report(_ measured: [Measured], titles: [String: String], label: String) {
        let total = measured.reduce(0) { $0 + $1.added.count }
        print("tag-related[\(label)]: \(measured.count) tags on ≥ 2 papers; \(total) papers added in all")
        for m in measured {
            print("tag-related[\(label)]: “\(m.tag)” \(m.tagged.count) tagged, +\(m.added.count)")
            for id in m.tagged { print("tag-related[\(label)]:     tagged  \(titles[id]?.prefix(90) ?? "")") }
            for a in m.added { print("tag-related[\(label)]:     + \(a.reason.text) — \(titles[a.id]?.prefix(90) ?? "")") }
        }
    }

    @Test func fixtureLibraryAddsCloseAndMentioningPapersOnly() throws {
        let fixture = try InterestTopicsTests.json("interest-library-v1")
        let map = try InterestMap(InterestArtifact(gzipped: InterestTopicsTests.resource("interest-map-v1", "gsi")))
        let terms = try InterestTerms(InterestArtifact(gzipped: InterestTopicsTests.resource("interest-terms-fixture", "gsi")))
        let (model, _, papers) = try InterestTopicsTests.library(fixture, map: map, terms: terms)
        var tags: [String: [String]] = [:]
        for p in papers { tags[p.key] = Self.tags(model, key: p.key, title: p.title, abstract: p.abstract) }
        let rows = papers.map { (key: $0.key, title: $0.title, abstract: $0.abstract, vector: model.fingerprints[$0.key]?.vector) }
        let measured = Self.measure(papers: rows, tags: tags, terms: terms)
        let titles = Dictionary(uniqueKeysWithValues: papers.map { ($0.key, $0.title) })
        if ProcessInfo.processInfo.environment["TAG_RELATED_REPORT"] != nil { Self.report(measured, titles: titles, label: "fixture") }
        #expect(!measured.isEmpty)
        func added(_ tag: String) -> [String] { measured.first { $0.tag == tag }?.added.map { titles[$0.id]! } ?? [] }
        // Multi-agent papers that say so join “Multi-Agent”; robot, speech and cryo-EM papers never do.
        #expect(added("Multi-Agent").contains { $0.hasPrefix("ECMR") } && added("Multi-Agent").contains { $0.hasPrefix("Shared-Roadmap") })
        #expect(!added("Multi-Agent").contains { ["Robot", "ASR", "Dexterous", "Cryo-EM"].contains(where: $0.contains) })
        // KV-cache papers close to just the one KV-cache paper tagged “Retrieval-augmented generation” (a weak tag) stay out;
        // the KV-cache paper about RAG joins by its words.
        let rag = added("Retrieval-augmented generation")
        #expect(rag.contains { $0.hasPrefix("SAFE-KV") } && !rag.contains { $0.hasPrefix("BELT") } && !rag.contains { $0.hasPrefix("KV-Repurpose") })
        // Every addition has its reason: the tag's words, or closeness to two or more tagged papers.
        for m in measured { for a in m.added { #expect(a.reason.mentions != nil || a.reason.closeTo >= 2) } }
        // Nothing is added to a tag twice, and a tagged paper never comes back as related.
        for m in measured { #expect(Set(m.added.map(\.id)).isDisjoint(with: m.tagged)) }
    }

    /// Opt-in: a real library (`INTEREST_DEVICE_DIR`, as InterestLibraryMeasurementTests) through the same rule. Prints every
    /// tag on two or more papers and what it adds; never committed, never run by default.
    @Test func realLibraryMeasurement() throws {
        guard let path = ProcessInfo.processInfo.environment["INTEREST_DEVICE_DIR"], !path.isEmpty else { return }
        struct Row: Decodable { let source_id: String; let title: String?; let abstract: String? }
        struct FP: Decodable { let q8: String; let leaf_id: Int?; let leaf_map_version: Int?; let terms: [String]? }
        let folder = URL(fileURLWithPath: path)
        let map = try InterestMap(InterestArtifact(gzipped: Data(contentsOf: folder.appendingPathComponent("map.gsi"))))
        let terms = try InterestTerms(InterestArtifact(gzipped: Data(contentsOf: folder.appendingPathComponent("terms.gsi"))))
        let fps = try JSONDecoder().decode([String: FP].self, from: Data(contentsOf: folder.appendingPathComponent("fingerprints.json")))
        let data = try Data(contentsOf: folder.appendingPathComponent("library.json"))
        let label = ProcessInfo.processInfo.environment["INTEREST_LIBRARY"] ?? ""
        let all = label.isEmpty ? try JSONDecoder().decode([Row].self, from: data) : try JSONDecoder().decode([String: [Row]].self, from: data)[label] ?? []
        var seen = Set<String>()
        let rows = all.filter { seen.insert($0.source_id).inserted }
        var model = InterestLibraryModel(map: map, terms: terms)
        model.setFingerprints(fps.map { key, fp in
            InterestFingerprint(key: key, vector: InterestQ8.decode(Data(base64Encoded: fp.q8, options: .ignoreUnknownCharacters)!), leafID: fp.leaf_id,
                                terms: fp.terms ?? [], mapVersion: fp.leaf_map_version)
        })
        let papers = rows.map { r in
            InterestLibraryPaper(id: UUID(), key: r.source_id.hasPrefix("upload:") ? nil : r.source_id, title: r.title ?? "", abstract: r.abstract ?? "",
                                 weight: .init(addedAt: nil, archived: false))
        }
        _ = model.update(papers: papers, registry: InterestRegistry(), now: Date())
        var tags: [String: [String]] = [:]
        for r in rows { tags[r.source_id] = Self.tags(model, key: r.source_id, title: r.title ?? "", abstract: r.abstract ?? "") }
        let input = rows.map { (key: $0.source_id, title: $0.title ?? "", abstract: $0.abstract ?? "", vector: model.fingerprints[InterestPool.key($0.source_id)]?.vector) }
        let titles = Dictionary(rows.map { ($0.source_id, $0.title ?? "") }, uniquingKeysWith: { a, _ in a })
        let started = Date()
        let measured = Self.measure(papers: input, tags: tags, terms: terms)
        print(String(format: "tag-related[real]: %d papers (%d with a fingerprint); %d tags measured in %.1f ms", rows.count,
                     input.filter { $0.vector != nil }.count, measured.count, Date().timeIntervalSince(started) * 1000))
        Self.report(measured, titles: titles, label: "real")
        // Closeness of each candidate to the tagged papers: the best single cosine, how many at ≥ 0.88, the centroid's.
        if ProcessInfo.processInfo.environment["TAG_RELATED_DETAIL"] != nil {
            let vectors = Dictionary(input.compactMap { row in row.vector.map { (row.key, $0) } }, uniquingKeysWith: { a, _ in a })
            for m in measured {
                let anchors = m.tagged.compactMap { vectors[$0] }
                guard !anchors.isEmpty else { continue }
                var centroid = [Float](repeating: 0, count: 384)
                for a in anchors { for i in 0 ..< 384 { centroid[i] += a[i] } }
                let norm = centroid.reduce(0) { $0 + $1 * $1 }.squareRoot()
                centroid = centroid.map { $0 / norm }
                var rows: [(String, Float, Float, Int)] = []
                for (key, v) in vectors where !m.tagged.contains(key) {
                    let sims = anchors.map { TagRelated.similarity(v, $0) }
                    rows.append((key, sims.max()!, TagRelated.similarity(v, centroid), sims.filter { $0 >= 0.88 }.count))
                }
                rows.sort { $0.1 > $1.1 }
                print("tag-related[detail]: “\(m.tag)” (\(anchors.count) tagged)")
                for r in rows.prefix(6) {
                    print(String(format: "tag-related[detail]:     max %.3f  centroid %.3f  n %d  %@", r.1, r.2, r.3, String(titles[r.0]?.prefix(70) ?? "")))
                }
            }
        }
        for threshold: Float in [0.86, 0.90, 0.92] {
            var settings = TagRelated.Settings(); settings.closeSimilarity = threshold
            let other = Self.measure(papers: input, tags: tags, terms: terms, settings: settings)
            print("tag-related[real]: at \(threshold): \(other.reduce(0) { $0 + $1.added.count }) papers added in all")
        }
    }

    /// Opt-in: 1,000-paper libraries drawn from the staging pool (`TAG_RELATED_POOL_DIR` = tools/interest-eval's output
    /// folder: `corpus.json` and `emb/gte-small.npy`, the same model as the fingerprints, unquantised). For each phrase, up to
    /// eight pool papers with it in their title are the tagged papers and 1,000 others (fixed seed) the rest of the library;
    /// prints what each rule adds, for reading by eye. `INTEREST_DEVICE_DIR` adds the published term statistics.
    @Test func poolLibrariesMeasurement() throws {
        guard let path = ProcessInfo.processInfo.environment["TAG_RELATED_POOL_DIR"], !path.isEmpty else { return }
        struct Row: Decodable { let source_id: String; let title: String?; let abstract: String? }
        let folder = URL(fileURLWithPath: path)
        let corpus = try JSONDecoder().decode([Row].self, from: Data(contentsOf: folder.appendingPathComponent("corpus.json")))
        let npy = try Data(contentsOf: folder.appendingPathComponent("emb/gte-small.npy"))
        let headerLength = Int(npy[8]) | Int(npy[9]) << 8
        let start = 10 + headerLength
        #expect((npy.count - start) / 4 == corpus.count * 384)
        let vectors: [[Float]] = npy.withUnsafeBytes { raw in
            (0 ..< corpus.count).map { row in
                let v = (0 ..< 384).map { raw.loadUnaligned(fromByteOffset: start + (row * 384 + $0) * 4, as: Float.self) }
                let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
                return v.map { $0 / n }
            }
        }
        let terms = try ProcessInfo.processInfo.environment["INTEREST_DEVICE_DIR"].map {
            try InterestTerms(InterestArtifact(gzipped: Data(contentsOf: URL(fileURLWithPath: $0).appendingPathComponent("terms.gsi"))))
        }
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        let phrases = ["on-policy distillation", "kv cache", "speculative decoding", "world models", "mixture of experts",
                       "computer-use agents", "video generation", "multi-agent", "medical image segmentation", "sparse attention",
                       "mathematical reasoning", "real-world", "knowledge distillation", "reward model"]
        var plainTotal = 0, chosenTotal = 0
        for phrase in phrases {
            let probe = try #require(TagPhrase(phrase))
            let titled = corpus.indices.filter { probe.occurs(in: TagPhrase.words(corpus[$0].title ?? "")) }
            let tagged = Array(stride(from: 0, to: titled.count, by: max(1, titled.count / 8)).map { titled[$0] }.prefix(8))
            var others = Set<Int>()
            while others.count < 1_000 { let i = next() % corpus.count; if !tagged.contains(i) { others.insert(i) } }
            func paper(_ i: Int) -> TagRelated.Paper {
                TagRelated.Paper(id: String(i), title: corpus[i].title ?? "", abstract: corpus[i].abstract ?? "", vector: vectors[i])
            }
            let candidates = others.sorted().map(paper)
            var plain = TagRelated.Settings(); plain.closeCount = 1
            let loose = TagRelated.select(tag: phrase, tagged: tagged.map(paper), candidates: candidates, terms: terms, settings: plain)
            let chosen = TagRelated.select(tag: phrase, tagged: tagged.map(paper), candidates: candidates, terms: terms)
            plainTotal += loose.count; chosenTotal += chosen.count
            let byWords = chosen.values.filter { $0.mentions != nil }.count
            let share = terms.flatMap { probe.poolShare($0) }.map { String(format: "%.1f %%", $0 * 100) } ?? "—"
            print("tag-related[pool]: “\(phrase)” (pool share \(share)) \(tagged.count) tagged; 0.88 alone +\(loose.count); chosen +\(chosen.count) (\(byWords) by words)")
            for (id, reason) in chosen.sorted(by: { $0.key < $1.key }) {
                let v = vectors[Int(id)!], best = tagged.map { TagRelated.similarity(v, vectors[$0]) }.max() ?? 0
                print(String(format: "tag-related[pool]:     %.3f  %@ — %@", best, reason.text, String(corpus[Int(id)!].title?.prefix(80) ?? "")))
            }
            for (id, _) in loose where chosen[id] == nil {
                let v = vectors[Int(id)!], best = tagged.map { TagRelated.similarity(v, vectors[$0]) }.max() ?? 0
                print(String(format: "tag-related[pool]:     dropped %.3f  %@", best, String(corpus[Int(id)!].title?.prefix(80) ?? "")))
            }
        }
        print("tag-related[pool]: \(phrases.count) tags: 0.88 alone adds \(plainTotal), the chosen rule \(chosenTotal)")
    }

    /// A 1,000-paper library, half of whose abstracts have the tag's longest word (so they are split into words): runs in the
    /// Library search's worker, off the main thread; the time is printed (debug builds on a busy machine vary too much to
    /// assert).
    @Test func largeLibraryMeasurement() {
        var rng = SystemRandomNumberGenerator()
        func random() -> [Float] {
            let v = (0 ..< 384).map { _ in Float.random(in: -1 ... 1, using: &rng) }
            let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return v.map { $0 / n }
        }
        let near = String(repeating: "We study policy optimization with on-line teachers and distillation of students. ", count: 18)
        let far = String(repeating: "We study graph kernels for molecules and their spectra under noise and sampling. ", count: 18)
        let tagged = (0 ..< 40).map { TagRelated.Paper(id: "t\($0)", title: "Tagged \($0)", abstract: near, vector: random()) }
        let candidates = (0 ..< 1_000).map { TagRelated.Paper(id: "c\($0)", title: "Candidate \($0)", abstract: $0 % 2 == 0 ? near : far, vector: random()) }
        let started = Date()
        let related = TagRelated.select(tag: "On-policy distillation", tagged: tagged, candidates: candidates)
        #expect(related.isEmpty, "random fingerprints are never close; no abstract has the phrase")
        print(String(format: "tag-related: 40 tagged × 1,000 candidates in %.0f ms", Date().timeIntervalSince(started) * 1000))
    }

    @Test func reasonsQuoteTheTagInLowerCaseKeepingAcronyms() throws {
        #expect(try #require(TagPhrase("Multi-Agent")).quoted == "multi-agent")
        #expect(try #require(TagPhrase("LLM-Based")).quoted == "LLM-based")
        #expect(try #require(TagPhrase("LoRA adapters")).quoted == "LoRA adapters")
        #expect(try #require(TagPhrase("Teacher policy")).quoted == "teacher policy")
    }
}
