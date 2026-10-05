import SwiftUI
import ScienceReaderCore

struct RootView: View {
    @Bindable var model: ReaderModel
    @Environment(\.scenePhase) private var scenePhase
    /// A software keyboard covers the tab bar, as with the system tab bar, so
    /// the chat transcript keeps its space while typing.
    @State private var softwareKeyboardShown = false

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 850 { wideLayout(width: geometry.size.width) }
            else {
                VStack(spacing: 0) {
                    destination(model.tab)
                    if !softwareKeyboardShown {
                        HStack(spacing: 0) {
                            ForEach(ReaderTab.allCases) { tab in
                                Button {
                                    model.tab = tab
                                    // Keep the selected destination when an iPad
                                    // rotates from tabs into the wider layout.
                                    switch tab {
                                    case .feed: model.wideMode = .feed
                                    case .library: model.wideMode = .library
                                    case .paper: model.wideMode = .reader
                                    case .chat: model.wideMode = model.generalChat ? .chat : .reader
                                    case .settings: break
                                    }
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: tab.symbol).font(.system(size: 20))
                                        Text(tab.rawValue).font(.caption2).lineLimit(1).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                                    }
                                    .frame(maxWidth: .infinity).frame(minHeight: 49)
                                    .foregroundStyle(model.tab == tab ? Color.accentColor : Color.secondary)
                                }
                                .disabled(tab == .paper && model.selectedPaper == nil)
                                .opacity(tab == .paper && model.selectedPaper == nil ? 0.35 : 1)
                                .accessibilityIdentifier("tab.\(tab.rawValue.lowercased())")
                                .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
                                .accessibilityShowsLargeContentViewer { Label(tab.rawValue, systemImage: tab.symbol) }
                            }
                        }
                        .padding(4).modifier(ReaderControlMaterial()).padding(.horizontal, 12).padding(.vertical, 4)
                    }
                }
                .onChange(of: model.generalChat) { _, general in
                    if model.tab == .chat { model.wideMode = general ? .chat : .reader }
                }
            }
        }
        // On the root so the state stays true across wide/compact layout switches.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            // A hardware keyboard's shortcut bar is short; keep the tabs then.
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            softwareKeyboardShown = (frame?.height ?? 0) > 150
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            softwareKeyboardShown = false
        }
        #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && targetEnvironment(simulator)
        .overlay(alignment: .topTrailing) {
            if OfflineResourceProbe.shared.mode != nil { OfflineResourceStatusView() }
        }
        #endif
        .overlay {
            if scenePhase != .active {
                ZStack {
                    Color(uiColor: .systemBackground).ignoresSafeArea()
                    Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .sheet(isPresented: signInPresentation, onDismiss: { model.authenticationSheetDismissed() }) {
            if let presentationID = model.signInPresentationID {
                AuthenticationView(model: model, presentationID: presentationID).id(presentationID)
            }
        }
        .sheet(isPresented: $model.showRecovery) { RecoveryView(model: model).interactiveDismissDisabled() }
        .sheet(item: consentPresentation) { prompt in ChatConsentView(model: model, prompt: prompt).interactiveDismissDisabled() }
        .sheet(isPresented: $model.showAllChats) { HistoryView(model: model, diagrams: false) }
        .sheet(isPresented: $model.showDiagrams) { HistoryView(model: model, diagrams: true) }
        // At the root: deletion signs out, which leaves Settings.
        .alert("Account deleted", isPresented: $model.accountDeletedNotice) { Button("OK") {} } message: {
            Text("Your account and its data were deleted from our servers and this device.")
        }
        .sheet(isPresented: $model.showStore) { CreditsStoreView(model: model) }
        .sheet(item: $model.presentedDiagram) { presented in
            if let diagram = model.diagram(presented.id) { DiagramSheet(diagram: diagram) }
        }
        .sheet(isPresented: $model.showReport, onDismiss: {
            model.reportScreenshot = nil
            if model.showReportsAfterComposer { model.showReportsAfterComposer = false; model.showReports = true }
        }) { ReportComposer(model: model) }
        .sheet(isPresented: $model.showReports) { if let service = model.support { ReportsView(service: service) } }
        .alert("Science Reader", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        #if INTERNAL
        .modifier(SessionCaptureHooks(model: model))
        #endif
        .onChange(of: scenePhase) { _, phase in
            Task {
                await model.flushDrafts()
                if phase == .active {
                    async let history: Void = model.synchronize()
                    async let library: Void = model.refreshLibrary()
                    async let purchases: Void = model.syncStoreTransactions()
                    _ = await (history, library, purchases)
                }
            }
        }
    }

    private var signInPresentation: Binding<Bool> {
        // SwiftUI may deliver the dismissal after this body has changed. Keep
        // the ID that this binding actually presented, rather than cancelling
        // whichever attempt happens to be current when the callback arrives.
        let presentationID = model.signInPresentationID
        return Binding(get: { model.showSignIn }, set: { presented in
            if !presented, let presentationID { model.closeSignIn(presentationID: presentationID) }
        })
    }

    /// A system dismissal counts as declining that captured question only.
    private var consentPresentation: Binding<ChatConsentPrompt?> {
        Binding(get: { model.chatConsentPrompt }, set: { value in
            if value == nil, let prompt = model.chatConsentPrompt { model.declineChatConsent(prompt) }
        })
    }

    @ViewBuilder private func destination(_ tab: ReaderTab) -> some View {
        switch tab {
        case .feed: FeedView(model: model)
        case .library: LibraryView(model: model)
            #if OFFLINE_RESOURCE_MEASUREMENTS
            .onAppear { OfflineResourceProbe.shared.destinationAppearance(.library, appeared: true) }
            .onDisappear { OfflineResourceProbe.shared.destinationAppearance(.library, appeared: false) }
            #endif
        case .paper: PaperView(model: model)
        case .chat: ChatView(model: model)
        case .settings: SettingsView(model: model)
            #if OFFLINE_RESOURCE_MEASUREMENTS
            .onAppear { OfflineResourceProbe.shared.destinationAppearance(.settings, appeared: true) }
            .onDisappear { OfflineResourceProbe.shared.destinationAppearance(.settings, appeared: false) }
            #endif
        }
    }

    private func wideLayout(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label("Science Reader", systemImage: "books.vertical").font(.headline)
                Spacer()
                Picker("View", selection: $model.wideMode) {
                    ForEach(WideMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 560)
                    .onChange(of: model.wideMode) { _, mode in
                        model.tab = mode == .feed ? .feed : (mode == .chat ? .chat : (mode == .reader ? .paper : .library))
                        if mode == .chat { model.generalChat = true }
                        if mode == .reader, model.chatPaperID != nil { model.generalChat = false }
                    }
                Button { model.tab = .settings } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }.accessibilityLabel("Settings")
            }.padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            if model.tab == .settings {
                SettingsView(model: model, dismissSettings: { model.tab = .library })
            } else {
                switch model.wideMode {
                case .feed: FeedView(model: model)
                case .library: LibraryView(model: model)
                case .reader:
                    HStack(spacing: 0) { PaperView(model: model).frame(maxWidth: .infinity); Divider(); ChatView(model: model).frame(width: min(400, max(320, width * 0.28))) }
                case .browse:
                    HStack(spacing: 0) { LibraryView(model: model).frame(width: min(350, max(300, width * 0.29))); Divider(); PaperView(model: model).frame(maxWidth: .infinity) }
                case .chat: ChatView(model: model)
                }
            }
        }
    }
}

