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
            // The Mac window is always the wide layout (its minimum width fits the panes).
            if geometry.size.width >= 850 || Platform.isMac { wideLayout(width: geometry.size.width) }
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
                                } label: { TabBarItem(tab: tab, selected: model.tab == tab) }
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
        #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && FIXTURE_HOST
        .overlay(alignment: .topTrailing) {
            if OfflineResourceProbe.shared.mode != nil { OfflineResourceStatusView() }
        }
        #endif
        .overlay {
            // Hides the paper in the iOS app switcher. A Mac window stays visible while another app is active.
            if scenePhase != .active && !Platform.isMac {
                ZStack {
                    Color(uiColor: .systemBackground).ignoresSafeArea()
                    Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .sheet(isPresented: signInPresentation, onDismiss: { model.authenticationSheetDismissed() }) {
            if let presentationID = model.signInPresentationID {
                AuthenticationView(model: model, presentationID: presentationID).id(presentationID).macSheetKeys()
            }
        }
        .sheet(isPresented: $model.showRecovery) { RecoveryView(model: model).interactiveDismissDisabled() }
        .sheet(item: consentPresentation) { prompt in ChatConsentView(model: model, prompt: prompt).interactiveDismissDisabled() }
        .sheet(isPresented: $model.showAllChats) { HistoryView(model: model, diagrams: false).macSheetKeys() }
        .sheet(isPresented: $model.showDiagrams) { HistoryView(model: model, diagrams: true).macSheetKeys() }
        // At the root: deletion signs out, which leaves Settings.
        .alert("Account deleted", isPresented: $model.accountDeletedNotice) { Button("OK") {} } message: {
            Text("Your account and its data were deleted from our servers and this device.")
        }
        .sheet(isPresented: $model.showStore) { CreditsStoreView(model: model).macSheetKeys() }
        .sheet(item: $model.presentedDiagram) { presented in
            if let diagram = model.diagram(presented.id) { DiagramSheet(diagram: diagram).macSheetKeys() }
        }
        .sheet(isPresented: $model.showReport, onDismiss: {
            model.reportScreenshot = nil
            if model.showReportsAfterComposer { model.showReportsAfterComposer = false; model.showReports = true }
        }) { ReportComposer(model: model).macSheetKeys() }
        .sheet(isPresented: $model.showReports) { if let service = model.support { ReportsView(service: service).macSheetKeys() } }
        .alert("Gradstep", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        #if INTERNAL
        .modifier(SessionCaptureHooks(model: model))
        #endif
        .onChange(of: scenePhase) { _, phase in
            Task {
                model.flushReadingActivity()
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
            // On the Mac the view switch and Settings are in the window's toolbar (MacWindowConfiguration).
            if !Platform.isMac {
                HStack {
                    Label("Gradstep", systemImage: "books.vertical").font(.headline)
                    Spacer()
                    Picker("View", selection: $model.wideMode) {
                        ForEach(WideMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 560)
                    Button { model.tab = .settings } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }.accessibilityLabel("Settings")
                }.padding(.horizontal, 18).padding(.vertical, 12)
                Divider()
            }
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
        .onChange(of: model.wideMode) { _, mode in model.showWideMode(mode) }
        #if targetEnvironment(macCatalyst)
        .background(MacWindowConfiguration(model: model, mode: model.wideMode, settingsShown: model.tab == .settings))
        #endif
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// For the menu's "Table"/"Detailed rows" label; the content measures its own width.
    @State private var containerWidth: CGFloat = 0
    @State private var searchFocused = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Status (design audit F4): one banner style, scrolling with a list; above other content.
                if model.searchExternal || model.libraryRows.isEmpty { banners(inset: true) }
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
                } else if tableShown {
                    // Owner request 2026-10-06: the same table on every size, with the columns that fit.
                    LibraryPaperTable(model: model) {
                        banners(inset: false).listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 8, leading: DesignMetrics.margin, bottom: 4, trailing: DesignMetrics.margin))
                    }
                    .refreshable { await model.refreshLibrary() }
                    .overlay(alignment: .top) { updatingIndicator }
                } else {
                    // Detailed rows are also the table's form at accessibility text sizes.
                    libraryList(detailed: model.libraryLayout != .list)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
            // Owner decision (2026-10-05, build 8 follow-up): one header row instead of the navigation
            // bar's title row and search drawer. At rest: search, Add and one options menu. While
            // searching: Cancel, and the Library/arXiv switch under the field.
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: model.searchExternal) { _, external in
                if external, model.discoveryState == .idle, !model.discoveryQuery.trimmingCharacters(in: .whitespaces).isEmpty { model.runDiscovery() }
            }
            // Mac menu bar: Edit › Search Library (⌘F) / Search arXiv (⌥⌘F).
            .onChange(of: MacCommandRequests.shared.librarySearch, initial: true) { _, request in
                if request != nil { MacCommandRequests.shared.librarySearch = nil; searchFocused = true }
            }
            .sheet(isPresented: $model.showImport) { ImportPaperView(model: model) }
            .sheet(isPresented: $model.showLibraryChanges) { LibraryChangesView(model: model).macSheetKeys() }
        }
    }

    private var searching: Bool { searchFocused || !model.searchQuery.isEmpty || model.searchExternal }
    /// The table spans the pane; everything else sits in the readable column. At accessibility text sizes the
    /// table shows as detailed rows.
    private var tableShown: Bool {
        model.libraryLayout == .table && !model.searchExternal && !dynamicTypeSize.isAccessibilitySize
    }

    /// Only states the reader can act on; none while browsing normally.
    @ViewBuilder private func banners(inset: Bool) -> some View {
        let signIn = !model.isSignedIn && !searching
        let issue = model.searchExternal ? nil : model.libraryIssue
        let pending = !model.searchExternal && (!model.libraryCommands.isEmpty || model.libraryCommandIssue != nil)
        let offline = model.searchExternal ? nil : model.offlineCacheIssue
        if signIn || issue != nil || pending || offline != nil {
            VStack(spacing: 8) {
                if signIn {
                    StatusBannerLink(tone: .info, systemImage: "lock.icloud", message: "Sign in to sync") { model.openSignIn() }
                        .accessibilityIdentifier("library.signIn")
                }
                if let issue {
                    StatusBanner(tone: .problem, systemImage: "exclamationmark.arrow.triangle.2.circlepath", message: issue) {
                        Button("Retry") { Task { await model.refreshLibrary() } }.disabled(model.libraryRefreshing)
                    }.accessibilityIdentifier("library.refreshIssue")
                }
                if pending {
                    StatusBanner(tone: model.libraryCommandIssue == nil ? .info : .problem, systemImage: "arrow.triangle.2.circlepath",
                                 message: model.libraryCommandIssue ?? "\(model.libraryCommands.count) change\(model.libraryCommands.count == 1 ? "" : "s") waiting to sync") {
                        if !model.libraryCommands.isEmpty {
                            Button("Review") { model.showLibraryChanges = true }.accessibilityIdentifier("library.pendingChanges")
                        }
                    }
                }
                if let offline {
                    StatusBanner(tone: .problem, systemImage: "arrow.down.circle", message: offline).accessibilityIdentifier("library.offlineIssue")
                }
            }
            .modifier(BannerInset(inset: inset, fullWidth: tableShown)).padding(.vertical, inset ? 8 : 0)
        }
    }


    /// The selected paper is highlighted only where it is shown beside the list (iPad Browse).
    private var highlightsSelection: Bool { model.wideMode == .browse && Platform.isLargeScreen }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                LibrarySearchField(text: $model.searchQuery, prompt: model.searchExternal ? "Search arXiv" : "Search your library",
                                   focused: $searchFocused) { if model.searchExternal { model.runDiscovery() } }
                    .frame(height: DesignMetrics.headerControl)
                if searching {
                    Button("Cancel") {
                        model.searchExternal = false; model.libraryQuery = ""; model.discoveryQuery = ""; searchFocused = false
                    }.accessibilityIdentifier("library.search.cancel")
                } else {
                    Button {
                        if model.librarySignInRequired { model.openSignIn() } else { model.showImport = true }
                    } label: { HeaderButtonLabel(systemImage: "plus") }.buttonStyle(.plain).accessibilityLabel("Add a paper")
                    optionsMenu
                }
            }
            if searching {
                Picker("Search", selection: $model.searchExternal) { Text("Library").tag(false); Text("arXiv").tag(true) }
                    .pickerStyle(.segmented)
            }
        }
        .modifier(HeaderWidth(fullWidth: tableShown))
        .padding(.top, 2).padding(.bottom, 8)
        .background(Color(uiColor: .systemBackground))
        .animation(.snappy(duration: 0.2), value: searching)
    }

    /// Every Library option behind one button (design audit F3): how the list looks, as submenus that
    /// show the current choice, then where else to go, then reporting.
    private var optionsMenu: some View {
        Menu {
            Section {
                Menu {
                    Picker("View as", selection: $model.libraryLayout) {
                        ForEach(LibraryLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.inline)
                } label: {
                    Label { Text("View as"); Text(model.libraryLayout.title) } icon: { menuIcon("rectangle.grid.1x2") }
                }
                Menu {
                    Picker("Sort by", selection: sortField) {
                        ForEach(sortFields(table: tableShown), id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.inline)
                } label: {
                    Label { Text("Sort by"); Text(model.librarySort.field.label) } icon: { menuIcon("arrow.up.arrow.down") }
                }
                // Topics is a column in the table, a line in the rows.
                Menu {
                    if model.libraryLayout == .list { Toggle("Abstracts", isOn: $model.showAbstracts) }
                    Toggle("Topics", isOn: $model.showTopics)
                    Toggle("Archived papers", isOn: $model.showArchivedPapers)
                } label: { Label { Text("Show") } icon: { menuIcon("eye") } }
            }
            Section {
                MenuRow("All chats", systemImage: "bubble.left.and.bubble.right") { model.showAllChats = true }
                MenuRow("All diagrams", systemImage: "square.stack.3d.up") { model.showDiagrams = true }
                MenuRow("Refresh library", systemImage: "arrow.clockwise") { Task { await model.refreshLibrary() } }
                    .disabled(!model.isSignedIn || model.libraryRefreshing)
            }
            Section {
                MenuRow("Report this screen", systemImage: "ladybug") { model.beginReport(afterMenu: true) }
            }
        } label: { HeaderButtonLabel(systemImage: "ellipsis") }
        .buttonStyle(.plain).accessibilityLabel("Library options")
    }

    /// Choosing a field from the menu uses its natural direction; table headers can reverse it.
    private var sortField: Binding<LibrarySearchSort.Field> {
        Binding(get: { model.librarySort.field }, set: { model.librarySort = LibrarySearchSort(field: $0) })
    }

    private func sortFields(table: Bool) -> [LibrarySearchSort.Field] {
        // Authors is a table column's sort; it stays listed while it is the current order.
        LibrarySearchSort.Field.allCases.filter { $0 != .authors || table || model.librarySort.field == .authors }
    }

    @ViewBuilder private var updatingIndicator: some View {
        if model.librarySearchPending { ProgressView("Updating results…").padding(8).allowsHitTesting(false) }
    }

    /// The List layout (unchanged), and detailed rows: the narrow form of the table layout.
    private func libraryList(detailed: Bool) -> some View {
        List {
            banners(inset: false).listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: DesignMetrics.margin, bottom: 4, trailing: DesignMetrics.margin))
            ForEach(model.libraryRows) { entry in
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
                    Button { model.select(paper) } label: {
                        if detailed {
                            DetailedPaperRow(facts: model.libraryFacts(for: entry), selected: highlightsSelection && model.selectedPaper?.id == paper.id,
                                             offlineStatus: model.offlineStatus(for: paper), showTopics: model.showTopics)
                        } else {
                            PaperRow(paper: paper, selected: highlightsSelection && model.selectedPaper?.id == paper.id, offlineStatus: model.offlineStatus(for: paper), showAbstract: model.showAbstracts, showTopics: model.showTopics)
                        }
                    }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("paper.\(paper.id.wire)")
                        .contextMenu { LibraryRowActions(model: model, entry: entry) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) { LibrarySwipeActions(model: model, entry: entry) }
                case .pending(let item):
                    Group {
                        if detailed {
                            DetailedImportRow(item: item, facts: model.libraryFacts(for: entry), showTopics: model.showTopics,
                                              getCredits: { model.showStore = true })
                        } else {
                            ImportRow(item: item, showAbstract: model.showAbstracts, showTopics: model.showTopics,
                                      stepSince: model.importSteps.timing(of: item)?.since, getCredits: { model.showStore = true })
                        }
                    }
                        // A container, so the row's own buttons (Get credits) keep their identifiers.
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("import.\(item.id.wire)")
                        .contextMenu { LibraryRowActions(model: model, entry: entry) }
                        // Cancel (and retry a failed import) by swiping, so a slow import is easy to stop.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) { LibrarySwipeActions(model: model, entry: entry) }
                case .queued(let command):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(command.display ?? "Queued paper").font(.headline)
                        Text(command.libraryStatus).font(.footnote).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("import.\(command.id.wire)")
                        .contextMenu { LibraryRowActions(model: model, entry: entry) }
                }
            }.listRowInsets(EdgeInsets(top: 12, leading: DesignMetrics.margin, bottom: 12, trailing: DesignMetrics.margin))
                .macRowHover()
            }
        }.listStyle(.plain).refreshable { await model.refreshLibrary() }
            .readableScrollColumn(width: containerWidth)
            .overlay(alignment: .top) { updatingIndicator }
    }
}

