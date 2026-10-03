import Foundation
import ScienceReaderCore

/// The reader's account session is separate from a reconciler's pull session:
/// compaction starts a new pull without changing the signed-in reader session.
struct LibraryScope: Equatable, Sendable {
    let accountID: UUID
    let readerSessionID: UUID
}

struct LibraryPageDelivery: Sendable {
    enum Page: Sendable { case baseline(LibraryBaselinePage), changes(LibraryChangesPage) }
    let request: LibraryPageRequest
    let page: Page
}

protocol LibraryTransport: Sendable {
    func libraryPage(_ request: LibraryPageRequest) async throws -> LibraryPageDelivery
}

/// Only the transport's exact structured PostgreSQL error maps to compaction.
/// Decoder errors, HTTP bodies containing similar text, and generic failures do
/// not discard a reconciler's successfully accepted pages.
enum LibraryTransportError: Error, Equatable { case resyncRequired }

enum LibraryServiceError: Error, Equatable {
    case retired, pageBudgetExhausted, repeatedCompaction, wrongDelivery, receiptNotObserved
}

struct LibrarySnapshot: Equatable, Sendable {
    let scope: LibraryScope
    let generation: UInt64
    let committedCursor: Int64
    let observation: LibraryCompleteObservation
    /// Tombstones and import-to-item mappings remain in the snapshot. Imports
    /// are their own typed records; an unresolved import has no document ID.
    let entries: [LibraryEntry]

    var items: [LibraryItemRecord] {
        entries.compactMap { if case .item(let value) = $0 { return value }; return nil }
    }
    var imports: [LibraryImportRecord] {
        entries.compactMap { if case .import(let value) = $0 { return value }; return nil }
    }
}

