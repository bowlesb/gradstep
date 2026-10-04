import Foundation
import ScienceReaderCore

/// Copy at the synchronous caller boundary. Foundation Data may wrap mutable
/// external memory; a suspended verification must never retain that backing.
struct ReaderBundleInput: Sendable {
    let manifestData: Data
    let expectedSHA256: String
    let members: [String: Data]

    init(manifestData: Data, expectedSHA256: String, members: [String: Data]) throws {
        guard manifestData.count <= 262_144, members.count <= 512 else { throw ReaderBundleError.invalidResource }
        var total = 0
        for (path, bytes) in members {
            guard path.utf8.count <= 240, bytes.count <= 16_777_216 else { throw ReaderBundleError.invalidResource }
            total += bytes.count
            guard total <= 33_554_432 else { throw ReaderBundleError.invalidResource }
        }
        self.manifestData = Self.copy(manifestData)
        self.expectedSHA256 = expectedSHA256
        self.members = members.mapValues(Self.copy)
    }

    private static func copy(_ data: Data) -> Data { data.withUnsafeBytes { Data($0) } }

    static func verify(_ input: Self) async throws -> VerifiedReaderBundle {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try ReaderBundleLoader.verify(manifest: input.manifestData,
                expectedSHA256: input.expectedSHA256, members: input.members)
        }
        return try await withTaskCancellationHandler {
            let result = try await work.value
            try Task.checkCancellation()
            return result
        } onCancel: { work.cancel() }
    }
}

struct OpenedReaderBundle: Sendable {
    let installation: InstalledReaderBundle
    let bundle: VerifiedReaderBundle
}

struct ReaderOfflineRestoration: Sendable {
    let presentation: Result<CachedLibraryPresentation?, Error>
    let installations: Result<InstalledReaderBundleList, Error>
}

/// One activated account owns installation, native image admission and lazy
/// reopening. The retirement queue also joins verification before a new owner
/// starts work, while accepted SQLite operations drain through persistence.
@MainActor
final class ReaderBundleCoordinator {
    typealias Verification = @Sendable (ReaderBundleInput) async throws -> VerifiedReaderBundle
    typealias DirectoryReader = @Sendable (EncryptedStore, LibraryCommandScope) async throws -> InstalledReaderBundleList
    let scope: LibraryCommandScope
    private let persistence: ReaderLocalPersistence
    private let verify: Verification
    private let readDirectory: DirectoryReader
    private let report: @MainActor (String?) -> Void
    private var closed = false
    private var paused = false
    private var install: Install?
    private var opening: (id: UUID, installationID: UUID, binding: ReaderArtifactBinding, task: Task<OpenedReaderBundle, Error>)?
    private var installed: [UUID: InstalledReaderBundle] = [:]
    private var directory: InstalledReaderBundleList?
    private var eligibility: [UUID: ReaderBundleEligibility] = [:]
    private var latestObservation: LibraryCompleteObservation?
    private var cacheSave: Task<CachedLibraryPresentation, Error>?
    private var cacheHalted = false
    private var policyFailed = false
    private var removals: [UUID: Task<Void, Error>] = [:]

    private final class Install {
        let id = UUID()
        let binding: ReaderArtifactBinding
        let begin: Task<ReaderInstallTicket, Error>
        var task: Task<InstalledReaderBundle, Error>?
        var commit: Task<(InstalledReaderBundle, InstalledReaderBundleList), Error>?
        var cleanup: Task<Void, Error>?
        var cancelled = false
        init(binding: ReaderArtifactBinding, begin: Task<ReaderInstallTicket, Error>) {
            self.binding = binding; self.begin = begin
        }
    }

    init(scope: LibraryCommandScope, persistence: ReaderLocalPersistence,
         verify: @escaping Verification = ReaderBundleInput.verify,
         readDirectory: @escaping DirectoryReader = { try await $0.listInstalledReaderBundles(scope: $1) },
         report: @escaping @MainActor (String?) -> Void = { _ in }) {
        self.scope = scope; self.persistence = persistence; self.verify = verify
        self.readDirectory = readDirectory; self.report = report
    }