struct ImportRow: View {
    let item: LibraryImportRecord
    var showAbstract = true
    var showTopics = true
    /// When this device first saw the import on its current step (shown as how long the step has run).
    var stepSince: Date? = nil
    /// Offered when the conversion failed for lack of credits.
    var getCredits: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var active: Bool { item.isActive }
    var body: some View {
        // Design audit F6: title, then authors (secondary), then abstract and details (tertiary).
        VStack(alignment: .leading, spacing: 4) {
            Text(item.metadata?.title ?? LibrarySource.placeholderTitle(sourceID: item.sourceID)).font(.headline).fixedSize(horizontal: false, vertical: true)
            if let authors = item.metadata?.authors, !authors.isEmpty {
                Text(authors.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
            if showAbstract, let abstract = item.metadata?.abstract, !abstract.isEmpty {
                Text(abstract).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            let year = item.metadata?.publishedAt.map { String($0.prefix(4)) }
            let topics = showTopics ? ArxivTopics.names(for: item.metadata?.categories ?? [], limit: 3) : []
            let revision = LibrarySource.badge(sourceID: item.sourceID, revision: item.sourceRevision ?? item.requestedRevision).map { [$0] } ?? []
            let metadata = (year.map { [$0] } ?? []) + revision + topics
            if !metadata.isEmpty { Text(metadata.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
            HStack(spacing: 6) {
                if active { ProgressView().controlSize(.small).accessibilityHidden(true) }
                ImportStatusText(item: item, since: stepSince).font(.footnote).foregroundStyle(.secondary)
                if item.phase == .failed, item.errorCode == .insufficientCredits, let getCredits {
                    Button("Get credits", action: getCredits).font(.footnote.weight(.semibold)).buttonStyle(.borderless)
                        .accessibilityIdentifier("import.getCredits")
                }
                if !active, let url = URL(string: item.sourceURL) {
                    Spacer(minLength: 8)
                    Link("View source", destination: url).font(.footnote.weight(.semibold)).foregroundStyle(.tint)
                }
            }.padding(.top, 2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An import's status line. While it is in progress, how long the current step has run follows quietly
/// ("Downloading PDF · 1 min"), and past three minutes "Taking longer than usual". It changes once a minute,
/// without animation; VoiceOver reads the step and the time.
struct ImportStatusText: View {
    let item: LibraryImportRecord
    let since: Date?
    var short = false
    var body: some View {
        if let since, let step = item.step {
            TimelineView(.periodic(from: since, by: 60)) { context in
                let elapsed = ImportStepElapsed(since: since, now: context.date)
                Group {
                    if let time = elapsed.label {
                        // One line when it fits; otherwise the time on a line of its own, never broken mid-phrase.
                        ViewThatFits(in: .horizontal) {
                            Text(step.status(short: short, elapsed: elapsed))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(short ? step.shortTitle : step.title)
                                Text(time)
                            }
                        }
                    } else {
                        Text(step.label(short: short))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(step.spokenStatus(elapsed: elapsed))
            }
        } else {
            Text(short ? item.libraryShortStatus : item.libraryStatus)
        }
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(paper.title).font(.headline).foregroundStyle(selected ? Color.accentColor : .primary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if offlineStatus == .available { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).accessibilityLabel("Available offline") }
                else if offlineStatus == .unavailable { Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).accessibilityLabel("Downloaded copy unavailable") }
            }
            if !paper.authors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text(paper.authors).font(.subheadline).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1) }
            if showAbstract && !paper.abstract.isEmpty { Text(paper.abstract).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
            let source = LibrarySource.badge(sourceID: paper.sourceID, revision: paper.sourceRevision).map { [$0] } ?? []
            let metadata = (paper.archived ? ["Archived"] : []) + (paper.year.map { [String($0)] } ?? []) + source
            let topics = showTopics ? ArxivTopics.names(for: paper.keywords, limit: 3) : []
            if !(metadata + topics).isEmpty { Text((metadata + topics).joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

struct FeedView: View {
    @Bindable var model: ReaderModel
    @State private var issue: String?
    @State private var width: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var isFailed: Bool { if case .failed = model.feedState { true } else { false } }
    /// The table spans the pane (its header too); at accessibility text sizes it shows as the list.
    private var tableShown: Bool {
        model.feedLayout == .table && !dynamicTypeSize.isAccessibilitySize && model.feedState == .loaded && !model.feedResults.isEmpty
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch model.feedState {
                case .idle, .loading:
                    Spacer(); ProgressView("Finding new papers…"); Spacer()
                case .failed(let message):
                    ContentUnavailableView { Label("Feed unavailable", systemImage: "dot.radiowaves.up.forward") }
                        description: { Text(message) }
                        actions: {
                            if model.librarySignInRequired {
                                Button { model.openSignIn() } label: { ProminentLabel(title: "Sign in") }.buttonStyle(.borderedProminent)
                            } else { Button("Try again") { model.loadFeed() } }
                        }
                case .loaded:
                    if model.feedResults.isEmpty {
                        ContentUnavailableView("No new papers", systemImage: "dot.radiowaves.up.forward", description: Text("Check back later or pick another topic."))
                    } else if tableShown {
                        FeedTable(model: model, issue: $issue).refreshable { model.loadFeed() }
                    } else {
                        List {
                            if let issue {
                                StatusBanner(tone: .problem, systemImage: "exclamationmark.circle", message: issue).listRowSeparator(.hidden)
                            }
                            ForEach(model.feedResults) { result in
                                DiscoveryRow(model: model, result: result, issue: $issue, showsIdentifier: false)
                                    .listRowInsets(EdgeInsets(top: 12, leading: DesignMetrics.margin, bottom: 12, trailing: DesignMetrics.margin))
                            }
                        }
                        .listStyle(.plain).refreshable { model.loadFeed() }
                        .readableScrollColumn(width: width)
                    }
                }
            }
            // Owner feedback (2026-10-06): the Feed's top used space like the Library's used to. Same
            // header as the Library: one row — the topics (the feed's filter) and the "…" menu.
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .toolbar(.hidden, for: .navigationBar)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .task { if model.feedState == .idle || (model.feedState != .loading && model.feedResults.isEmpty && !model.librarySignInRequired) { model.loadFeed() } }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if isFailed {
                Text("Feed").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.feedCategories, id: \.self) { category in
                            ChipButton(title: ArxivTopics.name(for: category),
                                       selected: (model.feedCategory ?? model.feedCategories.first) == category) {
                                model.selectFeedCategory(category)
                            }.accessibilityIdentifier("feed.topic.\(category)")
                        }
                    }
                }
                // Chips that scroll past the edge fade out instead of sliding under the menu button.
                .mask(HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 24)
                })
            }
            Menu {
                Section {
                    Menu {
                        Picker("View as", selection: $model.feedLayout) {
                            ForEach(FeedLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.inline)
                    } label: {
                        Label { Text("View as"); Text(model.feedLayout.title) } icon: { menuIcon("rectangle.grid.1x2") }
                    }
                }
                Section {
                    MenuRow("Refresh feed", systemImage: "arrow.clockwise") { model.loadFeed() }.disabled(model.librarySignInRequired)
                }
                Section { MenuRow("Report this screen", systemImage: "ladybug") { model.beginReport(afterMenu: true) } }
            } label: { HeaderButtonLabel(systemImage: "ellipsis") }
            .buttonStyle(.plain).accessibilityLabel("Feed options")
        }
        .modifier(HeaderWidth(fullWidth: tableShown)).padding(.top, 2).padding(.bottom, 8)
        .background(Color(uiColor: .systemBackground))
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
                        // Design audit F4: the app's one banner style, above the message box.
                        StatusBanner(tone: .problem, systemImage: "exclamationmark.circle", message: issue.message, actionsBelow: true,
                                     messageID: "chat.answerIssue") {
                            if issue.code == "insufficient_credits" {
                                Button("Get credits") { model.showStore = true }.accessibilityIdentifier("chat.getCredits")
                            }
                            if issue.retryable {
                                Button(issue.actionTitle) { model.retryAnswer() }.accessibilityIdentifier("chat.retryAnswer")
                            }
                        }
                        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                        .readableColumn().padding(.top, 8)
                    }
                    if let issue = model.chatDraftIssue {
                        HStack {
                            Text(issue).font(.caption)
                            Button("Retry") { model.retryDraftSave() }.font(.caption.weight(.semibold))
                        }.padding(.horizontal, 16).accessibilityIdentifier("chat.draftIssue")
                    } else if model.draftsArePersistent && !model.chatInput.isEmpty {
                        Text(model.chatDraftStatusText).font(.caption2).foregroundStyle(.tertiary)
                            .accessibilityIdentifier("chat.draftStatus")
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("Ask a question…", text: $model.chatInput, axis: .vertical)
                            .focused($composerFocused).accessibilityIdentifier("chat.composer")
                            .lineLimit(1...(compact ? 2 : 6)).fixedSize(horizontal: false, vertical: true)
                            .padding(12).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        // The software keyboard covers the tab bar (iPhone and compact iPad): a visible way back.
                        if composerFocused && !Platform.isMac {
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
                                .disabled(sendDisabled).accessibilityLabel("Send").accessibilityIdentifier("chat.send")
                                // Mac: ⌘Return sends; Return starts a new line, as on iPad (and input methods keep Return).
                                .macKeyboardShortcut(.return, modifiers: .command)
                        }
                    }.readableColumn().padding(.vertical, 10)
                    // Design audit F8: sync status only when something needs attention.
                    if model.isGenerating { ProgressView("Saving…").font(.caption).padding(.bottom, 5) }
                    else if let issue = model.syncIssue { Text(issue).font(.caption2).dynamicTypeSize(...DynamicTypeSize.xxxLarge).foregroundStyle(.secondary).padding(.bottom, 5) }
                }
            }
            .navigationTitle(model.chatTitle).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { composerFocused = false; model.showAllChats = true } label: { Image(systemName: "clock.arrow.circlepath") }.accessibilityLabel("Chat history") }
                // Design audit F8: the paper a conversation is about sits under its title (one tap back).
                ToolbarItem(placement: .principal) { titleView }
                ToolbarItem(placement: .topBarTrailing) { Button { model.newChat(general: model.generalChat); composerFocused = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("New chat") }
                // Separate circles, like the Library's + and … (iOS 26 groups adjacent items otherwise).
                if #available(iOS 26.0, *) { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
                ToolbarItem(placement: .topBarTrailing) { optionsMenu }
            }
        }
    }

