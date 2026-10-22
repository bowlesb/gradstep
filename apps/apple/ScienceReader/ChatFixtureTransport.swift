#if DEBUG && FIXTURE_HOST
import Foundation
import ScienceReaderCore

/// Synthetic answers for UI journeys (`--chat-fixture`). Compiled out of
/// physical-device and release builds; it never opens a network connection.
/// Modes: `--chat-fixture-mode=answer|slow|interrupt|insufficient_credits|refusal|diagram|broken_diagram|sources|research|throttled|overloaded|stall`.
/// `broken_diagram`: a diagram Mermaid can't parse, and a correction (`diagram_fix`) that still can't be.
/// `research`: a table, papers named by arXiv ID and DOI, and a Sources list.
/// `figure_parts`: an answer about the sample's Figure 1 that marks where its two parts go, and the parts.
/// `equation`: plain answers; the equation view's requests (actions `equation`, `equation_background`) are answered in
/// every mode — symbols as the live server sends them, background as a short cited text.
/// `figure_walkthrough`: plain answers; the figure view's requests (actions `figure`, `figure_simpler`) are answered in
/// every mode — a three-part walkthrough of the sample's Figure 1 with one crop and `[¶N]` links, streamed as the server
/// streams it (progress, summary, each part, then the final `figure`; `--figure-fixture-old-server` sends only the final
/// one, `--figure-fixture-step-ms=<n>` slows it), and a part more simply.
/// `--chat-fixture-consented` pre-accepts the in-memory cloud consent.
/// Answers report their model and profile and, when asked, a topic title (server 2026-10-08);
/// `--chat-fixture-no-profiles` behaves like a server without them.
struct ChatFixtureTransport: ChatTransport {
    enum Mode: String, Sendable {
        case answer, slow, interrupt, insufficientCredits = "insufficient_credits", refusal, diagram, brokenDiagram = "broken_diagram", sources, research
        case figureParts = "figure_parts", equation, figureWalkthrough = "figure_walkthrough"
        /// Faults (docs/architecture/RESILIENCE.md): the server is rate limiting (`rate_limited` before any text), the
        /// AI provider is overloaded (`provider_unavailable` before any text), or the stream goes silent (no events at all).
        case throttled, overloaded, stall, providerBilling = "provider_billing"
    }
    let mode: Mode

    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--chat-fixture") }

    static func launchTransport() -> ChatFixtureTransport {
        let value = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--chat-fixture-mode=") }
            .map { String($0.dropFirst("--chat-fixture-mode=".count)) }
        return ChatFixtureTransport(mode: value.flatMap(Mode.init(rawValue:)) ?? .answer)
    }

    static func launchConsentStore() -> any AuthenticationCredentialStore {
        MemoryCredentialStore(acceptsConsent: ProcessInfo.processInfo.arguments.contains("--chat-fixture-consented"))
    }

    static let figurePartsAnswer = """
    Figure 1 has two halves, read left to right.

    [[part 1]]
    The left half sets up the question the figure answers.

    [[part 2]]
    The right half shows the result.

    This is a synthetic fixture answer; no AI request was made.
    """

    static let equationSymbols = EquationSymbols(summary: "The square of x: x multiplied by itself, the paper's first numbered equation.", symbols: [
        .init(symbol: "x", latex: "x", meaning: "The quantity being squared, introduced in the introduction.", source: .paper, paragraph: 4),
        .init(symbol: "²", latex: "^2", meaning: "The exponent 2: the value is multiplied by itself.", source: .general)])
    static let equationBackground = """
    Squaring appears wherever a size must be positive whatever its sign, as in a squared error [¶4].

    - It grows faster than the value itself, so large values dominate.

    This is a synthetic fixture answer; no AI request was made.
    """

