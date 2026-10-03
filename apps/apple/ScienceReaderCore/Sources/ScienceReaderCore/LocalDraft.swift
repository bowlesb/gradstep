import Foundation

/// A device-local encrypted composer checkpoint. Revisions are monotonic within
/// one composer; text and explicit branch choices have independent identities.
/// This type is not a cloud event and does not promise cross-device draft sync.
public struct LocalDraft: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let documentID: UUID?
    public var conversationID: UUID?
    public var revision: Int64
    public var textRevision: UUID
    public var text: String
    public var editedAt: Date
    public var selectedHead: UUID?
    public var branchRevision: UUID
    /// Set to a successful submission's receipt when the composer has observed
    /// its result. Older checkpoints cannot undo that submission's branch head.
    public var acknowledgedSubmissionID: UUID?

    public init(id: UUID, documentID: UUID? = nil, conversationID: UUID? = nil,
                revision: Int64, textRevision: UUID, text: String, editedAt: Date,
                selectedHead: UUID? = nil, branchRevision: UUID,
                acknowledgedSubmissionID: UUID? = nil) {
        self.id = id; self.documentID = documentID; self.conversationID = conversationID
        self.revision = revision; self.textRevision = textRevision; self.text = text; self.editedAt = editedAt
        self.selectedHead = selectedHead; self.branchRevision = branchRevision
        self.acknowledgedSubmissionID = acknowledgedSubmissionID
    }
}

/// The exact checkpoint captured by a local send. Use the user message's event
/// ID for submissionID, and retain it for an exact retry of this operation.
public struct DraftConsumption: Equatable, Sendable {
    public let draft: LocalDraft
    public let submissionID: UUID
    public init(draft: LocalDraft, submissionID: UUID) {
        self.draft = draft; self.submissionID = submissionID
    }
}

public struct DraftSubmissionResult: Equatable, Sendable {
    public let envelopes: [EventEnvelope]
    /// The latest checkpoint after the atomic commit, including newer edits.
    public let draft: LocalDraft
    public let receiptID: UUID
    public init(envelopes: [EventEnvelope], draft: LocalDraft, receiptID: UUID) {
        self.envelopes = envelopes; self.draft = draft; self.receiptID = receiptID
    }
}
