import Foundation

/// One plaintext turn sent to the chat function. Built on the device from the
/// decrypted branch the user is continuing; never persisted in this form.
public struct ChatTurnInput: Equatable, Sendable {
    public let role: PrivateEvent.Role
    public let text: String
    public init(role: PrivateEvent.Role, text: String) { self.role = role; self.text = text }
}

public enum ChatRequestError: Error, Equatable {
    case emptyContext, questionTooLarge
}

/// The bounded `functions/v1/chat` request body (contract: docs/architecture/CHAT.md).
/// A selection action the server completes beyond answering (Ingest adds the
/// referenced paper to the library).
/// `related` (server: always searches the web for related papers) needs a server that accepts it
/// (chat.ts, 2026-10-06); `ingest` adds the cited paper. `relevance` (Why it matters: the paper only, never the web)
/// and `diagramFix` (one corrected diagram for one the device could not parse) need the chat function of 2026-10-07.
/// `study` (reworked 2026-10-22): a tutored turn on the paper numbered on this device; it carries the tutor's hidden
/// notes from its previous turn (`StudyNotes`, none on the first) and needs no selection.
/// `paperExplainer` (2026-10-22): the paper's AI Explainer, one turn on the paper numbered on this device, no selection.
/// `equation` and `equationBackground` (2026-10-15): the equation view's symbols and its optional background, on the
/// paper numbered on this device with the chat's own profile, so they share the chat's cached paper
/// (docs/architecture/EQUATION_VIEW.md). They are no conversation: no title, no follow-ups.
/// `figure` and `figureSimpler` (2026-10-16): the figure view's walkthrough of one figure and one of its parts again,
/// more simply, on the same terms (docs/architecture/FIGURE_VIEW.md); each carries exactly that figure's image.
/// (`figure_detail`, "Extract the subfigure and more context", was removed from the apps on 2026-10-21: the walkthrough is
/// the one figure result. The server still accepts it from older builds; this client never sends it.)
public enum ChatAction: String, Equatable, Sendable {
    case ingest, related, relevance, diagramFix = "diagram_fix", study, equation, equationBackground = "equation_background"
    case figure, figureSimpler = "figure_simpler", paperExplainer = "paper_explainer"
    public var isEquation: Bool { self == .equation || self == .equationBackground }
    /// The explainers: no conversation (no title, no follow-ups).
    public var isExplainer: Bool { isEquation || isFigure || self == .paperExplainer }
    public var isFigure: Bool { self == .figure || self == .figureSimpler }
}

public struct ChatGenerationRequest: Equatable, Sendable {
    /// v3 (2026-10-15) also names the figure a question is about (ChatConsentView); readers who accepted v2 are asked once more.
    public static let consentVersion = "cloud-ai-v6"
    public static let maximumTurns = 60
    public static let maximumMessageBytes = 200_000
    public static let maximumSelectionScalars = 4_000

    public let operationID: UUID
    /// Nil for general chat; the paper's document ID for paper chat.
    public let documentID: UUID?
    public let localContext: LocalPaperChatContext?
    public let turns: [ChatTurnInput]
    public let selection: String?
    /// Only sent with a selection.
    public let action: ChatAction?
    /// The chat's model, effort and length; sent only when it isn't the standard profile, so a request with the
    /// default stays byte-for-byte the one servers before profiles accept (server 2026-10-08).
    public let profile: ChatProfileChoice
    /// Ask the server for a topic title alongside the answer (server 2026-10-08).
    public let topicTitle: Bool
    /// Study mode: the tutor's notes from its previous turn (none on the first); sent only with the action `study`.
    public let studyNotes: StudyNotes?
    /// The reader's "Visual answers" setting: with it the server may draw diagrams and HTML visuals (sent as the
    /// `visual_answers` capability; an empty list says it is off).
    public let visualAnswers: Bool
    /// The figures the question is about (at most three images), sent under consent v3.
    public let figures: [ChatFigureImage]
    /// Native-only context, including device-PDF bundles. It must never be encoded for a cloud transport.
    public private(set) var onDevicePaperText: String?
    public private(set) var onDeviceFocus: Int?
    public private(set) var isLocalInference = false
    /// Where the answer goes on this device, for Your AI usage's link back to it (AIUsageProvenance): the conversation, or
    /// the equation's or figure's id in the paper's bundle ("paper" for the paper's AI Explainer). Never encoded or sent.
    public private(set) var usageConversationID: UUID?
    public private(set) var usageItemID: String?

