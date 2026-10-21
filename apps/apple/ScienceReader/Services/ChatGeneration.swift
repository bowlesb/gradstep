import Foundation
import ScienceReaderCore

/// Streams one metered answer. `BackendClient` is the production transport; a
/// Debug Simulator fixture replaces it for deterministic UI journeys.
protocol ChatTransport: Sendable {
    func chatStream(_ request: ChatGenerationRequest, accountID: UUID) async throws -> AsyncThrowingStream<ChatStreamEvent, Error>
    func creditBalance(accountID: UUID) async throws -> CreditBalance
    /// The server's chat profile table (2026-10-08); throws when the server offers none.
    func chatProfiles(accountID: UUID) async throws -> ChatProfileTable
    /// The reader pressed Stop on this answer (2026-10-16): it is charged for the part written; any other early end isn't.
    func recordStop(operationID: UUID, accountID: UUID) async throws
}

extension ChatTransport {
    func recordStop(operationID: UUID, accountID: UUID) async throws {}
}

extension BackendClient: ChatTransport {
    func recordStop(operationID: UUID, accountID: UUID) async throws {
        struct Params: Encodable, Sendable { let p_operation_id: String }
        struct Ignored: Decodable, Sendable { init(from decoder: Decoder) throws {} }
        _ = try await rpc("v1_chat_stop", params: Params(p_operation_id: operationID.wire), accountID: accountID, as: Ignored.self)
    }
}

/// Every answer has an end (docs/architecture/RESILIENCE.md, "bounded time everywhere"): a stream that sends nothing for
/// `idle` — the server pings every 15 s — ends with the connection-interrupted message instead of an endless spinner.
/// Wraps any transport, so the fixture and the live one behave the same.
struct IdleBoundedChatTransport: ChatTransport {
    let base: any ChatTransport
    let idle: Duration

    func chatStream(_ request: ChatGenerationRequest, accountID: UUID) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let source = try await base.chatStream(request, accountID: accountID)
        let idle = self.idle
        return AsyncThrowingStream { continuation in
            let lastEvent = LastEvent()
            let forward = Task {
                do {
                    for try await event in source { await lastEvent.touch(); continuation.yield(event) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            let watchdog = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: idle / 4)
                    if await lastEvent.silent(longerThan: idle) {
                        forward.cancel(); continuation.finish(throwing: ChatTransportError.rejected("transport")); return
                    }
                }
            }
            continuation.onTermination = { _ in forward.cancel(); watchdog.cancel() }
        }
    }
    func creditBalance(accountID: UUID) async throws -> CreditBalance { try await base.creditBalance(accountID: accountID) }
    func chatProfiles(accountID: UUID) async throws -> ChatProfileTable { try await base.chatProfiles(accountID: accountID) }
    func recordStop(operationID: UUID, accountID: UUID) async throws { try await base.recordStop(operationID: operationID, accountID: accountID) }

    private actor LastEvent {
        private var at = ContinuousClock.now
        func touch() { at = .now }
        func silent(longerThan idle: Duration) -> Bool { ContinuousClock.now - at > idle }
    }
}

enum ChatTransportError: Error, Equatable {
    /// A stable server code (docs/architecture/CHAT.md), never response text.
    case rejected(String)
}

struct CreditBalance: Decodable, Equatable, Sendable {
    let available: Int64
    let reserved: Int64
    let unlimitedTesting: Bool?

    init(available: Int64, reserved: Int64, unlimitedTesting: Bool? = nil) {
        self.available = available; self.reserved = reserved; self.unlimitedTesting = unlimitedTesting
    }
    enum CodingKeys: String, CodingKey {
        case available, reserved
        case unlimitedTesting = "unlimited_testing"
    }
    var availableLabel: String { unlimitedTesting == true ? "Unlimited testing" : "\(available.formatted()) credits" }
}

/// Per-account cloud-AI consent, kept in the device Keychain (not in chat
/// history, and never alongside plaintext). One record per environment/account.
struct ChatConsentLedger: Sendable {
    let environment: String
    let store: any AuthenticationCredentialStore

    func hasAccepted(_ accountID: UUID) -> Bool {
        guard let stored = try? store.read(name(accountID)) else { return false }
        return stored == Data(ChatGenerationRequest.consentVersion.utf8)
    }

    func accept(_ accountID: UUID) throws {
        try store.write(Data(ChatGenerationRequest.consentVersion.utf8), name: name(accountID))
    }

    private func name(_ accountID: UUID) -> String { "\(environment).\(accountID.wire).cloud-ai-consent" }
}

/// A saved question awaiting first-use consent. Accepting requests an answer
/// for exactly this captured turn, in its own conversation.
struct ChatConsentPrompt: Identifiable, Sendable {
    let id = UUID()
    let turn: ChatAnswerTurn
}

/// The saved user message an answer belongs to. Every write and presentation
/// is bound to these identities, never to whichever chat is visible later.
struct ChatAnswerTurn: Equatable, Sendable {
    let sessionID: UUID
    let accountID: UUID
    let deviceID: UUID
    let composerID: UUID
    let conversationID: UUID
    let documentID: UUID?
    let userMessageID: UUID
    let selection: String?
    var action: ChatAction? = nil
    /// The chat's model, effort and length when Send was pressed (2026-10-08); a retry asks with the same.
    var profile: ChatProfileChoice? = nil
    var paperReference: SourcePaperReference? = nil
    /// Study: the knowledge map this turn answers against (memory only; a retry sends the same map).
    var study: StudyMap? = nil
    /// Captured at Send; retry/stop can never switch between local inference and a paid cloud request.
    var localModelID: String? = nil
}