struct ReaderControlMaterial: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28)) }
        else { content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28)) }
    }
}

struct LibraryView: View {
    @Bindable var model: ReaderModel
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !model.isSignedIn {
                    Button { model.openSignIn() } label: {
                        HStack {
                            Image(systemName: "lock.icloud").font(.system(size: 20))
                            Text("Sign in to sync").font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.padding(.horizontal, 16).padding(.vertical, 4).background(Color.accentColor.opacity(0.06))
                }
                HStack {
                    Picker("Search", selection: $model.searchExternal) { Text("Library").tag(false); Text("arXiv").tag(true) }.pickerStyle(.segmented).frame(maxWidth: 220)
                    Spacer()
                    Menu { Picker("Sort", selection: $model.librarySort) { Text("Recent").tag("Recent"); Text("Title").tag("Title") } } label: { Image(systemName: "arrow.up.arrow.down").font(.system(size: 18)).frame(width: 44, height: 44) }.accessibilityLabel("Sort papers")
                        .disabled(model.searchExternal)
                    Menu {
                        Toggle("Abstracts", isOn: $model.showAbstracts)
                        Toggle("Topics", isOn: $model.showTopics)
                    } label: { Image(systemName: "text.alignleft").font(.system(size: 18)).frame(width: 44, height: 44) }.accessibilityLabel("Result details").disabled(model.searchExternal)
                }.padding(.horizontal, 16).padding(.vertical, 10)
                if !model.searchExternal, let issue = model.libraryIssue {
                    HStack(alignment: .firstTextBaseline) {
                        Text(issue).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Retry") { Task { await model.refreshLibrary() } }.font(.caption.weight(.semibold))
                            .disabled(model.libraryRefreshing)
                    }.padding(.horizontal, 16).padding(.bottom, 10).accessibilityIdentifier("library.refreshIssue")
                }
                if !model.searchExternal, !model.libraryCommands.isEmpty || model.libraryCommandIssue != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        if let issue = model.libraryCommandIssue { Text(issue).font(.caption).foregroundStyle(.secondary) }
                        if !model.libraryCommands.isEmpty {
                            Button("Pending changes (\(model.libraryCommands.count))", systemImage: "arrow.triangle.2.circlepath") {
                                model.showLibraryChanges = true
                            }.font(.caption.weight(.semibold)).accessibilityIdentifier("library.pendingChanges")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 10)
                }
                if !model.searchExternal, let issue = model.offlineCacheIssue {
                    Text(issue).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 10)
                        .accessibilityIdentifier("library.offlineIssue")
                }
                if model.searchExternal {
                    DiscoveryList(model: model)
                } else if model.librarySearchPending && !model.librarySearchKeepsCurrentRows {
                    Spacer()
                    ProgressView(model.libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Loading library…" : "Searching…")
                        .accessibilityIdentifier("library.searching")
                    Spacer()
                } else if let issue = model.librarySearchIssue {
                    ContentUnavailableView {
                        Label("Couldn’t search", systemImage: "magnifyingglass")
                    } description: { Text(issue) }
                        actions: { Button("Try again") { model.retryLibrarySearch() } }
                } else if model.libraryRefreshing && !model.libraryHasSnapshot && model.libraryRows.isEmpty {
                    Spacer()
                    ProgressView("Loading library…")
                    Spacer()
                } else if !model.librarySearchPending && model.libraryRows.isEmpty && !model.libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView {
                        Label("No matching papers", systemImage: "magnifyingglass")
                    } description: {
                        Text("Try a different title, author, or topic.")
                    } actions: {
                        Button("Clear search") { model.libraryQuery = "" }.accessibilityIdentifier("search.clear")
                    }
                } else if !model.librarySearchPending && model.libraryRows.isEmpty {
                    ContentUnavailableView {
                        Label(model.searchExternal ? "Find papers" : "Your library", systemImage: model.searchExternal ? "magnifyingglass" : "books.vertical")
                    } description: {
                        Text(model.searchExternal ? "Search arXiv to add a paper." : "Add a paper to read and ask questions.")
                    } actions: {
                        Button("Open sample") { model.openSample() }.buttonStyle(.bordered).accessibilityIdentifier("sample.open")
                    }
                } else {
                    List(model.libraryRows) { entry in
                        #if OFFLINE_RESOURCE_MEASUREMENTS
                        let resourceDocumentID: UUID? = {
                            if case .paper(let paper) = entry { return paper.id }
                            return nil
                        }()
                        let _ = OfflineResourceProbe.shared.recordLibraryRowBuilder(documentID: resourceDocumentID)
                        #endif
                        VStack(alignment: .leading, spacing: 0) {
                            switch entry {
                            case .paper(let paper):
                                Button { model.select(paper) } label: { PaperRow(paper: paper, selected: model.selectedPaper?.id == paper.id, offlineStatus: model.offlineStatus(for: paper), showAbstract: model.showAbstracts, showTopics: model.showTopics) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("paper.\(paper.id.wire)")
                                    .contextMenu {
                                        if !paper.isSample {
                                            Button("Remove from library", systemImage: "minus.circle", role: .destructive) { Task { await model.removePaper(paper) } }
                                                .disabled(!model.canChangeLibrary)
                                        }
                                    }
                            case .pending(let item):
                                ImportRow(item: item, showAbstract: model.showAbstracts, showTopics: model.showTopics, getCredits: { model.showStore = true })
                                    .accessibilityIdentifier("import.\(item.id.wire)")
                                    .contextMenu {
                                        if item.phase == .failed && item.retryable {
                                            Button("Retry import", systemImage: "arrow.clockwise") { Task { await model.changeImport(item, retry: true) } }
                                                .disabled(!model.canChangeLibrary)
                                        }
                                        Button("Cancel import", systemImage: "xmark.circle", role: .destructive) { Task { await model.changeImport(item, retry: false) } }
                                            .disabled(!model.canChangeLibrary)
                                    }
                            case .queued(let command):
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(command.display ?? "Queued paper").font(.headline)
                                    Text(command.libraryStatus).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityIdentifier("import.\(command.id.wire)")
                                    .contextMenu {
                                        Button("Cancel import", systemImage: "xmark.circle", role: .destructive) { Task { await model.cancelLibraryChange(command) } }
                                            .disabled(!model.canChangeLibrary)
                                    }
                            }
                        }.listRowInsets(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
                    }.listStyle(.plain).refreshable { await model.refreshLibrary() }
                        .overlay(alignment: .top) {
                            if model.librarySearchPending { ProgressView("Updating results…").padding(8).allowsHitTesting(false) }
                        }
                }
            }
            .navigationTitle("Library").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.searchQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: model.searchExternal ? "Search arXiv" : "Search your library")
            .onSubmit(of: .search) { if model.searchExternal { model.runDiscovery() } }
            .onChange(of: model.searchExternal) { _, external in
                if external, model.discoveryState == .idle, !model.discoveryQuery.trimmingCharacters(in: .whitespaces).isEmpty { model.runDiscovery() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("All chats", systemImage: "bubble.left.and.bubble.right") { model.showAllChats = true }
                        Button("All diagrams", systemImage: "square.stack.3d.up") { model.showDiagrams = true }
                        Button("Refresh library", systemImage: "arrow.clockwise") { Task { await model.refreshLibrary() } }
                            .disabled(!model.isSignedIn || model.libraryRefreshing)
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Library options")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if model.librarySignInRequired { model.openSignIn() } else { model.showImport = true }
                    } label: { Image(systemName: "plus") }.accessibilityLabel("Add a paper")
                }
            }
            .sheet(isPresented: $model.showImport) { ImportPaperView(model: model) }
            .sheet(isPresented: $model.showLibraryChanges) { LibraryChangesView(model: model) }
        }
    }
}

