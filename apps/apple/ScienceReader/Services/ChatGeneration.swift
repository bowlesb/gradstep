import Foundation
import ScienceReaderCore

/// Streams one metered answer. `BackendClient` is the production transport; a
/// Debug Simulator fixture replaces it for deterministic UI journeys.
protocol ChatTransport: Sendable {
    func chatStream(_ request: ChatGenerationRequest, accountID: UUID) async throws -> AsyncThrowingStream<ChatStreamEvent, Error>
    func creditBalance(accountID: UUID) async throws -> CreditBalance
}

extension BackendClient: ChatTransport {}

enum ChatTransportError: Error, Equatable {
    /// A stable server code (docs/architecture/CHAT.md), never response text.
    case rejected(String)
}

struct CreditBalance: Decodable, Equatable, Sendable {
    let available: Int64
    let reserved: Int64
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

    init(turn: ChatAnswerTurn) {
        id = UUID(); self.turn = turn; assistantID = UUID()
    }

    func event(text: String, status: PrivateEvent.TurnStatus) -> PrivateEvent {
        PrivateEvent(kind: .message, entityID: assistantID, parents: [turn.userMessageID], conversationID: turn.conversationID,
                     documentID: turn.documentID, text: text, role: .assistant, status: status)
    }
}

struct ChatAnswerIssue: Equatable, Sendable {
    let turn: ChatAnswerTurn
    let code: String
    var message: String {
        switch code {
        case "consent_declined": "Your question is saved. No answer was requested."
        case "consent_unsaved": "Your choice couldn’t be saved on this device. Try again."
        case "storage": "The answer couldn’t be saved on this device."
        default: ChatFailureText.message(for: code)
        }
    }
    var retryable: Bool { ["consent_declined", "consent_unsaved", "storage"].contains(code) || ChatFailureText.isRetryable(code) }
    var actionTitle: String { code == "consent_declined" ? "Get answer" : "Try again" }
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