    /// The same request, naming what it is for on this device (never sent).
    public func linked(conversation: UUID? = nil, item: String? = nil) -> Self {
        var copy = self; copy.usageConversationID = conversation ?? usageConversationID; copy.usageItemID = item ?? usageItemID; return copy
    }

    public func forLocalInference(paperText: String?, focus: Int? = nil) -> Self {
        var copy = self; copy.onDevicePaperText = paperText; copy.onDeviceFocus = focus; copy.isLocalInference = true; return copy
    }

    /// Keeps the newest turns that fit the server bounds. The context always
    /// starts and ends with a user turn; empty turns are skipped.
    public static func make(operationID: UUID, documentID: UUID?, transcript: [ChatTurnInput], selection: String?,
                            action: ChatAction? = nil, profile: ChatProfileChoice = .standard,
                            topicTitle: Bool = false, localContext: LocalPaperChatContext? = nil, studyNotes: StudyNotes? = nil,
                            visualAnswers: Bool = true, figures: [ChatFigureImage] = []) throws -> ChatGenerationRequest {
        let usable = transcript.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let last = usable.last, last.role == .user else { throw ChatRequestError.emptyContext }
        guard last.text.utf8.count <= maximumMessageBytes else { throw ChatRequestError.questionTooLarge }
        var kept: [ChatTurnInput] = [], bytes = 0
        for turn in usable.reversed() {
            let size = turn.text.utf8.count
            guard kept.count < maximumTurns, bytes + size <= maximumMessageBytes else { break }
            kept.append(turn); bytes += size
        }
        kept.reverse()
        while let first = kept.first, first.role != .user { kept.removeFirst() }
        let quote = selection.map { bounded($0, scalars: maximumSelectionScalars) }
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        // Every selection action needs its quote; Study and the paper's explainer act on the paper (a quote only starts a
        // study on a passage; the explainer takes none).
        let kept_action = action == .study || action == .paperExplainer || quote != nil ? action : nil
        return ChatGenerationRequest(operationID: operationID, documentID: documentID, turns: kept, selection: kept_action == .paperExplainer ? nil : quote,
                                     action: kept_action, profile: profile, topicTitle: topicTitle, localContext: localContext,
                                     studyNotes: kept_action == .study ? studyNotes : nil, visualAnswers: visualAnswers,
                                     figures: kept_action == .ingest || kept_action == .paperExplainer || (documentID == nil && localContext == nil) ? [] : Array(figures.prefix(3)))
    }

    /// A diagram the device's Mermaid could not parse, sent back once for a corrected version: general mode, one turn
    /// (title, Mermaid's error and the source, within the server's 24 KB), no conversation, no paper. The server
    /// meters it like any answer, with a small output allowance.
    public static let maximumRepairBytes = 24_000
    public static func diagramRepair(operationID: UUID, title: String, source: String, error: String) -> ChatGenerationRequest? {
        let message = bounded(error.trimmingCharacters(in: .whitespacesAndNewlines), scalars: 600)
        let text = "Title: \(bounded(title, scalars: 200))\nMermaid error: \(message.isEmpty ? "unknown" : message)\n\n\(source)"
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= maximumRepairBytes else { return nil }
        // A repair always uses the server's default model and asks for no title.
        return ChatGenerationRequest(operationID: operationID, documentID: nil, turns: [ChatTurnInput(role: .user, text: text)],
                                     selection: nil, action: .diagramFix, profile: .standard, topicTitle: false)
    }

    private init(operationID: UUID, documentID: UUID?, turns: [ChatTurnInput], selection: String?, action: ChatAction?,
                 profile: ChatProfileChoice, topicTitle: Bool, localContext: LocalPaperChatContext? = nil, studyNotes: StudyNotes? = nil, visualAnswers: Bool = true,
                 figures: [ChatFigureImage] = []) {
        self.operationID = operationID; self.documentID = localContext == nil ? documentID : nil; self.localContext = localContext; self.turns = turns; self.selection = selection; self.action = action
        self.profile = profile; self.topicTitle = topicTitle; self.studyNotes = studyNotes; self.visualAnswers = visualAnswers; self.figures = figures
    }