struct ImportRow: View {
    let item: LibraryImportRecord
    var showAbstract = true
    var showTopics = true
    /// Offered when the conversion failed for lack of credits.
    var getCredits: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var status: String {
        switch item.phase {
        case .accepted: "Queued"
        case .resolving: "Finding paper…"
        case .acquiring:
            switch item.progress {
            case .downloading: "Downloading PDF…"
            case .converting: "Converting equations and figures…"
            case .rendering, .finishing: "Building reader…"
            default: "Preparing PDF…"
            }
        case .sourceOnly: "Available at source"
        case .failed:
            switch item.errorCode {
            case .insufficientCredits: "Not enough credits to convert this paper"
            case .tooLarge: "This PDF is too large to convert"
            case .pdfInvalid: "This PDF couldn’t be read"
            case .conversionFailed: "Conversion failed"
            case .downloadFailed, .rateLimited: "Couldn’t download this paper"
            default: "Couldn’t import this paper"
            }
        case .membershipConflict: "Not added to library"
        case .ready: "Added"
        case .cancelled: "Cancelled"
        }
    }
    private var active: Bool { [.resolving, .acquiring].contains(item.phase) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.metadata?.title ?? "arXiv \(item.sourceID)").font(.headline).fixedSize(horizontal: false, vertical: true)
            if let authors = item.metadata?.authors, !authors.isEmpty {
                Text(authors.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
            if showAbstract, let abstract = item.metadata?.abstract, !abstract.isEmpty {
                Text(abstract).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            let year = item.metadata?.publishedAt.map { String($0.prefix(4)) }
            let topics = showTopics ? Array((item.metadata?.categories ?? []).prefix(3)) : []
            let revision = (item.sourceRevision ?? item.requestedRevision).map { ["arXiv v\($0)"] } ?? []
            let metadata = (year.map { [$0] } ?? []) + revision + topics
            if !metadata.isEmpty { Text(metadata.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
            HStack(spacing: 6) {
                if active { ProgressView().controlSize(.small).accessibilityHidden(true) }
                Text(status).font(.caption).foregroundStyle(.secondary)
                if item.phase == .failed, item.errorCode == .insufficientCredits, let getCredits {
                    Button("Get credits", action: getCredits).font(.caption.weight(.semibold)).buttonStyle(.borderless)
                        .accessibilityIdentifier("import.getCredits")
                }
                if !active, let url = URL(string: item.sourceURL) {
                    Spacer(minLength: 8)
                    Link("View source", destination: url).font(.caption.weight(.semibold))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PaperRow: View {
    let paper: Paper
    var selected = false
    var offlineStatus: PaperOfflineStatus = .none
    var showAbstract = true
    var showTopics = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        #if OFFLINE_RESOURCE_MEASUREMENTS
        let _ = OfflineResourceProbe.shared.recordPaperRowBody(documentID: paper.id)
        #endif
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(paper.title).font(.headline).foregroundStyle(selected ? Color.accentColor : .primary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if offlineStatus == .available { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).accessibilityLabel("Available offline") }
                else if offlineStatus == .unavailable { Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).accessibilityLabel("Downloaded copy unavailable") }
            }
            if !paper.authors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text(paper.authors).font(.caption).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1) }
            if showAbstract && !paper.abstract.isEmpty { Text(paper.abstract).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            let source = paper.sourceID == nil ? [] : [paper.sourceRevision.map { "arXiv v\($0)" } ?? "arXiv"]
            let metadata = (paper.year.map { [String($0)] } ?? []) + source
            let topics = showTopics ? Array(paper.keywords.prefix(3)) : []
            if !(metadata + topics).isEmpty { Text((metadata + topics).joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

struct FeedView: View {
    @Bindable var model: ReaderModel
    @State private var issue: String?
    private static let names = ["cs.LG": "Machine learning", "cs.CL": "Language", "cs.AI": "AI", "cs.CV": "Vision",
                                "stat.ML": "Statistical ML", "cs.RO": "Robotics", "cs.NE": "Neural computing", "cs.IR": "Retrieval",
                                "math.OC": "Optimization", "cs.CR": "Security", "cs.DC": "Distributed"]
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.feedCategories, id: \.self) { category in
                            let selected = (model.feedCategory ?? model.feedCategories.first) == category
                            Button(Self.names[category] ?? category) { model.selectFeedCategory(category) }
                                .buttonStyle(.bordered).tint(selected ? .accentColor : .secondary)
                                .accessibilityAddTraits(selected ? .isSelected : [])
                                .accessibilityIdentifier("feed.topic.\(category)")
                        }
                    }.padding(.horizontal, 16).padding(.vertical, 8)
                }
                switch model.feedState {
                case .idle, .loading:
                    Spacer(); ProgressView("Finding new papers…"); Spacer()
                case .failed(let message):
                    ContentUnavailableView { Label("Feed unavailable", systemImage: "dot.radiowaves.up.forward") }
                        description: { Text(message) }
                        actions: {
                            if model.librarySignInRequired { Button("Sign in") { model.openSignIn() }.buttonStyle(.borderedProminent) }
                            else { Button("Try again") { model.loadFeed() } }
                        }
                case .loaded:
                    if model.feedResults.isEmpty {
                        ContentUnavailableView("No new papers", systemImage: "dot.radiowaves.up.forward", description: Text("Check back later or pick another topic."))
                    } else {
                        List {
                            if let issue { Text(issue).font(.footnote).foregroundStyle(.secondary) }
                            ForEach(model.feedResults) { result in DiscoveryRow(model: model, result: result, issue: $issue) }
                        }.listStyle(.plain).refreshable { model.loadFeed() }
                    }
                }
            }
            .navigationTitle("Feed").navigationBarTitleDisplayMode(.inline)
            .task { if model.feedState == .idle || (model.feedState != .loading && model.feedResults.isEmpty && !model.librarySignInRequired) { model.loadFeed() } }
        }
    }
}

struct ChatView: View {
    @Bindable var model: ReaderModel
    @ScaledMetric(relativeTo: .body) private var bodySize = 17.0
    @FocusState private var composerFocused: Bool
    var body: some View {
        NavigationStack {
            GeometryReader { available in
                // Reserve reading and editing space as text grows or a keyboard
                // reduces the pane. The transcript/composer retain their identity.
                let compact = available.size.height < bodySize * 20
                VStack(spacing: 0) {
                    contextHeader(compact: compact)
                    if model.chatBranches.count > 1 {
                        Picker("Conversation branch", selection: $model.activeBranchID) {
                            ForEach(model.chatBranches, id: \.head) { branch in
                                Text(model.privateState.events[branch.head].map { model.privateState.isDeleted($0.payload.entityID) } == true
                                    ? "Earlier messages" : String((branch.messages.last?.payload.text ?? "Continuation").prefix(60)))
                                    .tag(Optional(branch.head))
                            }
                        }.pickerStyle(.menu).padding(.horizontal).accessibilityIdentifier("chat.branchPicker")
                    }
                    if !model.chatContextComplete && !model.chatWasDeleted {
                        Text("Sync to load the earlier messages in this conversation.").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    }
                    ChatTranscript(model: model, fontSize: model.chatFontSize * bodySize / 17)
                    if let issue = model.chatAnswerIssue {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                            Text(issue.message).font(.caption).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("chat.answerIssue")
                            if issue.code == "insufficient_credits" {
                                Button("Get credits") { model.showStore = true }.font(.caption.weight(.semibold))
                                    .accessibilityIdentifier("chat.getCredits")
                            }
                            if issue.retryable {
                                Button(issue.actionTitle) { model.retryAnswer() }.font(.caption.weight(.semibold))
                                    .accessibilityIdentifier("chat.retryAnswer")
                            }
                        }
                        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 6)
                    }
                    if let issue = model.chatDraftIssue {
                        HStack {
                            Text(issue).font(.caption)
                            Button("Retry") { model.retryDraftSave() }.font(.caption.weight(.semibold))
                        }.padding(.horizontal, 16).accessibilityIdentifier("chat.draftIssue")
                    } else if model.draftsArePersistent && !model.chatInput.isEmpty {
                        Text(model.chatDraftStatusText).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("chat.draftStatus")
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("Ask a question…", text: $model.chatInput, axis: .vertical)
                            .focused($composerFocused).accessibilityIdentifier("chat.composer")
                            .lineLimit(1...(compact ? 2 : 6)).fixedSize(horizontal: false, vertical: true)
                            .padding(12).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        if composerFocused {
                            Button { composerFocused = false } label: {
                                Image(systemName: "keyboard.chevron.compact.down").font(.body).frame(width: 44, height: 44)
                            }.accessibilityLabel("Dismiss keyboard").accessibilityIdentifier("chat.dismissKeyboard")
                                .keyboardShortcut(.cancelAction)
                        }
                        if model.isAnswering {
                            Button { model.stopAnswer() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 32)).frame(width: 44, height: 44) }
                                .disabled(model.isStoppingAnswer).accessibilityLabel("Stop answer").accessibilityIdentifier("chat.stop")
                        } else {
                            Button { Task { await model.sendMessage() } } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)).frame(width: 44, height: 44) }
                                .disabled(model.isGenerating || model.isDiscardingDraft || (!model.generalChat && !model.canUsePaperChat) || !model.chatContextComplete || model.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("Send").accessibilityIdentifier("chat.send")
                        }
                    }.padding(12)
                    if model.isGenerating { ProgressView("Saving…").font(.caption).padding(.bottom, 5) }
                    else if model.isSignedIn || model.chatHasSaved { Text(model.syncStatus).font(.caption2).dynamicTypeSize(...DynamicTypeSize.xxxLarge).foregroundStyle(.secondary).padding(.bottom, 5) }
                }
            }
            .navigationTitle(model.chatTitle).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { composerFocused = false; model.showAllChats = true } label: { Image(systemName: "clock.arrow.circlepath") }.accessibilityLabel("Chat history") }
                ToolbarItem(placement: .topBarTrailing) { Button { model.newChat(general: model.generalChat); composerFocused = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("New chat") }
            }
        }
    }

    private func contextPicker(compact: Bool) -> some View {
        Picker("Context", selection: Binding(get: { model.generalChat }, set: { if $0 || model.canUsePaperChat { model.generalChat = $0 } })) {
            Text(compact ? "Paper" : "Paper chat").accessibilityLabel("Paper chat").tag(false).disabled(!model.canUsePaperChat)
            Text(compact ? "General" : "General chat").accessibilityLabel("General chat").tag(true)
        }.pickerStyle(.segmented)
    }

    @ViewBuilder private func contextHeader(compact: Bool) -> some View {
        if compact {
            HStack(spacing: 8) {
                contextPicker(compact: true)
                returnToPaper(compact: true)
            }.padding(.horizontal, 12).padding(.vertical, 4)
        } else {
            VStack(spacing: 0) {
                contextPicker(compact: false).padding(12)
                returnToPaper(compact: false)
            }
        }
    }

    @ViewBuilder private func returnToPaper(compact: Bool) -> some View {
        if !model.generalChat {
            if let paper = model.chatPaper {
                Button { composerFocused = false; model.select(paper) } label: {
                    if compact {
                        Image(systemName: "doc.text").font(.body).frame(width: 44, height: 44).contentShape(Rectangle())
                    } else {
                        Label(paper.title, systemImage: "doc.text").font(.caption).lineLimit(2).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()).padding(.horizontal, 16)
                    }
                }.accessibilityLabel("Return to paper: \(paper.title)").accessibilityIdentifier("chat.returnToPaper")
                    .accessibilityShowsLargeContentViewer { Label(paper.title, systemImage: "doc.text") }
            } else if model.canUsePaperChat {
                Text("Paper unavailable in this library").font(.caption).foregroundStyle(.secondary).padding(.bottom, compact ? 0 : 10)
            }
        }
    }
}

