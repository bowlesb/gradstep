import Foundation

/// Measures global search's everything index (docs/architecture/GLOBAL_SEARCH.md "Measurements") on a synthetic,
/// deterministic corpus shaped like the proposal's owner and heavy profiles: chats whose messages alternate short
/// questions and two-to-four-paragraph answers (a third with an equation in LaTeX), kept explanations with symbols,
/// snippets, diagrams and collections. Words follow a Zipf-like mix of English function words, ML vocabulary (compounds,
/// model names, arXiv IDs, Greek letters in Unicode and LaTeX) and rare made-up words, so common words match most items
/// and the dictionary grows with the corpus. Prints no text. Used by `FullTextBenchTool everything` (release build) and
/// the opt-in `EverythingBenchTests`.
public enum EverythingBench {
    public struct Profile: Sendable, Equatable {
        public let name: String
        public let chats: Int, messages: Int, explanations: Int, snippets: Int, diagrams: Int, collections: Int
        public var items: Int { chats + messages + explanations + snippets + diagrams + collections }
        public static let owner = Profile(name: "owner", chats: 300, messages: 3_000, explanations: 1_200, snippets: 1_200, diagrams: 80, collections: 40)
        public static let heavy = Profile(name: "heavy", chats: 1_000, messages: 12_000, explanations: 4_000, snippets: 4_000, diagrams: 300, collections: 150)
        /// A quick one for ordinary test runs.
        public static let small = Profile(name: "small", chats: 30, messages: 300, explanations: 120, snippets: 120, diagrams: 8, collections: 4)
        public init(name: String, chats: Int, messages: Int, explanations: Int, snippets: Int, diagrams: Int, collections: Int) {
            self.name = name; self.chats = chats; self.messages = messages; self.explanations = explanations
            self.snippets = snippets; self.diagrams = diagrams; self.collections = collections
        }
    }

    public struct QueryTiming: Sendable {
        public let query: String
        public let matches: [SearchGroup: Int]
        public let indexMedianMS: Double, indexP95MS: Double
        /// Grouped, ranked, with excerpts for each group's first rows (what the screen shows after a keystroke).
        public let fullMedianMS: Double, fullP95MS: Double
        public let correction: String?
    }

    public struct Report: Sendable, CustomStringConvertible {
        public var profile: Profile
        public var textBytes = 0
        public var prepareSeconds = 0.0, buildSeconds = 0.0
        public var indexBytes = 0
        public var openMS = 0.0, loadMS = 0.0
        public var queries: [QueryTiming] = []
        public var commitMedianMS = 0.0, commitP95MS = 0.0
        public var typoMS = 0.0
        public var worstFullP95MS: Double { queries.map(\.fullP95MS).max() ?? 0 }

        public var description: String {
            var lines = [
                "profile \(profile.name): \(profile.chats) chats / \(profile.messages) messages / \(profile.explanations) explanations / \(profile.snippets) snippets / \(profile.diagrams) diagrams / \(profile.collections) collections = \(profile.items) items",
                String(format: "text %.1f MB; items made (readable text) %.2f s; index built (tokenize, seal, write) %.2f s", Double(textBytes) / 1e6, prepareSeconds, buildSeconds),
                String(format: "on disk %.1f MB (%.0f B an item); open %.1f ms; load all segments %.1f ms", Double(indexBytes) / 1e6,
                       Double(indexBytes) / Double(max(1, profile.items)), openMS, loadMS),
            ]
            for q in queries {
                let counts = [SearchGroup.chats, .explanations, .snippets, .diagrams].map { String(q.matches[$0] ?? 0) }.joined(separator: "/")
                lines.append(String(format: "query %-18@ matches %-18@ index %6.2f ms (p95 %6.2f)  grouped+excerpts %6.2f ms (p95 %6.2f)%@",
                                    q.query as NSString, counts as NSString, q.indexMedianMS, q.indexP95MS, q.fullMedianMS, q.fullP95MS,
                                    (q.correction.map { "  → \($0)" } ?? "") as NSString))
            }
            lines.append(String(format: "typo correction (zero results, both words) %.2f ms", typoMS))
            lines.append(String(format: "one-item commit median %.1f ms, p95 %.1f ms", commitMedianMS, commitP95MS))
            return lines.joined(separator: "\n")
        }
    }