    public func encoded() throws -> Data {
        guard !isLocalInference else { throw ChatRequestError.emptyContext }
        struct Turn: Encodable { let role: String; let text: String }
        struct Selection: Encodable { let quote: String }
        // Synthesized encoding omits nil optionals (general chat sends no document).
        struct Body: Encodable {
            let operation_id: String
            let consent_version: String
            let mode: String
            let document_id: String?
            let local_context: LocalPaperChatContext?
            let messages: [Turn]
            let selection: Selection?
            let action: String?
            /// Ingest may add web (non-arXiv) papers: this build shows them.
            let capabilities: [String]?
            let profile: ChatProfileChoice?
            let topic_title: Bool?
            /// Follow-up suggestions after every ordinary answer (not a diagram repair, not Ingest, not Study: the tutor asks).
            let follow_ups: Bool?
            /// Study mode: the tutor's notes from its previous turn (never the retired `study` map).
            let study_state: StudyNotes?
            /// The figures the question is about (consent v3).
            let figures: [Figure]?
        }
        struct Figure: Encodable { let id: String; let paragraph: Int; let caption: String; let media_type: String; let data: String; let width: Int; let height: Int }
        return try ReaderCrypto.encode(Body(operation_id: operationID.wire, consent_version: Self.consentVersion,
            mode: documentID == nil && localContext == nil ? "general" : "paper", document_id: documentID?.wire, local_context: localContext,
            messages: turns.map { Turn(role: $0.role.rawValue, text: $0.text) }, selection: selection.map(Selection.init), action: action?.rawValue,
            capabilities: Self.capabilities(action: action, visualAnswers: visualAnswers, figureRequests: localContext != nil,
                                            paper: documentID != nil || localContext != nil), profile: profile == .standard ? nil : profile,
            topic_title: topicTitle && action?.isExplainer != true ? true : nil,
            follow_ups: action == .diagramFix || action == .ingest || action == .study || action?.isExplainer == true ? nil : true,
            study_state: action == .study ? studyNotes : nil,
            figures: figures.isEmpty ? nil : figures.map { Figure(id: $0.id, paragraph: $0.paragraph, caption: $0.caption, media_type: $0.mediaType,
                                                                 data: $0.data, width: $0.width, height: $0.height) }))
    }

    /// Always a list: an empty one tells the server the reader turned visual answers off (builds before the setting
    /// sent nothing and still get diagrams).
    /// `figureRequests`: the device holds the paper (local context) and can attach a figure the model asks for
    /// (`figure_request`, 2026-10-15), so the server may offer `look_at_figure`.
    /// `stop_signal` (2026-10-16): this app records the reader's Stop (`v1_chat_stop`), so an answer that ends any other
    /// way early costs the reader nothing (CHAT.md, "When an answer stops early").
    /// `figure_view` (2026-10-16): this app has the figure view, so every paper chat carries the walkthrough's tool and a
    /// walkthrough reads the chat's cached paper (FIGURE_VIEW.md, "Server — as built"); never Add paper or a repair.
    public static func capabilities(action: ChatAction?, visualAnswers: Bool, figureRequests: Bool = false, paper: Bool = false) -> [String] {
        (action == .ingest ? ["web_import"] : []) + (visualAnswers ? ["visual_answers"] : [])
            + (visualAnswers && figureRequests && action != .ingest && action != .diagramFix ? ["figure_requests"] : [])
            + (paper && action != .ingest && action != .diagramFix ? ["figure_view"] : [])
            + ["stop_signal"]
    }

    /// The same question again with the figures the model asked for (a new operation: the first one is settled).
    public func attaching(_ figures: [ChatFigureImage]) -> ChatGenerationRequest {
        ChatGenerationRequest(operationID: UUID(), documentID: documentID, turns: turns, selection: selection, action: action, profile: profile,
                              topicTitle: topicTitle, localContext: localContext, studyNotes: studyNotes, visualAnswers: visualAnswers, figures: Array(figures.prefix(3)))
            .linked(conversation: usageConversationID, item: usageItemID)
    }

    static func bounded(_ text: String, scalars limit: Int) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: text.unicodeScalars.prefix(limit))
        return String(view)
    }
}