    /// Cache damage is reported separately from private-history recovery, and
    /// one damaged cache child does not prevent the other directory being read.
    func restore() async throws -> ReaderOfflineRestoration {
        try requireOpen()
        let scope = scope, readDirectory = readDirectory
        let task = try persistence.acceptWrite { store in
            let presentation: Result<CachedLibraryPresentation?, Error>
            let installations: Result<InstalledReaderBundleList, Error>
            do { presentation = .success(try await store.cachedLibraryPresentation(scope: scope)) }
            catch { presentation = .failure(error) }
            do { installations = .success(try await readDirectory(store, scope)) }
            catch { installations = .failure(error) }
            return ReaderOfflineRestoration(presentation: presentation, installations: installations)
        }
        let result = try await task.value
        try requireOpen()
        if case .success(let list) = result.installations {
            try publishDirectory(list)
        }
        return result
    }

    func localCopy(documentID: UUID, artifactID: UUID?) -> InstalledReaderBundle? {
        installed.values.first { $0.binding.documentID == documentID && $0.binding.artifactID == artifactID && permits($0) }
    }

    func installation(documentID: UUID, artifactID: UUID?) -> InstalledReaderBundle? {
        installed.values.first { $0.binding.documentID == documentID && $0.binding.artifactID == artifactID }
    }

    func permits(_ value: InstalledReaderBundle) -> Bool {
        !closed && !policyFailed && installed[value.id]?.binding == value.binding && removals[value.id] == nil &&
        (eligibility[value.binding.artifactID] ?? value.eligibility).canOpen
    }

    /// Live eligibility must apply even while key activation has paused the
    /// writer. The model retains that exact observation until writes resume.
    func applyLiveObservation(_ observation: LibraryCompleteObservation) throws {
        guard !closed, !persistence.isRetired else { throw CancellationError() }
        guard observation.accountID == scope.accountID else { throw ReaderError.wrongAccount }
        do {
            if let old = latestObservation {
                guard observation.committedCursor >= old.committedCursor else { throw OfflineCacheError.staleObservation }
                guard observation.committedCursor != old.committedCursor || observation.entries == old.entries
                else { throw OfflineCacheError.conflictingObservation }
            }
            var next = eligibility
            for value in installed.values {
                next[value.binding.artifactID] = try (next[value.binding.artifactID] ?? value.eligibility)
                    .applying(observation: observation, binding: value.binding)
            }
            if let operation = install {
                next[operation.binding.artifactID] = try (next[operation.binding.artifactID] ?? .init())
                    .applying(observation: observation, binding: operation.binding)
            }
            let changed = Set(next.compactMap { id, value -> UUID? in
                let old = eligibility[id] ?? .init()
                return old.block != value.block || old.membershipVisible != value.membershipVisible ? id : nil
            })
            eligibility = next; latestObservation = observation
            if let opening, changed.contains(opening.binding.artifactID) { opening.task.cancel() }
            if let install, changed.contains(install.binding.artifactID) { cancelInstall() }
        } catch {
            policyFailed = true; invalidatePendingPresentation()
            throw error
        }
    }

    func haltCachePersistence() {
        cacheHalted = true
        if !closed { reportCacheFailure() }
    }

    /// Register an accepted observation independently of the originating UI
    /// task's cancellation. Retirement and the writer pause still fence it.
    @discardableResult
    func observe(_ observation: LibraryCompleteObservation) throws -> Task<CachedLibraryPresentation, Error> {
        try applyLiveObservation(observation)
        guard !paused, !persistence.isActivating else { throw ReaderError.storageUnavailable }
        // Never skip a failed observation: it may contain a quarantine that a
        // later ordinary outage cannot clear. Preserve live guards and stop
        // new installs for this activation if the ordered disk chain fails.
        guard !cacheHalted else { throw ReaderError.storageUnavailable }
        let previous = cacheSave, scope = scope, readDirectory = readDirectory
        let saved: Task<CachedLibraryPresentation, Error>
        do {
            let accepted = try persistence.acceptWrite { store in
                if let previous { _ = try await previous.value }
                let presentation = try await store.saveLibraryPresentation(observation, scope: scope)
                return (presentation, try await readDirectory(store, scope))
            }
            saved = Task {
                let (presentation, list) = try await accepted.value
                if !self.closed { try self.publishDirectory(list) }
                return presentation
            }
        } catch { cacheHalted = true; reportCacheFailure(); throw error }
        cacheSave = saved
        Task {
            do { _ = try await saved.value }
            catch { self.cacheHalted = true; if !self.closed { self.reportCacheFailure() } }
        }
        return saved
    }