    private var sendDisabled: Bool {
        model.isGenerating || model.isDiscardingDraft || (!model.generalChat && !model.canUsePaperChat) || !model.chatContextComplete
            || model.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func contextPicker(compact: Bool) -> some View {
        Picker("Context", selection: Binding(get: { model.generalChat }, set: { if $0 || model.canUsePaperChat { model.generalChat = $0 } })) {
            Text(compact ? "Paper" : "Paper chat").accessibilityLabel("Paper chat").tag(false).disabled(!model.canUsePaperChat)
            Text(compact ? "General" : "General chat").accessibilityLabel("General chat").tag(true)
        }.pickerStyle(.segmented)
    }

    @ViewBuilder private func contextHeader(compact: Bool) -> some View {
        VStack(spacing: 6) {
            contextPicker(compact: compact)
            if !model.generalChat, model.chatPaper == nil, model.canUsePaperChat {
                Text("Paper unavailable in this library").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .readableColumn().padding(.vertical, compact ? 4 : 8)
    }

    /// iPad Reader layout: the paper is already open beside the chat.
    private var besidePaper: Bool { Platform.isLargeScreen && model.wideMode == .reader && model.tab != .chat }

    /// Conversation title, and under it the paper it is about (tap to return to the paper).
    private var titleView: some View {
        VStack(spacing: 1) {
            Text(model.chatTitle).font(.headline).lineLimit(1)
            if !model.generalChat, let paper = model.chatPaper, !besidePaper {
                Button { composerFocused = false; model.select(paper) } label: {
                    Label(paper.title, systemImage: "doc.text").labelStyle(.titleAndIcon).font(.caption).lineLimit(1)
                }.buttonStyle(.plain).foregroundStyle(.tint)
                    .accessibilityLabel("Return to paper: \(paper.title)").accessibilityIdentifier("chat.returnToPaper")
                    .accessibilityShowsLargeContentViewer { Label(paper.title, systemImage: "doc.text") }
            }
        }.frame(maxWidth: 420)
    }

    /// Design audit F2: the same "…" as every screen — text size, diagrams, reporting.
    private var optionsMenu: some View {
        Menu {
            ControlGroup {
                MenuRow("Smaller text", systemImage: "textformat.size.smaller") { model.chatFontSize = max(13, model.chatFontSize - 1) }
                MenuRow("Larger text", systemImage: "textformat.size.larger") { model.chatFontSize = min(26, model.chatFontSize + 1) }
            }.controlGroupStyle(.compactMenu)
            Section {
                MenuRow("All chats", systemImage: "bubble.left.and.bubble.right") { composerFocused = false; model.showAllChats = true }
                MenuRow("All diagrams", systemImage: "square.stack.3d.up") { composerFocused = false; model.showDiagrams = true }
            }
            Section {
                MenuRow("Report this screen", systemImage: "ladybug") { composerFocused = false; model.beginReport(afterMenu: true) }
            }
        } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Chat options")
    }
}

struct SettingsView: View {
    @Bindable var model: ReaderModel
    var dismissSettings: (() -> Void)? = nil
    @State private var showDeleteAccount = false
    @State private var width: CGFloat = 0
    private static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
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
                        Button("Delete account…", role: .destructive) { showDeleteAccount = true }.accessibilityIdentifier("account.delete")
                    }
                    else { Button("Sign in or create an account") { model.openSignIn() }.accessibilityIdentifier("account.signIn") }
                } header: { Text("Account") } footer: {
                    if model.isSignedIn { Text("Encrypted pending work stays on this device for your next sign-in.") }
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
                    sizeSlider("Paper text size", value: $model.paperFontSize, range: 14...26)
                    sizeSlider("Chat text size", value: $model.chatFontSize, range: 14...24)
                }
                // Design audit F11: rows that open something look alike (title + chevron); actions are tinted.
                Section("Your research") {
                    openRow("All chats") { model.showAllChats = true }
                    openRow("All diagrams") { model.showDiagrams = true }
                    Button("Sync now") { Task { await model.synchronize(reportErrors: true) } }.disabled(!model.isSignedIn)
                }
                Section("Testing") {
                    #if INTERNAL
                    SessionCaptureSettings()
                    #endif
                    Button("Report this screen") { model.beginReport() }
                    openRow("My reports") { model.showReports = true }.disabled(model.support == nil)
                    Button("Open reader sample") { model.openSample() }
                }
                Section("About") {
                    NavigationLink("Privacy & data") { PrivacyView() }
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                    LabeledContent("Version", value: Self.version)
                    LabeledContent("Environment", value: "Private beta · staging")
                }
            }
            .readableScrollColumn(width: width)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                // On the Form: a sheet attached inside a Form row doesn't present reliably.
                .sheet(isPresented: $showDeleteAccount) { DeleteAccountView(model: model) }
                .task(id: model.isSignedIn) { if model.isSignedIn { await model.refreshCreditBalance(); await model.refreshStoreSummary() } }
                .toolbar { if let dismissSettings { ToolbarItem(placement: .confirmationAction) { Button("Done", action: dismissSettings) } } }
        }
    }

    private func sizeSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Slider(value: value, in: range, step: 1) { Text(title) } minimumValueLabel: {
                Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }

    /// A row that opens a sheet, drawn like a navigation row.
    private func openRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
            }.contentShape(Rectangle())
        }.tint(.primary)
    }
}