public enum ChatStreamEvent: Equatable, Sendable {
    case delta(String)
    /// A diagram the answer drew (sent before `done`).
    case diagram(title: String, source: String)
    /// A visual answer (an HTML fragment the server sanitized), kept like a diagram.
    case visual(title: String, html: String)
    /// Parts of an attached figure, each cropped on the device with its note.
    case figureParts(ChatFigureParts)
    /// The model asks for a figure of the paper ("Figure 4"): the device asks again with it attached (servers from
    /// 2026-10-15, offered with the `figure_requests` capability).
    case figureRequest(String)
    /// What the server is doing between pieces of text (searching, adding a paper).
    case status(ChatProgress)
    /// The conversation's topic title (asked for with `topicTitle`), sent before `done`.
    case title(String)
    /// Follow-up questions the answer suggested (servers from 2026-10-14), sent before `done`; shown, never saved.
    case followUps([String])
    /// Study mode: the tutor's hidden notes after a tutored answer (servers from 2026-10-22), sent before `done`; kept
    /// with the open chat only and sent back with the next study turn.
    case studyState(StudyNotes)
    /// The paper's AI Explainer (action `paper_explainer`, servers from 2026-10-22): where the model is, the summary, each
    /// entry as it is complete (with its place among its kind), then the whole explainer.
    case paperProgress(PaperStreamProgress)
    case paperSummary(String)
    case paperItem(kind: PaperExplainer.Kind, index: Int, item: PaperExplainer.Item)
    case paperExplainer(PaperExplainer)
    /// The equation view's symbols (action `equation`, servers from 2026-10-15), sent once before `done`.
    case equation(EquationSymbols)
    /// The figure view's walkthrough (action `figure`, servers from 2026-10-16), sent once before `done`.
    case figure(FigureWalkthrough)
    /// The streamed walkthrough (action `figure`, servers from 2026-10-22), all before the final `figure`: where the
    /// writing is, the summary once, then each checked part with its place in the final walkthrough. Builds without these
    /// cases ignore the events and read only the final `figure`.
    case figureProgress(FigureStreamProgress)
    case figureSummary(String)
    case figureSection(index: Int, section: FigureWalkthrough.Section)
    /// The streamed symbols (action `equation`, servers from 2026-10-22; EQUATION_VIEW.md "Streamed explanation"), all
    /// before the final `equation`: where the writing is, the summary once, then each checked symbol with its place in the
    /// final symbols. Builds without these cases ignore the events and read only the final `equation`.
    case equationProgress(EquationStreamProgress)
    case equationSummary(String)
    case equationSymbol(index: Int, symbol: EquationSymbols.Symbol)
    /// `model`: the model that wrote the answer; `profile`: the profile it was asked with (servers from 2026-10-08).
    case done(stopReason: String, credits: Int, model: String? = nil, profile: String? = nil)
    /// `credits`: what the failed answer cost (0 when the provider never started it; servers from 2026-10-14).
    case failure(code: String, credits: Int? = nil)
}

/// Server work in progress during an answer (`status` events, server 2026-10-07).
/// Builds without this case ignore the event, as they ignore any unknown name.
public struct ChatProgress: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case searching, reading, findingPaper = "finding_paper", addingPaper = "adding_paper"
        /// The model hasn't sent anything back yet (servers from 2026-10-25, after 12 s), then it has started.
        case waiting, thinking
        /// The chosen model failed before writing and the answer is asked of its fallback (servers from 2026-10-25; CHAT.md
        /// "A fallback when the chosen model fails before writing"). `query` is that model's name ("Claude Haiku 5.5").
        case switching
        /// The device's own: a diagram that didn't parse is being redrawn (never sent by the server).
        case fixingDiagram = "fixing_diagram"
        /// The device's own: the figure the model asked for is attached and the question asked again.
        case lookingAtFigure = "looking_at_figure"
        /// The device's own: the paper the question is about is being prepared here before the question goes.
        case preparingPaper = "preparing_paper"
    }
    public static let maximumQueryCharacters = 200
    public let kind: Kind
    /// The search query, for `searching` only (the reader's own answer; never logged); the figure for `lookingAtFigure`;
    /// the fallback model's name for `switching`.
    public let query: String?

    public init(kind: Kind, query: String? = nil) {
        self.kind = kind
        let cleaned = query.map { value in
            String(value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        self.query = kind == .searching || kind == .lookingAtFigure || kind == .switching ? cleaned.flatMap { $0.isEmpty ? nil : String($0.prefix(Self.maximumQueryCharacters)) } : nil
    }

    /// One line under the streaming answer.
    public var text: String {
        switch kind {
        case .searching: query.map { "Searching the web for “\($0)”" } ?? "Searching the web…"
        case .reading: "Reading results…"
        case .findingPaper: "Finding the paper…"
        case .addingPaper: "Adding to your library…"
        case .waiting: "Still waiting for the model…"
        case .thinking: "Thinking…"
        case .switching: query.map { "Switching to \($0)…" } ?? "Switching to another model…"
        case .fixingDiagram: "Fixing the diagram…"
        case .lookingAtFigure: query.map { "Looking at \($0)…" } ?? "Looking at the figure…"
        case .preparingPaper: "Preparing the paper on this device…"
        }
    }
}

/// A `figure_progress` event: `reading` once the server asked the model, then `writing` with the walkthrough's characters
/// so far (growing) and, once the model announced it, how many parts it will write (1–12; else left out).
public struct FigureStreamProgress: Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable { case reading, writing }
    public let stage: Stage
    public let characters: Int?
    public let parts: Int?
    public init(stage: Stage, characters: Int? = nil, parts: Int? = nil) {
        self.stage = stage
        self.characters = characters.flatMap { (0...10_000_000).contains($0) ? $0 : nil }
        self.parts = parts.flatMap { (1...FigureWalkthrough.maximumSections).contains($0) ? $0 : nil }
    }
}

