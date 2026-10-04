import Foundation
import Observation
import ScienceReaderCore
import SwiftUI

enum ReaderTab: String, CaseIterable, Identifiable {
    case feed = "Feed", library = "Library", paper = "Paper", chat = "Chat", settings = "Settings"
    var id: Self { self }
    var symbol: String { switch self { case .feed: "dot.radiowaves.up.forward"; case .library: "books.vertical"; case .paper: "doc.text"; case .chat: "bubble.left.and.bubble.right"; case .settings: "gearshape" } }
}
enum WideMode: String, CaseIterable { case feed = "Feed", library = "Library", reader = "Reader", browse = "Browse", chat = "General Chat" }
enum SelectionAction: String, CaseIterable { case define = "Define", relevance = "Relevance", similar = "Similar", ingest = "Ingest" }

struct Paper: Identifiable, Sendable {
    let id: UUID
    let title: String
    let authors: String
    let year: Int?
    let abstract: String
    let keywords: [String]
    let fileURL: URL?
    let artifactID: UUID?
    var isSample = false
    var sourceID: String?
    var sourceRevision: Int?
    var readerBundle: VerifiedReaderBundle? = nil
    var sourceReference: String? { sourceID.map { $0 + (sourceRevision.map { "v\($0)" } ?? "") } }

    func displaying(_ bundle: VerifiedReaderBundle?) -> Paper {
        Paper(id: id, title: title, authors: authors, year: year, abstract: abstract, keywords: keywords,
              fileURL: bundle?.entryURL, artifactID: artifactID, isSample: isSample,
              sourceID: sourceID, sourceRevision: sourceRevision, readerBundle: bundle)
    }
}

enum LibraryListEntry: Identifiable {
    case paper(Paper)
    case pending(LibraryImportRecord)
    case queued(LocalLibraryCommand)
    var id: String {
        switch self {
        case .paper(let paper): "paper/\(paper.id.wire)"
        case .pending(let item): "import/\(item.id.wire)"
        case .queued(let command): "import/\(command.id.wire)"
        }
    }
    var title: String {
        switch self {
        case .paper(let paper): paper.title
        case .pending(let item): item.metadata?.title ?? "arXiv \(item.sourceID)"
        case .queued(let command): command.display ?? "Queued paper"
        }
    }
}

struct ReaderDocumentScope: Hashable {
    let sessionID: UUID
    let paperID: UUID
    let artifactID: UUID?
    let fileURL: URL?
    let manifestSHA256: String?
}

struct ChatFollowRequest: Equatable {
    let id = UUID()
    let composerID: UUID
}

@MainActor @Observable
final class ReaderModel {
    var tab: ReaderTab = .library
    var wideMode: WideMode = .library
    var papers: [Paper] = []
    private(set) var libraryImports: [LibraryImportRecord] = []
    private(set) var libraryRefreshing = false
    private(set) var libraryIssue: String?
    private(set) var libraryHasSnapshot = false
    private var libraryService: LibraryService?
    private var libraryPublicationGeneration: UInt64 = 0
    private var libraryRefreshAttempt: UUID?
    private var libraryCreationSequences: [UUID: Int64] = [:]
    private var presentedImportIDs: Set<UUID> = []
    private var completeLibrary: LibrarySnapshot?
    private var libraryPublicationDeferred = false
    private var deferredLibraryObservation: LibraryCompleteObservation?
    private var readerBundles: ReaderBundleCoordinator?
    private var readerOpenAttempt: UUID?
    private var readerOpenBinding: ReaderArtifactBinding?
    private(set) var openingPaperID: UUID?
    private(set) var readerOpenIssue: String?
    private(set) var offlineCacheIssue: String?
    private var libraryCommandCoordinator: LibraryCommandCoordinator?
    private var libraryCommandGeneration: Int64 = -1
    private(set) var libraryCommands: [LocalLibraryCommand] = []
    private(set) var libraryCommandIssue: String?
    var showLibraryChanges = false
    var librarySignInRequired: Bool { accountID == nil }
    var canChangeLibrary: Bool { libraryCommandCoordinator != nil && completeLibrary != nil && !workOwnership.isActivating && !libraryPublicationDeferred && !needsRecovery }
    var canBeginImport: Bool { canChangeLibrary && completeLibrary != nil }
    var selectedPaper: Paper? {
        didSet {
            if oldValue?.id != selectedPaper?.id || oldValue?.artifactID != selectedPaper?.artifactID || oldValue?.fileURL != selectedPaper?.fileURL || oldValue?.readerBundle?.manifestSHA256 != selectedPaper?.readerBundle?.manifestSHA256 {
                headings = []; paperJump = nil; selectedQuote = ""
            }
        }
    }
    var libraryQuery = ""
    var discoveryQuery = ""
    var librarySort = "Recent"
    var searchExternal = false
    var searchQuery: String { get { searchExternal ? discoveryQuery : libraryQuery } set { if searchExternal { discoveryQuery = newValue } else { libraryQuery = newValue } } }
    var showAbstracts = UserDefaults.standard.object(forKey: "library.showAbstracts") as? Bool ?? true { didSet { UserDefaults.standard.set(showAbstracts, forKey: "library.showAbstracts") } }
    var showTopics = UserDefaults.standard.object(forKey: "library.showTopics") as? Bool ?? true { didSet { UserDefaults.standard.set(showTopics, forKey: "library.showTopics") } }
    var appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system" { didSet { UserDefaults.standard.set(appearance, forKey: "appearance") } }
    var paperFontSize = UserDefaults.standard.double(forKey: "paperFontSize") == 0 ? 17 : UserDefaults.standard.double(forKey: "paperFontSize") { didSet { UserDefaults.standard.set(paperFontSize, forKey: "paperFontSize") } }
    var chatFontSize = UserDefaults.standard.double(forKey: "chatFontSize") == 0 ? 17 : UserDefaults.standard.double(forKey: "chatFontSize") { didSet { UserDefaults.standard.set(chatFontSize, forKey: "chatFontSize") } }
    var message = ""
    var generalChat = true
    var chatPaperID: UUID?
    private var chatWorkspace = ChatWorkspace()
    private var branchSelections = ConversationBranchSelections()
    private(set) var chatFollowRequest: ChatFollowRequest?
    private var chatContext: String { generalChat ? "general" : "paper/\((chatPaperID ?? selectedPaper?.id)?.wire ?? "none")" }
    var chatInput: String {
        get { chatWorkspace.draft(in: chatContext) }
        set {
            chatWorkspace.setDraft(newValue, in: chatContext)
            recordCurrentDraftBranch()
            if let chatComposerID { queueDraft(chatComposerID) }
        }
    }
    var activeConversation: UUID? {
        get { chatWorkspace.conversation(in: chatContext) }
        set {
            chatWorkspace.select(newValue, in: chatContext)
            branchSelections.reconcile(with: privateState, observing: newValue)
            recordCurrentDraftBranch()
            if let chatComposerID { queueDraft(chatComposerID) }
        }
    }
    var chatComposerID: UUID? { chatWorkspace.composerID(in: chatContext) }
    var unsentDrafts: [ChatWorkspace.UnsentDraft] { chatWorkspace.unsentDrafts }
    var chatHasSaved: Bool { chatWorkspace.hasSaved(in: chatContext) }
    var chatDraftStatus: ChatWorkspace.DraftStatus { chatWorkspace.draftStatus(in: chatContext) }
    var draftsArePersistent: Bool { draftQueue != nil }
    var chatDraftIssue: String? {
        if case .failed(let message) = chatDraftStatus { return message }
        return nil
    }
    var chatDraftStatusText: String {
        guard draftsArePersistent else { return "Draft kept for this session" }
        switch chatDraftStatus {
        case .saved: return "Draft saved on this device"
        case .saving, .changed: return "Saving draft…"
        case .failed: return "Draft not saved"
        case .memoryOnly: return "Draft kept for this session"
        }
    }
    var canUsePaperChat: Bool { chatPaperID != nil || selectedPaper != nil }
    var chatPaper: Paper? { (chatPaperID ?? selectedPaper?.id).flatMap { id in papers.first { $0.id == id } ?? (selectedPaper?.id == id ? selectedPaper : nil) } }
    var chatTitle: String { chatWasDeleted ? "Deleted conversation" : (activeConversation.flatMap { privateState.revisions(for: $0).first?.payload.text } ?? "New chat") }
    var chatWasDeleted: Bool { activeConversation.map { privateState.isDeleted($0) } ?? false }
    var privateState = PrivateState() {
        didSet {
            branchSelections.reconcile(with: privateState, observing: activeConversation)
            chatWorkspace.setDeletedConversations(Set(privateState.events.values.lazy
                .filter { $0.payload.kind == .tombstone }.map { $0.payload.entityID }))
            checkpointObservedBranches()
        }
    }
    var syncStatus = "On this device"
    var syncIssue: String?
    var error: String?
    var showSignIn = false
    var showAllChats = false
    var showDiagrams = false
    var showReport = false
    var showReports = false
    var showReportsAfterComposer = false
    var reportScreenshot: UIImage?
    var reportScreen = ""
    var support: SupportService?
    var showImport = false
    var showRecovery = false
    var recoveryCode: String?
    var needsRecovery = false
    var email: String?
    var isBusy = false
    var headings: [PaperHeading] = []
    @ObservationIgnored var paperLocations: [String: PaperReadingLocation] = [:]
    var paperJump: PaperJumpRequest?
    var selectedQuote = ""
    var isGenerating: Bool { chatWorkspace.isSaving(in: chatContext) }
    var isDiscardingDraft: Bool { chatWorkspace.isDiscarding(in: chatContext) }
    private var backend: BackendClient?
    private var keys: DeviceKeys?
    private var device: LocalDevice?
    private var localPersistence = ReaderLocalPersistence()
    private var draftQueue: ReaderDraftQueue?
    private var pendingDraftCheckpoints: [UUID: ChatWorkspace.Checkpoint] = [:]
    private var draftsRestored = false
    private let retirementQueue = ReaderRetirementQueue()
    private var store: EncryptedStore? { localPersistence.store }
    private var sync: CloudSync?
    private var started = false
    private var workOwnership = ReaderWorkOwnership()
    private var sessionID: UUID { workOwnership.accountSessionID }
    private var accountID: UUID?
    private var publishedGeneration: Int64 = -1
    private var publishedPendingCount = 0
    var readerSessionID: UUID { sessionID }
    var readerDocumentScope: ReaderDocumentScope? {
        selectedPaper.map { ReaderDocumentScope(sessionID: sessionID, paperID: $0.id, artifactID: $0.artifactID, fileURL: $0.fileURL, manifestSHA256: $0.readerBundle?.manifestSHA256) }
    }
    private let configuration: BackendConfiguration?
    private let readerBundleVerification: ReaderBundleCoordinator.Verification
    private let readerBundleDirectoryReader: ReaderBundleCoordinator.DirectoryReader

