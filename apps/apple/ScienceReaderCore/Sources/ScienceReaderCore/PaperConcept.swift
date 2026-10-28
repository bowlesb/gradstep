import Foundation

// "Go deeper" on one Key concept of the paper's AI Explainer (2026-10-25; docs/JUDGMENT_LOG.md 27, CHAT.md "Go deeper on a
// key concept"). Owner, TestFlight 93: "an option for users to request more elaboration on each concept, and then another
// screen in front. Then when we swipe away we get the entire overview behind". One concept, in this paper's context: what
// it is, why the paper needs it, an intuition or small example, how the paper uses it, and where it appears with ¶ links.
// The server streams it (`concept_progress`, `concept_section`, then the whole `paper_concept`; _shared/chat-paper-concept.ts);
// this file checks those events again (untrusted), builds the request's passage, the bar's words and the text a question
// about it carries. Kept with the explainer it deepens (PaperExplainerAnswer.concepts), so reopening it is free.

public struct PaperConcept: Codable, Equatable, Sendable {
    public static let format = "paper-concept-v1"
    public enum Limits {
        public static let sections = 6, text = 1_500, title = 60, places = 6, note = 160, paragraphs = 8
    }
    /// The server's section kinds (others are shown by their title).
    public enum Kind: String, Codable, Equatable, Sendable { case what, why, example, paper, `where` }

    public struct Place: Codable, Equatable, Sendable {
        public let paragraph: Int
        public let note: String
        public init(paragraph: Int, note: String) { self.paragraph = paragraph; self.note = note }
    }
    public struct Section: Codable, Equatable, Sendable {
        /// The server's kind (`what`, `why`, `example`, `paper`, `where`), kept as sent; nil when it named none.
        public let kind: String?
        public let title: String
        /// Markdown with `[¶N]` citations and LaTeX math; empty for a list of places only.
        public let text: String
        public let paragraphs: [Int]
        public let places: [Place]
        public init(kind: String? = nil, title: String, text: String, paragraphs: [Int] = [], places: [Place] = []) {
            self.kind = kind; self.title = title; self.text = text; self.paragraphs = paragraphs; self.places = places
        }
        public var known: Kind? { kind.flatMap(Kind.init(rawValue:)) }
    }

    public var format: String = PaperConcept.format
    public var sections: [Section]
    public init(sections: [Section]) { self.sections = sections }

    // MARK: Checks (as the server's paperConceptSection / paperConcept)

    struct Row: Decodable {
        let kind: String?; let title: String?; let text: String?; let paragraphs: [Int]?; let places: [RawPlace]?
        struct RawPlace: Decodable { let paragraph: Int?; let note: String? }
    }