/// Where the equation's symbols are (`equation_progress`): `reading` once the model was asked, then `writing` with the
/// characters written so far and, once the model said it, how many symbols it will list.
public struct EquationStreamProgress: Equatable, Sendable {
    public let stage: FigureStreamProgress.Stage
    public let characters: Int?
    public let symbols: Int?
    public init(stage: FigureStreamProgress.Stage, characters: Int? = nil, symbols: Int? = nil) {
        self.stage = stage
        self.characters = characters.flatMap { (0...10_000_000).contains($0) ? $0 : nil }
        self.symbols = symbols.flatMap { (1...EquationSymbols.maximumSymbols).contains($0) ? $0 : nil }
    }
}

public enum ChatStreamError: Error, Equatable {
    case malformed, tooLarge
}

/// Incremental, bounded `text/event-stream` parser for the chat function.
/// Unknown event names and comments (keep-alive pings) are ignored.
public struct ChatSSEParser: Sendable {
    public static let maximumLineBytes = 256 * 1024
    public static let maximumEventBytes = 256 * 1024
    private var line: [UInt8] = []
    private var afterCarriageReturn = false
    private var eventName = ""
    private var data: [UInt8] = []
    private var hasData = false

    public init() {}

    public mutating func consume<Bytes: Sequence>(_ bytes: Bytes) throws -> [ChatStreamEvent] where Bytes.Element == UInt8 {
        var events: [ChatStreamEvent] = []
        for byte in bytes {
            if afterCarriageReturn {
                afterCarriageReturn = false
                if byte == 0x0A { continue }
            }
            if byte == 0x0A || byte == 0x0D {
                afterCarriageReturn = byte == 0x0D
                if let event = try endLine() { events.append(event) }
                continue
            }
            guard line.count < Self.maximumLineBytes else { throw ChatStreamError.tooLarge }
            line.append(byte)
        }
        return events
    }

    /// End of input. An event without its terminating blank line is
    /// incomplete and dropped, as the SSE format requires.
    public mutating func finish() {
        line = []; afterCarriageReturn = false; eventName = ""; data = []; hasData = false
    }

