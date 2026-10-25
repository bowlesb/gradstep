import Foundation
import Testing
@testable import ScienceReaderCore

/// The interest index's device layer (docs/architecture/INTEREST_INDEX.md "Device layer"): the state's exact updates,
/// the topic rule against step 2's own output, hysteresis, the term layer against the reference in
/// tools/interest-eval/device_fixtures.py, and the published map and term statistics decoded from server-shaped bytes.
@Suite struct InterestTopicsTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func resource(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: try #require(Bundle.module.url(forResource: name, withExtension: ext)))
    }
    static func json(_ name: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: resource(name, "json")) as? [String: Any])
    }
    static func floats(_ base64: String) -> [Float] {
        let data = Data(base64Encoded: base64)!
        return data.withUnsafeBytes { raw in (0 ..< data.count / 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) } }
    }
    static func nodes(_ raw: [[String: Any]]) -> [InterestMap.Node] {
        raw.map { n in
            InterestMap.Node(id: n["id"] as! Int, level: n["level"] as! Int, parent: n["parent"] as? Int, size: n["size"] as! Int,
                             terms: n["terms"] as? [String] ?? [])
        }
    }
    static func map(_ fixture: [String: Any], version: Int = 1) throws -> InterestMap {
        let nodes = nodes(fixture["nodes"] as! [[String: Any]])
        return try InterestMap(version: version, nodes: nodes, centroids: nodes.map { _ in [Float](repeating: 0, count: 384) })
    }

    // MARK: Step 2 on the owner's library

    @Test func topicRuleReproducesStepTwo() throws {
        let fixture = try Self.json("interest-step2-topics")
        let map = try Self.map(fixture)
        #expect(map.backgroundTotal == fixture["background_total"] as! Int)
        var state = InterestState(mapVersion: 1)
        for p in fixture["papers"] as! [[String: Any]] {
            let added = state.add(InterestPaper(key: p["key"] as! String, vector: Self.floats(p["vector"] as! String),
                                                leafID: p["leaf"] as? Int, weight: p["weight"] as! Double), map: map)
            #expect(added)
        }
        let selection = InterestTopicRule.select(state: state, map: map)
        let expected = fixture["expected"] as! [String: Any]
        let topics = expected["topics"] as! [[String: Any]]
        #expect(selection.topics.count == 14 && topics.count == 14)
        for want in topics {
            let got = try #require(selection.topics.first { $0.id == want["node"] as! Int }, "topic \(want["node"]!)")
            #expect(got.papers == (want["papers"] as! [String]).sorted())
            #expect(got.folded == want["folded"] as! Int)
            #expect(got.level == want["level"] as! Int && got.residual == want["residual"] as! Bool)
            #expect(abs(got.share - (want["share"] as! Double)) < 1e-4)
            #expect(abs(got.lift - (want["lift"] as! Double)) < 0.06)
        }
        #expect(selection.other == (expected["other"] as! [String]).sorted())
        let groups = (expected["other_groups"] as! [[String: Any]]).map { ($0["node"] as! Int, $0["count"] as! Int) }
        #expect(selection.otherGroups.map(\.node) == groups.map(\.0) && selection.otherGroups.map(\.papers.count) == groups.map(\.1))
        #expect(selection.emerging.count == (expected["emerging"] as! [Any]).count)
    }

    // MARK: State

    private static func unit(_ seed: Int) -> [Float] {
        var v = (0 ..< 384).map { Float(sin(Double(seed * 97 + $0) * 13.37)) }
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        v = v.map { $0 / n }
        return v
    }

    @Test func stateUpdatesAreExactAndOrderIndependent() throws {
        let fixture = try Self.json("interest-step2-topics")
        let map = try Self.map(fixture)
        let papers = (fixture["papers"] as! [[String: Any]]).map {
            InterestPaper(key: $0["key"] as! String, vector: Self.floats($0["vector"] as! String), leafID: $0["leaf"] as? Int, weight: $0["weight"] as! Double)
        }
        var forward = InterestState(mapVersion: 1), backward = InterestState(mapVersion: 1)
        for p in papers { forward.add(p, map: map) }
        for p in papers.reversed() { backward.add(p, map: map) }
        #expect(forward == backward)
        // Removing papers is the exact inverse of adding them (integer sums), in any order.
        var partial = InterestState(mapVersion: 1)
        for p in papers.prefix(40) { partial.add(p, map: map) }
        var shrunk = forward
        for p in papers.dropFirst(40).shuffled() { shrunk.remove(p.key) }
        #expect(shrunk == partial)
        // A changed weight replaces the paper; sync brings the state to exactly the given papers.
        var reweighted = forward
        reweighted.add(InterestPaper(key: papers[0].key, vector: papers[0].vector, leafID: papers[0].leafID, weight: 3), map: map)
        #expect(reweighted != forward && reweighted.weight(of: papers[0].key) == 3)
        reweighted.sync(papers, map: map)
        #expect(reweighted == forward)
        var synced = InterestState(mapVersion: 1)
        synced.sync(Array(papers.prefix(40)), map: map)
        #expect(synced == partial)
        // Per node: counts, mass and the weighted fingerprint sum.
        let leaf = try #require(papers[0].leafID)
        let stats = try #require(forward.stats[leaf])
        #expect(stats.count == forward.members[leaf]!.count)
        let centroid = try #require(stats.centroid)
        #expect(abs(centroid.reduce(0) { $0 + $1 * $1 } - 1) < 1e-4)
        #expect(forward.paperCount == papers.count && abs(forward.totalMass - papers.reduce(0) { $0 + $1.weight }) < 0.01)
    }

    @Test func weightsFollowTheOwnersRules() {
        let now = Date(timeIntervalSince1970: 1_792_886_400) // 2026-10-25 00:00 UTC
        let day = 86_400.0
        let base = InterestWeights.weight(.init(addedAt: now), now: now)
        #expect(abs(base - 1) < 1e-12)
        #expect(abs(InterestWeights.weight(.init(addedAt: now - 120 * day), now: now) - (0.4 + 0.6 * exp(-1))) < 1e-12)
        #expect(abs(InterestWeights.weight(.init(addedAt: now, archived: true), now: now) - 0.5) < 1e-12)
        #expect(abs(InterestWeights.weight(.init(addedAt: now, hasOwnTags: true), now: now) - 1.5) < 1e-12)
        #expect(abs(InterestWeights.weight(.init(addedAt: now, readingLevel: 4, snippets: 1, chats: 2), now: now) - 1.75) < 1e-12)
        // Ages count whole UTC days: two devices computing on the same day agree.
        #expect(InterestWeights.weight(.init(addedAt: now - 3 * day + 5), now: now + 3_000) == InterestWeights.weight(.init(addedAt: now - 3 * day), now: now + 80_000))
        #expect([nil, 0.05, 0.1, 0.34, 0.35, 0.6, 0.89, 0.9, 1].map { InterestWeights.readingLevel(progress: $0) } == [0, 0, 1, 1, 2, 3, 3, 4, 4])
    }

    // MARK: The published map, the term statistics and a public library

    @Test func publishedMapDecodesAndDescendsLikeTheServer() throws {
        let map = try InterestMap(InterestArtifact(gzipped: Self.resource("interest-map-v1", "gsi")))
        let fixture = try Self.json("interest-library-v1")
        #expect(map.version == 1 && map.modelVersion?.hasPrefix("gte-small") == true)
        #expect([1, 2, 3].map { level in map.nodes.filter { $0.level == level }.count } == [20, 68, 246])
        #expect(map.backgroundTotal == fixture["background_total"] as! Int)
        #expect(map.nodes.map(\.id) == (fixture["nodes"] as! [[String: Any]]).map { $0["id"] as! Int })
        // Every leaf's path ends at a level-1 node; each centroid is unit length.
        for node in map.nodes where node.level == 3 {
            #expect(map.path(from: node.id).count == 3)
            let c = try #require(map.centroid(of: node.id))
            #expect(abs(c.reduce(0) { $0 + $1 * $1 } - 1) < 1e-3)
        }
        // The device's descent agrees with the server's leaves for the fixture papers.
        var agree = 0, total = 0
        for p in fixture["papers"] as! [[String: Any]] {
            let vector = InterestQ8.decode(Data(base64Encoded: p["q8"] as! String)!)
            total += 1
            if map.descend(vector) == p["leaf"] as? Int { agree += 1 }
        }
        #expect(total == 38 && agree >= total - 1, "descent agreed on \(agree) of \(total)")
    }

    @Test func mapFollowsRetiredIDsToTheirLargestSuccessor() throws {
        let nodes = [InterestMap.Node(id: 1, level: 1, parent: nil, size: 10), InterestMap.Node(id: 2, level: 2, parent: 1, size: 10),
                     InterestMap.Node(id: 3, level: 3, parent: 2, size: 6), InterestMap.Node(id: 4, level: 3, parent: 2, size: 4)]
        let map = try InterestMap(version: 3, nodes: nodes, centroids: nodes.map { Self.unit($0.id) },
                                  retired: [.init(id: 9, successors: [3, 4], shares: [0.3, 0.7]), .init(id: 8, successors: [9], shares: [1])])
        #expect(map.live(3) == 3 && map.live(9) == 4 && map.live(8) == 4 && map.live(77) == nil)
        #expect(map.descend(Self.unit(4)) == 4 && map.descend(Self.unit(3)) == 3)
    }

    @Test func termStatisticsDecodeAndTokenizeLikeScikitLearn() throws {
        let terms = try InterestTerms(InterestArtifact(gzipped: Self.resource("interest-terms-fixture", "gsi")))
        #expect(terms.corpusPapers > 9_000 && terms.totalDF > 100_000 && terms.stopWords.count == 410 && terms.count > 1_000)
        let kv = try #require(terms.find("kv cache"))
        #expect(terms.phrase(kv) == "kv cache" && terms.documentFrequency(kv) > 10 && terms.find("not a phrase here") == nil)
        // Sorted bytewise: every phrase finds itself.
        for i in stride(from: 0, to: terms.count, by: 37) { #expect(terms.find(terms.phrase(i)) == i) }

        // Tokens: Python's Unicode word boundaries, stop words dropped before n-grams (tests/backend/interest-terms.test.ts).
        #expect(InterestPhrases.tokens("The KV-cache of naïve GPT-4o models, 3D x", stopWords: terms.stopWords) == ["kv-cache", "gpt-4o"])
        #expect(InterestPhrases.tokens("naïve café résumé", stopWords: terms.stopWords).isEmpty)
        #expect(InterestPhrases.ngrams(["a", "b", "c"]) == ["a", "b", "c", "a b", "b c", "a b c"])
        #expect(InterestPhrases.ngrams(InterestPhrases.tokens("sparse learning of representations", stopWords: terms.stopWords)).contains("learning representations"))

        // scikit-learn CountVectorizer on 40 pool papers (min_df 2, max_df 0.5): the same vocabulary and counts.
        let ngrams = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.root.appendingPathComponent("tests/fixtures/interest/ngrams.json"))) as? [String: Any])
        let stop = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.root.appendingPathComponent("tests/fixtures/interest/stopwords.json"))) as? [String: Any])
        let stopWords = Set((stop["sklearn_english"] as! [String]) + (stop["domain"] as! [String]))
        let docs = (ngrams["docs"] as! [[String: String]]).map { InterestPhrases.documentText(title: $0["title"]!, abstract: $0["abstract"]!) }
        var df: [String: Int] = [:]
        var doc0: [String: Int] = [:]
        for (i, doc) in docs.enumerated() {
            let grams = InterestPhrases.ngrams(InterestPhrases.tokens(doc, stopWords: stopWords))
            for g in Set(grams) { df[g, default: 0] += 1 }
            if i == 0 { for g in grams { doc0[g, default: 0] += 1 } }
        }
        let vocabulary = df.filter { $0.value >= 2 && Double($0.value) <= 0.5 * Double(docs.count) }
        #expect(vocabulary == ngrams["vocabulary"] as! [String: Int])
        #expect(doc0.filter { vocabulary[$0.key] != nil } == ngrams["doc0_counts"] as! [String: Int])
    }

    /// The public fixture library through the whole device pipeline, against the Python reference.
    @Test func publicLibraryTopicsLabelsAndKeywordsMatchTheReference() throws {
        let fixture = try Self.json("interest-library-v1")
        let map = try InterestMap(InterestArtifact(gzipped: Self.resource("interest-map-v1", "gsi")))
        let terms = try InterestTerms(InterestArtifact(gzipped: Self.resource("interest-terms-fixture", "gsi")))
        #expect(InterestLabels.generic == Set(fixture["generic"] as! [String]))
        let (model, topics, papers) = try Self.library(fixture, map: map, terms: terms)
        let expected = fixture["expected"] as! [String: Any]
        let wantTopics = expected["topics"] as! [[String: Any]]
        let selection = InterestTopicRule.select(state: model.state, map: map)
        #expect(selection.topics.map(\.id) == wantTopics.map { $0["id"] as! Int })
        for (got, want) in zip(selection.topics, wantTopics) {
            #expect(got.papers == want["papers"] as! [String])
            #expect(got.folded == want["folded"] as! Int && got.residual == want["residual"] as! Bool)
            #expect(abs(got.share - (want["share"] as! Double)) < 1e-12)
        }
        #expect(selection.other == expected["other"] as! [String])
        // Labels: the same phrases, title-cased, and never a generic area.
        #expect(topics.topics.map(\.terms) == wantTopics.map { $0["terms"] as! [String] })
        for slice in topics.topics {
            #expect(slice.label == InterestLabels.label(slice.terms) && !InterestLabels.isGeneric(slice.label))
            #expect(slice.papers.count == wantTopics.first { $0["id"] as! Int == slice.id }.map { ($0["papers"] as! [String]).count })
        }
        #expect(topics.topics.first?.label == "KV Cache Compression, Decoding Throughput")
        #expect(topics.topics.map(\.colour) == Array(0 ..< topics.topics.count).map { Optional($0) })
        #expect(abs(topics.all.reduce(0) { $0 + $1.share } - 1) < 1e-9)
        #expect(topics.indexed == 38 && topics.pending == 0 && topics.uploads == 0)
        // Per-paper keywords (title and abstract).
        let keywords = expected["keywords"] as! [String: [String]]
        for p in papers {
            let got = InterestLabels.paperTerms(p.key, counts: InterestPhrases.counts(InterestPhrases.documentText(title: p.title, abstract: p.abstract), terms: terms),
                                                state: model.state, text: model.text, terms: terms,
                                                endorsed: Set((model.fingerprints[p.key]?.terms ?? []).map { $0.lowercased() })).map(terms.phrase)
            #expect(got == keywords[p.key], "\(p.key)")
        }
        let kv = try #require(papers.first { $0.title.hasPrefix("KVFetch") })
        #expect(model.keywords(for: kv.key, title: kv.title, abstract: kv.abstract).first.map { $0.first!.isUppercase } == true)
    }

    @Test func hysteresisKeepsAnEstablishedTopicAtTwoPapers() throws {
        let fixture = try Self.json("interest-library-v1")
        let map = try InterestMap(InterestArtifact(gzipped: Self.resource("interest-map-v1", "gsi")))
        let h = try #require((fixture["expected"] as! [String: Any])["hysteresis"] as? [String: Any])
        let topic = h["topic"] as! Int, removed = h["removed"] as! String
        let (model, _, _) = try Self.library(fixture, map: map, terms: nil)
        let before = InterestTopicRule.select(state: model.state, map: map)
        #expect(before.topicIDs.contains(topic))
        var state = model.state
        state.remove(removed)
        // Appears at 3, leaves below 2: a new topic needs 3; one the reader has keeps at 2…
        #expect(InterestTopicRule.select(state: state, map: map).topicIDs.contains(topic) == (h["without_established"] as! Bool))
        let kept = InterestTopicRule.select(state: state, map: map, established: before.topicIDs)
        #expect(kept.topicIDs.contains(topic) == (h["with_established"] as! Bool) && kept.topicIDs.contains(topic))
        // …and leaves at 1.
        let second = try #require(kept.topics.first { $0.id == topic }?.papers.first)
        state.remove(second)
        #expect(!InterestTopicRule.select(state: state, map: map, established: before.topicIDs).topicIDs.contains(topic))
        // The registry carries the shown set between devices: the same inputs give the same topics everywhere.
        let device = UUID()
        var registry = InterestRegistry()
        registry.apply(try InterestRegistryRecord(device: device, shown: registry.shownChanges(selected: before.topicIDs, map: map)))
        #expect(registry.shownIDs(map: map) == before.topicIDs)
        var otherDevice = InterestRegistry()
        otherDevice.apply(try InterestRegistryRecord(device: device, shown: InterestRegistry().shownChanges(selected: before.topicIDs, map: map)))
        #expect(otherDevice == registry)
    }

    struct FixturePaper { let key: String; let title: String; let abstract: String }

    static func library(_ fixture: [String: Any], map: InterestMap, terms: InterestTerms?) throws
        -> (InterestLibraryModel, InterestLibraryTopics, [FixturePaper]) {
        let now = ISO8601DateFormatter().date(from: (fixture["now"] as! String).replacingOccurrences(of: "+00:00", with: "Z"))!
        var model = InterestLibraryModel(map: map, terms: terms)
        var papers: [InterestLibraryPaper] = [], plain: [FixturePaper] = []
        var fingerprints: [InterestFingerprint] = []
        for (i, p) in (fixture["papers"] as! [[String: Any]]).enumerated() {
            let key = p["key"] as! String
            let inputs = InterestWeights.Inputs(addedAt: now.addingTimeInterval(-Double(p["days_ago"] as! Int) * 86_400), archived: p["archived"] as! Bool,
                                                hasOwnTags: p["own_tags"] as! Bool, readingLevel: p["reading"] as! Int,
                                                snippets: p["snippets"] as! Int, chats: p["chats"] as! Int)
            papers.append(InterestLibraryPaper(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!, key: key,
                                               title: p["title"] as! String, abstract: p["abstract"] as! String, weight: inputs))
            plain.append(FixturePaper(key: key, title: p["title"] as! String, abstract: p["abstract"] as! String))
            fingerprints.append(InterestFingerprint(key: key, vector: InterestQ8.decode(Data(base64Encoded: p["q8"] as! String)!),
                                                    leafID: p["leaf"] as? Int, terms: p["server_terms"] as? [String] ?? [],
                                                    mapVersion: p["leaf_map_version"] as? Int))
        }
        model.setFingerprints(fingerprints)
        let topics = model.update(papers: papers, registry: InterestRegistry(), now: now)
        return (model, topics, plain)
    }

    @Test func labelsAreTitleCasedTermsAndKeywordsSentenceCased() {
        #expect(InterestLabels.titleCase("parameter-efficient fine-tuning") == "Parameter-Efficient Fine-Tuning")
        #expect(InterestLabels.titleCase("kv cache compression") == "KV Cache Compression")
        #expect(InterestLabels.titleCase("llm-based multi-agent") == "LLM-Based Multi-Agent")
        #expect(InterestLabels.sentenceCase("kv cache compression") == "KV cache compression")
        #expect(InterestLabels.sentenceCase("parameter-efficient fine-tuning") == "Parameter-efficient fine-tuning")
        #expect(InterestLabels.label(["retrieval"]) == "Retrieval")
        #expect(InterestLabels.label(["parameter-efficient fine-tuning", "lora", "matrices"]) == "Parameter-Efficient Fine-Tuning, LoRA")
        // A term that would take the label past 44 characters is left out rather than making it run on.
        #expect(InterestLabels.label(["multi-agent interaction", "collaboration", "coordination"]) == "Multi-Agent Interaction, Collaboration")
        #expect(InterestLabels.label(["recursive self-improvement", "verification", "long-horizon agents"]) == "Recursive Self-Improvement, Verification")
        #expect(InterestLabels.isGeneric("Machine learning") && InterestLabels.isGeneric("regression") && InterestLabels.isGeneric("transformers")
                && !InterestLabels.isGeneric("sparse attention") && !InterestLabels.isGeneric("agents"))
    }
}