    static let figureWalkthrough = FigureWalkthrough(summary: "Figure 1 is a small test image: two halves, read left to right, that the introduction mentions [¶4].", sections: [
        .init(label: "Left half", title: "Where the figure starts", text: "The left half is the starting point the introduction names [¶4]. Read it first.", paragraphs: [4],
              box: .init(x: 0, y: 0, w: 0.5, h: 1)),
        .init(label: "Right half", title: "What it shows", text: "The right half is the result the caption sums up [¶6].", paragraphs: [6]),
        .init(label: "", title: "Reading it as a whole", text: "Together the halves make the figure’s single point. This is a synthetic fixture answer; no AI request was made.")])
    /// `--figure-fixture-panels`: Figure 1 is a real two-plot figure, and the walkthrough's boxes are written as models
    /// often write them, on the plotting areas, clipping titles, tick labels and axis titles (the crops are completed on
    /// the device: FigureCropCompletion).
    static var figurePanels: Bool { ProcessInfo.processInfo.arguments.contains("--figure-fixture-panels") }
    /// With `--figure-fixture-loose` too: the right box is deliberately imprecise, starting inside the left plot as a model
    /// sometimes writes it (FIGURE_VIEW.md "Parts as viewports": framed loosely and outlined).
    static var figureLoose: Bool { ProcessInfo.processInfo.arguments.contains("--figure-fixture-loose") }
    static var rightBox: FigureWalkthrough.Box { figureLoose ? .init(x: 0.45, y: 0.1, w: 0.54, h: 0.8) : .init(x: 0.55, y: 0.07, w: 0.44, h: 0.79) }
    static var panelsWalkthrough: FigureWalkthrough { FigureWalkthrough(summary: "Figure 1 sets two results side by side: reward against divergence on the left, win rate against sampling temperature on the right [¶4].", sections: [
        .init(label: "Left plot", title: "Reward against KL divergence", text: "Each point is one training run; higher and further left is better [¶4].", paragraphs: [4],
              box: .init(x: 0.06, y: 0.07, w: 0.42, h: 0.79)),
        .init(label: "Right plot", title: "Win rate against temperature", text: "Each line is one method; the dashed line is an even match [¶6].", paragraphs: [6],
              box: rightBox),
        .init(label: "", title: "Reading it as a whole", text: "Together the plots make the figure’s single point. This is a synthetic fixture answer; no AI request was made.")]) }
    /// `--figure-fixture-bundle=<dir>`: the study paper is a real compiled arXiv paper read from this Mac.
    static var figureBundle: URL? {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--figure-fixture-bundle=") }.map { URL(fileURLWithPath: String($0.dropFirst("--figure-fixture-bundle=".count))) }
    }
    /// `--figure-fixture-subfigures`: the walkthrough of a real figure of three sub-captioned images (2610.22353v1 Figure 3),
    /// written as a model writes it once it is told the structure (FIGURE_VIEW.md "Structure first"): a concept card, then
    /// (a), (b) with a box on its band and (c); all three are the figure's own sub-figures, exact. With
    /// `--figure-fixture-grouped`: (a) and (b) as one boxed part and (c): two parts for three sub-figures, so the group shows
    /// the whole figure, outlined, while (c) stays exact.
    static var figureSubfigures: Bool { ProcessInfo.processInfo.arguments.contains("--figure-fixture-subfigures") }
    static var figureGrouped: Bool { ProcessInfo.processInfo.arguments.contains("--figure-fixture-grouped") }
    static var subfiguresWalkthrough: FigureWalkthrough {
        let concept = FigureWalkthrough.Section(label: "", title: "How to read the three plots",
            text: "Each plot follows training on the same model with and without shared experts. This is a synthetic fixture answer; no AI request was made.", kind: .concept)
        let c = FigureWalkthrough.Section(label: "(c)", title: "Router variance", text: "The router's own variance stays lower with shared experts [¶4].", paragraphs: [4])
        if figureGrouped {
            return FigureWalkthrough(summary: "Figure 3 shows that shared experts make routing less exploratory [¶4].", sections: [concept,
                .init(label: "(a) and (b)", title: "Criticality and expert variance", text: "Both top plots fall with shared experts [¶4].", paragraphs: [4],
                      box: .init(x: 0, y: 0, w: 1, h: 0.66)), c])
        }
        return FigureWalkthrough(summary: "Figure 3 shows that shared experts make routing less exploratory: three measures, one per plot [¶4].", sections: [concept,
            .init(label: "(a)", title: "Routing criticality", text: "Routing criticality is lower with shared experts throughout training [¶4].", paragraphs: [4]),
            .init(label: "(b)", title: "Expert variance", text: "The variance across experts shrinks once shared experts carry the common load [¶4].", paragraphs: [4],
                  box: .init(x: 0.01, y: 0.34, w: 0.98, h: 0.32)),
            c])
    }
    /// `--figure-fixture-old-server`: the walkthrough as a server before 2026-10-22 sends it, only the final `figure`.
    static var figureOldServer: Bool { ProcessInfo.processInfo.arguments.contains("--figure-fixture-old-server") }
    /// `--figure-fixture-step-ms=<n>`: the pause between the streamed walkthrough's steps (default 450 ms; journeys that
    /// watch it arrive use a slower stream).
    static var figureStep: Duration {
        let value = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--figure-fixture-step-ms=") }
            .flatMap { Int($0.dropFirst("--figure-fixture-step-ms=".count)) }
        return .milliseconds(min(10_000, max(50, value ?? 450)))
    }