    private mutating func endLine() throws -> ChatStreamEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty { return try dispatch() }
        if line.first == 0x3A { return nil }
        let field: [UInt8], value: ArraySlice<UInt8>
        if let colon = line.firstIndex(of: 0x3A) {
            field = Array(line[..<colon])
            var rest = line[(colon + 1)...]
            if rest.first == 0x20 { rest = rest.dropFirst() }
            value = rest
        } else { field = line; value = [] }
        switch String(decoding: field, as: UTF8.self) {
        case "event":
            guard let name = String(bytes: value, encoding: .utf8) else { throw ChatStreamError.malformed }
            eventName = name
        case "data":
            if hasData { data.append(0x0A) }
            data.append(contentsOf: value); hasData = true
            guard data.count <= Self.maximumEventBytes else { throw ChatStreamError.tooLarge }
        default: break
        }
        return nil
    }

    static func label(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= PrivateEvent.maximumLabelBytes,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }) else { return nil }
        return value
    }

    private mutating func dispatch() throws -> ChatStreamEvent? {
        defer { eventName = ""; data = []; hasData = false }
        guard hasData else { return nil }
        let payload = Data(data)
        switch eventName {
        case "delta":
            struct Delta: Decodable { let text: String }
            guard let delta = try? JSONDecoder().decode(Delta.self, from: payload) else { throw ChatStreamError.malformed }
            return .delta(delta.text)
        case "diagram":
            struct Diagram: Decodable { let title: String; let source: String }
            guard let diagram = try? JSONDecoder().decode(Diagram.self, from: payload),
                  ChatDiagram(title: diagram.title, source: diagram.source, messageID: nil) != nil else { throw ChatStreamError.malformed }
            return .diagram(title: diagram.title, source: diagram.source)
        case "figure_request":
            // Informational: a request that is not a figure's label is dropped, never fatal.
            struct Request: Decodable { let figure: String }
            guard let request = try? JSONDecoder().decode(Request.self, from: payload),
                  request.figure.range(of: #"^(Figure|Table) [0-9]{1,3}$"#, options: .regularExpression) != nil else { return nil }
            return .figureRequest(request.figure)
        case "figure_parts":
            // Informational: parts that are not usable are dropped, never fatal.
            guard let parts = try? JSONDecoder().decode(ChatFigureParts.self, from: payload), parts.isValid else { return nil }
            return .figureParts(parts)
        case "visual":
            // Informational: a visual that is not usable is dropped, never fatal (builds before it ignore the event).
            struct Visual: Decodable { let title: String; let html: String }
            guard let visual = try? JSONDecoder().decode(Visual.self, from: payload),
                  ChatDiagram(title: visual.title, source: visual.html, messageID: nil, format: ChatDiagram.htmlFormat) != nil else { return nil }
            return .visual(title: visual.title, html: visual.html)
        case "status":
            // Informational only: an unknown kind or a malformed status is ignored, never fatal.
            struct Status: Decodable { let kind: String; let query: String?; let model: String? }
            guard let status = try? JSONDecoder().decode(Status.self, from: payload),
                  let kind = ChatProgress.Kind(rawValue: status.kind) else { return nil }
            // `switching` names the fallback by its client identity (a `done.model` label), shown by its name.
            if kind == .switching { return .status(ChatProgress(kind: kind, query: Self.label(status.model).map(ChatProfileText.modelName))) }
            return .status(ChatProgress(kind: kind, query: status.query))
        case "title":
            // A title that isn't usable is dropped; the answer is unaffected.
            struct Title: Decodable { let text: String }
            guard let title = try? JSONDecoder().decode(Title.self, from: payload), let text = ChatTopicTitle.clean(title.text) else { return nil }
            return .title(text)
        case "followups":
            // Informational: unusable suggestions are dropped, never fatal.
            struct FollowUps: Decodable { let questions: [String] }
            guard let decoded = try? JSONDecoder().decode(FollowUps.self, from: payload) else { return nil }
            let questions = ChatFollowUps.clean(decoded.questions)
            return questions.isEmpty ? nil : .followUps(questions)
        case "study_state":
            // Notes that can't be read are dropped; the answer and the previous notes are unaffected.
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], let state = object["state"] as? [String: Any],
                  let notes = StudyNotes.validated(state) else { return nil }
            return .studyState(notes)
        case "paper_progress":
            // Informational: a malformed step is dropped, never fatal.
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let stage = (object["stage"] as? String).flatMap(PaperStreamProgress.Stage.init(rawValue:)) else { return nil }
            return .paperProgress(PaperStreamProgress(stage: stage, characters: StudyNotes.whole(object["characters"]), items: StudyNotes.whole(object["items"])))
        case "paper_summary":
            return PaperExplainer.streamedSummary(payload).map(ChatStreamEvent.paperSummary)
        case "paper_item":
            return PaperExplainer.streamedItem(payload).map { .paperItem(kind: $0.kind, index: $0.index, item: $0.item) }
        case "paper_explainer":
            return PaperExplainer.validated(payload).map(ChatStreamEvent.paperExplainer)
        case "equation":
            // Informational: symbols that are not usable are dropped (the view then says it couldn't describe them).
            guard let symbols = EquationSymbols.validated(payload) else { return nil }
            return .equation(symbols)
        case "figure":
            // Informational: a walkthrough that is not usable is dropped (the view then says it couldn't explain it).
            guard let walkthrough = FigureWalkthrough.validated(payload) else { return nil }
            return .figure(walkthrough)
        case "figure_progress":
            // Informational: a malformed step is dropped, never fatal (the walkthrough itself is unaffected).
            struct Progress: Decodable { let stage: String; let characters: Double?; let parts: Double? }
            guard let progress = try? JSONDecoder().decode(Progress.self, from: payload),
                  let stage = FigureStreamProgress.Stage(rawValue: progress.stage) else { return nil }
            func whole(_ value: Double?) -> Int? { value.flatMap { $0.isFinite && $0.rounded() == $0 && abs($0) < 1e9 ? Int($0) : nil } }
            return .figureProgress(FigureStreamProgress(stage: stage, characters: whole(progress.characters), parts: whole(progress.parts)))
        case "figure_summary":
            // Informational: an unusable summary is dropped; the final `figure` still carries it.
            return FigureWalkthrough.streamedSummary(payload).map(ChatStreamEvent.figureSummary)
        case "figure_section":
            // Informational: an unusable part is dropped; the final `figure` decides what is kept.
            return FigureWalkthrough.streamedSection(payload).map { .figureSection(index: $0.index, section: $0.section) }
        case "equation_progress":
            // Informational: a malformed step is dropped, never fatal.
            struct Progress: Decodable { let stage: String; let characters: Double?; let symbols: Double? }
            guard let progress = try? JSONDecoder().decode(Progress.self, from: payload),
                  let stage = FigureStreamProgress.Stage(rawValue: progress.stage) else { return nil }
            func whole(_ value: Double?) -> Int? { value.flatMap { $0.isFinite && $0.rounded() == $0 && abs($0) < 1e9 ? Int($0) : nil } }
            return .equationProgress(EquationStreamProgress(stage: stage, characters: whole(progress.characters), symbols: whole(progress.symbols)))
        case "equation_summary":
            // Informational: an unusable summary is dropped; the final `equation` still carries it.
            return EquationSymbols.streamedSummary(payload).map(ChatStreamEvent.equationSummary)
        case "equation_symbol":
            // Informational: an unusable symbol is dropped; the final `equation` decides what is kept.
            return EquationSymbols.streamedSymbol(payload).map { .equationSymbol(index: $0.index, symbol: $0.symbol) }
        case "done":
            struct Done: Decodable { let stop_reason: String; let credits: Int; let model: String?; let profile: String? }
            guard let done = try? JSONDecoder().decode(Done.self, from: payload), done.credits >= 0 else { throw ChatStreamError.malformed }
            // Labels only: bounded plain identifiers, else left out (never fatal).
            return .done(stopReason: done.stop_reason, credits: done.credits, model: Self.label(done.model), profile: Self.label(done.profile))
        case "error":
            struct Failure: Decodable { let code: String; let credits: Int? }
            guard let failure = try? JSONDecoder().decode(Failure.self, from: payload),
                  failure.code.utf8.count <= 64 else { throw ChatStreamError.malformed }
            return .failure(code: failure.code, credits: failure.credits.flatMap { $0 >= 0 ? $0 : nil })
        default: return nil
        }
    }
}

