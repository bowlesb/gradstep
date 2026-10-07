import Foundation

/// One saved conversation as All chats lists it. Computed on the device from decrypted history (one pass over the
/// events); nothing here is sent anywhere.
public struct ConversationSummary: Equatable, Sendable, Identifiable {
    public let id: UUID
    /// The conversation's title: its first question as saved with the conversation (at most 100 characters).
    public let title: String
    /// The paper a paper chat is about; nil for a general chat.
    public let documentID: UUID?
    /// Surviving questions and answers, across branches.
    public let messageCount: Int
    /// When the conversation began (its root, else its earliest message), when recorded.
    public let startedAt: Date?
    /// The newest message's time, when recorded. History written before events carried times has none.
    public let lastUsedAt: Date?
    /// Arrival position of the conversation's newest event in this device's history; orders conversations that
    /// have no recorded time, and breaks ties.
    public let lastArrival: Int
    /// Arrival position of the conversation itself (its root), for the same purpose when ordering by start.
    public let startArrival: Int
    /// The newest answer's text (a bounded prefix), for a one-line preview.
    public let latestAnswer: String?
    /// The questions asked, newest first (bounded), for local search.
    public let questions: String
    /// The passage a selection action started this conversation from (saved, encrypted, with the conversation).
    public let anchor: TextAnchor?

    public init(id: UUID, title: String, documentID: UUID?, messageCount: Int, startedAt: Date?, lastUsedAt: Date?,
                lastArrival: Int, startArrival: Int? = nil, latestAnswer: String?, questions: String, anchor: TextAnchor? = nil) {
        self.id = id; self.title = title; self.documentID = documentID; self.messageCount = messageCount
        self.startedAt = startedAt; self.lastUsedAt = lastUsedAt; self.lastArrival = lastArrival
        self.startArrival = startArrival ?? lastArrival
        self.latestAnswer = latestAnswer; self.questions = questions; self.anchor = anchor
    }

    /// Characters of the newest answer kept for the preview.
    public static let answerPrefix = 1_000
    /// Characters of questions kept for search.
    public static let questionsLimit = 4_000
}

public extension PrivateState {
    /// Every saved, undeleted conversation, in a stable order (by identifier; callers sort for display). One pass over
    /// the events, then a sort of each conversation's messages.
    func conversationSummaries() -> [ConversationSummary] {
        var deleted = Set<UUID>()
        var roots: [UUID: [AppliedEvent]] = [:]
        var messages: [UUID: [AppliedEvent]] = [:]
        for event in events.values {
            switch event.payload.kind {
            case .tombstone: deleted.insert(event.payload.entityID)
            case .conversation: roots[event.payload.entityID, default: []].append(event)
            case .message: if let conversation = event.payload.conversationID { messages[conversation, default: []].append(event) }
            default: break
            }
        }
        var result: [ConversationSummary] = []
        result.reserveCapacity(roots.count)
        for (id, revisions) in roots where !deleted.contains(id) {
            // The current revision, as `revisions(for:)` chooses it: not superseded, then the lowest event ID.
            let superseded = Set(revisions.flatMap(\.payload.parents))
            guard let root = revisions.filter({ !superseded.contains($0.id) }).min(by: { $0.id.wire < $1.id.wire }) else { continue }
            let surviving = (messages[id] ?? []).filter { !deleted.contains($0.payload.entityID) }
            let ordered = surviving.sorted { arrivalIndex($0.id) ?? -1 < arrivalIndex($1.id) ?? -1 }
            let times = surviving.compactMap(\.payload.createdAt)
            let started = root.payload.createdAt ?? times.min()
            let last = (times + [root.payload.createdAt].compactMap { $0 }).max()
            let lastArrival = (revisions + surviving).compactMap { arrivalIndex($0.id) }.max() ?? -1
            let startArrival = revisions.compactMap { arrivalIndex($0.id) }.min() ?? lastArrival
            let answer = ordered.last { $0.payload.role == .assistant }?.payload.text.map { String($0.prefix(ConversationSummary.answerPrefix)) }
            var questions = ""
            for message in ordered.reversed() where message.payload.role == .user {
                guard questions.count < ConversationSummary.questionsLimit, let text = message.payload.text else { continue }
                questions += (questions.isEmpty ? "" : "\n") + text.prefix(ConversationSummary.questionsLimit - questions.count)
            }
            result.append(ConversationSummary(id: id, title: root.payload.text ?? "", documentID: root.payload.documentID,
                messageCount: Set(surviving.map(\.payload.entityID)).count,
                startedAt: started.map(Self.date), lastUsedAt: last.map(Self.date), lastArrival: lastArrival,
                startArrival: startArrival, latestAnswer: answer, questions: questions, anchor: root.payload.anchor))
        }
        return result.sorted { $0.id.wire < $1.id.wire }
    }