/// One in-flight answer. The assistant ID is allocated before streaming so the
/// transient row and the sealed encrypted message share an identity.
struct ChatGeneration: Sendable {
    let id: UUID
    let turn: ChatAnswerTurn
    let assistantID: UUID
    var text = ""
    var stopping = false
    var task: Task<Void, Never>?
    /// The request on its way (a figure's second request has its own): what a Stop names to the server.
    var operationID: UUID?
    /// The chat profile this answer was asked with (sent when not the default).
    var profile: ChatProfileChoice = .standard
    /// The figures sent with the question and the bundle they came from, so the answer's figure parts can be cropped.
    var figures: [ChatFigureImage] = []
    var figureManifest: String?
    /// The request carried choices (the server published its profile table).
    var sentProfile = false
    /// Nothing sent yet: the question waits for its paper to be prepared on this device (Stop just withdraws it).
    var waitingForPaper = false
    /// The model and profile the server reported in `done`, saved with the answer.
    var answeredModel: String?
    var answeredProfile: String?
    /// The profile saved with the answer: the server's report, else (an interrupted answer) the one it was asked with.
    var labelProfile: String? { answeredProfile ?? (sentProfile ? profile.id : nil) }
    /// The answer's time in history ("Last used"), fixed when it starts so every save of it is the same event.
    let createdAt: Int64

    init(turn: ChatAnswerTurn, now: Date = Date()) {
        id = UUID(); self.turn = turn; assistantID = UUID(); createdAt = PrivateEvent.timestamp(now)
    }

    func event(text: String, status: PrivateEvent.TurnStatus, model: String? = nil, profile: String? = nil) -> PrivateEvent {
        PrivateEvent(kind: .message, entityID: assistantID, parents: [turn.userMessageID], conversationID: turn.conversationID,
                     documentID: turn.documentID, text: text, role: .assistant, status: status, createdAt: createdAt,
                     model: model, profile: profile, paperReference: turn.paperReference)
    }
}

/// A question's paper couldn't be prepared on this device: why (ReaderModel.preparationReason).
struct ChatPreparationFailure: Error { let reason: String }

struct ChatAnswerIssue: Equatable, Sendable {
    let turn: ChatAnswerTurn
    let code: String
    /// What the failed answer cost, when the server said (0: the provider never started it; servers from 2026-10-14).
    var credits: Int? = nil
    /// `reader_unprepared`: why the paper couldn't be prepared on this device (build 78).
    var detail: String? = nil
    var message: String {
        switch code {
        // Asking prepares the paper on this device (build 78); this is left for a paper this device can't prepare at all.
        case "local_reader_unavailable": "This paper can’t be read on this device yet, so no answer was requested. Try again in a moment."
        case "reader_unprepared": "\(detail ?? "This paper couldn’t be prepared on this device.") No answer was requested; your question is saved."
        case "consent_declined", "answer_withdrawn": "Your question is saved. No answer was requested."
        case "consent_unsaved": "Your choice couldn’t be saved on this device. Try again."
        case "storage": "The answer couldn’t be saved on this device. Try again saves it; it isn’t asked for again."
        case "diagram_storage": "The answer was saved, but its diagram couldn’t be: this device’s unsynced storage is full."
        default: credits == 0 ? ChatFailureText.message(for: code) + " No credits were used." : ChatFailureText.message(for: code)
        }
    }
    /// A kept answer whose diagram could not be stored is informational; asking
    /// again would be a new paid answer.
    var retryable: Bool {
        code != "diagram_storage" && (["consent_declined", "answer_withdrawn", "consent_unsaved", "storage", "local_reader_unavailable", "reader_unprepared"].contains(code) || ChatFailureText.isRetryable(code))
    }
    var actionTitle: String { code == "consent_declined" || code == "answer_withdrawn" ? "Get answer" : "Try again" }
}

enum ChatGenerationOutcome: Equatable, Sendable {
    case completed(stopReason: String)
    case failed(code: String)
    case cancelled
}

extension ChatGenerationOutcome {
    /// What to keep locally: complete text, an explicitly interrupted partial,
    /// or nothing. A refusal's partial output is discarded, not kept.
    func resolution(text: String) -> (status: PrivateEvent.TurnStatus?, issue: String?) {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch self {
        case .completed(let stopReason):
            if empty { return (nil, "provider_unavailable") }
            return (["end_turn", "stop_sequence"].contains(stopReason) ? .complete : .interrupted, nil)
        case .failed(let code):
            if code == "refused" { return (nil, code) }
            return (empty ? nil : .interrupted, code)
        case .cancelled:
            return (empty ? nil : .interrupted, nil)
        }
    }
}

extension String {
    /// Bounded by the encrypted event limit (UTF-8 bytes) on a character boundary.
    func boundedForPrivateEvent(maximumBytes: Int = 200_000) -> String {
        guard utf8.count > maximumBytes else { return self }
        var result = "", bytes = 0
        for character in self {
            let size = String(character).utf8.count
            guard bytes + size <= maximumBytes else { break }
            result.append(character); bytes += size
        }
        return result
    }
}
