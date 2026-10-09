import SwiftUI
import ScienceReaderCore

struct RootView: View {
    @Bindable var model: ReaderModel
    @Environment(\.scenePhase) private var scenePhase
    /// A software keyboard covers the tab bar, as with the system tab bar, so
    /// the chat transcript keeps its space while typing.
    @State private var softwareKeyboardShown = false
    /// What the last keyboard hide left on screen (TestFlight build 21: the tab bar and A−/A+ ~170 pt up, the paper cut
    /// off above an empty band). After Search, WebKit's find bar stays docked where the keyboard was: UIKit reports the
    /// keyboard hidden with its end frame still on screen, and SwiftUI keeps that frame as a keyboard safe area. The tab
    /// bar was padded for the home indicator on top of it, and on a device the frame stayed once the bar had gone.
    @State private var keyboardLeftover = KeyboardLeftover.none
    /// The last keyboard shown was the find bar's: only its hide leaves a frame behind.
    @State private var findKeyboard = false

    private enum KeyboardLeftover {
        case none
        /// The find bar is docked: the tab bar sits just above it, the page above the tab bar.
        case findBar
        /// Nothing is there: the screens ignore the frame until the next keyboard.
        case frame
    }

    var body: some View {
        GeometryReader { geometry in
            // The Mac window is always the wide layout (its minimum width fits the panes).
            if geometry.size.width >= 850 || Platform.isMac { wideLayout(width: geometry.size.width) }
            else {
                // Floating chrome (2026-10-07): the tab bar floats over the screen, whose content scrolls
                // behind it; each screen keeps room for it (`tabBarSpace`) so its last row is reachable.
                // Over a docked find bar, the bar is the bottom safe area: no home indicator below the tabs.
                let safeBottom = keyboardLeftover == .findBar ? 0 : geometry.safeAreaInsets.bottom
                // The podcast mini-player rides on the tab bar and takes part of its reserve (PodcastMiniPlayer).
                let miniPlayer = model.podcasts.nowPlaying != nil
                destination(model.tab)
                    .environment(\.tabBarReserve, softwareKeyboardShown ? 0
                                 : ChromeMetrics.tabBarReserve(safeBottom: safeBottom) + (miniPlayer ? PodcastMiniPlayer.height : 0))
                    .overlay(alignment: .bottom) {
                        if !softwareKeyboardShown {
                            VStack(spacing: 6) {
                                if miniPlayer { PodcastMiniPlayer(model: model) }
                                tabBar
                            }
                                .padding(.horizontal, DesignMetrics.margin)
                                .padding(.bottom, ChromeMetrics.tabBarBottom(safeBottom: safeBottom))
                                .frame(maxHeight: .infinity, alignment: .bottom)
                                .ignoresSafeArea(keyboardLeftover == .frame ? [.container, .keyboard] : .container, edges: .bottom)
                        }
                    }
                    .onChange(of: model.generalChat) { _, general in
                        if model.tab == .chat { model.wideMode = general ? .chat : .reader }
                    }
            }
        }
        // A frame left with nothing there: ignored here and inside each screen's NavigationStack (`tabBarSpace`).
        .ignoresSafeArea(keyboardLeftover == .frame ? .keyboard : [], edges: .bottom)
        .environment(\.ignoresKeyboardFrame, keyboardLeftover == .frame)
        // On the root so the state stays true across wide/compact layout switches.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            // A hardware keyboard's shortcut bar is short; keep the tabs then.
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            softwareKeyboardShown = (frame?.height ?? 0) > 150
            keyboardLeftover = .none
            findKeyboard = findBarShown
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { keyboardHidden($0) }
        // Again once hidden, when the find bar has settled whether it stays.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { keyboardHidden($0) }
        // The bar can go with no further keyboard notification (the device's page was no longer dimmed for find):
        // its frame is then left with nothing there.
        .task(id: keyboardLeftover) {
            while keyboardLeftover == .findBar, (try? await Task.sleep(for: .milliseconds(500))) != nil {
                if !findBarShown { keyboardLeftover = .frame }
            }
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
        .sheet(isPresented: $model.showAllChats) { ChatHistoryView(model: model, paperID: model.allChatsPaperID).macSheetKeys() }
        .sheet(isPresented: $model.showDiagrams) { HistoryView(model: model, diagrams: true).macSheetKeys() }
        .sheet(item: $model.localPaperPresentation) { presentation in
            LocalPDFReaderView(presentation: presentation).macSheetKeys()
        }
        // At the root: deletion signs out, which leaves Settings.
        .alert("Account deleted", isPresented: $model.accountDeletedNotice) { Button("OK") {} } message: {
            Text("Your account and its data were deleted from our servers and this device.")
        }
        .sheet(isPresented: $model.showStore) { CreditsStoreView(model: model).macSheetKeys() }
        .modifier(PodcastPresenter(model: model))
        .sheet(isPresented: $model.showImportHelp) { ImportProgressExplainer().macSheetKeys() }
        .modifier(PDFUploadPresenter(model: model))
        .modifier(DeviceApprovalBanner(model: model))
        .sheet(item: $model.tagEditor) { request in
            if let paper = model.papers.first(where: { $0.id == request.paperID }) { TagEditorView(model: model, paper: paper) }
        }
        .sheet(item: $model.presentedDiagram) { presented in
            if let diagram = model.diagram(presented.id) { DiagramSheet(diagram: diagram).macSheetKeys() }
        }
        .sheet(isPresented: $model.showReport, onDismiss: {
            model.reportScreenshot = nil
            if model.showReportsAfterComposer { model.showReportsAfterComposer = false; model.showReports = true }
        }) { ReportComposer(model: model) }
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

    private func keyboardHidden(_ note: Notification) {
        softwareKeyboardShown = false
        let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .null
        guard let screen = note.object as? UIScreen, !frame.isEmpty, frame.minY < screen.bounds.maxY else { keyboardLeftover = .none; return }
        var barShown = findBarShown
        #if DEBUG && FIXTURE_HOST
        // UI tests: the device's case, the find bar's frame left once the bar had gone.
        if ProcessInfo.processInfo.arguments.contains("--find-bar-gone") { barShown = false }
        #endif
        keyboardLeftover = barShown ? .findBar : findKeyboard ? .frame : .none
    }

    /// WebKit's find bar is over the paper.
    private var findBarShown: Bool { ReaderWebView.paper?.findInteraction?.isFindNavigatorVisible == true }

    /// The tab bar: one glass capsule floating over the screen (2026-10-07).
    private var tabBar: some View {
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
                .buttonStyle(.plain)
                .disabled(tab == .paper && model.selectedPaper == nil)
                .opacity(tab == .paper && model.selectedPaper == nil ? 0.35 : 1)
                .accessibilityIdentifier("tab.\(tab.rawValue.lowercased())")
                .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
                .accessibilityShowsLargeContentViewer { Label(tab.rawValue, image: tab.icon) }
            }
        }
        .padding(4)
        .frame(maxWidth: ChromeMetrics.tabBarMaxWidth)
        .chromeSurface(Capsule(), interactive: true)
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
        case .feed: if model.podcasts.listenSelected { PodcastListenView(model: model) } else { FeedView(model: model) }
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
                    // The app's mark (∇ and its amber point), not a stock symbol.
                    Label { Text("Gradstep") } icon: {
                        Image(GradstepSymbol.mark).symbolRenderingMode(.palette).foregroundStyle(Color.gradstepInk, Color.gradstepAmber)
                    }.font(.headline)
                    Spacer()
                    Picker("View", selection: $model.wideMode) {
                        ForEach(WideMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 560)
                    Button { model.tab = .settings } label: { Image(GradstepSymbol.settings).font(.system(size: 19, weight: .medium)).frame(width: 44, height: 44) }
                        .accessibilityLabel("Settings")
                }.padding(.horizontal, 18).padding(.vertical, 12)
                Divider()
            }
            if model.tab == .settings {
                SettingsView(model: model, dismissSettings: { model.tab = .library })
            } else {
                switch model.wideMode {
                case .feed: if model.podcasts.listenSelected { PodcastListenView(model: model) } else { FeedView(model: model) }
                case .library: LibraryView(model: model)
                case .reader: ReaderSplit(model: model, width: width)
                case .browse:
                    HStack(spacing: 0) { LibraryView(model: model).frame(width: min(350, max(300, width * 0.29))); Divider(); PaperView(model: model).frame(maxWidth: .infinity) }
                case .chat: ChatView(model: model)
                }
            }
            // The podcast player docks along the bottom, below every pane (none of their controls go under it).
            if model.podcasts.nowPlaying != nil {
                Divider()
                PodcastMiniPlayer(model: model, wide: true).padding(.vertical, 6).frame(maxWidth: .infinity)
            }
        }
        .onChange(of: model.wideMode) { _, mode in model.showWideMode(mode) }
        #if targetEnvironment(macCatalyst)
        .background(MacWindowConfiguration(model: model, mode: model.wideMode, settingsShown: model.tab == .settings))
        #endif
    }
}