struct PrivacyView: View {
    var body: some View {
        List {
            Section {
                Text("Private conversations and notes are encrypted with keys held on your devices. An approved device or your recovery code is needed to restore them.")
            } header: { Text("Your notes and conversations") }
            Section {
                Text("AI answers send your question, any selected passage, earlier messages in that conversation and, for paper chats, the paper’s text to Anthropic. Claude may search the web for some questions; those searches go to Tavily, a search service, or Anthropic’s search provider as a backup.")
            } header: { Text("AI answers") }
            Section {
                Text("Private PDF uploads and reports you submit are accessible to the services that process them. Papers added from the web are fetched by our server and converted privately for your account.")
            } header: { Text("Papers and reports") }
        }.font(.subheadline).navigationTitle("Privacy & data").navigationBarTitleDisplayMode(.inline)
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
                            // Design audit F16: a conversation row says what it is about.
                            let paper = event.payload.documentID.flatMap { document in model.papers.first { $0.id == document } }
                            Button { model.openConversation(id); dismiss() } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(event.payload.text ?? "Untitled").foregroundStyle(.primary).lineLimit(2)
                                        Text(paper.map { "Paper chat · \($0.title)" } ?? (event.payload.documentID == nil ? "General chat" : "Paper chat"))
                                            .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
                                }.contentShape(Rectangle())
                            }.tint(.primary).accessibilityLabel(event.payload.text ?? "Untitled")
                        }
                    }
                    ForEach(savedDiagrams, id: \.id) { saved in
                        NavigationLink(saved.diagram.title) { DiagramDetail(diagram: saved.diagram) }
                            .accessibilityIdentifier("diagram.\(saved.id.wire)")
                    }
                } header: { if !drafts.isEmpty { Text("Saved conversations") } }
            }.overlay { if entities.isEmpty && savedDiagrams.isEmpty && drafts.isEmpty { ContentUnavailableView(diagrams ? "No diagrams yet" : "No conversations yet", systemImage: diagrams ? "square.stack.3d.up" : "bubble.left.and.bubble.right") } }
                .navigationTitle(diagrams ? "All diagrams" : "All chats").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}

