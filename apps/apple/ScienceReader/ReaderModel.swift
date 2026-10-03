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
}

struct ReaderDocumentScope: Hashable {
    let sessionID: UUID
    let paperID: UUID
    let artifactID: UUID?
    let fileURL: URL?
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
    var selectedPaper: Paper? {
        didSet {
            if oldValue?.id != selectedPaper?.id || oldValue?.artifactID != selectedPaper?.artifactID || oldValue?.fileURL != selectedPaper?.fileURL {
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
    var chatInput: String { get { chatWorkspace.draft(in: chatContext) } set { chatWorkspace.setDraft(newValue, in: chatContext) } }
    var activeConversation: UUID? {
        get { chatWorkspace.conversation(in: chatContext) }
        set {
            chatWorkspace.select(newValue, in: chatContext)
            branchSelections.reconcile(with: privateState, observing: newValue)
        }
    }
    var chatComposerID: UUID? { chatWorkspace.composerID(in: chatContext) }
    var unsentDrafts: [ChatWorkspace.UnsentDraft] { chatWorkspace.unsentDrafts }
    var chatHasSaved: Bool { chatWorkspace.hasSaved(in: chatContext) }
    var canUsePaperChat: Bool { chatPaperID != nil || selectedPaper != nil }
    var chatPaper: Paper? { (chatPaperID ?? selectedPaper?.id).flatMap { id in papers.first { $0.id == id } ?? (selectedPaper?.id == id ? selectedPaper : nil) } }
    var chatTitle: String { chatWasDeleted ? "Deleted conversation" : (activeConversation.flatMap { privateState.revisions(for: $0).first?.payload.text } ?? "New chat") }
    var chatWasDeleted: Bool { activeConversation.map { privateState.isDeleted($0) } ?? false }
    var privateState = PrivateState() {
        didSet { branchSelections.reconcile(with: privateState, observing: activeConversation) }
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
    var headings: [String] = []
    @ObservationIgnored var paperLocations: [String: PaperReadingLocation] = [:]
    var paperJump: PaperJumpRequest?
    var selectedQuote = ""
    var isGenerating: Bool { chatWorkspace.isSaving(in: chatContext) }
    private var backend: BackendClient?
    private var keys: DeviceKeys?
    private var device: LocalDevice?
    private var localPersistence = ReaderLocalPersistence()
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
        selectedPaper.map { ReaderDocumentScope(sessionID: sessionID, paperID: $0.id, artifactID: $0.artifactID, fileURL: $0.fileURL) }
    }
    private let configuration: BackendConfiguration?

    init(configuration: BackendConfiguration? = .bundled(), client: BackendClient? = nil) {
        self.configuration = configuration; self.backend = client
    }

    var configured: Bool { configuration != nil }
    var filteredPapers: [Paper] {
        let terms = libraryQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        let matching = papers.filter { paper in
            let fields = [paper.title, paper.authors, paper.abstract] + paper.keywords
            return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
        }
        return librarySort == "Title" ? matching.sorted { $0.title.localizedCompare($1.title) == .orderedAscending } : matching
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
        #if DEBUG && targetEnvironment(simulator)
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
        let guestDraft = accountID == nil && self.email == nil ? chatInput : nil
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
            try await loadLibrary(accountID: user.id, scope: scope)
            return
        }
        let preparation = try await manager.prepare()
        guard sessionID == scope, accountID == user.id else { throw BackendError.signInRequired }
        switch preparation {
        case .ready(let device): try await activate(device, scope: scope)
        case .saveRecoveryCode(let code): recoveryCode = code; needsRecovery = false; showRecovery = true
        case .recoveryRequired: recoveryCode = nil; needsRecovery = true; showRecovery = true
        }
        try await loadLibrary(accountID: user.id, scope: scope)
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
    private func activate(_ device: LocalDevice, scope: UUID) async throws -> ReaderWorkOwnership.StoreScope {
        guard sessionID == scope, accountID == device.accountID else { throw BackendError.signInRequired }
        guard let bundle = device.bundle, let backend, let configuration, let keys else { throw ReaderError.missingKey }
        try bundle.validate(accountID: device.accountID)
        let activation = workOwnership.beginActivation()
        var activated = false
        defer {
            workOwnership.finishActivation(activation)
            if !activated, workOwnership.owns(activation) {
                syncStatus = "Saved on this device · Sync paused"
                syncIssue = "Private library setup did not finish. Try restoring this device again."
            }
        }
        let persistence = localPersistence
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
        publish(snapshot)
        recoveryCode = nil; needsRecovery = false; showRecovery = false
        activated = true
        workOwnership.finishActivation(activation)
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

    private func clearAccountView() {
        workOwnership = ReaderWorkOwnership(); accountID = nil; isBusy = false
        publishedGeneration = -1; publishedPendingCount = 0
        support?.cancel(); support = nil
        retirementQueue.retire(sync: sync, persistence: localPersistence)
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

    private func loadLibrary(accountID: UUID, scope: UUID) async throws {
        guard let backend else { return }
        struct Row: Decodable, Sendable { let document_id: UUID; let title: String?; let authors: [String]?; let abstract: String?; let publication_year: Int?; let artifact_id: UUID? }
        let rows: [Row] = try await backend.rpc("v1_library", params: EmptyResponse(), accountID: accountID)
        guard sessionID == scope, self.accountID == accountID else { throw BackendError.signInRequired }
        papers = rows.map { Paper(id: $0.document_id, title: $0.title ?? "Untitled paper", authors: ($0.authors ?? []).joined(separator: ", "), year: $0.publication_year,
                                  abstract: $0.abstract ?? "", keywords: [], fileURL: nil, artifactID: $0.artifact_id) }
    }

    func select(_ paper: Paper) { selectedPaper = paper; chatPaperID = paper.id; tab = .paper; if wideMode != .browse { wideMode = .reader }; generalChat = false }

    func askAboutSelectedPaper() {
        guard let selectedPaper else { return }
        chatPaperID = selectedPaper.id; generalChat = false; tab = .chat; wideMode = .reader
    }

    func openConversation(_ id: UUID) {
        guard let event = privateState.revisions(for: id).first, event.payload.kind == .conversation else { return }
        if let documentID = event.payload.documentID {
            chatPaperID = documentID; selectedPaper = papers.first { $0.id == documentID }; generalChat = false; wideMode = .reader
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
        } else { generalChat = true; wideMode = .chat }
        tab = .chat
    }

    func discardUnsentDraft(_ id: UUID) { chatWorkspace.discardDraft(id) }
    func openSample() {
        let paper = Paper(id: UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!, title: "Reading machine learning papers", authors: "Science Reader · offline sample", year: 2026,
            abstract: "A local reading fixture with equations, a wide table, figure, and references. It demonstrates the reader without uploading a paper or using credits.",
            keywords: ["attention", "optimization", "evaluation"], fileURL: Bundle.main.url(forResource: "reader-sample", withExtension: "html"),
            artifactID: UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000002"), isSample: true)
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
        else { Task { await sendMessage() } }
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
        guard let submission = chatWorkspace.beginSubmission(in: chatContext) else { return }
        // A remote user message is not a local scrolling action. Capture the
        // accepted submit gesture before saving, scoped to its own composer.
        chatFollowRequest = ChatFollowRequest(composerID: submission.composerID)
        let branchChoice = branchSelections.capture(in: submission.conversationID)
        do {
            var events: [(id: UUID, event: PrivateEvent)] = []
            if let root = submission.rootID {
                events.append((root, PrivateEvent(kind: .conversation, entityID: submission.conversationID, documentID: documentID, text: String(submission.text.prefix(100)))))
                parents = [root]
            }
            events.append((submission.id, PrivateEvent(kind: .message, entityID: submission.id, parents: parents,
                conversationID: submission.conversationID, documentID: documentID, text: submission.text, role: .user, status: .complete)))
            let batch = events
            let committed = try await persistence.performWrite { local in
                try await local.appendBatch(batch, deviceID: device.deviceID)
            }
            let snapshot = await store.snapshot()
            guard sessionID == scope else { return }
            branchSelections.complete(branchChoice, head: committed.last?.id)
            chatWorkspace.complete(submission)
            if workOwnership.owns(storeScope), publish(snapshot) {
                syncStatus = syncIssue == nil ? "Saved on this device" : "Saved on this device · Sync paused"
            }
            branchSelections.reconcile(with: privateState, observing: submission.conversationID)
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
    private var writes: [UUID: Task<[EventEnvelope], Error>] = [:]

    func performWrite(_ operation: @escaping @Sendable (EncryptedStore) async throws -> [EventEnvelope]) async throws -> [EventEnvelope] {
        guard !isRetired, !isActivating, let store else { throw ReaderError.storageUnavailable }
        let id = UUID(), task = Task { try await operation(store) }
        writes[id] = task
        defer { writes.removeValue(forKey: id) }
        return try await task.value
    }

    func activate(url: URL, accountID: UUID, localKey: Data, keys: KeyBundle) async throws -> EncryptedStore {
        guard !isRetired, !isActivating else { throw ReaderError.storageUnavailable }
        try keys.validate(accountID: accountID)
        guard localKey.count == 32 else { throw ReaderError.invalidKey }
        isActivating = true
        defer { isActivating = false }
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

    func waitForAcceptedWrites() async {
        for task in Array(writes.values) { _ = await task.result }
    }
}

/// UI/account clearing is immediate, while old accepted local writes and sync
/// transactions finish before any later session opens another SQLite actor.
@MainActor
final class ReaderRetirementQueue {
    private var pending: (id: UUID, task: Task<Void, Never>)?

    func retire(sync: CloudSync?, persistence: ReaderLocalPersistence) {
        persistence.retire()
        sync?.cancel()
        enqueue(sync: sync, persistence: persistence)
    }

    func stop(_ sync: CloudSync) {
        sync.cancel()
        enqueue(sync: sync, persistence: nil)
    }

    private func enqueue(sync: CloudSync?, persistence: ReaderLocalPersistence?) {
        let previous = pending?.task, id = UUID()
        let task = Task { [weak self] in
            if let previous { await previous.value }
            if let sync { await sync.stop() }
            if let persistence { await persistence.waitForAcceptedWrites() }
            if self?.pending?.id == id { self?.pending = nil }
        }
        pending = (id, task)
    }

    func wait() async {
        while let task = pending?.task { await task.value }
    }
}