struct SettingsView: View {
    @Bindable var model: ReaderModel
    var dismissSettings: (() -> Void)? = nil
    @State private var showDeleteAccount = false
    private static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if model.isSignedIn {
                        Label(model.email.flatMap { $0.isEmpty ? nil : $0 } ?? "Signed in", systemImage: "person.crop.circle")
                        LabeledContent("Sync", value: model.syncStatus)
                        if let issue = model.syncIssue { Text(issue).font(.footnote).foregroundStyle(.secondary) }
                        if let issue = model.accountPreparationIssue {
                            Text(issue).font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("account.preparationIssue")
                            Button("Try again") { Task { await model.retryAccountPreparation() } }
                                .disabled(model.isBusy).accessibilityIdentifier("account.retryPreparation")
                        }
                        Button("Sign out") { Task { await model.signOut() } }.accessibilityIdentifier("account.signOut")
                        Text("Encrypted pending work stays on this device for your next sign-in.").font(.footnote).foregroundStyle(.secondary)
                        Button("Delete account…", role: .destructive) { showDeleteAccount = true }.accessibilityIdentifier("account.delete")
                    }
                    else { Button("Sign in or create an account") { model.openSignIn() }.accessibilityIdentifier("account.signIn") }
                    LabeledContent("Environment", value: "Private beta · staging")
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                }
                if model.isSignedIn && model.chatTransport != nil {
                    Section {
                        if let balance = model.creditBalance {
                            LabeledContent("Available", value: "\(balance.available.formatted()) credits")
                                .accessibilityIdentifier("settings.credits.available")
                            if balance.reserved > 0 {
                                LabeledContent("Held for answers in progress", value: balance.reserved.formatted())
                            }
                        } else if let issue = model.creditBalanceIssue {
                            Text(issue).font(.footnote).foregroundStyle(.secondary)
                        } else {
                            LabeledContent("Available", value: "Loading…")
                        }
                        if let plan = model.storeSummary?.planName { LabeledContent("Plan", value: plan) }
                        Button("Get credits") { model.showStore = true }
                            .disabled(!model.canPurchase).accessibilityIdentifier("settings.getCredits")
                    } header: { Text("Credits") } footer: {
                        Text("Each AI answer uses credits based on the question, the conversation, the paper’s length and the answer.")
                    }
                }
                Section("Reading") {
                    Picker("Appearance", selection: $model.appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                    VStack(alignment: .leading) { Text("Paper text size"); Slider(value: $model.paperFontSize, in: 14...26, step: 1) }.accessibilityElement(children: .combine)
                    VStack(alignment: .leading) { Text("Chat text size"); Slider(value: $model.chatFontSize, in: 14...24, step: 1) }.accessibilityElement(children: .combine)
                }
                Section("Your research") {
                    Button("All chats") { model.showAllChats = true }
                    Button("All diagrams") { model.showDiagrams = true }
                    Button("Sync now") { Task { await model.synchronize(reportErrors: true) } }.disabled(!model.isSignedIn)
                }
                Section("Privacy") {
                    Text("Private conversations and notes are encrypted with keys held on your devices. An approved device or your recovery code is needed to restore them.").font(.footnote).foregroundStyle(.secondary)
                    Text("AI answers send your question, any selected passage, earlier messages in that conversation and, for paper chats, the paper’s text to Anthropic. Claude may search the web for some questions; those searches go to Anthropic’s search provider. Private PDF uploads and reports you submit are accessible to the services that process them.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Testing") {
                    #if INTERNAL
                    SessionCaptureSettings()
                    #endif
                    Button("Report this screen", systemImage: "ladybug") { model.beginReport() }
                    Button("My reports", systemImage: "tray") { model.showReports = true }.disabled(model.support == nil)
                    LabeledContent("Version", value: Self.version)
                    Button("Open reader sample") { model.openSample() }
                }
            }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                // On the Form: a sheet attached inside a Form row doesn't present reliably.
                .sheet(isPresented: $showDeleteAccount) { DeleteAccountView(model: model) }
                .task(id: model.isSignedIn) { if model.isSignedIn { await model.refreshCreditBalance(); await model.refreshStoreSummary() } }
                .toolbar { if let dismissSettings { ToolbarItem(placement: .topBarLeading) { Button("Done", action: dismissSettings) } } }
        }
    }
}

