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

@MainActor @Observable
final class ReaderModel {
    var tab: ReaderTab = .library
    var wideMode: WideMode = .library
    var papers: [Paper] = []
    var selectedPaper: Paper?
    var libraryQuery = ""
    var librarySort = "Recent"
    var searchExternal = false
    var appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system" { didSet { UserDefaults.standard.set(appearance, forKey: "appearance") } }
    var paperFontSize = UserDefaults.standard.double(forKey: "paperFontSize") == 0 ? 17 : UserDefaults.standard.double(forKey: "paperFontSize") { didSet { UserDefaults.standard.set(paperFontSize, forKey: "paperFontSize") } }
    var chatFontSize = 16.0
    var message = ""
    var generalChat = true
    var chatPaperID: UUID?
    private var conversations: [String: UUID] = [:]
    private var drafts: [String: String] = [:]
    private var branchSelections: [UUID: UUID] = [:]
    private var chatContext: String { generalChat ? "general" : "paper/\((chatPaperID ?? selectedPaper?.id)?.wire ?? "none")" }
    var chatInput: String { get { drafts[chatContext] ?? "" } set { drafts[chatContext] = newValue } }
    var activeConversation: UUID? { get { conversations[chatContext] } set { conversations[chatContext] = newValue } }
    var privateState = PrivateState()
    var syncStatus = "On this device"
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
    var cloudConsent = false
    var showCloudConsent = false
    var headings: [String] = []
    var jumpToHeading: String?
    var selectedQuote = ""
    var isGenerating = false
    private var backend: BackendClient?
    private var keys: DeviceKeys?
    private var device: LocalDevice?
    private var store: EncryptedStore?
    private var sync: CloudSync?
    private var started = false
    private var sessionID = UUID()
    private var accountID: UUID?
    private let configuration: BackendConfiguration?

    init(configuration: BackendConfiguration? = .bundled(), client: BackendClient? = nil) {
        self.configuration = configuration; self.backend = client
    }

    var configured: Bool { configuration != nil }
    var filteredPapers: [Paper] {
        let matching = papers.filter { libraryQuery.isEmpty || ($0.title + " " + $0.authors + " " + $0.abstract + " " + $0.keywords.joined(separator: " ")).localizedCaseInsensitiveContains(libraryQuery) }
        return librarySort == "Title" ? matching.sorted { $0.title.localizedCompare($1.title) == .orderedAscending } : matching
    }
    var chatBranches: [ConversationBranch] { activeConversation.map { privateState.conversationBranches($0) } ?? [] }
    var activeBranchID: UUID? {
        get {
            let branches = chatBranches
            if let conversation = activeConversation, let selected = branchSelections[conversation] {
                if branches.contains(where: { $0.head == selected }) { return selected }
                if let continuation = branches.first(where: { $0.messages.contains(where: { $0.id == selected }) }) { return continuation.head }
            }
            return branches.first?.head
        }
        set { if let conversation = activeConversation { branchSelections[conversation] = newValue } }
    }
    var chatMessages: [AppliedEvent] { chatBranches.first(where: { $0.head == activeBranchID })?.messages ?? [] }
    var chatContextComplete: Bool { chatBranches.first(where: { $0.head == activeBranchID })?.complete ?? true }

