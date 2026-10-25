import Foundation
import ScienceReaderCore

// Your AI usage (owner, 2026-10-22; docs/architecture/OPERATIONS_AND_BILLING.md "Your AI usage"): the account's own
// metered requests from `v1_ai_usage` (migration 0144), and what this device remembers about where each answer came from
// so a row can say Paper chat / General chat / Explain in Chat and name the paper from the library here.

/// Reads the signed-in account's usage pages. The live backend, the fixture host and the idle wrapper answer it.
protocol AIUsageSource: Sendable {
    func aiUsage(days: Int, activity: AIUsageActivity?, before: AIUsageCursor?, accountID: UUID) async throws -> AIUsagePage
}

/// `aiUsage` is in BackendClient.swift, beside the balance (it uses the client's private authorized request).
extension BackendClient: AIUsageSource {}

extension IdleBoundedChatTransport: AIUsageSource {
    func aiUsage(days: Int, activity: AIUsageActivity?, before: AIUsageCursor?, accountID: UUID) async throws -> AIUsagePage {
        guard let source = base as? any AIUsageSource else { throw ChatTransportError.rejected("unavailable") }
        return try await source.aiUsage(days: days, activity: activity, before: before, accountID: accountID)
    }
}

/// The cloud chat transport, remembering on this device which conversation kind and paper each operation was for, just
/// before it is sent (titles are never stored or sent: the usage screen looks them up in the library).
struct UsageRecordingChatTransport: ChatTransport, AIUsageSource {
    let base: any ChatTransport
    let environment: String

    func chatStream(_ request: ChatGenerationRequest, accountID: UUID) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        if !request.isLocalInference {
            AIUsageProvenanceStore(environment: environment, accountID: accountID).remember(request.operationID, AIUsageProvenance(request))
        }
        return try await base.chatStream(request, accountID: accountID)
    }
    func creditBalance(accountID: UUID) async throws -> CreditBalance { try await base.creditBalance(accountID: accountID) }
    func chatProfiles(accountID: UUID) async throws -> ChatProfileTable { try await base.chatProfiles(accountID: accountID) }
    func recordStop(operationID: UUID, accountID: UUID) async throws { try await base.recordStop(operationID: operationID, accountID: accountID) }
    func aiUsage(days: Int, activity: AIUsageActivity?, before: AIUsageCursor?, accountID: UUID) async throws -> AIUsagePage {
        guard let source = base as? any AIUsageSource else { throw ChatTransportError.rejected("unavailable") }
        return try await source.aiUsage(days: days, activity: activity, before: before, accountID: accountID)
    }
}

extension ReaderModel {
    /// The usage reader for the signed-in account, when the server can be asked.
    var aiUsageSource: (any AIUsageSource)? { chatTransport as? any AIUsageSource }

    /// What this device remembers for the signed-in account (nothing while signed out).
    func aiUsageProvenance() -> [UUID: AIUsageProvenance] {
        guard let accountID else { return [:] }
        return AIUsageProvenanceStore(environment: usageEnvironment, accountID: accountID).all()
    }

    /// The paper's title in this device's library, or nil (an operation from another device, or a paper since removed).
    func aiUsagePaperTitle(_ provenance: AIUsageProvenance?) -> String? {
        guard let provenance else { return nil }
        if let membership = provenance.membershipID.flatMap(UUID.init(uuidString:)) {
            if let paper = papers.first(where: { $0.sourceMembership?.membershipID == membership }) { return paper.title }
            // A PDF the reader added: its id on this device (LocalPaperChatContext(ownPDF:); never sent).
            if let paper = papers.first(where: { $0.isLocalPDF && $0.id == membership }) { return paper.title }
            if let item = completeLibrary?.imports.first(where: { $0.id == membership && $0.visible }) { return item.metadata?.title ?? "Untitled paper" }
        }
        if let document = provenance.documentID, let paper = papers.first(where: { $0.id == document }) { return paper.title }
        return nil
    }
}
