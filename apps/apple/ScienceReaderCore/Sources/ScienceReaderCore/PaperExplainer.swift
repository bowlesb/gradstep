import CryptoKit
import Foundation

// The paper's AI Explainer (2026-10-22; docs/proposals/LEARNING_GUIDE.md "Paper AI Explainer"): the background a paper
// assumes, its key ideas and how they fit together, on request from the paper's options. The server streams it
// (`paper_progress`, `paper_summary`, `paper_item`, then the whole `paper_explainer`; _shared/chat-paper-explainer.ts);
// this file checks those events again (untrusted), draws the diagram's Mermaid source, the plain text "Open in Chat"
// carries, and the progress bar. The browser's apps/web/src/lib/paper-explainer.ts does the same: both reproduce
// tests/fixtures/paper-explainer.json exactly.

public struct PaperExplainer: Codable, Equatable, Sendable {
    public static let format = "paper-explainer-v1"
    public enum Kind: String, Codable, Equatable, Sendable { case background, idea }
    public struct Item: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let line: String
        public let paragraphs: [Int]
        public init(id: String, name: String, line: String, paragraphs: [Int]) { self.id = id; self.name = name; self.line = line; self.paragraphs = paragraphs }
    }
    public struct Link: Codable, Equatable, Sendable {
        public let from: String
        public let to: String
        public let label: String
        public init(from: String, to: String, label: String) { self.from = from; self.to = to; self.label = label }
    }
    public var format: String = PaperExplainer.format
    public var summary: String
    public var background: [Item]
    public var ideas: [Item]
    public var links: [Link]

    public init(summary: String, background: [Item], ideas: [Item], links: [Link]) {
        self.summary = summary; self.background = background; self.ideas = ideas; self.links = links
    }

    public enum Limits {
        public static let background = 10, ideas = 6, links = 24, summary = 600, name = 60, line = 240, label = 40, paragraphs = 6
    }

    // MARK: Checks (as the browser's parsePaperItem / parsePaperExplainer)

    /// One entry from an event (untrusted): nil when it has no usable id or name. Paragraphs outside 1…`paragraphs` are
    /// dropped (100,000 when the paper's block count isn't known).
    public static func item(_ input: Any?, paragraphs: Int = 100_000) -> Item? {
        guard let v = input as? [String: Any], let id = v["id"] as? String, isID(id), let name = text(v["name"], limit: Limits.name), !name.isEmpty else { return nil }
        var seen = Set<Int>(), kept: [Int] = []
        for value in (v["paragraphs"] as? [Any]) ?? [] {
            guard let n = StudyNotes.whole(value), n >= 1, n <= paragraphs, seen.insert(n).inserted else { continue }
            kept.append(n)
        }
        return Item(id: id, name: name, line: text(v["line"], limit: Limits.line) ?? "", paragraphs: Array(kept.prefix(Limits.paragraphs)))
    }

    /// The final `paper_explainer` event (untrusted), checked as the server checks it: entries without an id or name and
    /// links to unknown ids are dropped; nil when no entry is left or the format is unknown.
    public static func validated(_ data: Data, paragraphs: Int = 100_000) -> PaperExplainer? {
        guard let v = try? JSONSerialization.jsonObject(with: data) as? [String: Any], v["format"] as? String == format else { return nil }
        var seen = Set<String>()
        func items(_ raw: Any?, limit: Int) -> [Item] {
            var out: [Item] = []
            for entry in (raw as? [Any]) ?? [] {
                guard let item = item(entry, paragraphs: paragraphs), seen.insert(item.id).inserted else { continue }
                out.append(item)
            }
            return Array(out.prefix(limit))
        }
        let background = items(v["background"], limit: Limits.background), ideas = items(v["ideas"], limit: Limits.ideas)
        guard !background.isEmpty || !ideas.isEmpty else { return nil }
        let ids = Set((background + ideas).map(\.id))
        var pairs = Set<String>(), links: [Link] = []
        for raw in (v["links"] as? [Any]) ?? [] {
            guard let l = raw as? [String: Any], let from = l["from"] as? String, let to = l["to"] as? String,
                  ids.contains(from), ids.contains(to), from != to, pairs.insert("\(from)>\(to)").inserted else { continue }
            links.append(Link(from: from, to: to, label: text(l["label"], limit: Limits.label) ?? ""))
        }
        return PaperExplainer(summary: text(v["summary"], limit: Limits.summary) ?? "", background: background, ideas: ideas,
                              links: Array(links.prefix(Limits.links)))
    }

    /// A streamed summary (`paper_summary`), checked; nil when unusable.
    public static func streamedSummary(_ data: Data) -> String? {
        guard let v = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let summary = text(v["summary"], limit: Limits.summary),
              !summary.isEmpty else { return nil }
        return summary
    }

    /// A streamed entry (`paper_item`), checked; nil when unusable.
    public static func streamedItem(_ data: Data) -> (kind: Kind, index: Int, item: Item)? {
        guard let v = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let kind = (v["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let index = StudyNotes.whole(v["index"]), index >= 0, index < (kind == .background ? Limits.background : Limits.ideas),
              let item = item(v["item"]) else { return nil }
        return (kind, index, item)
    }

    private static func isID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil
    }
    /// One line: control characters out, white space collapsed; nil when longer than `limit` scalars (not cut).
    private static func text(_ value: Any?, limit: Int) -> String? {
        guard let value = value as? String else { return nil }
        let cleaned = String(String.UnicodeScalarView(value.unicodeScalars.map { scalar -> Unicode.Scalar in
            scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value) ? " " : scalar
        }))
        let line = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.unicodeScalars.count <= limit ? line : nil
    }

    // MARK: The diagram and the plain text

    /// How the paper's concepts fit together: a top-down Mermaid flowchart drawn by the app's own sandboxed renderer
    /// (strict mode, no network). Background concepts and the paper's own ideas are styled apart; labels are quoted and
    /// stripped of the characters Mermaid reads as syntax; node ids are prefixed so none is a keyword. Empty without entries.
    public var mermaid: String {
        guard !background.isEmpty || !ideas.isEmpty else { return "" }
        func node(_ id: String) -> String { "n_" + String(String.UnicodeScalarView(id.unicodeScalars.map { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" ? $0 : "_" })) }
        var lines = ["flowchart TD"]
        for b in background { lines.append("  \(node(b.id))[\"\(Self.mermaidLabel(b.name, max: 48))\"]:::background") }
        for i in ideas { lines.append("  \(node(i.id))[\"\(Self.mermaidLabel(i.name, max: 48))\"]:::idea") }
        for l in links {
            let label = Self.mermaidLabel(l.label, max: 32, fallback: "")
            lines.append(label.isEmpty ? "  \(node(l.from)) --> \(node(l.to))" : "  \(node(l.from)) -->|\"\(label)\"| \(node(l.to))")
        }
        lines += ["  classDef background fill:#eef1f8,stroke:#7a86a8,color:#1b1b1b", "  classDef idea fill:#fff1d6,stroke:#c98a12,color:#1b1b1b"]
        return lines.joined(separator: "\n")
    }

    /// A label Mermaid draws as written: no quotes, brackets, pipes or other syntax characters; at most `max` scalars (cut
    /// with "…").
    public static func mermaidLabel(_ value: String, max: Int, fallback: String = "concept") -> String {
        let stripped = String(String.UnicodeScalarView(value.unicodeScalars.map { "\"\\[]{}()<>|#;`".unicodeScalars.contains($0) ? " " : $0 }))
        let text = stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let scalars = Array(text.unicodeScalars)
        if scalars.count > max {
            let cut = String(String.UnicodeScalarView(scalars.prefix(max - 1)))
            return cut.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + "…"
        }
        return text.isEmpty ? fallback : text
    }

    /// The explainer as plain text: what "Open in Chat" carries into the conversation.
    public var text: String {
        func list(_ items: [Item]) -> String { items.map { "- \($0.name)" + ($0.line.isEmpty ? "" : ": \($0.line)") }.joined(separator: "\n") }
        return [summary, background.isEmpty ? "" : "Background:\n\(list(background))", ideas.isEmpty ? "" : "Key ideas:\n\(list(ideas))"]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// A `paper_progress` event: `reading` once the server asked the model, then `writing` with the explainer's characters so
/// far and, once the model announced it, how many entries it will write (1–16; else left out).
public struct PaperStreamProgress: Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable { case reading, writing }
    public let stage: Stage
    public let characters: Int?
    public let items: Int?
    public init(stage: Stage, characters: Int? = nil, items: Int? = nil) {
        self.stage = stage
        self.characters = characters.flatMap { (0...10_000_000).contains($0) ? $0 : nil }
        self.items = items.flatMap { (1...16).contains($0) ? $0 : nil }
    }
}

public extension ChatGenerationRequest {
    /// The paper's AI Explainer: the chat's own request for the paper numbered on this device (its profile, capabilities
    /// and cached paper), one turn, no passage and no figure.
    static let paperExplainerTurn = "Explain this paper"
    static func paperExplainer(operationID: UUID, profile: ChatProfileChoice, localContext: LocalPaperChatContext, visualAnswers: Bool) throws -> ChatGenerationRequest {
        try make(operationID: operationID, documentID: nil, transcript: [ChatTurnInput(role: .user, text: paperExplainerTurn)], selection: nil,
                 action: .paperExplainer, profile: profile, topicTitle: false, localContext: localContext, visualAnswers: visualAnswers)
    }
}

/// What the device keeps of one explainer (not synced, not chat history): the explainer or the words sent instead.
public struct PaperExplainerAnswer: Codable, Equatable, Sendable {
    public var explainer: PaperExplainer?
    public var text: String
    public var model: String?
    /// What it explains, for Settings › Your assets (action `paper_explainer`, item "paper").
    public var subject: ExplanationSubject?
    public init(explainer: PaperExplainer? = nil, text: String = "", model: String? = nil, subject: ExplanationSubject? = nil) {
        self.explainer = explainer; self.text = text; self.model = model; self.subject = subject
    }
}

/// One kept explainer: the paper revision (bundle manifest) and the chat profile.
public struct PaperExplainerKey: SealedAnswerKey {
    public let manifestSHA256: String
    public let profile: ChatProfileChoice
    public let localModel: String?
    public init(manifestSHA256: String, profile: ChatProfileChoice, localModel: String? = nil) {
        self.manifestSHA256 = manifestSHA256; self.profile = profile; self.localModel = localModel
    }
    public var fileName: String {
        let identity = "paper-explainer-v1\n\(manifestSHA256)\n\(localModel ?? profile.id)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined() + ".sealed"
    }
}

// MARK: The progress bar (the figure explainer's rules)

/// A stage label always; a determinate value only while the number of entries the model announced is known and not yet
/// reached; never backwards; past the estimate (the links, or more entries than announced) it turns indeterminate until the
/// explainer is done. The browser's `paperExplainerProgress`.
public enum PaperExplainerProgress {
    public enum Stage: String, Equatable, Sendable { case preparing, reading, writing, done }
    public struct Input: Equatable, Sendable {
        public var stage: Stage
        public var summary: Bool
        public var items: Int
        public var ideas: Int
        public var characters: Int
        public var charactersAtLast: Int
        public var expected: Int?
        public var previous: Double?
        public init(stage: Stage, summary: Bool = false, items: Int = 0, ideas: Int = 0, characters: Int = 0, charactersAtLast: Int = 0,
                    expected: Int? = nil, previous: Double? = nil) {
            self.stage = stage; self.summary = summary; self.items = items; self.ideas = ideas; self.characters = characters
            self.charactersAtLast = charactersAtLast; self.expected = expected; self.previous = previous
        }
    }
    public typealias State = FigureProgress.State

    /// Measured on the evaluation papers (2026-10-22): the summary's JSON about 500 characters, an entry's about 280.
    public enum Parameters {
        public static let summaryChars = 500.0, itemChars = 280.0, summaryShare = 0.1, itemsShare = 0.85, itemCap = 0.9
        public static var all: [String: Double] {
            ["summaryChars": summaryChars, "itemChars": itemChars, "summaryShare": summaryShare, "itemsShare": itemsShare, "itemCap": itemCap]
        }
    }

    public static func state(_ input: Input) -> State {
        switch input.stage {
        case .preparing: return State(label: "Preparing the paper…", value: nil)
        case .reading: return State(label: "Reading the paper…", value: nil)
        case .done: return State(label: "Done", value: 1)
        case .writing: break
        }
        let p = Parameters.self
        let inSummary = !input.summary && input.items == 0
        let known = input.expected.map { $0 >= 1 && input.items < $0 } ?? false
        let place = input.ideas > 0 ? "the key ideas" : "the background"
        let label: String
        if inSummary { label = "Writing the summary…" }
        else if let n = input.expected, input.items >= n { label = "Drawing how it fits together…" }
        else if known { label = "Writing \(place), \(input.items + 1) of \(input.expected!)…" }
        else { label = "Writing \(place)…" }
        guard known, let n = input.expected else { return State(label: label, value: nil) }
        let current = Double(max(0, input.characters - input.charactersAtLast))
        let value = inSummary ? p.summaryShare * min(p.itemCap, current / p.summaryChars)
            : p.summaryShare + p.itemsShare * (Double(input.items) + min(p.itemCap, current / p.itemChars)) / Double(n)
        return State(label: label, value: FigureProgress.round(min(1, max(input.previous ?? 0, value))))
    }

    /// One explainer request as its events arrive: the explainer so far (the summary, then entries in order, each once),
    /// the bar's inputs, and the final `paper_explainer` once it comes (which replaces what was streamed).
    public struct Tracker: Sendable {
        public private(set) var input = Input(stage: .preparing)
        public private(set) var summary: String?
        public private(set) var background: [PaperExplainer.Item] = []
        public private(set) var ideas: [PaperExplainer.Item] = []
        public private(set) var final: PaperExplainer?
        public init() {}

        /// What to show while it is written: the final explainer once it came, else the summary and entries so far.
        public var explainerSoFar: PaperExplainer? {
            final ?? (summary == nil && background.isEmpty && ideas.isEmpty ? nil
                : PaperExplainer(summary: summary ?? "", background: background, ideas: ideas, links: []))
        }

        public mutating func opened() { advance(.reading) }

        /// Applies one event; true when the explainer so far changed.
        @discardableResult public mutating func apply(_ event: ChatStreamEvent) -> Bool {
            switch event {
            case .paperProgress(let step):
                switch step.stage {
                case .reading: advance(.reading)
                case .writing:
                    if let items = step.items { input.expected = items }
                    if let characters = step.characters { input.characters = max(input.characters, characters) }
                    advance(.writing)
                }
                return false
            case .paperSummary(let text):
                guard final == nil, summary == nil else { return false }
                summary = text; input.summary = true; input.charactersAtLast = input.characters
                advance(.writing)
                return true
            case .paperItem(let kind, let index, let item):
                guard final == nil else { return false }
                switch kind {
                case .background:
                    guard index >= background.count, background.count < PaperExplainer.Limits.background else { return false }
                    background.append(item)
                case .idea:
                    guard index >= ideas.count, ideas.count < PaperExplainer.Limits.ideas else { return false }
                    ideas.append(item)
                }
                input.items = background.count + ideas.count; input.ideas = ideas.count; input.charactersAtLast = input.characters
                advance(.writing)
                return true
            case .paperExplainer(let explainer):
                final = explainer
                return true
            default: return false
            }
        }

        /// The bar now (and remembered, so it never goes back).
        public mutating func state() -> State {
            let state = PaperExplainerProgress.state(input)
            input.previous = state.value
            return state
        }

        private mutating func advance(_ stage: Stage) {
            let order: [Stage] = [.preparing, .reading, .writing, .done]
            if order.firstIndex(of: stage)! > order.firstIndex(of: input.stage)! { input.stage = stage }
        }
    }
}