    func start() async {
        guard !started else { return }; started = true
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
        clearAccountView()
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
            try await activate(recovered, scope: scope)
            guard sessionID == scope else { return }
            recoveryCode = nil; showRecovery = false
        } catch { if sessionID == scope { show(error) } }
    }

    private func activate(_ device: LocalDevice, scope: UUID) async throws {
        guard sessionID == scope, accountID == device.accountID else { throw BackendError.signInRequired }
        guard let bundle = device.bundle, let backend, let configuration else { throw ReaderError.missingKey }
        let environment = configuration.environment
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("\(environment)/\(device.accountID.wire)", isDirectory: true)
        let local = try EncryptedStore(url: directory.appendingPathComponent("private-state.enc"), accountID: device.accountID, localKey: device.localStoreKey, keys: bundle)
        let state = await local.state()
        guard sessionID == scope, accountID == device.accountID else { throw BackendError.signInRequired }
        self.device = device; self.store = local
        self.sync = CloudSync(backend: backend, device: device, store: local)
        privateState = state
        await synchronize()
    }

    func synchronize() async {
        let scope = sessionID
        if let support { await support.flush() }
        guard sessionID == scope else { return }
        guard let sync, let store else { return }
        syncStatus = "Syncing…"
        do {
            try await sync.synchronize()
            let state = await store.state()
            guard sessionID == scope else { return }
            privateState = state; syncStatus = "Synced"
        } catch { if sessionID == scope { syncStatus = "Saved on this device"; show(error) } }
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
        sessionID = UUID(); accountID = nil; isBusy = false; isGenerating = false
        support?.cancel(); support = nil
        sync?.cancel(); sync = nil
        device = nil; store = nil; keys = nil
        privateState = PrivateState(); papers = []; selectedPaper = nil; chatPaperID = nil
        conversations = [:]; drafts = [:]; branchSelections = [:]; selectedQuote = ""; headings = []; jumpToHeading = nil
        generalChat = true
        email = nil; recoveryCode = nil; showRecovery = false; showReports = false; showReport = false; reportScreenshot = nil
        cloudConsent = false; showCloudConsent = false; showAllChats = false; showDiagrams = false
        showReportsAfterComposer = false; error = nil; tab = .library; wideMode = .library; syncStatus = "On this device"
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

    func openConversation(_ id: UUID) {
        guard let event = privateState.revisions(for: id).first, event.payload.kind == .conversation else { return }
        if let documentID = event.payload.documentID {
            chatPaperID = documentID; selectedPaper = papers.first { $0.id == documentID }; generalChat = false; wideMode = .reader
        } else { generalChat = true; wideMode = .chat }
        activeConversation = id; tab = .chat
    }
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
        else if !cloudConsent { showCloudConsent = true }
        else { Task { await sendMessage() } }
    }

    func newChat(general: Bool) { generalChat = general; activeConversation = nil; chatInput = "" }

    func sendMessage() async {
        guard let store, let device else { showSignIn = true; return }
        guard !isGenerating, accountID == device.accountID else { return }
        guard cloudConsent else { showCloudConsent = true; return }
        guard chatContextComplete else { error = "Sync this conversation before continuing; an earlier message is still missing."; return }
        let draft = chatInput, context = chatContext, scope = sessionID
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let documentID = generalChat ? nil : (chatPaperID ?? selectedPaper?.id)
        let conversation = activeConversation ?? UUID()
        var parents = activeBranchID.map { [$0] } ?? []
        isGenerating = true; defer { if sessionID == scope { isGenerating = false } }
        do {
            if activeConversation == nil {
                let created = try await store.append(PrivateEvent(kind: .conversation, entityID: conversation, documentID: documentID, text: String(text.prefix(100))), deviceID: device.deviceID)
                guard sessionID == scope else { return }
                conversations[context] = conversation; parents = [created.id]
            }
            let sent = try await store.append(PrivateEvent(kind: .message, parents: parents, conversationID: conversation, documentID: documentID,
                text: text, role: .user, status: .complete), deviceID: device.deviceID)
            let state = await store.state()
            guard sessionID == scope else { return }
            branchSelections[conversation] = sent.id
            if drafts[context] == draft { drafts[context] = "" }
            privateState = state
            await synchronize()
            guard sessionID == scope else { return }
            // Provider ingress is connected only after the server budget gate and
            // dedicated provider credentials pass deployment verification.
            error = "Your message is saved. Cloud responses will be available once this beta backend is configured."
        } catch { if sessionID == scope { show(error) } }
    }

    func show(_ error: Error) { self.error = (error as? LocalizedError)?.errorDescription ?? "This operation could not finish. Your existing saved data has been preserved." }
}
