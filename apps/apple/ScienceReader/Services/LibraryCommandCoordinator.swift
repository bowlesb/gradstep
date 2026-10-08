import Foundation
import ScienceReaderCore

private struct LibraryQueueStorageFailure: Error {}

/// Owns one activated account's device-local queue. Network requests never run
/// inside a SQLite transaction, and every write joins the account retirement
/// barrier before the caller can acknowledge an action to the user.
@MainActor
final class LibraryCommandCoordinator {
    typealias Publication = @MainActor (LocalLibraryCommandSnapshot, LibrarySnapshot?) -> Void
    let scope: LibraryCommandScope
    private let persistence: ReaderLocalPersistence
    private let library: LibraryService
    private let transport: any LibraryCommandTransport
    private let publish: Publication
    private let report: @MainActor (String?) -> Void
    private var running: (id: UUID, task: Task<Void, Never>)?
    private var paused = false
    private var closed = false
    private var halted = false
    private var drainRequested = false

    init(scope: LibraryCommandScope, persistence: ReaderLocalPersistence, library: LibraryService,
         transport: any LibraryCommandTransport, publish: @escaping Publication,
         report: @escaping @MainActor (String?) -> Void) {
        self.scope = scope; self.persistence = persistence; self.library = library
        self.transport = transport; self.publish = publish; self.report = report
    }

    func restore() async throws {
        try requireOpen()
        let snapshot = try await snapshot()
        try requireOpen()
        publish(snapshot, nil)
        if snapshot.commands.isEmpty { report(nil) }
    }

    @discardableResult
    func enqueue(_ mutation: LibraryMutation, display: String?) async throws -> LocalLibraryCommandHandle {
        try requireWritable()
        guard await library.permitsLegacyCommands()
        else { throw LibraryCommandError.contextMismatch }
        let scope = scope
        let (handle, snapshot) = try await persist { store in
            let handle = try await store.enqueueLibraryCommand(scope: scope, mutation: mutation, display: display)
            return (handle, try await store.libraryCommandSnapshot(scope: scope))
        }
        try requireOpen()
        publish(snapshot, nil); flush()
        return handle
    }

    /// A tag edit: replaces an unsent earlier edit, or follows a sent one (see `editLibraryTags`).
    @discardableResult
    func editTags(documentID: UUID, tags: [String], hiddenTags: [String], observedRevision: Int64,
                  display: String?) async throws -> LocalLibraryCommandHandle {
        try requireWritable()
        guard await library.permitsLegacyCommands()
        else { throw LibraryCommandError.contextMismatch }
        let scope = scope
        let (handle, snapshot) = try await persist { store in
            let handle = try await store.editLibraryTags(scope: scope, documentID: documentID, tags: tags, hiddenTags: hiddenTags,
                                                         observedRevision: observedRevision, display: display)
            return (handle, try await store.libraryCommandSnapshot(scope: scope))
        }
        try requireOpen()
        publish(snapshot, nil); flush()
        return handle
    }

    /// HTTP cancellation cannot undo an issued RPC. A submitted intent gets a
    /// separate held reversal, frozen from its own eventual receipt revision.
    func cancel(_ command: LocalLibraryCommand) async throws {
        try requireWritable()
        guard command.scope == scope else { throw LibraryCommandError.invalidScope }
        let scope = scope
        let snapshot = try await persist { store in
            try await store.cancelLibraryCommand(command.handle, scope: scope)
        }
        try requireOpen()
        publish(snapshot, nil); flush()
    }

    func dismiss(_ command: LocalLibraryCommand) async throws {
        try requireWritable()
        let scope = scope
        let snapshot = try await persist { store in
            _ = try await store.dismissLibraryCommand(command.handle, expectedRevision: command.revision, scope: scope)
            return try await store.pruneLibraryCommands(scope: scope)
        }
        try requireOpen()
        publish(snapshot, nil)
        if snapshot.commands.isEmpty { report(nil) }
    }

    /// One foreground/manual drain, at most 16 distinct operations. A transport
    /// failure stops this drain; reopening a view never creates a retry loop.
    func resume() {
        guard !closed, !halted, !persistence.isRetired, !persistence.isActivating else { return }
        paused = false
        flush()
    }

    /// Foreground/manual retry can recover a rolled-back local write only after
    /// Core authenticates the current on-disk metadata. An ambiguous commit or
    /// replaced writer still requires reopening; never trust the cached queue.
    func retry() async {
        guard !closed, !paused, !persistence.isRetired, !persistence.isActivating else { return }
        if halted {
            do {
                guard let store = persistence.store else { throw ReaderError.storageUnavailable }
                let snapshot = try await store.libraryCommandSnapshot(scope: scope)
                guard !closed, !paused, !persistence.isRetired, !persistence.isActivating else { return }
                halted = false
                publish(snapshot, nil); report(nil)
            } catch { return }
        }
        flush()
    }