    /// Register the beginning synchronously so retirement can always release
    /// even a ticket that has not returned from the store actor yet.
    func install(binding: ReaderArtifactBinding, manifestData: Data,
                 members: [String: Data]) throws -> Task<InstalledReaderBundle, Error> {
        try requireOpen()
        guard binding.scope == scope else { throw LibraryCommandError.invalidScope }
        guard !cacheHalted, !policyFailed else { throw ReaderError.storageUnavailable }
        guard install == nil else { throw OfflineCacheError.installBusy }
        let prior = eligibility[binding.artifactID] ?? ReaderBundleEligibility()
        let access = try latestObservation.map { try prior.applying(observation: $0, binding: binding) } ?? prior
        guard access.canOpen else { throw OfflineCacheError.blocked }
        let input = try ReaderBundleInput(manifestData: manifestData,
                                         expectedSHA256: binding.manifestSHA256, members: members)
        let saved = cacheSave
        let begin = try persistence.acceptWrite { store in
            if let saved { _ = try await saved.value }
            return try await store.beginReaderInstall(binding: binding)
        }
        let operation = Install(binding: binding, begin: begin)
        install = operation
        eligibility[binding.artifactID] = access
        let task = Task {
            defer {
                if self.install === operation { self.install = nil }
                self.pruneEligibility()
            }
            do {
                let ticket = try await begin.value
                try self.requireInstall(operation)
                let admitted = try await self.verify(input)
                try self.requireInstall(operation)
                let readDirectory = self.readDirectory, scope = self.scope
                let commit = try self.persistence.acceptWrite { store in
                    let value = try await store.commitReaderInstall(ticket, bundle: admitted)
                    return (value, try await readDirectory(store, scope))
                }
                operation.commit = commit
                let (installed, list) = try await commit.value
                if !self.closed { try self.publishDirectory(list) }
                // A commit accepted before cancellation may have completed.
                // Its old account must not receive a late UI acknowledgement.
                try self.requireInstall(operation)
                return installed
            } catch {
                self.release(operation)
                if let cleanup = operation.cleanup { _ = await cleanup.result }
                throw error
            }
        }
        operation.task = task
        return task
    }

    /// Cancellation prevents an unaccepted commit. An already accepted commit
    /// finishes before release; it is never reported as a rolled-back write.
    func cancelInstall() {
        guard let operation = install else { return }
        operation.cancelled = true; operation.task?.cancel()
        release(operation)
    }

    /// A newer selection supersedes the old callback, but waits for the old
    /// bounded verifier to drain before allocating another bundle payload.
    func open(_ installation: InstalledReaderBundle) throws -> Task<OpenedReaderBundle, Error> {
        try requireOpen()
        guard installation.binding.scope == scope else { throw LibraryCommandError.invalidScope }
        guard installed[installation.id]?.binding == installation.binding else { throw OfflineCacheError.notInstalled }
        try remember(installation)
        guard permits(installation) else { throw OfflineCacheError.blocked }
        let previous = opening?.task
        previous?.cancel()
        let id = UUID(), scope = scope, saved = cacheSave
        let task = Task {
            defer { if self.opening?.id == id { self.opening = nil } }
            if let previous { _ = await previous.result }
            // A failed optional display checkpoint does not erase a valid
            // installed copy; its live eligibility is still checked below.
            if let saved { _ = await saved.result }
            try self.requireOpening(id)
            guard self.permits(installation) else { throw OfflineCacheError.blocked }
            let read = try self.persistence.acceptWrite { try await $0.readReaderBundle(id: installation.id, scope: scope) }
            let payload = try await read.value
            try self.requireOpening(id)
            guard payload.openToken.binding == installation.binding else { throw OfflineCacheError.revisionConflict }
            let input = try ReaderBundleInput(manifestData: payload.manifestData,
                expectedSHA256: installation.binding.manifestSHA256, members: payload.members)
            let admitted = try await self.verify(input)
            try self.requireOpening(id)
            let validation = try self.persistence.acceptWrite { try await $0.validateReaderOpen(payload.openToken) }
            let current = try await validation.value
            try self.requireOpening(id)
            try self.remember(current)
            guard self.permits(current) else { throw OfflineCacheError.blocked }
            return OpenedReaderBundle(installation: current, bundle: admitted)
        }
        opening = (id, installation.id, installation.binding, task)
        return task
    }

