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
enum PaperOfflineStatus: Equatable { case none, available, unavailable }

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
    var papers: [Paper] = [] { didSet { libraryPapersChanged(from: oldValue) } }
    private(set) var libraryImports: [LibraryImportRecord] = [] { didSet { if libraryImports != oldValue { librarySearchSourceChanged(); updateImportPolling() } } }
    private var importPollTask: Task<Void, Never>?
    private(set) var libraryRefreshing = false
    private(set) var libraryIssue: String?
    private(set) var libraryHasSnapshot = false
    private var libraryService: LibraryService?
    private var libraryPublicationGeneration: UInt64 = 0
    private var libraryRefreshAttempt: UUID?
    private var libraryCreationSequences: [UUID: Int64] = [:] { didSet { if libraryCreationSequences != oldValue { librarySearchSourceChanged() } } }
    private var presentedImportIDs: Set<UUID> = [] { didSet { if presentedImportIDs != oldValue { librarySearchSourceChanged() } } }
    private var completeLibrary: LibrarySnapshot?
    private var libraryPublicationDeferred = false
    private var deferredLibraryObservation: LibraryCompleteObservation?
    private var readerBundles: ReaderBundleCoordinator?
    private var readerOpenAttempt: UUID?
    private var readerOpenBinding: ReaderArtifactBinding?
    private(set) var openingPaperID: UUID?
    private(set) var readerOpenIssue: String?
    private var readerDownloadAttempt: (id: UUID, documentID: UUID)?
    private(set) var offlineCacheIssue: String?
    private var libraryCommandCoordinator: LibraryCommandCoordinator?
    private var libraryCommandGeneration: Int64 = -1 { didSet { if libraryCommandGeneration != oldValue { queueLibrarySearch() } } }
    private(set) var libraryCommands: [LocalLibraryCommand] = [] { didSet { if libraryCommands != oldValue { librarySearchSourceChanged() } } }
    private(set) var libraryCommandIssue: String?
    var showLibraryChanges = false
    var librarySignInRequired: Bool { accountID == nil }
    var canChangeLibrary: Bool { libraryCommandCoordinator != nil && completeLibrary != nil && !workOwnership.isActivating && !libraryPublicationDeferred && !needsRecovery }
    var canBeginImport: Bool { canChangeLibrary && completeLibrary != nil }
    var selectedPaper: Paper? {
        didSet {
            if oldValue?.id != selectedPaper?.id || oldValue?.artifactID != selectedPaper?.artifactID || oldValue?.fileURL != selectedPaper?.fileURL || oldValue?.readerBundle?.manifestSHA256 != selectedPaper?.readerBundle?.manifestSHA256 {
                headings = []; paperJump = nil; selectedQuote = ""
                releaseUnselectedReaderBundles()
            }
        }
    }
    var libraryQuery = "" { didSet { if libraryQuery != oldValue { queueLibrarySearch() } } }
    var discoveryQuery = ""
    enum DiscoveryState: Equatable { case idle, searching, results, failed(String) }
    private(set) var discoveryResults: [DiscoveryResult] = []
    private(set) var discoveryState: DiscoveryState = .idle
    private var discoveryGeneration = 0
    private var discoveryTask: Task<Void, Never>?
    var librarySort = "Recent" { didSet { if librarySort != oldValue { queueLibrarySearch() } } }
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
    private(set) var authentication: AuthenticationCoordinator?
    private(set) var signInPresentationID: UUID?
    private(set) var accountPreparationIssue: String?
    @ObservationIgnored private var accountPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var authenticationRetirement: Task<Void, Never>?
    @ObservationIgnored private var pendingRecoveryPresentation: (sessionID: UUID, accountID: UUID)?
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
    /// The local encrypted save of a question (not the AI answer).
    var isGenerating: Bool { chatWorkspace.isSaving(in: chatContext) }
    // Answers in flight, keyed by the composer that sent the question. Each is
    // fenced to its own account session, conversation and saved question.
    private var chatGenerations: [UUID: ChatGeneration] = [:]
    private var chatAnswerIssues: [UUID: ChatAnswerIssue] = [:]
    /// Throttled partial text by generation ID; only the transcript reads it.
    private var chatStreamingText: [UUID: String] = [:]
    @ObservationIgnored private var chatStreamBuffer: [UUID: String] = [:]
    @ObservationIgnored private var chatStreamFlushes: Set<UUID> = []
    @ObservationIgnored private var pendingSelection: (composerID: UUID, prompt: String, quote: String)?
    var chatConsentPrompt: ChatConsentPrompt?
    private(set) var creditBalance: CreditBalance?
    private(set) var creditBalanceIssue: String?
    private let chatTransportOverride: (any ChatTransport)?
    private let chatConsentStore: any AuthenticationCredentialStore
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
    private var accountID: UUID? { didSet { if accountID != oldValue { librarySearchSourceChanged() } } }
    private var publishedGeneration: Int64 = -1
    private var publishedPendingCount = 0
    var readerSessionID: UUID { sessionID }
    var readerDocumentScope: ReaderDocumentScope? {
        selectedPaper.map { ReaderDocumentScope(sessionID: sessionID, paperID: $0.id, artifactID: $0.artifactID, fileURL: $0.fileURL, manifestSHA256: $0.readerBundle?.manifestSHA256) }
    }
    private let configuration: BackendConfiguration?
    private let readerBundleVerification: ReaderBundleCoordinator.Verification
    private let readerBundleDirectoryReader: ReaderBundleCoordinator.DirectoryReader
    private let librarySearchWorker: LibrarySearchCoordinator.Worker?
    private(set) var libraryRows: [LibraryListEntry] = []
    private(set) var librarySearchPending = false
    private(set) var librarySearchIssue: String?
    @ObservationIgnored private var librarySearchCoordinator: LibrarySearchCoordinator?
    @ObservationIgnored private var librarySearchPreparation: Task<Void, Never>?
    @ObservationIgnored private var librarySearchSourceRevision: UInt64 = 0
    @ObservationIgnored private var librarySearchSourceDirty = true
    @ObservationIgnored private var librarySearchCandidates: [LibrarySearchCandidate] = []
    @ObservationIgnored private var libraryRowLookup: [String: LibraryListEntry] = [:]
    @ObservationIgnored private var libraryMatchedIDs: [String] = []
    @ObservationIgnored private var librarySearchTicket: LibrarySearchTicket?
    @ObservationIgnored private var librarySearchCandidateRevision: UInt64 = 0
    @ObservationIgnored private var completedLibrarySearchKey: LibrarySearchKey?

    init(configuration: BackendConfiguration? = .bundled(), client: BackendClient? = nil,
         readerBundleVerification: @escaping ReaderBundleCoordinator.Verification = ReaderBundleInput.verify,
         readerBundleDirectoryReader: @escaping ReaderBundleCoordinator.DirectoryReader = { try await $0.listInstalledReaderBundles(scope: $1) },
         librarySearchWorker: LibrarySearchCoordinator.Worker? = nil,
         chatTransport: (any ChatTransport)? = nil, chatConsentStore: (any AuthenticationCredentialStore)? = nil) {
        var resolvedConfiguration = configuration
        var resolvedClient = client
        var fixtureFailed = false
        var resolvedTransport = chatTransport
        var resolvedConsentStore: any AuthenticationCredentialStore = chatConsentStore ?? KeychainAuthenticationCredentialStore()
        #if DEBUG && targetEnvironment(simulator) && !OFFLINE_RESOURCE_MEASUREMENTS
        if ChatFixtureTransport.isEnabled {
            // Never a network transport: scripted answers and in-memory consent.
            resolvedTransport = ChatFixtureTransport.launchTransport()
            resolvedConsentStore = ChatFixtureTransport.launchConsentStore()
        }
        if AuthenticationWorkflowFixture.isEnabled {
            do {
                let fixture = try AuthenticationWorkflowFixture.makeBackend()
                resolvedConfiguration = fixture.configuration; resolvedClient = fixture.client
            } catch {
                // A requested local fixture must never fall back to the bundled
                // backend or a real provider when its isolated setup fails.
                resolvedConfiguration = nil; resolvedClient = nil; fixtureFailed = true
            }
        }
        #endif
        self.configuration = resolvedConfiguration; self.backend = resolvedClient
        self.chatTransportOverride = resolvedTransport; self.chatConsentStore = resolvedConsentStore
        self.readerBundleVerification = readerBundleVerification; self.readerBundleDirectoryReader = readerBundleDirectoryReader
        self.librarySearchWorker = librarySearchWorker
        if fixtureFailed { error = "The local sign-in fixture couldn’t be prepared." }
    }

    var configured: Bool { configuration != nil }
    var isSignedIn: Bool { accountID != nil }
    var filteredPapers: [Paper] {
        libraryRows.compactMap { if case .paper(let paper) = $0 { return paper }; return nil }
    }

    private var currentLibrarySearchKey: LibrarySearchKey {
        LibrarySearchKey(sessionID: sessionID, accountID: accountID,
            sourceRevision: librarySearchSourceRevision, query: libraryQuery,
            sort: librarySort == "Title" ? .title : .recent, commandRevision: libraryCommandGeneration)
    }

    var librarySearchKeepsCurrentRows: Bool {
        guard let completed = completedLibrarySearchKey else { return false }
        let current = currentLibrarySearchKey
        return completed.sessionID == current.sessionID && completed.accountID == current.accountID &&
            completed.query == current.query && completed.sort == current.sort
    }

    private func libraryPapersChanged(from previous: [Paper]) {
        // Installing verified bytes changes row presentation, not searchable
        // metadata. Keep the worker's snapshot free of reading bundles.
        let currentIDs = Set(papers.map(\.id))
        libraryRowLookup = libraryRowLookup.filter {
            if case .paper(let paper) = $0.value { return currentIDs.contains(paper.id) }
            return true
        }
        for paper in papers {
            let row = LibraryListEntry.paper(paper)
            libraryRowLookup[row.id] = row
        }
        if librarySearchKeepsCurrentRows {
            // A local removal disappears synchronously, including while a
            // replacement search is still joining its cancelled predecessor.
            libraryRows = libraryMatchedIDs.compactMap { libraryRowLookup[$0] }
        }
        let sameText = previous.count == papers.count && zip(previous, papers).allSatisfy { old, new in
            old.id == new.id && old.title == new.title && old.authors == new.authors &&
            old.abstract == new.abstract && old.keywords == new.keywords &&
            old.sourceID == new.sourceID && old.sourceRevision == new.sourceRevision
        }
        if !sameText || librarySearchSourceDirty { librarySearchSourceChanged() }
    }

    private func librarySearchSourceChanged() {
        librarySearchSourceRevision &+= 1
        librarySearchSourceDirty = true
        queueLibrarySearch()
    }

    private func queueLibrarySearch() {
        // Invalidate synchronously. A -> B -> A is new intent even when a
        // cancellation-ignoring older A finishes with the same query text.
        librarySearchCoordinator?.invalidate()
        librarySearchTicket = nil
        if !librarySearchKeepsCurrentRows {
            libraryMatchedIDs = []; libraryRows = []; completedLibrarySearchKey = nil
        }
        librarySearchPending = true; librarySearchIssue = nil
        #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && targetEnvironment(simulator)
        OfflineResourceProbe.shared.beginSearch(query: libraryQuery)
        #endif
        guard librarySearchPreparation == nil else { return }
        // One queued turn coalesces synchronous library/command publication.
        // Query changes reuse the immutable metadata snapshot.
        librarySearchPreparation = Task { @MainActor [weak self] in
            guard let self else { return }
            self.librarySearchPreparation = nil
            var mayReuse = self.librarySearchKeepsCurrentRows &&
                self.completedLibrarySearchKey?.sourceRevision == self.librarySearchCandidateRevision
            if self.librarySearchSourceDirty { mayReuse = self.prepareLibrarySearchSource() && mayReuse }
            if self.librarySearchKeepsCurrentRows {
                self.libraryRows = self.libraryMatchedIDs.compactMap { self.libraryRowLookup[$0] }
            }
            if mayReuse {
                self.completedLibrarySearchKey = self.currentLibrarySearchKey
                self.librarySearchPending = false
                return
            }
            if self.librarySearchCoordinator == nil {
                let publish: @MainActor (LibrarySearchEvent) -> Void = { [weak self] in self?.acceptLibrarySearch($0) }
                if let worker = self.librarySearchWorker {
                    self.librarySearchCoordinator = LibrarySearchCoordinator(worker: worker, publish: publish)
                } else { self.librarySearchCoordinator = LibrarySearchCoordinator(publish: publish) }
            }
            self.librarySearchTicket = self.librarySearchCoordinator?.submit(
                key: self.currentLibrarySearchKey, candidates: self.librarySearchCandidates)
        }
    }

    private func prepareLibrarySearchSource() -> Bool {
        #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && targetEnvironment(simulator)
        let start = DispatchTime.now().uptimeNanoseconds
        #endif
        var candidates: [LibrarySearchCandidate] = []
        var lookup: [String: LibraryListEntry] = [:]
        func append(_ row: LibraryListEntry, fields: [String], sequence: Int64) {
            candidates.append(LibrarySearchCandidate(id: row.id, title: row.title,
                fields: fields, recentSequence: sequence, position: candidates.count))
            lookup[row.id] = row
        }
        for paper in papers {
            append(.paper(paper), fields: [paper.title, paper.authors, paper.abstract, paper.sourceReference ?? ""] + paper.keywords,
                   sequence: libraryCreationSequences[paper.id] ?? Int64.max)
        }
        for item in libraryImports {
            let reference = item.sourceID + ((item.sourceRevision ?? item.requestedRevision).map { "v\($0)" } ?? "")
            append(.pending(item), fields: [reference, item.metadata?.title ?? "", item.metadata?.abstract ?? ""]
                + (item.metadata?.authors ?? []) + (item.metadata?.categories ?? []), sequence: item.createdSequence)
        }
        for command in libraryCommands {
            // Cached mappings suppress duplicate presentation only; they do
            // not resolve the durable command or authorize a mutation.
            guard case .beginImport(let source, let revision, _) = command.mutation,
                  command.isUnfinished, !presentedImportIDs.contains(command.id) else { continue }
            append(.queued(command), fields: [command.display ?? "", source + (revision.map { "v\($0)" } ?? "")],
                   sequence: Int64.max)
        }
        let equivalent = candidates == librarySearchCandidates
        librarySearchCandidates = candidates; libraryRowLookup = lookup
        librarySearchCandidateRevision = librarySearchSourceRevision
        librarySearchSourceDirty = false
        #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && targetEnvironment(simulator)
        OfflineResourceProbe.shared.searchSourceBuilt(rows: candidates.count,
            elapsedMS: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        #endif
        return equivalent
    }

    private func acceptLibrarySearch(_ event: LibrarySearchEvent) {
        switch event {
        case .completed(let result):
            guard librarySearchTicket == result.ticket, currentLibrarySearchKey == result.ticket.key else { return }
            #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && targetEnvironment(simulator)
            let start = DispatchTime.now().uptimeNanoseconds
            #endif
            let rows = result.rowIDs.compactMap { libraryRowLookup[$0] }
            guard rows.count == result.rowIDs.count else {
                librarySearchPending = false; librarySearchIssue = "Search couldn’t finish. Try again."
                return
            }
            libraryMatchedIDs = result.rowIDs; libraryRows = rows
            completedLibrarySearchKey = result.ticket.key
            librarySearchPending = false; librarySearchIssue = nil
            #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && targetEnvironment(simulator)
            OfflineResourceProbe.shared.searchCompleted(query: result.ticket.key.query,
                workerElapsedMS: result.workerElapsedMilliseconds,
                publicationElapsedMS: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000,
                count: rows.count)
            #endif
        case .failed(let ticket):
            guard librarySearchTicket == ticket, currentLibrarySearchKey == ticket.key else { return }
            librarySearchPending = false; librarySearchIssue = "Search couldn’t finish. Try again."
        }
    }

    func retryLibrarySearch() { queueLibrarySearch() }

    /// Join the accepted search, including replacements, without polling or
    /// creating a second synchronous search path for tests or callers.
    func waitForLibrarySearch() async {
        while librarySearchPreparation != nil || librarySearchPending {
            if let preparation = librarySearchPreparation { await preparation.value }
            if let coordinator = librarySearchCoordinator { await coordinator.waitForIdle() }
        }
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
                let fixtureSession = sessionID
                try await configureOfflineResourceFixture(mode: mode)
                if ProcessInfo.processInfo.arguments.contains("--offline-resource-settled") {
                    // The restoration function has returned: no decoded
                    // presentation result is retained by this sampling frame.
                    let persistence = localPersistence
                    guard let coordinator = readerBundles else { throw OfflineResourceFixture.Failure.unexpectedState }
                    await waitForLibrarySearch()
                    await coordinator.waitUntilIdle()
                    await persistence.waitForAcceptedWrites()
                    let expectedRows = mode == .empty ? 0 : OfflineResourceFixture.rowCount
                    let expectedSearch = currentLibrarySearchKey
                    let expectedCandidateRevision = librarySearchCandidateRevision
                    let expectedCandidateCount = librarySearchCandidates.count
                    let expectedLookupCount = libraryRowLookup.count
                    let expectedMatchCount = libraryMatchedIDs.count
                    let isCurrent: @MainActor (ReaderTab) -> Bool = { [weak self] destination in
                        guard let self else { return false }
                        return self.sessionID == fixtureSession && self.accountID == OfflineResourceFixture.account &&
                            self.readerBundles === coordinator && self.localPersistence === persistence &&
                            !self.workOwnership.isActivating && !self.librarySearchPending && self.librarySearchIssue == nil &&
                            self.currentLibrarySearchKey == expectedSearch && self.libraryQuery.isEmpty &&
                            self.tab == destination && self.wideMode == .library && self.offlineCacheIssue == nil &&
                            self.readerOpenAttempt == nil && self.openingPaperID == nil && self.selectedPaper == nil &&
                            self.papers.count == expectedRows && self.libraryRows.count == expectedRows &&
                            self.librarySearchCandidateRevision == expectedCandidateRevision &&
                            self.librarySearchCandidates.count == expectedCandidateCount &&
                            self.libraryRowLookup.count == expectedLookupCount && self.libraryMatchedIDs.count == expectedMatchCount
                    }
                    await OfflineResourceProbe.shared.sampleSettledFootprints { isCurrent(.library) }
                    #if OFFLINE_RESOURCE_MEASUREMENTS
                    await OfflineResourceProbe.shared.samplePresentationCycle(isCurrent: isCurrent) { [weak self] destination in
                        // The ordinary compact-layout tab action assigns the
                        // same destination; wideMode remains Library here.
                        self?.tab = destination
                    }
                    #endif
                }
            } catch {
                OfflineResourceProbe.shared.fail(.unexpectedState)
                show(error)
            }
            return
        }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--offline-reader-fixture") {
            let variant: OfflineReaderFixture.Variant = ProcessInfo.processInfo.arguments.contains("--mathpix-reader-fixture") ? .mathpix : .authored
            do { try await configureOfflineReaderFixture(reset: ProcessInfo.processInfo.arguments.contains("--reset-offline-reader-fixture"), variant: variant) }
            catch { show(error) }
            return
        }
        // The chat fixture answers into the same synthetic encrypted store.
        if ProcessInfo.processInfo.arguments.contains("--draft-fixture") || ChatFixtureTransport.isEnabled {
            do { try await configureDurableDraftFixture(reset: ProcessInfo.processInfo.arguments.contains("--reset-draft-fixture")) }
            catch { show(error) }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--workflow-fixture") {
            do { try configureWorkflowFixture() } catch { show(error) }
            return
        }
        #endif
        #if DEBUG && targetEnvironment(simulator) && !OFFLINE_RESOURCE_MEASUREMENTS
        if AuthenticationWorkflowFixture.isEnabled {
            openSample(); tab = .library; wideMode = .library
        }
        #endif
        if ProcessInfo.processInfo.arguments.contains("--reader-fixture") { openSample() }
        guard let configuration else { return }
        let scope = sessionID
        do {
            let client = try backend ?? BackendClient(configuration: configuration); backend = client
            let existing = await client.currentUser()
            if let user = existing, sessionID == scope {
                email = user.email; accountID = user.id
                beginAccountPreparation(user, client: client, scope: scope)
                await accountPreparationTask?.value
            }
            #if DEBUG && targetEnvironment(simulator)
            // Live staging journey tests sign in a synthetic @example.invalid
            // account supplied by the test runner. Never present in releases.
            let live = ProcessInfo.processInfo.environment
            if existing == nil, sessionID == scope, let liveEmail = live["SCIENCE_READER_LIVE_JOURNEY_EMAIL"],
               liveEmail.hasSuffix("@example.invalid"), let livePassword = live["SCIENCE_READER_LIVE_JOURNEY_PASSWORD"] {
                await authenticate(email: liveEmail, password: livePassword, create: false)
            }
            #endif
        } catch { if sessionID == scope { show(error) } }
    }

    func openSignIn() {
        guard !isSignedIn else {
            if needsRecovery || recoveryCode != nil || accountPreparationIssue != nil { requestRecoveryPresentation() }
            return
        }
        // Retain the previous sheet's identity through its actual onDismiss.
        // A new presentation cannot inherit that old dismissal callback.
        guard signInPresentationID == nil else { return }
        do {
            if backend == nil, let configuration { backend = try BackendClient(configuration: configuration) }
        } catch { show(error); return }
        beginAuthenticationContext()
        guard let backend else {
            signInPresentationID = UUID(); showSignIn = true
            return
        }
        let owner = AuthenticationCoordinator(backend: backend, predecessor: authenticationRetirement) { [weak self] acceptance in
            self?.acceptAuthentication(acceptance) ?? false
        }
        authentication = owner
        signInPresentationID = owner.open(readerSessionID: sessionID).id
        showSignIn = true
    }

    func closeSignIn(presentationID: UUID) {
        guard signInPresentationID == presentationID else { return }
        authentication?.close(presentationID: presentationID)
        showSignIn = false
    }

    func authenticationSheetDismissed() {
        guard let id = signInPresentationID else { return }
        if let authentication {
            authentication.didDismiss(presentationID: id)
            retainAuthenticationRetirement(authentication)
        }
        authentication = nil; signInPresentationID = nil; showSignIn = false
        if let pending = pendingRecoveryPresentation,
           pending.sessionID == sessionID, pending.accountID == accountID {
            pendingRecoveryPresentation = nil; showRecovery = true
        }
    }

    private func acceptAuthentication(_ acceptance: AuthenticationCoordinator.Acceptance) -> Bool {
        guard acceptance.presentationID == signInPresentationID,
              authentication?.presentation?.id == acceptance.presentationID,
              authentication?.phase == .accepted(accountID: acceptance.user.id),
              acceptance.readerSessionID == sessionID, accountID == nil, let backend else { return false }
        accountID = acceptance.user.id; email = acceptance.user.email
        // Register account work before requesting dismissal; no await occurs
        // between coordinator validation, model acceptance and this handoff.
        beginAccountPreparation(acceptance.user, client: backend, scope: acceptance.readerSessionID)
        showSignIn = false
        return true
    }

    private func beginAccountPreparation(_ user: AuthSession.User, client: BackendClient, scope: UUID) {
        guard sessionID == scope, accountID == user.id, accountPreparationTask == nil else { return }
        accountPreparationIssue = nil; isBusy = true
        accountPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.sessionID == scope, self.accountID == user.id {
                    self.accountPreparationTask = nil; self.isBusy = false
                }
            }
            do { try await self.signedIn(user, client: client, scope: scope) }
            catch {
                guard self.sessionID == scope, self.accountID == user.id else { return }
                self.accountPreparationIssue = "Couldn’t prepare your private library. Your saved work is still on this device."
                self.requestRecoveryPresentation()
            }
        }
    }

    func retryAccountPreparation() async {
        guard let backend, let accountID, accountPreparationTask == nil else { return }
        let scope = sessionID
        guard let user = await backend.currentUser(), user.id == accountID, sessionID == scope else { return }
        beginAccountPreparation(user, client: backend, scope: scope)
        await accountPreparationTask?.value
    }

    private func requestRecoveryPresentation() {
        guard let accountID else { return }
        if signInPresentationID != nil {
            pendingRecoveryPresentation = (sessionID, accountID)
        } else { showRecovery = true }
    }

    private func retainAuthenticationRetirement(_ owner: AuthenticationCoordinator) {
        let predecessor = authenticationRetirement
        authenticationRetirement = Task {
            await predecessor?.value
            await owner.waitForRetirement()
        }
    }

    private func beginAuthenticationContext() {
        // Only an unauthenticated local draft may cross initial sign-in. Never
        // carry a signed-in account's private context into another account.
        let wasGuest = accountID == nil
        let guestDraft = wasGuest && chatComposerID != nil ? chatInput : nil
        let guestPaper = wasGuest && selectedPaper?.isSample == true ? selectedPaper : nil
        let guestGeneral = generalChat
        let guestTab = tab, guestMode = wideMode
        clearAccountView()
        if wasGuest {
            if let guestPaper { papers = [guestPaper]; select(guestPaper) }
            generalChat = guestGeneral || guestPaper == nil
            if let guestDraft { chatInput = String(guestDraft.prefix(20_000)) }
            tab = guestTab; wideMode = guestMode
        }
    }

    /// Kept for deterministic development fixtures, not the customer sheet.
    func authenticate(email: String, password: String, create: Bool) async {
        guard let backend else { show(BackendError.unavailable); return }
        guard !isBusy else { return }
        beginAuthenticationContext()
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
        case .saveRecoveryCode(let code): recoveryCode = code; needsRecovery = false; requestRecoveryPresentation()
        case .recoveryRequired: recoveryCode = nil; needsRecovery = true; requestRecoveryPresentation()
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
        recoveryCode = nil; needsRecovery = false; showRecovery = false; pendingRecoveryPresentation = nil
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
                recoveryCode = nil; needsRecovery = true; requestRecoveryPresentation()
            } else if reportErrors { show(error) }
        }
    }

    func beginReport(afterMenu: Bool = false) {
        let scope = sessionID
        Task {
            if afterMenu { try? await Task.sleep(for: .milliseconds(350)) }
            guard sessionID == scope else { return }
            reportScreen = "\(tab.rawValue) / \(wideMode.rawValue)"
            reportScreenshot = showRecovery || signInPresentationID != nil ? nil : ScreenshotCapture.currentWindow()
            showReport = true
        }
    }

    func signOut() async {
        guard let backend else { return }
        clearAccountView()
        let scope = sessionID
        let predecessor = authenticationRetirement
        let task = Task { [weak self] in
            await predecessor?.value
            do { try await backend.signOut() }
            catch { if let self, self.sessionID == scope { self.show(error) } }
        }
        authenticationRetirement = task
        await task.value
    }

    /// Sign-out clears presentation immediately; wait here before retiring any
    /// backing files or opening a replacement owner in a workflow harness.
    func waitForLocalRetirement() async { await retirementQueue.wait() }

    private func clearAccountView() {
        // Before the old writer retires: fence answers and keep their partials.
        retireChatGenerations()
        if let authentication {
            authentication.invalidate()
            retainAuthenticationRetirement(authentication)
        }
        authentication = nil; showSignIn = false
        accountPreparationTask?.cancel(); accountPreparationTask = nil
        accountPreparationIssue = nil; pendingRecoveryPresentation = nil
        workOwnership = ReaderWorkOwnership(); accountID = nil; isBusy = false
        librarySearchCandidates = []; libraryRowLookup = [:]
        librarySearchSourceChanged()
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
        importPollTask?.cancel(); importPollTask = nil
        privateState = PrivateState(); papers = []; selectedPaper = nil; chatPaperID = nil
        chatWorkspace = ChatWorkspace(); branchSelections = ConversationBranchSelections(); chatFollowRequest = nil
        selectedQuote = ""; headings = []; paperJump = nil; paperLocations = [:]
        libraryQuery = ""; discoveryQuery = ""; searchExternal = false
        discoveryTask?.cancel(); discoveryResults = []; discoveryState = .idle
        feedTask?.cancel(); feedResults = []; feedState = .idle; feedCategory = nil
        generalChat = true
        email = nil; recoveryCode = nil; needsRecovery = false; showRecovery = false; showReports = false; showReport = false; reportScreenshot = nil
        showAllChats = false; showDiagrams = false
        showReportsAfterComposer = false; error = nil; tab = .library; wideMode = .library; syncStatus = "On this device"
        syncIssue = nil
    }

    /// While an import is converting on the server, refresh the library on a
    /// bounded schedule (4 s, then 15 s after two minutes) so progress and the
    /// finished paper appear without a manual refresh. Owned by one session.
    private func updateImportPolling() {
        let isActive: (LibraryImportRecord) -> Bool = { [.accepted, .resolving, .acquiring].contains($0.phase) }
        guard libraryImports.contains(where: isActive), accountID != nil else {
            importPollTask?.cancel(); importPollTask = nil; return
        }
        guard importPollTask == nil else { return }
        let scope = sessionID
        importPollTask = Task { [weak self] in
            let started = Date()
            while !Task.isCancelled {
                let delay: Double = Date().timeIntervalSince(started) > 120 ? 15 : 4
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled, self.sessionID == scope else { return }
                guard self.libraryImports.contains(where: isActive), self.accountID != nil else { self.importPollTask = nil; return }
                if !self.libraryRefreshing { await self.refreshLibrary() }
            }
        }
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
                    presentLibraryProjection(presentation.rows, validatedEntryCount: presentation.validatedEntryCount)
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
                if let elapsed = restored.projectionElapsedMilliseconds {
                    OfflineResourceProbe.shared.restorationProjected(elapsedMS: elapsed)
                } else { throw OfflineResourceFixture.Failure.unexpectedState }
                OfflineResourceProbe.shared.restored(rows: presentation?.validatedEntryCount ?? 0,
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

    /// Searches arXiv for the current discovery query. The latest query owns
    /// the results; failures are shown as failures, never as empty results.
    func runDiscovery() {
        let query = discoveryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        discoveryTask?.cancel(); discoveryGeneration += 1
        let generation = discoveryGeneration
        guard !query.isEmpty else { discoveryResults = []; discoveryState = .idle; return }
        guard let backend, let accountID else { discoveryState = .failed("Sign in to search arXiv."); return }
        discoveryState = .searching
        let scope = sessionID
        discoveryTask = Task {
            do {
                let results = try await backend.discover(query: query, accountID: accountID)
                guard self.sessionID == scope, self.discoveryGeneration == generation else { return }
                self.discoveryResults = results; self.discoveryState = .results
            } catch {
                guard self.sessionID == scope, self.discoveryGeneration == generation, !(error is CancellationError) else { return }
                self.discoveryState = .failed("arXiv search isn’t available right now. Try again in a moment.")
            }
        }
    }

    // MARK: Feed — newest papers in the library's own arXiv categories. The
    // categories are derived on the device; only the chosen category is sent.
    enum FeedState: Equatable { case idle, loading, loaded, failed(String) }
    private(set) var feedResults: [DiscoveryResult] = []
    private(set) var feedState: FeedState = .idle
    private(set) var feedCategory: String?
    private var feedGeneration = 0
    private var feedTask: Task<Void, Never>?

    var feedCategories: [String] {
        var counts: [String: Int] = [:]
        for paper in papers where !paper.isSample { for keyword in paper.keywords where keyword.contains(".") || keyword.contains("-") { counts[keyword, default: 0] += 1 } }
        let top = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(6).map(\.key)
        return top.isEmpty ? ["cs.LG", "cs.CL", "cs.AI", "stat.ML"] : top
    }

    func selectFeedCategory(_ category: String) { feedCategory = category; loadFeed() }

    func loadFeed() {
        let category = feedCategory ?? feedCategories.first ?? "cs.LG"
        feedCategory = category
        feedTask?.cancel(); feedGeneration += 1
        let generation = feedGeneration
        guard let backend, let accountID else { feedState = .failed("Sign in to see new papers."); return }
        feedState = .loading
        let scope = sessionID
        feedTask = Task {
            do {
                let results = try await backend.feed(category: category, accountID: accountID)
                guard self.sessionID == scope, self.feedGeneration == generation else { return }
                self.feedResults = results; self.feedState = .loaded
            } catch {
                guard self.sessionID == scope, self.feedGeneration == generation, !(error is CancellationError) else { return }
                self.feedState = .failed("New papers aren’t available right now. Try again in a moment.")
            }
        }
    }

    /// arXiv identifiers already in the library or being added.
    var librarySourceIDs: Set<String> {
        Set(papers.compactMap(\.sourceID) + libraryImports.filter { $0.visible }.map(\.sourceID))
    }

    func addDiscovered(_ result: DiscoveryResult) async throws {
        try await importPaper(result.sourceID, stayInSearch: true)
    }

    func importPaper(_ input: String, stayInSearch: Bool = false) async throws {
        let reference = try ArxivReference(input)
        guard canBeginImport, let snapshot = completeLibrary, let commands = libraryCommandCoordinator else { throw ReaderError.storageUnavailable }
        let scope = sessionID
        _ = try await commands.enqueue(.beginImport(sourceID: reference.sourceID, requestedRevision: reference.revision,
                                                    observedCursor: snapshot.committedCursor), display: "arXiv \(reference.identifier)")
        guard sessionID == scope else { throw CancellationError() }
        if !stayInSearch { searchExternal = false; libraryQuery = "" }
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
        // Live publication still includes native metadata mapping. Offline
        // projection does that within its separate measured cache-read phase.
        OfflineResourceProbe.shared.begin(.publication)
        defer { OfflineResourceProbe.shared.finish(.publication, count: entries.count) }
        #endif
        applyLibraryProjection(entries.compactMap(LibraryPresentationRow.project))
    }

    private func presentLibraryProjection(_ rows: [LibraryPresentationRow], validatedEntryCount: Int) {
        #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && targetEnvironment(simulator)
        // Format 4: final MainActor application only. Author joining and cache
        // validation are included in restoreProjectionElapsedMS and restore.
        OfflineResourceProbe.shared.begin(.publication)
        defer { OfflineResourceProbe.shared.finish(.publication, count: validatedEntryCount) }
        #endif
        applyLibraryProjection(rows)
    }

    private func applyLibraryProjection(_ rows: [LibraryPresentationRow]) {
        let previous = Dictionary(papers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = rows.compactMap { if case .item(let item) = $0 { return item }; return nil }
        let next = items.map { item in
            let paper = item.paper
            // Only the selected binding may carry decoded bytes through a
            // metadata refresh. Other installed copies remain on disk.
            let previousRow = previous[paper.id]
            let cached = selectedPaper?.id == paper.id && selectedPaper?.artifactID == paper.artifactID &&
                selectedPaper?.readerBundle?.manifestSHA256 == previousRow?.readerBundle?.manifestSHA256
                ? previousRow : nil
            let installed = readerBundles?.installation(documentID: paper.id, artifactID: paper.artifactID)
            let readable: Bool
            if let installed {
                readable = readerBundles?.permits(installed) == true && installed.binding.manifestSHA256 == cached?.readerBundle?.manifestSHA256
            } else { readable = item.canReadStructured }
            let file = readable && cached?.artifactID == paper.artifactID ? cached?.fileURL : nil
            return Paper(id: paper.id, title: paper.title, authors: paper.authors, year: paper.year,
                         abstract: paper.abstract, keywords: paper.keywords, fileURL: file,
                         artifactID: paper.artifactID, sourceID: paper.sourceID, sourceRevision: paper.sourceRevision,
                         readerBundle: file == nil ? nil : cached?.readerBundle)
        }
        let samples = papers.filter { candidate in candidate.isSample && !next.contains(where: { $0.id == candidate.id }) }
        // Samples have no server membership. Preserve the local sample
        // without letting it replace a real document-backed item.
        papers = next + samples
        presentedImportIDs = Set(rows.compactMap { if case .imported(let id, _) = $0 { return id }; return nil })
        libraryImports = rows.compactMap { if case .imported(_, let item) = $0 { return item }; return nil }
        libraryCreationSequences = Dictionary(uniqueKeysWithValues: items.map { ($0.paper.id, $0.createdSequence) })
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

    /// One selected downloaded bundle may remain loaded when returning to
    /// Library or Chat. Changing selection drops every other model/row handle;
    /// active WebKit views may finish using their own immutable copies.
    private func releaseUnselectedReaderBundles() {
        let selected = selectedPaper
        func shouldRelease(_ paper: Paper) -> Bool {
            guard !paper.isSample, let bundle = paper.readerBundle else { return false }
            return paper.id != selected?.id || paper.artifactID != selected?.artifactID ||
                bundle.manifestSHA256 != selected?.readerBundle?.manifestSHA256
        }
        guard papers.contains(where: shouldRelease) else { return }
        papers = papers.map { shouldRelease($0) ? $0.displaying(nil) : $0 }
    }

    /// Availability belongs to the permitted encrypted installation, not to
    /// whether this row currently owns decoded bytes in memory.
    func offlineStatus(for paper: Paper) -> PaperOfflineStatus {
        if paper.isSample { return paper.readerBundle == nil ? .none : .available }
        guard accountID != nil, let coordinator = readerBundles,
              let installation = coordinator.installation(documentID: paper.id, artifactID: paper.artifactID) else { return .none }
        return coordinator.permits(installation) ? .available : .unavailable
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
              let coordinator = readerBundles else { return }
        guard let installation = coordinator.installation(documentID: paper.id, artifactID: paper.artifactID) else {
            downloadReaderIfNeeded(paper, coordinator: coordinator)
            return
        }
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

    /// A converted paper without a local copy downloads automatically when
    /// opened. Every member is verified against the server-authorized manifest
    /// digest by the encrypted installer; then the normal open path runs.
    private func downloadReaderIfNeeded(_ paper: Paper, coordinator: ReaderBundleCoordinator) {
        if readerDownloadAttempt?.documentID == paper.id { openingPaperID = paper.id; return }
        guard let backend, let accountID, let artifactID = paper.artifactID,
              let item = completeLibrary?.items.first(where: { $0.documentID == paper.id && $0.visible }), item.canReadStructured,
              item.artifactID == artifactID, !workOwnership.isActivating, !libraryPublicationDeferred else { return }
        let attempt = UUID(), scope = sessionID
        readerDownloadAttempt = (attempt, paper.id); openingPaperID = paper.id; readerOpenIssue = nil
        Task {
            defer {
                if self.readerDownloadAttempt?.id == attempt {
                    self.readerDownloadAttempt = nil
                    if self.readerOpenAttempt == nil, self.openingPaperID == paper.id { self.openingPaperID = nil }
                }
            }
            do {
                let descriptor = try await backend.readerArtifact(itemID: item.id, accountID: accountID)
                guard descriptor.documentID == paper.id, descriptor.artifactID == artifactID else { throw ReaderError.corruptData }
                var members: [String: Data] = [:]
                for member in descriptor.members {
                    try Task.checkCancellation()
                    members[member.path] = try await backend.readerMember(member)
                }
                guard self.sessionID == scope, self.readerBundles === coordinator, self.readerDownloadAttempt?.id == attempt else { return }
                let binding = try ReaderArtifactBinding(scope: coordinator.scope, documentID: paper.id, artifactID: artifactID,
                                                        manifestSHA256: descriptor.manifestSHA256)
                _ = try await coordinator.install(binding: binding, manifestData: descriptor.manifestData, members: members).value
                guard self.sessionID == scope, self.readerDownloadAttempt?.id == attempt else { return }
                self.readerDownloadAttempt = nil
                if self.openingPaperID == paper.id { self.openingPaperID = nil }
                if self.selectedPaper?.id == paper.id { self.openLocalPaperIfNeeded() }
            } catch {
                guard self.sessionID == scope, self.readerDownloadAttempt?.id == attempt, !(error is CancellationError) else { return }
                self.readerOpenIssue = "This paper couldn’t be downloaded. Check your connection and try again."
            }
        }
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
        // The quote travels with this exact prompt and composer only.
        pendingSelection = chatComposerID.map { (composerID: $0, prompt: chatInput, quote: quote) }
        if !isSignedIn { openSignIn() }
        // The question is saved first; first-use cloud consent then binds the
        // answer request to that captured, saved turn.
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
        guard let store, let device else { openSignIn(); return }
        guard !isGenerating, !isAnswering, accountID == device.accountID else { return }
        let scope = sessionID
        let storeScope = workOwnership.storeScope, persistence = localPersistence
        let documentID = generalChat ? nil : (chatPaperID ?? selectedPaper?.id)
        var parents = activeBranchID.map { [$0] } ?? []
        if parents.isEmpty, let activeConversation, let root = privateState.revisions(for: activeConversation).first { parents = [root.id] }
        recordCurrentDraftBranch()
        guard let submission = chatWorkspace.beginSubmission(in: chatContext) else { return }
        let selection = pendingSelection.flatMap {
            $0.composerID == submission.composerID && $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines) == submission.text ? $0.quote : nil
        }
        if pendingSelection?.composerID == submission.composerID { pendingSelection = nil }
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
            if let question = committed.envelopes.last?.id {
                requestAnswer(for: ChatAnswerTurn(sessionID: scope, accountID: device.accountID, deviceID: device.deviceID,
                    composerID: submission.composerID, conversationID: submission.conversationID, documentID: documentID,
                    userMessageID: question, selection: selection), state: snapshot.state)
            }
        } catch {
            if sessionID == scope {
                chatWorkspace.fail(submission)
                if workOwnership.owns(storeScope) { show(error) }
            }
        }
    }

    // MARK: - Cloud answers

    var chatTransport: (any ChatTransport)? { chatTransportOverride ?? backend }
    /// An answer is streaming for the visible composer's question.
    var isAnswering: Bool { chatComposerID.map { chatGenerations[$0] != nil } ?? false }
    var isStoppingAnswer: Bool { chatComposerID.flatMap { chatGenerations[$0]?.stopping } ?? false }
    var chatAnswerIssue: ChatAnswerIssue? {
        guard let composer = chatComposerID, chatGenerations[composer] == nil, let issue = chatAnswerIssues[composer],
              issue.turn.sessionID == sessionID, issue.turn.conversationID == activeConversation,
              activeBranchID == privateState.resolvedEventID(issue.turn.userMessageID) else { return nil }
        return issue
    }
    /// Only the composer that owns the answer, while its question is the shown
    /// head, renders the transient row. Late tokens never reach other chats.
    private var visibleGeneration: ChatGeneration? {
        guard let composer = chatComposerID, let generation = chatGenerations[composer], generation.turn.sessionID == sessionID,
              generation.turn.conversationID == activeConversation,
              activeBranchID == privateState.resolvedEventID(generation.turn.userMessageID) else { return nil }
        return generation
    }
    var chatStreamingMessageID: UUID? { visibleGeneration?.assistantID }
    /// Saved branch messages plus the streaming answer, which already carries
    /// the identity its sealed encrypted message will use.
    var chatTranscriptMessages: [AppliedEvent] {
        let messages = chatMessages
        guard let generation = visibleGeneration, !messages.contains(where: { $0.id == generation.assistantID }) else { return messages }
        return messages + [AppliedEvent(id: generation.assistantID, deviceID: generation.turn.deviceID,
                                        payload: generation.event(text: chatStreamingText[generation.id] ?? "", status: .complete))]
    }
    private var chatConsent: ChatConsentLedger {
        ChatConsentLedger(environment: configuration?.environment ?? "local", store: chatConsentStore)
    }

    /// Requests an answer for a saved question. Without a transport (offline
    /// fixtures) nothing is sent. First use asks for cloud-processing consent.
    private func requestAnswer(for turn: ChatAnswerTurn, state: PrivateState? = nil) {
        guard let transport = chatTransport, turn.sessionID == sessionID, turn.accountID == accountID,
              chatGenerations[turn.composerID] == nil else { return }
        guard chatConsent.hasAccepted(turn.accountID) else {
            chatConsentPrompt = ChatConsentPrompt(turn: turn)
            return
        }
        startGeneration(turn, transport: transport, state: state ?? privateState)
    }

    func acceptChatConsent(_ prompt: ChatConsentPrompt) {
        guard chatConsentPrompt?.id == prompt.id else { return }
        chatConsentPrompt = nil
        guard prompt.turn.sessionID == sessionID, prompt.turn.accountID == accountID else { return }
        do { try chatConsent.accept(prompt.turn.accountID) }
        catch {
            chatAnswerIssues[prompt.turn.composerID] = ChatAnswerIssue(turn: prompt.turn, code: "consent_unsaved")
            return
        }
        requestAnswer(for: prompt.turn)
    }

    func declineChatConsent(_ prompt: ChatConsentPrompt) {
        guard chatConsentPrompt?.id == prompt.id else { return }
        chatConsentPrompt = nil
        guard prompt.turn.sessionID == sessionID else { return }
        chatAnswerIssues[prompt.turn.composerID] = ChatAnswerIssue(turn: prompt.turn, code: "consent_declined")
    }

    func retryAnswer() {
        guard let issue = chatAnswerIssue, issue.retryable else { return }
        chatAnswerIssues[issue.turn.composerID] = nil
        requestAnswer(for: issue.turn)
    }

    /// Stop keeps any partial text as an explicitly interrupted encrypted turn.
    func stopAnswer() {
        guard let composer = chatComposerID, let generation = chatGenerations[composer], !generation.stopping else { return }
        chatGenerations[composer]?.stopping = true
        generation.task?.cancel()
    }

    private func startGeneration(_ turn: ChatAnswerTurn, transport: any ChatTransport, state: PrivateState) {
        chatAnswerIssues[turn.composerID] = nil
        guard !state.isDeleted(turn.conversationID),
              let branch = state.conversationBranch(turn.conversationID, through: turn.userMessageID), branch.complete,
              branch.messages.last?.payload.role == .user else {
            chatAnswerIssues[turn.composerID] = ChatAnswerIssue(turn: turn, code: "invalid_request")
            return
        }
        let transcript = branch.messages.compactMap { message -> ChatTurnInput? in
            guard let role = message.payload.role, let text = message.payload.text else { return nil }
            return ChatTurnInput(role: role, text: text)
        }
        let request: ChatGenerationRequest
        do { request = try ChatGenerationRequest.make(operationID: UUID(), documentID: turn.documentID, transcript: transcript, selection: turn.selection) }
        catch {
            chatAnswerIssues[turn.composerID] = ChatAnswerIssue(turn: turn, code: "invalid_request")
            return
        }
        var generation = ChatGeneration(turn: turn)
        // A later explicit branch choice wins over moving to this answer.
        let choice = branchSelections.capture(in: turn.conversationID)
        let pending = generation
        generation.task = Task { [weak self] in
            await self?.runGeneration(pending, request: request, transport: transport, choice: choice)
        }
        chatGenerations[turn.composerID] = generation
    }

    private func ownsGeneration(_ generation: ChatGeneration) -> Bool {
        generation.turn.sessionID == sessionID && chatGenerations[generation.turn.composerID]?.id == generation.id
    }

    private func runGeneration(_ generation: ChatGeneration, request: ChatGenerationRequest, transport: any ChatTransport,
                               choice: ConversationBranchSelections.Choice) async {
        var text = "", outcome: ChatGenerationOutcome?
        // The consumer holds the only stream reference, so leaving it (a final
        // event, lost ownership or an error) releases the stream and cancels
        // the HTTP request before any local sealing work begins.
        func consume(_ stream: AsyncThrowingStream<ChatStreamEvent, Error>) async throws -> Bool {
            for try await event in stream {
                guard ownsGeneration(generation) else { return false }
                switch event {
                case .delta(let piece):
                    text += piece
                    bufferAnswer(generation, text: text)
                case .done(let stopReason, _): outcome = .completed(stopReason: stopReason)
                case .failure(let code): outcome = .failed(code: code)
                }
                if outcome != nil { break }
            }
            return true
        }
        do {
            guard try await consume(try await transport.chatStream(request, accountID: generation.turn.accountID)) else { return }
        } catch ChatTransportError.rejected(let code) {
            outcome = .failed(code: code)
        } catch BackendError.signInRequired {
            outcome = .failed(code: "authentication_required")
        } catch {
            if !Task.isCancelled { outcome = .failed(code: "transport") }
        }
        guard ownsGeneration(generation) else { return }
        // A stream that ends without done/error is interrupted, never complete.
        let resolved = outcome ?? (Task.isCancelled || chatGenerations[generation.turn.composerID]?.stopping == true
            ? .cancelled : .failed(code: "transport"))
        await finishGeneration(generation, text: text, outcome: resolved, choice: choice)
    }

    private func bufferAnswer(_ generation: ChatGeneration, text: String) {
        chatStreamBuffer[generation.id] = text
        guard chatStreamFlushes.insert(generation.id).inserted else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            self.chatStreamFlushes.remove(generation.id)
            guard self.ownsGeneration(generation), let latest = self.chatStreamBuffer[generation.id] else { return }
            self.chatStreamingText[generation.id] = latest
        }
    }

    private func finishGeneration(_ generation: ChatGeneration, text: String, outcome: ChatGenerationOutcome,
                                  choice: ConversationBranchSelections.Choice) async {
        let resolution = outcome.resolution(text: text)
        var issue = resolution.issue
        if let status = resolution.status {
            // Show exactly the sealed text before the row changes ownership.
            chatStreamingText[generation.id] = text
            do { try await sealAnswer(generation, text: text, status: status, choice: choice) }
            catch { if issue == nil { issue = "storage" } }
        }
        guard ownsGeneration(generation) else { return }
        chatGenerations[generation.turn.composerID] = nil
        chatStreamingText[generation.id] = nil; chatStreamBuffer[generation.id] = nil
        if let issue { chatAnswerIssues[generation.turn.composerID] = ChatAnswerIssue(turn: generation.turn, code: issue) }
        let scope = sessionID
        Task { if self.sessionID == scope { await self.refreshCreditBalance() } }
    }

    private func sealAnswer(_ generation: ChatGeneration, text: String, status: PrivateEvent.TurnStatus,
                            choice: ConversationBranchSelections.Choice) async throws {
        guard !privateState.isDeleted(generation.turn.conversationID) else { return }
        let persistence = localPersistence, scope = sessionID
        await persistence.waitForActivation()
        guard ownsGeneration(generation), persistence === localPersistence, let store else { throw CancellationError() }
        let storeScope = workOwnership.storeScope
        let id = generation.assistantID, deviceID = generation.turn.deviceID
        let event = generation.event(text: text.boundedForPrivateEvent(), status: status)
        let write = try persistence.acceptWrite { local in try await local.appendBatch([(id: id, event: event)], deviceID: deviceID) }
        let envelopes = try await write.value
        let snapshot = await store.snapshot()
        guard sessionID == scope else { return }
        branchSelections.complete(choice, head: envelopes.last?.id)
        if workOwnership.owns(storeScope) { publish(snapshot) }
        branchSelections.reconcile(with: privateState, observing: generation.turn.conversationID)
        Task { if self.sessionID == scope { await self.synchronize() } }
    }

    /// Account changes fence every answer. A non-empty partial is kept as an
    /// interrupted encrypted turn in the old account's store before it retires.
    private func retireChatGenerations() {
        let retiring = Array(chatGenerations.values), buffers = chatStreamBuffer
        chatGenerations = [:]; chatStreamingText = [:]; chatStreamBuffer = [:]; chatStreamFlushes = []
        chatAnswerIssues = [:]; chatConsentPrompt = nil; pendingSelection = nil
        creditBalance = nil; creditBalanceIssue = nil
        for generation in retiring {
            generation.task?.cancel()
            guard let text = buffers[generation.id], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !privateState.isDeleted(generation.turn.conversationID) else { continue }
            let id = generation.assistantID, deviceID = generation.turn.deviceID
            let event = generation.event(text: text.boundedForPrivateEvent(), status: .interrupted)
            _ = try? localPersistence.acceptWrite { local in try await local.appendBatch([(id: id, event: event)], deviceID: deviceID) }
        }
    }

    func refreshCreditBalance() async {
        guard let transport = chatTransport, let accountID, device != nil else { return }
        let scope = sessionID
        do {
            let balance = try await transport.creditBalance(accountID: accountID)
            guard sessionID == scope, self.accountID == accountID else { return }
            creditBalance = balance; creditBalanceIssue = nil
        } catch {
            guard sessionID == scope, self.accountID == accountID else { return }
            creditBalanceIssue = "Couldn’t load your credit balance. Try again later."
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
    func configureOfflineReaderFixture(reset: Bool, variant: OfflineReaderFixture.Variant) async throws {
        let fixtureDevice = try OfflineReaderFixture.device()
        guard let keys = fixtureDevice.bundle else { throw ReaderError.missingKey }
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(variant.directoryName, isDirectory: true)
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
        let cacheScope = try LibraryCommandScope(accountID: fixtureDevice.accountID, deploymentID: variant.deployment)
        let coordinator = ReaderBundleCoordinator(scope: cacheScope, persistence: localPersistence)
        readerBundles = coordinator
        if reset {
            _ = try await coordinator.observe(OfflineReaderFixture.observation(variant: variant)).value
            let reader = try OfflineReaderFixture.reader(variant: variant)
            let binding = try ReaderArtifactBinding(scope: cacheScope, documentID: OfflineReaderFixture.document,
                artifactID: OfflineReaderFixture.artifact, manifestSHA256: variant.manifestSHA256)
            let members = Dictionary(uniqueKeysWithValues: reader.manifest.members.map { ($0.path, reader.data(for: $0.path)!) })
            _ = try await coordinator.install(binding: binding, manifestData: reader.manifestData, members: members).value
        }
        await prepareOfflineLibrary(accountID: fixtureDevice.accountID, scope: sessionID, activation: activation,
                                    deploymentID: variant.deployment)
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