struct HistoryView: View {
    @Bindable var model: ReaderModel
    let diagrams: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            let entities = diagrams ? [] : model.privateState.entities(kind: .conversation)
            let savedDiagrams = diagrams ? model.privateState.diagrams() : []
            let drafts = diagrams ? [] : model.unsentDrafts
            List {
                if !drafts.isEmpty {
                    Section {
                        ForEach(drafts) { draft in
                            Button { model.openUnsentDraft(draft.id); dismiss() } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(draft.text).lineLimit(2)
                                    Text(draft.failed ? "Not saved" : (draft.context == "general" ? "General chat" : "Paper chat"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.accessibilityIdentifier("chat.draft.\(draft.id.wire)")
                                .swipeActions(allowsFullSwipe: false) {
                                    Button("Discard", role: .destructive) { model.discardUnsentDraft(draft.id) }
                                }
                        }
                    } header: { Text("Unsent drafts") } footer: {
                        Text(model.draftsArePersistent ? "Drafts stay on this device." : "Kept for this session.")
                    }
                }
                Section {
                    ForEach(entities, id: \.self) { id in
                        if let event = model.privateState.revisions(for: id).first {
                            Button(event.payload.text ?? "Untitled") { model.openConversation(id); dismiss() }
                        }
                    }
                    ForEach(savedDiagrams, id: \.id) { saved in
                        NavigationLink(saved.diagram.title) { DiagramDetail(diagram: saved.diagram) }
                            .accessibilityIdentifier("diagram.\(saved.id.wire)")
                    }
                } header: { if !drafts.isEmpty { Text("Saved conversations") } }
            }.overlay { if entities.isEmpty && savedDiagrams.isEmpty && drafts.isEmpty { ContentUnavailableView(diagrams ? "No diagrams yet" : "No conversations yet", systemImage: diagrams ? "square.stack.3d.up" : "bubble.left.and.bubble.right") } }
                .navigationTitle(diagrams ? "All diagrams" : "All chats").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

struct RecoveryView: View {
    @Bindable var model: ReaderModel
    @State private var input = ""
    @State private var saved = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(model.needsRecovery ? "Restore your private library" : (model.recoveryCode != nil ? "Save your recovery code" : "Set up this device"))
                        .font(.title2.weight(.semibold))
                    if model.needsRecovery || model.recoveryCode != nil {
                        Text("Your private conversations and notes are encrypted. If you lose all approved devices and this code, we cannot recover that content.")
                    }
                }
                if model.needsRecovery {
                    Section("Recovery code") {
                        TextField("Paste your recovery code", text: $input, axis: .vertical).font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                        Button("Recover this device") { Task { await model.finishRecovery(code: input) } }.disabled(input.isEmpty || model.isBusy)
                    }
                } else if let code = model.recoveryCode {
                    Section {
                        Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled).privacySensitive()
                        Toggle("I saved this code somewhere safe", isOn: $saved)
                        Button("Continue") { Task { await model.finishRecovery() } }.disabled(!saved || model.isBusy)
                    }
                }
                if let issue = model.accountPreparationIssue {
                    Section {
                        Text(issue).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("account.preparationIssue")
                        Button("Try again") { Task { await model.retryAccountPreparation() } }
                            .disabled(model.isBusy).accessibilityIdentifier("account.retryPreparation")
                    }
                }
                if model.isBusy { ProgressView() }
            }.navigationTitle("Private library").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Sign out") { Task { await model.signOut() } }.accessibilityIdentifier("account.signOut")
                    }
                }
        }
    }
}

