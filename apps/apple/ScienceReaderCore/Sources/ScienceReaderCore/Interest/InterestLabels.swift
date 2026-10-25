import Foundation

// Readable topic labels and per-paper keywords until the map is named (November): the step-2 term layer
// (tools/interest-eval/terms.py) on the device, against the pool's public term statistics.
//
// - A topic's label: weighted log-odds with an informative Dirichlet prior (Monroe et al. 2008) of the phrases its
//   papers use against the pool, then re-ranked by closeness to the topic, behind the concept filter; its 1–3 best
//   terms, title-cased, never a generic area ("Machine learning").
// - A paper's keywords: sublinear TF-IDF over its text (title twice, abstract and, when the paper is read on this device,
//   its full text), IDF from the pool, n-grams × 1.25, the top 40 re-ranked by closeness to the paper (KeyBERT-style).
//
// "Closeness" needs a vector per phrase. Phrase embeddings aren't shipped (≈ 23 MB) and the device has no gte-small, so
// a phrase stands for the weighted centroid of the reader's papers that use it (the document side of the server's
// conceptness): a phrase used only by a topic's papers sits at the topic's centre, one spread over the library sits
// near the library's. Labels computed here are identical on every device given the same papers and statistics.

/// Which statistics phrases a library paper's metadata uses (title twice and abstract), and the reverse index.
public struct InterestTextIndex: Sendable, Equatable {
    public private(set) var phrasesByPaper: [String: Set<Int>] = [:]
    public private(set) var papersByPhrase: [Int: Set<String>] = [:]
    public init() {}

    public mutating func set(_ key: String, phrases: Set<Int>) {
        let key = InterestPool.key(key)
        remove(key)
        phrasesByPaper[key] = phrases
        for t in phrases { papersByPhrase[t, default: []].insert(key) }
    }

    public mutating func set(_ key: String, title: String, abstract: String, terms: InterestTerms) {
        set(key, phrases: Set(InterestPhrases.counts(InterestPhrases.documentText(title: title, abstract: abstract), terms: terms).keys))
    }

    public mutating func remove(_ key: String) {
        let key = InterestPool.key(key)
        guard let old = phrasesByPaper.removeValue(forKey: key) else { return }
        for t in old {
            papersByPhrase[t]?.remove(key)
            if papersByPhrase[t]?.isEmpty == true { papersByPhrase[t] = nil }
        }
    }

    /// The phrase's stand-in vector: the weighted centroid of the reader's papers using it (unit length).
    func context(_ phrase: Int, state: InterestState) -> [Float]? {
        guard let papers = papersByPhrase[phrase] else { return nil }
        return state.centroid(of: papers.sorted())
    }
}

public enum InterestLabels {
    /// Never a label or keyword on its own: areas and the broadest subjects (owner, 2026-10-24: "not things like Machine
    /// Learning, not things like regression"; "attention" or "transformers" for a sparse-attention reader isn't helpful).
    /// The vocabulary's areas, `TagVocabulary.generic`, Related papers' generic topics and the broadest single subjects.
    /// tools/interest-eval/device_fixtures.py holds the same list (a test compares them).
    public static let generic: Set<String> = Set(TagVocabulary.tags.filter { $0.kind == .area }.map { $0.name.lowercased() })
        .union(TagVocabulary.generic).union(RelatedPapers.genericTopics)
        .union(["artificial intelligence", "ai", "ml", "neural", "deep neural networks", "large language", "language llms",
                "attention", "regression", "learning", "training", "inference", "algorithm", "algorithms", "network", "networks",
                "statistics", "classification", "prediction", "accuracy", "generalization", "representation", "representations",
                "llm-based", "ai systems"])

    public static func isGeneric(_ phrase: String) -> Bool { generic.contains(phrase.lowercased()) }

    // MARK: Topic labels

    /// A phrase the server's own per-paper terms chose (KeyBERT with real phrase embeddings) gains this much.
    public static let endorsedBonus = 1.0
    /// A topic label prefers a two- or three-word phrase over a single common word ("safe", "learned"): measured on the
    /// owner's library, single words won half the labels without it.
    public static let phraseBonus = 0.5
    /// A single word in more than this share of the pool's papers ("memory", "search", "decision") doesn't label a topic.
    public static let commonWordShare = 0.02

