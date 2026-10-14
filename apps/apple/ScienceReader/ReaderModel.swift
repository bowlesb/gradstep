import Foundation
import Observation
import ScienceReaderCore
import StoreKit
import SwiftUI

enum ReaderTab: String, CaseIterable, Identifiable {
    case feed = "Feed", library = "Library", paper = "Paper", chat = "Chat", settings = "Settings"
    var id: Self { self }
    var symbol: String { switch self { case .feed: "dot.radiowaves.up.forward"; case .library: "books.vertical"; case .paper: "doc.text"; case .chat: "bubble.left.and.bubble.right"; case .settings: "gearshape" } }
}
enum WideMode: String, CaseIterable { case feed = "Feed", library = "Library", reader = "Reader", browse = "Browse", chat = "General Chat" }
/// The reader's selection actions. Raw values are stable identifiers (UI tests, saved state);
/// `title` is the short label in chat titles ("Explain · …"); `menuTitle` is what the edit menu says.
enum SelectionAction: String, CaseIterable {
    case define = "Define", relevance = "Relevance", similar = "Similar", ingest = "Ingest"
    var title: String {
        switch self { case .define: "Explain"; case .relevance: "Why it matters"; case .similar: "Related"; case .ingest: "Add paper" }
    }
    /// In the paper's edit menu after Copy (owner feedback, build 16 #5: "make the options clear, 'Explain in Chat'").
    var menuTitle: String {
        switch self { case .define: "Explain in Chat"; case .relevance: "Why it matters"; case .similar: "Related papers"; case .ingest: "Add paper" }
    }
    var symbol: String {
        switch self { case .define: "text.magnifyingglass"; case .relevance: "lightbulb"; case .similar: "point.3.connected.trianglepath.dotted"; case .ingest: "plus.square.on.square" }
    }
    /// A tapped equation offers these (adding the paper a passage cites makes no sense for a formula).
    static let equationActions: [SelectionAction] = [.define, .relevance, .similar]
}
enum PaperOfflineStatus: Equatable { case none, available, unavailable }

struct Paper: Identifiable, Sendable {
    let id: UUID
    let title: String
    let authors: String
    let year: Int?
    let abstract: String
    let keywords: [String]
    var fileURL: URL?
    let artifactID: UUID?
    var isSample = false
    var sourceID: String?
    var sourceRevision: Int?
    var readerBundle: VerifiedReaderBundle? = nil
    var sourceMembership: SourcePaperReference? = nil
    var isLocalPDF = false
    /// Individual author names when known (`authors` is their joined display form).
    var authorNames: [String] = []
    /// When this paper joined the library (the server's membership time).
    var addedAt: Date? = nil
    var pageCount: Int? = nil
    /// False for a library item whose structured reader isn't available (not converted).
    var canReadStructured = true
    /// Archived (migration 020): in the library, hidden from the default list.
    var archived = false
    /// Where it was published ("NeurIPS"), from the library metadata (`publicationLine`).
    var venue: String? = nil
    /// The paper's topic tags as the reader sees them (docs/architecture/TAGS.md): the catalog's tags minus
    /// those the reader removed, then the reader's own, including an edit still syncing. Library columns and
    /// filters, the reader's header chips and search use these.
    var tags: [String] = []
    /// The server's lists behind `tags` (migration 030): the catalog's, the reader's own and the removed ones.
    var catalogTags: [String] = []
    var ownTags: [String] = []
    var hiddenTags: [String] = []
    /// Where the paper came from (a web paper's page; the Library's Source column shows its host).
    var sourceURL: String? = nil
    var sourceReference: String? { sourceID.map { $0 + (sourceRevision.map { "v\($0)" } ?? "") } }

    func displaying(_ bundle: VerifiedReaderBundle?) -> Paper {
        var paper = self
        paper.fileURL = bundle?.entryURL; paper.readerBundle = bundle
        return paper
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
        case .pending(let item): item.metadata?.title ?? LibrarySource.placeholderTitle(sourceID: item.sourceID)
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

struct TagEditorRequest: Identifiable, Equatable {
    let id = UUID()
    let paperID: UUID
}

/// A source-only PDF decrypted only while the user is viewing it. The bytes
/// are never written back to disk by the presentation layer; the encrypted
/// device store remains the source of truth.
struct LocalPaperPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let data: Data
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
    private(set) var libraryImports: [LibraryImportRecord] = [] {
        didSet {
            guard libraryImports != oldValue else { return }
            let now = importClock()
            importSteps.observe(libraryImports, now: now)
            importProgressTracker.observe(libraryImports, now: now)
            librarySearchSourceChanged(); updateImportPolling()
        }
    }
    /// When each import in progress entered its current step, as this device saw it (rows show how long).
    private(set) var importSteps = ImportStepClock()
    /// When each import's progress detail arrived here and how far its bar has got (rows count down from it).
    private(set) var importProgressTracker = ImportProgressTracker()
    /// The step clock's time source (tests inject one).
    @ObservationIgnored var importClock: () -> Date = { Date() }
    private var importPollTask: Task<Void, Never>?
    private(set) var libraryRefreshing = false
    private(set) var libraryIssue: String?
    private(set) var libraryHasSnapshot = false
    private var libraryService: LibraryService?
    private var libraryContextAuthenticated = false
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
    /// Exact source revisions retained in this device's encrypted paper store.
    /// The server library still owns metadata and account membership; these
    /// records are intentionally local-only.
    private(set) var localPaperRecords: [LocalPaperRecord] = []
    private(set) var localReaderRecords: [LocalReaderRecord] = []
    @ObservationIgnored private var localReaderTask: Task<Void, Never>?
    private var localReaderOpeningID: UUID?
    private(set) var localPaperDownloads: Set<UUID> = []
    private var libraryCommandCoordinator: LibraryCommandCoordinator?
    private var libraryCommandGeneration: Int64 = -1 { didSet { if libraryCommandGeneration != oldValue { queueLibrarySearch() } } }
    private(set) var libraryCommands: [LocalLibraryCommand] = [] { didSet { if libraryCommands != oldValue { applyPendingTagEdits(); librarySearchSourceChanged() } } }
    #if DEBUG && FIXTURE_HOST
    /// Fixture runs only: Retry and Remove on imports act locally (there is no account or server).
    @ObservationIgnored var fixtureImportChanges = false
    var fixtureRetriedImports: Set<UUID> = []
    #endif
    /// The Library's quick filter (All, Unread, Reading, Failed, Archived) and tag filter. Not persisted, like the
    /// sort: each launch starts with All.
    var libraryFilter = LibraryFilter.all { didSet { if libraryFilter != oldValue { librarySearchSourceChanged() } } }
    var libraryTagFilter: String? { didSet { if libraryTagFilter != oldValue { librarySearchSourceChanged() } } }
    var libraryFiltered: Bool { libraryFilter != .all || libraryTagFilter != nil }
    /// The table's columns, per width class (Library options › Columns).
    var libraryColumns = LibraryColumnSettings.load(from: .standard) { didSet { libraryColumns.save(to: .standard) } }
    /// Papers marked archived, including changes still syncing (for row labels and actions).
    func isArchived(_ paper: Paper) -> Bool {
        for command in libraryCommands.reversed() where command.isUnfinished {
            if case .setArchived(let document, let archived, _) = command.mutation, document == paper.id { return archived }
            if case .setSourceDetails(let id, let archived, _, _) = command.mutation, id == paper.id { return archived }
        }
        return paper.archived
    }
    private(set) var libraryCommandIssue: String?
    var showLibraryChanges = false
    /// The Edit tags sheet (paper options, the library row's long-press menu, the reader's tag chips).
    var tagEditor: TagEditorRequest?
    var librarySignInRequired: Bool { accountID == nil }
    /// Writes follow the complete observation's read context: v2 for a legacy library, v5 (bound to
    /// its dataset epoch, migration 042) once the upload-capable library is adopted.
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
    /// arXiv results newest first by default (owner feedback, build 16 #2); Relevance is the server's order. Kept.
    var discoveryOrder = DiscoveryOrder(rawValue: UserDefaults.standard.string(forKey: "discover.order") ?? "") ?? .newest {
        didSet { UserDefaults.standard.set(discoveryOrder.rawValue, forKey: "discover.order") }
    }
    var orderedDiscoveryResults: [DiscoveryResult] { discoveryOrder.ordered(discoveryResults) }
    private var discoveryGeneration = 0
    private var discoveryTask: Task<Void, Never>?
    /// Not persisted (as before): each launch starts with Recent.
    var librarySort = LibrarySearchSort.recent {
        didSet {
            guard librarySort != oldValue else { return }
            // Activity-based orders need a fresh activity snapshot in the candidates.
            if librarySort.field.usesActivity { librarySearchSourceChanged() } else { queueLibrarySearch() }
        }
    }
    var libraryLayout = LibraryLayout(saved: UserDefaults.standard.string(forKey: "library.layout")) {
        didSet { UserDefaults.standard.set(libraryLayout.rawValue, forKey: "library.layout") }
    }
    var feedLayout = FeedLayout(rawValue: UserDefaults.standard.string(forKey: "feed.layout") ?? "") ?? .list {
        didSet { UserDefaults.standard.set(feedLayout.rawValue, forKey: "feed.layout") }
    }
    /// The Feed table's order (not persisted, like the Library's sort).
    var feedSort = FeedTableColumn.defaultSort
    /// The Feed table's columns, per kind of device (build 17: "why are there so few options").
    var feedColumns = ColumnChoice.load(key: "feed.columns", compactDefault: FeedTableColumn.compactDefault,
                                        regularDefault: FeedTableColumn.regularDefault, introduced: FeedTableColumn.introduced, from: .standard) {
        didSet { feedColumns.save(to: .standard) }
    }
    /// The Feed leaves out papers already in the library (its "…" menu; kept on the device).
    var feedHidesLibrary = UserDefaults.standard.bool(forKey: "feed.hidesLibrary") {
        didSet { UserDefaults.standard.set(feedHidesLibrary, forKey: "feed.hidesLibrary") }
    }
    /// The Feed's papers as shown: without those in the library when the reader chose so.
    var shownFeedResults: [DiscoveryResult] {
        guard feedHidesLibrary else { return feedResults }
        let library = librarySourceIDs
        return feedResults.filter { !library.contains($0.sourceID) }
    }
    /// All chats' columns, per kind of device (build 16 #3).
    var chatColumns = ColumnChoice.load(key: "chats.columns", compactDefault: ChatTableLayout.compactDefault,
                                        regularDefault: ChatTableLayout.regularDefault, from: .standard) {
        didSet { chatColumns.save(to: .standard) }
    }
    var searchExternal = false
    var searchQuery: String { get { searchExternal ? discoveryQuery : libraryQuery } set { if searchExternal { discoveryQuery = newValue } else { libraryQuery = newValue } } }
    var showAbstracts = UserDefaults.standard.object(forKey: "library.showAbstracts") as? Bool ?? true { didSet { UserDefaults.standard.set(showAbstracts, forKey: "library.showAbstracts") } }
    var showTopics = UserDefaults.standard.object(forKey: "library.showTopics") as? Bool ?? true { didSet { UserDefaults.standard.set(showTopics, forKey: "library.showTopics") } }
    var appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system" { didSet { UserDefaults.standard.set(appearance, forKey: "appearance") } }
    var paperFontSize = UserDefaults.standard.double(forKey: "paperFontSize") == 0 ? 17 : UserDefaults.standard.double(forKey: "paperFontSize") { didSet { UserDefaults.standard.set(paperFontSize, forKey: "paperFontSize") } }
    var chatFontSize = UserDefaults.standard.double(forKey: "chatFontSize") == 0 ? 17 : UserDefaults.standard.double(forKey: "chatFontSize") { didSet { UserDefaults.standard.set(chatFontSize, forKey: "chatFontSize") } }
    /// The Feed's text size as steps from the system's (A− / A+, owner feedback build 16 #6); 0 follows the system.
    var feedTextStep = UserDefaults.standard.integer(forKey: "feedTextStep") { didSet { UserDefaults.standard.set(feedTextStep, forKey: "feedTextStep") } }
    /// iPad and Mac Reader: the chat column beside the paper is hidden for full-width reading (kept per device).
    var readerChatHidden = UserDefaults.standard.bool(forKey: "reader.chatHidden") { didSet { UserDefaults.standard.set(readerChatHidden, forKey: "reader.chatHidden") } }
    /// The chat column's width there as the reader dragged it; nil is the default for the window's width.
    var readerChatWidth = UserDefaults.standard.object(forKey: "reader.chatWidth") as? Double { didSet { UserDefaults.standard.set(readerChatWidth, forKey: "reader.chatWidth") } }
    /// Passage-linked conversations (Views/PaperPassages.swift): underline passages with chats (Settings › Reading),
    /// a Go to passage waiting for the reader, and the chats offered when a tap lands on several marks.
    var showsPassageMarks = UserDefaults.standard.object(forKey: "reader.passageMarks") as? Bool ?? true { didSet { UserDefaults.standard.set(showsPassageMarks, forKey: "reader.passageMarks") } }
    var passageRequest: PaperPassageRequest?
    var passageChoices: [UUID]?
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
    var chatTitle: String {
        guard !chatWasDeleted else { return "Deleted conversation" }
        guard let root = activeConversation.flatMap({ privateState.revisions(for: $0).first }) else { return "New chat" }
        return ChatTitle.display(root.payload.text ?? "", source: root.payload.titleSource)
    }
    /// The visible conversation has a topic title (generated or renamed); without one, its next answer asks for one.
    var chatHasTopicTitle: Bool { activeConversation.flatMap { privateState.revisions(for: $0).first?.payload.titleSource } != nil }

    // MARK: Chat profiles (model, effort, length; owner request 2026-10-08, docs/architecture/CHAT.md#models-effort-and-length)

    /// The chat function's published table; nil until fetched, or when the server offers no choices. Without it,
    /// requests carry no choice and ask for no title, exactly as before profiles.
    private(set) var chatProfileTable: ChatProfileTable?
    /// The last fetch failed (the control offers Try again).
    private(set) var chatProfileTableFailed = false
    @ObservationIgnored private var chatProfileFetch: UUID?
    /// Settings › Chat defaults: what a new chat starts with (this device only).
    var chatDefaultProfile: ChatProfileChoice = ReaderModel.storedChatDefault() {
        didSet { UserDefaults.standard.set(chatDefaultProfile.id, forKey: Self.chatDefaultKey) }
    }
    private static let chatDefaultKey = "chat.defaultProfile"
    private static func storedChatDefault() -> ChatProfileChoice {
        UserDefaults.standard.string(forKey: chatDefaultKey).flatMap(ChatProfileChoice.init(id:)) ?? .standard
    }
    /// A choice made in a chat's control and not yet used, per composer; once an answer carries it, the conversation's
    /// newest answer remembers it (encrypted, on every device).
    private var pendingChatProfiles: [UUID: ChatProfileChoice] = [:]

    /// The visible chat's model, effort and length: a choice just made here, else what its newest answer used, else
    /// Settings › Chat defaults.
    var chatProfile: ChatProfileChoice {
        if let composer = chatComposerID, let pending = pendingChatProfiles[composer] { return pending }
        return Self.answeredProfile(in: chatMessages) ?? chatDefaultProfile
    }

    func setChatProfile(_ choice: ChatProfileChoice) {
        pendingChatProfiles[chatComposerID ?? chatWorkspace.composer(in: chatContext)] = choice
    }

    /// The newest answer in a branch that recorded a profile.
    static func answeredProfile(in messages: [AppliedEvent]) -> ChatProfileChoice? {
        messages.last { $0.payload.role == .assistant && $0.payload.profile.flatMap(ChatProfileChoice.init(id:)) != nil }?
            .payload.profile.flatMap(ChatProfileChoice.init(id:))
    }

    /// What a request carries: the choice when the server's table offers it (else the server's default), and whether
    /// to ask for a topic title. Nothing extra without a table (an older server).
    func requestChoices(for turn: ChatAnswerTurn, branch: [AppliedEvent], state: PrivateState)
        -> (profile: ChatProfileChoice, topicTitle: Bool, sent: Bool) {
        guard let table = chatProfileTable else { return (.standard, false, false) }
        let conversationID = turn.conversationID
        let wanted = turn.profile ?? pendingChatProfiles[turn.composerID] ?? Self.answeredProfile(in: branch) ?? chatDefaultProfile
        let titled = state.revisions(for: conversationID).first?.payload.titleSource != nil
        return (table.offers(wanted) ? wanted : table.defaultChoice, !titled, true)
    }

    /// Fetches the server's table once per session (again after a failure, when the controls open).
    func refreshChatProfiles(force: Bool = false) {
        guard let transport = chatTransport, let accountID, chatProfileFetch == nil, force || chatProfileTable == nil else { return }
        let fetch = UUID()
        chatProfileFetch = fetch
        Task { [weak self] in
            let table = try? await transport.chatProfiles(accountID: accountID)
            guard let self, self.chatProfileFetch == fetch else { return }
            self.chatProfileFetch = nil
            if let table { self.chatProfileTable = table }
            self.chatProfileTableFailed = table == nil && self.chatProfileTable == nil
        }
    }

    /// Renames a conversation: a new encrypted revision with the reader's title (`renamed`), which a generated title
    /// never replaces. Empty names are ignored.
    func renameConversation(_ id: UUID, to title: String) async {
        guard let store, let device, let event = privateState.titledConversation(id, title: title, source: PrivateEvent.renamedTitle) else { return }
        let scope = sessionID, persistence = localPersistence, storeScope = workOwnership.storeScope
        do {
            let entries = [(id: UUID(), event: event)]
            let write = try persistence.acceptWrite { local in try await local.appendBatch(entries, deviceID: device.deviceID) }
            _ = try await write.value
            let snapshot = await store.snapshot()
            guard sessionID == scope else { return }
            if workOwnership.owns(storeScope) { publish(snapshot) }
            Task { if self.sessionID == scope { await self.synchronize() } }
        } catch {
            if sessionID == scope { show(error) }
        }
    }
    var chatWasDeleted: Bool { activeConversation.map { privateState.isDeleted($0) } ?? false }
    var privateState = PrivateState() {
        didSet {
            branchSelections.reconcile(with: privateState, observing: activeConversation)
            chatWorkspace.setDeletedConversations(Set(privateState.events.values.lazy
                .filter { $0.payload.kind == .tombstone }.map { $0.payload.entityID }))
            checkpointObservedBranches()
            let diagrams = privateState.diagramsByMessage()
            if diagrams != chatDiagrams { chatDiagrams = diagrams }
            let counts = Self.conversationCounts(privateState)
            if counts != paperChatCounts {
                paperChatCounts = counts
                if librarySort.field == .chats { librarySearchSourceChanged() }
            }
            let summaries = privateState.conversationSummaries()
            if summaries != conversationSummaries { conversationSummaries = summaries }
        }
    }
    /// All chats' rows: one summary per saved conversation, computed once per history change (one pass over the
    /// decrypted events, on this device).
    private(set) var conversationSummaries: [ConversationSummary] = []
    /// Saved conversations per paper, from the private state (deleted ones excluded).
    private(set) var paperChatCounts: [UUID: Int] = [:]
    /// This device's reading activity per paper: last opened here and progress at the saved
    /// position. Kept in the account's local encrypted folder; never sent to the server.
    private(set) var readingActivity: [UUID: PaperActivity] = [:]
    struct PaperActivity: Equatable {
        var openedAt: Date?
        var progress: Double?
    }
    @ObservationIgnored private var latestLocationKeys: [UUID: String] = [:]
    @ObservationIgnored private var readingSave: Task<Void, Never>?
    @ObservationIgnored private var readingResort: Task<Void, Never>?
    @ObservationIgnored private var readingDirty = false

    private static func conversationCounts(_ state: PrivateState) -> [UUID: Int] {
        var deleted = Set<UUID>(), conversations: [UUID: UUID] = [:]
        for event in state.events.values {
            switch event.payload.kind {
            case .tombstone: deleted.insert(event.payload.entityID)
            case .conversation: if let document = event.payload.documentID { conversations[event.payload.entityID] = document }
            default: break
            }
        }
        var counts: [UUID: Int] = [:]
        for (conversation, document) in conversations where !deleted.contains(conversation) { counts[document, default: 0] += 1 }
        return counts
    }
    /// Saved diagrams by the assistant message (entity ID) that drew them.
    private(set) var chatDiagrams: [UUID: ChatDiagramLink] = [:]
    var presentedDiagram: PresentedDiagram?
    func openDiagram(_ id: UUID) { if diagram(id) != nil { presentedDiagram = PresentedDiagram(id: id) } }
    func diagram(_ id: UUID) -> ChatDiagram? { privateState.revisions(for: id).first.flatMap { ChatDiagram.decode($0.payload.text) } }
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
    var showAllChats = false { didSet { if !showAllChats { allChatsPaperID = nil } } }
    /// The paper All chats was opened from (its paper or chat screen): it starts filtered to that paper's chats.
    private(set) var allChatsPaperID: UUID?
    func openAllChats(paper: UUID?) { allChatsPaperID = paper; showAllChats = true }
    /// A paper's saved conversations, most recently used first (the chat title menu's "Chats about this paper").
    func conversations(about paperID: UUID) -> [ConversationSummary] {
        ChatHistoryQuery.rows(conversationSummaries, paperTitles: [:], filter: .thisPaper, paperID: paperID, search: "", sort: .default)
            .map(\.summary)
    }
    var showDiagrams = false
    var localPaperPresentation: LocalPaperPresentation?
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
    /// How this account signs in ("apple", "google", "email") when Auth said; the Account page shows it.
    private(set) var signInProviders: [String] = []
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
    private var chatStreamProgress: [UUID: ChatProgress] = [:]
    @ObservationIgnored private var chatStreamBuffer: [UUID: String] = [:]
    @ObservationIgnored private var chatStreamFlushes: Set<UUID> = []
    @ObservationIgnored private var pendingSelection: (composerID: UUID, prompt: String, quote: String, action: ChatAction?, origin: PassageOrigin?)?
    var chatConsentPrompt: ChatConsentPrompt?
    /// Paper podcasts: Listen catalog, player, downloads, private generation (Services/PodcastCenter.swift).
    let podcasts = PodcastCenter()
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
    private var accountID: UUID? { didSet { if accountID != oldValue { librarySearchSourceChanged(); podcasts.accountChanged() } } }
    private var publishedGeneration: Int64 = -1
    /// Encrypted changes on this device not yet synced (the Account page says how many).
    private(set) var publishedPendingCount = 0
    var readerSessionID: UUID { sessionID }
    var hasLocalPaperStore: Bool { localPersistence.localPaperStore != nil }
    func beginLocalPaperDownload(_ id: UUID) -> Bool {
        guard !localPaperDownloads.contains(id) else { return false }
        localPaperDownloads.insert(id)
        return true
    }
    func finishLocalPaperDownload(_ id: UUID) { localPaperDownloads.remove(id) }
    func acceptLocalPaperWrite<Value: Sendable>(_ operation: @escaping @Sendable (DevicePaperStore) async throws -> Value) throws -> Task<Value, Error> {
        try localPersistence.acceptLocalPaperWrite(operation)
    }
    func loadLocalPaperRecords() async -> [LocalPaperRecord] {
        await localPersistence.localPaperStore?.records() ?? []
    }
    func refreshLocalPaperRecords() async { localPaperRecords = await loadLocalPaperRecords() }
    func localPaperAvailable(for item: LibraryImportRecord) -> Bool {
        localPaperRecord(for: item) != nil
    }
    /// Presents a source-only PDF from the encrypted device store. This does
    /// not create a cloud document or a server-side reader artifact.
    func sourceImport(for paper: Paper) -> LibraryImportRecord? {
        guard let reference = paper.sourceMembership else { return nil }
        return completeLibrary?.imports.first { $0.id == reference.membershipID && $0.visible }
    }
    func openLocalPaper(_ item: LibraryImportRecord) {
        guard let sourceID = item.sourceID, let revision = item.sourceRevision ?? item.requestedRevision else { return }
        openLocalPDF(sourceID: sourceID, revision: revision, title: item.metadata?.title ?? LibrarySource.placeholderTitle(sourceID: sourceID))
    }
    func openLocalPDF(sourceID: String, revision: Int, title: String) {
        guard
              let record = localPaperRecords.first(where: { $0.identity.sourceID == sourceID && $0.identity.revision == revision }),
              let store = localPersistence.localPaperStore else {
            error = "This paper is not available on this device. Download it first."
            return
        }
        let scope = readerSessionID
        Task { [weak self] in
            do {
                let data = try await store.read(record.identity)
                guard let self, self.readerSessionID == scope else { return }
                self.localPaperPresentation = LocalPaperPresentation(id: record.id, title: title, data: data)
            } catch {
                guard let self, self.readerSessionID == scope else { return }
                self.error = "The saved PDF could not be opened. Add or download the PDF again."
                await self.refreshLocalPaperRecords()
            }
        }
    }
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
    @ObservationIgnored private var librarySearchCandidatePositions: [String: Int] = [:]
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
        #if DEBUG && FIXTURE_HOST && !OFFLINE_RESOURCE_MEASUREMENTS
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
        if LibraryV5Fixture.isEnabled {
            // An activated account on a scripted upload-capable (v5) library; never the bundled backend.
            do {
                let fixture = try LibraryV5Fixture.makeBackend()
                resolvedConfiguration = fixture.configuration; resolvedClient = fixture.client
            } catch { resolvedConfiguration = nil; resolvedClient = nil; fixtureFailed = true }
        }
        #endif
        self.configuration = resolvedConfiguration; self.backend = resolvedClient
        self.chatTransportOverride = resolvedTransport; self.chatConsentStore = resolvedConsentStore
        self.readerBundleVerification = readerBundleVerification; self.readerBundleDirectoryReader = readerBundleDirectoryReader
        self.librarySearchWorker = librarySearchWorker
        if fixtureFailed { error = "The local sign-in fixture couldn’t be prepared." }
        podcasts.host = self
    }