struct ImportPaperView: View {
    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var saving = false
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Paper link") {
                    TextField("arXiv link or ID", text: $input).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("import.reference")
                        .disabled(saving)
                    if let issue { Text(issue).font(.footnote).foregroundStyle(.red) }
                }
                if !model.canChangeLibrary {
                    Section { Text("Restore this device to save library changes.").font(.footnote).foregroundStyle(.secondary) }
                } else if !model.libraryHasSnapshot {
                    Section {
                        Text("Refresh your library before adding a paper.").font(.footnote).foregroundStyle(.secondary)
                        Button("Refresh library") { Task { await model.refreshLibrary() } }.disabled(model.libraryRefreshing)
                    }
                }
                Section {
                    Button {
                        saving = true; issue = nil
                        Task {
                            defer { saving = false }
                            do { try await model.importPaper(input); dismiss() }
                            catch is CancellationError { }
                            catch is ArxivReferenceError { issue = "Enter a valid arXiv link or paper ID." }
                            catch LibraryCommandError.targetBusy { issue = "This paper already has a pending change." }
                            catch { issue = "Couldn’t save this import. Your link is still here." }
                        }
                    } label: {
                        HStack { Text("Add paper"); if saving { Spacer(); ProgressView() } }
                    }.disabled(saving || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canBeginImport)
                        .accessibilityIdentifier("import.add")
                }
            }.navigationTitle("Add a paper").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() }.disabled(saving) } }
                .interactiveDismissDisabled(saving)
        }
    }
}