    /// The topic's best phrases (statistics indices), best first, at most `k`. `endorsed`: the server's terms for the
    /// topic's papers (lowercase); `excluded`: phrases that already label a larger topic.
    public static func topicTerms(papers: [String], state: InterestState, text: InterestTextIndex, terms: InterestTerms, k: Int = 3,
                                  endorsed: Set<String> = [], excluded: Set<String> = []) -> [Int] {
        let keys = papers.map(InterestPool.key).filter { text.phrasesByPaper[$0] != nil && state.contains($0) }.sorted()
        guard !keys.isEmpty else { return [] }
        // Counts: yu = Σ weight of the topic's papers using the phrase, cnt = how many use it.
        var yu: [Int: Double] = [:], cnt: [Int: Int] = [:]
        var nu = 0.0, used = 0
        for key in keys {
            let w = Double(state.weightUnits(of: key) ?? 0) / InterestState.weightScale
            let phrases = text.phrasesByPaper[key] ?? []
            nu += w * Double(phrases.count); used += phrases.count
            for t in phrases { yu[t, default: 0] += w; cnt[t, default: 0] += 1 }
        }
        let nb = Double(max(0, terms.totalDF - used))
        let a0 = 1000.0
        func z(_ t: Int) -> Double {
            let u = yu[t] ?? 0, b = Double(max(0, terms.documentFrequency(t) - (cnt[t] ?? 0)))
            let a = a0 * (u + b) / max(nu + nb, 1e-9)
            let delta = log((u + a) / (nu + a0 - u - a)) - log((b + a) / (nb + a0 - b - a))
            return delta / (1 / (u + a) + 1 / (b + a)).squareRoot()
        }
        let need = keys.count <= 4 ? 2 : max(2, Int((0.4 * Double(keys.count)).rounded(.toNearestOrEven)))
        var candidates = cnt.filter { $0.value >= need }.map(\.key)
        if candidates.isEmpty { candidates = Array(cnt.keys) }
        let scored = candidates.map { ($0, z($0)) }.sorted { $0.1 == $1.1 ? terms.phrase($0.0) < terms.phrase($1.0) : $0.1 > $1.1 }.prefix(60)
        guard let centre = state.centroid(of: keys) else { return [] }
        let close = scored.map { t, _ in text.context(t, state: state).map { InterestState.dot($0, centre) } ?? 0 }
        let mean = close.reduce(0, +) / Double(max(1, close.count))
        let top = max(scored.first?.1 ?? 0, 1e-6)
        let order = zip(scored, close).map { item, c -> (Int, Double) in
            let phrase = terms.phrase(item.0)
            return (item.0, item.1 / top + 2 * (c - mean) + (endorsed.contains(phrase) ? endorsedBonus : 0) + (phrase.contains(" ") ? phraseBonus : 0))
        }
            .sorted { $0.1 == $1.1 ? terms.phrase($0.0) < terms.phrase($1.0) : $0.1 > $1.1 }.map(\.0)
        return pick(order, terms: terms, k: k, excluded: excluded, common: commonWordShare * Double(terms.corpusPapers), endorsed: endorsed)
    }

    /// Best-first with the concept filter, the generic list and de-duplication (a phrase inside a kept one, or sharing
    /// a word of four letters or more with it: "fine-tuning lora" after "parameter-efficient fine-tuning").
    static func pick(_ order: [Int], terms: InterestTerms, k: Int, excluded: Set<String> = [], common: Double? = nil,
                     endorsed: Set<String> = []) -> [Int] {
        var picked: [Int] = []
        for t in order.prefix(200) {
            guard terms.isConcept(t) else { continue }
            let phrase = terms.phrase(t)
            guard !isGeneric(phrase), !excluded.contains(phrase) else { continue }
            if let common, !phrase.contains(" "), Double(terms.documentFrequency(t)) > common { continue }
            let words = Set(phrase.split(separator: " ").map(String.init).filter { $0.count >= 4 })
            if picked.contains(where: { p in
                let other = terms.phrase(p)
                return other.contains(phrase) || phrase.contains(other)
                    || !words.isDisjoint(with: other.split(separator: " ").map(String.init))
            }) { continue }
            picked.append(t)
            if picked.count == k { break }
        }
        return picked
    }

    // MARK: Per-paper keywords