    /// The walkthrough streamed as the server of 2026-10-22 streams it: `reading`, then `writing` with the characters of
    /// its JSON so far and the announced number of parts, the summary, and each part in order; the caller sends the final
    /// `figure` and `done`.
    static func streamWalkthrough(_ walkthrough: FigureWalkthrough, _ continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation) async throws {
        let step = figureStep
        func size<T: Encodable>(_ value: T) -> Int { (try? JSONEncoder().encode(value).count) ?? 0 }
        try await Task.sleep(for: .milliseconds(300))
        continuation.yield(.figureProgress(.init(stage: .reading)))
        try await Task.sleep(for: step)
        var written = 30 + size(walkthrough.summary)
        let parts = walkthrough.sections.count
        continuation.yield(.figureProgress(.init(stage: .writing, characters: written / 2, parts: parts)))
        try await Task.sleep(for: step)
        continuation.yield(.figureProgress(.init(stage: .writing, characters: written, parts: parts)))
        continuation.yield(.figureSummary(walkthrough.summary))
        for (index, section) in walkthrough.sections.enumerated() {
            let length = size(section)
            try await Task.sleep(for: step)
            continuation.yield(.figureProgress(.init(stage: .writing, characters: written + length / 2, parts: parts)))
            try await Task.sleep(for: step)
            written += length
            continuation.yield(.figureProgress(.init(stage: .writing, characters: written, parts: parts)))
            continuation.yield(.figureSection(index: index, section: section))
        }
    }

    static let figureSimpler = """
    Start with the left half: it is only the starting point, nothing more [¶4].

    This is a synthetic fixture answer; no AI request was made.
    """

    static let answer = """
    Scaling by \\(1/\\sqrt{d_k}\\) keeps the dot products from growing with the key width, so the softmax stays in a range with useful gradients.

    - Without it, large logits push the softmax toward one-hot outputs.
    - The paper motivates this in Section 3.2.1:

    \\[ \\mathrm{Attention}(Q, K, V) = \\mathrm{softmax}\\left(\\frac{QK^\\top}{\\sqrt{d_k}}\\right) V \\]

    This is a synthetic fixture answer; no AI request was made.
    """