/// arXiv search results for the Library's "arXiv" segment. Adding stays in
/// search and appears as a pending import in the library.
struct DiscoveryList: View {
    @Bindable var model: ReaderModel
    @State private var issue: String?
    var body: some View {
        switch model.discoveryState {
        case .idle:
            ContentUnavailableView("Find papers", systemImage: "magnifyingglass",
                                   description: Text("Search arXiv by title, author, topic or ID, then add a paper to your library."))
                .accessibilityIdentifier("discover.idle")
        case .searching:
            VStack { Spacer(); ProgressView("Searching arXiv…"); Spacer() }.accessibilityIdentifier("discover.searching")
        case .failed(let message):
            ContentUnavailableView { Label("Couldn’t search", systemImage: "exclamationmark.magnifyingglass") }
                description: { Text(message) } actions: { Button("Try again") { model.runDiscovery() } }
                .accessibilityIdentifier("discover.failed")
        case .results:
            if model.discoveryResults.isEmpty {
                ContentUnavailableView("No papers found", systemImage: "magnifyingglass",
                                       description: Text("Try fewer or different words, an author, or an arXiv ID."))
            } else {
                List {
                    if let issue { Text(issue).font(.footnote).foregroundStyle(.secondary) }
                    ForEach(model.discoveryResults) { result in DiscoveryRow(model: model, result: result, issue: $issue) }
                }.listStyle(.plain)
            }
        }
    }

}