    func flush() {
        guard !closed, !paused, !halted, !persistence.isRetired, !persistence.isActivating else { return }
        guard running == nil else { drainRequested = true; return }
        let id = UUID()
        let task = Task { await self.drain(id: id) }
        running = (id, task)
    }

    func waitUntilIdle() async { while let task = running?.task { await task.value } }

    /// Key activation keeps this same SQLite actor. Finish/record a suspended
    /// attempt while writes are still accepted, before changing its keys.
    func pause() async {
        paused = true; drainRequested = false
        running?.task.cancel()
        if let task = running?.task { await task.value }
    }

    /// Account presentation clears immediately. A fresh store owner resets any
    /// unfinished attempt marker; a late callback cannot write to this account.
    func close() { closed = true; paused = true; drainRequested = false; running?.task.cancel() }
    func stop() async { close(); if let task = running?.task { await task.value } }

    private func drain(id: UUID) async {
        defer {
            if running?.id == id {
                running = nil
                let requested = drainRequested; drainRequested = false
                if requested { flush() }
            }
        }
        var attempted = Set<LocalLibraryCommandHandle>()
        do {
            let queued = try await snapshot()
            if queued.commands.contains(where: { $0.isUnfinished }) {
                let context = try await library.commandReadContext()
                try requireWritable()
                let scope = scope
                let reviewed = try await persist { store in
                    try await store.reviewLibraryCommandContext(context, scope: scope)
                }
                try requireWritable()
                publish(reviewed, nil)
                if context != .legacyFull3 {
                    report("Library changes are paused while this app finishes adopting the new sync version. Saved changes are preserved for review.")
                    return
                }
            }
            while !closed && !paused && !halted {
                try Task.checkCancellation()
                var current = try await snapshot()
                try requireOpen()
                // A restored receipt needs catch-up even when no POST remains.
                if current.commands.contains(where: { $0.phase == .receiptAwaitingCatchup }) {
                    current = try await reconcile(current)
                }
                guard !closed, !paused, attempted.count < 16 else { return }
                let ready = current.commands.filter { $0.canAttempt && !attempted.contains($0.handle) }
                // A capacity-rejected Add must not starve the Cancel/Remove
                // that can free capacity. Held reversals remain non-runnable
                // until their own predecessor receipt freezes the request.
                guard let next = ready.first(where: Self.isWithdrawal) ?? ready.first else {
                    publish(current, nil)
                    if !current.commands.contains(where: { $0.isUnfinished || $0.phase == .needsReview }) { report(nil) }
                    return
                }
                attempted.insert(next.handle)
                let scope = scope
                let attempt: LibraryCommandAttempt, begun: LocalLibraryCommandSnapshot
                do {
                    (attempt, begun) = try await persist { store in
                        let attempt = try await store.beginLibraryAttempt(next.handle, scope: scope)
                        return (attempt, try await store.libraryCommandSnapshot(scope: scope))
                    }
                } catch LibraryCommandError.staleHandle {
                    continue // A simultaneous local Cancel/prune won before dispatch.
                } catch LibraryCommandError.invalidTransition {
                    continue // Re-read the durable state; never POST the stale candidate.
                }
                guard !closed else { return }
                publish(begun, nil)
                if paused || Task.isCancelled {
                    try await failure(.suspended, attempt: attempt)
                    return
                }
                let delivery: LibraryCommandDelivery
                do {
                    delivery = try await transport.libraryCommand(attempt)
                    guard delivery.attempt == attempt else { throw LibraryCommandError.staleAttempt }
                } catch {
                    guard !closed else { return }
                    let reason: LibraryCommandFailure = paused || Task.isCancelled ? .suspended : Self.reason(error)
                    try await failure(reason, attempt: attempt)
                    return
                }
                guard !closed else { return }
                // A response received while pausing is still safe to persist:
                // pause joins this task before local key activation begins.
                do {
                    let saved = try await persist { store in try await store.recordLibraryReceipt(delivery.response, for: attempt) }
                    guard !closed else { return }
                    publish(saved, nil)
                } catch LibraryCommandError.invalidReceipt {
                    try await failure(.invalidResponse, attempt: attempt)
                    return
                }
            }
        } catch {
            guard !closed else { return }
            if error is CancellationError, paused { return }
            // A storage failure after a response may be an ambiguous commit.
            // Never issue another POST from that in-memory queue on this run.
            if error as? ReaderError != nil || error is LibraryQueueStorageFailure {
                pauseForStorageFailure()
            } else {
                report("Your change is saved on this device. Refresh to finish updating the library.")
            }
        }
    }

