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
public enum ChatAction: String, Equatable, Sendable { case ingest, related, relevance, diagramFix = "diagram_fix" }

public struct ChatGenerationRequest: Equatable, Sendable {
    public static let consentVersion = "cloud-ai-v2"
    public static let maximumTurns = 60
    public static let maximumMessageBytes = 200_000
    public static let maximumSelectionScalars = 4_000

    public let operationID: UUID
    /// Nil for general chat; the paper's document ID for paper chat.
    public let documentID: UUID?
    public let turns: [ChatTurnInput]
    public let selection: String?
    /// Only sent with a selection.
    public let action: ChatAction?

    /// Keeps the newest turns that fit the server bounds. The context always
    /// starts and ends with a user turn; empty turns are skipped.
    public static func make(operationID: UUID, documentID: UUID?, transcript: [ChatTurnInput], selection: String?,
                            action: ChatAction? = nil) throws -> ChatGenerationRequest {
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
        return ChatGenerationRequest(operationID: operationID, documentID: documentID, turns: kept, selection: quote,
                                     action: quote == nil ? nil : action)
    }

    /// A diagram the device's Mermaid could not parse, sent back once for a corrected version: general mode, one turn
    /// (title, Mermaid's error and the source, within the server's 24 KB), no conversation, no paper. The server
    /// meters it like any answer, with a small output allowance.
    public static let maximumRepairBytes = 24_000
    public static func diagramRepair(operationID: UUID, title: String, source: String, error: String) -> ChatGenerationRequest? {
        let message = bounded(error.trimmingCharacters(in: .whitespacesAndNewlines), scalars: 600)
        let text = "Title: \(bounded(title, scalars: 200))\nMermaid error: \(message.isEmpty ? "unknown" : message)\n\n\(source)"
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= maximumRepairBytes else { return nil }
        return ChatGenerationRequest(operationID: operationID, documentID: nil, turns: [ChatTurnInput(role: .user, text: text)],
                                     selection: nil, action: .diagramFix)
    }

    private init(operationID: UUID, documentID: UUID?, turns: [ChatTurnInput], selection: String?, action: ChatAction?) {
        self.operationID = operationID; self.documentID = documentID; self.turns = turns; self.selection = selection; self.action = action
    }

    public func encoded() throws -> Data {
        struct Turn: Encodable { let role: String; let text: String }
        struct Selection: Encodable { let quote: String }
        // Synthesized encoding omits nil optionals (general chat sends no document).
        struct Body: Encodable {
            let operation_id: String
            let consent_version: String
            let mode: String
            let document_id: String?
            let messages: [Turn]
            let selection: Selection?
            let action: String?
            /// Ingest may add web (non-arXiv) papers: this build shows them.
            let capabilities: [String]?
        }
        return try ReaderCrypto.encode(Body(operation_id: operationID.wire, consent_version: Self.consentVersion,
            mode: documentID == nil ? "general" : "paper", document_id: documentID?.wire,
            messages: turns.map { Turn(role: $0.role.rawValue, text: $0.text) }, selection: selection.map(Selection.init), action: action?.rawValue,
            capabilities: action == .ingest ? ["web_import"] : nil))
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
    /// What the server is doing between pieces of text (searching, adding a paper).
    case status(ChatProgress)
    case done(stopReason: String, credits: Int)
    case failure(code: String)
}

/// Server work in progress during an answer (`status` events, server 2026-10-07).
/// Builds without this case ignore the event, as they ignore any unknown name.
public struct ChatProgress: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case searching, reading, findingPaper = "finding_paper", addingPaper = "adding_paper"
        /// The device's own: a diagram that didn't parse is being redrawn (never sent by the server).
        case fixingDiagram = "fixing_diagram"
    }
    public static let maximumQueryCharacters = 200
    public let kind: Kind
    /// The search query, for `searching` only (the reader's own answer; never logged).
    public let query: String?

    public init(kind: Kind, query: String? = nil) {
        self.kind = kind
        let cleaned = query.map { value in
            String(value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        self.query = kind == .searching ? cleaned.flatMap { $0.isEmpty ? nil : String($0.prefix(Self.maximumQueryCharacters)) } : nil
    }

    /// One line under the streaming answer.
    public var text: String {
        switch kind {
        case .searching: query.map { "Searching the web for “\($0)”" } ?? "Searching the web…"
        case .reading: "Reading results…"
        case .findingPaper: "Finding the paper…"
        case .addingPaper: "Adding to your library…"
        case .fixingDiagram: "Fixing the diagram…"
        }
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
        case "status":
            // Informational only: an unknown kind or a malformed status is ignored, never fatal.
            struct Status: Decodable { let kind: String; let query: String? }
            guard let status = try? JSONDecoder().decode(Status.self, from: payload),
                  let kind = ChatProgress.Kind(rawValue: status.kind) else { return nil }
            return .status(ChatProgress(kind: kind, query: status.query))
        case "done":
            struct Done: Decodable { let stop_reason: String; let credits: Int }
            guard let done = try? JSONDecoder().decode(Done.self, from: payload), done.credits >= 0 else { throw ChatStreamError.malformed }
            return .done(stopReason: done.stop_reason, credits: done.credits)
        case "error":
            struct Failure: Decodable { let code: String }
            guard let failure = try? JSONDecoder().decode(Failure.self, from: payload),
                  failure.code.utf8.count <= 64 else { throw ChatStreamError.malformed }
            return .failure(code: failure.code)
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
        case "refused": "This request can’t be answered. Try rephrasing your question."
        case "invalid_request": "This conversation couldn’t be sent. Try starting a new chat."
        case "operation_replayed": "This answer was already requested. Try again to request a new one."
        case "authentication_required": "Sign in again to get answers."
        case "transport": "The connection was interrupted before the answer finished."
        default: "The answer couldn’t be completed. Try again."
        }
    }

    /// Whether retrying the same question can reasonably succeed.
    public static func isRetryable(_ code: String) -> Bool {
        !["invalid_request", "refused"].contains(code)
    }
}