/// One arXiv paper (search or Feed) with an Add action that stays in place.
struct DiscoveryRow: View {
    @Bindable var model: ReaderModel
    let result: DiscoveryResult
    @Binding var issue: String?
    @State private var adding = false
    var body: some View {
        let inLibrary = model.librarySourceIDs.contains(result.sourceID)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(result.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                if !result.authors.isEmpty {
                    Text(result.authors.prefix(8).joined(separator: ", ") + (result.authors.count > 8 ? " et al." : ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let abstract = result.abstract { Text(abstract).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                Text(([result.year.map(String.init)].compactMap { $0 } + ["arXiv \(result.sourceID)v\(result.revision)"] + result.categories.prefix(3))
                    .joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if inLibrary {
                Image(systemName: "checkmark").foregroundStyle(.secondary).frame(minWidth: 44, minHeight: 44).accessibilityLabel("In library")
            } else if adding {
                ProgressView().frame(minWidth: 44, minHeight: 44)
            } else {
                Button("Add") {
                    adding = true; issue = nil
                    Task {
                        do { try await model.addDiscovered(result) }
                        catch { issue = "Couldn’t add “\(result.title)”. Try again." }
                        adding = false
                    }
                }
                .buttonStyle(.bordered).disabled(!model.canBeginImport)
                .accessibilityIdentifier("discover.add.\(result.sourceID)")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("discover.result.\(result.sourceID)")
    }
}

/// Open-source notices for components shipped in the app. Reader bundles carry
/// their own NOTICE (renderer libraries and per-paper attribution).
struct AcknowledgementsView: View {
    private let items: [(String, String, String)] = [
        ("SwiftMath", "Native math typesetting in chat answers.", "MIT License · © 2023 Computer Inspirations"),
        ("Latin Modern Math", "Math font used for chat formulas (bundled by SwiftMath).", "GUST Font License"),
        ("Mermaid", "Draws diagrams from answers on this device (includes DOMPurify, d3 and other bundled libraries).", "MIT License · DOMPurify: Apache 2.0 / MPL 2.0"),
        ("Mathpix Markdown, MathJax, markdown-it", "Used on the server to build equation-aware readers; each reader includes its NOTICE.", "MIT / Apache 2.0"),
        ("arXiv", "Paper metadata and PDFs. Papers keep their authors' licenses; shared conversions are limited to CC BY and CC0.", "arXiv API terms"),
    ]
    var body: some View {
        List(items, id: \.0) { item in
            VStack(alignment: .leading, spacing: 4) {
                Text(item.0).font(.headline)
                Text(item.1).font(.subheadline)
                Text(item.2).font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 2)
        }.navigationTitle("Acknowledgements").navigationBarTitleDisplayMode(.inline)
    }
}

/// Deleting an account is permanent: explain what goes and what stays, then
/// require typing DELETE.
struct DeleteAccountView: View {
    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var deleting = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section {
                    Text("This permanently deletes your account:")
                    Label("Your library, conversations, notes and diagrams, and the files of papers converted privately for you", systemImage: "books.vertical")
                    Label("Your support reports and screenshots", systemImage: "exclamationmark.bubble")
                    Label("This device’s copy; other devices are signed out and your recovery code stops working", systemImage: "iphone")
                }
                Section {
                    Text("Unused credits are forfeited. Records of credits, AI usage and which papers were converted for you are kept without your email or name, for accounting.")
                    Text("An App Store subscription isn’t cancelled by deleting your account; manage it in Settings › Apple Account › Subscriptions.")
                }.font(.footnote).foregroundStyle(.secondary)
                Section("Type DELETE to confirm") {
                    TextField("DELETE", text: $confirmation).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .accessibilityIdentifier("account.delete.confirmation")
                    if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }
                    Button(role: .destructive) {
                        deleting = true; failure = nil
                        Task {
                            do {
                                try await model.deleteAccount()
                                dismiss()
                                // Present after the sheet has gone.
                                try? await Task.sleep(for: .milliseconds(500))
                                model.accountDeletedNotice = true
                            }
                            catch { failure = (error as? LocalizedError)?.errorDescription ?? "The account couldn’t be deleted. Try again." }
                            deleting = false
                        }
                    } label: {
                        HStack { Text("Delete account"); if deleting { Spacer(); ProgressView() } }
                    }
                    .disabled(confirmation != "DELETE" || deleting)
                    .accessibilityIdentifier("account.delete.confirm")
                    .id("account.delete.confirm")
                }
            }
            // Bring the button above the keyboard once the confirmation matches.
            .onChange(of: confirmation) { _, typed in
                if typed == "DELETE" { withAnimation { proxy.scrollTo("account.delete.confirm", anchor: .bottom) } }
            }
            }
            .navigationTitle("Delete account").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(deleting) } }
            .interactiveDismissDisabled(deleting)
        }
    }
}