    init(configuration: BackendConfiguration? = .bundled(), client: BackendClient? = nil,
         readerBundleVerification: @escaping ReaderBundleCoordinator.Verification = ReaderBundleInput.verify,
         readerBundleDirectoryReader: @escaping ReaderBundleCoordinator.DirectoryReader = { try await $0.listInstalledReaderBundles(scope: $1) }) {
        self.configuration = configuration; self.backend = client
        self.readerBundleVerification = readerBundleVerification; self.readerBundleDirectoryReader = readerBundleDirectoryReader
    }

    var configured: Bool { configuration != nil }
    var filteredPapers: [Paper] {
        let terms = libraryQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        let matching = papers.filter { paper in
            let fields = [paper.title, paper.authors, paper.abstract, paper.sourceReference ?? ""] + paper.keywords
            return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
        }
        return librarySort == "Title" ? matching.sorted { $0.title.localizedCompare($1.title) == .orderedAscending } : matching
    }
    var libraryRows: [LibraryListEntry] {
        #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && targetEnvironment(simulator)
        OfflineResourceProbe.shared.beginSearch(query: libraryQuery)
        #endif
        let terms = libraryQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        let imports = libraryImports.filter { item in
            let reference = item.sourceID + ((item.sourceRevision ?? item.requestedRevision).map { "v\($0)" } ?? "")
            let fields = [reference, item.metadata?.title ?? "", item.metadata?.abstract ?? ""]
                + (item.metadata?.authors ?? []) + (item.metadata?.categories ?? [])
            return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
        }
        // Cached mappings suppress duplicate display rows only. They never
        // acknowledge or reconcile the durable command itself.
        let knownImports = presentedImportIDs
        let localImports = libraryCommands.filter { command in
            guard case .beginImport(let source, let revision, _) = command.mutation,
                  command.isUnfinished, !knownImports.contains(command.id) else { return false }
            let fields = [command.display ?? "", source + (revision.map { "v\($0)" } ?? "")]
            return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
        }
        let rows = filteredPapers.map(LibraryListEntry.paper) + imports.map(LibraryListEntry.pending) + localImports.map(LibraryListEntry.queued)
        func sequence(_ row: LibraryListEntry) -> Int64 {
            switch row { case .paper(let paper): libraryCreationSequences[paper.id] ?? Int64.max
            case .pending(let item): item.createdSequence
            case .queued: Int64.max }
        }
        let sorted = rows.enumerated().sorted { lhs, rhs in
            if librarySort == "Title" {
                let comparison = lhs.element.title.localizedCompare(rhs.element.title)
                return comparison == .orderedSame ? lhs.element.id < rhs.element.id : comparison == .orderedAscending
            }
            let left = sequence(lhs.element), right = sequence(rhs.element)
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
        #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && targetEnvironment(simulator)
        OfflineResourceProbe.shared.finishSearch(query: libraryQuery, count: sorted.count)
        #endif
        return sorted
    }
    var chatBranches: [ConversationBranch] {
        guard let conversation = activeConversation, !chatWasDeleted else { return [] }
        var branches = privateState.conversationBranches(conversation)
        if let retained = branchSelections.selected(in: conversation), !branches.contains(where: { $0.head == retained }),
           let projection = privateState.conversationBranch(conversation, through: retained) {
            branches.append(projection)
        }
        return branches
    }
    var chatHasRemovedMessages: Bool {
        activeBranchID.flatMap { privateState.events[$0] }.map { privateState.isDeleted($0.payload.entityID) } ?? false
    }
    var activeBranchID: UUID? {
        get {
            guard let conversation = activeConversation, !chatWasDeleted else { return nil }
            return branchSelections.selected(in: conversation) ?? chatBranches.first?.head
        }
        set {
            if let conversation = activeConversation, let composerID = chatComposerID {
                guard newValue == nil || chatBranches.contains(where: { $0.head == newValue }) else { return }
                branchSelections.select(newValue, in: conversation)
                branchSelections.reconcile(with: privateState, observing: conversation)
                recordCurrentDraftBranch(explicit: true)
                queueDraft(composerID)
                chatFollowRequest = ChatFollowRequest(composerID: composerID)
            }
        }
    }
    var chatMessages: [AppliedEvent] { chatBranches.first(where: { $0.head == activeBranchID })?.messages ?? [] }
    var chatContextComplete: Bool {
        guard !chatWasDeleted else { return false }
        guard let activeBranchID else { return true }
        return chatBranches.first(where: { $0.head == activeBranchID })?.complete ?? false
    }

    func start() async {
        guard !started else { return }; started = true
        #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--offline-resource-fixture") {
            do {
                guard let mode = try OfflineResourceFixture.launchMode() else { throw OfflineResourceFixture.Failure.invalidArguments }
                try await configureOfflineResourceFixture(mode: mode)
            } catch {
                OfflineResourceProbe.shared.fail(.unexpectedState)
                show(error)
            }
            return
        }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--offline-reader-fixture") {
            do { try await configureOfflineReaderFixture(reset: ProcessInfo.processInfo.arguments.contains("--reset-offline-reader-fixture")) }
            catch { show(error) }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--draft-fixture") {
            do { try await configureDurableDraftFixture(reset: ProcessInfo.processInfo.arguments.contains("--reset-draft-fixture")) }
            catch { show(error) }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--workflow-fixture") {
            do { try configureWorkflowFixture() } catch { show(error) }
            return
        }
        #endif
        if ProcessInfo.processInfo.arguments.contains("--reader-fixture") { openSample() }
        guard let configuration else { return }
        let scope = sessionID
        do {
            let client = try backend ?? BackendClient(configuration: configuration); backend = client
            if let user = await client.currentUser(), sessionID == scope { email = user.email; accountID = user.id; try await signedIn(user, client: client, scope: scope) }
        } catch { if sessionID == scope { show(error) } }
    }

    func authenticate(email: String, password: String, create: Bool) async {
        guard let backend else { show(BackendError.unavailable); return }
        guard !isBusy else { return }
        // Only an unauthenticated local draft may cross initial sign-in. Never
        // carry a signed-in account's private context into another account.
        let guestDraft = accountID == nil && self.email == nil && chatComposerID != nil ? chatInput : nil
        let guestPaper = accountID == nil && self.email == nil && selectedPaper?.isSample == true ? selectedPaper : nil
        let guestGeneral = generalChat
        let guestTab = tab, guestMode = wideMode
        clearAccountView()
        if let guestDraft {
            if let guestPaper { papers = [guestPaper]; select(guestPaper) }
            generalChat = guestGeneral || guestPaper == nil
            chatInput = String(guestDraft.prefix(20_000))
            tab = guestTab; wideMode = guestMode
        }
        let scope = sessionID
        isBusy = true; defer { if sessionID == scope { isBusy = false } }
        do {
            if create { try await backend.signUp(email: email, password: password) }
            guard sessionID == scope else { return }
            let user = try await backend.signIn(email: email, password: password)
            guard sessionID == scope else { return }
            accountID = user.id
            self.email = user.email; showSignIn = false
            try await signedIn(user, client: backend, scope: scope)
        } catch { if sessionID == scope { show(error) } }
    }

    private func signedIn(_ user: AuthSession.User, client: BackendClient, scope: UUID) async throws {
        guard sessionID == scope, accountID == user.id, let configuration else { throw BackendError.signInRequired }
        support?.cancel()
        let feedback = try SupportService(accountID: user.id, environment: configuration.environment, backend: client)
        support = feedback
        Task { await feedback.refresh() }
        let manager = try DeviceKeys(backend: client, accountID: user.id, environment: configuration.environment)
        keys = manager
        if let cached = try manager.cachedDevice() {
            try await activate(cached, scope: scope)
            await loadLibrary(accountID: user.id, scope: scope)
            return
        }
        let preparation = try await manager.prepare()
        guard sessionID == scope, accountID == user.id else { throw BackendError.signInRequired }
        switch preparation {
        case .ready(let device): try await activate(device, scope: scope)
        case .saveRecoveryCode(let code): recoveryCode = code; needsRecovery = false; showRecovery = true
        case .recoveryRequired: recoveryCode = nil; needsRecovery = true; showRecovery = true
        }
        await loadLibrary(accountID: user.id, scope: scope)
    }

    func finishRecovery(code: String? = nil) async {
        guard let keys else { return }
        guard !isBusy else { return }
        let scope = sessionID
        isBusy = true; defer { if sessionID == scope { isBusy = false } }
        do {
            let recovered: LocalDevice
            if let code { recovered = try await keys.recover(code: code) }
            else { recovered = try await keys.confirmRecoverySaved() }
            guard sessionID == scope else { return }
            let activation = try await activate(recovered, scope: scope)
            guard sessionID == scope, workOwnership.owns(activation) else { return }
            if !needsRecovery { recoveryCode = nil; showRecovery = false }
        } catch { if sessionID == scope { show(error) } }
    }

    @discardableResult
    func activate(_ device: LocalDevice, scope: UUID) async throws -> ReaderWorkOwnership.StoreScope {
        guard sessionID == scope, accountID == device.accountID else { throw BackendError.signInRequired }
        guard let bundle = device.bundle, let backend, let configuration, let keys else { throw ReaderError.missingKey }
        try bundle.validate(accountID: device.accountID)
        let activation = workOwnership.beginActivation()
        var activated = false
        defer {
            if !activated, workOwnership.owns(activation) {
                syncStatus = "Saved on this device · Sync paused"
                syncIssue = "Private library setup did not finish. Try restoring this device again."
                // A failed key activation must not strand the prior local
                // reader in its temporary pause. Its store still validates
                // authority before any decrypted bytes can be reopened.
                resumeLibraryPublication()
                libraryCommandCoordinator?.resume()
                Task { [weak self] in
                    guard let self, self.workOwnership.owns(activation), self.accountID == device.accountID else { return }
                    self.openLocalPaperIfNeeded()
                }
            }
            workOwnership.finishActivation(activation)
        }
        let persistence = localPersistence
        // A superseded key activation may already be updating this writer.
        // Join it even if our caller is cancelled, before any owned cleanup
        // can resume work or register a deferred library checkpoint.
        await persistence.waitForActivation()
        guard workOwnership.owns(activation), accountID == device.accountID else { throw CancellationError() }
        readerOpenAttempt = nil; readerOpenBinding = nil; openingPaperID = nil
        await libraryCommandCoordinator?.pause()
        guard workOwnership.owns(activation), accountID == device.accountID else { throw CancellationError() }
        // Command callbacks have joined; at most the single model refresh can
        // still complete. No new pull starts while activation owns this phase.
        libraryPublicationDeferred = true
        await readerBundles?.pause()
        guard workOwnership.owns(activation), accountID == device.accountID else { throw BackendError.signInRequired }
        let previousSync = sync; sync = nil
        if let previousSync { retirementQueue.stop(previousSync) }
        await retirementQueue.wait()
        guard workOwnership.owns(activation), accountID == device.accountID else { throw BackendError.signInRequired }
        try Task.checkCancellation()
        let environment = configuration.environment
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("\(environment)/\(device.accountID.wire)", isDirectory: true)
        let local = try await persistence.activate(url: directory.appendingPathComponent("private-state.enc"),
                                                  accountID: device.accountID, localKey: device.localStoreKey, keys: bundle)
        let snapshot = await local.snapshot()
        guard workOwnership.owns(activation), accountID == device.accountID else { throw BackendError.signInRequired }
        try Task.checkCancellation()
        self.device = device
        self.sync = CloudSync(backend: backend, device: device, keyManager: keys, store: local) { [weak self] updated in
            guard let self, self.workOwnership.owns(activation), self.accountID == updated.accountID else { return }
            self.device = updated
        }
        prepareDrafts(snapshot: snapshot, scope: scope)
        publish(snapshot)
        checkpointAllDrafts()
        recoveryCode = nil; needsRecovery = false; showRecovery = false
        // Cached identity and device keys already suffice for local reading.
        // Do this before support flushing, key refresh, or any sync request.
        await prepareOfflineLibrary(accountID: device.accountID, scope: scope, activation: activation,
                                    deploymentID: configuration.url.absoluteString)
        guard sessionID == scope, workOwnership.owns(activation) else { throw CancellationError() }
        resumeLibraryPublication()
        do { try await prepareLibraryCommands(accountID: device.accountID, scope: scope) }
        catch {
            guard sessionID == scope, workOwnership.owns(activation) else { throw CancellationError() }
            libraryCommandCoordinator?.close(); libraryCommandCoordinator = nil
            libraryCommandIssue = "Library changes are paused. Reopen the app to check the saved queue."
        }
        guard sessionID == scope, workOwnership.owns(activation) else { throw CancellationError() }
        activated = true
        workOwnership.finishActivation(activation)
        libraryCommandCoordinator?.resume()
        openLocalPaperIfNeeded()
        await synchronize()
        return activation
    }

    func synchronize(reportErrors: Bool = false) async {
        let storeScope = workOwnership.storeScope
        if let support { await support.flush() }
        guard workOwnership.owns(storeScope), let sync, let store,
              let attempt = workOwnership.beginSync() else { return }
        syncStatus = "Syncing…"
        do {
            try await sync.synchronize()
            let snapshot = await store.snapshot()
            guard workOwnership.owns(storeScope) else { return }
            publish(snapshot)
            guard workOwnership.owns(attempt) else { return }
            syncIssue = nil
            syncStatus = publishedPendingCount == 0 ? "Synced" : "\(publishedPendingCount) changes waiting to sync"
            if publishedPendingCount > 0 { Task { if self.workOwnership.owns(attempt) { await self.synchronize() } } }
        } catch {
            // Earlier pages may already be durable even if a later request
            // failed. Expose them without letting an older attempt replace a
            // newer attempt's status, error, or recovery presentation.
            let snapshot = await store.snapshot()
            guard workOwnership.owns(storeScope) else { return }
            publish(snapshot)
            guard workOwnership.owns(attempt) else { return }
            syncStatus = "Saved on this device · Sync paused"
            syncIssue = (error as? LocalizedError)?.errorDescription ?? "Sync could not finish. Your saved work remains on this device."
            if let keyError = error as? ReaderError, keyError == .missingKey || keyError == .staleEpoch {
                recoveryCode = nil; needsRecovery = true; showRecovery = true
            } else if reportErrors { show(error) }
        }
    }

    func beginReport(afterMenu: Bool = false) {
        let scope = sessionID
        Task {
            if afterMenu { try? await Task.sleep(for: .milliseconds(350)) }
            guard sessionID == scope else { return }
            reportScreen = "\(tab.rawValue) / \(wideMode.rawValue)"
            reportScreenshot = showRecovery || showSignIn ? nil : ScreenshotCapture.currentWindow()
            showReport = true
        }
    }

    func signOut() async {
        guard let backend else { return }
        clearAccountView()
        let scope = sessionID
        do { try await backend.signOut() } catch { if sessionID == scope { show(error) } }
    }

    /// Sign-out clears presentation immediately; wait here before retiring any
    /// backing files or opening a replacement owner in a workflow harness.
    func waitForLocalRetirement() async { await retirementQueue.wait() }

    private func clearAccountView() {
        workOwnership = ReaderWorkOwnership(); accountID = nil; isBusy = false
        let oldCommands = libraryCommandCoordinator; libraryCommandCoordinator = nil
        oldCommands?.close()
        let oldBundles = readerBundles; readerBundles = nil
        oldBundles?.close()
        readerOpenAttempt = nil; readerOpenBinding = nil; openingPaperID = nil; readerOpenIssue = nil; offlineCacheIssue = nil
        let oldLibrary = libraryService; libraryService = nil
        Task { await oldLibrary?.invalidate() }
        libraryImports = []; libraryCreationSequences = [:]; presentedImportIDs = []; libraryPublicationGeneration = 0
        libraryRefreshAttempt = nil; libraryRefreshing = false; libraryHasSnapshot = false; libraryIssue = nil
        completeLibrary = nil; libraryCommands = []; libraryCommandGeneration = -1
        libraryPublicationDeferred = false; deferredLibraryObservation = nil
        libraryCommandIssue = nil; showLibraryChanges = false; showImport = false
        publishedGeneration = -1; publishedPendingCount = 0
        support?.cancel(); support = nil
        draftQueue?.close(); draftQueue = nil; pendingDraftCheckpoints = [:]; draftsRestored = false
        retirementQueue.retire(sync: sync, persistence: localPersistence, commands: oldCommands, bundles: oldBundles)
        sync = nil
        device = nil; localPersistence = ReaderLocalPersistence(); keys = nil
        privateState = PrivateState(); papers = []; selectedPaper = nil; chatPaperID = nil
        chatWorkspace = ChatWorkspace(); branchSelections = ConversationBranchSelections(); chatFollowRequest = nil
        selectedQuote = ""; headings = []; paperJump = nil; paperLocations = [:]
        libraryQuery = ""; discoveryQuery = ""; searchExternal = false
        generalChat = true
        email = nil; recoveryCode = nil; needsRecovery = false; showRecovery = false; showReports = false; showReport = false; reportScreenshot = nil
        showAllChats = false; showDiagrams = false
        showReportsAfterComposer = false; error = nil; tab = .library; wideMode = .library; syncStatus = "On this device"
        syncIssue = nil
    }

    func refreshLibrary() async {
        guard let accountID, !workOwnership.isActivating, !libraryPublicationDeferred else { return }
        let scope = sessionID
        await loadLibrary(accountID: accountID, scope: scope)
        if sessionID == scope, !workOwnership.isActivating { await libraryCommandCoordinator?.retry() }
    }

    private func prepareLibraryCommands(accountID: UUID, scope: UUID) async throws {
        guard sessionID == scope, self.accountID == accountID, let configuration, let backend else { throw CancellationError() }
        if libraryCommandCoordinator != nil { return }
        let library = libraryService ?? LibraryService(scope: .init(accountID: accountID, readerSessionID: scope), transport: backend)
        libraryService = library
        let commandScope = try LibraryCommandScope(accountID: accountID, deploymentID: configuration.url.absoluteString)
        let coordinator = LibraryCommandCoordinator(scope: commandScope, persistence: localPersistence, library: library, transport: backend,
            publish: { [weak self] commands, snapshot in
                guard let self, self.sessionID == scope, self.accountID == accountID, self.libraryService === library else { return }
                if let snapshot { self.publishLibrary(snapshot) }
                if commands.generation >= self.libraryCommandGeneration {
                    self.libraryCommandGeneration = commands.generation
                    self.libraryCommands = commands.commands.filter { ![.finished, .cancelled].contains($0.phase) }
                }
            }, report: { [weak self] issue in
                guard let self, self.sessionID == scope, self.accountID == accountID else { return }
                self.libraryCommandIssue = issue
            })
        libraryCommandCoordinator = coordinator
        try await coordinator.restore()
        guard sessionID == scope, libraryCommandCoordinator === coordinator else { throw CancellationError() }
    }

    private func prepareOfflineLibrary(accountID: UUID, scope: UUID, activation: ReaderWorkOwnership.StoreScope,
                                       deploymentID: String) async {
        guard sessionID == scope, self.accountID == accountID, workOwnership.owns(activation) else { return }
        do {
            let cacheScope = try LibraryCommandScope(accountID: accountID, deploymentID: deploymentID)
            let coordinator: ReaderBundleCoordinator
            if let existing = readerBundles {
                guard existing.scope == cacheScope else { throw LibraryCommandError.invalidScope }
                coordinator = existing; coordinator.resume()
            } else {
                coordinator = ReaderBundleCoordinator(scope: cacheScope, persistence: localPersistence,
                    verify: readerBundleVerification, readDirectory: readerBundleDirectoryReader, report: { [weak self] issue in
                    guard let self, self.sessionID == scope, self.accountID == accountID else { return }
                    self.offlineCacheIssue = issue
                })
                readerBundles = coordinator
                // Recovery may have obtained a live library before local keys
                // existed. Preserve that authority when its first cache opens.
                if let observation = deferredLibraryObservation {
                    try coordinator.applyLiveObservation(observation)
                } else if let observation = completeLibrary?.observation {
                    // This publication predates the pause. Its write can start
                    // now, leaving the single deferred slot for a refresh that
                    // is still in flight; observe preserves their disk order.
                    try coordinator.observe(observation)
                }
            }
            let restored = try await coordinator.restore()
            guard sessionID == scope, self.accountID == accountID, workOwnership.owns(activation), readerBundles === coordinator else { return }
            switch restored.presentation {
            case .success(let presentation):
                // A disk presentation never creates a live observation, nor
                // replaces a complete network publication that already won.
                if let presentation, completeLibrary == nil {
                    presentLibraryEntries(Array(presentation.entries.values))
                }
            case .failure: offlineCacheIssue = "Your saved library couldn’t be opened. Your notes and conversations are still available."
            }
            if case .failure = restored.installations {
                offlineCacheIssue = "Downloaded papers couldn’t be listed. Your notes and conversations are still available."
            }
            #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && targetEnvironment(simulator)
            if let mode = OfflineResourceProbe.shared.mode, mode != .seed {
                let presentation = try restored.presentation.get(), list = try restored.installations.get()
                guard mode == .empty || presentation?.committedCursor == Int64(OfflineResourceFixture.rowCount) else {
                    throw OfflineResourceFixture.Failure.unexpectedState
                }
                OfflineResourceProbe.shared.restored(rows: presentation?.entries.count ?? 0,
                    installations: list.installations.count, ciphertextBytes: list.ciphertextBytes)
            }
            #endif
        } catch {
            guard sessionID == scope, workOwnership.owns(activation) else { return }
            #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && targetEnvironment(simulator)
            if OfflineResourceProbe.shared.mode != nil { OfflineResourceProbe.shared.fail(.unexpectedState) }
            #endif
            offlineCacheIssue = "Offline reading couldn’t be restored. Your saved data has been preserved."
        }
    }

    func importPaper(_ input: String) async throws {
        let reference = try ArxivReference(input)
        guard canBeginImport, let snapshot = completeLibrary, let commands = libraryCommandCoordinator else { throw ReaderError.storageUnavailable }
        let scope = sessionID
        _ = try await commands.enqueue(.beginImport(sourceID: reference.sourceID, requestedRevision: reference.revision,
                                                    observedCursor: snapshot.committedCursor), display: "arXiv \(reference.identifier)")
        guard sessionID == scope else { throw CancellationError() }
        searchExternal = false; libraryQuery = ""
    }

    func removePaper(_ paper: Paper) async {
        guard !paper.isSample, canChangeLibrary, let snapshot = completeLibrary,
              let item = snapshot.items.first(where: { $0.documentID == paper.id && $0.visible }),
              let commands = libraryCommandCoordinator else { return }
        let scope = sessionID
        do {
            _ = try await commands.enqueue(.setMembership(documentID: item.documentID, present: false,
                                                         expectedRevision: item.membershipRevision, approvalID: item.approvalID),
                                           display: String(paper.title.unicodeScalars.prefix(200)))
        } catch { if sessionID == scope, !(error is CancellationError) { show(error) } }
    }

    func changeImport(_ item: LibraryImportRecord, retry: Bool) async {
        guard canChangeLibrary, let commands = libraryCommandCoordinator,
              completeLibrary?.imports.contains(where: { $0.id == item.id && $0.intentRevision == item.intentRevision }) == true,
              !retry || (item.phase == .failed && item.retryable) else { return }
        let scope = sessionID
        let mutation: LibraryMutation = retry ? .retryImport(importID: item.id, expectedRevision: item.intentRevision)
            : .cancelImport(importID: item.id, expectedRevision: item.intentRevision)
        do { _ = try await commands.enqueue(mutation, display: String((item.metadata?.title ?? "arXiv \(item.sourceID)").unicodeScalars.prefix(200))) }
        catch { if sessionID == scope, !(error is CancellationError) { show(error) } }
    }

    func cancelLibraryChange(_ command: LocalLibraryCommand) async {
        let scope = sessionID
        do { try await libraryCommandCoordinator?.cancel(command) }
        catch { if sessionID == scope, !(error is CancellationError) { show(error) } }
    }

    func dismissLibraryChange(_ command: LocalLibraryCommand) async {
        let scope = sessionID
        do { try await libraryCommandCoordinator?.dismiss(command) }
        catch { if sessionID == scope, !(error is CancellationError) { show(error) } }
    }

    private func loadLibrary(accountID: UUID, scope: UUID) async {
        guard let backend, sessionID == scope, self.accountID == accountID,
              !libraryRefreshing, !workOwnership.isActivating, !libraryPublicationDeferred else { return }
        let libraryScope = LibraryScope(accountID: accountID, readerSessionID: scope)
        let service: LibraryService
        if let existing = libraryService { service = existing }
        else {
            service = LibraryService(scope: libraryScope, transport: backend)
            libraryService = service
        }
        let attempt = UUID()
        libraryRefreshAttempt = attempt; libraryRefreshing = true
        defer {
            if sessionID == scope, libraryService === service, libraryRefreshAttempt == attempt { libraryRefreshing = false }
        }
        do {
            let snapshot = try await service.refresh()
            guard sessionID == scope, self.accountID == accountID, libraryService === service,
                  snapshot.scope == libraryScope else { return }
            publishLibrary(snapshot)
            if libraryRefreshAttempt == attempt { libraryIssue = nil }
        } catch {
            guard sessionID == scope, self.accountID == accountID, libraryService === service,
                  libraryRefreshAttempt == attempt, !(error is CancellationError) else { return }
            libraryIssue = libraryHasSnapshot ? "Couldn’t refresh your library. Showing the last complete update." : "Couldn’t load your library."
        }
    }

    private func publishLibrary(_ snapshot: LibrarySnapshot) {
        guard snapshot.scope.accountID == accountID, snapshot.scope.readerSessionID == sessionID else { return }
        if snapshot.generation > libraryPublicationGeneration {
            completeLibrary = snapshot
            do {
                if libraryPublicationDeferred {
                    try readerBundles?.applyLiveObservation(snapshot.observation)
                    // One model refresh is allowed to cross activation. If a
                    // future caller breaks that bound, retain live policy but
                    // halt persistence instead of skipping a sticky block.
                    guard deferredLibraryObservation == nil else {
                        readerBundles?.haltCachePersistence()
                        throw ReaderError.storageUnavailable
                    }
                    deferredLibraryObservation = snapshot.observation
                } else { try readerBundles?.observe(snapshot.observation) }
            }
            catch { offlineCacheIssue = "Your latest library update wasn’t saved for offline use. Reopen the app to try again." }
            presentLibraryEntries(snapshot.entries)
            libraryPublicationGeneration = snapshot.generation
        }
    }

    /// Synchronous registration preserves accepted observation order before
    /// another refresh or command drain may start, including cancellation.
    private func resumeLibraryPublication() {
        readerBundles?.resume()
        if let observation = deferredLibraryObservation {
            do {
                guard let readerBundles else { throw ReaderError.storageUnavailable }
                try readerBundles.observe(observation)
            } catch { offlineCacheIssue = "Your latest library update wasn’t saved for offline use. Reopen the app to try again." }
        }
        deferredLibraryObservation = nil
        libraryPublicationDeferred = false
    }

    private func presentLibraryEntries(_ entries: [LibraryEntry]) {
        #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && targetEnvironment(simulator)
        OfflineResourceProbe.shared.begin(.publication)
        defer { OfflineResourceProbe.shared.finish(.publication, count: entries.count) }
        #endif
        let previous = Dictionary(papers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = entries.compactMap { if case .item(let item) = $0, item.visible { return item }; return nil }
        let next = items.map { item in
            let cached = previous[item.documentID]
            let installed = readerBundles?.installation(documentID: item.documentID, artifactID: item.artifactID)
            let readable: Bool
            if let installed {
                readable = readerBundles?.permits(installed) == true && installed.binding.manifestSHA256 == cached?.readerBundle?.manifestSHA256
            } else { readable = item.canReadStructured }
            let file = readable && cached?.artifactID == item.artifactID ? cached?.fileURL : nil
            return Paper(id: item.documentID, title: item.metadata?.title ?? "Untitled paper",
                         authors: item.metadata?.authors.joined(separator: ", ") ?? "",
                         year: item.metadata?.publishedAt.flatMap { Int($0.prefix(4)) },
                         abstract: item.metadata?.abstract ?? "", keywords: item.metadata?.categories ?? [],
                         fileURL: file, artifactID: item.artifactID, sourceID: item.sourceID, sourceRevision: item.sourceRevision,
                         readerBundle: file == nil ? nil : cached?.readerBundle)
        }
        let samples = papers.filter { candidate in candidate.isSample && !next.contains(where: { $0.id == candidate.id }) }
        // Samples have no server membership. Preserve the local sample
        // without letting it replace a real document-backed item.
        papers = next + samples
        presentedImportIDs = Set(entries.compactMap { if case .import(let item) = $0 { return item.id }; return nil })
        libraryImports = entries.compactMap { if case .import(let item) = $0, item.visible { return item }; return nil }
        libraryCreationSequences = Dictionary(uniqueKeysWithValues: items.map { ($0.documentID, $0.createdSequence) })
        libraryHasSnapshot = true
        if let selectedPaper, !selectedPaper.isSample {
            self.selectedPaper = papers.first { $0.id == selectedPaper.id }
            if self.selectedPaper == nil {
                readerBundles?.cancelOpening()
                readerOpenAttempt = nil; readerOpenBinding = nil; openingPaperID = nil; readerOpenIssue = nil
                if tab == .paper { tab = .library }
                if wideMode == .reader || wideMode == .browse { wideMode = .library }
            }
            else { openLocalPaperIfNeeded() }
        }
    }

    func select(_ paper: Paper) {
        // UI closures may retain a previously loaded row across quarantine,
        // removal or account changes. Resolve its current membership first.
        guard let current = papers.first(where: {
            $0.id == paper.id && $0.artifactID == paper.artifactID && $0.isSample == paper.isSample
        }), current.isSample || accountID != nil else { return }
        selectedPaper = current; chatPaperID = current.id; tab = .paper
        if wideMode != .browse { wideMode = .reader }
        generalChat = false
        openLocalPaperIfNeeded()
    }

    func retryOpeningSelectedPaper() { openLocalPaperIfNeeded() }

    private func openLocalPaperIfNeeded() {
        if let paper = selectedPaper, !paper.isSample, let bundle = paper.readerBundle {
            let installed = readerBundles?.localCopy(documentID: paper.id, artifactID: paper.artifactID)
            if installed?.binding.manifestSHA256 != bundle.manifestSHA256 {
                let metadata = paper.displaying(nil)
                papers = papers.map { $0.id == paper.id ? metadata : $0 }
                selectedPaper = metadata
            }
        }
        if readerOpenAttempt != nil, let paper = selectedPaper, paper.readerBundle == nil,
           let coordinator = readerBundles,
           let installation = coordinator.localCopy(documentID: paper.id, artifactID: paper.artifactID),
           installation.binding == readerOpenBinding { return }
        readerOpenAttempt = nil; readerOpenBinding = nil; openingPaperID = nil; readerOpenIssue = nil
        readerBundles?.cancelOpening()
        guard let paper = selectedPaper, !paper.isSample, paper.readerBundle == nil,
              let coordinator = readerBundles,
              let installation = coordinator.installation(documentID: paper.id, artifactID: paper.artifactID) else { return }
        guard coordinator.permits(installation) else {
            readerOpenIssue = "This downloaded copy is currently unavailable."
            return
        }
        guard !workOwnership.isActivating, !libraryPublicationDeferred else { return }
        let attempt = UUID(), scope = sessionID
        do {
            #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && targetEnvironment(simulator)
            OfflineResourceProbe.shared.begin(.open)
            #endif
            let opening = try coordinator.open(installation)
            readerOpenAttempt = attempt; readerOpenBinding = installation.binding; openingPaperID = paper.id
            Task {
                defer {
                    if self.sessionID == scope, self.readerOpenAttempt == attempt {
                        self.openingPaperID = nil; self.readerOpenAttempt = nil; self.readerOpenBinding = nil
                    }
                }
                do {
                    let result = try await opening.value
                    guard self.sessionID == scope, self.readerBundles === coordinator, self.readerOpenAttempt == attempt,
                          let current = self.selectedPaper, current.id == paper.id, current.artifactID == paper.artifactID,
                          coordinator.permits(result.installation) else { return }
                    let displayed = current.displaying(result.bundle)
                    self.papers = self.papers.map { $0.id == displayed.id ? displayed : $0 }
                    self.selectedPaper = displayed
                    #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && targetEnvironment(simulator)
                    if OfflineResourceProbe.shared.mode != nil {
                        let bytes = result.bundle.manifest.members.reduce(0) { $0 + (result.bundle.data(for: $1.path)?.count ?? 0) }
                        let pixels = result.bundle.manifest.members.filter { $0.role == "image" }
                            .reduce(0) { $0 + ($1.width ?? 0) * ($1.height ?? 0) }
                        OfflineResourceProbe.shared.opened(memberBytes: bytes, imagePixels: pixels)
                    }
                    #endif
                } catch {
                    guard self.sessionID == scope, self.readerOpenAttempt == attempt, !(error is CancellationError) else { return }
                    self.readerOpenIssue = "This downloaded copy couldn’t be opened."
                }
            }
        } catch { readerOpenIssue = "This downloaded copy couldn’t be opened." }
    }

    func askAboutSelectedPaper() {
        guard let selectedPaper else { return }
        chatPaperID = selectedPaper.id; generalChat = false; tab = .chat; wideMode = .reader
    }

    func openConversation(_ id: UUID) {
        guard let event = privateState.revisions(for: id).first, event.payload.kind == .conversation else { return }
        if let documentID = event.payload.documentID {
            chatPaperID = documentID; selectedPaper = papers.first { $0.id == documentID }; generalChat = false; wideMode = .reader
            openLocalPaperIfNeeded()
        } else { generalChat = true; wideMode = .chat }
        activeConversation = id; tab = .chat
    }

    func openUnsentDraft(_ id: UUID) {
        guard let draft = unsentDrafts.first(where: { $0.id == id }) else { return }
        let documentID = draft.context.hasPrefix("paper/") ? UUID(uuidString: String(draft.context.dropFirst(6))) : nil
        guard draft.context == "general" || documentID != nil, chatWorkspace.selectDraft(id) != nil else { return }
        if let documentID {
            chatPaperID = documentID; selectedPaper = papers.first { $0.id == documentID }
            generalChat = false; wideMode = .reader
            openLocalPaperIfNeeded()
        } else { generalChat = true; wideMode = .chat }
        if let checkpoint = chatWorkspace.checkpoint(for: id), let conversation = checkpoint.conversationID,
           let head = checkpoint.selectedHead {
            branchSelections.select(head, in: conversation)
            branchSelections.reconcile(with: privateState, observing: conversation)
        }
        tab = .chat
        recordCurrentDraftBranch()
        queueDraft(id)
    }

    func discardUnsentDraft(_ id: UUID) {
        guard let draftQueue else { chatWorkspace.discardDraft(id); return }
        guard let removal = chatWorkspace.prepareDiscard(id) else { return }
        let scope = sessionID
        do {
            let task = try draftQueue.discard(id: id, revision: removal.revision)
            pendingDraftCheckpoints.removeValue(forKey: id)
            Task {
                do {
                    try await task.value
                    guard sessionID == scope else { return }
                    if let replacement = chatWorkspace.completeDiscard(removal) { queueDraft(replacement) }
                } catch {
                    guard sessionID == scope else { return }
                    chatWorkspace.failDiscard(removal)
                    queueDraft(id)
                    show(error)
                }
            }
        } catch { chatWorkspace.failDiscard(removal); queueDraft(id); show(error) }
    }
    func openSample() {
        let bundle: VerifiedReaderBundle
        do { bundle = try ReaderBundleLoader.sample() }
        catch { self.error = "The offline sample couldn’t be verified. Try reinstalling this development build."; return }
        let paper = Paper(id: UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!, title: "Reading machine learning papers", authors: "Science Reader · offline sample", year: 2026,
            abstract: "A local reading fixture with equations, a wide table, figure, and references. It demonstrates the reader without uploading a paper or using credits.",
            keywords: ["attention", "optimization", "evaluation"], fileURL: bundle.entryURL,
            artifactID: UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000002"), isSample: true, readerBundle: bundle)
        if !papers.contains(where: { $0.id == paper.id }) { papers.append(paper) }
        select(paper)
    }

    func selectionAction(_ action: SelectionAction, quote: String) {
        selectedQuote = quote
        let prompts: [SelectionAction: String] = [
            .define: "Define this in the context of the paper: \(quote)",
            .relevance: "Explain why this passage matters to the paper: \(quote)",
            .similar: "Find related research and explain the connections: \(quote)",
            .ingest: "Find and add the paper referenced in this passage: \(quote)"
        ]
        newChat(general: false); chatInput = prompts[action] ?? quote
        tab = .chat; wideMode = .reader
        if email == nil { showSignIn = true }
        // This build saves encrypted questions only; there is no provider route
        // to consent to yet. Provider consent must bind a captured future turn.
        else {
            let scope = sessionID, context = chatContext, composer = chatComposerID, prompt = chatInput, documentScope = readerDocumentScope
            Task {
                guard sessionID == scope, chatContext == context, chatComposerID == composer,
                      chatInput == prompt, readerDocumentScope == documentScope else { return }
                await sendMessage()
            }
        }
    }

    func selectionAction(_ action: SelectionAction, selection: ReaderSelection, scope: ReaderDocumentScope) {
        guard readerDocumentScope == scope, let bundle = selectedPaper?.readerBundle,
              bundle.manifestSHA256 == scope.manifestSHA256,
              let quote = try? selection.resolvedQuote(in: bundle), !quote.isEmpty else { return }
        selectionAction(action, quote: quote)
    }

    func newChat(general: Bool) {
        guard general || canUsePaperChat else { return }
        generalChat = general; activeConversation = nil
    }

    func sendMessage() async {
        guard !workOwnership.isActivating else { return }
        guard generalChat || canUsePaperChat else { return }
        guard !chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard chatContextComplete else { error = chatWasDeleted ? "This conversation was deleted. Start a new chat to continue." : "Sync this conversation before continuing; an earlier message is still missing."; return }
        guard let store, let device else { showSignIn = true; return }
        guard !isGenerating, accountID == device.accountID else { return }
        let scope = sessionID
        let storeScope = workOwnership.storeScope, persistence = localPersistence
        let documentID = generalChat ? nil : (chatPaperID ?? selectedPaper?.id)
        var parents = activeBranchID.map { [$0] } ?? []
        if parents.isEmpty, let activeConversation, let root = privateState.revisions(for: activeConversation).first { parents = [root.id] }
        recordCurrentDraftBranch()
        guard let submission = chatWorkspace.beginSubmission(in: chatContext) else { return }
        // A remote user message is not a local scrolling action. Capture the
        // accepted submit gesture before saving, scoped to its own composer.
        chatFollowRequest = ChatFollowRequest(composerID: submission.composerID)
        let branchChoice = branchSelections.capture(in: submission.conversationID)
        do {
            guard let checkpoint = submission.checkpoint else { throw ReaderError.invalidEvent }
            var events: [(id: UUID, event: PrivateEvent)] = []
            if let root = submission.rootID {
                events.append((root, PrivateEvent(kind: .conversation, entityID: submission.conversationID, documentID: documentID, text: String(submission.text.prefix(100)))))
                parents = [root]
            }
            events.append((submission.id, PrivateEvent(kind: .message, entityID: submission.id, parents: parents,
                conversationID: submission.conversationID, documentID: documentID, text: submission.text, role: .user, status: .complete)))
            let batch = events
            let committing = try persistence.acceptWrite { local in
                try await local.commitDraftSubmission(batch, deviceID: device.deviceID,
                    consuming: DraftConsumption(draft: checkpoint, submissionID: submission.id))
            }
            let committed = try await committing.value
            let snapshot = await store.snapshot()
            guard sessionID == scope else { return }
            branchSelections.complete(branchChoice, head: committed.envelopes.last?.id)
            chatWorkspace.complete(submission, stored: committed.draft, receiptID: committed.receiptID)
            if workOwnership.owns(storeScope), publish(snapshot) {
                syncStatus = syncIssue == nil ? "Saved on this device" : "Saved on this device · Sync paused"
            }
            branchSelections.reconcile(with: privateState, observing: submission.conversationID)
            if let head = branchSelections.selected(in: submission.conversationID) {
                chatWorkspace.recordSelectedHead(head, for: submission.composerID, explicit: false)
            }
            queueDraft(submission.composerID)
            // Local acknowledgement restores this composer's controls. Slow
            // network synchronization must not block a different conversation.
            Task { if self.sessionID == scope { await self.synchronize() } }
        } catch {
            if sessionID == scope {
                chatWorkspace.fail(submission)
                if workOwnership.owns(storeScope) { show(error) }
            }
        }
    }

    func show(_ error: Error) { self.error = (error as? LocalizedError)?.errorDescription ?? "This operation could not finish. Your existing saved data has been preserved." }

    private func prepareDrafts(snapshot: LocalStoreSnapshot, scope: UUID) {
        if !draftsRestored {
            chatWorkspace.restore(snapshot.drafts)
            var restoredConversations = Set<UUID>()
            for draft in snapshot.drafts {
                if let conversation = draft.conversationID, restoredConversations.insert(conversation).inserted {
                    branchSelections.select(draft.selectedHead, in: conversation)
                }
            }
            draftsRestored = true
        }
        guard draftQueue == nil else { return }
        draftQueue = ReaderDraftQueue(persistence: localPersistence) { [weak self] requested, result in
            guard let self, self.sessionID == scope,
                  let checkpoint = self.pendingDraftCheckpoints[requested.id], checkpoint.draft.revision == requested.revision else { return }
            self.pendingDraftCheckpoints.removeValue(forKey: requested.id)
            switch result {
            case .success(let stored):
                self.chatWorkspace.acknowledge(checkpoint, stored: stored)
                if self.chatWorkspace.checkpoint(for: requested.id) != stored { self.queueDraft(requested.id) }
            case .failure:
                self.chatWorkspace.failCheckpoint(checkpoint, message: "Draft not saved on this device. Try saving it again.")
            }
        }
    }

    private func recordCurrentDraftBranch(explicit: Bool = false) {
        guard let id = chatComposerID else { return }
        chatWorkspace.recordSelectedHead(activeBranchID, for: id, explicit: explicit)
    }

    private func checkpointObservedBranches() {
        for draft in chatWorkspace.checkpoints {
            guard let conversation = draft.conversationID,
                  let head = branchSelections.selected(in: conversation), head != draft.selectedHead else { continue }
            chatWorkspace.recordSelectedHead(head, for: draft.id, explicit: false)
            queueDraft(draft.id)
        }
    }

    private func queueDraft(_ id: UUID) {
        guard let draftQueue, let checkpoint = chatWorkspace.beginCheckpoint(for: id) else { return }
        pendingDraftCheckpoints[id] = checkpoint
        do { try draftQueue.save(checkpoint.draft) }
        catch {
            pendingDraftCheckpoints.removeValue(forKey: id)
            chatWorkspace.failCheckpoint(checkpoint, message: "Draft not saved on this device. Try saving it again.")
        }
    }

    private func checkpointAllDrafts() {
        for draft in chatWorkspace.checkpoints { queueDraft(draft.id) }
    }

    func retryDraftSave() { if let chatComposerID { queueDraft(chatComposerID) } }

    func flushDrafts() async {
        checkpointAllDrafts()
        await localPersistence.waitForAcceptedWrites()
    }

    #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && targetEnvironment(simulator)
    private func configureOfflineResourceFixture(mode: OfflineResourceFixture.Mode) async throws {
        let probe = OfflineResourceProbe.shared
        probe.configure(mode)
        let directory = try OfflineResourceFixture.directory(for: mode)
        if mode == .seed, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try OfflineResourceFixture.requireExistingSeed(at: directory, mode: mode)
        probe.begin(.restore)
        let fixtureDevice = try OfflineResourceFixture.device()
        guard let keys = fixtureDevice.bundle else { throw ReaderError.missingKey }
        accountID = fixtureDevice.accountID; device = fixtureDevice
        let activation = workOwnership.beginActivation()
        defer { workOwnership.finishActivation(activation) }
        let local = try await localPersistence.activate(url: directory.appendingPathComponent("state.sqlite"),
            accountID: fixtureDevice.accountID, localKey: fixtureDevice.localStoreKey, keys: keys)
        let snapshot = await local.snapshot()
        prepareDrafts(snapshot: snapshot, scope: sessionID); publish(snapshot)
        checkpointAllDrafts()
        let cacheScope = try LibraryCommandScope(accountID: fixtureDevice.accountID,
            deploymentID: OfflineResourceFixture.deployment)
        let coordinator = ReaderBundleCoordinator(scope: cacheScope, persistence: localPersistence)
        readerBundles = coordinator
        if mode == .seed {
            probe.didSeed(try await OfflineResourceFixture.seed(using: coordinator))
        } else {
            await prepareOfflineLibrary(accountID: fixtureDevice.accountID, scope: sessionID,
                activation: activation, deploymentID: OfflineResourceFixture.deployment)
        }
        tab = .library; wideMode = .library
    }
    #endif

    #if DEBUG && targetEnvironment(simulator)
    /// The reset flag is explicit installation intent in this test-only
    /// account. Relaunch reads only encrypted rows; it never reloads the sample
    /// resource as a substitute for a missing or damaged installed copy.
    func configureOfflineReaderFixture(reset: Bool) async throws {
        let fixtureDevice = try OfflineReaderFixture.device()
        guard let keys = fixtureDevice.bundle else { throw ReaderError.missingKey }
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("offline-reader-fixture", isDirectory: true)
        if reset, FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        accountID = fixtureDevice.accountID; email = "offline-fixture@example.invalid"; device = fixtureDevice
        let activation = workOwnership.beginActivation()
        defer { workOwnership.finishActivation(activation) }
        let local = try await localPersistence.activate(url: directory.appendingPathComponent("state.sqlite"),
            accountID: fixtureDevice.accountID, localKey: fixtureDevice.localStoreKey, keys: keys)
        let snapshot = await local.snapshot()
        prepareDrafts(snapshot: snapshot, scope: sessionID); publish(snapshot)
        checkpointAllDrafts()
        workOwnership.finishActivation(activation)
        let cacheScope = try LibraryCommandScope(accountID: fixtureDevice.accountID, deploymentID: OfflineReaderFixture.deployment)
        let coordinator = ReaderBundleCoordinator(scope: cacheScope, persistence: localPersistence)
        readerBundles = coordinator
        if reset {
            _ = try await coordinator.observe(OfflineReaderFixture.observation()).value
            let authored = try ReaderBundleLoader.sample()
            let binding = try ReaderArtifactBinding(scope: cacheScope, documentID: OfflineReaderFixture.document,
                artifactID: OfflineReaderFixture.artifact, manifestSHA256: ReaderBundleLoader.sampleManifestSHA256)
            let members = Dictionary(uniqueKeysWithValues: authored.manifest.members.map { ($0.path, authored.data(for: $0.path)!) })
            _ = try await coordinator.install(binding: binding, manifestData: authored.manifestData, members: members).value
        }
        await prepareOfflineLibrary(accountID: fixtureDevice.accountID, scope: sessionID, activation: activation,
                                    deploymentID: OfflineReaderFixture.deployment)
        tab = .library; wideMode = .library
    }

    /// Synthetic process-restart journeys use the real encrypted SQLite path,
    /// with public fixture keys and no Auth, networking, or provider setup.
    func configureDurableDraftFixture(reset: Bool) async throws {
        let fixtureAccount = UUID(uuidString: "eeeeeeee-0000-4000-8000-000000000001")!
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("workflow-draft-fixture", isDirectory: true)
        if reset, FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        let encoded = try JSONSerialization.data(withJSONObject: [
            "accountID": fixtureAccount.uuidString, "epoch": 1,
            "contentKeys": ["1": Data(repeating: 17, count: 32).base64EncodedString()],
            "managementToken": Data(repeating: 23, count: 32).base64EncodedString()
        ])
        let bundle = try JSONDecoder().decode(KeyBundle.self, from: encoded)
        var fixtureDevice = LocalDevice.create(accountID: fixtureAccount, localStoreKey: Data(repeating: 31, count: 32))
        fixtureDevice.bundle = bundle
        accountID = fixtureAccount; email = "draft-fixture@example.invalid"; device = fixtureDevice
        let activation = workOwnership.beginActivation()
        defer { workOwnership.finishActivation(activation) }
        let local = try await localPersistence.activate(url: directory.appendingPathComponent("state.sqlite"),
            accountID: fixtureAccount, localKey: fixtureDevice.localStoreKey, keys: bundle)
        openSample()
        let snapshot = await local.snapshot()
        prepareDrafts(snapshot: snapshot, scope: sessionID)
        publish(snapshot)
        checkpointAllDrafts()
        tab = .library; wideMode = .library
    }
    #endif

    @discardableResult
    func publish(_ snapshot: LocalStoreSnapshot) -> Bool {
        guard snapshot.generation >= publishedGeneration else { return false }
        publishedGeneration = snapshot.generation; publishedPendingCount = snapshot.pendingCount; privateState = snapshot.state
        return true
    }
}

/// Store replacement and sync ordering are different clocks. A newer network
/// attempt may update presentation without changing a local database generation.
struct ReaderWorkOwnership {
    struct StoreScope: Equatable, Sendable {
        let accountSessionID: UUID
        let epoch: UUID
    }
    struct SyncAttempt: Equatable, Sendable {
        let store: StoreScope
        let id: UUID
    }
    let accountSessionID: UUID
    private(set) var storeScope: StoreScope
    private(set) var isActivating = false
    private var latestSync: SyncAttempt?

    init() {
        let session = UUID()
        accountSessionID = session
        storeScope = StoreScope(accountSessionID: session, epoch: UUID())
    }

    mutating func beginActivation() -> StoreScope {
        storeScope = StoreScope(accountSessionID: accountSessionID, epoch: UUID())
        latestSync = nil; isActivating = true
        return storeScope
    }

    mutating func finishActivation(_ scope: StoreScope) {
        if owns(scope) { isActivating = false }
    }

    mutating func beginSync() -> SyncAttempt? {
        guard !isActivating else { return nil }
        let attempt = SyncAttempt(store: storeScope, id: UUID())
        latestSync = attempt
        return attempt
    }

    func owns(_ scope: StoreScope) -> Bool { storeScope == scope }
    func owns(_ attempt: SyncAttempt) -> Bool { owns(attempt.store) && latestSync == attempt && !isActivating }
}

/// One writer per account's local database. Activation waits for writes already
/// accepted by the UI before updating keys and keeps the same SQLite actor.
@MainActor
final class ReaderLocalPersistence {
    private(set) var store: EncryptedStore?
    private(set) var isActivating = false
    private(set) var isRetired = false
    private var accountID: UUID?
    private var localKey: Data?
    private var storageURL: URL?
    private var writes: [UUID: Task<Void, Never>] = [:]
    private var activationWaiters: [CheckedContinuation<Void, Never>] = []

    func performWrite(_ operation: @escaping @Sendable (EncryptedStore) async throws -> [EventEnvelope]) async throws -> [EventEnvelope] {
        try await acceptWrite(operation).value
    }

    /// Registers ownership synchronously, before a later sign-out can retire
    /// this writer. Once accepted, the old account's work is always drained.
    func acceptWrite<Value: Sendable>(_ operation: @escaping @Sendable (EncryptedStore) async throws -> Value) throws -> Task<Value, Error> {
        guard !isRetired, !isActivating, let store else { throw ReaderError.storageUnavailable }
        let id = UUID(), task = Task { try await operation(store) }
        let completion = Task { _ = await task.result }
        writes[id] = completion
        Task { [weak self] in
            await completion.value
            self?.writes.removeValue(forKey: id)
        }
        return task
    }

    func activate(url: URL, accountID: UUID, localKey: Data, keys: KeyBundle) async throws -> EncryptedStore {
        guard !isRetired, !isActivating else { throw ReaderError.storageUnavailable }
        try keys.validate(accountID: accountID)
        guard localKey.count == 32 else { throw ReaderError.invalidKey }
        isActivating = true
        defer {
            isActivating = false
            let waiters = activationWaiters; activationWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        // Writes themselves are not cancelled when activation or sign-out
        // begins: they belong to the old account and may already be committing.
        await waitForAcceptedWrites()
        try Task.checkCancellation()
        guard !isRetired else { throw CancellationError() }
        if let store {
            guard self.accountID == accountID else { throw ReaderError.wrongAccount }
            guard self.localKey == localKey else { throw ReaderError.invalidKey }
            guard storageURL == url.standardizedFileURL else { throw ReaderError.storageUnavailable }
            try await store.updateKeys(keys)
            try Task.checkCancellation()
            guard !isRetired else { throw CancellationError() }
            return store
        }
        let opened = try EncryptedStore(url: url, accountID: accountID, localKey: localKey, keys: keys)
        self.accountID = accountID; self.localKey = localKey; storageURL = url.standardizedFileURL
        store = opened
        return opened
    }

    func retire() { isRetired = true }

    /// An accepted key update belongs to this writer until it settles.
    /// Cancellation of a replacement owner does not shorten that lifetime.
    func waitForActivation() async {
        while isActivating {
            await withCheckedContinuation { activationWaiters.append($0) }
        }
    }

    func waitForAcceptedWrites() async {
        for task in Array(writes.values) { _ = await task.result }
    }
}

/// UI/account clearing is immediate, while old accepted local writes and sync
/// transactions finish before any later session opens another SQLite actor.
@MainActor
final class ReaderRetirementQueue {
    private var pending: (id: UUID, task: Task<Void, Never>)?

    func retire(sync: CloudSync?, persistence: ReaderLocalPersistence, commands: LibraryCommandCoordinator? = nil,
                bundles: ReaderBundleCoordinator? = nil) {
        commands?.close()
        bundles?.close()
        persistence.retire()
        sync?.cancel()
        enqueue(sync: sync, persistence: persistence, commands: commands, bundles: bundles)
    }

    func stop(_ sync: CloudSync) {
        sync.cancel()
        enqueue(sync: sync, persistence: nil)
    }

    private func enqueue(sync: CloudSync?, persistence: ReaderLocalPersistence?, commands: LibraryCommandCoordinator? = nil,
                         bundles: ReaderBundleCoordinator? = nil) {
        let previous = pending?.task, id = UUID()
        let task = Task { [weak self] in
            if let previous { await previous.value }
            if let commands { await commands.stop() }
            if let bundles { await bundles.stop() }
            if let sync { await sync.stop() }
            if let persistence {
                await persistence.waitForActivation()
                await persistence.waitForAcceptedWrites()
            }
            if self?.pending?.id == id { self?.pending = nil }
        }
        pending = (id, task)
    }

    func wait() async {
        while let task = pending?.task { await task.value }
    }
}