    private func reconcile(_ snapshot: LocalLibraryCommandSnapshot) async throws -> LocalLibraryCommandSnapshot {
        let waiting = snapshot.commands.filter { $0.phase == .receiptAwaitingCatchup }
        let receipts = waiting.compactMap { command in command.receipt.map {
            LibraryCommandReconciliation(handle: command.handle, receiptID: $0.id)
        } }
        let floor = waiting.compactMap { $0.receipt?.requiredCursor }.max() ?? 0
        // This call demands a newly observed boundary after these exact receipt
        // IDs, even when an older refresh/page was already in progress.
        let observed = try await library.refreshAfterCommand(minimumCursor: floor,
            readContext: waiting.first?.libraryReadContext ?? .legacyFull3)
        try Task.checkCancellation()
        try requireWritable()
        guard observed.scope.accountID == scope.accountID else { throw ReaderError.wrongAccount }
        let scope = scope
        let saved = try await persist { store in
            _ = try await store.reconcileLibraryCommands(receipts, observation: observed.observation, scope: scope)
            return try await store.pruneLibraryCommands(scope: scope)
        }
        try requireOpen()
        publish(saved, observed)
        if saved.commands.contains(where: { $0.phase == .needsReview }) {
            report("Your library changed on another device. Review it before trying that action again.")
        } else { report(nil) }
        return saved
    }

    private func failure(_ reason: LibraryCommandFailure, attempt: LibraryCommandAttempt) async throws {
        guard !closed else { return }
        let snapshot = try await persist { store in try await store.recordLibraryFailure(reason, for: attempt) }
        guard !closed else { return }
        publish(snapshot, nil)
        if reason != .suspended { report(Self.message(reason)) }
    }

    private func snapshot() async throws -> LocalLibraryCommandSnapshot {
        try requireOpen()
        guard let store = persistence.store else { throw ReaderError.storageUnavailable }
        do { return try await store.libraryCommandSnapshot(scope: scope) }
        catch {
            if error is LibraryCommandError { throw error }
            pauseForStorageFailure()
            throw LibraryQueueStorageFailure()
        }
    }

    private func persist<Value: Sendable>(_ operation: @escaping @Sendable (EncryptedStore) async throws -> Value) async throws -> Value {
        do { return try await persistence.acceptWrite(operation).value }
        catch {
            if error is LibraryCommandError || error is CancellationError { throw error }
            // SQLite/crypto errors are intentionally private Core types. Their
            // exact class is irrelevant: dispatch stops until a fresh reopen.
            pauseForStorageFailure()
            throw LibraryQueueStorageFailure()
        }
    }

    private func pauseForStorageFailure() {
        halted = true
        guard !closed else { return }
        report("Library changes are paused. Refresh to check the saved queue; reopen the app if this continues.")
    }

    private func requireOpen() throws {
        guard !closed, !persistence.isRetired else { throw CancellationError() }
        guard !halted else { throw ReaderError.storageUnavailable }
    }
    private func requireWritable() throws {
        try requireOpen()
        guard !paused else { throw CancellationError() }
        guard !persistence.isActivating else { throw ReaderError.storageUnavailable }
    }

    private static func isWithdrawal(_ command: LocalLibraryCommand) -> Bool {
        switch command.mutation {
        case .cancelImport, .setMembership(_, false, _, _): true
        default: false
        }
    }

    private static func reason(_ error: Error) -> LibraryCommandFailure {
        if let backend = error as? BackendError {
            switch backend {
            case .signInRequired: return .authentication
            case .rejected(let code):
                if code == "request_failed" { return .connection }
                if code == "request_rate_limit" { return .rateLimited }
                if code == "operation_id_conflict" { return .operationConflict }
                if code.hasPrefix("library_"), code.hasSuffix("_limit") { return .capacity }
                return .serverRejected
            default: return .connection
            }
        }
        if error is LibraryProtocolError || error is DecodingError || error is LibraryCommandError { return .invalidResponse }
        return .connection
    }

    private static func message(_ failure: LibraryCommandFailure) -> String {
        switch failure {
        case .authentication: "Sign in again to send your saved library changes."
        case .rateLimited: "Library updates are temporarily limited. Your change is saved on this device."
        case .capacity: "The library limit has been reached. Your change is saved on this device."
        case .operationConflict: "This library change needs review. Refresh your library before trying again."
        default: "Your change is saved on this device. Refresh to try sending it again."
        }
    }
}
