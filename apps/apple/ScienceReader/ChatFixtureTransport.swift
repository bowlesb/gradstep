#if DEBUG && targetEnvironment(simulator)
import Foundation
import ScienceReaderCore

/// Synthetic answers for UI journeys (`--chat-fixture`). Compiled out of
/// physical-device and release builds; it never opens a network connection.
/// Modes: `--chat-fixture-mode=answer|slow|interrupt|insufficient_credits|refusal|diagram|sources|research`.
/// `research`: a table, papers named by arXiv ID and DOI, and a Sources list.
/// `--chat-fixture-consented` pre-accepts the in-memory cloud consent.
struct ChatFixtureTransport: ChatTransport {
    enum Mode: String, Sendable { case answer, slow, interrupt, insufficientCredits = "insufficient_credits", refusal, diagram, sources, research }
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
                    switch mode {
                    case .insufficientCredits:
                        try await Task.sleep(for: .milliseconds(150))
                        continuation.yield(.failure(code: "insufficient_credits"))
                    case .refusal:
                        continuation.yield(.delta("I can’t"))
                        try await Task.sleep(for: .milliseconds(150))
                        continuation.yield(.failure(code: "refused"))
                    case .answer, .slow, .interrupt, .diagram, .sources, .research:
                        try await Task.sleep(for: .milliseconds(300))
                        let text = mode == .research ? Self.research : mode == .sources ? Self.answer + Self.sources : Self.answer
                        let pieces = Self.pieces(of: text, size: 14)
                        let delay: Duration = mode == .slow ? .milliseconds(250) : .milliseconds(30)
                        // research: a search before the first text, and another one mid-answer (status events).
                        let secondSearch = mode == .research ? Self.pieces(of: Self.research.components(separatedBy: "Papers to read next")[0], size: 14).count : -1
                        if mode == .research { try await Self.search("direct preference optimization follow-ups", continuation) }
                        for (index, piece) in pieces.enumerated() {
                            if mode == .interrupt, index == pieces.count / 2 {
                                continuation.yield(.failure(code: "provider_unavailable"))
                                break
                            }
                            if index == secondSearch { try await Self.search("IPO KTO comparison", continuation) }
                            continuation.yield(.delta(piece))
                            try await Task.sleep(for: delay)
                        }
                        if mode == .diagram { continuation.yield(.diagram(title: "Scaled dot-product attention", source: Self.diagram)) }
                        if mode != .interrupt { continuation.yield(.done(stopReason: "end_turn", credits: 2)) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Web search answers end with sources in this form (see docs/CHAT.md).
    static let sources = """


    Sources:
    1. Attention Is All You Need — https://arxiv.org/abs/1706.03762
    2. https://example.org/attention-notes
    """

    /// A comparison table (inline math, bold, a pipe inside code), papers named by
    /// arXiv ID, arXiv link and DOI, and a source that appears only in Sources.
    static let research = """
    This synthetic fixture compares preference-optimization objectives; no AI request was made and the numbers are placeholders.

    | Method | Objective | Reward model | Win rate |
    |:---|:---|:---:|---:|
    | RLHF (PPO) | maximize \\(r_\\phi(x, y) - \\beta\\,\\mathrm{KL}\\) | Yes | 61% |
    | **DPO** | \\(-\\log \\sigma(\\beta \\Delta_\\theta)\\) | No | 64% |
    | IPO | \\((\\Delta_\\theta - \\tfrac{1}{2\\beta})^2\\) | No | 63% |
    | KTO | prospect value `v(x | y)` | No | 62% |

    DPO drops the separate reward model and the sampling loop, so it is cheaper to tune.

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

    /// A server-side search as the stream reports it: searching (with the query), then reading.
    private static func search(_ query: String, _ continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation) async throws {
        continuation.yield(.status(ChatProgress(kind: .searching, query: query)))
        try await Task.sleep(for: .seconds(3))
        continuation.yield(.status(ChatProgress(kind: .reading)))
        try await Task.sleep(for: .milliseconds(1500))
    }

    func creditBalance(accountID: UUID) async throws -> CreditBalance { CreditBalance(available: 480, reserved: 0) }

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