    /// One section (untrusted), checked as the server checks it: nil without a title or without text and places; a title,
    /// text or note longer than the server sends is dropped rather than cut (as the explainer's lines); places and
    /// paragraphs outside 1…`paragraphs` are left out.
    static func checked(_ row: Row, paragraphs: Int = 100_000) -> Section? {
        let title = FigureWalkthrough.line(row.title, Int.max)
        let text = FigureWalkthrough.prose(row.text, Int.max)
        guard !title.isEmpty, title.count <= Limits.title, text.count <= Limits.text else { return nil }
        var places: [Place] = []
        for raw in row.places ?? [] {
            guard places.count < Limits.places, let n = raw.paragraph, (1...paragraphs).contains(n), !places.contains(where: { $0.paragraph == n }) else { continue }
            let note = FigureWalkthrough.line(raw.note, Int.max)
            guard note.count <= Limits.note else { continue }
            places.append(Place(paragraph: n, note: note))
        }
        guard !text.isEmpty || !places.isEmpty else { return nil }
        var numbers: [Int] = []
        for n in row.paragraphs ?? [] where (1...paragraphs).contains(n) && !numbers.contains(n) && numbers.count < Limits.paragraphs { numbers.append(n) }
        let kind = row.kind.flatMap { $0.range(of: #"^[a-z_]{1,16}$"#, options: .regularExpression) != nil ? $0 : nil }
        return Section(kind: kind, title: title, text: text, paragraphs: numbers, places: places)
    }

    /// The final `paper_concept` event (untrusted): its usable sections (the first six); nil when none is left or the format
    /// is unknown.
    public static func validated(_ data: Data, paragraphs: Int = 100_000) -> PaperConcept? {
        struct Raw: Decodable { let format: String; let sections: [Row] }
        guard data.count <= 128 * 1024, let raw = try? JSONDecoder().decode(Raw.self, from: data), raw.format == format else { return nil }
        let sections = raw.sections.compactMap { checked($0, paragraphs: paragraphs) }.prefix(Limits.sections)
        return sections.isEmpty ? nil : PaperConcept(sections: Array(sections))
    }

    /// A streamed `concept_section` event: its place in the final concept (0–5) and the section, checked; nil when unusable.
    public static func streamedSection(_ data: Data) -> (index: Int, section: Section)? {
        struct Event: Decodable { let index: Int; let section: Row }
        guard data.count <= 32 * 1024, let event = try? JSONDecoder().decode(Event.self, from: data),
              (0..<Limits.sections).contains(event.index), let section = checked(event.section) else { return nil }
        return (event.index, section)
    }

    // MARK: The request and the words

    /// What the request carries as its passage (the server's PAPER_CONCEPT_INSTRUCTIONS read it; scripts/paper-concept-probe.mjs
    /// sends the same): the concept's name, its kind, the explainer's line and the paragraphs it linked.
    public static func selection(_ item: PaperExplainer.Item, kind: PaperExplainer.Kind) -> String {
        ([ "Concept: \(item.name)", "Kind: \(kind == .background ? "background the paper assumes" : "one of this paper's own ideas")" ]
         + (item.line.isEmpty ? [] : ["The explainer's line: \(item.line)"])
         + (item.paragraphs.isEmpty ? [] : ["Paragraphs: " + item.paragraphs.map { "[¶\($0)]" }.joined(separator: " ")]))
            .joined(separator: "\n")
    }
    /// The request's one turn.
    public static func question(_ item: PaperExplainer.Item) -> String { "Go deeper: \(item.name)" }

    /// The concept as Markdown (what a question about it carries, and the words of a kept one in other places).
    public var text: String {
        sections.map { section in
            let list = section.places.map { "- [¶\($0.paragraph)]" + ($0.note.isEmpty ? "" : " \($0.note)") }.joined(separator: "\n")
            return ["**\(section.title)**", section.text, list].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
    }
}

public extension ChatGenerationRequest {
    /// "Go deeper" on one key concept: the explainer's own request for the paper numbered on this device (its profile,
    /// capabilities and cached paper, so the paper is read from the explainer's cache), one turn, the concept as the passage.
    static func paperConcept(operationID: UUID, item: PaperExplainer.Item, kind: PaperExplainer.Kind, profile: ChatProfileChoice,
                             localContext: LocalPaperChatContext, visualAnswers: Bool) throws -> ChatGenerationRequest {
        try make(operationID: operationID, documentID: nil, transcript: [ChatTurnInput(role: .user, text: PaperConcept.question(item))],
                 selection: PaperConcept.selection(item, kind: kind), action: .paperConcept, profile: profile, topicTitle: false,
                 localContext: localContext, visualAnswers: visualAnswers)
    }
}

/// One deepened concept as this device keeps it, with the explainer it deepens (not synced, not chat history): the
/// sections, or the words sent instead, and the model that wrote it.
public struct PaperConceptAnswer: Codable, Equatable, Sendable {
    public var concept: PaperConcept?
    public var text: String
    public var model: String?
    public var savedAt: Date
    public init(concept: PaperConcept? = nil, text: String = "", model: String? = nil, savedAt: Date = Date()) {
        self.concept = concept; self.text = text; self.model = model; self.savedAt = savedAt
    }
    /// The words a question about it carries.
    public var words: String { concept?.text ?? text }
}

// MARK: The progress bar (the figure explainer's rules)

/// One concept request as its events arrive: the sections so far (in order, each once), the bar's inputs (the count is
/// only what the model announced), a waiting or switching notice before the writing starts, and the final `paper_concept`
/// once it comes (which replaces what streamed).
public struct PaperConceptTracker: Sendable {
    public private(set) var input = FigureProgress.Input(stage: .preparing, summary: true)
    public private(set) var sections: [PaperConcept.Section] = []
    public private(set) var final: PaperConcept?
    /// "Still waiting for the model…" or "Switching to Claude Haiku 5.5…" (servers from 2026-10-25), until writing starts.
    public private(set) var notice: String?
    public init() {}

    public var conceptSoFar: PaperConcept? { final ?? (sections.isEmpty ? nil : PaperConcept(sections: sections)) }

    public mutating func opened() { advance(.reading) }

    /// Applies one event; true when the concept so far changed.
    @discardableResult public mutating func apply(_ event: ChatStreamEvent) -> Bool {
        switch event {
        case .conceptProgress(let step):
            switch step.stage {
            case .reading: advance(.reading)
            case .writing:
                if let parts = step.parts { input.expected = parts }
                if let characters = step.characters { input.characters = max(input.characters, characters) }
                advance(.writing); notice = nil
            }
            return false
        case .status(let progress) where progress.kind == .waiting || progress.kind == .switching:
            if input.stage != .writing { notice = progress.text }
            return false
        case .conceptSection(let index, let section):
            guard final == nil, index >= sections.count, sections.count < PaperConcept.Limits.sections else { return false }
            sections.append(section)
            input.parts = sections.count; input.charactersAtLast = input.characters
            advance(.writing); notice = nil
            return true
        case .paperConcept(let concept):
            final = concept
            return true
        default: return false
        }
    }

    /// The bar now (and remembered, so it never goes back).
    public mutating func state() -> FigureProgress.State {
        let state = FigureProgress.state(input, kind: .concept)
        input.previous = state.value
        guard let notice, input.stage != .writing else { return state }
        return FigureProgress.State(label: notice, value: state.value)
    }

    private mutating func advance(_ stage: FigureProgress.Stage) {
        let order: [FigureProgress.Stage] = [.preparing, .reading, .writing, .done]
        if order.firstIndex(of: stage)! > order.firstIndex(of: input.stage)! { input.stage = stage }
    }
}