public enum ChatDisplayText {
    /// Prepares message source for SwiftUI's inline Markdown: backslashes
    /// outside code spans are escaped so LaTeX such as `\(`, `\[`, `\{` and
    /// `\_` keeps its backslash. Code spans are left unchanged, since Markdown
    /// does not process escapes inside them.
    public static func inlineMarkdownPreservingBackslashes(_ text: String) -> String {
        var result = "", openRun = 0, index = text.startIndex
        result.reserveCapacity(text.utf8.count)
        while index < text.endIndex {
            if text[index] == "`" {
                var end = index, run = 0
                while end < text.endIndex, text[end] == "`" { run += 1; end = text.index(after: end) }
                result += String(repeating: "`", count: run)
                if openRun == 0 { openRun = run } else if openRun == run { openRun = 0 }
                index = end
                continue
            }
            result += text[index] == "\\" && openRun == 0 ? "\\\\" : String(text[index])
            index = text.index(after: index)
        }
        return result
    }
}

/// Customer wording for chat failure codes. Unknown codes get generic text.
public enum ChatFailureText {
    public static func message(for code: String) -> String {
        switch code {
        case "insufficient_credits": "Not enough credits for this answer. Your question is saved."
        case "platform_budget_exhausted": "AI answers are paused right now. Your papers and saved chats still work."
        case "rate_limited": "Too many requests right now. Try again in a moment."
        case "document_unavailable": "This paper isn’t ready for questions yet. Try again after it finishes processing."
        case "provider_unavailable": "The AI service couldn’t finish this answer. Try again."
        // Ours to fix, for every model alike (the gateway’s key or balance, or our server): a quick retry can’t help.
        case "service_unavailable": "AI answers are unavailable right now. Try again in a few minutes."
        case "model_unavailable": "This AI model isn’t available right now. Your AI credits were not charged. Choose another model in AI options, or try again later."
        case "refused": "This request can’t be answered. Try rephrasing your question."
        case "invalid_request": "This conversation couldn’t be sent. Try starting a new chat."
        case "operation_replayed": "This answer was already requested. Try again to request a new one."
        case "authentication_required": "Sign in again to get answers."
        case "transport": "The connection was interrupted before the answer finished."
        // docs/reviews/OFFLINE_AND_STORAGE_20261025.md: the request never reached Gradstep, so nothing was asked or charged.
        case "offline": "You’re offline. Your question is saved; try again when you’re connected."
        case "unreachable": "Couldn’t reach Gradstep. Your question is saved; try again in a moment."
        case "network_sign_in": "This Wi‑Fi needs you to sign in. Open Safari to sign in, then try again. Your question is saved."
        case "local_mac_only": "Local models are available in Gradstep for Mac. Choose a cloud model to continue here. Your question is saved."
        case "local_model_missing": "Download a model from the Local AI choice before asking. Your question is saved."
        case "local_model_invalid": "The local model failed verification. Remove its download and download it again."
        case "local_image_unsupported": "This model reads text only. Choose a vision model to discuss figures."
        case "local_image_invalid": "This figure could not be prepared for Local AI. Try opening the figure again."
        case "local_memory": "There is not enough app memory for this model right now. Choose a smaller local model."
        case "local_timeout": "The local model took too long. Your question is saved. Try a smaller model or a narrower question."
        case "local_interrupted": "Local inference stopped before it finished. Keep the app open while it answers, or try a smaller model."
        case "local_context_large": "The question, selection or images exceed the local context limit. Use a shorter question or one figure."
        case "local_action_unsupported": "This action needs cloud search or tools. Choose Cloud AI to use it."
        case "local_busy": "Another local answer is running. Stop it or wait for it to finish."
        case "local_unavailable": "Local inference requires an Apple Silicon device with Metal. It is unavailable in the Simulator."
        case "local_length": "The local answer reached its length limit. Ask a narrower question to continue."
        case "local_failed": "The local model could not finish. Try a smaller model or shorter question."
        default: "The answer couldn’t be completed. Try again."
        }
    }