    /// Called synchronously before the model publishes a new availability
    /// observation or removes a local copy; asynchronous work cannot race it.
    func invalidatePendingPresentation() {
        opening?.task.cancel()
        cancelInstall()
    }

    func cancelOpening() { opening?.task.cancel() }

    func remove(_ value: InstalledReaderBundle) throws -> Task<Void, Error> {
        try requireOpen()
        guard value.binding.scope == scope else { throw LibraryCommandError.invalidScope }
        guard removals[value.id] == nil else { throw OfflineCacheError.revisionConflict }
        if opening?.installationID == value.id { opening?.task.cancel() }
        if install?.binding == value.binding { cancelInstall() }
        let scope = scope, readDirectory = readDirectory
        let accepted = try persistence.acceptWrite { store in
            try await store.removeReaderBundle(id: value.id, expectedRevision: value.revision, scope: scope)
            return try await readDirectory(store, scope)
        }
        let task = Task {
            defer { self.removals.removeValue(forKey: value.id) }
            let list = try await accepted.value
            if !self.closed { try self.publishDirectory(list) }
            try self.requireOpen()
        }
        removals[value.id] = task
        return task
    }

    func pause() async {
        paused = true
        opening?.task.cancel(); cancelInstall()
        await waitUntilIdle()
    }

    func resume() { if !closed { paused = false } }

    /// Must run before persistence.retire(), including same-account sign-in.
    func close() {
        guard !closed else { return }
        closed = true; paused = true
        opening?.task.cancel(); cancelInstall()
    }

    func stop() async { close(); await waitUntilIdle() }

    func waitUntilIdle() async {
        if let task = install?.task { _ = await task.result }
        if let task = opening?.task { _ = await task.result }
        if let task = cacheSave { _ = await task.result }
        for task in Array(removals.values) { _ = await task.result }
    }

    private func requireOpen() throws {
        try Task.checkCancellation()
        guard !closed, !paused, !persistence.isRetired, !persistence.isActivating else { throw CancellationError() }
    }

    private func requireInstall(_ operation: Install) throws {
        try requireOpen()
        guard install === operation, !operation.cancelled else { throw CancellationError() }
        guard !cacheHalted, !policyFailed,
              eligibility[operation.binding.artifactID]?.canOpen ?? true else { throw OfflineCacheError.blocked }
    }

    private func requireOpening(_ id: UUID) throws {
        try requireOpen()
        guard opening?.id == id else { throw CancellationError() }
    }

    private func publishDirectory(_ list: InstalledReaderBundleList) throws {
        guard list.scope == scope else { throw LibraryCommandError.invalidScope }
        if let previous = directory {
            if list.generation < previous.generation { return }
            if list.generation == previous.generation {
                guard list == previous else { throw OfflineCacheError.corruptCache }
                return
            }
        }
        installed = Dictionary(uniqueKeysWithValues: list.installations.map { ($0.id, $0) })
        for value in list.installations { try remember(value) }
        pruneEligibility()
        directory = list
    }

    private func pruneEligibility() {
        let retained = Set(installed.values.map { $0.binding.artifactID }).union(install.map { [$0.binding.artifactID] } ?? [])
        eligibility = eligibility.filter { retained.contains($0.key) }
    }

    private func remember(_ value: InstalledReaderBundle) throws {
        guard value.binding.scope == scope else { throw LibraryCommandError.invalidScope }
        let old = eligibility[value.binding.artifactID] ?? value.eligibility
        eligibility[value.binding.artifactID] = try latestObservation.map { try old.applying(observation: $0, binding: value.binding) } ?? old
    }

    private func reportCacheFailure() {
        report("Your latest library update wasn’t saved for offline use. Reopen the app to try again.")
    }

    private func release(_ operation: Install) {
        guard operation.cleanup == nil else { return }
        let begin = operation.begin, commit = operation.commit
        // close() reserves this cleanup before retirement. Releasing a failed
        // begin needs no ticket; exact ended tickets are idempotent in Core.
        operation.cleanup = try? persistence.acceptWrite { store in
            guard let ticket = try? await begin.value else { return }
            if let commit { _ = await commit.result }
            try await store.cancelReaderInstall(ticket)
        }
    }
}