struct RecoveryView: View {
    @Bindable var model: ReaderModel
    @State private var input = ""
    @State private var saved = false
    @State private var anchor: UIWindow?
    @State private var passwords: PasswordsState = .idle
    private enum PasswordsState: Equatable { case idle, working, saved, failed(String) }

    private func saveToPasswords(_ code: String) {
        guard let anchor, passwords != .working else { return }
        passwords = .working
        Task {
            do {
                try await RecoveryPasswords.save(code: code, account: RecoveryPasswords.account(email: model.email), anchor: anchor)
                passwords = .saved; saved = true
            } catch RecoveryPasswords.Failure.cancelled {
                passwords = .idle
            } catch {
                passwords = .failed("Couldn’t save to Passwords. Copy the code and keep it somewhere safe instead.")
            }
        }
    }

    private func fillFromPasswords() {
        guard let anchor, passwords != .working else { return }
        passwords = .working
        Task {
            do { input = try await RecoveryPasswords.request(anchor: anchor); passwords = .idle }
            catch { passwords = .failed("No saved recovery code was filled. You can paste it instead.") }
        }
    }

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
                            .textContentType(.password).accessibilityIdentifier("recovery.input")
                        Button { fillFromPasswords() } label: { Label("Use code saved in Passwords", systemImage: "key.fill") }
                            .disabled(anchor == nil || passwords == .working || model.isBusy).accessibilityIdentifier("recovery.fromPasswords")
                        if case .failed(let message) = passwords { Text(message).font(.footnote).foregroundStyle(.secondary) }
                        Button("Recover this device") { Task { await model.finishRecovery(code: input) } }.disabled(input.isEmpty || model.isBusy)
                    }
                } else if let code = model.recoveryCode {
                    Section {
                        Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled).privacySensitive()
                            .accessibilityIdentifier("recovery.code")
                        if passwords == .saved {
                            Label("Saved in Passwords under gradstep.ai", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                .accessibilityIdentifier("recovery.savedToPasswords")
                        } else {
                            Button { saveToPasswords(code) } label: { Label("Save to Passwords", systemImage: "key.fill") }
                                .disabled(anchor == nil || passwords == .working).accessibilityIdentifier("recovery.saveToPasswords")
                        }
                        if case .failed(let message) = passwords { Text(message).font(.footnote).foregroundStyle(.secondary) }
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
            }.background { AuthenticationWindowReader { anchor = $0 }.frame(width: 0, height: 0) }
                .navigationTitle("Private library").navigationBarTitleDisplayMode(.inline)
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

    private func add() {
        saving = true; issue = nil
        Task {
            defer { saving = false }
            do { try await model.importPaper(input); dismiss() }
            catch is CancellationError { }
            catch is ArxivReferenceError { issue = "Enter a valid arXiv link or paper ID." }
            catch LibraryCommandError.targetBusy { issue = "This paper already has a pending change." }
            catch { issue = "Couldn’t save this import. Your link is still here." }
        }
    }
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
                if model.librarySignInRequired {
                    Section {
                        Text("Sign in to add papers to your library.").font(.footnote).foregroundStyle(.secondary)
                        Button("Sign in") { dismiss(); model.openSignIn() }
                    }
                } else if !model.canChangeLibrary {
                    Section { Text("Finish setting up this device to add papers.").font(.footnote).foregroundStyle(.secondary) }
                } else if !model.libraryHasSnapshot {
                    Section {
                        Text("Refresh your library before adding a paper.").font(.footnote).foregroundStyle(.secondary)
                        Button("Refresh library") { Task { await model.refreshLibrary() } }.disabled(model.libraryRefreshing)
                    }
                }
            }.navigationTitle("Add a paper").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving).macBarButton() }
                    // Design audit 2: a task sheet confirms in the top bar.
                    ToolbarItem(placement: .confirmationAction) {
                        if saving { ProgressView() } else {
                            Button("Add") { add() }
                                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canBeginImport)
                                .accessibilityIdentifier("import.add")
                        }
                    }
                }
                .onSubmit { if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.canBeginImport { add() } }
                .interactiveDismissDisabled(saving)
                .macSheetKeys(enabled: !saving)
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
    /// Search results show the arXiv number (people search by it); the Feed doesn't need it.
    var showsIdentifier = true
    @State private var adding = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // The Library rows' type scale (design audit F6): title, authors, then details.
            VStack(alignment: .leading, spacing: 4) {
                Text(result.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                if let authors = LibraryFormat.shortAuthors(result.authors) {
                    Text(authors).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if let abstract = result.abstract { Text(abstract).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                Text(([result.year.map(String.init)].compactMap { $0 } + ArxivTopics.names(for: result.categories, limit: 2)
                       + (showsIdentifier ? ["arXiv \(result.sourceID)"] : []))
                    .joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            DiscoveryAddControl(sourceID: result.sourceID, inLibrary: model.librarySourceIDs.contains(result.sourceID), adding: adding,
                                enabled: model.canBeginImport) {
                adding = true; issue = nil
                Task {
                    do { try await model.addDiscovered(result) }
                    catch { issue = "Couldn’t add “\(result.title)”. Try again." }
                    adding = false
                }
            }
        }
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
        ("OpenAlex", "Search ranking, and finding open-access copies of papers that aren't on arXiv (converted privately for you).", "CC0 data"),
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
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(deleting).macBarButton() } }
            .interactiveDismissDisabled(deleting)
            .macSheetKeys(enabled: !deleting)
        }
    }
}

