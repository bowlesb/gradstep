import Foundation
import ScienceReaderCore

/// Composer presentation and its bridge to device-local encrypted checkpoints.
/// Pending operations stay in memory and own their original composer.
struct ChatWorkspace {
    enum DraftStatus: Equatable {
        case memoryOnly, changed, saving, saved, failed(String)
    }
    struct Checkpoint: Sendable {
        let id: UUID
        let ownerID: UUID
        let draft: LocalDraft
        var composerID: UUID { draft.id }
        var revision: Int64 { draft.revision }
    }
    struct Discard: Sendable {
        let id: UUID
        let ownerID: UUID
        let composerID: UUID
        let revision: Int64
    }
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
        let checkpoint: LocalDraft?
    }
    private struct Composer {
        let context: String
        var conversationID: UUID?
        var draft = ""
        var revision = UUID()
        var checkpointRevision: Int64 = 1
        var selectedHead: UUID?
        var branchRevision = UUID()
        var acknowledgedSubmissionID: UUID?
        var pending: UUID?
        var pendingConversation: UUID?
        var saved = false
        var failed = false
        var editedAt = Date()
        var hasEditedText = false
        var persisted: LocalDraft?
        var tracksCheckpoints = false
        var checkpointAttempt: Checkpoint?
        var checkpointFailure: (revision: Int64, message: String)?
        var discardAttempt: UUID?
    }
    private let ownerID = UUID()
    private var selection: [String: UUID] = [:]
    private var selectionIntents: Set<String> = []
    private var composers: [UUID: Composer] = [:]
    private var conversationComposers: [UUID: UUID] = [:]
    private var discarded: Set<UUID> = []
    private var deletedConversations: Set<UUID> = []

    func composerID(in context: String) -> UUID? { selection[context] }
    func conversation(in context: String) -> UUID? { selected(in: context).flatMap { $0.conversationID ?? $0.pendingConversation } }
    func draft(in context: String) -> String { selected(in: context)?.draft ?? "" }
    func isSaving(in context: String) -> Bool { selected(in: context)?.pending != nil }
    func isDiscarding(in context: String) -> Bool { selected(in: context)?.discardAttempt != nil }
    func hasSaved(in context: String) -> Bool { selected(in: context)?.saved ?? false }

    mutating func setDeletedConversations(_ conversations: Set<UUID>) {
        deletedConversations = conversations
    }

    func draftStatus(in context: String) -> DraftStatus {
        guard let id = selection[context], let composer = composers[id], composer.tracksCheckpoints else { return .memoryOnly }
        if composer.checkpointAttempt?.revision == composer.checkpointRevision { return .saving }
        if let failure = composer.checkpointFailure, failure.revision == composer.checkpointRevision { return .failed(failure.message) }
        return checkpoint(for: id) == composer.persisted ? .saved : .changed
    }

    var checkpoints: [LocalDraft] {
        composers.keys.compactMap { checkpoint(for: $0) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func checkpoint(in context: String) -> LocalDraft? {
        selection[context].flatMap { checkpoint(for: $0) }
    }

    func checkpoint(for composerID: UUID) -> LocalDraft? {
        guard let composer = composers[composerID] else { return nil }
        return checkpoint(composerID, composer)
    }

    @discardableResult
    mutating func recordSelectedHead(_ head: UUID?, for composerID: UUID, explicit: Bool = false) -> LocalDraft? {
        guard var composer = composers[composerID] else { return nil }
        guard explicit || composer.selectedHead != head else { return checkpoint(for: composerID) }
        composer.selectedHead = head
        if explicit { composer.branchRevision = UUID(); composer.editedAt = Date() }
        composer.checkpointRevision += 1
        composers[composerID] = composer
        return checkpoint(for: composerID)
    }

    mutating func beginCheckpoint(for composerID: UUID) -> Checkpoint? {
        guard let composer = composers[composerID], let draft = checkpoint(for: composerID), composer.discardAttempt == nil else { return nil }
        guard draft != composer.persisted || composer.checkpointFailure != nil else { return nil }
        guard composer.conversationID != nil || composer.persisted != nil || composer.pending != nil
                || composer.hasEditedText || !composer.draft.isEmpty else { return nil }
        let token = Checkpoint(id: UUID(), ownerID: ownerID, draft: draft)
        composers[composerID]?.tracksCheckpoints = true
        composers[composerID]?.checkpointAttempt = token
        composers[composerID]?.checkpointFailure = nil
        return token
    }

    mutating func acknowledge(_ token: Checkpoint, stored: LocalDraft) {
        guard token.ownerID == ownerID, stored.id == token.composerID,
              var composer = composers[token.composerID], sameContext(composer, stored) else { return }
        merge(stored, into: &composer, id: token.composerID)
        if composer.checkpointAttempt?.id == token.id {
            composer.checkpointAttempt = nil
            composer.checkpointFailure = nil
        }
        composers[token.composerID] = composer
        rememberConversation(token.composerID)
    }

    mutating func failCheckpoint(_ token: Checkpoint, message: String) {
        guard token.ownerID == ownerID, composers[token.composerID]?.checkpointAttempt?.id == token.id else { return }
        composers[token.composerID]?.checkpointAttempt = nil
        composers[token.composerID]?.checkpointFailure = (token.revision, message)
    }

    /// Restore without choosing over a live selection, including an intentionally
    /// empty New Chat. All other unsent or displaced drafts remain reachable.
    mutating func restore(_ drafts: [LocalDraft]) {
        let ordered = drafts.sorted {
            if $0.editedAt != $1.editedAt { return $0.editedAt > $1.editedAt }
            if $0.revision != $1.revision { return $0.revision > $1.revision }
            return $0.id.uuidString < $1.id.uuidString
        }
        for draft in ordered where !discarded.contains(draft.id) {
            guard draft.revision > 0 else { continue }
            if var composer = composers[draft.id] {
                guard sameContext(composer, draft) else { continue }
                merge(draft, into: &composer, id: draft.id)
                composers[draft.id] = composer
            } else {
                var composer = Composer(context: context(for: draft), conversationID: draft.conversationID)
                assign(draft, to: &composer)
                composer.persisted = draft; composer.tracksCheckpoints = true
                composer.saved = draft.acknowledgedSubmissionID != nil
                composers[draft.id] = composer
            }
            rememberConversation(draft.id)
        }
        for draft in ordered {
            guard let composer = composers[draft.id], selection[composer.context] == nil,
                  !selectionIntents.contains(composer.context) else { continue }
            selection[composer.context] = draft.id
        }
    }

    /// What the chat screens show apart from draft text: each context's composer, the composers' conversations, saves and
    /// discards in progress, saved/failed marks, a draft save failure and the branch each follows. Typing changes none of
    /// it, so it is observed apart from the text (NATIVE_REVIEW_20261021 C6).
    struct Shape: Equatable {
        fileprivate struct Composer: Equatable {
            let conversation: UUID?, pendingConversation: UUID?, selectedHead: UUID?
            let submitting: Bool, discarding: Bool, saved: Bool, failed: Bool, failure: String?
        }
        fileprivate let selection: [String: UUID]
        fileprivate let composers: [UUID: Composer]
        fileprivate let conversationComposers: [UUID: UUID]
        fileprivate let deleted: Set<UUID>
    }
    var shape: Shape {
        Shape(selection: selection, composers: composers.mapValues { c in
            // As `draftStatus`: a failure counts while nothing newer is being saved or typed.
            let failure = c.tracksCheckpoints && c.checkpointAttempt?.revision != c.checkpointRevision
                ? c.checkpointFailure.flatMap { $0.revision == c.checkpointRevision ? $0.message : nil } : nil
            return Shape.Composer(conversation: c.conversationID, pendingConversation: c.pendingConversation, selectedHead: c.selectedHead,
                                  submitting: c.pending != nil, discarding: c.discardAttempt != nil, saved: c.saved, failed: c.failed,
                                  failure: failure)
        }, conversationComposers: conversationComposers, deleted: deletedConversations)
    }

    var unsentDrafts: [UnsentDraft] {
        composers.compactMap { id, composer -> UnsentDraft? in
            let displaced = composer.conversationID.map { conversationComposers[$0] != id || deletedConversations.contains($0) } ?? true
            guard displaced, composer.pending == nil,
                  !composer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return UnsentDraft(id: id, context: composer.context, text: composer.draft,
                               failed: composer.failed, editedAt: composer.editedAt)
        }.sorted { $0.editedAt == $1.editedAt ? $0.id.uuidString < $1.id.uuidString : $0.editedAt > $1.editedAt }
    }

    mutating func selectDraft(_ id: UUID) -> String? {
        guard unsentDrafts.contains(where: { $0.id == id }), let composer = composers[id] else { return nil }
        selection[composer.context] = id
        selectionIntents.insert(composer.context)
        composers[id]?.checkpointRevision += 1
        composers[id]?.editedAt = Date()
        if let conversation = composer.conversationID { conversationComposers[conversation] = id }
        return composer.context
    }

    mutating func discardDraft(_ id: UUID) {
        guard unsentDrafts.contains(where: { $0.id == id }) else { return }
        removeComposer(id)
    }

    mutating func prepareDiscard(_ id: UUID) -> Discard? {
        guard unsentDrafts.contains(where: { $0.id == id }), let composer = composers[id], composer.discardAttempt == nil else { return nil }
        let token = Discard(id: UUID(), ownerID: ownerID, composerID: id, revision: composer.checkpointRevision)
        composers[id]?.discardAttempt = token.id
        return token
    }

    /// An accepted durable deletion retires the old ID. Edits made while it was
    /// pending move to a fresh ID, since storage rejects a tombstoned composer.
    @discardableResult
    mutating func completeDiscard(_ token: Discard) -> UUID? {
        guard token.ownerID == ownerID, var composer = composers[token.composerID], composer.discardAttempt == token.id else { return nil }
        if composer.checkpointRevision == token.revision {
            removeComposer(token.composerID)
            return nil
        }
        let replacement = UUID()
        composer.discardAttempt = nil; composer.persisted = nil
        composer.checkpointAttempt = nil; composer.checkpointFailure = nil
        composer.acknowledgedSubmissionID = nil
        composer.checkpointRevision += 1
        composers[replacement] = composer
        if selection[composer.context] == token.composerID { selection[composer.context] = replacement }
        if let conversation = composer.conversationID, conversationComposers[conversation] == token.composerID {
            conversationComposers[conversation] = replacement
        }
        composers.removeValue(forKey: token.composerID); discarded.insert(token.composerID)
        return replacement
    }

    mutating func failDiscard(_ token: Discard) {
        guard token.ownerID == ownerID, composers[token.composerID]?.discardAttempt == token.id else { return }
        composers[token.composerID]?.discardAttempt = nil
    }

    /// The context's composer, created (empty) when there is none yet: a choice made in the chat before typing
    /// belongs to it.
    mutating func composer(in context: String) -> UUID { ensureComposer(in: context) }

    mutating func setDraft(_ text: String, in context: String) {
        let id = ensureComposer(in: context)
        composers[id]?.draft = text
        composers[id]?.hasEditedText = true
        // Even an edit back to identical text is a newer user action.
        composers[id]?.revision = UUID()
        composers[id]?.checkpointRevision += 1
        composers[id]?.editedAt = Date()
    }

    mutating func select(_ conversation: UUID?, in context: String) {
        selectionIntents.insert(context)
        if let conversation, let existing = conversationComposers[conversation], composers[existing]?.context == context {
            selection[context] = existing
            composers[existing]?.checkpointRevision += 1
            composers[existing]?.editedAt = Date()
        } else {
            let id = UUID()
            composers[id] = Composer(context: context, conversationID: conversation)
            selection[context] = id
            if let conversation { conversationComposers[conversation] = id }
        }
    }

    mutating func beginSubmission(in context: String) -> Submission? {
        let id = ensureComposer(in: context)
        guard let composer = composers[id], composer.pending == nil, composer.discardAttempt == nil else { return nil }
        let text = composer.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let ticket = Submission(id: UUID(), composerID: id,
                                conversationID: composer.conversationID ?? UUID(),
                                rootID: composer.conversationID == nil ? UUID() : nil,
                                draftRevision: composer.revision, text: text, checkpoint: checkpoint(for: id))
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
        composers[ticket.composerID]?.checkpointRevision += 1
        // Deliberately do not change selection: this may now be in history.
    }

    /// Complete from the transaction's canonical checkpoint, not the captured
    /// draft. A later identical edit or explicit branch choice still wins.
    @discardableResult
    mutating func complete(_ ticket: Submission, stored: LocalDraft, receiptID: UUID) -> Bool {
        guard receiptID == ticket.id, stored.id == ticket.composerID,
              stored.conversationID == ticket.conversationID,
              var composer = composers[ticket.composerID], composer.pending == ticket.id,
              sameContext(composer, stored) else { return false }
        let textUnchanged = composer.revision == ticket.draftRevision
        let explicitChoiceUnchanged = ticket.checkpoint?.branchRevision == composer.branchRevision
        let receiptAlreadyObserved = composer.acknowledgedSubmissionID == receiptID
        merge(stored, into: &composer, id: ticket.composerID)
        composer.conversationID = stored.conversationID
        if textUnchanged {
            composer.draft = stored.text
            composer.revision = stored.text.isEmpty ? UUID() : stored.textRevision
        }
        if explicitChoiceUnchanged && !receiptAlreadyObserved { composer.selectedHead = stored.selectedHead }
        composer.acknowledgedSubmissionID = receiptID
        // The later checkpoint acknowledges the receipt and permits subsequent
        // automatically observed branch heads to advance again.
        composer.checkpointRevision = max(composer.checkpointRevision, stored.revision) + 1
        composer.pending = nil; composer.pendingConversation = nil
        composer.saved = true; composer.failed = false
        composers[ticket.composerID] = composer
        conversationComposers[ticket.conversationID] = ticket.composerID
        return true
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

    private func context(for draft: LocalDraft) -> String {
        draft.documentID.map { "paper/\($0.uuidString.lowercased())" } ?? "general"
    }

    private func sameContext(_ composer: Composer, _ draft: LocalDraft) -> Bool {
        composer.context == context(for: draft)
    }

    private func checkpoint(_ id: UUID, _ composer: Composer) -> LocalDraft? {
        let document = composer.context.hasPrefix("paper/") ? UUID(uuidString: String(composer.context.dropFirst(6))) : nil
        guard composer.context == "general" || document != nil else { return nil }
        return LocalDraft(id: id, documentID: document, conversationID: composer.conversationID,
            revision: composer.checkpointRevision, textRevision: composer.revision, text: composer.draft,
            editedAt: composer.editedAt, selectedHead: composer.selectedHead, branchRevision: composer.branchRevision,
            acknowledgedSubmissionID: composer.acknowledgedSubmissionID)
    }

    private func assign(_ draft: LocalDraft, to composer: inout Composer) {
        composer.conversationID = draft.conversationID; composer.draft = draft.text
        composer.revision = draft.textRevision; composer.checkpointRevision = draft.revision
        composer.editedAt = draft.editedAt; composer.selectedHead = draft.selectedHead
        composer.branchRevision = draft.branchRevision; composer.acknowledgedSubmissionID = draft.acknowledgedSubmissionID
        composer.hasEditedText = true
    }

    private func merge(_ stored: LocalDraft, into composer: inout Composer, id: UUID) {
        guard stored.revision >= (composer.persisted?.revision ?? 0) else { return }
        let before = checkpoint(id, composer)
        let pristine = before == composer.persisted && composer.pending == nil && composer.discardAttempt == nil
        if pristine {
            assign(stored, to: &composer)
        } else {
            // Matching text identity can be normalized by a committed send;
            // an intervening edit, even to the same string, has a different ID.
            if composer.revision == stored.textRevision { composer.draft = stored.text }
            if composer.conversationID == nil { composer.conversationID = stored.conversationID }
            let newReceipt = stored.acknowledgedSubmissionID != nil && stored.acknowledgedSubmissionID != composer.acknowledgedSubmissionID
            if newReceipt {
                if composer.branchRevision == stored.branchRevision { composer.selectedHead = stored.selectedHead }
                composer.acknowledgedSubmissionID = stored.acknowledgedSubmissionID
            }
            let changed = checkpoint(id, composer) != before
            composer.checkpointRevision = max(composer.checkpointRevision, stored.revision)
            if changed || (checkpoint(id, composer) != stored && composer.checkpointRevision == stored.revision) {
                composer.checkpointRevision += 1
            }
        }
        composer.persisted = stored; composer.tracksCheckpoints = true
    }

    private mutating func rememberConversation(_ id: UUID) {
        guard let conversation = composers[id]?.conversationID else { return }
        if conversationComposers[conversation] == nil { conversationComposers[conversation] = id }
    }

    private mutating func removeComposer(_ id: UUID) {
        guard let composer = composers.removeValue(forKey: id) else { return }
        discarded.insert(id)
        if selection[composer.context] == id {
            selection.removeValue(forKey: composer.context)
            selectionIntents.insert(composer.context)
        }
        if let conversation = composer.conversationID, conversationComposers[conversation] == id {
            conversationComposers.removeValue(forKey: conversation)
        }
    }

    private mutating func ensureComposer(in context: String) -> UUID {
        if let id = selection[context] { return id }
        select(nil, in: context)
        return selection[context]!
    }
}