    /// Whether retrying the same question can reasonably succeed.
    public static func isRetryable(_ code: String) -> Bool {
        !["invalid_request", "refused", "model_unavailable", "local_image_unsupported", "local_action_unsupported", "local_unavailable", "local_context_large", "local_memory", "local_mac_only"].contains(code)
    }
}

/// Follow-up questions an answer suggests (2026-10-14): at most three one-line questions of 3–120 characters,
/// cleaned the way the browser cleans them. They are shown as one-tap suggestions and never persisted.
public enum ChatFollowUps {
    public static let maximum = 3
    public static let maximumCharacters = 120
    public static func clean(_ raw: [String]) -> [String] {
        var result: [String] = []
        for value in raw {
            let scalars = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
            let text = scalars.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard text.count >= 3, text.count <= maximumCharacters, !result.contains(where: { $0.lowercased() == text.lowercased() }) else { continue }
            result.append(text)
            if result.count == maximum { break }
        }
        return result
    }
}

/// Conversation topic titles (owner feedback, TestFlight build 21): written by the chat service alongside an answer, or
/// typed by the reader when renaming. Kept in the encrypted history as a conversation revision (`titleSource`).
public enum ChatTopicTitle {
    public static let maximumCharacters = 80

    /// One plain line of at most 80 characters (control and bidirectional-override characters removed, whitespace
    /// collapsed); nil when nothing is left.
    public static func clean(_ text: String) -> String? {
        let scalars = text.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar) || (0x200B...0x200F).contains(scalar.value) || (0x2028...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value) ? " " : String(scalar)
        }.joined()
        let line = scalars.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        guard line.count > maximumCharacters else { return line }
        // A typed name longer than the limit keeps its first 80 characters.
        return String(line.prefix(maximumCharacters)).trimmingCharacters(in: .whitespaces)
    }
}


/// Any JSON value, re-encoded as it was received (an object's keys kept): how a nested document reaches a validator
/// that reads raw JSON.
struct AnyJSON: Codable {
    let value: Any
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull() }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let string = try? container.decode(String.self) { value = string }
        else if let array = try? container.decode([AnyJSON].self) { value = array.map(\.value) }
        else if let object = try? container.decode([String: AnyJSON].self) { value = object.mapValues(\.value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON") }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull: try container.encodeNil()
        case let bool as Bool: try container.encode(bool)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let string as String: try container.encode(string)
        case let array as [Any]: try container.encode(array.map(AnyJSON.init(value:)))
        case let object as [String: Any]: try container.encode(object.mapValues(AnyJSON.init(value:)))
        default: throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Unsupported JSON"))
        }
    }
    init(value: Any) { self.value = value }
}
