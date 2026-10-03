import Foundation
import ScienceReaderCore

/// Coalesces edits while SQLite is working. Each worker is registered with the
/// account's retirement barrier before returning to the UI; no timer is needed
/// to eventually start a save, and sign-out cannot strand accepted checkpoints.
@MainActor
final class ReaderDraftQueue {
    typealias Completion = @MainActor (LocalDraft, Result<LocalDraft, Error>) -> Void
    private let persistence: ReaderLocalPersistence
    private let completion: Completion
    private var pending: [UUID: LocalDraft] = [:]
    private var order: [UUID] = []
    private var running = false
    private var closed = false

    init(persistence: ReaderLocalPersistence, completion: @escaping Completion) {
        self.persistence = persistence; self.completion = completion
    }

    func save(_ draft: LocalDraft) throws {
        guard !closed, !persistence.isRetired, !persistence.isActivating else { throw ReaderError.storageUnavailable }
        if let newer = pending[draft.id], newer.revision > draft.revision { return }
        if pending[draft.id] == nil { order.append(draft.id) }
        pending[draft.id] = draft
        guard !running else { return }
        running = true
        do {
            _ = try persistence.acceptWrite { [self] store in
                while let checkpoint = await next() {
                    do {
                        let saved = try await store.saveDraft(checkpoint)
                        await finished(checkpoint, result: .success(saved))
                    } catch {
                        await finished(checkpoint, result: .failure(error))
                    }
                }
            }
        } catch {
            running = false
            pending.removeValue(forKey: draft.id); order.removeAll { $0 == draft.id }
            throw error
        }
    }

    func discard(id: UUID, revision: Int64) throws -> Task<Void, Error> {
        guard !closed else { throw ReaderError.storageUnavailable }
        let task = try persistence.acceptWrite { store in try await store.discardDraft(id: id, revision: revision) }
        pending.removeValue(forKey: id); order.removeAll { $0 == id }
        return task
    }

    /// Clear presentation elsewhere, but finish every already accepted edit.
    func close() { closed = true }

    private func next() -> LocalDraft? {
        while !order.isEmpty {
            let id = order.removeFirst()
            if let draft = pending.removeValue(forKey: id) { return draft }
        }
        // Release the queue on the main actor before the worker returns. An
        // edit arriving now registers its own worker before retirement starts.
        running = false
        return nil
    }

    private func finished(_ checkpoint: LocalDraft, result: Result<LocalDraft, Error>) {
        completion(checkpoint, result)
    }
}
