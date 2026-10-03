import Foundation

/// Ephemeral composer state. Saved history belongs to EncryptedStore. A pending
/// save owns its original composer even when the user opens another conversation.
struct ChatWorkspace {
    struct UnsentDraft: Identifiable {
        let id: UUID
        let context: String
        let text: String
        let failed: Bool
        let editedAt: Date
    }
    struct Submission: Sendable {
        let id: UUID
        let composerID: UUID
        let conversationID: UUID
        let rootID: UUID?
        let draftRevision: UUID
        let text: String
    }
    private struct Composer {
        let context: String
        var conversationID: UUID?
        var draft = ""
        var revision = UUID()
        var pending: UUID?
        var pendingConversation: UUID?
        var saved = false
        var failed = false
        var editedAt = Date()
    }
    private var selection: [String: UUID] = [:]
    private var composers: [UUID: Composer] = [:]
    private var conversationComposers: [UUID: UUID] = [:]

    func composerID(in context: String) -> UUID? { selection[context] }
    func conversation(in context: String) -> UUID? { selected(in: context).flatMap { $0.conversationID ?? $0.pendingConversation } }
    func draft(in context: String) -> String { selected(in: context)?.draft ?? "" }
    func isSaving(in context: String) -> Bool { selected(in: context)?.pending != nil }
    func hasSaved(in context: String) -> Bool { selected(in: context)?.saved ?? false }

    var unsentDrafts: [UnsentDraft] {
        composers.compactMap { id, composer -> UnsentDraft? in
            guard composer.conversationID == nil, composer.pending == nil,
                  !composer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return UnsentDraft(id: id, context: composer.context, text: composer.draft,
                               failed: composer.failed, editedAt: composer.editedAt)
        }.sorted { $0.editedAt == $1.editedAt ? $0.id.uuidString < $1.id.uuidString : $0.editedAt > $1.editedAt }
    }

    mutating func selectDraft(_ id: UUID) -> String? {
        guard unsentDrafts.contains(where: { $0.id == id }), let composer = composers[id] else { return nil }
        selection[composer.context] = id
        return composer.context
    }

    mutating func discardDraft(_ id: UUID) {
        guard unsentDrafts.contains(where: { $0.id == id }), let composer = composers.removeValue(forKey: id) else { return }
        if selection[composer.context] == id { selection.removeValue(forKey: composer.context) }
    }

    mutating func setDraft(_ text: String, in context: String) {
        let id = ensureComposer(in: context)
        composers[id]?.draft = text
        // Even an edit back to identical text is a newer user action.
        composers[id]?.revision = UUID()
        composers[id]?.editedAt = Date()
    }

    mutating func select(_ conversation: UUID?, in context: String) {
        if let conversation, let existing = conversationComposers[conversation], composers[existing]?.context == context {
            selection[context] = existing
        } else {
            let id = UUID()
            composers[id] = Composer(context: context, conversationID: conversation)
            selection[context] = id
            if let conversation { conversationComposers[conversation] = id }
        }
    }

    mutating func beginSubmission(in context: String) -> Submission? {
        let id = ensureComposer(in: context)
        guard let composer = composers[id], composer.pending == nil else { return nil }
        let text = composer.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let ticket = Submission(id: UUID(), composerID: id,
                                conversationID: composer.conversationID ?? UUID(),
                                rootID: composer.conversationID == nil ? UUID() : nil,
                                draftRevision: composer.revision, text: text)
        composers[id]?.pending = ticket.id
        composers[id]?.failed = false
        composers[id]?.pendingConversation = ticket.conversationID
        conversationComposers[ticket.conversationID] = id
        return ticket
    }

    mutating func complete(_ ticket: Submission) {
        guard composers[ticket.composerID]?.pending == ticket.id else { return }
        composers[ticket.composerID]?.conversationID = ticket.conversationID
        conversationComposers[ticket.conversationID] = ticket.composerID
        if composers[ticket.composerID]?.revision == ticket.draftRevision {
            composers[ticket.composerID]?.draft = ""
            composers[ticket.composerID]?.revision = UUID()
        }
        composers[ticket.composerID]?.pending = nil
        composers[ticket.composerID]?.pendingConversation = nil
        composers[ticket.composerID]?.saved = true
        composers[ticket.composerID]?.failed = false
        // Deliberately do not change selection: this may now be in history.
    }

    mutating func fail(_ ticket: Submission) {
        guard composers[ticket.composerID]?.pending == ticket.id else { return }
        if ticket.rootID != nil, composers[ticket.composerID]?.conversationID == nil,
           conversationComposers[ticket.conversationID] == ticket.composerID {
            conversationComposers.removeValue(forKey: ticket.conversationID)
        }
        composers[ticket.composerID]?.pending = nil
        composers[ticket.composerID]?.pendingConversation = nil
        composers[ticket.composerID]?.failed = true
    }

    private func selected(in context: String) -> Composer? {
        selection[context].flatMap { composers[$0] }
    }

    private mutating func ensureComposer(in context: String) -> UUID {
        if let id = selection[context] { return id }
        select(nil, in: context)
        return selection[context]!
    }
}