/// Read-only, account-scoped memory state. A complete snapshot is published
/// only after a full baseline and its fixed-boundary catch-up, or a completed
/// subsequent catch-up. This service makes no persistence/offline guarantee.
actor LibraryService {
    struct Limits: Sendable {
        let pagesPerRefresh: Int
        let compactionsPerRefresh: Int
        init(pagesPerRefresh: Int = 256, compactionsPerRefresh: Int = 1) {
            self.pagesPerRefresh = max(1, min(256, pagesPerRefresh))
            self.compactionsPerRefresh = max(0, min(1, compactionsPerRefresh))
        }
    }

    let scope: LibraryScope
    private let transport: any LibraryTransport
    private let limits: Limits
    private var working: LibraryReconciler
    private var published: LibrarySnapshot?
    private var publicationGeneration: UInt64 = 0
    private var retired = false
    private var pullCycle: UInt64 = 0
    private var requiredCursor: Int64 = 0
    private var requiresFreshBoundary = false
    private var running: (id: UUID, cycle: UInt64, task: Task<LibrarySnapshot, Error>)?

    init(scope: LibraryScope, transport: any LibraryTransport, limits: Limits = .init()) {
        self.scope = scope; self.transport = transport; self.limits = limits
        working = LibraryReconciler(accountID: scope.accountID)
    }

    func snapshot() -> LibrarySnapshot? { published }
    var isRefreshing: Bool { running != nil }

    /// Concurrent callers share one bounded pull. Cancellation of an awaiting
    /// view does not cancel another caller's refresh; account retirement does.
    func refresh() async throws -> LibrarySnapshot {
        try await refresh(minimumCursor: 0, startedAfter: nil)
    }

    /// A command reply can omit other entities changed in its transaction.
    /// Finish any older pull, then observe a fresh server boundary. The floor
    /// is evidence to read through, never a replacement for the library cursor.
    /// This also handles absent-item conflicts whose receipt has no sequence.
    func refreshAfterCommand(minimumCursor: Int64) async throws -> LibrarySnapshot {
        guard minimumCursor >= 0 else { throw LibraryProtocolError.invalidCursor }
        return try await refresh(minimumCursor: minimumCursor, startedAfter: pullCycle)
    }

    private func refresh(minimumCursor: Int64, startedAfter: UInt64?) async throws -> LibrarySnapshot {
        try Task.checkCancellation()
        guard !retired else { throw LibraryServiceError.retired }
        if let startedAfter {
            // Ignore an older pull's transient failure here: its exact pending
            // page remains in working, and the new bounded pull retries it.
            while let old = running, old.cycle <= startedAfter {
                _ = try? await old.task.value
                try Task.checkCancellation()
                guard !retired else { throw LibraryServiceError.retired }
            }
        }
        let task: Task<LibrarySnapshot, Error>
        if let running {
            requiredCursor = max(requiredCursor, minimumCursor)
            requiresFreshBoundary = requiresFreshBoundary || startedAfter != nil
            task = running.task
        }
        else {
            guard pullCycle < UInt64.max else { throw LibraryServiceError.pageBudgetExhausted }
            let id = UUID()
            pullCycle += 1
            requiredCursor = minimumCursor
            requiresFreshBoundary = startedAfter != nil
            task = Task { try await self.pull(id: id) }
            running = (id, pullCycle, task)
        }
        let result = try await task.value
        try Task.checkCancellation()
        guard !retired, result.scope == scope else { throw CancellationError() }
        return result
    }

    /// Clear this account immediately. A cancelled or cancellation-ignoring
    /// transport cannot publish old data, including after same-account login.
    func invalidate() {
        retired = true
        running?.task.cancel(); running = nil
        working.reset(accountID: scope.accountID)
        published = nil
    }

    private func pull(id: UUID) async throws -> LibrarySnapshot {
        defer { if running?.id == id { running = nil } }
        var pages = 0, compactions = 0
        var readFreshBoundary = false
        while true {
            try requireOwnership(id)
            guard pages < limits.pagesPerRefresh else { throw LibraryServiceError.pageBudgetExhausted }
            let request = try working.nextRequest()
            pages += 1
            do {
                let delivery = try await transport.libraryPage(request)
                try requireOwnership(id, request: request)
                guard delivery.request == request else { throw LibraryServiceError.wrongDelivery }
                switch delivery.page {
                case .baseline(let page): try working.accept(page, for: request)
                case .changes(let page): try working.accept(page, for: request)
                }
                if case .changes(_, nil) = request.query { readFreshBoundary = true }
            } catch {
                try requireOwnership(id, request: request)
                guard error as? LibraryTransportError == .resyncRequired else { throw error }
                // Even exhaustion retires the expired ticket before returning.
                // The next explicit refresh can start a valid new baseline.
                guard working.requireResync(for: request) else { throw CancellationError() }
                readFreshBoundary = false
                compactions += 1
                guard compactions <= limits.compactionsPerRefresh else { throw LibraryServiceError.repeatedCompaction }
                continue
            }
            if working.phase == .ready, let cursor = working.committedCursor {
                try requireOwnership(id)
                if requiresFreshBoundary && !readFreshBoundary { continue }
                if cursor < requiredCursor {
                    // A resumed fixed-boundary page may predate the receipt.
                    // Read one new boundary, but never spin on a server that
                    // still cannot return an already-acknowledged sequence.
                    guard !readFreshBoundary else { throw LibraryServiceError.receiptNotObserved }
                    continue
                }
                let observation = try working.completeObservation()
                publicationGeneration += 1
                let result = LibrarySnapshot(scope: scope, generation: publicationGeneration,
                                             committedCursor: cursor, observation: observation,
                                             entries: working.orderedEntries)
                published = result
                return result
            }
        }
    }

    private func requireOwnership(_ id: UUID, request: LibraryPageRequest? = nil) throws {
        try Task.checkCancellation()
        guard !retired, running?.id == id,
              request.map({ $0.accountID == scope.accountID && $0.sessionID == working.sessionID }) ?? true else {
            throw CancellationError()
        }
    }
}