    private static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }
}

/// A one-line plain-text preview of a chat message: Markdown markers, display math, code and the sources list left
/// out; inline math kept as its source. Presentation only.
public enum ChatPreview {
    public static func plain(_ text: String, limit: Int = 160) -> String {
        var parts: [String] = []
        var length = 0
        for block in ChatRichText.parse(String(text.prefix(ConversationSummary.answerPrefix))) {
            let inline: [ChatInline]
            var heading = false
            switch block {
            case .paragraph(let content), .listItem(_, _, let content): inline = content
            case .heading(_, let content): inline = content; heading = true
            case .displayMath, .preformatted, .table, .sources: continue
            }
            var line = inline.map { piece -> String in
                switch piece {
                case .text(let value): stripMarkdown(ChatRichText.inertLinks(value))
                case .math(let body): readableMath(body)
                }
            }.joined()
            // "Short answer" then its paragraph reads as "Short answer: …".
            if heading, let last = line.trimmingCharacters(in: .whitespaces).last, !".:?!".contains(last) { line += ":" }
            let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !collapsed.isEmpty else { continue }
            parts.append(collapsed); length += collapsed.count + 1
            if length >= limit { break }
        }
        let joined = parts.joined(separator: " ")
        return joined.count > limit ? String(joined.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : joined
    }

    /// Inline LaTeX as one line of text: common symbols as characters, `\mathrm{x}` as x, other command backslashes
    /// and braces dropped (`\sqrt{d_k}` → `√d_k`). Approximate; the transcript typesets the real thing.
    public static func readableMath(_ body: String) -> String {
        var result = body.replacingOccurrences(of: #"\^\{?\\top\}?"#, with: "ᵀ", options: .regularExpression)
        for (command, symbol) in mathSymbols.sorted(by: { $0.key.count > $1.key.count }) {
            result = result.replacingOccurrences(of: "\\\\\(command)(?![A-Za-z])", with: symbol, options: .regularExpression)
        }
        result = result.replacingOccurrences(of: #"\\(?:mathrm|mathbf|mathit|mathcal|mathbb|text|operatorname|bm|boldsymbol)\{([^{}]*)\}"#,
                                              with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\\(?:left|right)(?![A-Za-z])"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\\([A-Za-z]+)"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\\[,;:! ]"#, with: " ", options: .regularExpression)
        return result.filter { $0 != "{" && $0 != "}" }
    }

    private static let mathSymbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "eta": "η",
        "theta": "θ", "lambda": "λ", "mu": "μ", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ",
        "varphi": "φ", "psi": "ψ", "omega": "ω", "Delta": "Δ", "Gamma": "Γ", "Sigma": "Σ", "Omega": "Ω",
        "sqrt": "√", "sum": "∑", "prod": "∏", "int": "∫", "partial": "∂", "nabla": "∇", "infty": "∞",
        "cdot": "·", "times": "×", "odot": "⊙", "otimes": "⊗", "top": "ᵀ", "le": "≤", "leq": "≤", "ge": "≥",
        "geq": "≥", "ll": "≪", "gg": "≫", "ne": "≠", "neq": "≠", "approx": "≈", "sim": "∼", "propto": "∝",
        "in": "∈", "to": "→", "rightarrow": "→", "leftarrow": "←", "mid": "|", "ldots": "…", "cdots": "⋯",
    ]

    private static func stripMarkdown(_ text: String) -> String {
        var result = text
        for marker in ["**", "__", "`"] { result = result.replacingOccurrences(of: marker, with: "") }
        // Single-asterisk emphasis, but not a lone multiplication sign between spaces.
        return result.replacingOccurrences(of: #"(?<!\s)\*|\*(?!\s)"#, with: "", options: .regularExpression)
    }
}