    /// The signed-in, activated account's podcast service and local folder; nil before activation or when signed out.
    var podcastAccount: PodcastAccount? {
        guard let backend, let accountID, let configuration, let device, device.accountID == accountID,
              let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return nil }
        return PodcastAccount(id: accountID, transport: BackendPodcastTransport(client: backend, accountID: accountID),
                              folder: base.appendingPathComponent("\(configuration.environment)/\(accountID.wire)", isDirectory: true),
                              localKey: device.localStoreKey, deviceID: device.deviceID)
    }

    /// The library item the podcast service knows a paper by.
    func podcastItemID(for paper: Paper) -> UUID? { completeLibrary?.items.first { $0.documentID == paper.id && $0.visible }?.id }

    var configured: Bool { configuration != nil }
    var isSignedIn: Bool { accountID != nil }
    var filteredPapers: [Paper] {
        libraryRows.compactMap { if case .paper(let paper) = $0 { return paper }; return nil }
    }

    private var currentLibrarySearchKey: LibrarySearchKey {
        LibrarySearchKey(sessionID: sessionID, accountID: accountID,
            sourceRevision: librarySearchSourceRevision, query: libraryQuery,
            sort: librarySort, commandRevision: libraryCommandGeneration)
    }

    /// The displayed rows are still the right set (same session, account and query). A sort
    /// change only reorders them, so the list or table stays in place until the new order lands.
    var librarySearchKeepsCurrentRows: Bool {
        guard let completed = completedLibrarySearchKey else { return false }
        let current = currentLibrarySearchKey
        return completed.sessionID == current.sessionID && completed.accountID == current.accountID &&
            completed.query == current.query
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
            old.year == new.year && old.authorNames == new.authorNames &&
            old.abstract == new.abstract && old.keywords == new.keywords &&
            old.sourceID == new.sourceID && old.sourceRevision == new.sourceRevision &&
            old.tags == new.tags && old.archived == new.archived && old.pageCount == new.pageCount && old.sourceURL == new.sourceURL
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
        #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && FIXTURE_HOST
        OfflineResourceProbe.shared.beginSearch(query: libraryQuery)
        #endif
        guard librarySearchPreparation == nil else { return }
        // One queued turn coalesces synchronous library/command publication.
        // Query changes reuse the immutable metadata snapshot.
        librarySearchPreparation = Task { @MainActor [weak self] in
            guard let self else { return }
            self.librarySearchPreparation = nil
            var mayReuse = self.librarySearchKeepsCurrentRows &&
                self.completedLibrarySearchKey?.sort == self.librarySort &&
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

    /// How many rows each quick filter holds, and the tags to filter by within the current quick filter, most used
    /// first (the filter row's chips and Tags menu). Archive changes still syncing already count.
    func libraryFilterSummary() -> LibraryFilterSummary {
        var pendingArchive: [UUID: Bool] = [:]
        for command in libraryCommands where command.isUnfinished {
            if case .setArchived(let document, let archived, _) = command.mutation { pendingArchive[document] = archived }
        }
        var counts: [LibraryFilter: Int] = [:], tagRows: [[String]] = []
        for paper in papers {
            let activity = readingActivity[paper.id], tags = LibraryTags.tags(for: paper)
            for filter in LibraryFilter.allCases where filter.includesPaper(archived: pendingArchive[paper.id] ?? paper.archived,
                                                                          opened: activity?.openedAt, progress: activity?.progress) {
                counts[filter, default: 0] += 1
                if filter == libraryFilter { tagRows.append(tags) }
            }
        }
        for item in libraryImports {
            for filter in LibraryFilter.allCases where filter.includesImport(item.phase, retryingAutomatically: item.isRetryingAutomatically) {
                counts[filter, default: 0] += 1
                if filter == libraryFilter { tagRows.append(LibraryTags.tags(for: item)) }
            }
        }
        return LibraryFilterSummary(counts: counts, tags: LibraryTags.counts(tagRows))
    }

    private func prepareLibrarySearchSource() -> Bool {
        #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && FIXTURE_HOST
        let start = DispatchTime.now().uptimeNanoseconds
        #endif
        var candidates: [LibrarySearchCandidate] = []
        var lookup: [String: LibraryListEntry] = [:]
        func append(_ row: LibraryListEntry, fields: [String], sequence: Int64, keys: LibrarySortKeys = .init()) {
            candidates.append(LibrarySearchCandidate(id: row.id, title: row.title,
                fields: fields, recentSequence: sequence, position: candidates.count, keys: keys))
            lookup[row.id] = row
        }
        // Archive changes waiting to sync already apply here, so a swipe hides the row at once.
        var pendingArchive: [UUID: Bool] = [:]
        for command in libraryCommands where command.isUnfinished {
            if case .setArchived(let document, let archived, _) = command.mutation { pendingArchive[document] = archived }
        }
        // The quick filter and tag filter decide which rows are candidates; search and sort then run over them.
        let filter = libraryFilter, tagFilter = libraryTagFilter
        func tagged(_ tags: [String]) -> Bool { tagFilter.map(tags.contains) ?? true }
        for paper in papers {
            let activity = readingActivity[paper.id]
            let tags = LibraryTags.tags(for: paper)
            guard filter.includesPaper(archived: pendingArchive[paper.id] ?? paper.archived, opened: activity?.openedAt,
                                       progress: activity?.progress), tagged(tags) else { continue }
            let keys = LibrarySortKeys(authors: (paper.authorNames.first.map(LibraryFormat.familyName)) ?? (paper.authors.isEmpty ? nil : paper.authors),
                                       year: paper.year, opened: activity?.openedAt, progress: activity?.progress,
                                       chats: paperChatCounts[paper.id] ?? 0, tag: tags.first, pages: paper.pageCount,
                                       source: LibrarySourceLabel.label(sourceID: paper.sourceID, url: paper.sourceURL))
            append(.paper(paper), fields: [paper.title, paper.authors, paper.abstract, paper.sourceReference ?? ""] + paper.keywords + tags,
                   sequence: libraryCreationSequences[paper.id] ?? Int64.max, keys: keys)
        }
        for item in libraryImports {
            let tags = LibraryTags.tags(for: item)
            guard filter.includesImport(item.phase, retryingAutomatically: item.isRetryingAutomatically), tagged(tags) else { continue }
            let reference = (item.sourceID ?? "") + ((item.sourceRevision ?? item.requestedRevision).map { "v\($0)" } ?? "")
            let keys = LibrarySortKeys(authors: item.metadata?.authors.first.map(LibraryFormat.familyName),
                                       year: item.metadata?.publishedAt.flatMap { Int($0.prefix(4)) }, tag: tags.first,
                                       source: LibrarySourceLabel.label(sourceID: item.sourceID, url: nil))
            append(.pending(item), fields: [reference, item.metadata?.title ?? "", item.metadata?.abstract ?? ""]
                + (item.metadata?.authors ?? []) + (item.metadata?.categories ?? []) + tags, sequence: item.createdSequence, keys: keys)
        }
        for command in libraryCommands where filter.includesQueued && tagFilter == nil {
            // Cached mappings suppress duplicate presentation only; they do
            // not resolve the durable command or authorize a mutation.
            guard case .beginImport(let source, let revision, _) = command.mutation,
                  command.isUnfinished, !presentedImportIDs.contains(command.id) else { continue }
            append(.queued(command), fields: [command.display ?? "", source + (revision.map { "v\($0)" } ?? "")],
                   sequence: Int64.max)
        }
        let equivalent = candidates == librarySearchCandidates
        librarySearchCandidates = candidates; libraryRowLookup = lookup
        librarySearchCandidatePositions = Dictionary(candidates.map { ($0.id, $0.position) }, uniquingKeysWith: { first, _ in first })
        librarySearchCandidateRevision = librarySearchSourceRevision
        librarySearchSourceDirty = false
        #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && FIXTURE_HOST
        OfflineResourceProbe.shared.searchSourceBuilt(rows: candidates.count,
            elapsedMS: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        #endif
        return equivalent
    }

    private func acceptLibrarySearch(_ event: LibrarySearchEvent) {
        switch event {
        case .completed(let result):
            guard librarySearchTicket == result.ticket, currentLibrarySearchKey == result.ticket.key else { return }
            #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && FIXTURE_HOST
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
            #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && FIXTURE_HOST
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

    /// The row's metadata snapshot as last prepared for search (its sort keys). A row that
    /// arrived after that snapshot gets a minimal stand-in until the next search.
    func librarySearchCandidate(for entry: LibraryListEntry) -> LibrarySearchCandidate {
        if let index = librarySearchCandidatePositions[entry.id], librarySearchCandidates.indices.contains(index),
           librarySearchCandidates[index].id == entry.id { return librarySearchCandidates[index] }
        return LibrarySearchCandidate(id: entry.id, title: entry.title, fields: [], recentSequence: .max, position: .max)
    }

    /// What the table shows for one entry, from current model state.
    func libraryFacts(for entry: LibraryListEntry) -> LibraryRowFacts {
        let status = libraryStatus(for: entry)
        switch entry {
        case .paper(let paper):
            let activity = readingActivity[paper.id]
            return LibraryRowFacts(id: entry.id, title: paper.title, paper: paper, authors: LibraryFormat.shortAuthors(for: paper),
                year: paper.year, tags: LibraryTags.tags(for: paper), added: paper.addedAt,
                opened: activity?.openedAt, progress: activity?.progress, chats: paperChatCounts[paper.id] ?? 0,
                pages: paper.pageCount, status: status, needsCredits: false,
                source: LibrarySourceLabel.label(sourceID: paper.sourceID, url: paper.sourceURL),
                spokenSource: LibrarySourceLabel.spoken(sourceID: paper.sourceID, url: paper.sourceURL))
        case .pending(let item):
            let retrying = isRetrying(item)
            return LibraryRowFacts(id: entry.id, title: entry.title, paper: nil,
                authors: LibraryFormat.shortAuthors(item.metadata?.authors ?? []),
                year: item.metadata?.publishedAt.flatMap { Int($0.prefix(4)) },
                tags: LibraryTags.tags(for: item), added: nil, opened: nil, progress: nil,
                chats: 0, pages: nil, status: status,
                needsCredits: !retrying && item.phase == .failed && item.errorCode == .insufficientCredits,
                stepTiming: importSteps.timing(of: item), importProgress: retrying ? nil : importProgress(for: item),
                source: LibrarySourceLabel.label(sourceID: item.sourceID, url: nil),
                spokenSource: LibrarySourceLabel.spoken(sourceID: item.sourceID, url: nil),
                step: retrying ? item.retryStep : item.step,
                importAction: LibraryImportAction.available(for: item, retrying: retrying,
                    localPaperAvailable: localPaperRecord(for: item) != nil))
        case .queued:
            return LibraryRowFacts(id: entry.id, title: entry.title, paper: nil, authors: nil, year: nil, tags: [],
                added: nil, opened: nil, progress: nil, chats: 0, pages: nil, status: status, needsCredits: false)
        }
    }

    /// A failed import whose Retry is on its way to the server: it shows as running again at once (owner feedback
    /// 2026-10-07), until the server's own state arrives. A retry the server refused (needs review) stops counting.
    func isRetrying(_ item: LibraryImportRecord) -> Bool {
        guard item.phase == .failed, !item.isRetryingAutomatically else { return false }
        #if DEBUG && FIXTURE_HOST
        if fixtureRetriedImports.contains(item.id) { return true }
        #endif
        return libraryCommands.contains { command in
            guard command.isUnfinished, case .retryImport(let id, let revision) = command.mutation else { return false }
            return id == item.id && revision == item.intentRevision
        }
    }

    /// An import in progress: its step in the reader's words, percent and time left (nil when it isn't in progress).
    func importProgress(for item: LibraryImportRecord) -> ImportProgress? {
        importProgressTracker.progress(of: item, stepSince: importSteps.timing(of: item)?.since, now: importClock())
    }

    /// Only the Status column's value (cheap enough to check every row for the column's visibility).
    func libraryStatus(for entry: LibraryListEntry) -> LibraryRowFacts.Status {
        switch entry {
        case .paper(let paper):
            if openingPaperID == paper.id { return .active("Opening…") }
            if paper.isLocalPDF { return .info(localPaperRecords.contains(where: { $0.identity.sourceID == paper.sourceID }) ? "PDF on this device" : "PDF needed on this device") }
            if !paper.canReadStructured { return .problem("Reader unavailable") }
            switch offlineStatus(for: paper) {
            case .available: return .none
            case .unavailable: return .problem("Unavailable offline")
            case .none: return paper.isSample ? .none : .info("Not downloaded")
            }
        case .pending(let item):
            if localPaperDownloads.contains(item.id) { return .active("Downloading on this device…") }
            if localPaperRecord(for: item) != nil { return .info("On this device") }
            if isRetrying(item) { return .active(item.retryStep.label(short: true)) }
            switch item.phase {
            case .resolving, .acquiring: return .active(item.libraryShortStatus)
            case .failed where item.isRetryingAutomatically: return .active(item.libraryShortStatus)
            case .failed, .membershipConflict: return .problem(item.libraryShortStatus)
            default: return .info(item.libraryShortStatus)
            }
        case .queued(let command): return .info(command.libraryStatus)
        }
    }

    private func localPaperRecord(for item: LibraryImportRecord) -> LocalPaperRecord? {
        guard let sourceID = item.sourceID,
              let revision = item.sourceRevision ?? item.requestedRevision else { return nil }
        return localPaperRecords.first { $0.identity.sourceID == sourceID && $0.identity.revision == revision }
    }

    // MARK: Reading activity (device-local)

    /// Opening a paper records when this account last opened it on this device.
    private func recordOpened(_ paper: Paper, at date: Date = Date()) {
        readingActivity[paper.id, default: PaperActivity()].openedAt = date
        readingActivityChanged(resort: librarySort.field == .opened || libraryFilter.usesActivity)
    }

    /// The reader reports its place (throttled while scrolling). The position stays per immutable
    /// artifact; the paper's progress follows the latest saved position.
    func recordReadingLocation(_ location: PaperReadingLocation, key: String, documentID: UUID) {
        paperLocations[key] = location
        latestLocationKeys[documentID] = key
        if let progress = location.progress {
            let previous = readingActivity[documentID]?.progress
            // Whole-percent changes only, so scrolling doesn't redraw the library continuously.
            if previous.map({ LibraryFormat.percent($0) }) != LibraryFormat.percent(progress) {
                readingActivity[documentID, default: PaperActivity()].progress = progress
                if librarySort.field == .progress || libraryFilter.usesActivity { scheduleActivityResort() }
            }
        }
        readingActivityChanged(resort: false)
    }

    private func readingActivityChanged(resort: Bool) {
        readingDirty = true
        if resort { librarySearchSourceChanged() }
        guard readingSave == nil else { return }
        let scope = sessionID
        readingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.sessionID == scope else { return }
            self.readingSave = nil
            self.saveReadingActivity()
        }
    }

    /// Re-sorting by progress waits until scrolling settles.
    private func scheduleActivityResort() {
        readingResort?.cancel()
        let scope = sessionID
        readingResort = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.sessionID == scope else { return }
            self.readingResort = nil
            if self.librarySort.field == .progress || self.libraryFilter.usesActivity { self.librarySearchSourceChanged() }
        }
    }

    /// Saves now (scene changes, sign-out). Signed-out reading stays in memory only.
    func flushReadingActivity() {
        readingSave?.cancel(); readingSave = nil
        saveReadingActivity()
    }

    private func saveReadingActivity() {
        guard readingDirty, accountID != nil else { return }
        let entries = readingActivityEntries()
        do {
            let write = try localPersistence.acceptReadingWrite(entries)
            readingDirty = false
            let scope = sessionID
            Task { [weak self] in
                // A failed write is retried with the next save.
                if (try? await write.value) == nil, let self, self.sessionID == scope { self.readingDirty = true }
            }
        } catch {
            // Activating or retired: keep the changes for the next save.
        }
    }

    private func readingActivityEntries() -> [ReadingActivityEntry] {
        Set(readingActivity.keys).union(latestLocationKeys.keys).map { id in
            let activity = readingActivity[id]
            let key = latestLocationKeys[id]
            let location = key.flatMap { paperLocations[$0] }
            return ReadingActivityEntry(documentID: id, openedAt: activity?.openedAt, progress: activity?.progress,
                locationKey: location == nil ? nil : key,
                location: location.map { .init(blockIndex: $0.blockIndex, blockFraction: $0.blockFraction,
                                                blockHeight: $0.blockHeight, scrollY: $0.scrollY) })
        }
    }

    /// Loaded entries fill in what this session hasn't recorded itself.
    private func restoreReadingActivity(_ entries: [ReadingActivityEntry]) {
        var activity = readingActivity
        for entry in entries {
            if activity[entry.documentID] == nil {
                activity[entry.documentID] = PaperActivity(openedAt: entry.openedAt, progress: entry.progress)
            }
            if latestLocationKeys[entry.documentID] == nil, let key = entry.locationKey, let location = entry.location {
                latestLocationKeys[entry.documentID] = key
                if paperLocations[key] == nil {
                    paperLocations[key] = PaperReadingLocation(blockIndex: location.blockIndex, blockFraction: location.blockFraction,
                        blockHeight: location.blockHeight, scrollY: location.scrollY, progress: entry.progress)
                }
            }
        }
        if activity != readingActivity {
            readingActivity = activity
            if librarySort.field.usesActivity || libraryFilter.usesActivity { librarySearchSourceChanged() }
        }
    }

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
        startStoreUpdates()
        #if DEBUG && FIXTURE_HOST
        resetLibraryPreferencesForFixtures()
        #endif
        #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && FIXTURE_HOST
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
        #if DEBUG && FIXTURE_HOST
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
        #if DEBUG && FIXTURE_HOST && !OFFLINE_RESOURCE_MEASUREMENTS
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
                email = user.email; signInProviders = user.providers; accountID = user.id
                beginAccountPreparation(user, client: client, scope: scope)
                await accountPreparationTask?.value
            }
            #if DEBUG && FIXTURE_HOST
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
        accountID = acceptance.user.id; email = acceptance.user.email; signInProviders = acceptance.user.providers
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
            do {
                try await self.signedIn(user, client: client, scope: scope)
                // Purchases made while signed out (or not yet confirmed) are reported now.
                Task { await self.syncStoreTransactions() }
            }
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
            self.email = user.email; self.signInProviders = user.providers; showSignIn = false
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

    /// Device approval (DeviceApprovalViews.swift): the account, while this device holds active keys to share.
    var deviceApprovalAccount: UUID? {
        guard let accountID, let device, device.accountID == accountID, device.bundle != nil else { return nil }
        return accountID
    }

    /// Settings › Account › Add a device and the waiting-device banner. Nil until this device's keys are active.
    func makeDeviceApprover() -> DeviceApprover? {
        guard let account = deviceApprovalAccount else { return nil }
        let keys: @MainActor () -> KeyBundle? = { [weak self] in
            guard let self, self.accountID == account, self.device?.accountID == account else { return nil }
            return self.device?.bundle
        }
        #if FIXTURE_HOST
        if DeviceApprovalFixture.isEnabled {
            return DeviceApprover(accountID: account, transport: DeviceApprovalFixture.shared, currentKeys: keys, refreshKeys: { keys() })
        }
        #endif
        guard let backend else { return nil }
        // A refresh runs the ordinary key preparation (CloudSync), which updates `device` when keys rotated.
        return DeviceApprover(accountID: account, transport: LiveDeviceApprovalTransport(backend: backend, accountID: account),
                              currentKeys: keys, refreshKeys: { [weak self] in await self?.synchronize(); return keys() })
    }

    #if targetEnvironment(macCatalyst)
    /// The Mac recovery sheet's QR path uses the same DeviceKeys pending enrollment as browser approval. A completed
    /// poll is activated through the normal ReaderModel ownership path before the sheet is dismissed.
    func macApprovalPayload(refresh: Bool) async throws -> DeviceApprovalPayload? {
        guard let accountID, let keys else { throw BackendError.signInRequired }
        let scope = sessionID
        let payload = try await keys.macApprovalPayload(refresh: refresh)
        guard sessionID == scope, self.accountID == accountID else { throw BackendError.signInRequired }
        if payload == nil, let approved = try keys.cachedDevice() {
            try await activate(approved, scope: scope)
            guard sessionID == scope else { throw BackendError.signInRequired }
            needsRecovery = false; recoveryCode = nil; showRecovery = false
        }
        return payload
    }
    #endif

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
        localPaperRecords = await persistence.localPaperStore?.records() ?? []
        localReaderRecords = await persistence.localReaderStore?.records() ?? []
        localPaperDownloads = []
        let snapshot = await local.snapshot()
        let reading = await persistence.readingStore?.load() ?? []
        guard workOwnership.owns(activation), accountID == device.accountID else { throw BackendError.signInRequired }
        try Task.checkCancellation()
        restoreReadingActivity(reading)
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
        activateUploads()
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

    /// Deletes the account on the server, then signs out and erases this
    /// device's copy: the account's local folder (encrypted store, installed
    /// readers, support outbox) and its Keychain items.
    func deleteAccount() async throws {
        guard let backend, let accountID, let configuration else { throw BackendError.signInRequired }
        try await backend.deleteAccount(accountID: accountID)
        let environment = configuration.environment
        await signOut()
        await waitForLocalRetirement()
        Self.eraseLocalAccountData(environment: environment, accountID: accountID)
    }
    var accountDeletedNotice = false

    static func eraseLocalAccountData(environment: String, accountID: UUID) {
        if let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            let directory = base.appendingPathComponent("\(environment)/\(accountID.wire)", isDirectory: true)
            if FileManager.default.fileExists(atPath: directory.path) { try? FileManager.default.removeItem(at: directory) }
        }
        try? KeychainVault.deleteAll(namesContaining: "\(environment).\(accountID.wire).")
    }

    /// Sign-out clears presentation immediately; wait here before retiring any
    /// backing files or opening a replacement owner in a workflow harness.
    func waitForLocalRetirement() async { await retirementQueue.wait() }

    private func clearAccountView() {
        // Before the old writer retires: fence answers and keep their partials.
        retireChatGenerations()
        // The old account's reading activity is saved by its own writer, which retirement drains.
        flushReadingActivity()
        readingResort?.cancel(); readingResort = nil
        readingActivity = [:]; latestLocationKeys = [:]; readingDirty = false
        if let authentication {
            authentication.invalidate()
            retainAuthenticationRetirement(authentication)
        }
        authentication = nil; showSignIn = false
        accountPreparationTask?.cancel(); accountPreparationTask = nil
        accountPreparationIssue = nil; pendingRecoveryPresentation = nil
        workOwnership = ReaderWorkOwnership(); accountID = nil; isBusy = false
        librarySearchCandidates = []; libraryRowLookup = [:]; librarySearchCandidatePositions = [:]
        librarySearchSourceChanged()
        let oldCommands = libraryCommandCoordinator; libraryCommandCoordinator = nil
        oldCommands?.close()
        uploads.deactivate()
        let oldBundles = readerBundles; readerBundles = nil
        oldBundles?.close()
        readerOpenAttempt = nil; readerOpenBinding = nil; openingPaperID = nil; readerOpenIssue = nil; offlineCacheIssue = nil
        localReaderTask?.cancel(); localReaderTask = nil; localReaderOpeningID = nil; localReaderRecords = []
        localPaperRecords = []; localPaperDownloads = []; localPaperPresentation = nil
        let oldLibrary = libraryService; libraryService = nil; libraryContextAuthenticated = false
        Task { await oldLibrary?.invalidate() }
        libraryImports = []; libraryCreationSequences = [:]; presentedImportIDs = []; libraryPublicationGeneration = 0
        libraryRefreshAttempt = nil; libraryRefreshing = false; libraryHasSnapshot = false; libraryIssue = nil
        completeLibrary = nil; libraryCommands = []; libraryCommandGeneration = -1
        libraryPublicationDeferred = false; deferredLibraryObservation = nil
        libraryCommandIssue = nil; showLibraryChanges = false; showImport = false; tagEditor = nil
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
        feedSelection = nil; feedShown = nil; feedPersonal = FeedPersonalization()
        generalChat = true
        email = nil; signInProviders = []; recoveryCode = nil; needsRecovery = false; showRecovery = false; showReports = false; showReport = false; reportScreenshot = nil
        showAllChats = false; showDiagrams = false; presentedDiagram = nil
        showReportsAfterComposer = false; error = nil; tab = .library; wideMode = .library; syncStatus = "On this device"
        syncIssue = nil
    }

    /// While an import is converting on the server, refresh the library on a
    /// bounded schedule (4 s, then 15 s after two minutes) so progress and the
    /// finished paper appear without a manual refresh. Owned by one session.
    /// Seconds until the next import status check, by seconds since polling began: fast at
    /// first so "Queued" moves on as soon as the worker starts (owner feedback 2026-10-05).
    @ObservationIgnored var importPollDelay: (TimeInterval) -> Double = { elapsed in elapsed < 20 ? 1 : elapsed > 120 ? 15 : 4 }
    #if DEBUG && FIXTURE_HOST
    /// Library metadata fixture only: synthetic offline availability for guest rows.
    @ObservationIgnored var fixtureOfflineStatus: [UUID: PaperOfflineStatus] = [:]
    #endif

    private func updateImportPolling() {
        // Includes a download the server will retry by itself, so the row turns into progress when it does.
        let isActive: (LibraryImportRecord) -> Bool = { [.accepted, .resolving, .acquiring].contains($0.phase) || $0.isRetryingAutomatically }
        guard libraryImports.contains(where: isActive), accountID != nil else {
            importPollTask?.cancel(); importPollTask = nil; return
        }
        guard importPollTask == nil else { return }
        let scope = sessionID
        importPollTask = Task { [weak self] in
            let started = Date()
            while !Task.isCancelled {
                let delay = self?.importPollDelay(Date().timeIntervalSince(started)) ?? 4
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled, self.sessionID == scope else { return }
                guard self.libraryImports.contains(where: isActive), self.accountID != nil else { self.importPollTask = nil; return }
                if !self.libraryRefreshing { await self.refreshLibrary() }
            }
        }
    }

    func refreshLibrary() async {
        uploads.resume(); importSharedItems()
        guard let accountID, !workOwnership.isActivating, !libraryPublicationDeferred else { return }
        let scope = sessionID
        await loadLibrary(accountID: accountID, scope: scope)
        if sessionID == scope, !workOwnership.isActivating { await libraryCommandCoordinator?.retry() }
    }

    private func prepareLibraryCommands(accountID: UUID, scope: UUID) async throws {
        guard sessionID == scope, self.accountID == accountID, let configuration, let backend else { throw CancellationError() }
        if libraryCommandCoordinator != nil { return }
        let library = try await scopedLibraryService(accountID: accountID, scope: scope)
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
            // Before recovery, public rows are provisional presentation. Check
            // the sealed protocol root before they can update any offline policy.
            if backend != nil, let configuration,
               try LibraryCommandScope(accountID: accountID, deploymentID: configuration.url.absoluteString) == cacheScope {
                _ = try await scopedLibraryService(accountID: accountID, scope: scope)
            } else {
                // Offline-only fixture readers have no associated transport.
                // They still authenticate this exact cache scope before opening.
                guard libraryService == nil, let store else { throw ReaderError.storageUnavailable }
                _ = try await store.rememberedLibraryReadContext(scope: cacheScope)
                libraryContextAuthenticated = true
            }
            guard workOwnership.owns(activation) else { throw CancellationError() }
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
            #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && FIXTURE_HOST
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
            #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && FIXTURE_HOST
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

    // MARK: Feed — For you and the reader's topics when the server offers them (docs/architecture/
    // PERSONALIZED_FEED.md), else the newest papers in the library's own arXiv categories. The categories are
    // derived on the device; only the chosen category or topic is sent.
    enum FeedState: Equatable { case idle, loading, loaded, failed(String) }
    private(set) var feedResults: [DiscoveryResult] = []
    private(set) var feedState: FeedState = .idle
    private(set) var feedCategory: String?
    private var feedGeneration = 0
    private var feedTask: Task<Void, Never>?
    /// Whether For you is offered and the reader's topic chips (kept on the device).
    var feedPersonal = FeedPersonalization.load(from: .standard) {
        didSet { if feedPersonal != oldValue { feedPersonal.save(to: .standard) } }
    }
    /// The chip the reader picked; nil opens For you when it may be offered, else the first category.
    private(set) var feedSelection: FeedSelection?
    /// What the loaded results are.
    private(set) var feedShown: FeedSelection?

    /// The Feed's chip: the reader's pick while it can be shown, else For you, else the first category.
    var currentFeedSelection: FeedSelection {
        if let feedSelection, feedPersonal.allows(feedSelection) { return feedSelection }
        if feedPersonal.available != false { return .forYou }
        return .category(feedCategory ?? feedCategories.first ?? "cs.LG")
    }

    func selectFeed(_ selection: FeedSelection) {
        feedSelection = selection
        if case .category(let category) = selection { feedCategory = category }
        loadFeed()
    }

    /// Feed topics from the library's arXiv categories (owner feedback 2026-10-06: a single
    /// cross-listed paper put "hep-ph" first). A topic needs two papers unless it is core ML;
    /// the most frequent come first; at most six. Chips show the tag vocabulary's names
    /// (`ArxivTopics.name`), so categories with the same name ("cs.LG" and "stat.ML" are both
    /// Machine learning) show once, as the more frequent one.
    var feedCategories: [String] {
        var counts: [String: Int] = [:]
        for paper in papers where !paper.isSample { for keyword in paper.keywords where keyword.contains(".") || keyword.contains("-") { counts[keyword, default: 0] += 1 } }
        let core: Set<String> = ["cs.LG", "cs.CL", "cs.AI", "cs.CV", "stat.ML", "cs.NE", "cs.RO", "cs.IR"]
        var names = Set<String>()
        let top = counts.filter { $0.value >= 2 || core.contains($0.key) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
            .filter { names.insert(ArxivTopics.name(for: $0)).inserted }.prefix(6)
        return top.isEmpty ? ["cs.LG", "cs.CL", "cs.AI", "cs.CV"] : Array(top)
    }

    func selectFeedCategory(_ category: String) { selectFeed(.category(category)) }

    func loadFeed() {
        let selection = currentFeedSelection
        if case .category(let category) = selection { feedCategory = category }
        // For you and topics open in the server's order; categories newest first (as before).
        if feedShown?.isPersonal != selection.isPersonal { feedSort = FeedTableColumn.defaultSort(personal: selection.isPersonal) }
        feedTask?.cancel(); feedGeneration += 1
        let generation = feedGeneration
        #if DEBUG && FIXTURE_HOST
        if let response = fixtureFeedResponse(selection) { showFeed(response, for: selection); return }
        #endif
        guard let backend, let accountID else { feedState = .failed("Sign in to see new papers."); return }
        feedState = .loading
        let scope = sessionID
        feedTask = Task {
            do {
                let response = try await backend.feed(selection, accountID: accountID)
                guard self.sessionID == scope, self.feedGeneration == generation else { return }
                self.showFeed(response, for: selection)
            } catch {
                guard self.sessionID == scope, self.feedGeneration == generation, !(error is CancellationError) else { return }
                if selection.isPersonal, case BackendError.rejected(let code) = error, code == "feed_unavailable" || code == "invalid_feed_topic" {
                    // For you isn't offered (the category chips, as before), or that topic is gone (For you).
                    if code == "feed_unavailable" { self.feedPersonal.note(nil, for: selection) }
                    self.feedSelection = nil
                    self.loadFeed()
                    return
                }
                self.feedState = .failed("New papers aren’t available right now. Try again in a moment.")
            }
        }
    }

    private func showFeed(_ response: DiscoveryResponse, for selection: FeedSelection) {
        feedPersonal.note(response.feed, for: selection)
        feedResults = response.results; feedShown = selection; feedState = .loaded
    }

    /// arXiv identifiers already in the library or being added.
    var librarySourceIDs: Set<String> {
        Set(papers.compactMap(\.sourceID) + libraryImports.filter { $0.visible }.compactMap(\.sourceID))
    }

    func addDiscovered(_ result: DiscoveryResult) async throws {
        try await importPaper(result.sourceID, stayInSearch: true)
    }

    func importPaper(_ input: String, stayInSearch: Bool = false) async throws {
        let reference = try ArxivReference(input)
        guard canBeginImport, let snapshot = completeLibrary, let commands = libraryCommandCoordinator else { throw ReaderError.storageUnavailable }
        let scope = sessionID
        _ = try await commands.enqueue(.beginImport(sourceID: reference.sourceID, requestedRevision: reference.revision,
                                                    observedCursor: snapshot.committedCursor), display: "arXiv \(reference.identifier)",
                                       observedIn: snapshot.observation.readContext)
        guard sessionID == scope else { throw CancellationError() }
        if !stayInSearch { searchExternal = false; libraryQuery = "" }
    }

    func removePaper(_ paper: Paper) async {
        if paper.isLocalPDF { await editLocalPDF(paper, remove: true); return }
        if let ref = paper.sourceMembership, let item = completeLibrary?.imports.first(where: { $0.id == ref.membershipID }) {
            await changeImport(item, retry: false); return
        }
        guard !paper.isSample, canChangeLibrary, let snapshot = completeLibrary,
              let item = snapshot.items.first(where: { $0.documentID == paper.id && $0.visible }),
              let commands = libraryCommandCoordinator else { return }
        let scope = sessionID
        do {
            _ = try await commands.enqueue(.setMembership(documentID: item.documentID, present: false,
                                                         expectedRevision: item.membershipRevision, approvalID: item.approvalID),
                                           display: String(paper.title.unicodeScalars.prefix(200)), observedIn: snapshot.observation.readContext)
        } catch { if sessionID == scope, !(error is CancellationError) { show(error) } }
    }

    /// Archive or unarchive (migration 020): the item stays in the library and syncs across devices.
    func setArchived(_ paper: Paper, archived: Bool) async {
        if paper.isLocalPDF { await editLocalPDF(paper, archived: archived); return }
        if paper.sourceMembership != nil { if let issue = await editSourceDetails(paper, archived: archived, tags: paper.ownTags) { error = issue }; return }
        guard !paper.isSample, canChangeLibrary, let snapshot = completeLibrary,
              let item = snapshot.items.first(where: { $0.documentID == paper.id && $0.visible }),
              let commands = libraryCommandCoordinator else { return }
        let scope = sessionID
        do {
            _ = try await commands.enqueue(.setArchived(documentID: item.documentID, archived: archived, expectedRevision: item.membershipRevision),
                                           display: String(paper.title.unicodeScalars.prefix(200)), observedIn: snapshot.observation.readContext)
        } catch { if sessionID == scope, !(error is CancellationError) { show(error) } }
    }

    // MARK: Tags (docs/architecture/TAGS.md)

    /// Tag edits waiting to sync, by paper; the newest wins. A follow-up edit held behind a sent one
    /// names its paper through that predecessor.
    private var pendingTagEdits: [UUID: (own: [String], hidden: [String])] {
        var edits: [UUID: (own: [String], hidden: [String])] = [:]
        let byIntent = Dictionary(libraryCommands.map { ($0.handle.intentID, $0) }, uniquingKeysWith: { first, _ in first })
        for command in libraryCommands.sorted(by: { $0.handle.localSequence < $1.handle.localSequence }) where command.isUnfinished {
            if case .setTags(let document, let own, let hidden, _) = command.mutation { edits[document] = (own, hidden) }
            else if case .setSourceDetails(let id, _, let tags, _) = command.mutation { edits[id] = (tags, []) }
            else if command.mutation == nil, case .setTags(let own, let hidden) = command.successor,
                    let parent = command.predecessor.flatMap({ byIntent[$0.intentID] }), let document = parent.mutation?.itemDocument {
                edits[document] = (own, hidden)
            }
        }
        return edits
    }

    private static func withTagEdit(_ paper: Paper, _ edit: (own: [String], hidden: [String])?) -> Paper {
        var row = paper
        row.tags = PaperTags.effective(catalog: paper.catalogTags, own: edit?.own ?? paper.ownTags, hidden: edit?.hidden ?? paper.hiddenTags)
        return row
    }

    /// What the reader asked for shows at once, before the edit syncs (and stays if it can't).
    private func applyPendingTagEdits() {
        let edits = pendingTagEdits
        let updated = papers.map { Self.withTagEdit($0, edits[$0.id]) }
        if updated.map(\.tags) != papers.map(\.tags) { papers = updated }
        if let selected = selectedPaper, let current = papers.first(where: { $0.id == selected.id }), current.tags != selected.tags {
            selectedPaper?.tags = current.tags
        }
    }

    func editTags(for paper: Paper) {
        guard !paper.isSample, papers.contains(where: { $0.id == paper.id }) else { return }
        tagEditor = TagEditorRequest(paperID: paper.id)
    }

    /// The reader's own tags on other papers, most used first (suggestions in the Edit tags sheet).
    func ownTagsInLibrary(excluding paperID: UUID) -> [String] {
        var counts: [String: (name: String, count: Int)] = [:]
        for paper in papers where paper.id != paperID {
            for tag in PaperTags.effective(catalog: [], own: paper.ownTags, hidden: []) {
                let key = tag.lowercased()
                counts[key] = (counts[key]?.name ?? tag, (counts[key]?.count ?? 0) + 1)
            }
        }
        return counts.values.sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }.map(\.name)
    }

    /// Saves `desired` as the tags the reader sees for `paper` (catalog tags left out are hidden; the
    /// rest are their own). Nil on success, otherwise what to tell the reader.
    func saveTags(_ desired: [String], for paper: Paper) async -> String? {
        if paper.isLocalPDF { await editLocalPDF(paper, tags: desired); return nil }
        if paper.sourceMembership != nil { return await editSourceDetails(paper, archived: paper.archived, tags: desired) }
        guard !paper.isSample, canChangeLibrary, let snapshot = completeLibrary,
              let item = snapshot.items.first(where: { $0.documentID == paper.id && $0.visible }),
              let commands = libraryCommandCoordinator else { return "Tags can be changed once your library is up to date." }
        let edit = PaperTags.edit(catalog: item.tags ?? [], desired: desired)
        guard edit.own.count <= PaperTags.maximumOwnTags else { return "A paper can have up to \(PaperTags.maximumOwnTags) tags of your own." }
        let scope = sessionID
        do {
            try await commands.editTags(documentID: item.documentID, tags: edit.own, hiddenTags: edit.hidden,
                                        observedRevision: item.membershipRevision, display: String(paper.title.unicodeScalars.prefix(200)),
                                        observedIn: snapshot.observation.readContext)
            return nil
        } catch LibraryCommandError.targetBusy {
            return "This paper has another change waiting to sync. Try again in a moment."
        } catch {
            guard sessionID == scope, !(error is CancellationError) else { return nil }
            return (error as? LocalizedError)?.errorDescription ?? "Your tags couldn’t be saved. Try again."
        }
    }

    private func editSourceDetails(_ paper: Paper, archived: Bool, tags: [String]) async -> String? {
        guard canChangeLibrary, let snapshot = completeLibrary, let commands = libraryCommandCoordinator,
              let item = snapshot.imports.first(where: { $0.id == paper.sourceMembership?.membershipID && $0.visible }) else { return "Refresh your library and try again." }
        do {
            _ = try await commands.enqueue(.setSourceDetails(importID: item.id, archived: archived, tags: tags, expectedRevision: item.intentRevision),
                display: String(paper.title.prefix(200)), observedIn: snapshot.observation.readContext)
            return nil
        } catch { return "This change couldn’t be saved. Let other changes finish, then try again." }
    }

    private func editLocalPDF(_ paper: Paper, remove: Bool = false, archived: Bool? = nil, tags: [String]? = nil) async {
        guard let device, let store, let prior = privateState.revisions(for: paper.id).first,
              var membership = try? LocalPDFMembership.decode(prior.payload) else { return }
        let scope = sessionID, persistence = localPersistence
        if let archived { membership.archived = archived }
        if let tags { membership.tags = tags }
        do {
            let event = PrivateEvent(kind: remove ? .tombstone : .localPaper, entityID: paper.id, parents: [prior.id],
                text: remove ? nil : try membership.text(), createdAt: PrivateEvent.timestamp(Date()))
            _ = try await persistence.acceptWrite { try await $0.appendBatch([(id: UUID(), event: event)], deviceID: device.deviceID) }.value
            if remove, let record = localPaperRecords.first(where: { $0.identity.sourceID == paper.sourceID }) {
                _ = try await persistence.acceptLocalPaperWrite { try await $0.remove(record.identity) }.value
            }
            let snapshot = await store.snapshot()
            guard sessionID == scope else { return }
            publish(snapshot); await refreshLocalPaperRecords(); await synchronize()
        } catch { if sessionID == scope { show(error) } }
    }

    /// Retry and Remove on an import can run (the row's buttons and menu).
    var canChangeImports: Bool {
        #if DEBUG && FIXTURE_HOST
        if fixtureImportChanges { return true }
        #endif
        return canChangeLibrary
    }

    func changeImport(_ item: LibraryImportRecord, retry: Bool) async {
        #if DEBUG && FIXTURE_HOST
        if fixtureImportChanges {
            // Fixture runs only (no account or server): a retry shows as running again; Remove takes the row away.
            guard !retry || (item.phase == .failed && item.retryable) else { return }
            if retry { fixtureRetriedImports.insert(item.id) } else { libraryImports.removeAll { $0.id == item.id } }
            return
        }
        #endif
        guard canChangeLibrary, let commands = libraryCommandCoordinator, let snapshot = completeLibrary,
              snapshot.imports.contains(where: { $0.id == item.id && $0.intentRevision == item.intentRevision }),
              !retry || (item.phase == .failed && item.retryable) else { return }
        let scope = sessionID
        let mutation: LibraryMutation = retry ? .retryImport(importID: item.id, expectedRevision: item.intentRevision)
            : .cancelImport(importID: item.id, expectedRevision: item.intentRevision)
        do { _ = try await commands.enqueue(mutation, display: String((item.metadata?.title ?? LibrarySource.placeholderTitle(sourceID: item.sourceID)).unicodeScalars.prefix(200)),
                                            observedIn: snapshot.observation.readContext) }
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
        do { service = try await scopedLibraryService(accountID: accountID, scope: scope) }
        catch {
            guard sessionID == scope, self.accountID == accountID, !(error is CancellationError) else { return }
            libraryIssue = "Your saved library is preserved. Unlock this device’s library before refreshing."
            return
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

    private func scopedLibraryService(accountID: UUID, scope: UUID) async throws -> LibraryService {
        guard sessionID == scope, self.accountID == accountID, let backend, let configuration
        else { throw ReaderError.storageUnavailable }
        if let existing = libraryService, libraryContextAuthenticated || store == nil { return existing }
        guard let store else {
            let provisional = LibraryService(scope: .init(accountID: accountID, readerSessionID: scope), transport: backend)
            libraryService = provisional
            return provisional
        }
        let cacheScope = try LibraryCommandScope(accountID: accountID, deploymentID: configuration.url.absoluteString)
        // Read the authenticated root separately. A corrupt child is not proof
        // that this account/deployment has never adopted the upload protocol.
        let context = try await store.rememberedLibraryReadContext(scope: cacheScope)
        let seed: LibraryReplicaSeed?
        do { seed = try await store.cachedLibraryReplicaSeed(scope: cacheScope) }
        catch let error as OfflineCacheError where error == .corruptCache {
            seed = nil
            offlineCacheIssue = "Your saved library couldn’t be opened. Your saved data has been preserved."
        }
        guard sessionID == scope, self.accountID == accountID, self.store === store else { throw CancellationError() }
        if let existing = libraryService {
            let legacy = await existing.permitsLegacyCommands()
            let requiresReplacement = context?.permitsUploads == true && legacy
            guard sessionID == scope, self.accountID == accountID, self.store === store else { throw CancellationError() }
            if !requiresReplacement { libraryContextAuthenticated = true; return existing }
            // The old callback may ignore cancellation. Identity checks on
            // publication reject it after replacement; no legacy observation
            // reaches the newly authenticated v5 cache or command queue.
            libraryService = nil
            await existing.invalidate()
            completeLibrary = nil; deferredLibraryObservation = nil; libraryPublicationGeneration = 0
            libraryRefreshAttempt = nil; libraryRefreshing = false
        }
        let created = LibraryService(scope: .init(accountID: accountID, readerSessionID: scope), transport: backend,
            rememberedContext: context, resume: seed)
        libraryService = created; libraryContextAuthenticated = true
        return created
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
            catch { offlineCacheIssue = ReaderBundleCoordinator.cacheFailureMessage }
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
            } catch { offlineCacheIssue = ReaderBundleCoordinator.cacheFailureMessage }
        }
        deferredLibraryObservation = nil
        libraryPublicationDeferred = false
    }

    private func presentLibraryEntries(_ entries: [LibraryEntry]) {
        #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && FIXTURE_HOST
        // Live publication still includes native metadata mapping. Offline
        // projection does that within its separate measured cache-read phase.
        OfflineResourceProbe.shared.begin(.publication)
        defer { OfflineResourceProbe.shared.finish(.publication, count: entries.count) }
        #endif
        applyLibraryProjection(entries.compactMap(LibraryPresentationRow.project))
    }

    private func presentLibraryProjection(_ rows: [LibraryPresentationRow], validatedEntryCount: Int) {
        #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && FIXTURE_HOST
        // Format 4: final MainActor application only. Author joining and cache
        // validation are included in restoreProjectionElapsedMS and restore.
        OfflineResourceProbe.shared.begin(.publication)
        defer { OfflineResourceProbe.shared.finish(.publication, count: validatedEntryCount) }
        #endif
        applyLibraryProjection(rows)
    }

    private func applyLibraryProjection(_ rows: [LibraryPresentationRow]) {
        let previous = Dictionary(papers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tagEdits = pendingTagEdits
        let items = rows.compactMap { if case .item(let item) = $0 { return item }; return nil }
        var next = items.map { item in
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
            var row = paper
            row.fileURL = file; row.readerBundle = file == nil ? nil : cached?.readerBundle
            return Self.withTagEdit(row, tagEdits[row.id])
        }
        let sourceRows = rows.compactMap { row -> LibraryImportRecord? in
            if case .imported(_, let item) = row, let item, item.visible, item.phase == .sourceOnly,
               item.source == "arxiv", item.sourceRevision != nil, item.metadata != nil { return item }
            return nil
        }
        for item in sourceRows {
            guard let sourceID = item.sourceID, let revision = item.sourceRevision,
                  let ref = try? SourcePaperReference(membershipID: item.id, sourceID: sourceID, revision: revision) else { continue }
            let cached = previous[item.id]?.sourceMembership == ref ? previous[item.id]?.readerBundle : nil
            let paper = Paper(id: item.id, title: item.metadata?.title ?? "Untitled paper",
                authors: item.metadata?.authors.joined(separator: ", ") ?? "", year: item.metadata?.publishedAt.flatMap { Int($0.prefix(4)) },
                abstract: item.metadata?.abstract ?? "", keywords: item.metadata?.categories ?? [], artifactID: nil,
                sourceID: sourceID, sourceRevision: revision, readerBundle: cached, sourceMembership: ref,
                authorNames: item.metadata?.authors ?? [], canReadStructured: true, archived: item.archived ?? false, venue: item.metadata?.venue, tags: item.userTags ?? [], ownTags: item.userTags ?? [], sourceURL: item.sourceURL)
            next.append(Self.withTagEdit(paper.displaying(cached), tagEdits[paper.id]))
        }
        let samples = papers.filter { candidate in candidate.isSample && !next.contains(where: { $0.id == candidate.id }) }
        // Samples have no server membership. Preserve the local sample
        // without letting it replace a real document-backed item.
        papers = next + samples
        presentLocalPDFMemberships()
        presentedImportIDs = Set(rows.compactMap { if case .imported(let id, _) = $0 { return id }; return nil })
        libraryImports = rows.compactMap { if case .imported(_, let item) = $0, !sourceRows.contains(where: { $0.id == item?.id }) { return item }; return nil }
        libraryCreationSequences = Dictionary(uniqueKeysWithValues: items.map { ($0.paper.id, $0.createdSequence) })
        for item in sourceRows { libraryCreationSequences[item.id] = item.createdSequence }
        libraryHasSnapshot = true
        prefetchReaders()
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
        if current.isLocalPDF {
            guard let sourceID = current.sourceID else { return }
            if localPaperRecords.contains(where: { $0.identity.sourceID == sourceID }) {
                openLocalPDF(sourceID: sourceID, revision: 1, title: current.title)
            } else { uploads.pickRequest = .init(target: .localPaper(current.id), title: current.title) }
            return
        }
        selectedPaper = current; chatPaperID = current.id; tab = .paper
        if wideMode != .browse { wideMode = .reader }
        generalChat = false
        recordOpened(current)
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
        #if DEBUG && FIXTURE_HOST
        if let status = fixtureOfflineStatus[paper.id] { return status }
        #endif
        if paper.isSample { return paper.readerBundle == nil ? .none : .available }
        if let source = paper.sourceMembership {
            return localReaderRecords.contains { $0.identity.sourceID == source.sourceID && $0.identity.revision == source.revision } ? .available : .none
        }
        guard accountID != nil, let coordinator = readerBundles,
              let installation = coordinator.installation(documentID: paper.id, artifactID: paper.artifactID) else { return .none }
        return coordinator.permits(installation) ? .available : .unavailable
    }

    func retryOpeningSelectedPaper() { openLocalPaperIfNeeded() }

    private func openLocalPaperIfNeeded() {
        if let paper = selectedPaper, paper.sourceMembership != nil { openHTMLReader(paper); return }
        localReaderTask?.cancel(); localReaderTask = nil; localReaderOpeningID = nil
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
            #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && FIXTURE_HOST
            OfflineResourceProbe.shared.begin(.open)
            #endif
            let openStarted = ProcessInfo.processInfo.systemUptime
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
                    SessionTimeline.shared.record("bundle", ["step": "open", "ms": String(Int((ProcessInfo.processInfo.systemUptime - openStarted) * 1000))])
                    guard self.sessionID == scope, self.readerBundles === coordinator, self.readerOpenAttempt == attempt,
                          let current = self.selectedPaper, current.id == paper.id, current.artifactID == paper.artifactID,
                          coordinator.permits(result.installation) else { return }
                    let displayed = current.displaying(result.bundle)
                    self.papers = self.papers.map { $0.id == displayed.id ? displayed : $0 }
                    self.selectedPaper = displayed
                    #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && FIXTURE_HOST
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

    /// Opening a metadata membership prepares its exact official HTML on this
    /// device, or reopens the authenticated local copy while offline.
    private func openHTMLReader(_ paper: Paper) {
        guard let ref = paper.sourceMembership else { return }
        if paper.readerBundle != nil { return }
        if localReaderOpeningID == paper.id { return }
        localReaderTask?.cancel()
        guard !workOwnership.isActivating, !libraryPublicationDeferred, let store = localPersistence.localReaderStore else { return }
        let scope = sessionID, persistence = localPersistence
        localReaderOpeningID = paper.id; openingPaperID = paper.id; readerOpenIssue = nil
        localReaderTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.sessionID == scope, self.localReaderOpeningID == paper.id {
                    self.localReaderOpeningID = nil; self.localReaderTask = nil; self.openingPaperID = nil
                }
            }
            do {
                let bundle: VerifiedReaderBundle
                if let record = await store.record(sourceID: ref.sourceID, revision: ref.revision) {
                    let reopened = try await store.read(record.identity)
                    bundle = try await Task.detached(priority: .userInitiated) { try ReaderBundleLoader.admitImages(in: reopened) }.value
                } else {
                    bundle = try await ArxivHTMLReader().prepare(ref.arxivSource)
                    try Task.checkCancellation()
                    guard self.sessionID == scope, self.papers.contains(where: { $0.sourceMembership == ref }) else { throw CancellationError() }
                    let commit = try persistence.acceptLocalReaderWrite { try await $0.install(bundle: bundle) }
                    _ = try await commit.value
                }
                try Task.checkCancellation()
                guard self.sessionID == scope, self.selectedPaper?.sourceMembership == ref else { return }
                self.localReaderRecords = await store.records()
                guard self.sessionID == scope, self.selectedPaper?.sourceMembership == ref else { return }
                let displayed = paper.displaying(bundle)
                self.papers = self.papers.map { $0.id == paper.id ? displayed : $0 }
                self.selectedPaper = displayed
            } catch {
                guard self.sessionID == scope, self.localReaderOpeningID == paper.id, !(error is CancellationError) else { return }
                self.readerOpenIssue = (error as? ArxivHTMLError)?.message ?? "This paper couldn’t be prepared on this device. Try again, or open its PDF."
            }
        }
    }

    /// A converted paper without a local copy downloads when opened (if the
    /// background prefetch hasn't already fetched it). Every member is verified
    /// against the server-authorized manifest digest by the encrypted installer;
    /// then the normal open path runs.
    private func downloadReaderIfNeeded(_ paper: Paper, coordinator: ReaderBundleCoordinator) {
        if readerDownloadAttempt?.documentID == paper.id { openingPaperID = paper.id; return }
        guard libraryContextAuthenticated, backend != nil, accountID != nil, let artifactID = paper.artifactID,
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
                try await self.downloadReader(paper, coordinator: coordinator)
                guard self.sessionID == scope, self.readerDownloadAttempt?.id == attempt else { return }
                self.readerDownloadAttempt = nil
                if self.openingPaperID == paper.id { self.openingPaperID = nil }
                if self.selectedPaper?.id == paper.id { self.openLocalPaperIfNeeded() }
            } catch {
                guard self.sessionID == scope, self.readerDownloadAttempt?.id == attempt, !(error is CancellationError) else { return }
                self.readerOpenIssue = (error as? BackendError)?.readerDeliveryMessage
                    ?? "This paper couldn’t be downloaded. Check your connection and try again."
            }
        }
    }

    /// Downloads and installs one converted paper; concurrent requests for the
    /// same paper (an open during a prefetch) share one download.
    private func downloadReader(_ paper: Paper, coordinator: ReaderBundleCoordinator) async throws {
        if let running = readerDownloads[paper.id] { return try await running.value }
        guard libraryContextAuthenticated, let backend, let accountID, let artifactID = paper.artifactID,
              let item = completeLibrary?.items.first(where: { $0.documentID == paper.id && $0.visible }), item.canReadStructured,
              item.artifactID == artifactID else { throw ReaderError.corruptData }
        let scope = sessionID
        let task = Task { @MainActor [weak self] () throws -> Void in
            let descriptor = try await backend.readerArtifact(itemID: item.id, accountID: accountID)
            guard descriptor.documentID == paper.id, descriptor.artifactID == artifactID else { throw ReaderError.corruptData }
            // Four members at a time (they were fetched one by one: ~0.4–1 s each).
            let members = try await withThrowingTaskGroup(of: (String, Data).self) { group in
                var fetched: [String: Data] = [:], queue = descriptor.members[...]
                func next() { if let member = queue.popFirst() { group.addTask { (member.path, try await backend.readerMember(member, accountID: accountID)) } } }
                for _ in 0..<4 { next() }
                while let (path, data) = try await group.next() { fetched[path] = data; next() }
                return fetched
            }
            guard let self, self.sessionID == scope, self.readerBundles === coordinator else { throw CancellationError() }
            let binding = try ReaderArtifactBinding(scope: coordinator.scope, documentID: paper.id, artifactID: artifactID,
                                                    manifestSHA256: descriptor.manifestSHA256)
            let installStarted = ProcessInfo.processInfo.systemUptime
            _ = try await coordinator.install(binding: binding, manifestData: descriptor.manifestData, members: members).value
            SessionTimeline.shared.record("bundle", ["step": "install", "ms": String(Int((ProcessInfo.processInfo.systemUptime - installStarted) * 1000))])
        }
        readerDownloads[paper.id] = task
        defer { if sessionID == scope { readerDownloads[paper.id] = nil } }
        try await task.value
    }

    /// Converted papers download in the background, newest first, so opening one
    /// is local (owner feedback 2026-10-05: opening should be instant).
    private func prefetchReaders() {
        guard libraryContextAuthenticated, readerPrefetch == nil, let coordinator = readerBundles, let library = completeLibrary, accountID != nil,
              !workOwnership.isActivating, !libraryPublicationDeferred else { return }
        let scope = sessionID
        let pending = library.items.filter { $0.visible && $0.canReadStructured }
            .sorted { $0.createdSequence > $1.createdSequence }
            .compactMap { item in papers.first { $0.id == item.documentID && $0.artifactID == item.artifactID && !$0.isSample } }
            .filter { coordinator.installation(documentID: $0.id, artifactID: $0.artifactID) == nil }
            .prefix(Self.prefetchLimit)
        guard !pending.isEmpty else { return }
        readerPrefetch = Task { [weak self] in
            for paper in pending {
                guard let self, !Task.isCancelled, self.sessionID == scope, self.readerBundles === coordinator else { return }
                SessionTimeline.shared.record("bundle", ["step": "prefetch", "paper": String(paper.id.uuidString.prefix(8))])
                try? await self.downloadReader(paper, coordinator: coordinator)
            }
            guard let self, self.sessionID == scope else { return }
            self.readerPrefetch = nil
        }
    }
    static let prefetchLimit = 12

    func askAboutSelectedPaper() {
        guard let selectedPaper else { return }
        chatPaperID = selectedPaper.id; generalChat = false; tab = .chat; wideMode = .reader; readerChatHidden = false
    }

    func openConversation(_ id: UUID) {
        guard let event = privateState.revisions(for: id).first, event.payload.kind == .conversation else { return }
        if let documentID = event.payload.documentID {
            chatPaperID = documentID; selectedPaper = papers.first { $0.id == documentID }; generalChat = false; wideMode = .reader
            readerChatHidden = false
            openLocalPaperIfNeeded()
        } else { generalChat = true; wideMode = .chat }
        activeConversation = id; tab = .chat
    }

    /// Deleting needs this account's encrypted history on the device (not the signed-out sample or a fixture).
    var canDeleteConversations: Bool { store != nil && device != nil && !workOwnership.isActivating }

    /// Deletes a saved conversation everywhere: a durable tombstone in the encrypted history, which hides it (and its
    /// diagrams) on every device once synced and blocks continuing it. Its unsent follow-up text stays recoverable
    /// as a draft. The encrypted records remain until account deletion; the service never could read them.
    func deleteConversation(_ id: UUID) async {
        guard privateState.revisions(for: id).first?.payload.kind == .conversation,
              let store, let device, accountID == device.accountID, !workOwnership.isActivating else { return }
        let scope = sessionID, storeScope = workOwnership.storeScope, persistence = localPersistence, deviceID = device.deviceID
        // The visible chat moves to a new one in the same context rather than showing a deleted conversation.
        if activeConversation == id { newChat(general: generalChat) }
        do {
            let entry = [(id: UUID(), event: PrivateEvent(kind: .tombstone, entityID: id, createdAt: PrivateEvent.timestamp(Date())))]
            let write = try persistence.acceptWrite { local in try await local.appendBatch(entry, deviceID: deviceID) }
            _ = try await write.value
            let snapshot = await store.snapshot()
            guard sessionID == scope else { return }
            if workOwnership.owns(storeScope) { publish(snapshot) }
            Task { if self.sessionID == scope { await self.synchronize() } }
        } catch {
            if sessionID == scope, workOwnership.owns(storeScope) { show(error) }
        }
    }

    func openUnsentDraft(_ id: UUID) {
        guard let draft = unsentDrafts.first(where: { $0.id == id }) else { return }
        let documentID = draft.context.hasPrefix("paper/") ? UUID(uuidString: String(draft.context.dropFirst(6))) : nil
        guard draft.context == "general" || documentID != nil, chatWorkspace.selectDraft(id) != nil else { return }
        if let documentID {
            chatPaperID = documentID; selectedPaper = papers.first { $0.id == documentID }
            generalChat = false; wideMode = .reader; readerChatHidden = false
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
        let paper = Paper(id: UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!, title: "Reading machine learning papers", authors: "Gradstep · offline sample", year: 2026,
            abstract: "A local reading fixture with equations, a wide table, figure, and references. It demonstrates the reader without uploading a paper or using credits.",
            keywords: ["attention", "optimization", "evaluation"], fileURL: bundle.entryURL,
            artifactID: UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000002"), isSample: true, readerBundle: bundle)
        if !papers.contains(where: { $0.id == paper.id }) { papers.append(paper) }
        select(paper)
    }

    /// The result of "Add to library" on a reference, shown over the reader.
    struct ReferenceNotice: Equatable, Identifiable {
        enum Kind: Equatable { case working, added, present, closed, notFound, unavailable }
        let id = UUID()
        let kind: Kind
        let message: String
        let reference: String
        /// The library source the server matched (added or already present), if any.
        var sourceID: String? = nil
    }
    var referenceNotice: ReferenceNotice?

    /// Adds the paper a bibliography entry cites, without a chat: the server identifies it and
    /// queues it like the Library's Add. When it can't, the notice offers "Ask in chat".
    func addReference(_ text: String) async {
        guard isSignedIn, backend != nil, accountID != nil else { openSignIn(); return }
        let scope = sessionID
        referenceNotice = ReferenceNotice(kind: .working, message: "Adding to your library…", reference: text)
        guard let notice = await referenceOutcome(text), sessionID == scope, referenceNotice?.reference == text else { return }
        referenceNotice = notice
    }

    /// The `add-reference` call and its outcome, without presenting it (the reader shows a
    /// banner; "Papers in this answer" shows it on the row). Nil when signed out.
    func referenceOutcome(_ text: String) async -> ReferenceNotice? {
        guard let backend, let accountID else { return nil }
        do {
            let result = try await backend.addReference(text, accountID: accountID)
            let title = result.paper.map { "“\($0.title)”" } ?? "This paper"
            let source = result.paper?.source_id
            if result.status == "added" { Task { await refreshLibrary() } }
            switch result.status {
            case "added": return .init(kind: .added, message: "Added \(title). It’s being prepared to read.", reference: text, sourceID: source)
            case "present": return .init(kind: .present, message: "\(title) is already in your library.", reference: text, sourceID: source)
            case "closed": return .init(kind: .closed, message: "\(title) isn’t openly available, so it can’t be added.", reference: text)
            case "not_found": return .init(kind: .notFound, message: "Couldn’t identify this reference.", reference: text)
            case "needs_update": return .init(kind: .closed, message: "\(title) needs the latest version of Gradstep.", reference: text)
            default: return .init(kind: .unavailable, message: "Couldn’t add it right now.", reference: text)
            }
        } catch {
            return .init(kind: .unavailable, message: "Couldn’t add it right now.", reference: text)
        }
    }

    // MARK: Add by any identifier or link, and PDF uploads (docs/architecture/PDF_UPLOADS.md)

    /// PDFs on their way to the library (picked, dropped, shared or downloaded on this device).
    let uploads = PDFUploadCenter()

    /// Starts this account's upload queue once its library is ready; unsent uploads resume.
    func activateUploads() {
        guard let service = addingService, let accountID, let configuration else { return }
        let scope = sessionID
        uploads.activate(.init(service: service, accountID: accountID, deploymentID: configuration.url.absoluteString,
            cursor: { [weak self] in
                guard let self, self.sessionID == scope else { return nil }
                return self.completeLibrary?.committedCursor
            },
            added: { [weak self] in Task { await self?.refreshLibrary() } },
            installLocal: { [weak self] file, checked, target in
                guard let self, self.sessionID == scope else { throw CancellationError() }
                try await self.installLocalPDF(file, checked: checked, target: target)
            }))
        importSharedItems()
    }

    private func installLocalPDF(_ file: URL, checked: CheckedPDF, target: PDFUploadTarget) async throws {
        guard let device, let store else { throw ReaderError.storageUnavailable }
        let scope = sessionID, id = UUID(), persistence = localPersistence
        if case .localPaper(let paperID) = target {
            guard let paper = papers.first(where: { $0.id == paperID && $0.isLocalPDF }),
                  let prior = privateState.revisions(for: paperID).first,
                  let membership = try? LocalPDFMembership.decode(prior.payload), membership.pageCount == checked.pages else { throw ReaderError.invalidEvent }
            _ = try await persistence.acceptLocalPaperWrite {
                try await $0.install(pdfAt: file, sourceID: LocalPDFMembership.sourceID(paperID), revision: 1, expectedSHA256: Data(hex: checked.sha256))
            }.value
            guard sessionID == scope else { throw CancellationError() }
            await refreshLocalPaperRecords()
            openLocalPDF(sourceID: LocalPDFMembership.sourceID(paperID), revision: 1, title: paper.title)
            return
        }
        if case .importID(let importID, _) = target {
            guard let item = completeLibrary?.imports.first(where: { $0.id == importID && $0.visible }),
                  let sourceID = item.sourceID, let revision = item.sourceRevision ?? item.requestedRevision else { throw ReaderError.invalidEvent }
            let write = try persistence.acceptLocalPaperWrite {
                try await $0.install(pdfAt: file, sourceID: sourceID, revision: revision, expectedSHA256: Data(hex: checked.sha256))
            }
            _ = try await write.value
            guard sessionID == scope else { return }
            await refreshLocalPaperRecords()
            return
        }
        let membership = try LocalPDFMembership(title: checked.title, pageCount: checked.pages, createdAt: PrivateEvent.timestamp(Date()))
        let write = try persistence.acceptLocalPaperWrite { local in
            try await local.install(pdfAt: file, sourceID: LocalPDFMembership.sourceID(id), revision: 1, expectedSHA256: Data(hex: checked.sha256))
        }
        let record = try await write.value
        guard sessionID == scope else { throw CancellationError() }
        do {
            let event = PrivateEvent(kind: .localPaper, entityID: id, text: try membership.text(), createdAt: membership.createdAt)
            let saved = try persistence.acceptWrite { try await $0.appendBatch([(id: UUID(), event: event)], deviceID: device.deviceID) }
            _ = try await saved.value
            guard sessionID == scope else { return }
            localPaperRecords = await persistence.localPaperStore?.records() ?? []
            let snapshot = await store.snapshot()
            guard sessionID == scope else { return }
            publish(snapshot)
            Task { if self.sessionID == scope { await self.synchronize() } }
        } catch {
            _ = try? persistence.acceptLocalPaperWrite { try await $0.remove(record.identity) }
            throw error
        }
    }

    private func presentLocalPDFMemberships() {
        var local: [Paper] = []
        let ids = Set(privateState.events.values.filter { $0.payload.kind == .localPaper }.map { $0.payload.entityID })
        for id in ids where !privateState.isDeleted(id) {
            guard let event = privateState.revisions(for: id).first?.payload,
                  let member = try? LocalPDFMembership.decode(event) else { continue }
            local.append(Paper(id: id, title: member.title, authors: "", year: nil, abstract: "", keywords: [], artifactID: nil,
                sourceID: LocalPDFMembership.sourceID(id), sourceRevision: 1, isLocalPDF: true,
                addedAt: Date(timeIntervalSince1970: Double(member.createdAt) / 1000), pageCount: member.pageCount,
                canReadStructured: false, archived: member.archived, tags: member.tags, ownTags: member.tags))
        }
        papers = papers.filter { !$0.isLocalPDF } + local
    }

    /// The Add sheet's network calls for the signed-in account (a script in UI fixtures).
    var addingService: (any PaperAddingService)? {
        #if DEBUG && FIXTURE_HOST
        if let fixture = AddPaperFixture.service { return fixture }
        #endif
        guard let backend, let accountID else { return nil }
        return BackendPaperAdding(backend: backend, accountID: accountID)
    }

    /// The Add sheet's lookup for anything but an arXiv ID: the server identifies it and queues it as
    /// this account's import, or says what to do next. Nil when signed out or after an account change.
    func addPaperOutcome(_ query: String) async -> AddOutcome? {
        guard let service = addingService else { return nil }
        let scope = sessionID
        do {
            let result = try await service.addPaper(query)
            guard sessionID == scope else { return nil }
            if result.status == "added" { Task { await refreshLibrary() } }
            return AddOutcome.from(result)
        } catch {
            return sessionID == scope && !(error is CancellationError) ? .unavailable : nil
        }
    }

    /// Actions on text or a formula in a chat answer (owner feedback 2026-10-07): Quote in Chat (was "Ask about this")
    /// quotes it into the composer; Explain and Define ask about it as a new question in this chat.
    enum ChatQuoteAction: CaseIterable {
        case ask, explain, define
        /// The edit menu's words (build 16 #4: "make it more clear that we have the option to … reference in the chat box").
        var menuTitle: String { switch self { case .ask: "Quote in Chat"; case .explain: "Explain"; case .define: "Define" } }
        var symbol: String { switch self { case .ask: "quote.bubble"; case .explain: "text.magnifyingglass"; case .define: "character.book.closed" } }
    }
    /// Changes when the composer should take focus (Quote in Chat, Discuss in chat).
    private(set) var chatComposerFocusRequest = UUID()
    /// A focus request no composer has taken yet: the Chat tab a request opens is created after it (iPhone), so it
    /// takes the request when it appears instead of seeing it change.
    @ObservationIgnored private var chatComposerFocusPending = false

    private func requestComposerFocus() {
        chatComposerFocusPending = true
        chatComposerFocusRequest = UUID()
    }

    /// True once per request, for the composer that takes the focus.
    func takeComposerFocusRequest() -> Bool {
        defer { chatComposerFocusPending = false }
        return chatComposerFocusPending
    }

    /// A bibliography entry's "Discuss in chat" (owner feedback, build 21): this paper's chat with the entry quoted in
    /// the message box as Quote in Chat does, the cursor after it, nothing sent. A conversation already under way
    /// keeps its own subject, so the entry starts a new one; an unsent message in a new chat follows the quote.
    func discussReference(_ text: String) {
        guard let paper = selectedPaper else { return }
        chatPaperID = paper.id; generalChat = false
        if activeConversation != nil { newChat(general: false) }
        tab = .chat; wideMode = .reader; readerChatHidden = false
        chatQuoteAction(.ask, quote: text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }

    func chatQuoteAction(_ action: ChatQuoteAction, quote raw: String) {
        let quote = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ChatGenerationRequest.maximumSelectionScalars))
        guard !quote.isEmpty else { return }
        let draft = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case .ask:
            // A reference the reader completes with their question; an existing draft follows it.
            chatInput = "About “\(quote)”: " + draft
            requestComposerFocus()
        case .explain, .define:
            // Explain is the reader's (an equation gets the equation prompt); Define is chat-only.
            let prompt = action == .explain ? SelectionAction.define.prompt(quote) : "Define the terms and symbols in: \(quote)"
            // Never overwrite a draft: with one, the question waits in the composer instead.
            guard draft.isEmpty else { chatInput = prompt + "\n\n" + draft; requestComposerFocus(); return }
            chatInput = prompt
            if !isSignedIn { openSignIn(); return }
            let scope = sessionID, composer = chatComposerID
            Task {
                guard sessionID == scope, chatComposerID == composer, chatInput == prompt else { return }
                await sendMessage()
            }
        }
    }

    func selectionAction(_ action: SelectionAction, quote: String, origin: PassageOrigin? = nil) {
        selectedQuote = quote
        // The chat's current model, effort and length go with the action into its new conversation.
        let carried = chatProfile
        // The prompts live with `ChatTitle`, which turns them back into short titles.
        newChat(general: false); chatInput = action.prompt(quote)
        if carried != chatDefaultProfile { setChatProfile(carried) }
        tab = .chat; wideMode = .reader; readerChatHidden = false
        // The quote (and the passage it came from, saved on the new conversation) travels with this exact prompt
        // and composer only.
        pendingSelection = chatComposerID.map { (composerID: $0, prompt: chatInput, quote: quote,
            action: action.chatAction, origin: origin) }
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
        selectionAction(action, quote: quote, origin: PassageOrigin(scope: scope, selection: selection, quote: quote))
    }

    func newChat(general: Bool) {
        guard general || canUsePaperChat else { return }
        generalChat = general; activeConversation = nil
        if !general { readerChatHidden = false }
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
        // The answer uses the model, effort and length the chat shows as Send is pressed.
        let chosenProfile = chatProfile
        let documentID = generalChat ? nil : (chatPaperID ?? selectedPaper?.id)
        var parents = activeBranchID.map { [$0] } ?? []
        if parents.isEmpty, let activeConversation, let root = privateState.revisions(for: activeConversation).first { parents = [root.id] }
        recordCurrentDraftBranch()
        guard let submission = chatWorkspace.beginSubmission(in: chatContext) else { return }
        let pending = pendingSelection.flatMap {
            $0.composerID == submission.composerID && $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines) == submission.text ? $0 : nil
        }
        let selection = pending?.quote
        if pendingSelection?.composerID == submission.composerID { pendingSelection = nil }
        // A remote user message is not a local scrolling action. Capture the
        // accepted submit gesture before saving, scoped to its own composer.
        chatFollowRequest = ChatFollowRequest(composerID: submission.composerID)
        let branchChoice = branchSelections.capture(in: submission.conversationID)
        do {
            guard let checkpoint = submission.checkpoint else { throw ReaderError.invalidEvent }
            var events: [(id: UUID, event: PrivateEvent)] = []
            // Encrypted with the event; All chats shows it as Started / Last used.
            let createdAt = PrivateEvent.timestamp(Date())
            if let root = submission.rootID {
                // A selection action's passage, for Go to passage and the paper's marks (encrypted with the event).
                let anchor = pending?.origin.flatMap { $0.documentID == documentID ? $0.anchor : nil }
                events.append((root, PrivateEvent(kind: .conversation, entityID: submission.conversationID, documentID: documentID,
                    text: String(submission.text.prefix(100)), anchor: anchor, createdAt: createdAt)))
                parents = [root]
            }
            events.append((submission.id, PrivateEvent(kind: .message, entityID: submission.id, parents: parents,
                conversationID: submission.conversationID, documentID: documentID, text: submission.text, role: .user, status: .complete,
                createdAt: createdAt)))
            let reference = documentID.flatMap { id in papers.first(where: { $0.id == id })?.sourceMembership }
            let batch = try events.map { entry in
                var event = entry.event
                if let reference { try event.bind(to: reference) }
                return (id: entry.id, event: event)
            }
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
                    userMessageID: question, selection: selection, action: pending?.action, profile: chosenProfile, paperReference: reference), state: snapshot.state)
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
    /// Checks a diagram's Mermaid source before it is kept (tests substitute their own).
    @ObservationIgnored var diagramCheck: @MainActor (String) async -> MermaidCheck.Result = { await MermaidCheck.check($0) }
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
    /// What the server is doing for the visible answer (searching, adding a paper) until text resumes.
    var chatStreamingProgress: ChatProgress? { visibleGeneration.flatMap { chatStreamProgress[$0.id] } }
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
        if let reference = turn.paperReference,
           let paper = papers.first(where: { $0.sourceMembership == reference }), paper.readerBundle == nil {
            if selectedPaper?.id == paper.id { openHTMLReader(paper) }
            let preparation = localReaderTask
            Task { [weak self] in
                await preparation?.value
                guard let self, self.sessionID == turn.sessionID, self.chatGenerations[turn.composerID] == nil else { return }
                self.startGeneration(turn, transport: transport, state: state ?? self.privateState)
            }
        } else { startGeneration(turn, transport: transport, state: state ?? privateState) }
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
            chatAnswerIssues[turn.composerID] = ChatAnswerIssue(turn: turn, code: turn.paperReference != nil ? "local_reader_unavailable" : "invalid_request")
            return
        }
        let transcript = branch.messages.compactMap { message -> ChatTurnInput? in
            guard let role = message.payload.role, let text = message.payload.text else { return nil }
            return ChatTurnInput(role: role, text: text)
        }
        let request: ChatGenerationRequest
        let choices = requestChoices(for: turn, branch: branch.messages, state: state)
        do {
            let localContext: LocalPaperChatContext?
            if let reference = turn.paperReference {
                guard let bundle = papers.first(where: { $0.sourceMembership == reference })?.readerBundle else {
                    throw ChatTransportError.rejected("local_reader_unavailable")
                }
                localContext = try LocalPaperChatContext(reference: reference, bundle: bundle)
            } else { localContext = nil }
            request = try ChatGenerationRequest.make(operationID: UUID(), documentID: turn.documentID, transcript: transcript, selection: turn.selection,
                                                     action: turn.action, profile: choices.profile, topicTitle: choices.topicTitle, localContext: localContext)
        } catch {
            chatAnswerIssues[turn.composerID] = ChatAnswerIssue(turn: turn, code: turn.paperReference != nil ? "local_reader_unavailable" : "invalid_request")
            return
        }
        var generation = ChatGeneration(turn: turn)
        generation.profile = choices.profile; generation.sentProfile = choices.sent
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
        var text = "", outcome: ChatGenerationOutcome?, diagram: (title: String, source: String)?
        var title: String?, answered: (model: String?, profile: String?) = (nil, nil)
        // The consumer holds the only stream reference, so leaving it (a final
        // event, lost ownership or an error) releases the stream and cancels
        // the HTTP request before any local sealing work begins.
        func consume(_ stream: AsyncThrowingStream<ChatStreamEvent, Error>) async throws -> Bool {
            for try await event in stream {
                guard ownsGeneration(generation) else { return false }
                switch event {
                case .delta(let piece):
                    text += piece
                    // Text resumed: the server's status line has done its job.
                    if piece.contains(where: { !$0.isWhitespace }) { chatStreamProgress[generation.id] = nil }
                    bufferAnswer(generation, text: text)
                case .status(let progress): chatStreamProgress[generation.id] = progress
                case .diagram(let title, let source): diagram = (title, source)
                case .title(let topic): title = topic
                case .done(let stopReason, _, let model, let profile):
                    outcome = .completed(stopReason: stopReason); answered = (model, profile)
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
        // Only a diagram that will be kept (with a complete answer) is checked.
        if resolved.resolution(text: text).status == .complete, let drawn = diagram {
            diagram = await checkedDiagram(drawn, generation: generation, transport: transport)
            guard ownsGeneration(generation) else { return }
        }
        var labelled = generation
        labelled.answeredModel = answered.model; labelled.answeredProfile = answered.profile
        await finishGeneration(labelled, text: text, outcome: resolved, choice: choice, diagram: diagram, title: title)
    }

    /// Diagrams are checked with the bundled Mermaid before they are kept (2026-10-07). One that doesn't parse is sent
    /// back once for a corrected version: a separate, small metered request (`diagram_fix`, held and charged like any
    /// answer). A correction that is missing or still fails keeps the original, whose view then says it couldn't be drawn.
    private func checkedDiagram(_ drawn: (title: String, source: String), generation: ChatGeneration,
                                transport: any ChatTransport) async -> (title: String, source: String) {
        guard case .invalid(let error) = await diagramCheck(drawn.source), !Task.isCancelled, ownsGeneration(generation),
              let request = ChatGenerationRequest.diagramRepair(operationID: UUID(), title: drawn.title, source: drawn.source, error: error)
        else { return drawn }
        chatStreamProgress[generation.id] = ChatProgress(kind: .fixingDiagram)
        var fixed: String?
        var completed = false
        do {
            stream: for try await event in try await transport.chatStream(request, accountID: generation.turn.accountID) {
                guard ownsGeneration(generation) else { return drawn }
                switch event {
                case .diagram(_, let source): fixed = source
                case .done(let stopReason, _, _, _):
                    completed = stopReason == "end_turn" || stopReason == "stop_sequence"
                    break stream
                case .failure: break stream
                default: continue
                }
            }
        } catch { return drawn }
        // A diagram frame alone is not a successful correction: the stream can
        // fail, be truncated, or end before its final acknowledgement.
        guard completed, let fixed, ownsGeneration(generation), !Task.isCancelled,
              case .valid = await diagramCheck(fixed) else { return drawn }
        // The answer named its diagram; the correction only changes the source.
        return (drawn.title, fixed)
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
                                  choice: ConversationBranchSelections.Choice, diagram: (title: String, source: String)? = nil,
                                  title: String? = nil) async {
        let resolution = outcome.resolution(text: text)
        var issue = resolution.issue
        if let status = resolution.status {
            // Show exactly the sealed text before the row changes ownership.
            chatStreamingText[generation.id] = text
            // A diagram is kept only with a complete answer, in the same batch.
            let drawn = status == .complete ? diagram.flatMap { ChatDiagram(title: $0.title, source: $0.source, messageID: generation.assistantID) } : nil
            do {
                // A topic title is kept only with a complete answer, in the same batch.
                let kept = try await sealAnswer(generation, text: text, status: status, choice: choice, diagram: drawn,
                                                title: status == .complete ? title : nil)
                if drawn != nil, !kept, issue == nil { issue = "diagram_storage" }
            } catch { if issue == nil { issue = "storage" } }
        }
        guard ownsGeneration(generation) else { return }
        chatGenerations[generation.turn.composerID] = nil
        chatStreamingText[generation.id] = nil; chatStreamBuffer[generation.id] = nil; chatStreamProgress[generation.id] = nil
        if let issue { chatAnswerIssues[generation.turn.composerID] = ChatAnswerIssue(turn: generation.turn, code: issue) }
        let scope = sessionID, added = generation.turn.action == .ingest && resolution.status != nil
        Task {
            guard self.sessionID == scope else { return }
            await self.refreshCreditBalance()
            // Ingest may have queued an import on the server. A refresh already
            // in flight may predate it, so wait for that one and refresh again.
            guard added else { return }
            for _ in 0..<50 where self.libraryRefreshing { try? await Task.sleep(for: .milliseconds(200)) }
            if self.sessionID == scope, !self.libraryRefreshing { await self.refreshLibrary() }
        }
    }

    /// Returns whether the diagram (if any) was kept with the answer.
    @discardableResult
    private func sealAnswer(_ generation: ChatGeneration, text: String, status: PrivateEvent.TurnStatus,
                            choice: ConversationBranchSelections.Choice, diagram: ChatDiagram? = nil, title: String? = nil) async throws -> Bool {
        guard !privateState.isDeleted(generation.turn.conversationID) else { return true }
        let persistence = localPersistence, scope = sessionID
        await persistence.waitForActivation()
        guard ownsGeneration(generation), persistence === localPersistence, let store else { throw CancellationError() }
        let storeScope = workOwnership.storeScope
        let id = generation.assistantID, deviceID = generation.turn.deviceID
        let event = generation.event(text: text.boundedForPrivateEvent(), status: status, model: generation.answeredModel,
                                     profile: generation.labelProfile)
        var batch: [(id: UUID, event: PrivateEvent)] = [(id: id, event: event)]
        // The conversation's topic title, unless it got one meanwhile (a rename, or another device's title).
        if let title, privateState.revisions(for: generation.turn.conversationID).first?.payload.titleSource == nil,
           let titled = privateState.titledConversation(generation.turn.conversationID, title: title, source: PrivateEvent.generatedTitle) {
            batch.append((id: UUID(), event: titled))
        }
        if let diagram {
            let diagramID = UUID()
            batch.append((id: diagramID, event: PrivateEvent(kind: .diagram, entityID: diagramID, conversationID: generation.turn.conversationID,
                                                             documentID: generation.turn.documentID, text: diagram.encodedText(),
                                                             createdAt: generation.createdAt, paperReference: generation.turn.paperReference)))
        }
        let entries = batch
        let envelopes: [EventEnvelope]
        var keptDiagram = true
        do {
            let write = try persistence.acceptWrite { local in try await local.appendBatch(entries, deviceID: deviceID) }
            envelopes = try await write.value
        } catch ReaderError.localCapacityExceeded where entries.count > 1 {
            // Near the offline capacity limit the answer matters more than its diagram (or title).
            let answer = [(id: id, event: event)]
            let write = try persistence.acceptWrite { local in try await local.appendBatch(answer, deviceID: deviceID) }
            envelopes = try await write.value
            keptDiagram = false
        }
        let snapshot = await store.snapshot()
        guard sessionID == scope else { return keptDiagram }
        branchSelections.complete(choice, head: envelopes.first?.id)
        if workOwnership.owns(storeScope) { publish(snapshot) }
        branchSelections.reconcile(with: privateState, observing: generation.turn.conversationID)
        Task { if self.sessionID == scope { await self.synchronize() } }
        return keptDiagram
    }

    /// Account changes fence every answer. A non-empty partial is kept as an
    /// interrupted encrypted turn in the old account's store before it retires.
    private func retireChatGenerations() {
        let retiring = Array(chatGenerations.values), buffers = chatStreamBuffer
        chatGenerations = [:]; chatStreamingText = [:]; chatStreamBuffer = [:]; chatStreamFlushes = []; chatStreamProgress = [:]
        chatAnswerIssues = [:]; chatConsentPrompt = nil; pendingSelection = nil
        creditBalance = nil; creditBalanceIssue = nil
        storeSummary = nil; storeNotice = nil; lastStoreSyncResults = []; showStore = false; planOwnedElsewhere = false; storeOwnershipKnown = false
        storeRetry?.cancel(); storeRetry = nil; storeRetryAttempt = 0
        readerPrefetch?.cancel(); readerPrefetch = nil; readerDownloads = [:]
        for generation in retiring {
            generation.task?.cancel()
            guard let text = buffers[generation.id], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !privateState.isDeleted(generation.turn.conversationID) else { continue }
            let id = generation.assistantID, deviceID = generation.turn.deviceID
            let event = generation.event(text: text.boundedForPrivateEvent(), status: .interrupted, profile: generation.labelProfile)
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

    #if INTERNAL
    /// What a test-session reviewer needs to know about the visible state
    /// (docs/SESSION_REVIEW.md): screen, sheet, messages shown, activity. IDs are
    /// shortened; no paper or chat text.
    var sessionState: [String: String] {
        let sheet: String? = showSignIn ? "sign_in" : showRecovery ? "recovery" : chatConsentPrompt != nil ? "chat_consent"
            : showStore ? "store" : showImport ? "import" : showLibraryChanges ? "library_changes" : showAllChats ? "all_chats"
            : showDiagrams ? "diagrams" : presentedDiagram != nil ? "diagram" : showReport ? "report" : showReports ? "reports"
            : showImportHelp ? "import_help" : nil
        var state: [String: String] = ["tab": tab.rawValue, "signed_in": isSignedIn ? "1" : "0", "sync": syncStatus]
        if let sheet { state["sheet"] = sheet }
        if let paper = selectedPaper { state["paper"] = String(paper.id.uuidString.prefix(8)) }
        if let opening = openingPaperID { state["opening_paper"] = String(opening.uuidString.prefix(8)) }
        if chatStreamingMessageID != nil { state["answering"] = "1" }
        if isBusy { state["busy"] = "1" }
        if libraryRefreshing { state["library_refreshing"] = "1" }
        let active = libraryImports.filter { [.resolving, .acquiring].contains($0.phase) }.count
        if active > 0 { state["imports_active"] = String(active) }
        let failed = libraryImports.filter { $0.phase == .failed }.count
        if failed > 0 { state["imports_failed"] = String(failed) }
        // Messages the reader sees (app-authored text).
        if let error { state["error"] = error }
        if let issue = chatAnswerIssue { state["chat_issue"] = issue.code }
        if let issue = chatDraftIssue { state["chat_draft_issue"] = issue }
        if let issue = readerOpenIssue { state["reader_issue"] = issue }
        if let issue = libraryIssue { state["library_issue"] = issue }
        if let issue = offlineCacheIssue { state["offline_issue"] = issue }
        if let issue = creditBalanceIssue { state["credits_issue"] = issue }
        if let issue = accountPreparationIssue { state["account_issue"] = issue }
        if let notice = storeNotice { state["store_notice"] = notice }
        if !lastStoreSyncResults.isEmpty { state["store_results"] = lastStoreSyncResults.prefix(5).map(\.supportLine).joined(separator: "\n") }
        if let balance = creditBalance { state["credits"] = String(balance.available) }
        return state
    }
    #endif

    /// "Why does this take a minute?": what happens while a paper is being made readable.
    var showImportHelp = false

    // MARK: App Store purchases (docs/architecture/PURCHASES.md)

    var showStore = false
    private(set) var storeSummary: StoreSummary?
    /// This Apple Account's plan was bought by another (open) account: plans are
    /// not offered here, so a purchase can't land on the other account.
    private(set) var planOwnedElsewhere = false
    /// Set once this session's first purchase sync has checked plan ownership.
    private(set) var storeOwnershipKnown = false
    var storeNotice: String?
    private(set) var lastStoreSyncResults: [StoreSyncResult] = []
    var purchaseSupportDiagnostics: String? {
        let unconfirmed = lastStoreSyncResults.filter { !$0.isFinal }.prefix(5)
        return unconfirmed.isEmpty ? nil : "Purchase verification\n" + unconfirmed.map(\.supportLine).joined(separator: "\n")
    }
    @ObservationIgnored private var storeUpdates: Task<Void, Never>?
    @ObservationIgnored private var readerPrefetch: Task<Void, Never>?
    @ObservationIgnored private var readerDownloads: [UUID: Task<Void, Error>] = [:]
    @ObservationIgnored private var storeRetry: Task<Void, Never>?
    @ObservationIgnored private var storeRetryAttempt = 0

    /// Binds every purchase to the signed-in account on Apple's side.
    var purchaseOptions: Set<Product.PurchaseOption> { accountID.map { [.appAccountToken($0)] } ?? [] }
    var canPurchase: Bool { isSignedIn && device != nil && backend != nil }

    /// Transactions StoreKit delivers outside a purchase sheet: renewals, Ask to
    /// Buy approvals, refunds, purchases on another device. Started at launch.
    func startStoreUpdates() {
        guard storeUpdates == nil else { return }
        storeUpdates = Task { [weak self] in
            for await update in StoreKit.Transaction.updates {
                guard let self, let pending = await self.pendingTransaction(update) else { continue }
                await self.reportStoreTransactions([pending])
            }
        }
    }

    /// Xcode StoreKit-testing purchases are local only: finished, never reported.
    private func pendingTransaction(_ item: VerificationResult<StoreKit.Transaction>) async -> PendingStoreTransaction? {
        if case .verified(let transaction) = item, transaction.environment == .xcode { await transaction.finish(); return nil }
        return PendingStoreTransaction(item)
    }

    /// Reports unfinished transactions (and, for a restore, the current ones);
    /// at sign-in, on returning to the foreground and on retries.
    func syncStoreTransactions(includeCurrent: Bool = false) async {
        guard canPurchase, let accountID else { return }
        var pending: [PendingStoreTransaction] = [], foreignPlan = false
        for await item in StoreKit.Transaction.unfinished { if let transaction = await pendingTransaction(item) { pending.append(transaction) } }
        for await item in StoreKit.Transaction.currentEntitlements {
            var foreign = false
            if case .verified(let transaction) = item, transaction.productType == .autoRenewable,
               let token = transaction.appAccountToken, token != accountID { foreign = true; foreignPlan = true }
            // A plan tagged to another account is reported too: if that account
            // was deleted, the server moves the plan here.
            if includeCurrent || foreign, let transaction = await pendingTransaction(item) { pending.append(transaction) }
        }
        if !pending.isEmpty { await reportStoreTransactions(pending) }
        else if self.accountID == accountID { lastStoreSyncResults = [] }
        await refreshStoreSummary()
        guard self.accountID == accountID else { return }
        // A deleted account's plan moves to this one when reported, so it shows here.
        planOwnedElsewhere = foreignPlan && storeSummary?.plan == nil
        storeOwnershipKnown = true
    }

    /// Unreported or unconfirmed transactions stay unfinished; when the server
    /// was unreachable they are retried with backoff during this session.
    @discardableResult
    private func reportStoreTransactions(_ pending: [PendingStoreTransaction]) async -> [StoreSyncResult]? {
        guard let backend, let accountID, device != nil else { return nil }
        let scope = sessionID
        let results = try? await StoreSync.report(pending, accountID: accountID, transport: backend)
        guard sessionID == scope else { return results }
        lastStoreSyncResults = Array((results ?? [StoreSyncResult(outcome: "verification_unavailable", credits: nil)]).prefix(StoreSync.batchSize))
        if results?.contains(where: \.isFinal) == true { await refreshCreditBalance(); await refreshStoreSummary() }
        if results == nil || results?.contains(where: { $0.outcome == "verification_unavailable" }) == true { scheduleStoreRetry() }
        else { storeRetryAttempt = 0 }
        return results
    }

    /// Backoff while the server can't confirm purchases; reset by a confirmed report.
    private func scheduleStoreRetry() {
        let delays: [Duration] = [.seconds(15), .seconds(60), .seconds(300), .seconds(900)]
        guard storeRetry == nil, storeRetryAttempt < delays.count else { return }
        let delay = delays[storeRetryAttempt], scope = sessionID
        storeRetryAttempt += 1
        storeRetry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.sessionID == scope else { return }
            self.storeRetry = nil
            await self.syncStoreTransactions() // A further failure schedules the next attempt.
        }
    }

    func completePurchase(_ result: Product.PurchaseResult) async {
        switch result {
        case .success(let verification):
            if case .verified(let transaction) = verification, transaction.environment == .xcode {
                await transaction.finish(); storeNotice = "This was an Xcode test purchase; it isn’t sent to the server."; return
            }
            guard let pending = PendingStoreTransaction(verification) else {
                storeNotice = "The App Store couldn’t verify this purchase, so no credits were added. If you were charged, send a report."
                return
            }
            storeNotice = StoreSync.message(for: await reportStoreTransactions([pending])?.first)
        case .pending: storeNotice = "Your purchase is waiting for approval. Credits are added once it’s approved."
        case .userCancelled: break
        @unknown default: break
        }
    }

    func restorePurchases() async {
        do { try await AppStore.sync() } catch { storeNotice = "Couldn’t reach the App Store. Try again later."; return }
        await syncStoreTransactions(includeCurrent: true)
        if planOwnedElsewhere { storeNotice = "The plan on this Apple Account belongs to another account. Sign in to that account to use it." }
        else if let unconfirmed = lastStoreSyncResults.first(where: { !$0.isFinal }) { storeNotice = StoreSync.message(for: unconfirmed) }
        else { storeNotice = storeSummary?.planName.map { "Your \($0) plan is active." } ?? "No active plan was found for this Apple Account." }
    }

    func refreshStoreSummary() async {
        guard let backend, let accountID, device != nil else { return }
        let scope = sessionID
        guard let summary = try? await backend.storeSummary(accountID: accountID), sessionID == scope, self.accountID == accountID else { return }
        storeSummary = summary
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

    #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && FIXTURE_HOST
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

    #if DEBUG && FIXTURE_HOST
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
        // Visual checks without UI automation (docs/VISUAL_CHECK.md): open the fixture paper, and Edit tags over it.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--visual-open-paper"), let paper = papers.first(where: { $0.id == OfflineReaderFixture.document }) {
            select(paper)
            if arguments.contains("--visual-edit-tags") { editTags(for: paper) }
        }
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
        accountID = fixtureAccount; email = "draft-fixture@example.invalid"; signInProviders = ["apple"]; device = fixtureDevice
        let activation = workOwnership.beginActivation()
        defer { workOwnership.finishActivation(activation) }
        let local = try await localPersistence.activate(url: directory.appendingPathComponent("state.sqlite"),
            accountID: fixtureAccount, localKey: fixtureDevice.localStoreKey, keys: bundle)
        restoreReadingActivity(await localPersistence.readingStore?.load() ?? [])
        openSample()
        if let kind = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--chat-paper-navigation-fixture=") }) {
            try configureChatPaperNavigationFixture(pending: kind.hasSuffix("=pending"))
        }
        if Self.chatHistoryFixtureEnabled { try await installChatHistoryFixture(into: local, deviceID: fixtureDevice.deviceID) }
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
        presentLocalPDFMemberships()
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

#if DEBUG && FIXTURE_HOST
/// Synthetic UI fixtures only (compiled out of device and release builds).
extension ReaderModel {
    /// Fixture runs start from the default Library and Feed layouts unless an argument names one
    /// (`--library-layout=table`, `--feed-layout=table`), so one test's choice can't leak into the next run.
    func resetLibraryPreferencesForFixtures() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(where: { $0.hasPrefix("--") && $0.contains("fixture") }) else { return }
        func argument(_ prefix: String) -> String? { arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } }
        libraryLayout = argument("--library-layout=").flatMap(LibraryLayout.init(rawValue:)) ?? .list
        feedLayout = argument("--feed-layout=").flatMap(FeedLayout.init(rawValue:)) ?? .list
        // Default columns unless named (`--library-columns=year,tags,progress`, for both widths).
        var columns = LibraryColumnSettings()
        if let named = argument("--library-columns=") {
            let chosen = Set(named.split(separator: ",").compactMap { LibraryTableColumn(rawValue: String($0)) })
            columns.compact = chosen; columns.regular = chosen
        }
        libraryColumns = columns
        feedColumns = ColumnChoice(key: "feed.columns", compactDefault: FeedTableColumn.compactDefault,
                                   regularDefault: FeedTableColumn.regularDefault)
        chatColumns = ColumnChoice(key: "chats.columns", compactDefault: ChatTableLayout.compactDefault,
                                   regularDefault: ChatTableLayout.regularDefault)
        feedHidesLibrary = false
        feedTextStep = 0
        if let named = argument("--feed-columns=") {
            let chosen = Set(named.split(separator: ",").compactMap { FeedTableColumn(rawValue: String($0)) })
            feedColumns.compact = chosen; feedColumns.regular = chosen
        }
        if let named = argument("--chat-columns=") {
            let chosen = Set(named.split(separator: ",").compactMap { ChatHistoryField(rawValue: String($0)) })
            chatColumns.compact = chosen; chatColumns.regular = chosen
        }
        libraryFilter = argument("--library-filter=").flatMap(LibraryFilter.init(rawValue:)) ?? .all
        libraryTagFilter = argument("--library-tag=")
        // The iPad Reader's chat column: shown at its default width unless a test hides it or keeps the last run's.
        if !arguments.contains("--keep-reader-chat") { readerChatHidden = arguments.contains("--reader-chat-hidden"); readerChatWidth = nil }
        // Visual checks only: show the Add-paper sheet, which otherwise needs a signed-in account.
        if arguments.contains("--visual-show-import") { showImport = true }
    }

    /// Installs a varied synthetic library: papers with added dates, imports, offline states,
    /// and this device's reading activity. Chats come from the fixture's private state.
    /// Feed results without a network (visual checks).
    func installFeedFixture() {
        let json = """
        [{"source_id":"2610.01234","revision":1,"title":"Sparse Mixture-of-Experts Scaling Without Load-Balancing Losses","authors":["Mei Lin","Jonas Weber","Ana Costa","Rahul Iyer"],"year":2026,"abstract":"We show that expert routing with a learned temperature removes the need for auxiliary load-balancing losses while matching quality at three model scales.","categories":["cs.LG","cs.CL"]},
         {"source_id":"2610.02287","revision":2,"title":"Test-Time Training for Long-Context Language Models","authors":["Sara Okafor","Peter Lindqvist"],"year":2026,"abstract":"A lightweight inner loop adapts attention projections on the prompt itself, improving retrieval over 1M-token contexts.","categories":["cs.CL"]},
         {"source_id":"2610.03011","revision":1,"title":"Diffusion Policies with Consistency Distillation for Real-Robot Manipulation","authors":["Hiro Tanaka","Lena Fischer","Omar Haddad","Yuki Sato","Dana Cohen","Ivan Petrov","Maria Rossi","Tom Walsh","Ama Mensah"],"year":2026,"abstract":"Distilling a diffusion policy into a one-step consistency model keeps success rates while running at 50 Hz on hardware.","categories":["cs.RO","cs.LG"]},
         {"source_id":"2609.11890","revision":1,"title":"Calibrated Uncertainty for Reward Models","authors":["Priya Nair"],"year":2026,"abstract":null,"categories":["cs.LG","stat.ML"]},
         {"source_id":"2001.08361","revision":1,"title":"Scaling Laws for Neural Language Models","authors":["Jared Kaplan","Sam McCandlish"],"year":2020,"abstract":"An existing import is already part of the library.","categories":["cs.LG"]}]
        """
        feedResults = (try? JSONDecoder().decode([DiscoveryResult].self, from: Data(json.utf8))) ?? []
        Self.fixtureCategoryJSON = json
        if ProcessInfo.processInfo.arguments.contains("--feed-full-abstract-fixture") {
            let full = String(repeating: "We evaluate a compact policy across several model sizes and datasets, reporting accuracy, latency, and uncertainty. ", count: 8)
                + "The final limitation is that results have not been evaluated on physical robots."
            let row: [String: Any] = ["source_id": "2610.03011", "revision": 1,
                "title": "Diffusion Policies with Consistency Distillation for Real-Robot Manipulation Across Long-Horizon Tasks and Unseen Environments",
                "authors": ["Hiro Tanaka", "Lena Fischer"], "year": 2026, "categories": ["cs.RO", "cs.LG"],
                "abstract": String(full.prefix(700)), "full_abstract": full, "abstract_truncated": false]
            if let data = try? JSONSerialization.data(withJSONObject: row),
               let result = try? JSONDecoder().decode(DiscoveryResult.self, from: data) { feedResults = [result] }
        }
        feedCategory = feedCategories.first; feedState = .loaded
        if ProcessInfo.processInfo.arguments.contains("--feed-for-you-fixture") {
            feedPersonal = FeedPersonalization(available: true, topics: Self.fixtureFeedTopics)
            feedSelection = nil
            loadFeed()
        } else {
            feedPersonal = FeedPersonalization(available: false)
        }
    }

    /// The category fixture's rows (`installFeedFixture`), for More topics.
    nonisolated(unsafe) static var fixtureCategoryJSON = "[]"

    static let fixtureFeedTopics = [FeedTopic(name: "RL for reasoning", kind: "combined", papers: 41),
                                    FeedTopic(name: "Mechanistic interpretability", kind: "topic", papers: 12),
                                    FeedTopic(name: "Tokenization", kind: "topic", papers: 9),
                                    FeedTopic(name: "State space models", kind: "topic", papers: 7),
                                    FeedTopic(name: "byte-level LMs", kind: "own", papers: 3)]

    /// For you and topic responses for UI checks (`--feed-for-you-fixture`): synthetic papers with reasons, specific
    /// topics and upvotes (one unknown, shown as a dash). Categories keep the ordinary fixture.
    func fixtureFeedResponse(_ selection: FeedSelection) -> DiscoveryResponse? {
        guard ProcessInfo.processInfo.arguments.contains("--feed-for-you-fixture") else { return nil }
        if case .category = selection {
            // More topics: the ordinary category fixture, from a server that offers For you.
            return try? JSONDecoder().decode(DiscoveryResponse.self, from: Data(#"{"feed":{"for_you":true},"results":\#(Self.fixtureCategoryJSON)}"#.utf8))
        }
        let rows: [[String: Any]] = [
            ["source_id": "2610.08448", "revision": 1, "title": "Cross-Tokenizer On-Policy Distillation for Reasoning Models",
             "authors": ["Mei Lin", "Jonas Weber", "Ana Costa"], "year": 2026, "categories": ["cs.CL", "cs.LG"],
             "abstract": "We distill a reasoning teacher into a student with a different tokenizer, aligning byte spans on-policy.",
             "topics": ["Knowledge distillation", "Tokenization", "Reasoning"], "upvotes": 162,
             "reason": ["kind": "tag", "label": "byte-level LMs", "text": "In your tag: byte-level LMs"]],
            ["source_id": "2610.07767", "revision": 1, "title": "Verifier-Guided GRPO Scales Mathematical Reasoning",
             "authors": ["Sara Okafor", "Peter Lindqvist"], "year": 2026, "categories": ["cs.LG"],
             "abstract": "Process verifiers shape group-relative policy optimization rewards, improving pass@1 on olympiad problems.",
             "topics": ["Policy optimization", "Mathematical reasoning", "Reward modeling"], "upvotes": 87,
             "reason": ["kind": "added", "label": "DeepSeekMath", "text": "Because you added “DeepSeekMath”"]],
            ["source_id": "2610.05030", "revision": 1, "title": "Sparse Feature Circuits in Long-Context Retrieval Heads",
             "authors": ["Hiro Tanaka", "Lena Fischer"], "year": 2026, "categories": ["cs.LG", "cs.CL"],
             "abstract": "Sparse autoencoder features reveal the circuits retrieval heads use across a million-token context.",
             "topics": ["Mechanistic interpretability", "Long context"], "upvotes": 40,
             "reason": ["kind": "author", "label": "Lena Fischer", "text": "By Lena Fischer, an author in your library"]],
            ["source_id": "2610.03543", "revision": 1, "title": "Selective State Spaces Without Tokenizers",
             "authors": ["Omar Haddad"], "year": 2026, "categories": ["cs.LG"],
             "abstract": "A byte-level selective state space model matches subword transformers at equal compute.",
             "topics": ["State space models", "Tokenization"], "upvotes": NSNull(),
             "reason": ["kind": "added", "label": "Mamba", "text": "Because you added “Mamba: Linear-Time Sequence Modeling”"]],
            ["source_id": "2610.09912", "revision": 1, "title": "Household Manipulation from a Single Demonstration",
             "authors": ["Yuki Sato", "Dana Cohen"], "year": 2026, "categories": ["cs.RO"],
             "abstract": "One demonstration and a learned world model suffice for long-horizon household tasks.",
             "topics": ["Imitation learning", "World models"], "upvotes": 5,
             "reason": ["kind": "explore", "label": "cs.RO", "text": "Something different: Robotics"]],
        ]
        // A topic chip: the papers with that topic ("RL for reasoning" and "byte-level LMs" stand for their parts).
        let parts: [String: [String]] = ["RL for reasoning": ["Policy optimization", "Reasoning"], "byte-level LMs": ["Tokenization"]]
        let chosen: [[String: Any]]
        switch selection {
        case .topic(let name):
            let wanted = Set(parts[name] ?? [name])
            chosen = rows.filter { !wanted.isDisjoint(with: $0["topics"] as? [String] ?? []) }
        default:
            chosen = rows
        }
        var feed: [String: Any] = ["for_you": true, "cold_start": false]
        if case .topic(let name) = selection { feed["topic"] = ["name": name, "kind": "topic"] }
        else { feed["topics"] = Self.fixtureFeedTopics.map { ["name": $0.name, "kind": $0.kind, "papers": $0.papers ?? 0] } }
        guard let data = try? JSONSerialization.data(withJSONObject: ["results": chosen, "feed": feed]) else { return nil }
        return try? JSONDecoder().decode(DiscoveryResponse.self, from: data)
    }

    /// Add-paper fixture: an import the scripted upload service created or retried (replaces one with the same ID).
    func insertFixtureImport(_ record: LibraryImportRecord) {
        fixtureImportChanges = true
        libraryImports.removeAll { $0.id == record.id }
        libraryImports.insert(record, at: 0)
    }

    func installLibraryMetadataFixture(papers fixturePapers: [Paper], imports: [LibraryImportRecord], sequences: [UUID: Int64],
                                       activity: [UUID: PaperActivity], offline: [UUID: PaperOfflineStatus],
                                       importStepStarts: [UUID: Date] = [:], importDetailsReceived: [UUID: Date] = [:]) {
        fixtureOfflineStatus = offline
        fixtureImportChanges = true
        libraryCreationSequences = sequences
        readingActivity = activity
        libraryImports = imports
        for item in imports { if let since = importStepStarts[item.id] { importSteps.record(item, since: since) } }
        for item in imports { if let at = importDetailsReceived[item.id] { importProgressTracker.record(item, receivedAt: at) } }
        papers = papers.filter { $0.isSample } + fixturePapers
    }
}
#endif

/// One writer per account's local database. Activation waits for writes already
/// accepted by the UI before updating keys and keeps the same SQLite actor.
@MainActor
final class ReaderLocalPersistence {
    private(set) var store: EncryptedStore?
    /// Device-local originals for source-only papers. These bytes never enter
    /// the cloud library journal or the PDF upload queue.
    private(set) var localPaperStore: DevicePaperStore?
    private(set) var localReaderStore: DeviceReaderStore?
    /// Device-local reading activity, sealed beside the store under the same local-store key.
    private(set) var readingStore: ReadingActivityStore?
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
        return register { try await operation(store) }
    }

    /// Reading-activity saves follow the same ownership: refused once retired, drained before
    /// a replacement session or account deletion erases the folder.
    func acceptReadingWrite(_ entries: [ReadingActivityEntry]) throws -> Task<Void, Error> {
        guard !isRetired, !isActivating, let readingStore else { throw ReaderError.storageUnavailable }
        return register { try await readingStore.save(entries) }
    }

    /// A source-only PDF install is a local write with the same retirement
    /// fence as encrypted chat and reading activity. Sign-out waits for an
    /// accepted install before replacing this writer.
    func acceptLocalPaperWrite<Value: Sendable>(_ operation: @escaping @Sendable (DevicePaperStore) async throws -> Value) throws -> Task<Value, Error> {
        guard !isRetired, !isActivating, let localPaperStore else { throw ReaderError.storageUnavailable }
        return register { try await operation(localPaperStore) }
    }

    func acceptLocalReaderWrite<Value: Sendable>(_ operation: @escaping @Sendable (DeviceReaderStore) async throws -> Value) throws -> Task<Value, Error> {
        guard !isRetired, !isActivating, let localReaderStore else { throw ReaderError.storageUnavailable }
        return register { try await operation(localReaderStore) }
    }

    private func register<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) -> Task<Value, Error> {
        let id = UUID(), task = Task { try await operation() }
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
            if localPaperStore == nil {
                localPaperStore = try DevicePaperStore(directory: url.deletingLastPathComponent().appendingPathComponent("device-papers", isDirectory: true),
                                                        accountID: accountID, localKey: localKey)
            }
            if localReaderStore == nil {
                localReaderStore = try DeviceReaderStore(directory: url.deletingLastPathComponent().appendingPathComponent("device-readers", isDirectory: true),
                                                         accountID: accountID, localKey: localKey)
            }
            try Task.checkCancellation()
            guard !isRetired else { throw CancellationError() }
            return store
        }
        let opened = try EncryptedStore(url: url, accountID: accountID, localKey: localKey, keys: keys)
        let localPapers = try DevicePaperStore(directory: url.deletingLastPathComponent().appendingPathComponent("device-papers", isDirectory: true),
                                                accountID: accountID, localKey: localKey)
        self.accountID = accountID; self.localKey = localKey; storageURL = url.standardizedFileURL
        let localReaders = try DeviceReaderStore(directory: url.deletingLastPathComponent().appendingPathComponent("device-readers", isDirectory: true),
                                                   accountID: accountID, localKey: localKey)
        store = opened; localPaperStore = localPapers; localReaderStore = localReaders
        readingStore = try? ReadingActivityStore(directory: url.deletingLastPathComponent(), accountID: accountID, localKey: localKey)
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