struct LibraryView: View {
    @Bindable var model: ReaderModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The pane's width (the List's readable column, and the column chooser's "needs more room").
    @State private var containerWidth: CGFloat = 0
    @State private var searchFocused = false
    @State private var showColumns = false
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
                        Text(model.libraryFiltered ? "Try a different title, author, or tag, or search all papers." : "Try a different title, author, or topic.")
                    } actions: {
                        Button("Clear search") { model.libraryQuery = "" }.accessibilityIdentifier("search.clear")
                        if model.libraryFiltered { Button("Show all papers") { clearFilters() }.accessibilityIdentifier("library.filter.clear") }
                    }
                } else if !model.librarySearchPending && model.libraryRows.isEmpty && model.libraryFiltered {
                    // A filter with nothing in it (the last failed import was retried, say): one way back.
                    ContentUnavailableView {
                        Label(model.libraryTagFilter.map { "No papers tagged “\($0)”" } ?? model.libraryFilter.emptyTitle,
                              systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Other papers are in All.")
                    } actions: {
                        Button("Show all papers") { clearFilters() }.accessibilityIdentifier("library.filter.clear")
                    }
                } else if !model.librarySearchPending && model.libraryRows.isEmpty {
                    ContentUnavailableView {
                        Label { Text(model.searchExternal ? "Find papers" : "Your library") } icon: {
                            model.searchExternal ? Image(systemName: "magnifyingglass") : Image(GradstepSymbol.library)
                        }
                    } description: {
                        Text(model.searchExternal ? "Search arXiv to add a paper." : "Add a paper to read and ask questions.")
                    } actions: {
                        Button("Open sample") { model.openSample() }.buttonStyle(.bordered).accessibilityIdentifier("sample.open")
                    }
                } else if tableShown {
                    // Owner requests 2026-10-06/07: the same table on every size, with the reader's columns that fit.
                    LibraryPaperTable(model: model) {
                        banners(inset: false).listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 8, leading: DesignMetrics.margin, bottom: 4, trailing: DesignMetrics.margin))
                        LibraryFilterBar(model: model)
                    }
                    .refreshable { await model.refreshLibrary() }
                    .overlay(alignment: .top) { updatingIndicator }
                } else {
                    // Also the table's form at accessibility text sizes.
                    libraryList()
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
            // iPad and Mac: drop PDFs on the Library to add them (docs/architecture/PDF_UPLOADS.md).
            .acceptsDroppedPDFs(model: model)
            .sheet(isPresented: $showColumns) {
                LibraryColumnsSheet(model: model, tableWidth: max(0, containerWidth - 2 * DesignMetrics.margin))
            }
            // Owner decision (2026-10-05, build 8 follow-up): one header row instead of the navigation
            // bar's title row and search drawer. At rest: search, Add and one options menu. While
            // searching: Cancel, and the Library/arXiv switch under the field.
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .tabBarSpace()
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
    /// table shows the List's rows (DESIGN.md › Tables).
    private var tableShown: Bool {
        model.libraryLayout == .table && !model.searchExternal && !dynamicTypeSize.isAccessibilitySize
    }

    private func clearFilters() { model.libraryFilter = .all; model.libraryTagFilter = nil }

    /// Only states the reader can act on; none while browsing normally.
    @ViewBuilder private func banners(inset: Bool) -> some View {
        let signIn = !model.isSignedIn && !searching
        let issue = model.searchExternal ? nil : model.libraryIssue
        let pending = !model.searchExternal && (!model.libraryCommands.isEmpty || model.libraryCommandIssue != nil)
        let offline = model.searchExternal ? nil : model.offlineCacheIssue
        let uploading = !model.searchExternal && PDFUploadBanners.shows(model)
        if signIn || issue != nil || pending || offline != nil || uploading {
            VStack(spacing: 8) {
                if uploading { PDFUploadBanners(model: model) }
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
                    .padding(.leading, 10).padding(.trailing, 6).frame(height: DesignMetrics.headerControl)
                    .chromeSurface(Capsule())
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
        // Floating chrome (2026-10-07): rows scroll under the header and fade out behind it. Over the table
        // the band stays solid: the table's column titles pin right below it.
        .chromeBand(.top, solid: tableShown)
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
                if tableShown {
                    // Owner request 2026-10-07: columns that can be turned on or off (a sheet; changes show at once).
                    MenuRow("Columns", systemImage: "tablecells") { showColumns = true }
                } else {
                    // The List's lines. (Archived papers are a filter now: the Archived chip.)
                    Menu {
                        Toggle("Abstracts", isOn: $model.showAbstracts)
                        Toggle("Topics", isOn: $model.showTopics)
                    } label: { Label { Text("Show") } icon: { menuIcon("eye") } }
                }
            }
            Section {
                MenuRow("All chats", systemImage: GradstepSymbol.chats) { model.showAllChats = true }
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
        // Authors, Tags, Pages and Source are the table's orders; each stays listed while it is the current order.
        LibrarySearchSort.Field.allCases.filter { !$0.isTableOnly || table || model.librarySort.field == $0 }
    }

    private var updatingIndicator: some View { SlowSearchIndicator(pending: model.librarySearchPending) }

    /// The List layout (also the table's form at accessibility text sizes), with the same filters.
    private func libraryList() -> some View {
        List {
            banners(inset: false).listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: DesignMetrics.margin, bottom: 4, trailing: DesignMetrics.margin))
            LibraryFilterBar(model: model)
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
                        PaperRow(paper: paper, selected: highlightsSelection && model.selectedPaper?.id == paper.id, offlineStatus: model.offlineStatus(for: paper), showAbstract: model.showAbstracts, showTopics: model.showTopics)
                    }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("paper.\(paper.id.wire)")
                        .contextMenu { LibraryRowActions(model: model, entry: entry) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) { LibrarySwipeActions(model: model, entry: entry) }
                case .pending(let item):
                    let retrying = model.isRetrying(item)
                    ImportRow(item: item, showAbstract: model.showAbstracts, showTopics: model.showTopics,
                              stepSince: model.importSteps.timing(of: item)?.since,
                              progress: retrying ? nil : model.importProgress(for: item), retrying: retrying,
                              action: LibraryImportAction.available(for: item, retrying: retrying,
                                  localPaperAvailable: model.localPaperAvailable(for: item)),
                              actionEnabled: { action in
                                  model.canChangeImports ||
                                  (item.phase == .sourceOnly && model.hasLocalPaperStore &&
                                   (action == .downloadOnDevice || action == .openLocalPDF))
                              },
                              explain: { model.showImportHelp = true }) { action in
                        LibraryImportAction.perform(action, on: item, model: model)
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
    /// While in progress: the step in the reader's words, a bar and the time left (`ImportProgressView`).
    var progress: ImportProgress? = nil
    /// Retry was tapped and is on its way: shown as running again at once.
    var retrying = false
    /// A stopped import's one action (Retry, Get credits, Remove), shown inline (owner feedback 2026-10-07).
    var action: LibraryImportAction? = nil
    var actionEnabled: (LibraryImportAction) -> Bool = { _ in true }
    /// "Why does this take a minute?" beside the progress.
    var explain: (() -> Void)? = nil
    var perform: ((LibraryImportAction) -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var active: Bool { item.isActive || retrying }
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
            if let progress {
                // In progress: the step in the reader's words, a bar and the time left (pipeline progress, 2026-10-07).
                ImportProgressView(progress: progress, style: .row, explain: explain).padding(.top, 2)
            } else {
                HStack(spacing: 6) {
                    if active { ProgressView().controlSize(.small).accessibilityHidden(true) }
                    if retrying {
                        Text(item.retryStep.label(short: false)).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ImportStatusText(item: item, since: stepSince).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let action, let perform {
                        Button(action.title) { perform(action) }.font(.footnote.weight(.semibold)).buttonStyle(.borderless)
                            .tint(action == .remove ? Color.secondary : Color.accentColor)
                            .disabled(!actionEnabled(action) && action != .getCredits)
                            .accessibilityHint(action.hint)
                            .accessibilityIdentifier(action == .getCredits ? "import.getCredits" : "import.\(action.title.lowercased()).\(item.id.wire)")
                    }
                    if !active, let url = item.sourceURL.flatMap({ URL(string: $0) }) {
                        Spacer(minLength: 8)
                        Link(item.sourceLinkTitle, destination: url).font(.footnote.weight(.semibold)).foregroundStyle(.tint)
                    }
                }.padding(.top, 2)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An import's status line. While it is in progress, how long the current step has run follows quietly
/// ("Downloading the PDF · 1 min"), and past three minutes "Taking longer than usual". It changes once a minute,
/// without animation; VoiceOver reads the step and the time. (Rows with an `ImportProgress` show
/// `ImportProgressView` instead.)
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
            // Its tags when it has any (docs/architecture/TAGS.md), else its arXiv topics.
            let topics = showTopics ? (paper.tags.isEmpty ? ArxivTopics.names(for: paper.keywords, limit: 3) : Array(paper.tags.prefix(3))) : []
            if !(metadata + topics).isEmpty { Text((metadata + topics).joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

struct FeedView: View {
    @Bindable var model: ReaderModel
    @State private var issue: String?
    @State private var width: CGFloat = 0
    @State private var showColumns = false
    @ScaledMetric(relativeTo: .subheadline) private var columnScale: CGFloat = 1
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.tabBarReserve) private var tabBarReserve
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
                    ContentUnavailableView { Label("Feed unavailable", image: GradstepSymbol.feed) }
                        description: { Text(message) }
                        actions: {
                            if model.librarySignInRequired {
                                Button { model.openSignIn() } label: { ProminentLabel(title: "Sign in") }.buttonStyle(.borderedProminent)
                            } else { Button("Try again") { model.loadFeed() } }
                        }
                case .loaded:
                    if model.feedResults.isEmpty {
                        ContentUnavailableView("No new papers", image: GradstepSymbol.feed, description: Text("Check back later or pick another topic."))
                    } else if model.shownFeedResults.isEmpty {
                        // Every paper here is already in the library and the reader hides those.
                        ContentUnavailableView {
                            Label("All in your library", image: GradstepSymbol.feed)
                        } description: {
                            Text("Every new paper in this topic is already in your library.")
                        } actions: {
                            Button("Show them") { model.feedHidesLibrary = false }.accessibilityIdentifier("feed.showLibrary")
                        }
                    } else if tableShown {
                        FeedTable(model: model, issue: $issue).refreshable { model.loadFeed() }
                    } else {
                        List {
                            if let issue {
                                StatusBanner(tone: .problem, systemImage: "exclamationmark.circle", message: issue).listRowSeparator(.hidden)
                            }
                            FeedColdStartNote(model: model)
                            ForEach(model.shownFeedResults) { result in
                                DiscoveryRow(model: model, result: result, issue: $issue, showsIdentifier: false)
                                    .listRowInsets(EdgeInsets(top: 12, leading: DesignMetrics.margin, bottom: 12, trailing: DesignMetrics.margin))
                            }
                        }
                        .listStyle(.plain).refreshable { model.loadFeed() }
                        .readableScrollColumn(width: width)
                    }
                }
            }
            // A− / A+ (build 16 #6): the Feed's text, in steps from the system's text size.
            .dynamicTypeSize(dynamicTypeSize.stepped(by: model.feedTextStep))
            // Room under the last row for the text size control.
            .contentMargins(.bottom, model.feedState == .loaded ? 56 : 0, for: .scrollContent)
            // Owner feedback (2026-10-06): the Feed's top used space like the Library's used to. Same
            // header as the Library: one row — the topics (the feed's filter) and the "…" menu.
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .tabBarSpace()
            .overlay(alignment: .bottomTrailing) {
                if model.feedState == .loaded && !model.feedResults.isEmpty {
                    let current = dynamicTypeSize.stepped(by: model.feedTextStep)
                    TextSizeControl(identifier: "feed.textSize",
                                    canShrink: dynamicTypeSize.stepped(by: model.feedTextStep - 1) != current,
                                    canGrow: dynamicTypeSize.stepped(by: model.feedTextStep + 1) != current,
                                    shrink: { model.feedTextStep = max(-6, model.feedTextStep - 1) },
                                    grow: { model.feedTextStep = min(6, model.feedTextStep + 1) })
                        .padding(.trailing, DesignMetrics.margin).padding(.bottom, tabBarReserve + 8)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .sheet(isPresented: $showColumns) { feedColumnsSheet }
            .task { if model.feedState == .idle || (model.feedState != .loading && model.feedResults.isEmpty && !model.librarySignInRequired) { model.loadFeed() } }
        }
    }

    /// Feed options › Columns (build 17).
    private var feedColumnsSheet: some View {
        let width = LibraryColumnSettings.WidthClass.current
        let chosen = model.feedColumns[width]
        let fitting = Set(PaperTableLayout.visibleColumns(FeedTableColumn.columns(chosen), width: max(0, self.width - 2 * DesignMetrics.margin),
                                                          scale: columnScale).map(\.id))
        return ColumnChooserSheet(
            identifier: "feed.columns", titleRow: ("Title", "With the first author"),
            options: FeedTableColumn.choosable.map { .init(id: $0.rawValue, title: $0.title, explanation: $0.explanation) },
            fixed: [("Add", FeedTableColumn.add.explanation)],
            chosen: Binding(get: { Set(model.feedColumns[width].map(\.rawValue)) },
                            set: { model.feedColumns[width] = Set($0.compactMap(FeedTableColumn.init(rawValue:))) }),
            defaults: Set(model.feedColumns.defaults(width).map(\.rawValue)),
            scrolling: Set(chosen.map(\.rawValue)).subtracting(fitting),
            footer: TableColumnWording.footer(width))
    }

    private var header: some View {
        HStack(spacing: 10) {
            if isFailed {
                PodcastListenChip(model: model)
                Text("Feed").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // Listen (podcasts) first, then the Feed's own chips: For you, the reader's topics and
                        // More topics when For you is offered; else the categories.
                        PodcastListenChip(model: model)
                        FeedChipsBar(model: model)
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
                if model.feedLayout == .table {
                    // The table's order and columns (build 17: "sort by Published, Title, Topic"; "choose which columns").
                    Section {
                        Menu {
                            Picker("Sort by", selection: Binding(get: { model.feedSort.key }, set: { key in
                                model.feedSort = PaperTableSort(key: key, ascending: key.ascendingFirst)
                            })) {
                                ForEach(FeedSortKey.offered(personal: model.currentFeedSelection.isPersonal), id: \.self) { Text($0.label).tag($0) }
                            }.pickerStyle(.inline)
                        } label: {
                            Label { Text("Sort by"); Text(model.feedSort.key.label) } icon: { menuIcon("arrow.up.arrow.down") }
                        }
                        MenuRow("Columns", systemImage: "tablecells") { showColumns = true }.accessibilityIdentifier("feed.columns")
                    }
                }
                Section {
                    Toggle(isOn: $model.feedHidesLibrary) { Label("Hide papers in your library", systemImage: "checkmark.circle") }
                        .accessibilityIdentifier("feed.hideLibrary")
                    MenuRow("Refresh feed", systemImage: "arrow.clockwise") { model.loadFeed() }.disabled(model.librarySignInRequired)
                }
                Section { MenuRow("Report this screen", systemImage: "ladybug") { model.beginReport(afterMenu: true) } }
            } label: { HeaderButtonLabel(systemImage: "ellipsis") }
            .buttonStyle(.plain).accessibilityLabel("Feed options")
        }
        .modifier(HeaderWidth(fullWidth: tableShown)).padding(.top, 2).padding(.bottom, 8)
        .chromeBand(.top, solid: tableShown)
    }
}

struct ChatView: View {
    @Bindable var model: ReaderModel
    @ScaledMetric(relativeTo: .body) private var bodySize = 17.0
    @ScaledMetric(relativeTo: .headline) private var titleFontSize = 17.0
    @FocusState private var composerFocused: Bool
    @Environment(\.tabBarReserve) private var tabBarReserve
    /// Where the floating controls end (global y): the bottom of the title bar above, the top of the message box below.
    @State private var chromeTop: CGFloat = 0
    @State private var chromeBottom: CGFloat = 0
    @State private var historyBounds = CGRect.zero
    @State private var newChatBounds = CGRect.zero
    @State private var toolbarLayoutWidth: CGFloat = 0
    @State private var renaming: UUID?
    var body: some View {
        NavigationStack {
            GeometryReader { available in
                // Reserve reading and editing space as text grows or a keyboard
                // reduces the pane. The transcript/composer retain their identity.
                // The podcast mini-player's share of the tab bar's reserve hides with the keyboard: it never decides the
                // message box's layout (counted while a keyboard appears, it tipped iPhones into the compact one).
                let podcastShare = model.podcasts.nowPlaying != nil && tabBarReserve > 0 ? PodcastMiniPlayer.height : 0
                let compact = available.size.height + podcastShare < bodySize * 20
                // Floating chrome (2026-10-07): the conversation runs the full height, under the title bar,
                // the context switch, the message box and the tab bar, and fades out behind them.
                // The insets are measured from the controls' edges (a proxy's safe area leaves out the
                // controls' own insets).
                GeometryReader { pane in
                    let frame = pane.frame(in: .global)
                    ChatTranscript(model: model, fontSize: model.chatFontSize * bodySize / 17, insets: EdgeInsets(
                        top: chromeTop > 0 ? max(0, chromeTop - frame.minY) : pane.safeAreaInsets.top, leading: 0,
                        bottom: chromeBottom > 0 ? max(0, frame.maxY - chromeBottom) : pane.safeAreaInsets.bottom, trailing: 0))
                }
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .safeAreaInset(edge: .top, spacing: 0) {
                    topControls(compact: compact).onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { chromeTop = $0 }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    bottomControls(compact: compact).onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { chromeBottom = $0 }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { toolbarLayoutWidth = $0 }
            .tabBarSpace(fade: false)
            .task(id: model.isSignedIn) { model.refreshChatProfiles() }
            .renameConversationAlert(model: model, conversation: $renaming)
            .navigationTitle(model.chatTitle).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { composerFocused = false; model.openAllChats(paper: chatsPaperID) } label: { Image(GradstepSymbol.chats) }
                        .accessibilityLabel("Chat history")
                        .background(ToolbarButtonBounds(layoutWidth: toolbarLayoutWidth) { historyBounds = $0 })
                }
                // Design audit F8: the paper a conversation is about sits under its title (one tap back).
                ToolbarItem(placement: .principal) { titleView }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.newChat(general: model.generalChat); composerFocused = true } label: { Image(GradstepSymbol.newChat) }
                        .accessibilityLabel("New chat")
                        .background(ToolbarButtonBounds(layoutWidth: toolbarLayoutWidth) { newChatBounds = $0 })
                }
                // Separate circles, like the Library's + and … (iOS 26 groups adjacent items otherwise).
                if #available(iOS 26.0, *) { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
                ToolbarItem(placement: .topBarTrailing) { optionsMenu }
            }
        }
    }

    /// Conversation notes (rare), floating over the top of the conversation; the band continues the title bar.
    private func topControls(compact: Bool) -> some View {
        VStack(spacing: 0) {
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
                    .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .chromeBand(.top)
    }

    /// The message box and its notes, floating over the end of the conversation (like Gemini's "Ask" field).
    private func bottomControls(compact: Bool) -> some View {
        VStack(spacing: 6) {
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
                .readableColumn()
            }
            if let issue = model.chatDraftIssue {
                HStack {
                    Text(issue).font(.caption)
                    Button("Retry") { model.retryDraftSave() }.font(.caption.weight(.semibold))
                }.padding(.horizontal, 16).accessibilityIdentifier("chat.draftIssue")
            } else if model.draftsArePersistent && !model.chatInput.isEmpty {
                Text(model.chatDraftStatusText).font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat.draftStatus")
            }
            HStack(alignment: .bottom, spacing: 8) {
                composer(compact: compact)
                // The software keyboard covers the tab bar (iPhone and compact iPad): a visible way back.
                if composerFocused && !Platform.isMac {
                    Button { composerFocused = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 17, weight: .semibold))
                            .frame(width: 50, height: 50).modifier(GlassCircle()).contentShape(Circle())
                    }.buttonStyle(.plain).foregroundStyle(.tint)
                        .accessibilityLabel("Dismiss keyboard").accessibilityIdentifier("chat.dismissKeyboard")
                        .keyboardShortcut(.cancelAction)
                }
            }.readableColumn()
            // Design audit F8: sync status only when something needs attention.
            if model.isGenerating { ProgressView("Saving…").font(.caption) }
            else if let issue = model.syncIssue { Text(issue).font(.caption2).dynamicTypeSize(...DynamicTypeSize.xxxLarge).foregroundStyle(.secondary) }
        }
        // Close above the tab bar (owner feedback, build 14: "space below chat box not well used").
        .padding(.top, 6).padding(.bottom, tabBarReserve > 0 ? 2 : 8)
        .frame(maxWidth: .infinity)
        .chromeBand(.bottom)
    }

    /// One glass pill: the question, then the answer settings (model, effort, length; 2026-10-08) and Send (or Stop)
    /// on the row under it, as in Gemini's message box. With little height (a keyboard in landscape) everything is one
    /// row and the settings control shows only its symbol.
    @ViewBuilder private func composer(compact: Bool) -> some View {
        let field = TextField("Chat", text: $model.chatInput, axis: .vertical)
            .focused($composerFocused).accessibilityIdentifier("chat.composer")
            .onChange(of: model.chatComposerFocusRequest) { _, _ in _ = model.takeComposerFocusRequest(); composerFocused = true } // Quote in Chat
            // Discuss in chat opens the Chat tab, created after the request: take it once it is on screen.
            .task { if model.takeComposerFocusRequest() { try? await Task.sleep(for: .milliseconds(300)); composerFocused = true } }
            .lineLimit(1...(compact ? 2 : 6)).fixedSize(horizontal: false, vertical: true)
        // One layout that changes shape, never two: the text field keeps its identity (and the keyboard its focus)
        // when the message box turns compact or back, for example while a keyboard appears.
        let layout = compact ? AnyLayout(HStackLayout(alignment: .bottom, spacing: 4)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
        layout {
            if compact { ChatProfileButton(model: model, compact: true).padding(.leading, 6).padding(.bottom, 3) }
            field.padding(.horizontal, compact ? 0 : 18).padding(.top, 14).padding(.bottom, compact ? 14 : 2)
            if compact {
                sendButton
            } else {
                HStack(alignment: .center, spacing: 4) {
                    ChatProfileButton(model: model).padding(.leading, 10)
                    Spacer(minLength: 4)
                    sendButton
                }
            }
        }
        .frame(minHeight: 50)
        .chromeSurface(RoundedRectangle(cornerRadius: 25, style: .continuous), outlined: true)
    }

    private var sendButton: some View {
        Group {
            if model.isAnswering {
                Button { model.stopAnswer() } label: { ComposerActionLabel(systemImage: "stop.fill", enabled: !model.isStoppingAnswer) }
                    .disabled(model.isStoppingAnswer).accessibilityLabel("Stop answer").accessibilityIdentifier("chat.stop")
            } else {
                Button { send() } label: { ComposerActionLabel(systemImage: "arrow.up", enabled: !sendDisabled) }
                    .disabled(sendDisabled).accessibilityLabel("Send").accessibilityIdentifier("chat.send")
                    // Mac: ⌘Return sends; Return starts a new line, as on iPad (and input methods keep Return).
                    .macKeyboardShortcut(.return, modifiers: .command)
            }
        }.buttonStyle(.plain).padding(3)
    }

    private func send() {
        // Mac (⌘Return): the composer ends editing first, so it can't write the sent text back afterwards;
        // then it takes the focus again for the next question.
        guard Platform.isMac, composerFocused else { Task { await model.sendMessage() }; return }
        composerFocused = false
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            await model.sendMessage()
        }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            composerFocused = true
        }
    }

    private var sendDisabled: Bool {
        model.isGenerating || model.isDiscardingDraft || (!model.generalChat && !model.canUsePaperChat) || !model.chatContextComplete
            || model.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Paper chat or General chat (owner feedback, build 14: "the paper vs general option needs to be in a menu …
    /// we can't take away screen real estate for chatting"). Same two modes; Paper needs a paper to talk about.
    private var contextPicker: some View {
        Picker("Chat about", selection: Binding(get: { model.generalChat }, set: { if $0 || model.canUsePaperChat { model.generalChat = $0 } })) {
            Label("Paper chat", image: GradstepSymbol.paper).tag(false).disabled(!model.canUsePaperChat)
            Label("General chat", image: GradstepSymbol.chat).tag(true)
        }.pickerStyle(.inline)
    }

    /// In a paper chat, All chats opens on this paper's chats ("This paper"; one tap on All shows everything).
    private var chatsPaperID: UUID? { model.generalChat ? nil : model.chatPaper?.id }

    /// The paper's other conversations, newest first, in the title menu (the legacy app opened a paper on its
    /// History); all of them in All chats, filtered to this paper.
    @ViewBuilder private var paperChatsSection: some View {
        if let paper = chatsPaperID {
            let chats = model.conversations(about: paper)
            let others = chats.filter { $0.id != model.activeConversation }
            if !others.isEmpty {
                Section("Chats about this paper") {
                    ForEach(others.prefix(5)) { chat in
                        Button { composerFocused = false; model.openConversation(chat.id) } label: {
                            let title = ChatTitle.display(chat)
                            Text(title.isEmpty ? "Untitled conversation" : title)
                            Text([ChatHistoryFormat.lastUsed(chat.lastUsedAt), ChatHistoryFormat.messages(chat.messageCount)].joined(separator: " · "))
                        }
                        .accessibilityIdentifier("chat.paperChat.\(chat.id.wire)")
                    }
                    MenuRow(chats.count == 1 ? "Show in All chats" : "All \(chats.count) chats about this paper", systemImage: GradstepSymbol.chats) {
                        composerFocused = false; model.openAllChats(paper: paper)
                    }
                    .accessibilityIdentifier("chat.paperChats.all")
                }
            }
        }
    }

    /// iPad Reader layout: the paper is already open beside the chat.
    private var besidePaper: Bool { Platform.isLargeScreen && model.wideMode == .reader && model.tab != .chat }

    /// A custom principal view can report its ideal width beyond the space
    /// UIKit leaves between toolbar buttons. Use their measured positions,
    /// including each button's minimum touch target, so long titles truncate.
    private var titleWidth: CGFloat {
        guard historyBounds.width > 0, newChatBounds.width > 0 else { return 160 }
        let left = historyBounds.midX < newChatBounds.midX ? historyBounds : newChatBounds
        let right = historyBounds.midX < newChatBounds.midX ? newChatBounds : historyBounds
        let start = left.midX + max(44, left.width) / 2
        let end = right.midX - max(44, right.width) / 2
        return max(0, min(420, end - start - 16))
    }

    /// UIKit's toolbar Menu keeps an intrinsic label width even when its
    /// surrounding SwiftUI frame shrinks. Fit its visible text explicitly;
    /// accessibility and the saved conversation retain the complete title.
    private var visibleTitle: String {
        let title = model.chatTitle
        let font = UIFont.systemFont(ofSize: titleFontSize, weight: .semibold)
        let available = max(0, titleWidth - 24) // chevron and its spacing
        func fits(_ value: String) -> Bool { (value as NSString).size(withAttributes: [.font: font]).width <= available }
        guard !fits(title) else { return title }
        let characters = Array(title)
        var low = 0, high = characters.count
        while low < high {
            let count = (low + high + 1) / 2
            if fits(String(characters.prefix(count)) + "…") { low = count } else { high = count - 1 }
        }
        return String(characters.prefix(low)) + "…"
    }

    /// The conversation title is the menu that switches Paper chat / General chat; under it, the paper the
    /// conversation is about (tap to return to it), or "General chat".
    private var titleView: some View {
        VStack(spacing: 1) {
            Menu {
                // An anchored chat (from a passage) can go back to it (Views/PaperPassages.swift).
                Section { GoToPassageMenuRow(model: model) { composerFocused = false } }
                if let conversation = model.activeConversation, !model.chatWasDeleted {
                    Section {
                        MenuRow("Rename…", systemImage: "pencil") { composerFocused = false; renaming = conversation }
                            .accessibilityIdentifier("chat.rename")
                    }
                }
                contextPicker
                paperChatsSection
            } label: {
                HStack(spacing: 3) {
                    Text(visibleTitle).font(.system(size: titleFontSize, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }.foregroundStyle(.primary).frame(minWidth: 0, maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.context")
            // Not just the title: a new conversation is titled "New chat", like the button beside it.
            .accessibilityLabel("Conversation: \(model.chatTitle)")
            .accessibilityValue(model.generalChat ? "General chat" : "Paper chat")
            .accessibilityHint(chatsPaperID == nil ? "Switches between paper chat and general chat"
                               : "Switches between paper chat and general chat, or opens another chat about this paper")
            if !model.generalChat, let paper = model.chatPaper, !besidePaper {
                Button { composerFocused = false; model.select(paper) } label: {
                    Label(paper.title, systemImage: "doc.text").labelStyle(.titleAndIcon).font(.caption).lineLimit(1)
                }.buttonStyle(.plain).foregroundStyle(.tint)
                    .accessibilityLabel("Return to paper: \(paper.title)").accessibilityIdentifier("chat.returnToPaper")
                    .accessibilityShowsLargeContentViewer { Label(paper.title, systemImage: "doc.text") }
            } else if !model.generalChat, model.chatPaper == nil, model.canUsePaperChat {
                Text("Paper unavailable in this library").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if model.generalChat {
                Text("General chat").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.frame(width: titleWidth)
    }

    /// Design audit F2: the same "…" as every screen — text size, diagrams, reporting.
    private var optionsMenu: some View {
        Menu {
            ControlGroup {
                MenuRow("Smaller text", systemImage: "textformat.size.smaller") { model.chatFontSize = max(13, model.chatFontSize - 1) }
                MenuRow("Larger text", systemImage: "textformat.size.larger") { model.chatFontSize = min(26, model.chatFontSize + 1) }
            }.controlGroupStyle(.compactMenu)
            Section {
                GoToPassageMenuRow(model: model) { composerFocused = false }
                MenuRow("All chats", systemImage: GradstepSymbol.chats) { composerFocused = false; model.openAllChats(paper: chatsPaperID) }
                MenuRow("All diagrams", systemImage: "square.stack.3d.up") { composerFocused = false; model.showDiagrams = true }
            }
            Section {
                MenuRow("Report this screen", systemImage: "ladybug") { composerFocused = false; model.beginReport(afterMenu: true) }
            }
        } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Chat options")
    }
}

/// Toolbar items have separate SwiftUI hosting roots, so their `.global`
/// geometry is not a shared coordinate space. Report real window coordinates
/// after layout; pane-width changes also ask the bridge to measure again.
private struct ToolbarButtonBounds: UIViewRepresentable {
    let layoutWidth: CGFloat
    let report: (CGRect) -> Void

    func makeUIView(context: Context) -> BoundsView {
        let view = BoundsView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: BoundsView, context: Context) {
        view.report = report
        view.scheduleMeasurement()
    }

    final class BoundsView: UIView {
        var report: ((CGRect) -> Void)?
        private var scheduled = false
        private var previous: CGRect?

        override func didMoveToWindow() { super.didMoveToWindow(); scheduleMeasurement() }
        override func layoutSubviews() { super.layoutSubviews(); scheduleMeasurement() }

        func scheduleMeasurement() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard let window = self.window, !self.bounds.isEmpty else { return }
                let rect = self.convert(self.bounds, to: window)
                guard rect != self.previous else { return }
                self.previous = rect
                self.report?(rect)
            }
        }
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
                // Owner feedback, build 14 #8: one Account row (who, how, synced?) opening the Account page, which
                // holds sync, Sign out and Delete account (`SettingsPages.swift`).
                Section {
                    if model.isSignedIn {
                        NavigationLink {
                            AccountView(model: model) { showDeleteAccount = true }
                        } label: {
                            let sync = SyncSummary.from(status: model.syncStatus, issue: model.syncIssue, pending: model.publishedPendingCount)
                            let methods = model.email?.isEmpty == false ? AccountFormat.methods(model.signInProviders) : nil
                            AccountRow(name: AccountFormat.name(email: model.email, providers: model.signInProviders),
                                       detail: [methods.map { "Signed in with \($0)" }, sync.short].compactMap { $0 }.joined(separator: " · "))
                        }
                        .accessibilityIdentifier("account.row")
                        if let issue = model.accountPreparationIssue {
                            Text(issue).font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("account.preparationIssue")
                            Button("Try again") { Task { await model.retryAccountPreparation() } }
                                .disabled(model.isBusy).accessibilityIdentifier("account.retryPreparation")
                        }
                    }
                    else {
                        Button { model.openSignIn() } label: { Label("Sign in or create an account", systemImage: "person.crop.circle") }
                            .accessibilityIdentifier("account.signIn")
                    }
                } footer: {
                    if !model.isSignedIn { Text("Sign in to sync your library and chats between your devices.") }
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
                if model.chatTransport != nil {
                    Section {
                        NavigationLink {
                            ChatDefaultsView(model: model)
                        } label: {
                            LabeledContent("Chat defaults", value: ChatProfileText.summary(model.chatDefaultProfile, table: model.chatProfileTable))
                        }
                        .accessibilityIdentifier("settings.chatDefaults")
                    } footer: {
                        Text("The model, effort and length new chats start with. A chat can change them in its message box.")
                    }
                }
                Section("Reading") {
                    ThemePicker(selection: $model.appearance)
                    sizeSlider("Paper text size", value: $model.paperFontSize, range: 14...26)
                    sizeSlider("Chat text size", value: $model.chatFontSize, range: 14...24)
                    Toggle("Underline passages with chats", isOn: $model.showsPassageMarks)
                        .accessibilityIdentifier("settings.passageMarks")
                }
                // Design audit F11: rows that open something look alike (title + chevron); actions are tinted.
                // (Sync now moved to the Account page, beside the sync state it acts on.)
                Section("Your research") {
                    openRow("All chats") { model.showAllChats = true }
                    openRow("All diagrams") { model.showDiagrams = true }
                }
                Section("Testing") {
                    #if INTERNAL
                    SessionCaptureSettings()
                    #endif
                    Button("Report this screen") { model.beginReport() }
                    openRow("My reports") { model.showReports = true }.disabled(model.support == nil)
                    Button("Open reader sample") { model.openSample() }
                }
                // Owner feedback, build 14 #9: version, privacy and acknowledgements behind one row at the bottom.
                Section {
                    NavigationLink("About Gradstep") { AboutView(version: Self.version) }.accessibilityIdentifier("settings.about")
                }
            }
            .readableScrollColumn(width: width)
            .tabBarSpace(color: .chromeGroupedBackground)
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

/// All diagrams. (All chats is `ChatHistoryView`, a table.)
struct HistoryView: View {
    @Bindable var model: ReaderModel
    let diagrams: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            let savedDiagrams = model.privateState.diagrams()
            List {
                ForEach(savedDiagrams, id: \.id) { saved in
                    NavigationLink(saved.diagram.title) { DiagramDetail(diagram: saved.diagram) }
                        .accessibilityIdentifier("diagram.\(saved.id.wire)")
                }
            }.overlay { if savedDiagrams.isEmpty { ContentUnavailableView("No diagrams yet", systemImage: "square.stack.3d.up") } }
                .navigationTitle("All diagrams").navigationBarTitleDisplayMode(.inline)
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
                    #if targetEnvironment(macCatalyst)
                    MacDeviceApprovalSection { refresh in
                        try await model.macApprovalPayload(refresh: refresh)
                    }
                    #endif
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

/// "Updating results…" over the Library, only when its search is slow enough to notice (owner feedback, build 16 #7).
/// Every import progress update re-runs the library's search, which finishes in milliseconds; shown at once, the
/// spinner and its words flashed under the filter chips several times a minute while a paper was being added.
struct SlowSearchIndicator: View {
    let pending: Bool
    static let delay: Duration = .milliseconds(600)
    @State private var shown = false
    var body: some View {
        Group {
            if pending && shown { ProgressView("Updating results…").padding(8).allowsHitTesting(false).transition(.opacity) }
        }
        .task(id: pending) {
            guard pending else { shown = false; return }
            try? await Task.sleep(for: Self.delay)
            if !Task.isCancelled { shown = true }
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
                    orderChips
                    if let issue { Text(issue).font(.footnote).foregroundStyle(.secondary) }
                    ForEach(model.orderedDiscoveryResults) { result in DiscoveryRow(model: model, result: result, issue: $issue) }
                }.listStyle(.plain)
            }
        }
    }

    /// Newest first (the default) or arXiv's relevance order, as chips that scroll away with the results.
    private var orderChips: some View {
        HStack(spacing: 8) {
            ForEach(DiscoveryOrder.allCases) { order in
                ChipButton(title: order.title, selected: model.discoveryOrder == order) { model.discoveryOrder = order }
                    .accessibilityIdentifier("discover.order.\(order.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Order")
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: DesignMetrics.margin, bottom: 4, trailing: DesignMetrics.margin))
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
    @State private var expanded = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // The Library rows' type scale (design audit F6): title, authors, then details.
            VStack(alignment: .leading, spacing: 4) {
                Text(result.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                if let authors = LibraryFormat.shortAuthors(result.authors) {
                    Text(authors).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if let reason = result.reason { FeedReasonLine(reason: reason) }
                if let abstract = result.abstract {
                    Text(abstract).font(.footnote).foregroundStyle(.secondary).lineLimit(expanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(expanded ? "Less" : "Full abstract") { expanded.toggle() }
                        .font(.footnote).buttonStyle(.borderless)
                        .accessibilityIdentifier("discover.abstract.\(result.sourceID)")
                    if expanded && result.abstractTruncated, let url = URL(string: "https://arxiv.org/abs/\(result.sourceID)") {
                        Link("Read the full abstract on arXiv", destination: url).font(.footnote)
                    }
                }
                // Year, popularity when known, its specific topics (else arXiv topics), and in search the arXiv number.
                Text(([result.year.map(String.init), FeedFormat.popularity(result)].compactMap { $0 } + FeedFormat.topics(result, limit: 3)
                       + (showsIdentifier ? ["arXiv \(result.sourceID)"] : []))
                    .joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    .accessibilityLabel(([result.year.map(String.init), result.upvotes.map { _ in FeedFormat.spokenPopularity(result) }].compactMap { $0 }
                                         + FeedFormat.topics(result, limit: 3) + (showsIdentifier ? ["arXiv \(result.sourceID)"] : []))
                        .joined(separator: ", "))
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
        ("Mathpix Markdown, MathJax, markdown-it", "Used on the server to make readable versions of papers, equations included. Each readable version carries these notices.", "MIT / Apache 2.0"),
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
        // On the header's glass capsule (floating chrome), not the system's gray field.
        field.borderStyle = .none
        field.backgroundColor = .clear
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