    public static let defaultQueries = ["softmax", "attention", "kl divergence", "\"policy gradient\"", "\\alpha", "α", "transfo",
                                        "atention ", "learning rate", "the"]

    /// Builds the profile's corpus into a fresh sealed index in `directory`, reopens it cold and times the queries.
    public static func run(_ profile: Profile, directory: URL, queries: [String] = defaultQueries, repetitions: Int = 20,
                           batch: Int = 512) async throws -> Report {
        try? FileManager.default.removeItem(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) }), account = UUID()
        var report = Report(profile: profile)
        let prepareStart = ContinuousClock.now
        let items = corpus(profile)
        report.prepareSeconds = seconds(prepareStart.duration(to: .now))
        report.textBytes = items.reduce(0) { $0 + $1.title.utf8.count + $1.tags.utf8.count + $1.notes.utf8.count + $1.body.utf8.count }
        var index = try EverythingIndex(directory: directory, accountID: account, localKey: key)
        let buildStart = ContinuousClock.now
        var start = 0
        while start < items.count {
            let slice = items[start..<min(items.count, start + batch)]
            try await index.commit(slice.map { ($0, $0.contentFingerprint) })
            start += batch
        }
        report.buildSeconds = seconds(buildStart.duration(to: .now))
        report.indexBytes = await index.footprint().bytes

        // Cold, as at launch: open (the manifest), then the first search loads every segment.
        await index.close()
        let open = ContinuousClock.now
        index = try EverythingIndex(directory: directory, accountID: account, localKey: key)
        report.openMS = milliseconds(open.duration(to: .now))
        let load = ContinuousClock.now
        let snapshot = try await index.snapshot()
        report.loadMS = milliseconds(load.duration(to: .now))
        let source = Dictionary(uniqueKeysWithValues: items.map { ($0.group, $0) })

        for text in queries {
            var query = FullTextQuery(text)
            var correction: String?
            var indexTimes: [Double] = [], fullTimes: [Double] = []
            var groups: [EverythingSearch.Group] = []
            for repetition in 0...repetitions {
                let started = ContinuousClock.now
                _ = snapshot.index.search(query)
                let indexed = milliseconds(started.duration(to: .now))
                let full = ContinuousClock.now
                groups = EverythingSearch.search(snapshot, query: query)
                if groups.isEmpty, repetition == 0, let word = query.clauses.first?.text,
                   let fixed = FullTextTypos.correction(for: word, in: [snapshot.index]) {
                    correction = fixed; query = FullTextQuery(fixed + " ")
                    groups = EverythingSearch.search(snapshot, query: query)
                }
                for group in groups {
                    for hit in group.hits.prefix(3) {
                        guard let item = source[hit.info.group] else { continue }
                        _ = EverythingSearch.display(item, title: item.title, query: query, match: hit.match, fieldClauses: hit.fieldClauses)
                    }
                }
                // The grouped search runs its own index query: its time includes it.
                if repetition > 0 { indexTimes.append(indexed); fullTimes.append(milliseconds(full.duration(to: .now))) }
            }
            var matches: [SearchGroup: Int] = [:]
            for group in groups { matches[group.group] = group.total }
            report.queries.append(QueryTiming(query: text, matches: matches, indexMedianMS: median(indexTimes), indexP95MS: p95(indexTimes),
                                              fullMedianMS: median(fullTimes), fullP95MS: p95(fullTimes), correction: correction))
        }
        let typo = ContinuousClock.now
        _ = FullTextTypos.correction(for: "transfromer", in: [snapshot.index])
        report.typoMS = milliseconds(typo.duration(to: .now))

        // One sent message at a time (each commit reseals the manifest).
        var commits: [Double] = []
        for n in 0..<20 {
            let item = SearchItem.message(eventID: UUID(), conversationID: UUID(), paperID: nil,
                                          text: "One more question \(n) about the softmax temperature?", byReader: true, date: Date())
            let started = ContinuousClock.now
            try await index.commit([(item, item.contentFingerprint)])
            commits.append(milliseconds(started.duration(to: .now)))
        }
        report.commitMedianMS = median(commits); report.commitP95MS = p95(commits)
        await index.close()
        return report
    }

    // MARK: Corpus

    /// The profile's items, the same on every run.
    public static func corpus(_ profile: Profile) -> [SearchItem] {
        var random = SplitMix(seed: 0x6C0BA1)
        let words = Words(random: &random)
        var items: [SearchItem] = []
        items.reserveCapacity(profile.items)
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        func date(_ random: inout SplitMix) -> Date { now.addingTimeInterval(-Double(random.next(400)) * 86_400 - Double(random.next(86_400))) }
        let papers = (0..<max(1, profile.chats / 4)).map { _ in UUID() }
        var conversations: [UUID] = []
        for _ in 0..<profile.chats {
            let id = UUID()
            conversations.append(id)
            let paper = random.next(3) == 0 ? nil : papers[random.next(papers.count)]
            items.append(.conversation(id: id, title: words.title(&random), paperID: paper, paperTitle: paper.map { _ in words.title(&random) },
                                       passage: random.next(4) == 0 ? words.sentence(&random) : nil, date: date(&random)))
        }
        for n in 0..<profile.messages {
            let conversation = conversations[n % max(1, conversations.count)]
            let question = n % 2 == 0
            let text = question ? words.question(&random) : words.answer(&random)
            items.append(.message(eventID: UUID(), conversationID: conversation, paperID: nil, text: text, byReader: question, date: date(&random)))
        }
        for n in 0..<profile.explanations {
            let subject = ExplanationSubject(paperID: papers[random.next(papers.count)], paperTitle: words.title(&random), manifestSHA256: "m",
                                             itemID: "eq\(n)", label: "Equation (\(1 + random.next(40)))", action: "equation", savedAt: date(&random))
            let symbols = (0..<(2 + random.next(5))).map { _ in
                EquationSymbols.Symbol(symbol: words.greek(&random), latex: words.latexSymbol(&random), meaning: words.sentence(&random), source: .paper, paragraph: 3)
            }
            let answer = EquationAnswer(symbols: EquationSymbols(summary: words.sentence(&random) + " " + words.sentence(&random), symbols: symbols),
                                        text: words.answer(&random), subject: subject)
            if let item = SearchItem.equation(fileName: "e\(n)", answer: answer) { items.append(item) }
        }
        let collections = (0..<max(1, profile.collections)).map { _ in UUID() }
        for id in collections.prefix(profile.collections) { items.append(.collection(id: id, name: words.title(&random), date: date(&random))) }
        for n in 0..<profile.snippets {
            let record = NoteEntryRecord.benchQuote(id: UUID(), note: collections[n % collections.count], quote: words.paragraph(&random),
                                                    comment: random.next(2) == 0 ? words.sentence(&random) : "", title: words.title(&random))
            items.append(.snippet(record, collection: "Collection \(n % collections.count)", paperID: papers[random.next(papers.count)],
                                  extra: [], recognised: nil, date: date(&random)))
        }
        for _ in 0..<profile.diagrams {
            let source = "flowchart LR\n  A[\(words.phrase(&random))] --> B(\(words.phrase(&random)))\n  B -->|\(words.phrase(&random))| C{\(words.phrase(&random))}"
            if let diagram = ChatDiagram(title: words.title(&random), source: source, messageID: nil) {
                items.append(.diagram(id: UUID(), diagram: diagram, conversationID: conversations.first, paperID: nil, date: date(&random)))
            }
        }
        return items
    }

    /// A deterministic generator (SplitMix64).
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func next(_ bound: Int) -> Int { bound <= 1 ? 0 : Int(next() % UInt64(bound)) }
    }

    /// The corpus's words: function words (Zipf), ML vocabulary, rare made-up words, equations.
    struct Words {
        static let function = ["the", "of", "and", "to", "a", "in", "is", "that", "for", "we", "this", "with", "as", "on", "by", "it",
                               "are", "be", "an", "from", "which", "can", "at", "not", "or", "its", "their", "each", "our", "more",
                               "than", "when", "how", "why", "what", "so", "also", "into", "only", "both", "then", "but", "these"]
        static let ml = ["attention", "softmax", "gradient", "transformer", "transformers", "diffusion", "policy", "reward", "model",
                         "models", "learning", "rate", "loss", "training", "token", "tokens", "embedding", "layer", "layers",
                         "optimization", "optimizer", "momentum", "variance", "divergence", "KL", "entropy", "sampling",
                         "temperature", "probability", "distribution", "likelihood", "posterior", "prior", "inference",
                         "parameters", "weights", "matrix", "orthogonal", "Newton-Schulz", "self-attention", "cross-attention",
                         "in-context", "state-space", "Mamba", "recurrence", "selective", "scan", "convolution", "residual",
                         "normalization", "LayerNorm", "dropout", "regularization", "preference", "DPO", "RLHF", "PPO",
                         "clipping", "advantage", "value", "critic", "actor", "on-policy", "off-policy", "GPT-4o",
                         "Llama-3.1-8B", "2106.09685", "1706.03762", "benchmark", "evaluation", "accuracy", "perplexity",
                         "scaling", "compute", "dataset", "pretraining", "fine-tuning", "LoRA", "adapter", "rank",
                         "low-rank", "quantization", "precision", "kernel", "GPU", "throughput", "latency", "batch",
                         "sequence", "length", "context", "window", "retrieval", "memory", "cache", "key", "query",
                         "queries", "keys", "values", "head", "heads", "multi-head", "positional", "encoding", "rotary",
                         "denoising", "score", "matching", "noise", "schedule", "sampler", "decoder", "encoder",
                         "autoregressive", "contrastive", "representation", "features", "linear", "nonlinear", "activation",
                         "ReLU", "GELU", "SwiGLU", "Adam", "AdamW", "Muon", "warmup", "decay", "cosine", "objective",
                         "constraint", "bound", "theorem", "proof", "lemma", "estimator", "unbiased", "variance-reduced",
                         "Monte-Carlo", "Markov", "stationary", "trajectory", "rollout", "environment", "agent", "agents"]
        static let equations = [#"\mathrm{softmax}(QK^\top/\sqrt{d_k})V"#,
                                #"\mathcal{L}_{\mathrm{DPO}} = -\log \sigma\left(\beta \log \frac{\pi_\theta(y_w|x)}{\pi_{\mathrm{ref}}(y_w|x)} - \beta \log \frac{\pi_\theta(y_l|x)}{\pi_{\mathrm{ref}}(y_l|x)}\right)"#,
                                #"h_t = \bar{A} h_{t-1} + \bar{B} x_t"#,
                                #"L^{CLIP}(\theta) = \mathbb{E}_t[\min(r_t(\theta)\hat{A}_t, \mathrm{clip}(r_t(\theta), 1-\epsilon, 1+\epsilon)\hat{A}_t)]"#,
                                #"X_{k+1} = \frac{3}{2}X_k - \frac{1}{2}X_k X_k^\top X_k"#,
                                #"\nabla_\theta J(\theta) = \mathbb{E}[\nabla_\theta \log \pi_\theta(a|s) A(s,a)]"#,
                                #"D_{\mathrm{KL}}(p \| q) = \sum_x p(x) \log \frac{p(x)}{q(x)}"#,
                                #"x_t = \sqrt{\bar{\alpha}_t} x_0 + \sqrt{1-\bar{\alpha}_t}\epsilon"#,
                                "α̅ₜ = ∏ₛ (1 − βₛ)", "∇θ L = ∂L/∂θ"]
        static let greek = ["α", "β", "γ", "θ", "λ", "σ", "ε", "π", "μ", "η"]
        static let latex = [#"\alpha"#, #"\beta"#, #"\theta"#, #"\lambda"#, #"\sigma"#, #"\epsilon"#, #"\pi_\theta"#, #"\mu"#, #"\eta"#, #"\nabla"#]
        let rare: [String]
        init(random: inout SplitMix) {
            rare = (0..<14_000).map { n in
                let letters = Array("abcdefghiklmnoprstuvwyz")
                return (0..<(5 + n % 6)).map { _ in String(letters[random.next(letters.count)]) }.joined()
            }
        }
        /// Function words half the time (the first ones most), ML words a third, rare words the rest.
        func word(_ random: inout SplitMix) -> String {
            let roll = random.next(100)
            if roll < 50 { return Self.function[min(random.next(Self.function.count), random.next(Self.function.count))] }
            if roll < 85 { return Self.ml[min(random.next(Self.ml.count), random.next(Self.ml.count))] }
            if roll < 87 { return Self.greek[random.next(Self.greek.count)] }
            return rare[min(random.next(rare.count), random.next(rare.count))]
        }
        func phrase(_ random: inout SplitMix) -> String { (0..<(2 + random.next(3))).map { _ in word(&random) }.joined(separator: " ") }
        func sentence(_ random: inout SplitMix) -> String {
            var text = (0..<(8 + random.next(18))).map { _ in word(&random) }.joined(separator: " ")
            text = text.prefix(1).uppercased() + text.dropFirst()
            return text + "."
        }
        func title(_ random: inout SplitMix) -> String {
            (0..<(3 + random.next(5))).map { _ in Self.ml[random.next(Self.ml.count)] }.joined(separator: " ").capitalized
        }
        func paragraph(_ random: inout SplitMix) -> String { (0..<(3 + random.next(4))).map { _ in sentence(&random) }.joined(separator: " ") }
        func question(_ random: inout SplitMix) -> String {
            var text = sentence(&random)
            text.removeLast()
            return random.next(3) == 0 ? text + " \\(" + Self.latex[random.next(Self.latex.count)] + "\\)?" : text + "?"
        }
        func answer(_ random: inout SplitMix) -> String {
            var paragraphs = (0..<(2 + random.next(3))).map { _ in paragraph(&random) }
            if random.next(3) == 0 { paragraphs.insert("$$" + Self.equations[random.next(Self.equations.count)] + "$$", at: 1) }
            if random.next(4) == 0 { paragraphs[0] = "**Short answer:** " + paragraphs[0] + " [¶\(1 + random.next(40))]" }
            return paragraphs.joined(separator: "\n\n")
        }
        func greek(_ random: inout SplitMix) -> String { Self.greek[random.next(Self.greek.count)] }
        func latexSymbol(_ random: inout SplitMix) -> String { Self.latex[random.next(Self.latex.count)] }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
    static func seconds(_ duration: Duration) -> Double { milliseconds(duration) / 1_000 }
    static func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
    static func p95(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[min(values.count - 1, values.count * 95 / 100)] }
}

extension NoteEntryRecord {
    /// A quotation snippet for the benchmark corpus.
    static func benchQuote(id: UUID, note: UUID, quote: String, comment: String, title: String) -> NoteEntryRecord {
        NoteEntryRecord(entryID: id, noteID: note, kind: .quote, counter: 1, capturedAt: 0, offsetMinutes: 0, comment: comment,
                        source: NoteSource(kind: .document, title: title, authors: [], sourceID: nil), anchor: nil, quote: quote, media: nil)
    }
}
