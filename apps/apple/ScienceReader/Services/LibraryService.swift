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
    func readerCapabilities(accountID: UUID) async throws -> ReaderCapabilities?
}

extension LibraryTransport {
    // Existing fixture transports explicitly model a legacy server.
    func readerCapabilities(accountID: UUID) async throws -> ReaderCapabilities? { nil }
}

/// Only the transport's exact structured PostgreSQL error maps to compaction.
/// Decoder errors, HTTP bodies containing similar text, and generic failures do
/// not discard a reconciler's successfully accepted pages.
enum LibraryTransportError: Error, Equatable { case resyncRequired }

enum LibraryServiceError: Error, Equatable {
    case retired, pageBudgetExhausted, repeatedCompaction, wrongDelivery, receiptNotObserved, capabilityUnavailable
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
    private var receiptContext: LibraryReadContext?
    private var adoptedFull5: Bool
    private(set) var capabilities: ReaderCapabilities?
    private var running: (id: UUID, cycle: UInt64, task: Task<LibrarySnapshot, Error>)?

    init(scope: LibraryScope, transport: any LibraryTransport, limits: Limits = .init(),
         rememberedContext: LibraryReadContext? = nil, resume: LibraryReplicaSeed? = nil) {
        self.scope = scope; self.transport = transport; self.limits = limits
        let context = rememberedContext ?? .legacyFull3
        adoptedFull5 = context.permitsUploads
        if let resume, resume.scope.accountID == scope.accountID, resume.readContext == context,
           let restored = try? LibraryReconciler(resuming: resume, scope: resume.scope) { working = restored }
        else { working = LibraryReconciler(accountID: scope.accountID, readContext: context) }
    }

    func snapshot() -> LibrarySnapshot? { published }
    var isRefreshing: Bool { running != nil }
    func permitsLegacyCommands() -> Bool { !adoptedFull5 && working.readContext == .legacyFull3 }

    /// Discovery may stop obsolete writes without claiming any row is current.
    /// v5 writes remain disabled until the server can enforce the epoch in the
    /// same transaction as the mutation; this is not a substitute for that gate.
    func commandReadContext() async throws -> LibraryReadContext {
        if let active = running { _ = try await active.task.value }
        try Task.checkCancellation()
        guard !retired else { throw LibraryServiceError.retired }
        let advertised = try await transport.readerCapabilities(accountID: scope.accountID)
        try Task.checkCancellation()
        guard !retired else { throw LibraryServiceError.retired }
        return try updateCapabilities(advertised)
    }

    /// Concurrent callers share one bounded pull. Cancellation of an awaiting
    /// view does not cancel another caller's refresh; account retirement does.
    func refresh() async throws -> LibrarySnapshot {
        try await refresh(minimumCursor: 0, startedAfter: nil, readContext: nil)
    }

    /// A command reply can omit other entities changed in its transaction.
    /// Finish any older pull, then observe a fresh server boundary. The floor
    /// is evidence to read through, never a replacement for the library cursor.
    /// This also handles absent-item conflicts whose receipt has no sequence.
    func refreshAfterCommand(minimumCursor: Int64, readContext: LibraryReadContext = .legacyFull3) async throws -> LibrarySnapshot {
        guard minimumCursor >= 0 else { throw LibraryProtocolError.invalidCursor }
        return try await refresh(minimumCursor: minimumCursor, startedAfter: pullCycle, readContext: readContext)
    }

    private func refresh(minimumCursor: Int64, startedAfter: UInt64?, readContext: LibraryReadContext?) async throws -> LibrarySnapshot {
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
            if let readContext, let receiptContext, readContext != receiptContext { throw LibraryProtocolError.contextMismatch }
            requiredCursor = max(requiredCursor, minimumCursor)
            requiresFreshBoundary = requiresFreshBoundary || startedAfter != nil
            receiptContext = readContext ?? receiptContext
            task = running.task
        }
        else {
            guard pullCycle < UInt64.max else { throw LibraryServiceError.pageBudgetExhausted }
            let id = UUID()
            pullCycle += 1
            requiredCursor = minimumCursor
            requiresFreshBoundary = startedAfter != nil
            receiptContext = readContext
            task = Task { try await self.pull(id: id) }
            running = (id, pullCycle, task)
        }
        let result = try await task.value
        try Task.checkCancellation()
        guard !retired, result.scope == scope else { throw CancellationError() }
        if let readContext, result.observation.readContext != readContext { throw LibraryProtocolError.contextMismatch }
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
        try await negotiate(id: id)
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
                try await negotiate(id: id)
                continue
            }
            if working.phase == .ready, let cursor = working.committedCursor {
                try requireOwnership(id)
                if requiresFreshBoundary && !readFreshBoundary { continue }
                if let receiptContext, receiptContext != working.readContext { throw LibraryProtocolError.contextMismatch }
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

    private func negotiate(id: UUID) async throws {
        try requireOwnership(id)
        let advertised = try await transport.readerCapabilities(accountID: scope.accountID)
        try requireOwnership(id)
        let context = try updateCapabilities(advertised)
        if let receiptContext, context != receiptContext { throw LibraryProtocolError.contextMismatch }
    }

    private func updateCapabilities(_ advertised: ReaderCapabilities?) throws -> LibraryReadContext {
        let context: LibraryReadContext
        if let advertised {
            guard advertised.accountID == scope.accountID else { throw LibraryProtocolError.accountMismatch }
            context = advertised.readContext
            adoptedFull5 = true
        } else {
            guard !adoptedFull5 else { throw LibraryServiceError.capabilityUnavailable }
            context = .legacyFull3
        }
        capabilities = advertised
        if context != working.readContext { working.reset(accountID: scope.accountID, readContext: context) }
        return context
    }

    private func requireOwnership(_ id: UUID, request: LibraryPageRequest? = nil) throws {
        try Task.checkCancellation()
        guard !retired, running?.id == id,
              request.map({ $0.accountID == scope.accountID && $0.sessionID == working.sessionID }) ?? true else {
            throw CancellationError()
        }
    }
}