    /// A paper's keywords (statistics indices), best first. `counts`: occurrences of each phrase in the paper's text
    /// (`InterestPhrases.counts` over the title twice, the abstract and, when there is one, the full text).
    public static func paperTerms(_ key: String, counts: [Int: Int], state: InterestState, text: InterestTextIndex,
                                  terms: InterestTerms, k: Int = 5, endorsed: Set<String> = []) -> [Int] {
        guard !counts.isEmpty else { return [] }
        let scored = counts.map { t, c -> (Int, Double) in
            let tfidf = (1 + log(Double(c))) * terms.idf(t) * (terms.phrase(t).contains(" ") ? 1.25 : 1)
            return (t, tfidf)
        }.sorted { $0.1 == $1.1 ? terms.phrase($0.0) < terms.phrase($1.0) : $0.1 > $1.1 }.prefix(40)
        let top = max(scored.first?.1 ?? 0, 1e-9)
        var order: [(Int, Double)]
        if let vector = state.vector(of: key) {
            // Closeness to the paper: a phrase only this paper uses sits at the paper; one the library shares, at the
            // centre of the papers sharing it. Phrases the library's metadata doesn't use count as average.
            let close = scored.map { t, _ in text.context(t, state: state).map { InterestState.dot($0, vector) } }
            let known = close.compactMap { $0 }
            let mean = known.isEmpty ? 0 : known.reduce(0, +) / Double(known.count)
            order = zip(scored, close).map { ($0.0, $0.1 / top + 2 * (($1 ?? mean) - mean)) }
        } else {
            order = scored.map { ($0.0, $0.1 / top) }
        }
        order = order.map { ($0.0, $0.1 + (endorsed.contains(terms.phrase($0.0)) ? endorsedBonus : 0)) }
        order.sort { $0.1 == $1.1 ? terms.phrase($0.0) < terms.phrase($1.0) : $0.1 > $1.1 }
        return pick(order.map(\.0), terms: terms, k: k)
    }

    // MARK: Display

    /// Words written their usual way when a label is title-cased.
    public static let acronyms: [String: String] = [
        "ai": "AI", "ml": "ML", "llm": "LLM", "llms": "LLMs", "rl": "RL", "rlhf": "RLHF", "kv": "KV", "rag": "RAG",
        "moe": "MoE", "lora": "LoRA", "loras": "LoRAs", "asr": "ASR", "tts": "TTS", "cot": "CoT", "vlm": "VLM", "vlms": "VLMs",
        "mllm": "MLLM", "mllms": "MLLMs", "gpt": "GPT", "cnn": "CNN", "cnns": "CNNs", "gnn": "GNN", "gnns": "GNNs",
        "nlp": "NLP", "sae": "SAE", "saes": "SAEs", "dpo": "DPO", "ppo": "PPO", "grpo": "GRPO", "gpu": "GPU", "gpus": "GPUs",
        "cua": "CUA", "cuas": "CUAs", "sql": "SQL", "api": "API", "apis": "APIs", "3d": "3D", "2d": "2D", "ood": "OOD",
        "vae": "VAE", "gan": "GAN", "gans": "GANs", "mcmc": "MCMC", "sgd": "SGD", "nerf": "NeRF", "ssm": "SSM", "ssms": "SSMs",
        "vqa": "VQA", "ocr": "OCR", "pde": "PDE", "pdes": "PDEs", "ode": "ODE", "odes": "ODEs", "iot": "IoT", "qa": "QA",
        "mtp": "MTP", "cli": "CLI", "cad": "CAD", "ui": "UI", "gui": "GUI", "llava": "LLaVA", "bert": "BERT", "vit": "ViT",
        "clip": "CLIP", "mcp": "MCP", "e2e": "E2E", "rgb": "RGB", "lidar": "LiDAR", "slam": "SLAM", "mpc": "MPC"]

    /// "parameter-efficient fine-tuning" → "Parameter-Efficient Fine-Tuning"; "kv cache" → "KV Cache".
    public static func titleCase(_ phrase: String) -> String {
        phrase.split(separator: " ").map { word in
            word.split(separator: "-", omittingEmptySubsequences: false).map { part -> String in
                let lower = part.lowercased()
                if let known = acronyms[lower] { return known }
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }.joined(separator: "-")
        }.joined(separator: " ")
    }

    /// Sentence case for a paper's keyword chips, like the vocabulary's ("Parameter-efficient fine-tuning", "KV cache").
    public static func sentenceCase(_ phrase: String) -> String {
        var first = true
        return phrase.split(separator: " ").map { word in
            word.split(separator: "-", omittingEmptySubsequences: false).map { part -> String in
                let lower = part.lowercased()
                defer { first = false }
                if let known = acronyms[lower] { return known }
                return first ? lower.prefix(1).uppercased() + lower.dropFirst() : lower
            }.joined(separator: "-")
        }.joined(separator: " ")
    }

    /// A topic's label from its best terms: up to three, joined by ", ", stopping before it passes `maxLength`.
    public static func label(_ phrases: [String], maxLength: Int = 44) -> String? {
        var out: [String] = []
        for phrase in phrases.prefix(3) {
            let next = (out + [titleCase(phrase)]).joined(separator: ", ")
            if !out.isEmpty && next.count > maxLength { break }
            out.append(titleCase(phrase))
        }
        return out.isEmpty ? nil : out.joined(separator: ", ")
    }
}