/// The system search text field (look, clear button, Search key and accessibility of a search
/// bar) for a header row of our own, without the navigation bar drawer's spacing.
struct LibrarySearchField: UIViewRepresentable {
    @Binding var text: String
    var prompt: String
    @Binding var focused: Bool
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UISearchTextField {
        let field = UISearchTextField()
        field.delegate = context.coordinator
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.accessibilityIdentifier = "library.search"
        // Announced (and found by UI tests) as a search field, like the system search bar.
        field.accessibilityTraits.insert(.searchField)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UISearchTextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        if field.placeholder != prompt { field.placeholder = prompt }
        if focused, !field.isFirstResponder { DispatchQueue.main.async { field.becomeFirstResponder() } }
        else if !focused, field.isFirstResponder { DispatchQueue.main.async { field.resignFirstResponder() } }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: LibrarySearchField
        init(_ parent: LibrarySearchField) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        func textFieldDidBeginEditing(_ field: UITextField) { if !parent.focused { parent.focused = true } }
        func textFieldDidEndEditing(_ field: UITextField) { if parent.focused { parent.focused = false } }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit(); field.resignFirstResponder(); return true
        }
    }
}

/// One tab of the app's tab bar (design audit F10): every symbol in the same box so labels share a
/// baseline; the selected tab gets its filled symbol and a light accent capsule.
struct TabBarItem: View {
    let tab: ReaderTab
    let selected: Bool
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: selected && UIImage(systemName: tab.symbol + ".fill") != nil ? tab.symbol + ".fill" : tab.symbol).resizable().scaledToFit()
                .fontWeight(.medium).frame(width: 26, height: 21)
                .frame(width: 30, height: 24)
            Text(tab.rawValue).font(.caption2.weight(selected ? .semibold : .regular)).lineLimit(1)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .frame(maxWidth: .infinity).frame(minHeight: 49)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: Capsule())
        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
    }
}

/// Library header width: the readable column, or the full pane over the table.
private struct HeaderWidth: ViewModifier {
    let fullWidth: Bool
    func body(content: Content) -> some View {
        if fullWidth { content.padding(.horizontal, DesignMetrics.margin) } else { content.readableColumn() }
    }
}

/// Banners above content follow the header's width.
private struct BannerInset: ViewModifier {
    let inset: Bool
    let fullWidth: Bool
    func body(content: Content) -> some View {
        if !inset { content } else if fullWidth { content.padding(.horizontal, DesignMetrics.margin) } else { content.readableColumn() }
    }
}
