import Foundation
import ScienceReaderCore

/// Presentation remembers the path already shown, independently of UUID order
/// in the branch picker. Explicit choices also fence a pending save's callback.
struct ConversationBranchSelections {
    struct Choice: Sendable {
        let conversationID: UUID
        let revision: UUID?
    }
    private var heads: [UUID: UUID] = [:]
    private var revisions: [UUID: UUID] = [:]

    func selected(in conversation: UUID) -> UUID? { heads[conversation] }
    func capture(in conversation: UUID) -> Choice { Choice(conversationID: conversation, revision: revisions[conversation]) }

    mutating func select(_ head: UUID?, in conversation: UUID) {
        heads[conversation] = head
        revisions[conversation] = UUID()
    }

    @discardableResult
    mutating func complete(_ choice: Choice, head: UUID?) -> Bool {
        guard revisions[choice.conversationID] == choice.revision else { return false }
        heads[choice.conversationID] = head
        return true
    }

    mutating func reconcile(with state: PrivateState, observing conversation: UUID?) {
        let conversations = Set(heads.keys).union(conversation.map { [$0] } ?? [])
        for id in conversations {
            guard !state.isDeleted(id) else {
                heads.removeValue(forKey: id)
                continue
            }
            let branches = state.conversationBranches(id)
            // Prefer an exact surviving head, then its descendants. Retaining
            // every newly observed tip prevents the next fork from moving us
            // back to a different descendant of an older common ancestor.
            if let previous = heads[id].map(state.resolvedEventID) {
                let chosen = branches.first { $0.head == previous }
                    ?? branches.first { $0.complete && contains(previous, in: $0, conversation: id, state: state) }
                // A deleted tip remains a causal anchor. Its projected path
                // hides deleted text and must not jump to a surviving sibling.
                // Missing ancestry likewise stays unresolved until catch-up.
                heads[id] = chosen?.head ?? previous
            } else {
                heads[id] = branches.first?.head
            }
        }
    }

    private func contains(_ ancestor: UUID, in branch: ConversationBranch, conversation: UUID, state: PrivateState) -> Bool {
        // Include tombstoned intermediate messages in ancestry, while keeping
        // their text out of the transcript supplied by the reducer.
        var remaining = [branch.head], visited = Set<UUID>()
        while let id = remaining.popLast() {
            guard visited.insert(id).inserted, let event = state.events[id],
                  event.payload.kind == .message, event.payload.conversationID == conversation else { continue }
            if id == ancestor { return true }
            remaining.append(contentsOf: event.payload.parents)
        }
        return false
    }
}
