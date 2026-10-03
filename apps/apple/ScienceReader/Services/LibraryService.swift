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
    case retired, pageBudgetExhausted, repeatedCompaction, wrongDelivery
}

struct LibrarySnapshot: Equatable, Sendable {
    let scope: LibraryScope
    let generation: UInt64
    let committedCursor: Int64
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
    private var running: (id: UUID, task: Task<LibrarySnapshot, Error>)?

    init(scope: LibraryScope, transport: any LibraryTransport, limits: Limits = .init()) {
        self.scope = scope; self.transport = transport; self.limits = limits
        working = LibraryReconciler(accountID: scope.accountID)
    }

    func snapshot() -> LibrarySnapshot? { published }
    var isRefreshing: Bool { running != nil }

    /// Concurrent callers share one bounded pull. Cancellation of an awaiting
    /// view does not cancel another caller's refresh; account retirement does.
    func refresh() async throws -> LibrarySnapshot {
        try Task.checkCancellation()
        guard !retired else { throw LibraryServiceError.retired }
        let task: Task<LibrarySnapshot, Error>
        if let running { task = running.task }
        else {
            let id = UUID()
            task = Task { try await self.pull(id: id) }
            running = (id, task)
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
            } catch {
                try requireOwnership(id, request: request)
                guard error as? LibraryTransportError == .resyncRequired else { throw error }
                // Even exhaustion retires the expired ticket before returning.
                // The next explicit refresh can start a valid new baseline.
                guard working.requireResync(for: request) else { throw CancellationError() }
                compactions += 1
                guard compactions <= limits.compactionsPerRefresh else { throw LibraryServiceError.repeatedCompaction }
                continue
            }
            if working.phase == .ready, let cursor = working.committedCursor {
                try requireOwnership(id)
                publicationGeneration += 1
                let result = LibrarySnapshot(scope: scope, generation: publicationGeneration,
                                             committedCursor: cursor, entries: working.orderedEntries)
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