    func chatStream(_ request: ChatGenerationRequest, accountID: UUID) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let mode = self.mode
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if mode == .providerBilling && request.profile.model == .sonnet {
                        continuation.yield(.failure(code: "model_unavailable", credits: 0))
                        continuation.finish(); return
                    }
                    if request.action == .study {
                        // Study (2026-10-14): a calibrating question first, then a judgement, a taught passage and one
                        // bold question; the map grows as the live server's would.
                        try await Task.sleep(for: .milliseconds(300))
                        let first = request.turns.count == 1
                        for piece in Self.pieces(of: first ? Self.studyFirst : Self.studyNext, size: 14) {
                            continuation.yield(.delta(piece)); try await Task.sleep(for: .milliseconds(30))
                        }
                        continuation.yield(.study(first ? Self.studyMapFirst : Self.studyMapNext))
                        continuation.yield(.done(stopReason: "end_turn", credits: 4, model: "claude-sonnet-5-5", profile: request.profile.id))
                        continuation.finish(); return
                    }
                    if request.action == .equation {
                        try await Task.sleep(for: .milliseconds(400))
                        continuation.yield(.equation(Self.equationSymbols))
                        continuation.yield(.done(stopReason: "end_turn", credits: 3, model: ChatProfileText.apiModel(for: request.profile.model), profile: request.profile.id))
                        continuation.finish(); return
                    }
                    if request.action == .equationBackground {
                        try await Task.sleep(for: .milliseconds(300))
                        for piece in Self.pieces(of: Self.equationBackground, size: 16) {
                            continuation.yield(.delta(piece)); try await Task.sleep(for: .milliseconds(25))
                        }
                        continuation.yield(.done(stopReason: "end_turn", credits: 2, model: ChatProfileText.apiModel(for: request.profile.model), profile: request.profile.id))
                        continuation.finish(); return
                    }
                    if request.action == .figure {
                        let walkthrough = Self.figureSubfigures ? Self.subfiguresWalkthrough : Self.figurePanels ? Self.panelsWalkthrough : Self.figureWalkthrough
                        if Self.figureOldServer {
                            try await Task.sleep(for: Self.figureStep)
                        } else {
                            try await Self.streamWalkthrough(walkthrough, continuation)
                        }
                        continuation.yield(.figure(walkthrough))
                        continuation.yield(.done(stopReason: "end_turn", credits: 5, model: ChatProfileText.apiModel(for: request.profile.model), profile: request.profile.id))
                        continuation.finish(); return
                    }
                    if request.action == .figureSimpler {
                        try await Task.sleep(for: .milliseconds(300))
                        for piece in Self.pieces(of: Self.figureSimpler, size: 16) {
                            continuation.yield(.delta(piece)); try await Task.sleep(for: .milliseconds(25))
                        }
                        continuation.yield(.done(stopReason: "end_turn", credits: 3, model: ChatProfileText.apiModel(for: request.profile.model), profile: request.profile.id))
                        continuation.finish(); return
                    }
                    if request.action == .diagramFix {
                        try await Task.sleep(for: .milliseconds(1500))
                        continuation.yield(.diagram(title: "Scaled dot-product attention", source: Self.brokenDiagram))
                        continuation.yield(.done(stopReason: "end_turn", credits: 1, model: "claude-sonnet-5-5", profile: "diagram_fix"))
                        continuation.finish(); return
                    }
                    if mode == .figureParts {
                        try await Task.sleep(for: .milliseconds(300))
                        for piece in Self.pieces(of: Self.figurePartsAnswer, size: 14) {
                            continuation.yield(.delta(piece)); try await Task.sleep(for: .milliseconds(20))
                        }
                        if let figure = request.figures.first {
                            continuation.yield(.figureParts(ChatFigureParts(figure: figure.id, paragraph: figure.paragraph, title: "The figure, part by part", parts: [
                                .init(label: "Left half", box: [0, 0, 0.5, 1], note: "The left half of the figure."),
                                .init(label: "Right half", box: [0.5, 0, 1, 1], note: "The right half of the figure.")])))
                        }
                        continuation.yield(.done(stopReason: "end_turn", credits: 3, model: "claude-sonnet-5-5", profile: request.profile.id))
                        continuation.finish(); return
                    }
                    switch mode {
                    case .throttled:
                        try await Task.sleep(for: .milliseconds(200))
                        continuation.yield(.failure(code: "rate_limited"))
                    case .overloaded:
                        try await Task.sleep(for: .milliseconds(200))
                        continuation.yield(.failure(code: "provider_unavailable"))
                    case .stall:
                        // Nothing ever arrives: the client's idle deadline must end it.
                        try await Task.sleep(for: .seconds(3600))
                    case .insufficientCredits:
                        try await Task.sleep(for: .milliseconds(150))
                        continuation.yield(.failure(code: "insufficient_credits"))
                    case .refusal:
                        continuation.yield(.delta("I can’t"))
                        try await Task.sleep(for: .milliseconds(150))
                        continuation.yield(.failure(code: "refused"))
                    case .providerBilling, .answer, .slow, .interrupt, .diagram, .brokenDiagram, .sources, .research, .figureParts, .equation, .figureWalkthrough:
                        try await Task.sleep(for: .milliseconds(300))
                        // A numbered (device-prepared) paper gets a cited answer, as the live server writes one.
                        let cited = request.localContext != nil
                        let scrollAudit = ProcessInfo.processInfo.arguments.contains("--chat-scroll-audit=stream")
                        if scrollAudit, ProcessInfo.processInfo.arguments.contains("--chat-scroll-audit-growing-row") {
                            // Start with enough of the current answer to read above its still-growing tail.
                            continuation.yield(.delta("## Growing answer\n\n" + String(repeating: Self.answer + "\n\n", count: 8)))
                        }
                        let text = scrollAudit ? String(repeating: Self.answer + "\n\n", count: 20)
                            : mode == .research ? Self.research : mode == .sources ? Self.answer + Self.sources : cited ? Self.citedAnswer : Self.answer
                        let pieces = Self.pieces(of: text, size: 14)
                        let delay: Duration = scrollAudit ? .milliseconds(90) : mode == .slow ? .milliseconds(250) : .milliseconds(30)
                        // research: a search before the first text, and another one mid-answer (status events).
                        let secondSearch = mode == .research ? Self.pieces(of: Self.research.components(separatedBy: "Papers to read next")[0], size: 14).count : -1
                        if mode == .research { try await Self.search("direct preference optimization follow-ups", continuation) }
                        for (index, piece) in pieces.enumerated() {
                            if mode == .interrupt, index == pieces.count / 2 {
                                // As the server since 2026-10-16: an answer the provider cut short costs the reader nothing.
                                continuation.yield(.failure(code: "provider_unavailable", credits: 0))
                                break
                            }
                            if index == secondSearch { try await Self.search("IPO KTO comparison", continuation) }
                            continuation.yield(.delta(piece))
                            try await Task.sleep(for: delay)
                        }
                        if mode == .diagram { continuation.yield(.diagram(title: "Scaled dot-product attention", source: Self.diagram)) }
                        if mode == .brokenDiagram { continuation.yield(.diagram(title: "Scaled dot-product attention", source: Self.brokenDiagram)) }
                        if mode != .interrupt {
                            // A server from before profiles (`--chat-fixture-no-profiles`) sends neither a title nor labels.
                            if Self.serverHasProfiles {
                                if request.topicTitle { continuation.yield(.title(Self.topicTitle(for: request))) }
                                continuation.yield(.followUps(Self.followUps))
                                // The server records the effort it chose for an automatic request (low, in the fixture).
                                var answered = request.profile
                                if answered.effort == .auto { answered.effort = .low }
                                continuation.yield(.done(stopReason: "end_turn", credits: 2, model: ChatProfileText.apiModel(for: answered.model),
                                                         profile: answered.id))
                            } else {
                                continuation.yield(.done(stopReason: "end_turn", credits: 2))
                            }
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static let studyFirst = "Let’s start with the central idea. **In one sentence, what does attention compute?**"
    static let studyNext = "Partly right. Attention weights the values by how well each key matches the query [¶4]. **What does the softmax do to large scores?**"
    static let studyMapFirst = StudyMap(concepts: [StudyMap.Concept(id: "attention", label: "Attention", state: .learning, paragraphs: [4])],
                                        links: [], focus: "attention", journey: ["attention"], next: .calibrate)
    static let studyMapNext = StudyMap(concepts: [StudyMap.Concept(id: "attention", label: "Attention", state: .known, paragraphs: [4], note: "Knows the weighted sum"),
                                                  StudyMap.Concept(id: "softmax", label: "Softmax", state: .learning, paragraphs: [4])],
                                       links: [StudyMap.Link(from: "softmax", to: "attention", kind: .prerequisite)], focus: "softmax", journey: ["attention", "softmax"], next: .teach)

    /// Follow-up questions every complete fixture answer suggests (servers from 2026-10-14).
    static let followUps = ["Why does the softmax saturate without the scaling?", "How does this compare with additive attention?"]

    /// The fixture answer for a device-prepared paper: the same text citing its numbered blocks.
    static let citedAnswer = answer.replacingOccurrences(of: "The paper motivates this in Section 3.2.1:", with: "The paper motivates this in Section 3.2.1 [¶4]:")

    /// Web search answers end with sources in this form (see docs/CHAT.md).
    static let sources = """


    Sources:
    1. Attention Is All You Need — https://arxiv.org/abs/1706.03762
    2. https://example.org/attention-notes
    """

    /// A comparison table (inline math, bold, a pipe inside code), papers named by
    /// arXiv ID, arXiv link and DOI, and a source that appears only in Sources.
    static let research = """
    **Answer:** This synthetic fixture compares preference-optimization objectives; no AI request was made and the numbers are placeholders.

    | Method | Objective | Reward model | Win rate |
    |:---|:---|:---:|---:|
    | RLHF (PPO) | maximize \\(r_\\phi(x, y) - \\beta\\,\\mathrm{KL}\\) | Yes | 61% |
    | **DPO** | \\(-\\log \\sigma(\\beta \\Delta_\\theta)\\) | No | 64% |
    | IPO | \\((\\Delta_\\theta - \\tfrac{1}{2\\beta})^2\\) | No | 63% |
    | KTO | prospect value `v(x | y)` | No | 62% |

    DPO drops the separate reward model and the sampling loop, so it is cheaper to tune. **At $\\beta = 0$:** the policy ignores the reference model.

    Papers to read next:

    1. **Direct Preference Optimization: Your Language Model is Secretly a Reward Model** — Rafailov et al., 2023. arXiv:2305.18290
    2. [A General Theoretical Paradigm to Understand Learning from Human Preferences](https://arxiv.org/abs/2310.12036) — Azar et al., 2023.
    3. **Rank Analysis of Incomplete Block Designs** — Bradley and Terry, 1952: the pairwise preference model behind DPO. https://doi.org/10.2307/2334029

    Sources:
    1. Attention Is All You Need — https://arxiv.org/abs/1706.03762
    """

    static let diagram = """
    flowchart LR
      Q[Queries] --> S[Scaled dot products]
      K[Keys] --> S
      S --> M[Softmax]
      M --> O[Weighted values]
      V[Values] --> O
    """

    /// Unquoted parentheses and Unicode in labels: the mistakes the Mermaid label rules prevent.
    static let brokenDiagram = """
    flowchart TD
      Q[Queries (Q)] --> S[Q × Kᵀ / √d_k]
      S --> M[Softmax]
    """

    /// A server-side search as the stream reports it: searching (with the query), then reading.
    private static func search(_ query: String, _ continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation) async throws {
        continuation.yield(.status(ChatProgress(kind: .searching, query: query)))
        try await Task.sleep(for: .seconds(3))
        continuation.yield(.status(ChatProgress(kind: .reading)))
        try await Task.sleep(for: .milliseconds(1500))
    }

    func creditBalance(accountID: UUID) async throws -> CreditBalance { CreditBalance(available: 480, reserved: 0) }

    static var serverHasProfiles: Bool { !ProcessInfo.processInfo.arguments.contains("--chat-fixture-no-profiles") }

    func chatProfiles(accountID: UUID) async throws -> ChatProfileTable {
        guard Self.serverHasProfiles,
              let table = ChatProfileTable.decode(ProcessInfo.processInfo.arguments.contains("--chat-fixture-auto-profiles") ? Self.automaticProfiles
                                                  : Data(Self.profiles.utf8)) else { throw ChatTransportError.rejected("method_unavailable") }
        return table
    }

    /// `--chat-fixture-auto-profiles`: the table after the chat redesign (2026-10-16) — the same version and default, plus
    /// the automatic effort and DeepSeek, appended. An automatic profile's estimate is the usual effort's (brief and
    /// standard: low; detailed: medium) with the highest effort's maximum; DeepSeek's are the fixture's own.
    static var automaticProfiles: Data {
        guard var json = (try? JSONSerialization.jsonObject(with: Data(profiles.utf8))) as? [String: Any],
              var rows = json["profiles"] as? [[String: Any]] else { return Data(profiles.utf8) }
        func credits(_ model: String, _ effort: String, _ length: String) -> [String: Int]? {
            rows.first { $0["model"] as? String == model && $0["effort"] as? String == effort && $0["length"] as? String == length }?["credits"] as? [String: Int]
        }
        for length in ["brief", "standard", "detailed"] {
            for model in ["haiku", "sonnet", "opus"] {
                // As the server: the usual pick's estimate, the most it can pick's maximum (brief low, standard medium, detailed high).
                let highest = length == "brief" ? "low" : length == "standard" ? "medium" : "high"
                guard let usual = credits(model, length == "detailed" ? "medium" : "low", length), let most = credits(model, highest, length) else { continue }
                rows.append(["model": model, "effort": "auto", "length": length, "credits": ["low": usual["low"] ?? 0, "high": usual["high"] ?? 0, "max": most["max"] ?? 0]])
            }
            rows.append(["model": "deepseek", "effort": "auto", "length": length, "credits": ["low": 1, "high": 1, "max": length == "detailed" ? 2 : 1]])
        }
        json["profiles"] = rows
        json["models"] = ((json["models"] as? [[String: Any]]) ?? []) + [["id": "deepseek", "label": "DeepSeek", "detail": "Low cost; processed by DeepSeek"]]
        json["efforts"] = ((json["efforts"] as? [[String: Any]]) ?? []) + [["id": "auto", "label": "Automatic", "detail": "Chosen for each question"]]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data(profiles.utf8)
    }

    /// A topic title like the server's: from the question, deterministic for tests.
    static func topicTitle(for request: ChatGenerationRequest) -> String {
        let question = request.turns.first { $0.role == .user }?.text.lowercased() ?? ""
        if question.contains("transformer") || question.contains("attention") || question.contains("scal") { return "Scaling in dot-product attention" }
        if question.contains("dpo") || question.contains("preference") { return "Why DPO needs no reward model" }
        return "Explainer for a persona paper"
    }

    /// `GET functions/v1/chat` as the server publishes it (the Core fixture chat-profiles-v1.json, minified).
    static let profiles = #"""
    {"version":"chat-profiles-v1","rate_version":"beta-credits-v1","tariff":"anthropic-list-prices-2026-10-08","microusd_per_credit":5000,"default":{"model":"sonnet","effort":"low","length":"standard"},"models":[{"id":"haiku","label":"Haiku","detail":"Fastest and cheapest","api_model":"claude-haiku-5-5"},{"id":"sonnet","label":"Sonnet","detail":"Strong answers at a moderate cost","api_model":"claude-sonnet-5-5"},{"id":"opus","label":"Opus","detail":"Most capable; costs the most","api_model":"claude-opus-5-5"}],"efforts":[{"id":"low","label":"Low","detail":"Thinks only when needed; quickest"},{"id":"medium","label":"Medium","detail":"Thinks through harder questions"},{"id":"high","label":"High","detail":"Thinks carefully; slowest"}],"lengths":[{"id":"brief","label":"Brief","detail":"A few sentences"},{"id":"standard","label":"Standard","detail":"Focused answers"},{"id":"detailed","label":"Detailed","detail":"Thorough, with derivations and caveats"}],"profiles":[{"id":"haiku-low-brief","model":"haiku","effort":"low","length":"brief","api_model":"claude-haiku-5-5","max_output_tokens":3000,"credits":{"low":1,"high":2,"max":2}},{"id":"haiku-low-standard","model":"haiku","effort":"low","length":"standard","api_model":"claude-haiku-5-5","max_output_tokens":8000,"credits":{"low":1,"high":2,"max":2}},{"id":"haiku-low-detailed","model":"haiku","effort":"low","length":"detailed","api_model":"claude-haiku-5-5","max_output_tokens":12000,"credits":{"low":1,"high":2,"max":3}},{"id":"haiku-medium-brief","model":"haiku","effort":"medium","length":"brief","api_model":"claude-haiku-5-5","max_output_tokens":5000,"credits":{"low":1,"high":2,"max":2}},{"id":"haiku-medium-standard","model":"haiku","effort":"medium","length":"standard","api_model":"claude-haiku-5-5","max_output_tokens":10000,"credits":{"low":1,"high":2,"max":3}},{"id":"haiku-medium-detailed","model":"haiku","effort":"medium","length":"detailed","api_model":"claude-haiku-5-5","max_output_tokens":14000,"credits":{"low":1,"high":2,"max":3}},{"id":"haiku-high-brief","model":"haiku","effort":"high","length":"brief","api_model":"claude-haiku-5-5","max_output_tokens":9000,"credits":{"low":1,"high":2,"max":2}},{"id":"haiku-high-standard","model":"haiku","effort":"high","length":"standard","api_model":"claude-haiku-5-5","max_output_tokens":14000,"credits":{"low":1,"high":2,"max":3}},{"id":"haiku-high-detailed","model":"haiku","effort":"high","length":"detailed","api_model":"claude-haiku-5-5","max_output_tokens":18000,"credits":{"low":1,"high":2,"max":3}},{"id":"sonnet-low-brief","model":"sonnet","effort":"low","length":"brief","api_model":"claude-sonnet-5-5","max_output_tokens":3000,"credits":{"low":3,"high":22,"max":27}},{"id":"sonnet-low-standard","model":"sonnet","effort":"low","length":"standard","api_model":"claude-sonnet-5-5","max_output_tokens":8000,"credits":{"low":4,"high":24,"max":37}},{"id":"sonnet-low-detailed","model":"sonnet","effort":"low","length":"detailed","api_model":"claude-sonnet-5-5","max_output_tokens":12000,"credits":{"low":7,"high":26,"max":45}},{"id":"sonnet-medium-brief","model":"sonnet","effort":"medium","length":"brief","api_model":"claude-sonnet-5-5","max_output_tokens":5000,"credits":{"low":5,"high":24,"max":31}},{"id":"sonnet-medium-standard","model":"sonnet","effort":"medium","length":"standard","api_model":"claude-sonnet-5-5","max_output_tokens":10000,"credits":{"low":6,"high":26,"max":41}},{"id":"sonnet-medium-detailed","model":"sonnet","effort":"medium","length":"detailed","api_model":"claude-sonnet-5-5","max_output_tokens":14000,"credits":{"low":9,"high":28,"max":49}},{"id":"sonnet-high-brief","model":"sonnet","effort":"high","length":"brief","api_model":"claude-sonnet-5-5","max_output_tokens":9000,"credits":{"low":9,"high":28,"max":39}},{"id":"sonnet-high-standard","model":"sonnet","effort":"high","length":"standard","api_model":"claude-sonnet-5-5","max_output_tokens":14000,"credits":{"low":10,"high":29,"max":49}},{"id":"sonnet-high-detailed","model":"sonnet","effort":"high","length":"detailed","api_model":"claude-sonnet-5-5","max_output_tokens":18000,"credits":{"low":12,"high":32,"max":57}},{"id":"opus-low-brief","model":"opus","effort":"low","length":"brief","api_model":"claude-opus-5-5","max_output_tokens":3000,"credits":{"low":5,"high":44,"max":54}},{"id":"opus-low-standard","model":"opus","effort":"low","length":"standard","api_model":"claude-opus-5-5","max_output_tokens":8000,"credits":{"low":8,"high":47,"max":74}},{"id":"opus-low-detailed","model":"opus","effort":"low","length":"detailed","api_model":"claude-opus-5-5","max_output_tokens":12000,"credits":{"low":13,"high":52,"max":90}},{"id":"opus-medium-brief","model":"opus","effort":"medium","length":"brief","api_model":"claude-opus-5-5","max_output_tokens":5000,"credits":{"low":9,"high":48,"max":62}},{"id":"opus-medium-standard","model":"opus","effort":"medium","length":"standard","api_model":"claude-opus-5-5","max_output_tokens":10000,"credits":{"low":12,"high":51,"max":82}},{"id":"opus-medium-detailed","model":"opus","effort":"medium","length":"detailed","api_model":"claude-opus-5-5","max_output_tokens":14000,"credits":{"low":17,"high":56,"max":98}},{"id":"opus-high-brief","model":"opus","effort":"high","length":"brief","api_model":"claude-opus-5-5","max_output_tokens":9000,"credits":{"low":17,"high":55,"max":78}},{"id":"opus-high-standard","model":"opus","effort":"high","length":"standard","api_model":"claude-opus-5-5","max_output_tokens":14000,"credits":{"low":19,"high":58,"max":98}},{"id":"opus-high-detailed","model":"opus","effort":"high","length":"detailed","api_model":"claude-opus-5-5","max_output_tokens":18000,"credits":{"low":24,"high":63,"max":114}}],"estimate_note":"For a question about a typical 25-page paper. Web searches add about 2 credits each."}
    """#

    static func pieces(of text: String, size: Int) -> [String] {
        var result: [String] = [], current = ""
        for character in text {
            current.append(character)
            if current.count == size { result.append(current); current = "" }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// Process-lifetime credential store for synthetic journeys.
final class MemoryCredentialStore: AuthenticationCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private let acceptsConsent: Bool

    init(acceptsConsent: Bool = false) { self.acceptsConsent = acceptsConsent }

    func read(_ name: String) throws -> Data? {
        lock.withLock {
            if acceptsConsent, values[name] == nil, name.hasSuffix(".cloud-ai-consent") { return Data(ChatGenerationRequest.consentVersion.utf8) }
            return values[name]
        }
    }
    func write(_ data: Data, name: String) throws { lock.withLock { values[name] = data } }
    func delete(_ name: String) throws { lock.withLock { values[name] = nil } }
}
#endif
